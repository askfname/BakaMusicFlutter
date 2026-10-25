/// 插件 HTTP 通道
/// 运行在 worker isolate 内：手动重定向、gzip/deflate 解压、
/// 私有网拦截、16MiB 上限、首试失败后用 Connection:close 重试一次
/// request() 恒不抛异常：成功 `{status,headers,data}`，失败 `{__error}`
library;

import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';
import 'dart:typed_data';

import 'js_compute.dart' show decodeBase64Lenient;

/// 插件未指定 UA 时的默认值
const String defaultPluginUserAgent =
    'Mozilla/5.0 (Linux; Android 14; Mobile) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Mobile Safari/537.36 BakaMusic/1.0';

/// 响应体上限（按解压后的字节计）
const int maxPluginResponseBytes = 16 * 1024 * 1024;

const Set<int> _redirectCodes = {301, 302, 303, 307, 308};

const Duration _drainTimeout = Duration(seconds: 5);

class _BakaHttpError implements Exception {
  _BakaHttpError(this.message);

  final String message;

  @override
  String toString() => message;
}

void _defaultLog(String message) {
  developer.log(message, name: 'BakaPlugin');
}

/// 主机名是否本机/内网（解析失败视为私网）
Future<bool> isPluginPrivateHost(String host) async {
  if (host == 'localhost' || host == '0.0.0.0' || host.endsWith('.localhost')) {
    return true;
  }
  try {
    final addresses = await InternetAddress.lookup(host);
    return addresses.any(_isPrivateAddress);
  } catch (_) {
    return true;
  }
}

bool _isPrivateAddress(InternetAddress address) {
  final bytes = address.rawAddress;
  if (bytes.length == 4) {
    final b0 = bytes[0];
    final b1 = bytes[1];
    if (b0 == 0 && b1 == 0 && bytes[2] == 0 && bytes[3] == 0) return true;
    if (b0 == 127) return true;
    if (b0 == 169 && b1 == 254) return true;
    if (b0 == 10) return true;
    if (b0 == 172 && b1 >= 16 && b1 <= 31) return true;
    if (b0 == 192 && b1 == 168) return true;
    return false;
  }
  if (bytes.length == 16) {
    if (bytes.every((byte) => byte == 0)) return true;
    if (bytes[15] == 1 && bytes.take(15).every((byte) => byte == 0)) {
      return true;
    }
    if (bytes[0] == 0xFE && (bytes[1] & 0xC0) == 0x80) return true;
    if (bytes[0] == 0xFE && (bytes[1] & 0xC0) == 0xC0) return true;
    if ((bytes[0] & 0xFE) == 0xFC) return true;
    if (bytes[10] == 0xFF &&
        bytes[11] == 0xFF &&
        bytes.take(10).every((byte) => byte == 0)) {
      final b0 = bytes[12];
      final b1 = bytes[13];
      if (b0 == 0 && b1 == 0 && bytes[14] == 0 && bytes[15] == 0) return true;
      if (b0 == 127 || b0 == 10) return true;
      if (b0 == 169 && b1 == 254) return true;
      if (b0 == 172 && b1 >= 16 && b1 <= 31) return true;
      if (b0 == 192 && b1 == 168) return true;
    }
    return false;
  }
  return true;
}

class PluginHttpClient {
  PluginHttpClient({required this.platformName, void Function(String)? logger})
      : _log = logger ?? _defaultLog;

  final String platformName;
  final void Function(String message) _log;

  HttpClient? _client;
  bool _canceled = false;

  /// 每次 invoke 开始时清除取消标记
  void beginInvoke() {
    _canceled = false;
  }

  /// 切歌/取消时强制断开全部在途连接
  void cancelAll() {
    _canceled = true;
    _closeClient();
  }

  void close() {
    _canceled = true;
    _closeClient();
  }

  void _closeClient() {
    final client = _client;
    _client = null;
    if (client != null) {
      try {
        client.close(force: true);
      } catch (_) {}
    }
  }

  HttpClient _ensureClient() {
    final existing = _client;
    if (existing != null) return existing;
    final client = HttpClient()..autoUncompress = false;
    return _client = client;
  }

  /// 执行一次插件 HTTP 请求（configText 为 JS 侧 JSON.stringify 的配置）
  Future<String> request(String configText) async {
    try {
      return await _executeWithRetry(configText);
    } catch (error) {
      final message = _errorMessage(error);
      return jsonEncode({'__error': message.isEmpty ? 'network error' : message});
    }
  }

