import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/media_models.dart';
import 'song_record.dart';

/// 本地数据存储：搜索历史、收藏、歌单与默认音质
class AppRepository extends ChangeNotifier {
  AppRepository(this._prefs);

  final SharedPreferences _prefs;

  static Future<AppRepository> create() async =>
      AppRepository(await SharedPreferences.getInstance());

  /// 收藏歌单名称，不可修改或删除
  static const String favoriteSheet = '我喜欢的音乐';

  /// 无自建歌单时的后备选项
  static const String defaultSheet = '默认歌单';

  static const String _historyKey = 'search_history';
  static const String _favoriteKey = 'favorite_song_ids';
  static const String _playQualityKey = 'default_play_quality';
  static const String _downloadQualityKey = 'default_download_quality';
  static const String _recordKey = 'song_records';
  static const String _playlistNamesKey = 'playlist_names';

  List<String> get searchHistory => _decode(_prefs.getString(_historyKey));

  Set<String> get favorites => _decode(_prefs.getString(_favoriteKey)).toSet();

  /// 默认播放音质
  String get playQuality => _prefs.getString(_playQualityKey) ?? 'flac';

  /// 默认下载音质
  String get downloadQuality => _prefs.getString(_downloadQualityKey) ?? 'flac';

  Map<String, String> _records() {
    final map = <String, String>{};
    for (final s in _decode(_prefs.getString(_recordKey))) {
      try {
        final o = jsonDecode(s);
        final k = (o is Map ? o['key'] : null) as String?;
        if (k != null && k.isNotEmpty) map[k] = s;
      } catch (_) {}
    }
    return map;
  }

  Future<void> _saveRecords(Map<String, String> records) =>
      _prefs.setString(_recordKey, _encode(records.values.toList()));

  /// 收藏歌曲快照列表，无快照的旧收藏 ID 会被跳过
  List<SongRecord> get favoriteSongs {
    final keys = _decode(_prefs.getString(_favoriteKey)).toSet();
    final records = _records();
    return [
      for (final k in keys)
        if (records[k] != null)
          if (SongRecord.fromJson(records[k]) != null) SongRecord.fromJson(records[k])!,
    ];
  }

  /// 全部歌单名列表，始终包含“我喜欢的音乐”
  List<String> get playlistNames =>
      _distinct([favoriteSheet, ..._decode(_prefs.getString(_playlistNamesKey))]);

  /// 用户自建歌单名列表，不含“我喜欢的音乐”
  List<String> get userPlaylistNames =>
      _distinct(_decode(_prefs.getString(_playlistNamesKey)));

  /// 指定歌单的歌曲快照列表
  List<SongRecord> playlistSongs(String name) {
    if (name == favoriteSheet) return favoriteSongs;
    final keys = _decode(_prefs.getString('playlist_$name'));
    final records = _records();
    return [
      for (final k in keys)
        if (records[k] != null)
          if (SongRecord.fromJson(records[k]) != null) SongRecord.fromJson(records[k])!,
    ];
  }

  Future<void> addSearch(String query) async {
    if (query.trim().isEmpty) return;
    final list = _decode(_prefs.getString(_historyKey))..remove(query);
    list.insert(0, query);
    await _prefs.setString(_historyKey, _encode(list.take(20).toList()));
    notifyListeners();
  }

  Future<void> removeSearch(String query) async {
    final list = _decode(_prefs.getString(_historyKey))..remove(query);
    await _prefs.setString(_historyKey, _encode(list));
    notifyListeners();
  }

  Future<void> clearSearchHistory() async {
    await _prefs.setString(_historyKey, _encode(const []));
    notifyListeners();
  }

  /// 收藏切换：收藏时写入快照，取消时仅移除键（快照保留供歌单使用）
  /// 返回切换后是否为已收藏
  Future<bool> toggleFavorite(MediaItem item) async {
    final record = SongRecord.fromItem(item);
    final values = favorites;
    final bool result;
    if (values.contains(record.key)) {
      values.remove(record.key);
      result = false;
    } else {
      values.add(record.key);
      result = true;
    }
    await _prefs.setString(_favoriteKey, _encode(values.toList()));
    final records = _records();
    records[record.key] = SongRecord.toJsonString(record);
    await _saveRecords(records);
    notifyListeners();
    return result;
  }

  bool isFavorite(String platform, String id) =>
      favorites.contains(SongRecord.recordKey(platform, id));

  Future<void> addToPlaylist(String playlist, MediaItem item) async {
    final record = SongRecord.fromItem(item);
    if (playlist == favoriteSheet) {
      final values = [..._decode(_prefs.getString(_favoriteKey)), record.key];
      await _prefs.setString(_favoriteKey, _encode(_distinct(values)));
    } else {
      final key = 'playlist_$playlist';
      await _prefs.setString(
          key, _encode(_distinct([..._decode(_prefs.getString(key)), record.key])));
      await _prefs.setString(
          _playlistNamesKey,
          _encode(_distinct(
              [..._decode(_prefs.getString(_playlistNamesKey)), playlist])));
    }
    final records = _records();
    records[record.key] = SongRecord.toJsonString(record);
    await _saveRecords(records);
    notifyListeners();
  }

  Future<void> removeFromPlaylist(String playlist, String key) async {
    if (playlist == favoriteSheet) {
      final values = _decode(_prefs.getString(_favoriteKey))..remove(key);
      await _prefs.setString(_favoriteKey, _encode(values));
    } else {
      final prefsKey = 'playlist_$playlist';
      final values = _decode(_prefs.getString(prefsKey))..remove(key);
      await _prefs.setString(prefsKey, _encode(values));
    }
    notifyListeners();
  }

  Future<bool> createPlaylist(String name) async {
    final clean = name.trim();
    if (clean.isEmpty || clean == favoriteSheet) return false;
    final names = _decode(_prefs.getString(_playlistNamesKey));
    final created = !names.contains(clean);
    if (created) names.add(clean);
    await _prefs.setString(_playlistNamesKey, _encode(names));
    notifyListeners();
    return created;
  }

  Future<bool> deletePlaylist(String name) async {
    if (name == favoriteSheet) return false;
    final names = _decode(_prefs.getString(_playlistNamesKey))..remove(name);
    await _prefs.setString(_playlistNamesKey, _encode(names));
    await _prefs.remove('playlist_$name');
    notifyListeners();
    return true;
  }

  Future<void> setPlayQuality(String key) async {
    await _prefs.setString(_playQualityKey, key);
    notifyListeners();
  }

  Future<void> setDownloadQuality(String key) async {
    await _prefs.setString(_downloadQualityKey, key);
    notifyListeners();
  }

  String _encode(List<String> values) => jsonEncode(values);

  List<String> _decode(String? raw) {
    if (raw == null || raw.isEmpty) return [];
    try {
      final array = jsonDecode(raw);
      if (array is List) return array.whereType<String>().toList();
    } catch (_) {}
    return [];
  }

  List<String> _distinct(List<String> values) {
    final seen = <String>{};
    final out = <String>[];
    for (final v in values) {
      if (seen.add(v)) out.add(v);
    }
    return out;
  }
}
