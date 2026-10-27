import 'dart:async';

import 'package:flutter/services.dart';

import '../models/media_models.dart';

/// 下载目录信息：默认公共 Music/BakaMusic，或用户通过 SAF 选择的自定义目录
class DownloadDirectoryInfo {
  const DownloadDirectoryInfo({required this.label, required this.custom});

  static const DownloadDirectoryInfo fallback = DownloadDirectoryInfo(
    label: 'Music/BakaMusic',
    custom: false,
  );

  final String label;
  final bool custom;
}

/// 原生下载状态事件：status 为 success / failure，title 为歌曲名
class DownloadEvent {
  const DownloadEvent({
    required this.status,
    required this.title,
    required this.message,
  });

  final String status;
  final String title;
  final String message;

  bool get failed => status == 'failure';

  static DownloadEvent? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final status = '${raw['status'] ?? ''}'.trim();
    if (status.isEmpty) return null;
    return DownloadEvent(
      status: status,
      title: '${raw['title'] ?? ''}'.trim(),
      message: '${raw['message'] ?? ''}'.trim(),
    );
  }
}

/// 音乐下载：交给 Android 原生 DownloadManager 或 SAF 前台服务，
/// 默认保存到公共 Music/BakaMusic，用户也可在设置中选择自定义目录
class DownloadHelper {
  DownloadHelper._();

  static const MethodChannel _channel = MethodChannel('baka_music/downloads');
  static const EventChannel _eventChannel = EventChannel(
    'baka_music/download_events',
  );

  static const String defaultUserAgent =
      'Mozilla/5.0 (Linux; Android 10) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/120.0 Mobile Safari/537.36';

  static final RegExp _invalidChars = RegExp(r'[\\/:*?"<>|]');

  static const Set<String> _flacKeys = {
    'flac',
    'flac24bit',
    'hires',
    'vinyl',
    'master',
    'mgg',
  };

  static const Set<String> _knownExtensions = {
    'mp3',
    'flac',
    'm4a',
    'aac',
    'ogg',
    'opus',
    'wav',
  };

  static const Map<String, String> _mimeTypes = {
    'flac': 'audio/flac',
    'm4a': 'audio/mp4',
    'aac': 'audio/aac',
    'ogg': 'audio/ogg',
    'opus': 'audio/ogg',
    'wav': 'audio/wav',
  };

  /// 按音质对象下载，返回开始下载的提示文案
  static Future<String> enqueue(MediaItem item, MusicQuality quality) =>
      enqueueByKey(item, quality.key);

  /// 下载请求头：保留插件头，缺少 UA 时使用统一默认值
  static Map<String, String> requestHeaders(MediaItem item) {
    final headers = <String, String>{...item.mediaHeaders};
    if (!headers.keys.any((key) => key.toLowerCase() == 'user-agent')) {
      headers['User-Agent'] = defaultUserAgent;
    }
    return headers;
  }

  /// 按音质键下载，返回开始下载的提示文案
  static Future<String> enqueueByKey(MediaItem item, String qualityKey) async {
    final url = item.mediaUrl;
    if (url == null || url.isEmpty) {
      throw StateError('当前歌曲没有可用的下载地址');
    }
    final lower = url.toLowerCase();
    if (!lower.startsWith('https://') && !lower.startsWith('http://')) {
      throw StateError('下载地址必须为 HTTP(S)');
    }
    final ext = _extensionFor(qualityKey, url);
    final safeTitle = _sanitize(item.title, '未知歌曲');
    final safeArtist = _sanitize(item.artist, '未知歌手');
    final message = await _channel.invokeMethod<String>('enqueue', {
      'url': url,
      'headers': requestHeaders(item),
      'fileName': '$safeTitle - $safeArtist.$ext',
      'mimeType': _mimeTypes[ext] ?? 'audio/mpeg',
      'title': safeTitle,
      'artist': safeArtist,
      'qualityLabel': MusicQuality.labelOf(qualityKey),
    });
    if (message == null || message.isEmpty) {
      throw StateError('下载服务未响应');
    }
    return message;
  }

  /// 真实下载状态流：默认目录由系统完成广播转换，自定义目录由前台服务上报
  static Stream<DownloadEvent> get events async* {
    await for (final raw in _eventChannel.receiveBroadcastStream()) {
      final event = DownloadEvent.tryParse(raw);
      if (event != null) yield event;
    }
  }

  /// 读取当前下载目录；原生侧不可用时回退默认目录
  static Future<DownloadDirectoryInfo> directory() async {
    try {
      final result = await _channel.invokeMapMethod<String, Object?>(
        'getDirectory',
      );
      return _parseDirectory(result);
    } on MissingPluginException {
      return DownloadDirectoryInfo.fallback;
    }
  }

  /// 打开系统目录选择器；取消返回 null
  static Future<DownloadDirectoryInfo?> pickDirectory() async {
    final result = await _channel.invokeMapMethod<String, Object?>(
      'pickDirectory',
    );
    if (result == null) return null;
    return _parseDirectory(result);
  }

  /// 恢复默认公共目录
  static Future<DownloadDirectoryInfo> resetDirectory() async {
    final result = await _channel.invokeMapMethod<String, Object?>(
      'resetDirectory',
    );
    return _parseDirectory(result);
  }

  static DownloadDirectoryInfo _parseDirectory(Map<String, Object?>? value) {
    if (value == null) return DownloadDirectoryInfo.fallback;
    final label = '${value['label'] ?? ''}'.trim();
    return DownloadDirectoryInfo(
      label: label.isEmpty ? DownloadDirectoryInfo.fallback.label : label,
      custom: value['custom'] == true,
    );
  }

  /// 优先采用链接末尾的真实扩展名，缺失时才按音质推断
  static String _extensionFor(String qualityKey, String url) {
    final path = Uri.tryParse(url)?.path.toLowerCase() ?? '';
    final dot = path.lastIndexOf('.');
    if (dot >= 0) {
      final ext = path.substring(dot + 1);
      if (_knownExtensions.contains(ext)) return ext;
    }
    return _flacKeys.contains(qualityKey.toLowerCase()) ? 'flac' : 'mp3';
  }

  static String _sanitize(String value, String fallback) {
    final cleaned = value.replaceAll(_invalidChars, '_');
    return cleaned.trim().isEmpty ? fallback : cleaned;
  }
}
