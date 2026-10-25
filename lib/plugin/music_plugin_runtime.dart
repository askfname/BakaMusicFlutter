/// QuickJS 插件运行时宿主
/// 每个插件一个 worker isolate，所有 JS 调用在 worker 内串行执行：
/// - 单次调用默认 30s 超时，播放解析与榜单详情分别放宽到 30s/60s；
/// - 超时后取消在途请求；
/// - JS 失败时 QQ 平台转原生直连兜底，其余上抛由路由重试；
/// - 实例被重载/释放后抛出 [StalePluginException]，由上层重新加载适配器
library;

import 'dart:convert';
import 'dart:developer' as developer;

import '../models/media_models.dart';
import 'js_worker.dart';
import 'plugin_http_client.dart';
import 'qq_direct_fallback.dart';

/// 单次播放解析超时 30s：多供应商插件需留足预算
const int _mediaSourceTimeoutMs = 30000;
const Duration _mediaSourceTimeout =
    Duration(milliseconds: _mediaSourceTimeoutMs);

/// 详情补全超时：最佳努力，超时返回 null 并直接走播放解析
const int _musicInfoTimeoutMs = 10000;
const Duration _musicInfoTimeout =
    Duration(milliseconds: _musicInfoTimeoutMs);

/// 榜单详情可能涉及多次串行请求，超时放宽到 60s
const int _topListDetailTimeoutMs = 60000;
const Duration _topListDetailTimeout =
    Duration(milliseconds: _topListDetailTimeoutMs);

const Duration _defaultInvokeTimeout = Duration(seconds: 30);

const int _maxInt64 = 0x7FFFFFFFFFFFFFFF;

void _logPlugin(String message, {bool warn = false}) {
  developer.log(message, name: 'BakaPlugin', level: warn ? 900 : 500);
}