  /// lrc 为 URL 时抓取纯文本歌词（5s 超时、2MiB 上限、逐跳校验私网），失败返回 null
  Future<String?> fetchText(String url) async {
    const timeout = Duration(seconds: 5);
    try {
      var currentUrl = url;
      var redirectCount = 0;
      final client = _ensureClient();
      client.connectionTimeout = timeout;
      while (true) {
        if (!_isHttpUrl(currentUrl)) return null;
        final host = _hostOf(currentUrl);
        if (host == null || await isPluginPrivateHost(host)) return null;
        final uri = Uri.tryParse(currentUrl);
        if (uri == null) return null;
        final request = await client.getUrl(uri);
        request.followRedirects = false;
        HttpClientResponse response;
        try {
          response = await request.close().timeout(timeout);
        } on TimeoutException {
          request.abort();
          rethrow;
        }
        final code = response.statusCode;
        if (_redirectCodes.contains(code) && redirectCount < 20) {
          final values = response.headers['location'];
          final location =
              values == null || values.isEmpty ? '' : values.first.trim();
          if (location.isNotEmpty) {
            final nextUrl = _resolveLocation(currentUrl, location);
            try {
              await response.drain<void>().timeout(_drainTimeout);
            } catch (_) {}
            currentUrl = nextUrl;
            redirectCount++;
            continue;
          }
        }
        final bytes = await _readLimited(response, 2 * 1024 * 1024, timeout);
        return utf8.decode(bytes, allowMalformed: true);
      }
    } catch (_) {
      return null;
    }
  }

