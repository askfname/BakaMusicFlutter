/// LX 取流源模型：平台映射、脚本描述符、头注释元信息解析、声明源解析、音质覆盖与回退顺序
library;

import 'dart:convert';

import '../models/media_models.dart'
    show MediaItem, QualityInfo, qualityKeysOrdered;

/// LX 取流源
const List<String> lxSources = ['kw', 'kg', 'tx', 'wy', 'mg'];

/// 平台名→LX 源（匹配时不区分大小写）
const Map<String, List<String>> _lxPlatformNames = {
  'kw': ['酷我音乐', '酷我', 'Kuwo'],
  'kg': ['酷狗音乐', '酷狗', 'Kugou'],
  'tx': ['QQ音乐', 'QQ Music', 'Tencent'],
  'wy': ['网易云音乐', '网易云', 'NetEase Cloud Music', 'Netease'],
  'mg': ['咪咕音乐', '咪咕', 'Migu'],
};

/// 平台名→LX 源键，未匹配返回 null
String? lxSourceForPlatform(String platform) {
  final name = platform.trim().toLowerCase();
  for (final source in lxSources) {
    final names = _lxPlatformNames[source];
    if (names == null) continue;
    for (final candidate in names) {
      if (candidate.toLowerCase() == name) return source;
    }
  }
  return null;
}

/// 单个取流源声明：脚本可为该源提供的音质集合
class LxSourceDescriptor {
  const LxSourceDescriptor({this.qualities = const []});

  final List<String> qualities;

  Map<String, dynamic> toJson() => {'qualities': qualities};

  static LxSourceDescriptor fromJson(Map<String, dynamic> o) {
    final raw = o['qualities'];
    return LxSourceDescriptor(
      qualities: raw is List
          ? raw.whereType<String>().where((q) => q.isNotEmpty).toList()
          : const [],
    );
  }
}

/// LX 脚本描述符：注册表持久化与界面展示单元
class LxPluginDescriptor {
  const LxPluginDescriptor({
    required this.hash,
    required this.name,
    this.description = '',
    this.version = '',
    this.author = '',
    this.homepage = '',
    this.sourceUrl = '',
    this.sources = const {},
    this.active = false,
  });

  final String hash;
  final String name;
  final String description;
  final String version;
  final String author;
  final String homepage;

  /// 脚本下载地址（本地导入为空）
  final String sourceUrl;
  final Map<String, LxSourceDescriptor> sources;

  /// 是否当前生效的取流脚本
  final bool active;

  LxPluginDescriptor copyWith({
    String? hash,
    String? name,
    String? description,
    String? version,
    String? author,
    String? homepage,
    String? sourceUrl,
    Map<String, LxSourceDescriptor>? sources,
    bool? active,
  }) => LxPluginDescriptor(
    hash: hash ?? this.hash,
    name: name ?? this.name,
    description: description ?? this.description,
    version: version ?? this.version,
    author: author ?? this.author,
    homepage: homepage ?? this.homepage,
    sourceUrl: sourceUrl ?? this.sourceUrl,
    sources: sources ?? this.sources,
    active: active ?? this.active,
  );

  Map<String, dynamic> toJson() => {
    'hash': hash,
    'name': name,
    'description': description,
    'version': version,
    'author': author,
    'homepage': homepage,
    'sourceUrl': sourceUrl,
    'sources': sources.map((k, v) => MapEntry(k, v.toJson())),
    'active': active,
  };

  static LxPluginDescriptor fromJson(Map<String, dynamic> o) {
    final sources = <String, LxSourceDescriptor>{};
    final rawSources = o['sources'];
    if (rawSources is Map) {
      rawSources.forEach((key, value) {
        if (value is Map) {
          sources['$key'] = LxSourceDescriptor.fromJson(
            Map<String, dynamic>.from(value),
          );
        }
      });
    }
    return LxPluginDescriptor(
      hash: '${o['hash'] ?? ''}',
      name: '${o['name'] ?? ''}',
      description: '${o['description'] ?? ''}',
      version: '${o['version'] ?? ''}',
      author: '${o['author'] ?? ''}',
      homepage: '${o['homepage'] ?? ''}',
      sourceUrl: '${o['sourceUrl'] ?? ''}',
      sources: sources,
      active: o['active'] == true,
    );
  }
}

/// 脚本头注释元信息
class LxScriptInfo {
  const LxScriptInfo({
    required this.name,
    this.description = '',
    this.version = '',
    this.author = '',
    this.homepage = '',
  });

  final String name;
  final String description;
  final String version;
  final String author;
  final String homepage;

  Map<String, dynamic> toJson() => {
    'name': name,
    'description': description,
    'version': version,
    'author': author,
    'homepage': homepage,
  };