int _levelOf(String level) {
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

void _forwardWorkerLog(String level, String message) {
  developer.log(message, name: 'BakaPlugin', level: _levelOf(level));
}

bool _isBlank(String value) => value.trim().isEmpty;

/// ifBlank 语义：值为空白时取 fallback，否则保留原值（不裁剪空白）
String _fallbackBlank(String value, String fallback) =>
    _isBlank(value) ? fallback : value;

/// 逐个取第一个非空白候选，全部空白返回空串（不裁剪返回的候选）
String _firstNonBlank(List<String> values) {
  for (final value in values) {
    if (!_isBlank(value)) return value;
  }
  return '';
}

/// 逐个取第一个 trim 后非空的候选，全部为空返回空串（返回 trim 结果）
String _firstTrimmedNonBlank(List<String> values) {
  for (final value in values) {
    final trimmed = value.trim();
    if (trimmed.isNotEmpty) return trimmed;
  }
  return '';
}

String _optString(Object? value) {
  if (value == null) return '';
  if (value is String) return value;
  return '$value';
}

/// 不区分大小写，其余返回缺省值
bool _optBool(Object? value, bool fallback) {
  if (value is bool) return value;
  if (value is String) {
    final lower = value.toLowerCase();
    if (lower == 'true') return true;
    if (lower == 'false') return false;
  }
  return fallback;
}

int? _optInt(Object? value) {
  if (value is num) return value.toInt();
  if (value is String) return double.tryParse(value)?.toInt();
  return null;
}

double? _optDouble(Object? value) {
  if (value is num) return value.toDouble();
  if (value is String) return double.tryParse(value);
  return null;
}

/// http(s) 开头判定
String? _httpUrl(String value) =>
    value.toLowerCase().startsWith('http') ? value : null;

final RegExp _scientificNumberRegExp =
    RegExp(r'^[0-9]+(\.[0-9]+)?[eE][+-]?[0-9]+$');
final RegExp _trailingZeroDecimalRegExp = RegExp(r'^[0-9]+\.0+$');
final RegExp _scientificSplitRegExp =
    RegExp(r'^([+-]?)(\d+)(?:\.(\d+))?[eE]([+-]?\d+)$');
final RegExp _trailingZerosRegExp = RegExp(r'0+$');
final RegExp _trailingDotRegExp = RegExp(r'\.$');

/// 展开科学计数法为纯十进制文本
String _plainDecimal(String text) {
  final match = _scientificSplitRegExp.firstMatch(text);
  if (match == null) return text;
  final sign = match.group(1) ?? '';
  final intPart = match.group(2)!;
  final fracPart = match.group(3) ?? '';
  final exponent = int.parse(match.group(4)!);
  final digits = '$intPart$fracPart';
  final pointIndex = intPart.length + exponent;
  String body;
  if (pointIndex <= 0) {
    body = '0.${'0' * -pointIndex}$digits';
  } else if (pointIndex >= digits.length) {
    body = '$digits${'0' * (pointIndex - digits.length)}';
  } else {
    body =
        '${digits.substring(0, pointIndex)}.${digits.substring(pointIndex)}';
  }
  return '$sign$body';
}

String _plainNumber(String text) {
  var plain = _plainDecimal(text);
  if (plain.contains('.')) {
    plain = plain.replaceFirst(_trailingZerosRegExp, '');
    plain = plain.replaceFirst(_trailingDotRegExp, '');
    if (plain.isEmpty) return '0';
  }
  return plain;
}

/// JS 数值经 QuickJS→JSON 桥接后，大 id 会变成 Double，
/// optString/toString 会得到科学计数法（如 3.342319503E9）或带 .0 后缀，
/// 此处统一还原为纯整数文本；hash 等非纯数字标识不受影响。
String normalizePluginId(Object? raw) {
  if (raw == null) return '';
  if (raw is bool) return '$raw';
  if (raw is int) return raw.toString();
  if (raw is double) return _plainNumber('$raw');
  final text = '$raw'.trim();
  if (text.isEmpty) return '';
  if (_scientificNumberRegExp.hasMatch(text)) {
    return _plainNumber(text);
  }
  if (_trailingZeroDecimalRegExp.hasMatch(text)) {
    return text.substring(0, text.indexOf('.'));
  }
  return text;
}

const List<String> _idFieldKeys = [
  'id',
  'songmid',
  'songid',
  'mid',
  'copyrightId',
  'albumId',
  'album_id',
];

/// 修复回传 JSON 中易被科学计数法污染的歌曲标识字段（含已持久化的旧快照）
void normalizeIdFields(Map<String, dynamic> obj) {
  for (final key in _idFieldKeys) {
    if (!obj.containsKey(key) || obj[key] == null) continue;
    final fixed = normalizePluginId(obj[key]);
    if (fixed.isNotEmpty) obj[key] = fixed;
  }
}

/// 回传 id 恢复数字类型：插件原始 JSON 中的数字 id 经桥接全变字符串，
/// 而 QQ 等接口对 songID 做严格类型校验（字符串直接报 10006），
/// 导致新歌词接口失败并降级到无逐字的旧接口，
/// 此处对纯整数 id 同样放回数字（其余保持字符串，避免前导零等变形）
void putPluginId(Map<String, dynamic> obj, String id) {
  final number = int.tryParse(id);
  if (number != null && number >= 0 && (id == '0' || !id.startsWith('0'))) {
    obj['id'] = number;
  } else {
    obj['id'] = id;
  }
}

/// 备用 CDN：主源 403/断连时播放器侧自动切换
List<String> parseBackupUrls(Map<String, dynamic> obj) {
  final urls = <String>[];
  void addUrl(Object? value) {
    if (value is String && value.toLowerCase().startsWith('http')) {
      if (!urls.contains(value)) urls.add(value);
    }
  }

  for (final field in [obj['backupUrls'], obj['backupUrl']]) {
    if (field is List) {
      for (final item in field) {
        addUrl(item);
      }
    } else if (field is String) {
      addUrl(field);
    }
  }
  return urls.take(3).toList();
}

/// 新音质→旧插件兼容音质键，旧插件无此概念时返回 null。
String? legacyQualityOf(String key) {
  switch (key) {
    case '96k':
    case '128k':
      return 'low';
    case '192k':
      return 'standard';
    case '320k':
      return 'high';
    case 'flac':
    case 'flac24bit':
    case 'hires':
    case 'vinyl':
    case 'dolby':
    case 'atmos':
    case 'atmos_plus':
    case 'master':
      return 'super';
    default:
      return null;
  }
}

Map<String, dynamic> _rawJsonObject(String? rawJson) {
  if (rawJson == null) return <String, dynamic>{};
  try {
    final decoded = jsonDecode(rawJson);
    if (decoded is Map) return Map<String, dynamic>.from(decoded);
  } catch (_) {}
  return <String, dynamic>{};
}

/// 榜单条目回传插件：保留原始字段供插件定位榜单
Map<String, dynamic> topListJson(TopListItem item, String platformName) {
  final obj = _rawJsonObject(item.rawJson);
  normalizeIdFields(obj);
  putPluginId(obj, _fallbackBlank(normalizePluginId(item.id), item.id));
  obj['platform'] = _fallbackBlank(item.platform, platformName);
  obj['title'] = item.title;
  if (!obj.containsKey('coverImg') && item.coverImg != null) {
    obj['coverImg'] = item.coverImg;
  }
  if (!obj.containsKey('description') && !_isBlank(item.description)) {
    obj['description'] = item.description;
  }
  return obj;
}

/// 条目回传插件：原始字段 + 关键标识与时长补全
Map<String, dynamic> itemJson(MediaItem item) {
  final obj = _rawJsonObject(item.rawJson);
  normalizeIdFields(obj);
  putPluginId(obj, _fallbackBlank(normalizePluginId(item.id), item.id));
  obj['platform'] = item.platform;
  obj['title'] = item.title;
  obj['artist'] = item.artist;
  obj['album'] = item.album;
  // 补充秒级单位的 duration 字段，确保 rawJson 缺失时插件仍可获取时长
  if (!obj.containsKey('duration') && item.durationMs > 0) {
    obj['duration'] = item.durationMs ~/ 1000;
  }
  if (!obj.containsKey('durationMs') && item.durationMs > 0) {
    obj['durationMs'] = item.durationMs;
  }
  return obj;
}

String _encodedRaw(Map<String, dynamic> obj) {
  normalizeIdFields(obj);
  try {
    return jsonEncode(obj);
  } catch (_) {
    return '$obj';
  }
}

/// 插件返回 JSON → MediaItem
MediaItem toMedia(Map<String, dynamic> obj, String platformName) {
  final qualities = <String, QualityInfo>{};
  final rawQualities = obj['qualities'];
  if (rawQualities is Map) {
    for (final entry in rawQualities.entries) {
      final info = entry.value;
      if (info is! Map) continue;
      final size = _optInt(info['size']);
      final bitrate = _optInt(info['bitrate']);
      qualities['${entry.key}'] = QualityInfo(
        size: (size != null && size > 0) ? size : null,
        bitrate: (bitrate != null && bitrate > 0) ? bitrate : null,
        url: _httpUrl(_optString(info['url'])),
      );
    }
  }
  final duration = _optDouble(obj['duration']) ?? 0;
  final backups = parseBackupUrls(obj);
  // 封面统一去除首尾空白，避免空白导致图片加载失败
  final artwork = _firstTrimmedNonBlank([
    _optString(obj['artwork']),
    _optString(obj['coverImg']),
    _optString(obj['cover']),
  ]);
  return MediaItem(
    id: _firstNonBlank([
      normalizePluginId(obj['id']),
      normalizePluginId(obj['songmid']),
      normalizePluginId(obj['songid']),
    ]),
    platform: _fallbackBlank(_optString(obj['platform']), platformName),
    title: _fallbackBlank(_optString(obj['title']), _optString(obj['songname'])),
    artist:
        _fallbackBlank(_optString(obj['artist']), _optString(obj['singer'])),
    album: _fallbackBlank(_optString(obj['album']), _optString(obj['albumname'])),
    artwork: artwork.isEmpty ? null : artwork,
    durationMs: duration > 10000 ? duration.toInt() : (duration * 1000).toInt(),
    mediaUrl: _httpUrl(_optString(obj['url'])),
    qualities: qualities,
    rawJson: _encodedRaw(obj),
    backupUrls: backups,
  );
}

/// 歌词文本归一化：去除回车符，展开字面量换行符
String? normalizeLyric(String? text) {
  if (text == null) return null;
  final normalized = text
      .replaceAll('\r', '')
      .replaceAll('\\r\\n', '\n')
      .replaceAll('\\n', '\n')
      .replaceAll('\\r', '\n');
  return _isBlank(normalized) ? null : normalized;
}

bool _isAllDigits(String value) =>
    value.codeUnits.every((code) => code >= 0x30 && code <= 0x39);

/// 取歌词字段：字符映射对象按数字键排序还原，数组按行拼接，其余对象丢弃
String? lyricString(Map<String, dynamic> value, String key) {
  final raw = value[key];
  if (raw == null) return null;
  if (raw is String) return _isBlank(raw) ? null : raw;
  if (raw is List) {
    final lines = <String>[];
    for (final item in raw) {
      if (item == null) continue;
      if (item is! String) continue;
      if (!_isBlank(item)) lines.add(item);
    }
    final joined = lines.join('\n');
    return _isBlank(joined) ? null : joined;
  }
  if (raw is Map) {
    final keys = raw.keys.map((key) => '$key').toList();
    // 字符映射：键均为数字
    if (keys.isNotEmpty && keys.every(_isAllDigits)) {
      final indexed = List<int>.generate(keys.length, (index) => index);
      indexed.sort((a, b) {
        final va = int.tryParse(keys[a]) ?? _maxInt64;
        final vb = int.tryParse(keys[b]) ?? _maxInt64;
        final cmp = va.compareTo(vb);
        return cmp != 0 ? cmp : a.compareTo(b);
      });
      final joined = indexed.map((index) => _optString(raw[keys[index]])).join();
      return _isBlank(joined) ? null : joined;
    }
    // 其余对象不是歌词，不序列化为 JSON 文本，直接丢弃
    return null;
  }
  return null;
}

/// 基于 QuickJS 的 MusicPlugin 实现
class QuickJsMusicPlugin implements MusicPlugin {
  QuickJsMusicPlugin._(
    this._worker, {
    required this.id,
    required this.name,
    this.version,
  }) : _platformName = name;

  final PluginWorker _worker;

  /// 安装插件 id（用于插件管理）
  final String id;

  /// 安装插件显示名
  final String name;

  @override
  final String? version;
  String _platformName;
  Set<String> _qualities = const <String>{};
  bool _closed = false;
  bool _mediaInFlight = false;
  PluginHttpClient? _ownerHttp;

  @override
  String get platform => _platformName;

  @override
  Set<String> get supportedQualities => _qualities;

  void _applyLoadResult(PluginLoadResult result) {
    _platformName =
        result.platform.trim().isEmpty ? name : result.platform;
    _qualities = result.qualities.toSet();
  }

  void _log(String message, {bool warn = false}) {
    _logPlugin(message, warn: warn);
  }

  /// 统一调用入口：返回插件 JSON 对象，实例过期抛 [StalePluginException]。
  Future<Map<String, dynamic>> _invoke(
    String method,
    List<Object?> args, {
    Duration timeout = _defaultInvokeTimeout,
  }) async {
    if (_closed) {
      throw StalePluginException('$_platformName 运行时已重载');
    }
    String text;
    try {
      text = await _worker.invoke(method, jsonEncode(args), timeout: timeout);
    } on PluginWorkerTimeoutException {
      // 超时同样取消在途请求
      _worker.cancel();
      rethrow;
    } on PluginJsErrorException {
      rethrow;
    } on PluginWorkerException {
      // worker 已停止等基础设施错误：按过期实例处理，由上层重新加载
      _closed = true;
      throw StalePluginException('$_platformName 运行时已重载');
    }
    final decoded = jsonDecode(text);
    if (decoded is Map) return Map<String, dynamic>.from(decoded);
    return <String, dynamic>{};
  }

  @override
  Future<SearchPage<MediaItem>> search(String query, int page) async {
    // 首次失败后延时重试一次，仍失败则抛出至上层展示
    Map<String, dynamic> value;
    try {
      value = await _invoke('search', [query, page, 'music']);
    } on PluginCanceledException {
      rethrow;
    } on PluginWorkerTimeoutException {
      rethrow;
    } catch (error) {
      _log('$_platformName.search 第1次失败，1.2s后重试: $error', warn: true);
      await Future<void>.delayed(const Duration(milliseconds: 1200));
      value = await _invoke('search', [query, page, 'music']);
    }
    final data = value['data'];
    final items = <MediaItem>[];
    if (data is List) {
      for (final entry in data) {
        if (entry is Map) {
          items.add(toMedia(Map<String, dynamic>.from(entry), _platformName));
        }
      }
    }
    return SearchPage<MediaItem>(
      data: items,
      isEnd: _optBool(value['isEnd'], true),
    );
  }

  /// 榜单分组（对应 getTopLists）：顶层数组读取 data，失败时返回空列表
  @override
  Future<List<TopListGroup>> topLists() async {
    Map<String, dynamic> value;
    try {
      value = await _invoke('getTopLists', const []);
    } catch (_) {
      return const [];
    }
    final groups = value['data'];
    if (groups is! List) return const [];
    final out = <TopListGroup>[];
    for (final entry in groups) {
      if (entry is! Map) continue;
      final group = Map<String, dynamic>.from(entry);
      final groupTitle = _optString(group['title']);
      final items = group['data'];
      if (items is! List) continue;
      final list = <TopListItem>[];
      for (final itemEntry in items) {
        if (itemEntry is! Map) continue;
        final item = _toTopList(Map<String, dynamic>.from(itemEntry), groupTitle);
        if (item != null) list.add(item);
      }
      out.add(TopListGroup(title: groupTitle, items: list));
    }
    final boards = out.fold<int>(0, (sum, group) => sum + group.items.length);
    if (boards == 0) {
      _log(
        '$_platformName.getTopLists 空榜单: groups=${out.length} '
        'rawKeys=${value.keys.toList()}',
        warn: true,
      );
    } else {
      _log('$_platformName.getTopLists: groups=${out.length} boards=$boards');
    }
    return out;
  }

  TopListItem? _toTopList(Map<String, dynamic> obj, String groupTitle) {
    final idFirst = normalizePluginId(obj['id']);
    final idSecond = normalizePluginId(obj['songid']);
    var id = idFirst;
    if (_isBlank(id)) id = idSecond;
    if (_isBlank(id)) {
      final topId = _optString(obj['topId']);
      id = topId == '0' ? '' : topId;
    }
    if (_isBlank(id)) return null;
    final cover = _firstNonBlank([
      _optString(obj['coverImg']),
      _optString(obj['artwork']),
      _optString(obj['cover']),
      _optString(obj['pic']),
    ]);
    return TopListItem(
      id: id,
      platform: _fallbackBlank(_optString(obj['platform']), _platformName),
      title: _fallbackBlank(_optString(obj['title']), _optString(obj['name'])),
      description: _fallbackBlank(
        _optString(obj['description']),
        _optString(obj['intro']),
      ),
      coverImg: cover.isEmpty ? null : cover,
      groupTitle: groupTitle,
      rawJson: _encodedRaw(obj),
    );
  }

  /// 榜单详情（对应 getTopListDetail）：兼容扁平与嵌套两种响应结构
  @override
  Future<SearchPage<MediaItem>> topListDetail(
    TopListItem item, [
    int page = 1,
  ]) async {
    final value = await _invoke(
      'getTopListDetail',
      [topListJson(item, _platformName), page],
      timeout: _topListDetailTimeout,
    );
    List<dynamic>? musicArray;
    final rawMusicList = value['musicList'];
    if (rawMusicList is List) musicArray = rawMusicList;
    if (musicArray == null) {
      final nested = value['topListItem'];
      if (nested is Map && nested['musicList'] is List) {
        musicArray = nested['musicList'] as List;
      }
    }
    if (musicArray == null) {
      final rawData = value['data'];
      if (rawData is List) musicArray = rawData;
    }
    final songs = <MediaItem>[];
    if (musicArray != null) {
      for (final entry in musicArray) {
        if (entry is Map) {
          songs.add(toMedia(Map<String, dynamic>.from(entry), _platformName));
        }
      }
    }
    final noCover = songs.where((song) => _isBlank(song.artwork ?? '')).length;
    _log(
      '$_platformName.getTopListDetail: board=${item.title} '
      'songs=${songs.length} noCover=$noCover',
    );
    return SearchPage<MediaItem>(
      data: songs,
      isEnd: _optBool(value['isEnd'], true),
    );
  }

  /// 歌曲详情补全：qualities 为空的搜索项在播放/下载前先取详情，
  /// 否则音质选择器只能看到 320k 且降级顺序失去依据。超时或失败返回 null
  @override
  Future<MediaItem?> getMusicInfo(MediaItem item) async {
    Map<String, dynamic> value;
    try {
      value = await _invoke(
        'getMusicInfo',
        [itemJson(item)],
        timeout: _musicInfoTimeout,
      );
    } on PluginCanceledException {
      rethrow;
    } catch (_) {
      return null;
    }
    if (value.isEmpty || value.containsKey('__error')) return null;
    final enriched = toMedia(value, _platformName);
    if (_isBlank(enriched.id)) return null;
    // 详情为主、旧 rawJson 补漏：bvid/aid/cid/pages 等别名字段缺一不可，否则 getMediaSource 定位失败
    final mergedRaw = Map<String, dynamic>.from(value);
    final oldRaw = _rawJsonObjectOrNull(item.rawJson);
    if (oldRaw != null) {
      for (final entry in oldRaw.entries) {
        if (!mergedRaw.containsKey(entry.key)) {
          mergedRaw[entry.key] = entry.value;
        }
      }
    }
    normalizeIdFields(mergedRaw);
    putPluginId(mergedRaw, _fallbackBlank(normalizePluginId(item.id), item.id));
    return item.copyWith(
      artwork: enriched.artwork ?? item.artwork,
      durationMs: enriched.durationMs > 0 ? enriched.durationMs : item.durationMs,
      qualities:
          enriched.qualities.isNotEmpty ? enriched.qualities : item.qualities,
      backupUrls: enriched.backupUrls.isNotEmpty
          ? enriched.backupUrls
          : item.backupUrls,
      rawJson: jsonEncode(mergedRaw),
    );
  }

  @override
  Future<MediaItem?> getMediaSource(MediaItem item, String quality) async {
    final resolved = await getMediaSourceDetailed(item, quality);
    return resolved?.$1;
  }

  @override
  Future<(MediaItem, String)?> getMediaSourceDetailed(
    MediaItem item,
    String quality,
  ) async {
    _preemptMediaCalls();
    final payload = itemJson(item);
    Map<String, dynamic>? value;
    _mediaInFlight = true;
    try {
      try {
        var result = await _invoke(
          'getMediaSource',
          [payload, quality],
          timeout: _mediaSourceTimeout,
        );
        // 旧插件仅认识 low/standard/high/super：新音质键无结果时回退一次
        if (_isBlank(_optString(result['url']))) {
          final legacy = legacyQualityOf(quality);
          if (legacy != null && legacy != quality) {
            try {
              result = await _invoke(
                'getMediaSource',
                [payload, legacy],
                timeout: _mediaSourceTimeout,
              );
            } on PluginWorkerTimeoutException {
              throw MediaResolveTimeoutException(_timeoutMessage(item, quality));
            } on PluginCanceledException {
              rethrow;
            } on StalePluginException {
              rethrow;
            } catch (error) {
              // 非 QQ 保持原行为：上抛由路由延时重试；QQ 则保留旧值走原生兜底
              if (!isQqPlatform(_platformName)) rethrow;
              _log(
                '$_platformName.getMediaSource 旧音质回退失败: $error',
                warn: true,
              );
            }
          }
        }
        value = result;
      } on PluginWorkerTimeoutException {
        throw MediaResolveTimeoutException(_timeoutMessage(item, quality));
      } on PluginCanceledException {
        rethrow;
      } on StalePluginException {
        rethrow;
      } catch (error) {
        // 非 QQ 保持原行为：上抛由路由延时重试一次；QQ 则转原生兜底
        if (!isQqPlatform(_platformName)) rethrow;
        _log('$_platformName.getMediaSource JS 失败，转原生兜底: $error', warn: true);
      }
    } finally {
      _mediaInFlight = false;
    }
    var url = value == null ? null : _httpUrl(_optString(value['url']));
    // QQ 原生兜底：不依赖插件文件内容，在线更新覆盖后依然有效
    if (url == null && isQqPlatform(_platformName)) {
      String? direct;
      try {
        direct = await qqDirectMediaUrl(item, payload, quality);
      } on PluginCanceledException {
        rethrow;
      } catch (error) {
        _log('$_platformName.getMediaSource 原生兜底异常: $error', warn: true);
      }
      if (direct != null) {
        _log('$_platformName.getMediaSource 原生兜底命中: quality=$quality');
        value = <String, dynamic>{'url': direct};
        url = direct;
      }
    }
    if (url == null) return null;
    final result = value;
    if (result == null) return null;
    // 当前客户端无法解密加密流（cek/ekey），返回 null，由路由继续尝试更低音质
    if (result.containsKey('cek') && !_isBlank(_optString(result['cek']))) {
      _log('$_platformName.getMediaSource 加密流跳过(cek): quality=$quality');
      return null;
    }
    if (result.containsKey('ekey') && !_isBlank(_optString(result['ekey']))) {
      _log('$_platformName.getMediaSource 加密流跳过(ekey): quality=$quality');
      return null;
    }
    final headers = <String, String>{};
    final rawHeaders = result['headers'];
    if (rawHeaders is Map) {
      for (final entry in rawHeaders.entries) {
        final headerValue = _optString(entry.value);
        if (!_isBlank(headerValue)) headers['${entry.key}'] = headerValue;
      }
    }
    final userAgent = _optString(result['userAgent']);
    if (!_isBlank(userAgent)) {
      headers.putIfAbsent('User-Agent', () => userAgent);
    }
    // 插件可能降级返回（如 bilibili 请求 flac 实际命中 320k）：以上报为准
    final reportedQuality = _optString(result['quality']).trim();
    final actualQuality = reportedQuality.isNotEmpty ? reportedQuality : quality;
    // 本次解析返回的备用 CDN 随条目透出，播放失败时自动切换
    final backups = parseBackupUrls(result);
    return (
      item.copyWith(
        mediaUrl: url,
        mediaHeaders: headers,
        backupUrls: backups.isNotEmpty ? backups : item.backupUrls,
      ),
      actualQuality,
    );
  }

  /// 取消本插件上一笔未完成的播放任务
  void _preemptMediaCalls() {
    if (!_mediaInFlight) return;
    _worker.cancel();
  }

  String _timeoutMessage(MediaItem item, String quality) =>
      '播放请求超时(${_mediaSourceTimeoutMs}ms): ${item.platform}:${item.id} $quality';

  @override
  Future<LyricSource?> getLyric(MediaItem item) async {
    final value = await _invoke('getLyric', [itemJson(item)]);
    if (value.isEmpty || value.containsKey('__error')) return null;
    // 歌词字段可能是 URL、纯文本、QRC 或字符映射对象，需分别处理；
    // 仅接收字符串，并按映射或数组展开，避免将对象直接序列化为 JSON 文本展示
    var raw = normalizeLyric(lyricString(value, 'rawLrc'));
    String? lrcUrl;
    final lrc = lyricString(value, 'lrc');
    if (lrc != null) {
      if (lrc.trimLeft().toLowerCase().startsWith('http')) {
        lrcUrl = lrc.trim();
      } else if (raw == null || _isBlank(raw)) {
        raw = normalizeLyric(lrc);
      }
    }
    if ((raw == null || _isBlank(raw)) && lrcUrl != null) {
      final text = await _fetchOwnerText(lrcUrl);
      raw = normalizeLyric(text != null && !_isBlank(text) ? text : null);
    }
    final translation = normalizeLyric(lyricString(value, 'translation'));
    final romanization = normalizeLyric(lyricString(value, 'romanization'));
    // raw 为空时以翻译或罗马音作为后备，避免显示暂无歌词
    var finalRaw = raw;
    if (finalRaw == null || _isBlank(finalRaw)) {
      finalRaw = translation ?? romanization;
    }
    final hasAny = (finalRaw != null && !_isBlank(finalRaw)) ||
        (translation != null && !_isBlank(translation)) ||
        (romanization != null && !_isBlank(romanization));
    if (!hasAny) return null;
    return LyricSource(
      rawLrc: finalRaw,
      translation: translation,
      romanization: romanization,
      format: _fallbackBlank(_optString(value['format']), 'lrc'),
    );
  }

  /// lrc 为 URL 时同步请求一次纯文本歌词（5s 超时，2MiB 上限）
  Future<String?> _fetchOwnerText(String url) async {
    try {
      final client = _ownerHttp ??= PluginHttpClient(platformName: _platformName);
      return await client.fetchText(url);
    } catch (_) {
      return null;
    }
  }

  @override
  Future<PlaylistSnapshot?> importMusicSheet(String urlLike) async {
    Map<String, dynamic> value;
    try {
      value = await _invoke('importMusicSheet', [urlLike]);
    } on PluginCanceledException {
      rethrow;
    } on PluginWorkerTimeoutException {
      rethrow;
    } catch (error) {
      _log('$_platformName.importMusicSheet 失败: $error');
      return null;
    }
    if (value.isEmpty || value.containsKey('__error')) return null;
    // 数组或对象统一归一为 PlaylistSnapshot
    List<dynamic>? musicArray;
    final rawMusicList = value['musicList'];
    if (rawMusicList is List) musicArray = rawMusicList;
    if (musicArray == null) {
      final rawData = value['data'];
      if (rawData is List) musicArray = rawData;
    }
    if (musicArray == null) {
      final rawSongs = value['songs'];
      if (rawSongs is List) musicArray = rawSongs;
    }
    final songs = <MediaItem>[];
    if (musicArray != null) {
      for (final entry in musicArray) {
        if (entry is Map) {
          songs.add(toMedia(Map<String, dynamic>.from(entry), _platformName));
        }
      }
    }
    if (songs.isEmpty) return null;
    final id = _firstNonBlank([
      _optString(value['id']),
      _optString(value['dissid']),
      urlLike,
    ]);
    final title = _firstNonBlank([
      _optString(value['title']),
      _optString(value['dissname']),
      _optString(value['dirname']),
      '导入歌单',
    ]);
    final artist = _firstNonBlank([
      _optString(value['artist']),
      _optString(value['nickname']),
      _optString(value['creator']),
    ]);
    final artwork = _firstNonBlank([
      _optString(value['artwork']),
      _optString(value['logo']),
      _optString(value['picurl']),
      _optString(value['cover']),
    ]);
    return PlaylistSnapshot(
      id: id,
      platform: _fallbackBlank(_optString(value['platform']), _platformName),
      title: title,
      artist: artist.isEmpty ? null : artist,
      artwork: artwork.isEmpty ? null : artwork,
      musicList: songs,
    );
  }

  @override
  void cancelPendingRequests() {
    _worker.cancel();
  }

  /// 释放实例：关闭 owner 侧 HTTP 客户端与 worker
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    try {
      _ownerHttp?.close();
    } catch (_) {}
    _ownerHttp = null;
    await _worker.close();
  }
}

