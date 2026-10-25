/// 点播解析整体超时：超时终止请求，并按失败原因显示对应的播放提示
const int playResolveTimeoutMs = 20000;

/// 音质档位：key 为插件契约值，label 为界面展示文案
enum MusicQuality {
  q96('96k', '流畅 · 96K'),
  low('128k', '标准 · 128K'),
  q192('192k', '中等 · 192K'),
  high('320k', '高品质 · 320K'),
  lossless('flac', '无损 · FLAC'),
  flac24('flac24bit', '无损 · FLAC 24Bit'),
  hiRes('hires', 'Hi-Res'),
  vinyl('vinyl', '黑胶 · Vinyl'),
  dolby('dolby', '杜比 · Dolby'),
  atmos('atmos', '空间 · Atmos'),
  atmosPlus('atmos_plus', '空间 · Atmos 2.0'),
  master('master', '大师 · Master');

  const MusicQuality(this.key, this.label);

  final String key;
  final String label;

  static MusicQuality? fromKey(String? key) {
    for (final q in MusicQuality.values) {
      if (q.key == key) return q;
    }
    return null;
  }

  static String labelOf(String key) => fromKey(key)?.label ?? key.toUpperCase();
}

/// 音质键：从低到高
const List<String> qualityKeysOrdered = [
  '96k', '128k', '192k', '320k', 'flac', 'flac24bit',
  'hires', 'vinyl', 'dolby', 'atmos', 'atmos_plus', 'master',
];

int qualityRankOf(String key) => qualityKeysOrdered.indexOf(key);

/// 生成音质尝试顺序：默认音质优先，其次更低音质，最后更高音质
List<String> qualityOrderLowerFirst(String defaultKey) {
  final idx = qualityKeysOrdered.indexOf(defaultKey);
  if (idx < 0) return [defaultKey, ...qualityKeysOrdered];
  final left = qualityKeysOrdered.sublist(0, idx).reversed;
  final right = qualityKeysOrdered.sublist(idx + 1);
  return [defaultKey, ...left, ...right];
}

/// 播放降级顺序：默认音质起逐级向低尝试，不主动探测更高音质
List<String> qualityOrderDownFrom(String defaultKey) {
  final idx = qualityKeysOrdered.indexOf(defaultKey);
  if (idx < 0) return [defaultKey];
  return [defaultKey, ...qualityKeysOrdered.sublist(0, idx).reversed];
}

/// 播放实际尝试顺序：已知音质只走默认及更低；未知音质才全量探测
List<String> playbackQualityOrder(MediaItem item, String defaultKey) {
  if (item.qualities.isEmpty) return qualityOrderLowerFirst(defaultKey);
  final tried = qualityOrderDownFrom(defaultKey)
      .where(item.qualities.containsKey)
      .toList();
  if (tried.isNotEmpty) return tried;
  // 可用音质全高于默认时按从低到高兜底
  final keys = item.qualities.keys.toList()
    ..sort((a, b) => qualityRankOf(a).compareTo(qualityRankOf(b)));
  return keys;
}

/// 当前播放项：已解析地址与实际播放音质，供播放栏/播放页显示
class NowPlaying {
  const NowPlaying({
    required this.item,
    required this.mediaUrl,
    required this.qualityKey,
    this.size,
    this.headers = const {},
    this.loading = false,
    this.backupUrls = const [],
    this.via = '',
  });

  final MediaItem item;
  final String mediaUrl;
  final String qualityKey;
  final int? size;

  /// 播放请求头，随地址一起传递给播放器
  final Map<String, String> headers;

  /// 是否处于解析中：解析中先显示歌曲信息并叠加加载动画
  final bool loading;

  /// 备用播放地址：主源 403/断连时自动切换，耗尽才弹失败框
  final List<String> backupUrls;

  /// 取流来源标注：空=原生插件
  final String via;

  String get key => '${item.platform}:${item.id}';

  /// 界面展示的音源名：平台 + 取流来源
  String get sourceLabel => '${item.platform}$via';

