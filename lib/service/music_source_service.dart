import 'dart:async';
import 'dart:developer' as developer;
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../data/lx_models.dart';
import '../models/media_models.dart';
import '../plugin/lx_resolver.dart';
import '../plugin/lx_source_manager.dart';
import '../plugin/music_plugin_runtime.dart';
import '../plugin/plugin_manager.dart';
import '../plugin/plugin_router.dart';

/// 搜索、歌单导入、播放地址与歌词的统一入口
/// UI 与下载层应经由本服务调用，不直接选择插件；PluginRouter 按启用优先级路由
class MusicSourceService {
  MusicSourceService._(
    this._manager,
    this._runtime,
    this._lxManager,
    this._router,
  ) {
    _router.lxResolver = LxResolver(_lxManager);
    _live.add(WeakReference(this));
  }

  final PluginManager _manager;
  final MusicPluginRuntime _runtime;
  final LxSourceManager _lxManager;
  final PluginRouter _router;

  /// 已加载的注册表指纹：插件变更后下次调用自动重载
  bool _loaded = false;
  int _loadedVersion = -1;

  /// LX 注册表指纹
  int _loadedLxVersion = -1;

  /// 串行化加载：避免并发替换 QuickJS 上下文
  Future<void> _loadChain = Future<void>.value();

  /// 注册表代际：插件增删改/启停用/排序/LX 变更后推进，UI 订阅后自动重查列表
  final ValueNotifier<int> generation = ValueNotifier<int>(0);

  static final List<WeakReference<MusicSourceService>> _live = [];

  static Future<MusicSourceService> create() async {
    final manager = await PluginManager.create();
    final lxManager = await LxSourceManager.create();
    return MusicSourceService._(
      manager,
      MusicPluginRuntime(),
      lxManager,
      PluginRouter(manager),
    );
  }

  Future<void> close() async {
    await _runtime.destroy();
    try {
      await _lxManager.close();
    } catch (_) {}
    _live.removeWhere((ref) => ref.target == null || ref.target == this);
  }

  /// 插件变更后调用：所有现存运行时立即重载新插件
  static Future<void> refreshAll() async {
    final snapshot = List<WeakReference<MusicSourceService>>.from(_live);
    for (final ref in snapshot) {
      final service = ref.target;
      if (service == null) continue;
      try {
        await service.refresh();
      } catch (_) {}
    }
  }

  bool get _upToDate =>
      _loaded &&
      _manager.dataVersion() == _loadedVersion &&
      _lxManager.dataVersion() == _loadedLxVersion;

  /// 注册表无变化时跳过重建，避免中断正在提供服务的旧实例
  Future<void> ensureLoaded() async {
    if (!_upToDate) {
      await _withLoadLock(() async {
        if (!_upToDate) {
          _router.replaceAll(await _loadEnabledPlugins());
          _loaded = true;
          // 取加载完成后的最新指纹
          _loadedVersion = _manager.dataVersion();
          await _lxManager.loadEnabled();
          _loadedLxVersion = _lxManager.dataVersion();
        }
      });
    }
    generation.value = dataVersion();
  }

  /// 插件变更后调用，重新加载 QuickJS 音源
  Future<void> refresh() => ensureLoaded();

  /// 加载全部启用插件；单个插件失败不影响其它插件
  Future<List<(InstalledPlugin, MusicPlugin)>> _loadEnabledPlugins() async {
    final entries = <(InstalledPlugin, MusicPlugin)>[];
    for (final plugin in _manager.plugins()) {
      String source;
      try {
        source = await _manager.readPluginSource(plugin);
      } catch (error) {
        developer.log(
          'QuickJS 加载失败: ${plugin.name}',
          name: 'BakaPlugin',
          level: 1000,
          error: error,
        );
        continue;
      }
      final adapter = await _runtime.loadPlugin(
        id: plugin.id,
        name: plugin.name,
        version: plugin.version,
        source: source,
      );
      if (adapter != null) entries.add((plugin, adapter));
    }
    return entries;
  }

  Future<T> _withLoadLock<T>(Future<T> Function() action) async {
    final previous = _loadChain;
    final current = Completer<void>();
    _loadChain = current.future;
    await previous;
    try {
      return await action();
    } finally {
      current.complete();
    }
  }

  Future<List<MusicPlugin>> sources() async {
    await ensureLoaded();
    return _router.activeSources();
  }

  List<String> enabledSourceNames() => _manager.enabledPluginNames();

  /// 注册表元信息，供音源选择组件展示，不调用 JS 运行时
  List<InstalledPlugin> installedPlugins() => _manager.plugins();