  static LxScriptInfo fromJson(Map<String, dynamic> o) => LxScriptInfo(
    name: '${o['name'] ?? ''}',
    description: '${o['description'] ?? ''}',
    version: '${o['version'] ?? ''}',
    author: '${o['author'] ?? ''}',
    homepage: '${o['homepage'] ?? ''}',
  );
}

/// 解析脚本头注释元信息：首个块注释内 `@key value` 行，键不区分大小写
LxScriptInfo parseLxScriptInfo(String code, String fallbackName) {
  final values = <String, String>{};
  final header = RegExp(r'^\uFEFF?\s*/\*([\s\S]*?)\*/').firstMatch(code);
  if (header != null) {
    final line = RegExp(r'^\s*\*?\s*@([A-Za-z]+)\s+(.+?)\s*$', multiLine: true);
    for (final match in line.allMatches(header.group(1)!)) {
      final key = match.group(1)!.toLowerCase();
      final value = match.group(2)!.trim();
      if (value.isNotEmpty) values[key] = value;
    }
  }
  String pick(String key) => values[key]?.trim() ?? '';
  final name = pick('name');
  return LxScriptInfo(
    name: name.isEmpty ? fallbackName : name,
    description: pick('description'),
    version: pick('version'),
    author: pick('author'),
    homepage: pick('homepage'),
  );
}

/// 解析脚本 `inited` 声明的取流源：仅收录音乐源、声明了 musicUrl 动作
/// 且音质与客户端音质档位有交集的条目
Map<String, LxSourceDescriptor> parseLxSourcesDeclared(
  Map<String, dynamic>? declared,
) {
  final out = <String, LxSourceDescriptor>{};
  final sources = declared?['sources'];
  if (sources is! Map) return out;
  final allowed = qualityKeysOrdered.toSet();
  for (final source in lxSources) {
    final entry = sources[source];
    if (entry is! Map) continue;
    if ('${entry['type'] ?? ''}' != 'music') continue;
    final actions = entry['actions'];
    if (actions is! List || !actions.any((action) => '$action' == 'musicUrl')) {
      continue;
    }
    final rawQualities = entry['qualitys'] is List
        ? entry['qualitys']
        : entry['qualities'];
    if (rawQualities is! List) continue;
    final qualities = <String>[];
    for (final raw in rawQualities) {
      final key = '$raw'.trim();
      if (allowed.contains(key) && !qualities.contains(key)) qualities.add(key);
    }
    if (qualities.isEmpty) continue;
    out[source] = LxSourceDescriptor(qualities: qualities);
  }
  return out;
}

/// LX 降级顺序：本档起逐级向低，仅保留声明支持的音质；
/// 未知音质仅在其被声明支持时返回自身
List<String> lxQualityFallbacks(String requested, Set<String> override) {
  final index = qualityKeysOrdered.indexOf(requested);
  if (index < 0) return override.contains(requested) ? [requested] : const [];
  final out = <String>[];
  final ladder = [requested, ...qualityKeysOrdered.sublist(0, index).reversed];
  for (final key in ladder) {
    if (override.contains(key)) out.add(key);
  }
  return out;
}

/// 以 LX 音质集重写条目 qualities：useSupported 时取脚本声明全集，
/// 否则仅保留条目本身已有的档位；已存在的档位保真大小/码率
MediaItem replaceLxMusicQualities(
  MediaItem item,
  Set<String> override,
  bool useSupported,
) {
  final List<String> keys;
  if (item.qualities.isNotEmpty) {
    keys = useSupported
        ? override.toList()
        : [
            for (final key in override)
              if (item.qualities.containsKey(key)) key,
          ];
  } else {
    keys = useSupported ? override.toList() : const [];
  }
  return item.copyWith(
    qualities: {
      for (final key in keys) key: item.qualities[key] ?? const QualityInfo(),
    },
  );
}

