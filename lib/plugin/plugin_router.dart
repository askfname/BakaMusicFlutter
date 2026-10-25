/// 按音源优先级路由插件调用：
/// 已禁用与未注册的插件永不被调用
library;

import 'dart:developer' as developer;

import '../models/media_models.dart';
import 'js_worker.dart' show PluginCanceledException;
import 'lx_resolver.dart';
import 'plugin_manager.dart';

class PluginRouter {
  PluginRouter(this._manager);

  final PluginManager _manager;

  /// LX 取流解析器：已配置时具权威性
  LxResolver? lxResolver;

  final Map<String, MusicPlugin> _adapters = {};

  void register(InstalledPlugin plugin, MusicPlugin adapter) {
    if (!plugin.enabled) {
      throw ArgumentError('禁用的插件不能注册为音源');
    }
    _adapters[plugin.id] = adapter;
  }

  void unregister(String pluginId) {
    _adapters.remove(pluginId);
  }

  void clear() {
    _adapters.clear();
  }

  /// 切歌时立即终止各插件未完成的网络请求
  void cancelPendingRequests() {
    for (final adapter in _adapters.values.toList()) {
      try {
        adapter.cancelPendingRequests();
      } catch (_) {}
    }
  }

  /// 插件调用失败返回 null，取消与播放超时必须继续向上传播
  Future<T?> _runAbortable<T>(Future<T?> Function() block) async {
    try {
      return await block();
    } on PluginCanceledException {
      rethrow;
    } on MediaResolveTimeoutException {
      rethrow;
    } catch (_) {
      return null;
    }
  }

  /// 搜索项 qualities 为空时用 getMusicInfo 补全；
  /// 补全失败则回退用原条目直接解析，不阻塞播放
  Future<MediaItem> _maybeEnrich(MusicPlugin plugin, MediaItem item) async {
    if (item.qualities.isNotEmpty) return item;
    final enriched = await _runAbortable(() => plugin.getMusicInfo(item));
    if (enriched == null) return item;
    return enriched.qualities.isNotEmpty ? enriched : item;
  }

  /// 替换全量映射，调用方需保证串行调用
  void replaceAll(List<(InstalledPlugin, MusicPlugin)> entries) {
    _adapters.clear();
    for (final (meta, adapter) in entries) {
      if (meta.enabled) _adapters[meta.id] = adapter;
    }
  }

  /// 按平台名获取当前最新适配器，调用方不应长期持有返回的旧对象
  MusicPlugin? findAdapterByPlatform(String platform) =>
      _resolveAdapter(platform);

  MusicPlugin? findAdapterById(String id) {
    for (final plugin in _manager.plugins()) {
      if (plugin.id == id) return _adapters[id];
    }
    return null;
  }

  /// 注册名优先、运行时名兜底解析适配器
  MusicPlugin? _resolveAdapter(String platform) {
    for (final plugin in _manager.plugins()) {
      if (plugin.name == platform) {
        final adapter = _adapters[plugin.id];
        if (adapter != null) return adapter;
        break;
      }
    }
    for (final adapter in _activeAdapters()) {
      if (adapter.platform == platform) return adapter;
    }
    return null;
  }

  List<MusicPlugin> _activeAdapters() => [
    for (final plugin in _manager.plugins())
      if (_adapters[plugin.id] != null) _adapters[plugin.id]!,
  ];

  List<MusicPlugin> activeSources() => _activeAdapters();

  Future<SearchPage<MediaItem>> search(
    MusicPlugin plugin,
    String query, [
    int page = 1,
  ]) async {
    try {
      return await plugin.search(query, page);
    } on PluginCanceledException {
      rethrow;
    } catch (error) {
      developer.log(
        '${plugin.platform}.search failed: $error',
        name: 'BakaPlugin',
        level: 1000,
        error: error,
      );
      rethrow;
    }
  }

  /// 逐插件尝试搜索，首个有结果或标记结束的返回，全部失败返回空页
  Future<SearchPage<MediaItem>> searchAny(String query, [int page = 1]) async {
    for (final plugin in _activeAdapters()) {
      final res = await _runAbortable(() => plugin.search(query, page));
      if (res != null && (res.data.isNotEmpty || res.isEnd)) return res;
    }
    return const SearchPage<MediaItem>(data: []);
  }

  /// 指定平台榜单分组：无适配器或插件未实现时返回空列表
  Future<List<TopListGroup>> topLists(String platform) async {
    final plugin = _resolveAdapter(platform);
    if (plugin == null) return const [];
    try {
      return await plugin.topLists();
    } on PluginCanceledException {
      rethrow;
    } on StalePluginException {
      // 旧实例已释放时抛出至上层，由上层获取最新适配器重试一次
      rethrow;
    } catch (error) {
      developer.log(
        '${plugin.platform}.getTopLists failed: $error',
        name: 'BakaPlugin',
        level: 1000,
        error: error,
      );
      return const [];
    }
  }

