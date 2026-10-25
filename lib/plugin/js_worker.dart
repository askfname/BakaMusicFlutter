/// JS 插件 worker：在独立 isolate 内托管 QuickJS 运行时与插件实例
///
/// QuickJsPluginRuntime 的线程模型与挂起-重放机制：
/// - JS 桥 `BakaNative` 是同步的，而 Dart 网络请求是异步的；
///   `request` 操作先返回 `__BAKA_SUSPEND__` 标记让 JS 抛错中断求值，
///   由 Dart 侧执行真实 HTTP 后从头重放；已完成请求按 (method+url) 签名
///   存入响应链，本轮同签名第 n 次调用命中链上第 n 条响应（与调用位置解耦，
///   插件吞掉挂起继续 fallback 时也稳定收敛）；
/// - 其余桥操作（哈希/HMAC/模幂/编码/解压/AES）同步计算直接返回并记忆，
///   Date.now/Math.random/randomBytes 按本轮调用序记忆保证重放确定性；
/// - 同时托管 LX 取流脚本（lx-music-source 格式）：initLx/lxReady/invokeLx
///   复用同一挂起-重放核心；
/// - 运行时与插件对象常驻 worker，跨调用复用；取消不重建，方法超时才由调用方终止。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:isolate';

import 'package:quickjs_engine/quickjs_engine.dart';

import 'js_bootstrap.dart';
import 'js_compute.dart' as compute;
import 'lx_bootstrap.dart';
import 'plugin_http_client.dart';

/// 挂起/错误/取消标记
const String _suspendMarker = '__BAKA_SUSPEND__';
const String _errorMarkerPrefix = '__BAKA_ERROR__';
const String _canceledMarker = '__BAKA_CANCELED__';

/// 单次 invoke 允许的最大重放轮数，防御插件请求序列不稳定导致的死循环。
/// 多数插件的方法需要几十上百个串行请求（每轮重放只推进一个请求），
/// 确定性记忆使单轮重放接近零成本后提高上限不会拖慢正常流程
const int _maxReplayPasses = 512;

/// QuickJS 运行时内存上限（16MiB 响应经 JSON 往返的峰值约 40-60MiB）
const int _runtimeMemoryLimit = 128 * 1024 * 1024;

/// worker 级故障（启动/加载失败、运行时已停止、超时等）
class PluginWorkerException implements Exception {
  PluginWorkerException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 插件 JS 方法执行抛出的错误（message 为 JS 侧 Error 文本）
class PluginJsErrorException extends PluginWorkerException {
  PluginJsErrorException(super.message);
}

/// 插件调用被主动取消（播放抢占/插件重载）
class PluginCanceledException implements Exception {
  @override
  String toString() => '插件调用已取消';
}

/// 插件方法执行超时，调用方应终止并重建 worker
class PluginWorkerTimeoutException extends PluginWorkerException {
  PluginWorkerTimeoutException(super.message);
}

/// 加载完成后返回的插件元信息
class PluginLoadResult {
  PluginLoadResult({
    required this.name,
    required this.platform,
    required this.qualities,
  });

  final String name;
  final String platform;
  final List<String> qualities;
}

/// worker 调用侧句柄（运行在主 isolate）
class PluginWorker {
  PluginWorker._(this._isolate, this._receivePort);

  final Isolate _isolate;
  final ReceivePort _receivePort;

  SendPort? _sendPort;
  StreamSubscription<dynamic>? _subscription;
  Completer<void>? _handshake;
  Completer<PluginLoadResult>? _loadCompleter;
  Completer<String>? _lxLoadCompleter;
  Completer<void>? _closedCompleter;
  final Map<int, Completer<String>> _pending = {};
  int _invokeSeq = 0;
  bool _dead = false;

  /// worker 日志回调（level: log/info/error/debug）
  void Function(String level, String message)? onLog;

  bool get isDead => _dead;

  /// 启动 worker isolate 并完成握手
  static Future<PluginWorker> spawn() async {
    final receivePort = ReceivePort();
    final isolate = await Isolate.spawn(
      _workerMain,
      receivePort.sendPort,
      debugName: 'BakaPluginWorker',
    );
    final worker = PluginWorker._(isolate, receivePort);
    final handshake = Completer<void>();
    worker._handshake = handshake;
    worker._subscription = receivePort.listen((dynamic message) {
      if (message is SendPort) {
        worker._sendPort = message;
        if (!handshake.isCompleted) handshake.complete();
        return;
      }
      worker._handleMessage(message);
    });
    final errors = ReceivePort();
    isolate.addErrorListener(errors.sendPort);
    errors.listen((dynamic error) {
      worker._handleFatal('插件 worker 异常: $error');
    });
    isolate.addOnExitListener(receivePort.sendPort);
    return handshake.future
        .timeout(
          const Duration(seconds: 10),
          onTimeout: () {
            worker.kill();
            throw PluginWorkerException('插件 worker 启动超时');
          },
        )
        .then((_) => worker);
  }