Map<String, dynamic>? _rawJsonObjectOrNull(String? rawJson) {
  if (rawJson == null) return null;
  try {
    final decoded = jsonDecode(rawJson);
    if (decoded is Map) return Map<String, dynamic>.from(decoded);
  } catch (_) {}
  return null;
}

/// 基于 QuickJS 的 MusicPlugin 运行时宿主：所有 JS 调用均在插件自己的
/// worker 内执行，单个插件失败不影响其它插件
class MusicPluginRuntime {
  final Map<String, QuickJsMusicPlugin> _active = {};

  /// 当前已加载插件（只读视图）
  List<QuickJsMusicPlugin> get activePlugins =>
      List.unmodifiable(_active.values);

  /// 加载插件源码；失败返回 null 并记录日志
  Future<QuickJsMusicPlugin?> loadPlugin({
    required String id,
    required String name,
    String? version,
    required String source,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final existing = _active.remove(id);
    if (existing != null) {
      await existing.close();
    }
    PluginWorker worker;
    try {
      worker = await PluginWorker.spawn();
    } catch (error) {
      developer.log(
        'QuickJS 加载失败: $name',
        name: 'BakaPlugin',
        level: 1000,
        error: error,
      );
      return null;
    }
    worker.onLog = _forwardWorkerLog;
    final instance = QuickJsMusicPlugin._(
      worker,
      id: id,
      name: name,
      version: version,
    );
    try {
      final result = await worker.load(name, source, timeout: timeout);
      instance._applyLoadResult(result);
      _active[id] = instance;
      return instance;
    } catch (error) {
      await worker.close();
      developer.log(
        'QuickJS 加载失败: $name',
        name: 'BakaPlugin',
        level: 1000,
        error: error,
      );
      return null;
    }
  }

  /// 终止所有插件未完成的网络请求
  void cancelPending() {
    for (final plugin in _active.values) {
      plugin.cancelPendingRequests();
    }
  }

  /// 释放全部插件实例
  Future<void> clear() => destroy();

  /// 释放全部插件实例
  Future<void> destroy() async {
    final instances = _active.values.toList();
    _active.clear();
    for (final instance in instances) {
      try {
        await instance.close();
      } catch (_) {}
    }
  }
}