  Future<String> _executeWithRetry(String configText) async {
    final decoded = jsonDecode(configText);
    if (decoded is! Map) {
      throw _BakaHttpError('请求配置无效');
    }
    var url = _encodeUrlInline('${decoded['url'] ?? ''}');
    final params = decoded['params'];
    if (params is Map) {
      final pairs = <String>[];
      void append(dynamic key, dynamic value) {
        if (value == null) return;
        final text = value is Map || value is List ? jsonEncode(value) : '$value';
        pairs.add('${Uri.encodeQueryComponent('$key')}='
            '${Uri.encodeQueryComponent(text)}');
      }

      params.forEach((key, value) {
        if (value is List) {
          for (final item in value) {
            append(key, item);
          }
        } else {
          append(key, value);
        }
      });
      if (pairs.isNotEmpty) {
        url += url.contains('?') ? '&${pairs.join('&')}' : '?${pairs.join('&')}';
      }
    }
    if (!_isHttpUrl(url)) {
      throw _BakaHttpError('插件网络请求必须使用 HTTP(S)');
    }
    final host = _hostOf(url);
    if (host == null) throw _BakaHttpError('插件请求地址无效');
    if (await isPluginPrivateHost(host)) {
      throw _BakaHttpError('插件不能访问本机或内网地址');
    }
    final method = '${decoded['method'] ?? 'GET'}'.toUpperCase();
    final responseType = '${decoded['responseType'] ?? ''}'.toLowerCase();
    final isBinary = responseType == 'arraybuffer' || responseType == 'blob';
    // JS 指定的超时钳制在 3s~60s；整体仍受上层解析预算约束
    final timeoutMs = _readInt(decoded['timeout'], 15000).clamp(3000, 60000);
    final maxRedirects = decoded.containsKey('maxRedirects')
        ? _readInt(decoded['maxRedirects'], 5).clamp(0, 20)
        : 5;
    final headers = <String, String>{};
    var contentType = '';
    final rawHeaders = decoded['headers'];
    if (rawHeaders is Map) {
      rawHeaders.forEach((key, value) {
        final name = '$key';
        final text = value == null ? '' : '$value';
        headers[name] = text;
        if (name.toLowerCase() == 'content-type') contentType = text;
      });
    }
    final data = decoded['data'];
    final hasBody = data != null && method != 'GET' && method != 'HEAD';
    // body 预先算好，重试时复用同一字节（签名已绑定 body，重试不得改变内容）
    var bodyKind = 'none';
    Uint8List? bodyBytes;
    if (hasBody) {
      if (data is Map && data.containsKey('__bytes_base64')) {
        bodyKind = 'bytes';
        bodyBytes =
            Uint8List.fromList(decodeBase64Lenient('${data['__bytes_base64']}'));
      } else if (data is Map && _isUint8ArrayJson(data)) {
        bodyKind = 'bytes';
        bodyBytes = _uint8ArrayJsonToBytes(data);
      } else if (data is Map &&
          contentType.toLowerCase().contains('x-www-form-urlencoded')) {
        bodyKind = 'form';
        bodyBytes = Uint8List.fromList(utf8.encode(_formEncode(data)));
      } else if (data is Map) {
        bodyKind = 'json';
        bodyBytes = Uint8List.fromList(utf8.encode(jsonEncode(data)));
      } else {
        bodyKind = 'raw';
        final text = data is String ? data : jsonEncode(data);
        bodyBytes = Uint8List.fromList(utf8.encode(text));
      }
    }
    final hostPath = host + (_pathOf(url) ?? '');
    Object? lastError;
    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        return await _exchangeOnce(
          url: url,
          hostPath: hostPath,
          method: method,
          headers: headers,
          contentType: contentType,
          bodyBytes: bodyBytes,
          bodyKind: bodyKind,
          hasBody: hasBody,
          isBinary: isBinary,
          timeoutMs: timeoutMs,
          maxRedirects: maxRedirects,
          closeConnection: attempt == 1,
        );
      } catch (error) {
        if (_isIntentionalCancel(error)) rethrow;
        if (attempt == 1 || !_isRetryableNetworkError(error)) rethrow;
        lastError = error;
        _log('[$platformName][http] $method $hostPath 失败重试: '
            '${_errorMessage(error)}');
      }
    }
    throw lastError ?? _BakaHttpError('network error');
  }

  Future<String> _exchangeOnce({
    required String url,
    required String hostPath,
    required String method,
    required Map<String, String> headers,
    required String contentType,
    required Uint8List? bodyBytes,
    required String bodyKind,
    required bool hasBody,
    required bool isBinary,
    required int timeoutMs,
    required int maxRedirects,
    required bool closeConnection,
  }) async {
    // 手动跟随重定向
    var currentUrl = url;
    var currentMethod = method;
    Uint8List? currentBody = bodyBytes;
    var currentHasBody = hasBody;
    var redirectCount = 0;
    final start = DateTime.now().millisecondsSinceEpoch;
    final timeout = Duration(milliseconds: timeoutMs);
    final client = _ensureClient();
    client.connectionTimeout = timeout;
    while (true) {
      final uri = Uri.tryParse(currentUrl);
      if (uri == null) throw _BakaHttpError('插件请求地址无效');
      final request = await client.openUrl(currentMethod, uri);
      request
        ..followRedirects = false
        ..persistentConnection = true;
      var hasConnectionHeader = false;
      var hasUserAgent = false;
      var hasAccept = false;
      var hasAcceptEncoding = false;
      var connectionValue = '';
      headers.forEach((name, value) {
        final lower = name.toLowerCase();
        if (lower == 'connection') {
          hasConnectionHeader = true;
          connectionValue = value.toLowerCase();
        } else if (lower == 'user-agent') {
          hasUserAgent = true;
        } else if (lower == 'accept') {
          hasAccept = true;
        } else if (lower == 'accept-encoding') {
          hasAcceptEncoding = true;
        }
        _setHeader(request, name, value);
      });
      // 插件未指定时补默认请求头（部分网关拒绝无 UA 请求）
      if (!hasUserAgent) _setHeader(request, 'User-Agent', defaultPluginUserAgent);
      if (!hasAccept) {
        _setHeader(request, 'Accept', 'application/json, text/plain, */*');
      }
      if (!hasAcceptEncoding) {
        _setHeader(request, 'Accept-Encoding', 'gzip, deflate');
      }
      // 重试时禁用 keep-alive 复用，强制走新连接
      if (closeConnection && !hasConnectionHeader) {
        request.persistentConnection = false;
      } else if (hasConnectionHeader && connectionValue.contains('close')) {
        request.persistentConnection = false;
      }
      if (currentHasBody && currentBody != null) {
        if (contentType.trim().isEmpty) {
          _setHeader(request, 'Content-Type', 'application/json;charset=UTF-8');
        }
        request.add(currentBody);
      }
      HttpClientResponse response;
      try {
        response = await request.close().timeout(timeout);
      } on TimeoutException {
        request.abort();
        throw TimeoutException('read timeout');
      }
      final code = response.statusCode;
      if (_redirectCodes.contains(code) && redirectCount < maxRedirects) {
        // Location 匹配大小写不敏感
        final values = response.headers['location'];
        final location =
            values == null || values.isEmpty ? '' : values.first.trim();
        if (location.isNotEmpty) {
          final nextUrl = _resolveLocation(currentUrl, location);
          final nextHost = _hostOf(nextUrl);
          if (nextHost == null) throw _BakaHttpError('插件重定向地址无效');
          if (await isPluginPrivateHost(nextHost)) {
            throw _BakaHttpError('插件不能重定向到本机或内网地址');
          }
          // 301/302/303 的 POST 转 GET；307/308 保持不变
          if (code == 303 ||
              ((code == 301 || code == 302) && currentMethod == 'POST')) {
            currentMethod = 'GET';
            currentBody = null;
            currentHasBody = false;
          }
          try {
            await response.drain<void>().timeout(_drainTimeout);
          } catch (_) {}
          currentUrl = nextUrl;
          redirectCount++;
          continue;
        }
      }
      final finalHost = _hostOf(currentUrl);
      if (finalHost == null) throw _BakaHttpError('插件重定向地址无效');
      if (await isPluginPrivateHost(finalHost)) {
        throw _BakaHttpError('插件不能重定向到本机或内网地址');
      }
      if (response.contentLength > maxPluginResponseBytes) {
        throw _BakaHttpError('响应超过 16 MiB 限制');
      }
      final encoding =
          (response.headers['content-encoding']?.join(',') ?? '').toLowerCase();
      Stream<List<int>> stream = response;
      if (encoding.contains('gzip')) {
        stream = gzip.decoder.bind(response);
      } else if (encoding.contains('deflate')) {
        stream = ZLibDecoder().bind(response);
      }
      final bytes = await _readLimited(stream, maxPluginResponseBytes, timeout);
      final bodyText = utf8.decode(bytes, allowMalformed: true);
      dynamic dataValue;
      if (isBinary) {
        dataValue = {'__base64': base64.encode(bytes)};
      } else {
        final trimmed = bodyText.trim();
        if (trimmed.startsWith('{') || trimmed.startsWith('[')) {
          try {
            dataValue = jsonDecode(bodyText);
          } catch (_) {
            dataValue = bodyText;
          }
        } else {
          dataValue = bodyText;
        }
      }
      final responseHeaders = <String, String>{};
      response.headers.forEach((name, values) {
        if (name.trim().isEmpty || values.isEmpty) return;
        responseHeaders[_canonicalHeader(name)] = values.join(',');
      });
      final elapsed = DateTime.now().millisecondsSinceEpoch - start;
      if (method == 'POST' || elapsed > 2000 || redirectCount > 0) {
        _log('[$platformName][http] $method $hostPath code=$code ${elapsed}ms '
            'req=${bodyBytes?.length ?? 0}B($bodyKind) '
            'resp=${bytes.length}B redirects=$redirectCount');
      }
      return jsonEncode({
        'status': code,
        'headers': responseHeaders,
        'data': dataValue,
      });
    }
  }

  /// 读取受限流并在两次数据间启用读超时看门狗
  Future<Uint8List> _readLimited(
    Stream<List<int>> stream,
    int limit,
    Duration timeout,
  ) {
    final completer = Completer<Uint8List>();
    final builder = BytesBuilder(copy: false);
    var total = 0;
    StreamSubscription<List<int>>? subscription;
    Timer? watchdog;
    void fail(Object error) {
      watchdog?.cancel();
      final sub = subscription;
      subscription = null;
      if (sub != null) sub.cancel();
      if (!completer.isCompleted) completer.completeError(error);
    }

    void armWatchdog() {
      watchdog?.cancel();
      watchdog = Timer(timeout, () => fail(TimeoutException('read timeout')));
    }

    subscription = stream.listen(
      (chunk) {
        total += chunk.length;
        if (total > limit) {
          fail(_BakaHttpError('响应超过限制'));
          return;
        }
        builder.add(chunk);
        armWatchdog();
      },
      onError: (Object error, StackTrace stackTrace) => fail(error),
      onDone: () {
        watchdog?.cancel();
        if (!completer.isCompleted) completer.complete(builder.takeBytes());
      },
      cancelOnError: true,
    );
    armWatchdog();
    return completer.future;
  }

  void _setHeader(HttpClientRequest request, String name, String value) {
    try {
      request.headers.set(name, value);
    } catch (_) {}
  }

  bool _isIntentionalCancel(Object error) {
    if (_canceled) return true;
    final message = _errorMessage(error).toLowerCase();
    return message.contains('socket closed') ||
        message.contains('thread interrupted') ||
        message.contains('canceled') ||
        message.contains('cancelled');
  }

  /// 仅传输层偶发错误重试一次；HTTP 状态码错误由 JS 层按插件逻辑处理
  bool _isRetryableNetworkError(Object error) {
    if (error is TimeoutException) return true;
    final message = _errorMessage(error).toLowerCase();
    return message.contains('unexpected end of stream') ||
        message.contains('connection reset') ||
        message.contains('econnreset') ||
        message.contains('epipe') ||
        message.contains('broken pipe') ||
        message.contains('connection refused') ||
        message.contains('refused') ||
        message.contains('forcibly closed') ||
        message.contains('timed out') ||
        message.contains('timeout') ||
        message.contains('connection closed');
  }

  String _errorMessage(Object error) {
    if (error is _BakaHttpError) return error.message;
    if (error is TimeoutException) return error.message ?? 'timeout';
    if (error is SocketException) return error.osError?.message ?? error.message;
    if (error is HttpException) return error.message;
    if (error is FormatException) return error.message;
    return error.toString();
  }
}