  /// 加载插件源码，返回平台名与支持音质
  Future<PluginLoadResult> load(
    String name,
    String source, {
    Duration timeout = const Duration(seconds: 30),
  }) {
    if (_dead) {
      return Future.error(PluginWorkerException('插件 worker 已停止'));
    }
    final completer = Completer<PluginLoadResult>();
    _loadCompleter = completer;
    _sendMessage({'t': 'init', 'name': name, 'source': source});
    return completer.future.timeout(
      timeout,
      onTimeout: () {
        _loadCompleter = null;
        throw PluginWorkerException('插件加载超时');
      },
    );
  }

  /// 加载 LX 取流脚本，返回 `inited` 事件声明的源 JSON 文本
  Future<String> loadLx(
    String name,
    String source,
    String infoJson, {
    Duration timeout = const Duration(seconds: 30),
  }) {
    if (_dead) {
      return Future.error(PluginWorkerException('插件 worker 已停止'));
    }
    final completer = Completer<String>();
    _lxLoadCompleter = completer;
    _sendMessage({
      't': 'initLx',
      'name': name,
      'source': source,
      'infoJson': infoJson,
    });
    return completer.future.timeout(
      timeout,
      onTimeout: () {
        _lxLoadCompleter = null;
        throw PluginWorkerException('LX 脚本载入超时');
      },
    );
  }

  /// 调用插件方法（argsJson 为 JSON 数组文本），返回 JSON 结果文本
  ///
  /// 超时抛出 [PluginWorkerTimeoutException]；此时调用方应 [cancel] 取消
  /// 在途请求，worker 与插件对象保留
  Future<String> invoke(String method, String argsJson, {Duration? timeout}) {
    if (_dead) {
      return Future.error(PluginWorkerException('插件 worker 已停止'));
    }
    final id = ++_invokeSeq;
    final completer = Completer<String>();
    _pending[id] = completer;
    _sendMessage({
      't': 'invoke',
      'id': id,
      'method': method,
      'argsJson': argsJson,
    });
    final future = completer.future;
    if (timeout == null) return future;
    return future.timeout(
      timeout,
      onTimeout: () {
        _pending.remove(id);
        throw PluginWorkerTimeoutException(
          '插件方法执行超时(${timeout.inMilliseconds}ms): $method',
        );
      },
    );
  }

  /// 调用 LX 脚本 `request` 处理器解析播放地址（musicInfoJson 为曲目 JSON），
  /// 返回 `{"url": ...}` 结果文本
  Future<String> invokeLx(
    String source,
    String quality,
    String musicInfoJson, {
    Duration? timeout,
  }) {
    if (_dead) {
      return Future.error(PluginWorkerException('插件 worker 已停止'));
    }
    final id = ++_invokeSeq;
    final completer = Completer<String>();
    _pending[id] = completer;
    _sendMessage({
      't': 'invokeLx',
      'id': id,
      'source': source,
      'quality': quality,
      'musicInfoJson': musicInfoJson,
    });
    final future = completer.future;
    if (timeout == null) return future;
    return future.timeout(
      timeout,
      onTimeout: () {
        _pending.remove(id);
        throw PluginWorkerTimeoutException(
          'LX 解析超时(${timeout.inMilliseconds}ms): $source $quality',
        );
      },
    );
  }

  /// 中止当前调用（不终止 worker，插件对象与运行时保留）
  void cancel() {
    if (_dead) return;
    _sendPort?.send({'t': 'cancel'});
  }

  /// 优雅关闭：等待 worker 释放引擎后终止 isolate
  Future<void> close() async {
    if (_dead) return;
    final closed = Completer<void>();
    _closedCompleter = closed;
    _sendPort?.send({'t': 'close'});
    try {
      await closed.future.timeout(const Duration(seconds: 3));
    } catch (_) {}
    kill();
  }

