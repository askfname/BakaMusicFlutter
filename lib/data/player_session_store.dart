import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/media_models.dart';
import 'song_record.dart';

/// 播放会话快照：持久化当前歌曲与播放列表，重建后恢复展示
class SavedPlayerSession {
  const SavedPlayerSession({
    this.queue = const [],
    this.queueIndex = 0,
    this.current,
    this.qualityKey = '320k',
    this.size,
    this.positionMs = 0,
  });

  final List<MediaItem> queue;
  final int queueIndex;
  final MediaItem? current;
  final String qualityKey;
  final int? size;
  final int positionMs;
}

/// 播放会话持久化：进程被回收或界面重建导致内存状态丢失时，以此恢复播放信息与播放列表；
/// 播放/暂停/进度仍以播放服务的实时快照为准。通过 SharedPreferences 读写，以便启动时同步恢复
class PlayerSessionStore {
  PlayerSessionStore(this._prefs);

  final SharedPreferences _prefs;

  static const int _maxQueue = 200;

  static const String _queueKey = 'queue';
  static const String _queueIndexKey = 'queueIndex';
  static const String _currentKey = 'current';
  static const String _qualityKey = 'qualityKey';
  static const String _sizeKey = 'size';
  static const String _positionMsKey = 'positionMs';

  /// 队列或当前歌曲变化时全量保存，调用方应对进度写入进行节流
  Future<void> save({
    required List<MediaItem> queue,
    required int queueIndex,
    MediaItem? current,
    String? qualityKey,
    int? size,
    required int positionMs,
  }) async {
    try {
      // 队列过长时仅保留当前曲目附近共 200 首，避免持久化数据过大
      var from = 0;
      if (queue.length > _maxQueue) {
        final idx = queueIndex < 0
            ? 0
            : (queueIndex >= queue.length ? queue.length - 1 : queueIndex);
        from = (idx - _maxQueue ~/ 2).clamp(0, queue.length);
      }
      final end =
          queue.length > from + _maxQueue ? from + _maxQueue : queue.length;
      final trimmed = queue.sublist(from, end);
      final trimmedIndex = (queueIndex - from)
          .clamp(0, trimmed.isEmpty ? 0 : trimmed.length - 1);
      await _prefs.setString(
          _queueKey,
          jsonEncode([
            for (final it in trimmed)
              SongRecord.toJsonString(SongRecord.fromItem(it)),
          ]));
      await _prefs.setInt(_queueIndexKey, trimmedIndex);
      await _prefs.setString(_currentKey,
          current == null ? '' : SongRecord.toJsonString(SongRecord.fromItem(current)));
      await _prefs.setString(
          _qualityKey, (qualityKey == null || qualityKey.isEmpty) ? '320k' : qualityKey);
      if (size != null && size > 0) {
        await _prefs.setInt(_sizeKey, size);
      } else {
        await _prefs.remove(_sizeKey);
      }
      await _prefs.setInt(_positionMsKey, positionMs < 0 ? 0 : positionMs);
    } catch (_) {}
  }

  /// 进度单独轻量保存，调用方应节流调用（如每 5 秒一次）
  Future<void> savePosition(int positionMs) async {
    try {
      await _prefs.setInt(_positionMsKey, positionMs < 0 ? 0 : positionMs);
    } catch (_) {}
  }

  SavedPlayerSession? load() {
    try {
      if (!_prefs.containsKey(_queueKey) && !_prefs.containsKey(_currentKey)) {
        return null;
      }
      final queue = <MediaItem>[];
      final rawQueue = _prefs.getString(_queueKey);
      if (rawQueue != null && rawQueue.isNotEmpty) {
        try {
          final array = jsonDecode(rawQueue);
          if (array is List) {
            for (final s in array.whereType<String>()) {
              final record = SongRecord.fromJson(s);
              if (record != null) queue.add(record.toMediaItem());
            }
          }
        } catch (_) {}
      }
      final rawIndex = _prefs.getInt(_queueIndexKey) ?? 0;
      final index = rawIndex.clamp(0, queue.isEmpty ? 0 : queue.length - 1);
      final rawCurrent = _prefs.getString(_currentKey);
      final current = (rawCurrent == null || rawCurrent.isEmpty)
          ? null
          : SongRecord.fromJson(rawCurrent)?.toMediaItem();
      if (queue.isEmpty && current == null) return null;
      final size = _prefs.getInt(_sizeKey);
      final quality = _prefs.getString(_qualityKey);
      return SavedPlayerSession(
        queue: queue,
        queueIndex: index,
        current: current,
        qualityKey: (quality == null || quality.isEmpty) ? '320k' : quality,
        size: (size != null && size > 0) ? size : null,
        positionMs: (_prefs.getInt(_positionMsKey) ?? 0).clamp(0, 1 << 62),
      );
    } catch (_) {
      return null;
    }
  }
}
