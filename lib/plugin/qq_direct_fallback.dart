/// QQ 音乐原生直连兜底
///
/// 仅当 JS 的 getMediaSource 抛错或返回空地址时触发，不改变正常插件流程：
/// 念心 tx.php 主通道 + s01s 备用通道，均经音频探针确认，失败返回 null
library;

import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';

import '../data/lx_models.dart';
import '../models/media_models.dart';
import 'plugin_http_client.dart' show isPluginPrivateHost;

void _log(String message, {bool warn = false}) {
  developer.log(message, name: 'BakaPlugin', level: warn ? 900 : 500);
}

/// 是否 QQ 平台
bool isQqPlatform(String platform) {
  if (platform.trim().toLowerCase() == 'qq音乐') return true;
  return lxSourceForPlatform(platform) == 'tx';
}

/// “念心”音质档位
const Map<String, String> _qqNianxinLevel = {
  '96k': 'standard',
  '128k': 'standard',
  '192k': 'standard',
  '320k': 'exhigh',
  'flac': 'lossless',
  'flac24bit': 'lossless',
  'hires': 'hires',
  'atmos': 'lossless',
  'atmos_plus': 'lossless',
  'master': 'jymaster',
  'vinyl': 'lossless',
  'dolby': 'lossless',
};

/// s01s 按音质的字段优先级（单字段为空时自动找同接口其它可用档）
const Map<String, List<String>> _qqS01sFields = {
  '96k': [
    'song_play_url_fq',
    'song_play_url_standard',
    'song_play_url',
    'song_play_url_hq',
    'song_play_url_sq',
  ],
  '128k': [
    'song_play_url_standard',
    'song_play_url',
    'song_play_url_hq',
    'song_play_url_fq',
    'song_play_url_sq',
  ],
  '192k': [
    'song_play_url_standard',
    'song_play_url',
    'song_play_url_hq',
    'song_play_url_fq',
    'song_play_url_sq',
  ],
  '320k': [
    'song_play_url_hq',
    'song_play_url',
    'song_play_url_sq',
    'song_play_url_standard',
    'song_play_url_fq',
  ],
  'flac': [
    'song_play_url_sq',
    'song_play_url',
    'song_play_url_hq',
    'song_play_url_standard',
    'song_play_url_fq',
  ],
  'flac24bit': [
    'song_play_url_sq',
    'song_play_url',
    'song_play_url_hq',
    'song_play_url_standard',
    'song_play_url_fq',
  ],
  'hires': [
    'song_play_url_sq',
    'song_play_url_hq',
    'song_play_url',
    'song_play_url_standard',
    'song_play_url_fq',
  ],
  'atmos': [
    'song_play_url_sq',
    'song_play_url_hq',
    'song_play_url',
    'song_play_url_standard',
    'song_play_url_fq',
  ],
  'atmos_plus': [
    'song_play_url_sq',
    'song_play_url_hq',
    'song_play_url',
    'song_play_url_standard',
    'song_play_url_fq',
  ],
  'master': [
    'song_play_url_sq',
    'song_play_url_hq',
    'song_play_url',
    'song_play_url_standard',
    'song_play_url_fq',
  ],
};

final RegExp _qqPageUrl = RegExp(
  r'music\.163\.com/song/media/outer|\.(?:html?|php)(?:[?#]|$)|/songDetail/',
  caseSensitive: false,
);
const int _qqApiTimeoutMs = 8000;
const int _qqProbeTimeoutMs = 5000;
const String _qqUa = 'Mozilla/5.0';

/// 从回传载荷中取 QQ songmid（优先字母型 mid，纯数字 id 仅作最后尝试）
String? _qqSongMid(Map<String, dynamic> payload, MediaItem item) {
  var mid = '${payload['songmid'] ?? ''}'.trim();
  if (mid.isEmpty) mid = '${payload['mid'] ?? ''}'.trim();
  if (mid.isNotEmpty) return mid;
  final id = item.id.trim();
  if (id.isNotEmpty) return id;
  return null;
}

String _enc(String value) => Uri.encodeQueryComponent(value);

Future<List<int>> _readLimited(Stream<List<int>> stream, int limit) async {
  final bytes = <int>[];
  await for (final chunk in stream) {
    final remaining = limit - bytes.length;
    if (remaining <= 0) break;
    if (chunk.length <= remaining) {
      bytes.addAll(chunk);
    } else {
      bytes.addAll(chunk.sublist(0, remaining));
    }
  }
  return bytes;
}

Future<String> _httpGetText(String url, int timeoutMs) async {
  final timeout = Duration(milliseconds: timeoutMs);
  final lower = url.toLowerCase();
  if (!lower.startsWith('http://') && !lower.startsWith('https://')) {
    throw StateError('bad url');
  }
  final uri = Uri.tryParse(url);
  if (uri == null) throw StateError('bad url');
  final host = uri.host.toLowerCase();
  if (host.isEmpty) throw StateError('bad url');
  if (await isPluginPrivateHost(host)) throw StateError('bad host');
  final client = HttpClient();
  try {
    client.connectionTimeout = timeout;
    final request = await client.getUrl(uri).timeout(timeout);
    request.followRedirects = true;
    request.headers.set(HttpHeaders.userAgentHeader, _qqUa);
    request.headers.set(
      HttpHeaders.acceptHeader,
      'application/json, text/plain, */*',
    );
    final response = await request.close().timeout(timeout);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw StateError('HTTP ${response.statusCode}');
    }
    var finalHost = host;
    if (response.redirects.isNotEmpty) {
      final redirectHost = response.redirects.last.location.host.toLowerCase();
      if (redirectHost.isNotEmpty) finalHost = redirectHost;
    }
    if (await isPluginPrivateHost(finalHost)) {
      throw StateError('bad redirect host');
    }
    final bytes = await _readLimited(response.timeout(timeout), 512 * 1024);
    return utf8.decode(bytes, allowMalformed: true);
  } finally {
    client.close(force: true);
  }
}