  /// 硬终止 worker（方法超时/插件重载路径）
  void kill() {
    if (_dead) return;
    _dead = true;
    try {
      _isolate.kill(priority: Isolate.immediate);
    } catch (_) {}
    _subscription?.cancel();
    _subscription = null;
    _receivePort.close();
    final error = PluginWorkerException('插件运行时已停止');
    final load = _loadCompleter;
    _loadCompleter = null;
    if (load != null && !load.isCompleted) {
      load.completeError(error);
    }
    final lxLoad = _lxLoadCompleter;
    _lxLoadCompleter = null;
    if (lxLoad != null && !lxLoad.isCompleted) {
      lxLoad.completeError(error);
    }
    _failPending(error);
    final closed = _closedCompleter;
    _closedCompleter = null;
    if (closed != null && !closed.isCompleted) {
      closed.complete();
    }
  }

  void _sendMessage(Map<String, dynamic> message) {
    final port = _sendPort;
    if (port == null) return;
    port.send(message);
  }

  void _handleFatal(String message) {
    if (_dead) return;
    _dead = true;
    final error = PluginWorkerException(message);
    final handshake = _handshake;
    _handshake = null;
    if (handshake != null && !handshake.isCompleted) {
      handshake.completeError(error);
    }
    final load = _loadCompleter;
    _loadCompleter = null;
    if (load != null && !load.isCompleted) {
      load.completeError(error);
    }
    final lxLoad = _lxLoadCompleter;
    _lxLoadCompleter = null;
    if (lxLoad != null && !lxLoad.isCompleted) {
      lxLoad.completeError(error);
    }
    _failPending(error);
    final closed = _closedCompleter;
    _closedCompleter = null;
    if (closed != null && !closed.isCompleted) {
      closed.complete();
    }
    _subscription?.cancel();
    _subscription = null;
    _receivePort.close();
  }

  void _failPending(PluginWorkerException error) {
    final pending = List<Completer<String>>.of(_pending.values);
    _pending.clear();
    for (final completer in pending) {
      if (!completer.isCompleted) {
        completer.completeError(error);
      }
    }
  }

  void _handleMessage(dynamic message) {
    if (_dead) return;
    if (message == null) {
      _handleFatal('插件 worker 已退出');
      return;
    }
    if (message is! Map) return;
    final type = '${message['t'] ?? ''}';
    switch (type) {
      case 'ready':
        final load = _loadCompleter;
        _loadCompleter = null;
        if (load != null && !load.isCompleted) {
          final qualities = <String>[];
          final rawQualities = message['qualities'];
          if (rawQualities is List) {
            for (final item in rawQualities) {
              final text = '$item'.trim();
              if (text.isNotEmpty) qualities.add(text);
            }
          }
          load.complete(
            PluginLoadResult(
              name: '${message['name'] ?? ''}',
              platform: '${message['platform'] ?? ''}',
              qualities: qualities,
            ),
          );
        }
        break;
      case 'lxReady':
        final lxLoad = _lxLoadCompleter;
        _lxLoadCompleter = null;
        if (lxLoad != null && !lxLoad.isCompleted) {
          lxLoad.complete('${message['sourcesJson'] ?? 'null'}');
        }
        break;
      case 'initError':
        final error = PluginWorkerException(
          '${message['message'] ?? '插件加载失败'}',
        );
        final load = _loadCompleter;
        _loadCompleter = null;
        if (load != null && !load.isCompleted) {
          load.completeError(error);
        }
        final lxLoad = _lxLoadCompleter;
        _lxLoadCompleter = null;
        if (lxLoad != null && !lxLoad.isCompleted) {
          lxLoad.completeError(error);
        }
        break;
      case 'done':
        final id = message['id'];
        final completer = id is int ? _pending.remove(id) : null;
        if (completer != null && !completer.isCompleted) {
          completer.complete('${message['result'] ?? ''}');
        }
        break;
      case 'error':
        final id = message['id'];
        final completer = id is int ? _pending.remove(id) : null;
        if (completer != null && !completer.isCompleted) {
          completer.completeError(
            PluginJsErrorException('${message['message'] ?? ''}'),
          );
        }
        break;
      case 'canceled':
        final id = message['id'];
        final completer = id is int ? _pending.remove(id) : null;
        if (completer != null && !completer.isCompleted) {
          completer.completeError(PluginCanceledException());
        }
        break;
      case 'log':
        final callback = onLog;
        if (callback != null) {
          callback(
            '${message['level'] ?? 'log'}',
            '${message['message'] ?? ''}',
          );
        }
        break;
      case 'closed':
        final closed = _closedCompleter;
        _closedCompleter = null;
        if (closed != null && !closed.isCompleted) {
          closed.complete();
        }
        break;
    }
  }
}

/// 待执行请求：签名 + 原始配置（执行后响应追加进对应签名的响应链）
class _PendingRequest {
  _PendingRequest(this.signature, this.configText);