  /// 指定平台榜单详情：仅请求当前平台插件，确保 id 体系一致
  Future<SearchPage<MediaItem>> topListDetail(
    String platform,
    TopListItem item, [
    int page = 1,
  ]) async {
    final plugin = _resolveAdapter(platform);
    if (plugin == null) return const SearchPage<MediaItem>(data: []);
    try {
      return await plugin.topListDetail(item, page);
    } on PluginCanceledException {
      rethrow;
    } catch (error) {
      developer.log(
        '${plugin.platform}.getTopListDetail failed: $error',
        name: 'BakaPlugin',
        level: 1000,
        error: error,
      );
      rethrow;
    }
  }

  Future<MediaItem?> resolveMedia(MediaItem item, MusicQuality quality) {
    return resolveMediaByKey(item, quality.key);
  }

  /// 单音质解析：失败延时重试一次，仍失败返回 null 由外层换下一档
  Future<MediaItem?> _resolveOne(
    MusicPlugin plugin,
    MediaItem item,
    String quality,
  ) async {
    final first = await _runAbortable(
      () => plugin.getMediaSource(item, quality),
    );
    if (first != null) return first;
    await Future<void>.delayed(const Duration(milliseconds: 200));
    return _runAbortable(() => plugin.getMediaSource(item, quality));
  }

  /// 单音质解析（带实际命中音质），语义同 resolveOne
  Future<(MediaItem, String)?> _resolveOneDetailed(
    MusicPlugin plugin,
    MediaItem item,
    String quality,
  ) async {
    final first = await _runAbortable(
      () => plugin.getMediaSourceDetailed(item, quality),
    );
    if (first != null) return first;
    await Future<void>.delayed(const Duration(milliseconds: 200));
    return _runAbortable(() => plugin.getMediaSourceDetailed(item, quality));
  }

  /// 按音质键解析：仅请求当前平台插件，不跨平台解析
  Future<MediaItem?> resolveMediaByKey(
    MediaItem item,
    String qualityKey,
  ) async {
    final plugin = findAdapterByPlatform(item.platform);
    if (plugin == null) {
      developer.log(
        '无当前平台适配器，拒绝解析: ${item.platform}:${item.id}',
        name: 'BakaPlugin',
        level: 500,
      );
      return null;
    }
    final current = await _maybeEnrich(plugin, item);
    final lx = lxResolver;
    if (lx != null) {
      final outcome = await lx.resolveDetailed(current, qualityKey);
      if (outcome is LxResolved) return outcome.media;
      // LX 失败则回退原生插件，权威语义仍优先 LX（命中即返回），仅在失败时继续走 JS
      if (outcome is LxFailed) {
        developer.log(
          '[LX] 回退原生插件 ${current.platform}:${current.id}',
          name: 'BakaPlugin',
          level: 500,
        );
      }
    }
    final tried = playbackQualityOrder(current, qualityKey);
    for (final quality in tried) {
      final res = await _resolveOne(plugin, current, quality);
      if (_isHttpUrl(res?.mediaUrl)) return res;
    }
    // 后备：使用 qualities 自带的 url
    return _qualitiesUrlFallback(current, qualityKey);
  }

  /// qualities 自带的直链后备
  MediaItem? _qualitiesUrlFallback(MediaItem item, String qualityKey) {
    final url = item.qualities[qualityKey]?.url;
    if (!_isHttpUrl(url)) return null;
    return item.copyWith(mediaUrl: url);
  }

  /// 原生单档直试（跳过 LX）：Source error 来自 LX 非音频 URL 时，
  /// 同档原生 URL 不同源，需优先直试而非直接降档
  Future<(MediaItem, String, String)?> resolveNativeDetailed(
    MediaItem item,
    String qualityKey,
  ) async {
    final plugin = findAdapterByPlatform(item.platform);
    if (plugin == null) return null;
    final current = await _maybeEnrich(plugin, item);
    final res = await _resolveOneDetailed(plugin, current, qualityKey);
    if (res != null && _isHttpUrl(res.$1.mediaUrl)) {
      developer.log(
        '解析命中 ${current.platform}:${current.id} '
        'quality=${res.$2}(requested=$qualityKey) via '
        '${plugin.platform}(native-retry)',
        name: 'BakaPlugin',
        level: 500,
      );
      return (res.$1, res.$2, '');
    }
    final url = current.qualities[qualityKey]?.url;
    if (_isHttpUrl(url)) {
      return (current.copyWith(mediaUrl: url), qualityKey, '');
    }
    return null;
  }