/// 音频探针：Range 首 1KB，命中 ID3/fLaC/OggS/MP3 帧同步/ftyp 才算可用
Future<bool> _probeQqAudio(String url) async {
  final timeout = const Duration(milliseconds: _qqProbeTimeoutMs);
  final lower = url.toLowerCase();
  if (!lower.startsWith('http://') && !lower.startsWith('https://')) {
    return false;
  }
  final client = HttpClient();
  try {
    final uri = Uri.tryParse(url);
    if (uri == null) return false;
    final host = uri.host.toLowerCase();
    if (host.isEmpty || await isPluginPrivateHost(host)) return false;
    client.connectionTimeout = timeout;
    final request = await client.getUrl(uri).timeout(timeout);
    request.followRedirects = true;
    request.headers.set(HttpHeaders.userAgentHeader, _qqUa);
    request.headers.set(HttpHeaders.rangeHeader, 'bytes=0-1023');
    final response = await request.close().timeout(timeout);
    final status = response.statusCode;
    if (status != 200 && status != 206) return false;
    var finalHost = host;
    if (response.redirects.isNotEmpty) {
      final redirectHost = response.redirects.last.location.host.toLowerCase();
      if (redirectHost.isNotEmpty) finalHost = redirectHost;
    }
    if (await isPluginPrivateHost(finalHost)) return false;
    final bytes = await _readLimited(response.timeout(timeout), 64 * 1024);
    if (bytes.length < 4) return false;
    final sig4 = String.fromCharCodes(bytes.sublist(0, 4));
    if (sig4 == 'fLaC' || sig4.startsWith('ID3') || sig4 == 'OggS') {
      return true;
    }
    if (bytes[0] == 0xFF && (bytes[1] & 0xE0) == 0xE0) return true;
    if (bytes.length >= 8 &&
        String.fromCharCodes(bytes.sublist(4, 8)) == 'ftyp') {
      return true;
    }
    return false;
  } catch (_) {
    return false;
  } finally {
    client.close(force: true);
  }
}

String? _validQqUrl(String? raw) {
  if (raw == null) return null;
  final url = raw.trim();
  if (url.isEmpty) return null;
  if (!url.toLowerCase().startsWith('http')) return null;
  if (_qqPageUrl.hasMatch(url)) return null;
  return url;
}

/// QQ 原生直连取流：念心 tx.php 主通道 + s01s 备用通道，均经音频探针确认
/// 失败返回 null（由路由继续降级下一档），不抛错。
Future<String?> qqDirectMediaUrl(
  MediaItem item,
  Map<String, dynamic> payload,
  String quality,
) async {
  final songmid = _qqSongMid(payload, item);
  if (songmid == null || songmid.isEmpty) {
    _log('QQ 原生兜底缺少 songmid: ${item.platform}:${item.id}', warn: true);
    return null;
  }
  // 主通道：念心 tx.php
  try {
    final level = _qqNianxinLevel[quality] ?? 'standard';
    final api =
        'https://mcp.nianxinxz.com/share/ceshi/tx.php?id=${_enc(songmid)}&level=${_enc(level)}';
    final decoded = jsonDecode(await _httpGetText(api, _qqApiTimeoutMs));
    var direct = '';
    if (decoded is Map) {
      direct = '${decoded['url'] ?? ''}';
      if (direct.isEmpty) {
        final data = decoded['data'];
        if (data is Map) direct = '${data['url'] ?? ''}';
      }
    }
    final curl = _validQqUrl(direct);
    if (curl != null && await _probeQqAudio(curl)) return curl;
    throw StateError('念心未返回可用音频');
  } catch (error) {
    _log('QQ 原生兜底念心失败($quality): $error', warn: true);
  }
  // 备用通道：s01s（遍历该音质全部字段，空字段跳过）
  try {
    const fallbackFields = [
      'song_play_url_standard',
      'song_play_url',
      'song_play_url_hq',
      'song_play_url_fq',
      'song_play_url_sq',
    ];
    final fields = _qqS01sFields[quality] ?? fallbackFields;
    final api = 'https://tang.api.s01s.cn/music_open_api.php?mid=${_enc(songmid)}';
    final decoded = jsonDecode(await _httpGetText(api, _qqApiTimeoutMs));
    if (decoded is Map) {
      for (final field in fields) {
        final curl = _validQqUrl('${decoded[field] ?? ''}');
        if (curl == null) continue;
        if (await _probeQqAudio(curl)) return curl;
      }
    }
    throw StateError('s01s 未返回请求音质的播放链接');
  } catch (error) {
    _log('QQ 原生兜底 s01s 失败($quality): $error', warn: true);
  }
  return null;
}