  final String signature;
  final String configText;
}

/// worker isolate 入口
void _workerMain(SendPort ownerPort) {
  final receivePort = ReceivePort();
  ownerPort.send(receivePort.sendPort);
  final worker = _PluginWorkerIsolate(ownerPort, receivePort);
  receivePort.listen((dynamic message) {
    try {
      worker.handleMessage(message);
    } catch (_) {
      // 消息处理异常不应终结 isolate
    }
  });
}

/// 运行在 worker isolate 内的插件宿主
class _PluginWorkerIsolate {
  _PluginWorkerIsolate(this._ownerPort, this._receivePort);

  final SendPort _ownerPort;
  final ReceivePort _receivePort;

  QuickJsRuntime2? _runtime;
  PluginHttpClient? _http;
  String _name = '';
  String _platform = '';
  bool _ready = false;
  bool _closed = false;
  bool _canceled = false;
  Future<void> _queue = Future<void>.value();

  /// 请求响应链：签名 → 按调用次序累积的响应。
  /// 重放时同一签名第 n 次调用命中链上第 n 条响应，与调用位置解耦——
  /// 插件在挂起被内层 catch 吞掉后继续走 fallback 时，后续请求的
  /// 出现位置轮轮变化，位置游标式记忆会持续失配分叉、永不收敛
  final Map<String, List<String>> _responseChains = <String, List<String>>{};

  /// 本轮各签名已消费的调用次数（每轮重放前清空）
  final Map<String, int> _passCalls = <String, int>{};

  /// 本轮首个未命中请求（求值因它挂起中断，由 Dart 执行后重放）
  _PendingRequest? _pendingRequest;

  /// 本次 invoke 实际执行过的请求总数（诊断用）
  int _requestCount = 0;

  /// 单次 invoke 内的确定性桥计算记忆（op+参数 → 结果）：
  /// 重放时直接命中，避免每轮重复执行 RSA/AES/哈希等昂贵计算
  final Map<String, String> _computeMemo = <String, String>{};
  int _computeMemoBytes = 0;
  static const int _computeMemoMaxBytes = 32 * 1024 * 1024;

  /// 非确定性桥调用按"本轮第 n 次调用"记忆，保证同一次 invoke 的重放对
  /// 同一调用序返回同值（时间戳/随机数在签名头中漂移会导致重放永不收敛）
  final List<String> _momentChain = <String>[];
  int _passMomentCalls = 0;
  final List<String> _randomChain = <String>[];
  int _passRandomCalls = 0;
  final List<String> _bytesChain = <String>[];
  final List<int> _bytesChainSizes = <int>[];
  int _passBytesCalls = 0;

  /// 消息分发：init/invoke/close 串行入队，cancel 立即处理
  void handleMessage(dynamic message) {
    if (message is! Map) return;
    switch ('${message['t'] ?? ''}') {
      case 'init':
        _enqueue(() => _handleInit(message));
        break;
      case 'initLx':
        _enqueue(() => _handleInitLx(message));
        break;
      case 'invoke':
        _enqueue(() => _handleInvoke(message));
        break;
      case 'invokeLx':
        _enqueue(() => _handleInvokeLx(message));
        break;
      case 'cancel':
        _handleCancel();
        break;
      case 'close':
        _enqueue(_handleClose);
        break;
    }
  }

  void _enqueue(Future<void> Function() task) {
    _queue = _queue.then((_) async {
      try {
        await task();
      } catch (_) {
        // 消息级兜底：单条消息异常不应中断后续消息
      }
    });
  }

