/// LX 取流脚本宿主：
/// 每个脚本一个独立 QuickJS worker isolate，负责加载握手、取流调用与可用性探针
library;

import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';

import '../data/lx_models.dart';
import '../models/media_models.dart';
import 'js_worker.dart';
import 'plugin_http_client.dart' show isPluginPrivateHost;

/// LX 探针类错误：与普通失败区分，仅此类错误值得同档重试
class LxProbeException implements Exception {
  LxProbeException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// LX 宿主校验错误（脚本未加载、音质不支持、地址非法等）
class LxHostException implements Exception {
  LxHostException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// LX 脚本宿主
class LxPluginHost {
  final Map<String, _HostedScript> _hosted = {};
  final Set<HttpClient> _openClients = {};

  static const int _maxUrlLength = 8192;
  static const int _maxRedirects = 5;
  static const Duration _loadTimeout = Duration(seconds: 15);
  static const Duration _invokeTimeout = Duration(seconds: 20);
  static const Duration _probeTimeout = Duration(seconds: 8);
  static const String mediaUserAgent =
      'Mozilla/5.0 BakaMusic LX Compatibility/2.0';
  static const Map<String, String> mediaHeaders = {
    HttpHeaders.userAgentHeader: mediaUserAgent,
  };

  /// 载入脚本并执行 lx.send('inited') 握手，返回声明的 sources
  Future<Map<String, LxSourceDescriptor>> loadPlugin(
    String hash,
    String code,
    LxScriptInfo info,
  ) async {
    await unload(hash);
    final worker = await PluginWorker.spawn();
    worker.onLog = (level, message) {
      developer.log(
        '[LX:${info.name}] $message',
        name: 'BakaLx',
        level: _logLevelOf(level),
      );
    };
    // 脚本信息含原始源码
    final infoJson = jsonEncode({...info.toJson(), 'rawScript': code});
    String sourcesJson;
    try {
      sourcesJson = await worker.loadLx(
        hash,
        code,
        infoJson,
        timeout: _loadTimeout,
      );
    } catch (_) {
      worker.kill();
      rethrow;
    }
    dynamic declared;
    try {
      declared = jsonDecode(sourcesJson);
    } catch (_) {
      declared = null;
    }
    final sources = parseLxSourcesDeclared(
      declared is Map ? Map<String, dynamic>.from(declared) : null,
    );
    if (sources.isEmpty) {
      worker.kill();
      throw LxHostException('LX 脚本未声明可用 source');
    }
    _hosted[hash] = _HostedScript(worker, info, sources);
    developer.log(
      '[LX] 载入 ${info.name} sources=${sources.keys.toList()}',
      name: 'BakaLx',
      level: 500,
    );
    return sources;
  }

  /// 调用脚本 request handler 取流，返回经探针校验的播放地址
  Future<String> invoke(
    String hash,
    String source,
    String quality,
    String musicInfoJson,
  ) async {
    final hosted = _hosted[hash];
    if (hosted == null) throw LxHostException('LX 脚本未加载');
    if (!(hosted.sources[source]?.qualities.contains(quality) ?? false)) {
      throw LxHostException('LX 不支持该音质: $quality');
    }
    final String result;
    try {
      result = await hosted.worker.invokeLx(
        source,
        quality,
        musicInfoJson,
        timeout: _invokeTimeout,
      );
    } on PluginWorkerTimeoutException {
      // 超时终止在途调用，仅该脚本 worker 受影响
      hosted.worker.cancel();
      throw MediaResolveTimeoutException('LX 解析超时: $source $quality');
    } on PluginCanceledException {
      hosted.worker.cancel();
      rethrow;
    }
    var url = '';
    try {
      final dynamic decoded = jsonDecode(result);
      if (decoded is Map) url = '${decoded['url'] ?? ''}'.trim();
    } catch (_) {}
    if (url.isEmpty || url.length > _maxUrlLength) {
      throw LxHostException('LX 脚本返回了无效的播放地址');
    }
    await _probe(url);
    return url;
  }

  /// 卸载单个脚本并释放其运行时
  Future<void> unload(String hash) async {
    final item = _hosted.remove(hash);
    if (item == null) return;
    try {
      await item.worker.close();
    } catch (_) {}
  }

  /// 卸载全部脚本
  Future<void> clear() async {
    final items = _hosted.values.toList();
    _hosted.clear();
    for (final item in items) {
      try {
        await item.worker.close();
      } catch (_) {}
    }
  }

  /// 中止所有在途调用与探针连接（保留已加载脚本）
  void cancelPending() {
    for (final item in _hosted.values) {
      item.worker.cancel();
    }
    for (final client in _openClients.toList()) {
      try {
        client.close(force: true);
      } catch (_) {}
    }
    _openClients.clear();
  }

  /// 释放全部资源
  Future<void> destroy() async {
    cancelPending();
    await clear();
  }

  /// 取流探针：Range 首字节，200/206 才算可用
  Future<void> _probe(String url) async {
    final scheme = url.toLowerCase();
    if (!scheme.startsWith('http://') && !scheme.startsWith('https://')) {
      throw LxHostException('LX 播放地址无效');
    }
    var current = url;
    var redirects = 0;
    while (true) {
      final uri = Uri.tryParse(current);
      var host = uri?.host ?? '';
      if (uri == null || host.isEmpty) throw LxHostException('LX 播放地址无效');
      host = host.toLowerCase();
      if (await isPluginPrivateHost(host)) {
        throw LxHostException('LX 不能访问本机或内网地址');
      }
      final client = HttpClient()..connectionTimeout = _probeTimeout;
      _openClients.add(client);
      try {
        final request = await client.getUrl(uri);
        request.followRedirects = false;
        request.headers.set(HttpHeaders.userAgentHeader, mediaUserAgent);
        request.headers.set('Range', 'bytes=0-1');
        final response = await request.close().timeout(_probeTimeout);
        final code = response.statusCode;
        if (code >= 300 && code <= 399 && redirects < _maxRedirects) {
          final location =
              response.headers.value(HttpHeaders.locationHeader)?.trim() ?? '';
          if (location.isNotEmpty) {
            String resolved;
            try {
              resolved = uri.resolve(location).toString();
            } catch (_) {
              resolved = location;
            }
            final target = resolved.toLowerCase();
            if (!target.startsWith('http://') &&
                !target.startsWith('https://')) {
              throw LxHostException('LX 重定向地址无效');
            }
            current = resolved;
            redirects++;
            continue;
          }
        }
        if (code != 200 && code != 206) {
          throw LxProbeException('LX media URL probe failed with HTTP $code');
        }
        return;
      } finally {
        _openClients.remove(client);
        client.close(force: true);
      }
    }
  }
}

class _HostedScript {
  _HostedScript(this.worker, this.info, this.sources);

  final PluginWorker worker;
  final LxScriptInfo info;
  final Map<String, LxSourceDescriptor> sources;
}

int _logLevelOf(String level) {
  switch (level) {
    case 'fatal':
      return 1200;
    case 'error':
      return 1000;
    case 'warn':
      return 900;
    case 'debug':
      return 500;
    default:
      return 800;
  }
}
