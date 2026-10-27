import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

/// 下载地址返回非音频内容
class MediaUrlInvalidException implements Exception {
  const MediaUrlInvalidException(this.message);

  final String message;

  @override
  String toString() => message;
}

const int _maxRedirects = 5;

/// 预读下载地址首段内容，拦截 JSON、HTML 等伪音频响应
Future<void> validateMediaUrl(
  String url,
  Map<String, String> headers, {
  Duration timeout = const Duration(seconds: 10),
}) async {
  final parsed = Uri.tryParse(url);
  if (parsed == null || !_isHttp(parsed)) {
    throw const MediaUrlInvalidException('下载地址无效');
  }
  var current = parsed;
  var redirects = 0;
  while (true) {
    var probe = await _probe(
      current,
      headers,
      withRange: true,
      timeout: timeout,
    );
    if (probe.redirect != null) {
      if (++redirects > _maxRedirects) {
        throw const MediaUrlInvalidException('下载地址重定向过多');
      }
      current = probe.redirect!;
      continue;
    }
    try {
      _ensureAudio(probe);
      return;
    } on MediaUrlInvalidException {
      // 兼容拒绝 Range 的服务器：按实际下载的请求方式再探测一次
      probe = await _probe(
        current,
        headers,
        withRange: false,
        timeout: timeout,
      );
      if (probe.redirect != null) {
        if (++redirects > _maxRedirects) {
          throw const MediaUrlInvalidException('下载地址重定向过多');
        }
        current = probe.redirect!;
        continue;
      }
      _ensureAudio(probe);
      return;
    }
  }
}

Future<_UrlProbe> _probe(
  Uri uri,
  Map<String, String> headers, {
  required bool withRange,
  required Duration timeout,
}) async {
  final client = HttpClient()..connectionTimeout = timeout;
  try {
    final request = await client.getUrl(uri);
    request.followRedirects = false;
    _applyHeaders(request, headers, withRange: withRange);
    final response = await request.close().timeout(timeout);
    final code = response.statusCode;
    final location = response.headers.value(HttpHeaders.locationHeader)?.trim();
    if (code >= 300 && code <= 399 && location != null && location.isNotEmpty) {
      final next = uri.resolve(location);
      if (!_isHttp(next)) {
        throw const MediaUrlInvalidException('下载重定向地址无效');
      }
      return _UrlProbe(statusCode: code, redirect: next);
    }
    final mime = response.headers.contentType?.mimeType.toLowerCase() ?? '';
    if (code != 200 && code != 206) {
      return _UrlProbe(statusCode: code, mime: mime);
    }
    final bytes = await _readPrefix(response, 2048).timeout(timeout);
    return _UrlProbe(statusCode: code, mime: mime, bytes: bytes);
  } on MediaUrlInvalidException {
    rethrow;
  } on TimeoutException {
    throw const MediaUrlInvalidException('下载地址响应超时');
  } catch (error) {
    throw MediaUrlInvalidException('下载地址校验失败: $error');
  } finally {
    client.close(force: true);
  }
}

void _ensureAudio(_UrlProbe probe) {
  if (probe.statusCode != 200 && probe.statusCode != 206) {
    throw MediaUrlInvalidException('下载地址返回 HTTP ${probe.statusCode}');
  }
  if (_isErrorMime(probe.mime)) {
    throw const MediaUrlInvalidException('下载地址返回了非音频内容');
  }
  final bytes = probe.bytes;
  if (bytes == null ||
      bytes.isEmpty ||
      _looksLikeError(bytes) ||
      (!_hasAudioMagic(bytes) && _isTextual(bytes))) {
    throw const MediaUrlInvalidException('下载地址返回了非音频内容');
  }
}

class _UrlProbe {
  const _UrlProbe({
    required this.statusCode,
    this.mime = '',
    this.bytes,
    this.redirect,
  });

  final int statusCode;
  final String mime;
  final Uint8List? bytes;
  final Uri? redirect;
}

bool _isHttp(Uri uri) =>
    (uri.scheme == 'http' || uri.scheme == 'https') && uri.host.isNotEmpty;

void _applyHeaders(
  HttpClientRequest request,
  Map<String, String> headers, {
  required bool withRange,
}) {
  const skipped = {
    'range',
    'host',
    'content-length',
    'connection',
    'transfer-encoding',
    'accept-encoding',
  };
  headers.forEach((key, value) {
    if (value.isEmpty || skipped.contains(key.toLowerCase())) return;
    try {
      request.headers.set(key, value);
    } catch (_) {}
  });
  request.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
  if (withRange) {
    request.headers.set(HttpHeaders.rangeHeader, 'bytes=0-2047');
  }
}

Future<Uint8List> _readPrefix(HttpClientResponse response, int limit) async {
  final builder = BytesBuilder(copy: false);
  await for (final chunk in response) {
    builder.add(chunk);
    if (builder.length >= limit) break;
  }
  final bytes = builder.takeBytes();
  return bytes.length <= limit ? bytes : Uint8List.sublistView(bytes, 0, limit);
}

bool _isErrorMime(String mime) =>
    mime.contains('json') ||
    mime == 'text/html' ||
    mime == 'application/xhtml+xml' ||
    mime == 'application/xml' ||
    mime == 'text/xml';

bool _looksLikeError(Uint8List bytes) {
  var index = 0;
  if (bytes.length >= 3 &&
      bytes[0] == 0xEF &&
      bytes[1] == 0xBB &&
      bytes[2] == 0xBF) {
    index = 3;
  }
  while (index < bytes.length && _isSpace(bytes[index])) {
    index++;
  }
  if (index >= bytes.length) return true;
  final first = bytes[index];
  return first == 0x7B || first == 0x5B || first == 0x3C;
}

bool _isSpace(int byte) =>
    byte == 0x09 || byte == 0x0A || byte == 0x0D || byte == 0x20;

bool _hasAudioMagic(Uint8List bytes) {
  if (bytes.length >= 3 &&
      bytes[0] == 0x49 &&
      bytes[1] == 0x44 &&
      bytes[2] == 0x33) {
    return true;
  }
  if (bytes.length >= 4) {
    final magic = String.fromCharCodes(bytes.sublist(0, 4));
    if (magic == 'fLaC' ||
        magic == 'OggS' ||
        magic == 'RIFF' ||
        magic == 'FORM' ||
        magic == 'wvpk' ||
        magic == 'MAC ') {
      return true;
    }
  }
  if (bytes.length >= 8 &&
      bytes[4] == 0x66 &&
      bytes[5] == 0x74 &&
      bytes[6] == 0x79 &&
      bytes[7] == 0x70) {
    return true;
  }
  return bytes.length >= 2 && bytes[0] == 0xFF && (bytes[1] & 0xE0) == 0xE0;
}

bool _isTextual(Uint8List bytes) {
  final count = bytes.length < 256 ? bytes.length : 256;
  if (count == 0) return true;
  for (var i = 0; i < count; i++) {
    final byte = bytes[i];
    final printable =
        byte == 0x09 ||
        byte == 0x0A ||
        byte == 0x0D ||
        (byte >= 0x20 && byte <= 0x7E);
    if (!printable) return false;
  }
  return true;
}