  Future<void> _handleInit(Map message) async {
    if (_closed) return;
    _disposeRuntime();
    _ready = false;
    _canceled = false;
    _name = '${message['name'] ?? ''}';
    final source = '${message['source'] ?? ''}';
    try {
      _http = PluginHttpClient(platformName: _name, logger: _logHttp);
      final runtime = QuickJsRuntime2(
        memoryLimit: _runtimeMemoryLimit,
        hostPromiseRejectionHandler: (dynamic reason) {
          _log('error', '未处理的 Promise 拒绝: $reason');
        },
      );
      _runtime = runtime;
      // JS 桥；引擎 console 默认走 print，替换为转发到宿主日志
      runtime.setupBridge('BakaNative', _onBridge);
      JavascriptRuntime.channelFunctionsRegistered[runtime
              .getEngineInstanceId()]?['ConsoleLog'] =
          _onConsoleLog;
      // 引导顺序：
      // 桥前置 → CommonJS 模块工厂 → polyfill 垫片 → 插件源码（去 async/await + 补丁）→ 应用导出
      runtime.evaluate(jsBridgePrelude);
      runtime.evaluate(buildModuleFactoriesSource());
      runtime.evaluate(jsRuntimeBootstrap);
      // 插件源码须按模块脚本求值：
      // 顶层 let/const 进入独立模块作用域，否则会与运行时全局（如 var CryptoJs）
      // 冲突产生 SyntaxError，被静默吞掉后表现为插件导出为空
      final pluginEval = runtime.evaluate(
        stripAsyncAwait(buildWrappedPluginSource(source)),
        name: '$_name.js',
        evalFlags: JSEvalFlag.MODULE,
      );
      if (pluginEval.isError) {
        throw PluginWorkerException(_evalErrorMessage(pluginEval));
      }
      final applyResult = runtime.evaluate('__bakaApplyPlugin();');
      if (applyResult.isError) {
        throw PluginWorkerException(_evalErrorMessage(applyResult));
      }
      final infoEval = runtime.evaluate(jsPluginInfo);
      if (infoEval.isError) {
        throw PluginWorkerException(_evalErrorMessage(infoEval));
      }
      final info = _decodeInfo(infoEval);
      _platform = _nonBlank(info['platform'] as String?, _name);
      final qualities = <String>[];
      final rawQualities = info['qualities'];
      if (rawQualities is List) {
        for (final item in rawQualities) {
          final text = '$item'.trim();
          if (text.isNotEmpty) qualities.add(text);
        }
      }
      _ready = true;
      _send({
        't': 'ready',
        'name': _name,
        'platform': _platform,
        'qualities': qualities,
      });
    } catch (error) {
      _send({'t': 'initError', 'message': _errorText(error)});
      _disposeRuntime();
    }
  }

  Future<void> _handleInitLx(Map message) async {
    if (_closed) return;
    _disposeRuntime();
    _ready = false;
    _canceled = false;
    _name = '${message['name'] ?? ''}';
    final source = '${message['source'] ?? ''}';
    final infoJson = '${message['infoJson'] ?? 'null'}';
    try {
      _http = PluginHttpClient(platformName: _name, logger: _logHttp);
      final runtime = QuickJsRuntime2(
        memoryLimit: _runtimeMemoryLimit,
        hostPromiseRejectionHandler: (dynamic reason) {
          _log('error', '未处理的 Promise 拒绝: $reason');
        },
      );
      _runtime = runtime;
      runtime.setupBridge('BakaNative', _onBridge);
      JavascriptRuntime.channelFunctionsRegistered[runtime
              .getEngineInstanceId()]?['ConsoleLog'] =
          _onConsoleLog;
      // LX 引导顺序：桥前置 → CommonJS 模块工厂 → polyfill 垫片 → LX prelude
      // → 去 async/await 的脚本源码（挂起标记经同步调用栈传播，复用重放机制）
      runtime.evaluate(jsBridgePrelude);
      runtime.evaluate(buildModuleFactoriesSource());
      runtime.evaluate(jsRuntimeBootstrap);
      runtime.evaluate(lxRuntimeSource(infoJson));
      final sourceEval = runtime.evaluate(stripAsyncAwait(source));
      if (sourceEval.isError) {
        throw PluginWorkerException(_evalErrorMessage(sourceEval));
      }
      final handler = runtime.evaluate(
        "String(typeof globalThis.__lxRequestHandler === 'function')",
      );
      if (handler.isError) {
        throw PluginWorkerException(_evalErrorMessage(handler));
      }
      final handlerRaw = handler.rawResult;
      final handlerText = handlerRaw is String
          ? handlerRaw.trim()
          : '${handlerRaw ?? handler.stringResult}'.trim();
      if (handlerText != 'true') {
        throw PluginWorkerException('LX 脚本未注册 request handler');
      }
      final declared = runtime.evaluate(
        "typeof __bakaLxSourcesDeclaredRaw === 'string' "
        "? __bakaLxSourcesDeclaredRaw : 'null'",
      );
      if (declared.isError) {
        throw PluginWorkerException(_evalErrorMessage(declared));
      }
      final raw = declared.rawResult;
      _ready = true;
      _send({
        't': 'lxReady',
        'sourcesJson': raw is String ? raw : declared.stringResult,
      });
    } catch (error) {
      _send({'t': 'initError', 'message': _errorText(error)});
      _disposeRuntime();
    }
  }