  /// 插件注册表指纹（含 LX），供播放地址缓存失效判断
  int dataVersion() {
    final pluginVersion = _manager.dataVersion();
    final lxVersion = _lxManager.dataVersion();
    return pluginVersion > lxVersion ? pluginVersion : lxVersion;
  }

  /// 确保 LX 脚本已加载（设置页打开时调用）
  Future<void> ensureLxLoaded() => ensureLoaded();

  /// LX 取流脚本管理：供设置页调用
  List<LxPluginDescriptor> installedLx() => _lxManager.installed();

  Future<LxPluginDescriptor> installLxLocal(File file) =>
      _lxManager.installLocal(file);

  Future<LxPluginDescriptor> installLxNetwork(String url) =>
      _lxManager.installNetwork(url);

  Future<void> uninstallLx(String hash) => _lxManager.uninstall(hash);

  Future<void> setActiveLx(String? hash) => _lxManager.setActive(hash);

  /// 切歌时立即终止未完成的插件网络请求，不阻塞调用方
  void cancelPendingRequests() {
    try {
      _runtime.cancelPending();
    } catch (_) {}
    try {
      _router.cancelPendingRequests();
    } catch (_) {}
  }

  Future<SearchPage<MediaItem>> searchSource(
    MusicPlugin source,
    String query, [
    int page = 1,
  ]) async {
    await ensureLoaded();
    return _router.search(source, query, page);
  }

  /// 按平台名搜索：每次取最新适配器，找不到则以第一优先级作为后备
  Future<SearchPage<MediaItem>> searchByPlatform(
    String? platform,
    String query, [
    int page = 1,
  ]) async {
    await ensureLoaded();
    MusicPlugin? adapter = platform == null
        ? null
        : _router.findAdapterByPlatform(platform);
    if (adapter == null) {
      final available = _router.activeSources();
      if (available.isEmpty) throw StateError('无可用插件');
      adapter = available.first;
    }
    return _router.search(adapter, query, page);
  }

  Future<SearchPage<MediaItem>> search(String query, [int page = 1]) async {
    await ensureLoaded();
    return _router.searchAny(query, page);
  }

  /// 指定平台榜单分组，无榜单能力时返回空列表
  Future<List<TopListGroup>> topListsByPlatform(String platform) async {
    await ensureLoaded();
    try {
      return await _router.topLists(platform);
    } on StalePluginException {
      // 若遇到插件重建，按平台名重新获取最新适配器并仅重试一次
      await ensureLoaded();
      return _router.topLists(platform);
    }
  }

  /// 指定平台榜单详情，无榜单能力时返回空结果
  Future<SearchPage<MediaItem>> topListDetailByPlatform(
    String platform,
    TopListItem item, [
    int page = 1,
  ]) async {
    await ensureLoaded();
    try {
      return await _router.topListDetail(platform, item, page);
    } on StalePluginException {
      await ensureLoaded();
      return _router.topListDetail(platform, item, page);
    }
  }

  Future<PlaylistSnapshot?> importPlaylist(String url) async {
    await ensureLoaded();
    return _router.importSheet(url);
  }

  Future<MediaItem?> resolve(MediaItem item, MusicQuality quality) async {
    await ensureLoaded();
    return _router.resolveMedia(item, quality);
  }

  Future<MediaItem?> resolveByKey(MediaItem item, String qualityKey) async {
    await ensureLoaded();
    return _router.resolveMediaByKey(item, qualityKey);
  }

  Future<MediaItem?> resolveForPlayback(
    MediaItem item,
    String defaultQualityKey,
  ) async {
    await ensureLoaded();
    return _router.resolveForPlayback(item, defaultQualityKey);
  }

  Future<(MediaItem, String, String)?> resolveForPlaybackDetailed(
    MediaItem item,
    String defaultQualityKey, {
    Set<String> excludeQualities = const {},
    bool cascade = true,
    void Function(String quality, int? size, String via)? onTrying,
  }) async {
    await ensureLoaded();
    return _router.resolveForPlaybackDetailed(
      item,
      defaultQualityKey,
      excludeQualities: excludeQualities,
      cascade: cascade,
      onTrying: onTrying,
    );
  }

  /// 原生单档直试（跳过 LX，供 Source error 同档回退）
  Future<(MediaItem, String, String)?> resolveNativeDetailed(
    MediaItem item,
    String qualityKey,
  ) async {
    await ensureLoaded();
    return _router.resolveNativeDetailed(item, qualityKey);
  }

  Future<LyricSource?> lyrics(MediaItem item) async {
    await ensureLoaded();
    return _router.lyric(item);
  }
}