String _resolveLocation(String currentUrl, String location) {
  try {
    return Uri.parse(currentUrl).resolve(_encodeUrlInline(location)).toString();
  } catch (_) {
    return location;
  }
}

const Set<int> _inlineSpecialUnits = {
  0x3C, // <
  0x3E, // >
  0x22, // "
  0x7B, // {
  0x7D, // }
  0x7C, // |
  0x5C, // \
  0x5E, // ^
  0x60, // `
};

/// URL 仅编码非法字符，保留已有百分号编码
String _encodeUrlInline(String raw) {
  final out = StringBuffer();
  for (final unit in raw.trim().codeUnits) {
    if (unit == 0x20) {
      out.write('%20');
    } else if (unit > 127 || _inlineSpecialUnits.contains(unit)) {
      for (final byte in utf8.encode(String.fromCharCode(unit))) {
        out.write('%');
        out.write(byte.toRadixString(16).toUpperCase().padLeft(2, '0'));
      }
    } else {
      out.writeCharCode(unit);
    }
  }
  return out.toString();
}

String _formEncode(Map<dynamic, dynamic> obj) {
  return obj.entries.map((entry) {
    final raw = entry.value;
    final text =
        raw == null ? '' : (raw is Map || raw is List ? jsonEncode(raw) : '$raw');
    return '${Uri.encodeQueryComponent('${entry.key}')}='
        '${Uri.encodeQueryComponent(text)}';
  }).join('&');
}