  /// 供播放调用：默认音质优先向更低音质降级
  Future<MediaItem?> resolveForPlayback(
    MediaItem item,
    String defaultQualityKey,
  ) {
    return resolveMediaByKey(item, defaultQualityKey);
  }

  /// 供播放调用（返回实际命中音质与取流来源标注，供播放栏显示），仅请求当前平台
  Future<(MediaItem, String, String)?> resolveForPlaybackDetailed(
    MediaItem item,
    String defaultQualityKey, {
    Set<String> excludeQualities = const {},
    bool cascade = true,
    void Function(String quality, int? size, String via)? onTrying,
  }) async {
    final plugin = findAdapterByPlatform(item.platform);
    if (plugin == null) {
      developer.log(
        '无当前平台适配器，拒绝解析: ${item.platform}:${item.id}',
        name: 'BakaPlugin',
        level: 500,
      );
      return null;
    }
    final current = await _maybeEnrich(plugin, item);
    final lx = lxResolver;
    if (lx != null) {
      final outcome = await lx.resolveDetailed(
        current,
        defaultQualityKey,
        exclude: excludeQualities,
        cascade: cascade,
        onTrying: onTrying,
      );
      if (outcome is LxResolved) {
        developer.log(
          '解析命中 ${current.platform}:${current.id} '
          'quality=${outcome.quality}(lx) via ${plugin.platform}',
          name: 'BakaPlugin',
          level: 500,
        );
        return (outcome.media, outcome.quality, outcome.via);
      }
      // LX 失败则回退原生插件，仅记录后继续走 JS 档位循环
      if (outcome is LxFailed) {
        developer.log(
          '[LX] 回退原生插件 ${current.platform}:${current.id} '
          'tried=lx excluded=$excludeQualities',
          name: 'BakaPlugin',
          level: 500,
        );
      }
    }
    // 手动切音质只试所选单档，不自动级联
    final tried = cascade
        ? playbackQualityOrder(current, defaultQualityKey)
        : <String>[defaultQualityKey];
    for (final quality in tried) {
      if (excludeQualities.contains(quality)) continue;
      // 上报当前尝试档，供界面实时跟随；原生档 via 置空（与 LX 档区分显示）
      onTrying?.call(quality, current.qualities[quality]?.size, '');
      final res = await _resolveOneDetailed(plugin, current, quality);
      if (res != null && _isHttpUrl(res.$1.mediaUrl)) {
        developer.log(
          '解析命中 ${current.platform}:${current.id} '
          'quality=${res.$2}(requested=$quality) via ${plugin.platform}',
          name: 'BakaPlugin',
          level: 500,
        );
        return (res.$1, res.$2, '');
      }
    }
    if (!excludeQualities.contains(defaultQualityKey)) {
      final url = current.qualities[defaultQualityKey]?.url;
      if (_isHttpUrl(url)) {
        return (current.copyWith(mediaUrl: url), defaultQualityKey, '');
      }
    }
    developer.log(
      '解析失败 ${current.platform}:${current.id} '
      'tried=$tried excluded=$excludeQualities',
      name: 'BakaPlugin',
      level: 500,
    );
    return null;
  }

  Future<LyricSource?> lyric(MediaItem item) async {
    // 仅请求当前平台插件，各平台 id 体系不同
    final plugin = findAdapterByPlatform(item.platform);
    if (plugin == null) {
      developer.log(
        '无当前平台适配器，跳过歌词: ${item.platform}:${item.id}',
        name: 'BakaPlugin',
        level: 500,
      );
      return null;
    }
    try {
      final res = await plugin.getLyric(item);
      if (res == null) {
        developer.log(
          '${plugin.platform}.lyric 空结果(id=${item.id})',
          name: 'BakaPlugin',
          level: 500,
        );
      }
      return res;
    } on PluginCanceledException {
      rethrow;
    } on MediaResolveTimeoutException {
      rethrow;
    } catch (error) {
      developer.log(
        '${plugin.platform}.lyric 失败(id=${item.id}): $error',
        name: 'BakaPlugin',
        level: 500,
      );
      return null;
    }
  }

  Future<PlaylistSnapshot?> importSheet(String urlLike) async {
    for (final plugin in _activeAdapters()) {
      final res = await _runAbortable(() => plugin.importMusicSheet(urlLike));
      if (res != null) return res;
    }
    return null;
  }
}

bool _isHttpUrl(String? url) =>
    url != null && url.toLowerCase().startsWith('http');