  NowPlaying copyWith({
    MediaItem? item,
    String? mediaUrl,
    String? qualityKey,
    int? size,
    Map<String, String>? headers,
    bool? loading,
    List<String>? backupUrls,
    String? via,
  }) =>
      NowPlaying(
        item: item ?? this.item,
        mediaUrl: mediaUrl ?? this.mediaUrl,
        qualityKey: qualityKey ?? this.qualityKey,
        size: size ?? this.size,
        headers: headers ?? this.headers,
        loading: loading ?? this.loading,
        backupUrls: backupUrls ?? this.backupUrls,
        via: via ?? this.via,
      );
}

class MediaItem {
  const MediaItem({
    required this.id,
    required this.platform,
    required this.title,
    required this.artist,
    this.album = '',
    this.artwork,
    this.durationMs = 0,
    this.mediaUrl,
    this.mediaHeaders = const {},
    this.lyric,
    this.qualities = const {},
    this.rawJson,
    this.backupUrls = const [],
  });

  final String id;
  final String platform;
  final String title;
  final String artist;
  final String album;
  final String? artwork;
  final int durationMs;
  final String? mediaUrl;
  final Map<String, String> mediaHeaders;
  final LyricSource? lyric;
  final Map<String, QualityInfo> qualities;

  /// 插件返回的完整原始 JSON，用于回传给 getMediaSource/getLyric
  final String? rawJson;

  /// 备用播放地址，主源失败时自动切换
  final List<String> backupUrls;

  String get key => '$platform:$id';

  MediaItem copyWith({
    String? id,
    String? platform,
    String? title,
    String? artist,
    String? album,
    String? artwork,
    int? durationMs,
    String? mediaUrl,
    Map<String, String>? mediaHeaders,
    LyricSource? lyric,
    Map<String, QualityInfo>? qualities,
    String? rawJson,
    List<String>? backupUrls,
  }) =>
      MediaItem(
        id: id ?? this.id,
        platform: platform ?? this.platform,
        title: title ?? this.title,
        artist: artist ?? this.artist,
        album: album ?? this.album,
        artwork: artwork ?? this.artwork,
        durationMs: durationMs ?? this.durationMs,
        mediaUrl: mediaUrl ?? this.mediaUrl,
        mediaHeaders: mediaHeaders ?? this.mediaHeaders,
        lyric: lyric ?? this.lyric,
        qualities: qualities ?? this.qualities,
        rawJson: rawJson ?? this.rawJson,
        backupUrls: backupUrls ?? this.backupUrls,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'platform': platform,
        'title': title,
        'artist': artist,
        'album': album,
        'artwork': artwork ?? '',
        'durationMs': durationMs,
        'mediaUrl': mediaUrl ?? '',
        'mediaHeaders': mediaHeaders,
        'qualities': {for (final e in qualities.entries) e.key: e.value.toJson()},
        'rawJson': rawJson ?? '',
        'backupUrls': backupUrls,
      };

  static MediaItem fromJson(Map<String, dynamic> o) {
    final qualities = <String, QualityInfo>{};
    final rawQualities = o['qualities'];
    if (rawQualities is Map) {
      for (final entry in rawQualities.entries) {
        final q = entry.value;
        if (q is Map) {
          qualities['${entry.key}'] = QualityInfo.fromJson(Map<String, dynamic>.from(q));
        }
      }
    }
    return MediaItem(
      id: '${o['id'] ?? ''}',
      platform: '${o['platform'] ?? ''}',
      title: '${o['title'] ?? ''}',
      artist: '${o['artist'] ?? ''}',
      album: '${o['album'] ?? ''}',
      artwork: (o['artwork'] as String?)?.trim().takeIf((v) => v.isNotEmpty),
      durationMs: (o['durationMs'] as num?)?.toInt() ?? 0,
      mediaUrl: (o['mediaUrl'] as String?)?.takeIf((v) => v.isNotEmpty),
      mediaHeaders: o['mediaHeaders'] is Map
          ? Map<String, String>.from(o['mediaHeaders'] as Map)
          : const {},
      qualities: qualities,
      rawJson: (o['rawJson'] as String?)?.takeIf((v) => v.isNotEmpty),
      backupUrls: o['backupUrls'] is List
          ? (o['backupUrls'] as List).whereType<String>().toList()
          : const [],
    );
  }
}