/// 组装 LX 脚本入参 musicInfo：原始字段 + 归一化标识/音质/元信息
Map<String, dynamic> toLxMusicInfo(String source, MediaItem item) {
  final raw = _rawJsonObject(item.rawJson);
  final rawQualities = raw['qualities'] is Map
      ? Map<String, dynamic>.from(raw['qualities'] as Map)
      : <String, dynamic>{};

  String? top(List<String> keys) {
    for (final key in keys) {
      final value = '${raw[key] ?? ''}'.trim();
      if (value.isNotEmpty) return value;
    }
    return null;
  }

  String str(List<String> keys) => top(keys) ?? '';

  // hash 兜底仅在酷狗源生效
  String? qHash(String quality) {
    final declared = rawQualities[quality];
    if (declared is Map) {
      final hash = '${declared['hash'] ?? ''}'.trim();
      if (hash.isNotEmpty) return hash;
    }
    if (source != 'kg') return null;
    return switch (quality) {
      '320k' => top(['320hash', 'hash', 'id']),
      'flac' || 'flac24bit' => top(['sqhash', 'hash', 'id']),
      'hires' || 'master' => top(['ResFileHash', 'sqhash', 'hash', 'id']),
      _ => top(['hash', 'id']),
    };
  }

  final types = <Map<String, dynamic>>[];
  final qualityMap = <String, dynamic>{};
  for (final entry in rawQualities.entries) {
    final quality = entry.key;
    final info = entry.value;
    if (info is! Map) continue;
    final size = info.containsKey('size') && info['size'] != null
        ? '${info['size']}'
        : null;
    final hash = qHash(quality);
    types.add(<String, dynamic>{'type': quality, 'size': size, 'hash': ?hash});
    qualityMap[quality] = <String, dynamic>{'size': size, 'hash': ?hash};
  }

  final songId = switch (source) {
    'tx' => str(['songmid', 'mid', 'id']),
    'kg' => str(['songmid', 'audio_id', 'album_audio_id', 'id']),
    'mg' => str(['songmid', 'songId', 'id']),
    _ => str(['songmid', 'id']),
  };
  final albumName = str(['album', 'albumName']);
  final albumId = str(['albumId', 'album_id', 'albumid']);
  final rawArtwork = str(['artwork', 'img']);
  final artwork = rawArtwork.isNotEmpty ? rawArtwork : (item.artwork ?? '');

  final meta = <String, dynamic>{
    'songId': songId,
    'albumName': albumName,
    'albumId': albumId,
    'picUrl': artwork,
    'qualitys': types,
    '_qualitys': qualityMap,
  };
  if (source == 'kg') {
    meta['hash'] = str(['hash', 'id']);
  }
  if (source == 'tx') {
    meta['strMediaMid'] = str([
      'strMediaMid',
      'mediaMid',
      'songmid',
      'mid',
      'id',
    ]);
    meta['albumMid'] = str(['albumMid', 'albummid']);
    meta['id'] = str(['songId', 'id']);
  }
  if (source == 'mg') {
    meta['copyrightId'] = str(['copyrightId', 'id']);
    meta['lrcUrl'] = str(['lrcUrl', 'lrc']);
    meta['mrcUrl'] = str(['mrcUrl']);
    meta['trcUrl'] = str(['trcUrl']);
  }

  final totalSec = item.durationMs ~/ 1000;
  final interval = item.durationMs > 0
      ? '${(totalSec ~/ 60).toString().padLeft(2, '0')}:'
            '${(totalSec % 60).toString().padLeft(2, '0')}'
      : null;

  final out = <String, dynamic>{
    ...raw,
    'id': item.id,
    'name': item.title,
    'singer': item.artist,
    'source': source,
    'songmid': songId,
    'interval': interval,
    'albumName': albumName,
    'albumId': albumId,
    'img': artwork,
    'types': types,
    '_types': qualityMap,
    'typeUrl': <String, dynamic>{},
    'meta': meta,
  };
  if (source == 'kg') {
    out['hash'] = str(['hash', 'id']);
  }
  if (source == 'tx') {
    out['strMediaMid'] = meta['strMediaMid'] ?? '';
    out['albumMid'] = meta['albumMid'] ?? '';
    out['songId'] = meta['id'] ?? '';
  }
  if (source == 'mg') {
    out['copyrightId'] = meta['copyrightId'] ?? '';
    out['lrcUrl'] = meta['lrcUrl'] ?? '';
    out['mrcUrl'] = meta['mrcUrl'] ?? '';
    out['trcUrl'] = meta['trcUrl'] ?? '';
  }
  return out;
}

Map<String, dynamic> _rawJsonObject(String? rawJson) {
  if (rawJson == null || rawJson.isEmpty) return <String, dynamic>{};
  try {
    final decoded = jsonDecode(rawJson);
    if (decoded is Map) return Map<String, dynamic>.from(decoded);
  } catch (_) {}
  return <String, dynamic>{};
}

/// 当前生效脚本中声明了指定取流源的描述符，未激活或无声明返回 null
LxPluginDescriptor? activeLxPluginForSource(
  List<LxPluginDescriptor> descriptors,
  String? activeHash,
  String source,
) {
  if (activeHash == null || activeHash.isEmpty) return null;
  for (final descriptor in descriptors) {
    if (descriptor.hash == activeHash &&
        descriptor.sources.containsKey(source)) {
      return descriptor;
    }
  }
  return null;
}