/// JSON.stringify(Uint8Array) 会变成 {"0":..,"1":..} 的纯数字键对象
bool _isUint8ArrayJson(Map<dynamic, dynamic> obj) {
  if (obj.isEmpty || obj.length > 8 * 1024 * 1024) return false;
  for (final key in obj.keys) {
    final text = '$key';
    if (text.isEmpty) return false;
    for (final unit in text.codeUnits) {
      if (unit < 0x30 || unit > 0x39) return false;
    }
  }
  return true;
}

/// 数字键对象按索引排序还原为原始字节（越界值按低 8 位截断）
Uint8List _uint8ArrayJsonToBytes(Map<dynamic, dynamic> obj) {
  final indices = <int>[];
  for (final key in obj.keys) {
    final index = int.tryParse('$key');
    if (index != null) indices.add(index);
  }
  indices.sort();
  final out = Uint8List(indices.length);
  for (var i = 0; i < indices.length; i++) {
    out[i] = _readInt(obj['${indices[i]}'], 0) & 0xFF;
  }
  return out;
}

int _readInt(dynamic value, int fallback) {
  if (value is int) return value;
  if (value is double) return value.toInt();
  if (value is String) {
    final parsed = double.tryParse(value.trim());
    if (parsed != null) return parsed.toInt();
  }
  return fallback;
}

bool _isHttpUrl(String url) {
  final lower = url.toLowerCase();
  return lower.startsWith('http://') || lower.startsWith('https://');
}

String? _hostOf(String url) {
  try {
    final host = Uri.parse(url).host.toLowerCase();
    return host.isEmpty ? null : host;
  } catch (_) {
    return null;
  }
}

String? _pathOf(String url) {
  try {
    return Uri.parse(url).path;
  } catch (_) {
    return null;
  }
}

/// 头名（每段首字母大写、其余小写）
String _canonicalHeader(String name) {
  return name.split('-').map((part) {
    if (part.isEmpty) return part;
    return '${part[0].toUpperCase()}${part.substring(1).toLowerCase()}';
  }).join('-');
}