extension _StringTakeIf on String? {
  String? takeIf(bool Function(String) predicate) =>
      (this != null && predicate(this!)) ? this : null;
}

class QualityInfo {
  const QualityInfo({this.size, this.bitrate, this.url});

  final int? size;
  final int? bitrate;
  final String? url;

  Map<String, dynamic> toJson() => {
        if (size != null) 'size': size,
        if (bitrate != null) 'bitrate': bitrate,
        if (url != null) 'url': url,
      };

  static QualityInfo fromJson(Map<String, dynamic> o) => QualityInfo(
        size: (o['size'] as num?)?.toInt(),
        bitrate: (o['bitrate'] as num?)?.toInt(),
        url: (o['url'] as String?)?.takeIf((v) => v.isNotEmpty),
      );
}

class LyricSource {
  const LyricSource({
    this.rawLrc,
    this.translation,
    this.romanization,
    this.format = 'lrc',
  });

  final String? rawLrc;
  final String? translation;
  final String? romanization;
  final String format;
}

class SearchPage<T> {
  const SearchPage({required this.data, this.isEnd = true});

  final List<T> data;
  final bool isEnd;
}

/// 榜单分组：title 为分组名，items 为该分组下的榜单条目
class TopListGroup {
  const TopListGroup({this.title = '', this.items = const []});

  final String title;
  final List<TopListItem> items;
}

/// 单个榜单条目：原始字段保留在 rawJson 中，用于调用 getTopListDetail 时定位榜单
class TopListItem {
  const TopListItem({
    required this.id,
    this.platform = '',
    this.title = '',
    this.description = '',
    this.coverImg,
    this.groupTitle = '',
    this.rawJson,
  });

  final String id;
  final String platform;
  final String title;
  final String description;
  final String? coverImg;

  /// 所属分组名，仅展示用，不传递给插件
  final String groupTitle;
  final String? rawJson;
}

/// 播放解析请求超时：与协程取消区分，超时显示 3003 错误弹窗。
class MediaResolveTimeoutException implements Exception {
  MediaResolveTimeoutException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 插件运行时已被重载/释放：调用方应按平台名重新获取最新适配器重试一次
class StalePluginException implements Exception {
  StalePluginException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 插件契约的数据侧接口
abstract class MusicPlugin {
  String get platform;
  String? get version;
  Set<String> get supportedQualities;

  Future<SearchPage<MediaItem>> search(String query, int page);

  Future<MediaItem?> getMediaSource(MediaItem item, String quality);

  /// 歌曲详情补全，搜索项 qualities 为空时补音质/封面，不支持返回 null
  Future<MediaItem?> getMusicInfo(MediaItem item) async => null;

  /// 带实际命中音质的播放解析：部分插件会降级返回，
  /// 此时第二分量为插件上报的实际音质键；默认实现沿用请求音质
  Future<(MediaItem, String)?> getMediaSourceDetailed(MediaItem item, String quality) async {
    final r = await getMediaSource(item, quality);
    return r == null ? null : (r, quality);
  }

  Future<LyricSource?> getLyric(MediaItem item);

  Future<PlaylistSnapshot?> importMusicSheet(String urlLike);

  /// 榜单分组，不支持的插件返回空列表
  Future<List<TopListGroup>> topLists() async => const [];

  /// 榜单详情，多数插件忽略 page，isEnd 缺省为 true
  Future<SearchPage<MediaItem>> topListDetail(TopListItem item, [int page = 1]) async => const SearchPage(data: []);

  /// 切歌时立即终止该插件未完成的网络请求
  void cancelPendingRequests();
}

class PlaylistSnapshot {
  const PlaylistSnapshot({
    required this.id,
    required this.platform,
    required this.title,
    this.artist,
    this.artwork,
    this.musicList = const [],
  });

  final String id;
  final String platform;
  final String title;
  final String? artist;
  final String? artwork;
  final List<MediaItem> musicList;
}
