import 'dart:convert';

import '../models/media_models.dart';

/// 歌曲快照：收藏/歌单展示与回放所需信息，key 规则为 "${platform}:${id}"
class SongRecord {
  const SongRecord({
    required this.key,
    required this.id,
    required this.platform,
    required this.title,
    required this.artist,
    this.album = '',
    this.artwork,
    this.durationMs = 0,
    this.qualityKey = '320k',
    this.size,
    this.qualitiesJson = '{}',
    this.rawJson,
  });

  final String key;
  final String id;
  final String platform;
  final String title;
  final String artist;
  final String album;
  final String? artwork;
  final int durationMs;
  final String qualityKey;
  final int? size;
  final String qualitiesJson;
  final String? rawJson;

  MediaItem toMediaItem() {
    final qualities = <String, QualityInfo>{};
    try {
      final o = jsonDecode(qualitiesJson);
      if (o is Map) {
        for (final entry in o.entries) {
          final q = entry.value;
          if (q is Map) {
            final size = (q['size'] as num?)?.toInt();
            final bitrate = (q['bitrate'] as num?)?.toInt();
            final url = q['url'] as String?;
            qualities['${entry.key}'] = QualityInfo(
              size: (size != null && size > 0) ? size : null,
              bitrate: (bitrate != null && bitrate > 0) ? bitrate : null,
              url: (url != null && url.toLowerCase().startsWith('http')) ? url : null,
            );
          }
        }
      }
    } catch (_) {}
    return MediaItem(
      id: id,
      platform: platform,
      title: title,
      artist: artist,
      album: album,
      artwork: artwork,
      durationMs: durationMs,
      qualities: qualities,
      rawJson: rawJson,
    );
  }

  static String recordKey(String platform, String id) => '$platform:$id';

  static SongRecord fromItem(MediaItem item, {String? qualityKey}) {
    final best = qualityKey ??
        (item.qualities.isEmpty
            ? null
            : item.qualities.keys
                .reduce((a, b) => qualityRankOf(a) >= qualityRankOf(b) ? a : b)) ??
        '320k';
    final qualitiesJson = jsonEncode({
      for (final e in item.qualities.entries) e.key: e.value.toJson(),
    });
    return SongRecord(
      key: recordKey(item.platform, item.id),
      id: item.id,
      platform: item.platform,
      title: item.title,
      artist: item.artist,
      album: item.album,
      artwork: item.artwork,
      durationMs: item.durationMs,
      qualityKey: best,
      size: item.qualities[best]?.size,
      qualitiesJson: qualitiesJson,
      rawJson: item.rawJson,
    );
  }

  static SongRecord? fromJson(String? raw) {
    if (raw == null || raw.trim().isEmpty) return null;
    try {
      final o = jsonDecode(raw) as Map<String, dynamic>;
      final key = o['key'] as String?;
      if (key == null) return null;
      final size = (o['size'] as num?)?.toInt();
      final qualityKey = o['qualityKey'] as String?;
      return SongRecord(
        key: key,
        id: '${o['id'] ?? ''}',
        platform: '${o['platform'] ?? ''}',
        title: (o['title'] as String?) ?? '未知歌曲',
        artist: (o['artist'] as String?) ?? '未知歌手',
        album: '${o['album'] ?? ''}',
        artwork: (o['artwork'] as String?)?.takeIf((v) => v.isNotEmpty),
        durationMs: (o['durationMs'] as num?)?.toInt() ?? 0,
        qualityKey: (qualityKey == null || qualityKey.isEmpty) ? '320k' : qualityKey,
        size: (size != null && size > 0) ? size : null,
        qualitiesJson: (o['qualitiesJson'] as String?) ?? '{}',
        rawJson: (o['rawJson'] as String?)?.takeIf((v) => v.isNotEmpty),
      );
    } catch (_) {
      return null;
    }
  }

  static String toJsonString(SongRecord r) => jsonEncode({
        'key': r.key,
        'id': r.id,
        'platform': r.platform,
        'title': r.title,
        'artist': r.artist,
        'album': r.album,
        'artwork': r.artwork ?? '',
        'durationMs': r.durationMs,
        'qualityKey': r.qualityKey,
        if (r.size != null) 'size': r.size,
        'qualitiesJson': r.qualitiesJson,
        'rawJson': r.rawJson ?? '',
      });
}

extension _StringTakeIf on String? {
  String? takeIf(bool Function(String) predicate) =>
      (this != null && predicate(this!)) ? this : null;
}