  Future<void> _handleInvoke(Map message) async {
    if (_closed) return;
    final id = message['id'];
    if (!_ready || _runtime == null) {
      _send({'t': 'error', 'id': id, 'message': '插件运行时未就绪'});
      return;
    }
    final method = '${message['method'] ?? ''}';
    final argsJson = '${message['argsJson'] ?? '[]'}';
    // argsJson 以 JSON 字符串字面量注入，
    // __bakaInvoke 内部再 JSON.parse，勿直接内联数组表达式
    await _runInvoke(
      id,
      '__bakaInvoke(${jsonEncode(method)}, ${jsonEncode(argsJson)})',
      label: '$method ',
    );
  }

  Future<void> _handleInvokeLx(Map message) async {
    if (_closed) return;
    final id = message['id'];
    if (!_ready || _runtime == null) {
      _send({'t': 'error', 'id': id, 'message': 'LX 运行时未就绪'});
      return;
    }
    final source = '${message['source'] ?? ''}';
    final quality = '${message['quality'] ?? ''}';
    final musicInfoJson = '${message['musicInfoJson'] ?? '{}'}';
    await _runInvoke(
      id,
      '__lxInvoke(${jsonEncode(source)}, ${jsonEncode(quality)}, '
      '${jsonEncode(musicInfoJson)})',
      label: 'lx ',
    );
  }

  /// 挂起-重放执行核心：注入表达式求值，命中挂起则执行真实请求后从头重放
  Future<void> _runInvoke(
    dynamic id,
    String expression, {
    String label = '',
  }) async {
    final runtime = _runtime;
    final http = _http;
    if (runtime == null || http == null) {
      _send({'t': 'error', 'id': id, 'message': '插件运行时未就绪'});
      return;
    }
    _responseChains.clear();
    _passCalls.clear();
    _pendingRequest = null;
    _requestCount = 0;
    _canceled = false;
    _computeMemo.clear();
    _computeMemoBytes = 0;
    _momentChain.clear();
    _passMomentCalls = 0;
    _randomChain.clear();
    _passRandomCalls = 0;
    _bytesChain.clear();
    _bytesChainSizes.clear();
    _passBytesCalls = 0;
    http.beginInvoke();
    try {
      for (var pass = 0; ; pass++) {
        if (pass >= _maxReplayPasses) {
          _log(
            'debug',
            '[replay] $label重放次数超限 passes=$pass 请求=$_requestCount '
                '计算记忆=${_computeMemo.length}',
          );
          _send({'t': 'error', 'id': id, 'message': '插件请求序列不稳定，重放次数超限'});
          return;
        }
        if (_canceled || _closed) {
          _send({'t': 'canceled', 'id': id});
          return;
        }
        _passCalls.clear();
        _passMomentCalls = 0;
        _passRandomCalls = 0;
        _passBytesCalls = 0;
        final eval = runtime.evaluate(expression);
        final pending = _pendingRequest;
        if (pending != null) {
          // 求值因挂起中断：执行真实请求，响应记入其签名响应链后从头重放
          final response = await http.request(pending.configText);
          if (_canceled || _closed) {
            _send({'t': 'canceled', 'id': id});
            return;
          }
          _responseChains
              .putIfAbsent(pending.signature, () => <String>[])
              .add(response);
          _pendingRequest = null;
          continue;
        }
        if (eval.isError) {
          final text = _evalErrorMessage(eval);
          if (text.contains('BakaCanceled')) {
            _send({'t': 'canceled', 'id': id});
          } else {
            _send({'t': 'error', 'id': id, 'message': text});
          }
          return;
        }
        // 诊断：重放轮数异常偏高的调用留下证据，便于定位序列抖动来源
        if (pass >= 16) {
          _log(
            'debug',
            '[replay] $label完成 passes=${pass + 1} 请求=$_requestCount '
                '计算记忆=${_computeMemo.length}',
          );
        }
        final raw = eval.rawResult;
        _send({
          't': 'done',
          'id': id,
          'result': raw is String ? raw : eval.stringResult,
        });
        return;
      }
    } catch (error) {
      if (_canceled || _closed) {
        _send({'t': 'canceled', 'id': id});
      } else {
        _send({'t': 'error', 'id': id, 'message': _errorText(error)});
      }
    }
  }

  void _handleCancel() {
    _canceled = true;
    // 立即强制关闭在途连接，请求结果会被丢弃并返回取消
    _http?.cancelAll();
  }

  Future<void> _handleClose() async {
    if (_closed) return;
    _closed = true;
    _canceled = true;
    _http?.cancelAll();
    _disposeRuntime();
    _send({'t': 'closed'});
    _receivePort.close();
  }

  void _disposeRuntime() {
    final runtime = _runtime;
    _runtime = null;
    _ready = false;
    if (runtime != null) {
      try {
        JavascriptRuntime.channelFunctionsRegistered.remove(
          runtime.getEngineInstanceId(),
        );
      } catch (_) {}
      try {
        runtime.dispose();
      } catch (_) {}
    }
    try {
      _http?.close();
    } catch (_) {}
    _http = null;
  }

  /// JS 桥入口：同步返回字符串标记/结果
  dynamic _onBridge(dynamic message) {
    try {
      if (message is! Map) return '$_errorMarkerPrefix桥接消息无效';
      final op = '${message['op'] ?? ''}';
      final rawArgs = message['args'];
      final args = rawArgs is List ? rawArgs : const <dynamic>[];
      if (op == 'request') {
        return _memoRequest(args.isEmpty ? '' : '${args[0]}');
      }
      // 非确定性桥调用按调用序记忆；其余确定性计算按 (op,参数) 记忆
      if (op == 'timeNow') return _memoTimeNow();
      if (op == 'randomUnit') return _memoRandomUnit();
      if (op == 'randomBytes') {
        final size = int.tryParse(args.isEmpty ? '' : '${args[0]}'.trim()) ?? 0;
        return _memoRandomBytes(size);
      }
      return _memoCompute(op, args);
    } catch (error) {
      return '$_errorMarkerPrefix${_errorText(error)}';
    }
  }

  /// 确定性计算记忆：命中直接返回，未命中执行后入表（超限则退化为直算）
  String _memoCompute(String op, List<dynamic> args) {
    var key = op;
    for (final arg in args) {
      key = '$key\u0000$arg';
      // 参数过大（如整段响应 base64）不入记忆，避免内存与比较开销膨胀
      if (key.length > 131072) return _computeOp(op, args);
    }
    final cached = _computeMemo[key];
    if (cached != null) return cached;
    final value = _computeOp(op, args);
    final cost = key.length + value.length;
    if (_computeMemoBytes + cost <= _computeMemoMaxBytes) {
      _computeMemo[key] = value;
      _computeMemoBytes += cost;
    }
    return value;
  }

  /// Date.now 按本轮第 n 次调用记忆：重放命中同一调用序，返回同值
  String _memoTimeNow() {
    final index = _passMomentCalls++;
    if (index < _momentChain.length) return _momentChain[index];
    final value = '${DateTime.now().millisecondsSinceEpoch}';
    _momentChain.add(value);
    return value;
  }

  /// Math.random 按本轮第 n 次调用记忆：[0,1) 的十进制字符串
  String _memoRandomUnit() {
    final index = _passRandomCalls++;
    if (index < _randomChain.length) return _randomChain[index];
    final bytes = base64Decode(compute.randomBytesBase64(6));
    var value = 0;
    for (final byte in bytes) {
      value = (value << 8) | byte;
    }
    final unit = (value / 0x1000000000000).toStringAsFixed(12);
    _randomChain.add(unit);
    return unit;
  }

  /// 随机字节按本轮第 n 次调用记忆；同序尺寸不一致（序列分叉）时刷新该序号
  String _memoRandomBytes(int size) {
    final index = _passBytesCalls++;
    if (index < _bytesChain.length && _bytesChainSizes[index] == size) {
      return _bytesChain[index];
    }
    final value = compute.randomBytesBase64(size);
    if (index < _bytesChain.length) {
      _bytesChain[index] = value;
      _bytesChainSizes[index] = size;
    } else {
      _bytesChain.add(value);
      _bytesChainSizes.add(size);
    }
    return value;
  }

  /// 同步桥操作分发
  String _computeOp(String op, List<dynamic> args) {
    String text(int index) => index < args.length ? '${args[index]}' : '';
    switch (op) {
      case 'md5':
        return compute.md5Hex(text(0));
      case 'sha1':
        return compute.sha1Hex(text(0));
      case 'sha256':
        return compute.sha256Hex(text(0));
      case 'sha512':
        return compute.sha512Hex(text(0));
      case 'hmacSha256':
        return compute.hmacSha256Hex(text(0), text(1));
      case 'hmacSha1':
        return compute.hmacSha1Hex(text(0), text(1));
      case 'hmacMd5':
        return compute.hmacMd5Hex(text(0), text(1));
      case 'modPowHex':
        return compute.modPowHex(text(0), text(1), text(2));
      case 'textDecode':
        return compute.textDecode(text(0), text(1));
      case 'inflate':
        return compute.inflateBase64(text(0));
      case 'aes':
        return compute.aesEncrypt(text(0), text(1), text(2), text(3));
      case 'aesDecrypt':
        return compute.aesDecrypt(text(0), text(1), text(2), text(3));
      case 'aesBytes':
        return compute.aesEncryptBytes(text(0), text(1), text(2), text(3));
      case 'rsaEncrypt':
        return compute.rsaEncryptBase64(text(0), text(1));
      case 'deflate':
        return compute.deflateBase64(text(0));
      default:
        throw PluginWorkerException('未知插件桥操作: $op');
    }
  }

  /// 挂起-重放核心：本轮同一签名第 n 次调用命中其响应链第 n 条响应；
  /// 链上无此响应时登记待执行并挂起（同一轮内至多登记一个）
  String _memoRequest(String configText) {
    if (_closed || _canceled) return _canceledMarker;
    if (_pendingRequest != null) return _suspendMarker;
    final signature = _requestSignature(configText);
    final index = _passCalls[signature] ?? 0;
    _passCalls[signature] = index + 1;
    final chain = _responseChains[signature];
    if (chain != null && index < chain.length) {
      return chain[index];
    }
    _pendingRequest = _PendingRequest(signature, configText);
    _requestCount++;
    return _suspendMarker;
  }

  /// 请求签名：method + scheme://host:port/path（忽略 query/params，
  /// 避免插件使用时间戳参数时重放永远失配）
  String _requestSignature(String configText) {
    try {
      final decoded = jsonDecode(configText);
      if (decoded is Map) {
        final method = '${decoded['method'] ?? 'GET'}'.toUpperCase();
        final url = '${decoded['url'] ?? ''}';
        final uri = Uri.tryParse(url);
        if (uri != null && uri.host.isNotEmpty) {
          return '$method\u0000${uri.scheme}://${uri.host}:${uri.port}${uri.path}';
        }
        return '$method\u0000$url';
      }
    } catch (_) {}
    return configText;
  }

  dynamic _onConsoleLog(dynamic args) {
    try {
      if (args is List && args.isNotEmpty) {
        final level = '${args[0]}';
        final parts = <String>[];
        for (var index = 1; index < args.length; index++) {
          parts.add(_formatConsoleArg(args[index]));
        }
        _log(level, parts.join(' '));
      }
    } catch (_) {}
    return null;
  }

  String _formatConsoleArg(dynamic value) {
    if (value == null) return 'null';
    if (value is String) return value;
    if (value is num || value is bool) return '$value';
    if (value is List || value is Map) {
      try {
        return jsonEncode(value);
      } catch (_) {
        return '$value';
      }
    }
    return '$value';
  }

  Map<String, dynamic> _decodeInfo(JsEvalResult eval) {
    final raw = eval.rawResult;
    final text = raw is String ? raw : eval.stringResult;
    final decoded = jsonDecode(text);
    if (decoded is! Map) {
      throw PluginWorkerException('插件信息格式无效');
    }
    return Map<String, dynamic>.from(decoded);
  }

  String _evalErrorMessage(JsEvalResult eval) {
    final raw = eval.rawResult;
    if (raw is JSError) return raw.message;
    return eval.stringResult;
  }

  String _nonBlank(String? value, String fallback) {
    final trimmed = value?.trim() ?? '';
    return trimmed.isEmpty ? fallback : trimmed;
  }

  String _errorText(Object? error) => '${error ?? '未知错误'}';

  void _log(String level, String message) {
    _send({'t': 'log', 'level': level, 'message': message});
  }

  void _logHttp(String message) {
    _log('debug', message);
  }

  void _send(Map<String, dynamic> message) {
    if (_closed && message['t'] != 'closed') return;
    _ownerPort.send(message);
  }
}
