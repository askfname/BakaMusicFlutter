/// 按音源优先级路由插件调用：
/// 已禁用与未注册的插件永不被调用
library;

import 'dart:async';
import 'dart:developer' as developer;

import '../models/media_models.dart';
import 'js_worker.dart' show PluginCanceledException;
import 'lx_resolver.dart';
import 'plugin_manager.dart';

/// 单档竞速结果：命中或未命中，附带 LX 是否超时与是否被新任务取消
class _TierOutcome {
  const _TierOutcome.hit(this.media, this.quality, this.via)
    : lxTimedOut = false,
      canceled = false;

  const _TierOutcome.miss({this.lxTimedOut = false, this.canceled = false})
    : media = null,
      quality = '',
      via = '';

  final MediaItem? media;
  final String quality;
  final String via;
  final bool lxTimedOut;
  final bool canceled;

  bool get isHit => media != null;
}

class PluginRouter {
  PluginRouter(
    this._manager, {
    this.attemptTimeout = const Duration(milliseconds: resolveAttemptTimeoutMs),
    this.hedgeDelay = const Duration(milliseconds: lxNativeHedgeDelayMs),
    this.resolveBudget = const Duration(milliseconds: playResolveBudgetMs),
  });

  final PluginManager _manager;

  /// 单档解析上限
  final Duration attemptTimeout;

  /// LX 与原生同档竞速时，原生延迟启动的时间窗
  final Duration hedgeDelay;

  /// 整轮播放解析预算
  final Duration resolveBudget;

  /// 解析代际：新一轮解析或切歌后，旧竞速不得取消新请求
  int _resolveEpoch = 0;

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
    // 推进代际：旧解析的收尾逻辑不得再影响新一轮请求
    _resolveEpoch++;
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
  /// 补全超时或失败直接用原条目解析，避免阻塞取流
  Future<MediaItem> _maybeEnrich(MusicPlugin plugin, MediaItem item) async {
    if (item.qualities.isNotEmpty) return item;
    MediaItem? enriched;
    try {
      enriched = await _runAbortable(() => plugin.getMusicInfo(item))
          .timeout(const Duration(milliseconds: resolveEnrichTimeoutMs));
    } on TimeoutException {
      // 中止仍在执行的补全，避免占住插件 worker 拖慢取流
      try {
        plugin.cancelPendingRequests();
      } catch (_) {}
      developer.log(
        '元信息补全超时，直接解析: ${item.platform}:${item.id}',
        name: 'BakaPlugin',
        level: 500,
      );
    } on PluginCanceledException {
      rethrow;
    } on MediaResolveTimeoutException {
      // 补全超时不影响主流程
    }
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

  /// 单音质解析：只尝试一次，超时立即视为该档失败，交给下一候选
  Future<(MediaItem, String)?> _resolveOneDetailed(
    MusicPlugin plugin,
    MediaItem item,
    String quality, {
    Duration? timeout,
  }) async {
    final limit = timeout ?? attemptTimeout;
    if (limit <= Duration.zero) return null;
    try {
      return await _runAbortable(
        () => plugin.getMediaSourceDetailed(item, quality),
      ).timeout(limit);
    } on PluginCanceledException {
      rethrow;
    } on TimeoutException {
      developer.log(
        '原生解析超时 ${item.platform}:${item.id} quality=$quality',
        name: 'BakaPlugin',
        level: 900,
      );
      return null;
    } on MediaResolveTimeoutException {
      return null;
    }
  }

  /// 播放候选：请求档起逐级向低，最多 [maxPlaybackQualityCandidates] 档；
  /// LX 与原生声明集合合并，避免 LX 支持的高规格被提前裁掉
  List<String> _playbackCandidates(
    MediaItem item,
    String requested,
    Set<String> extraAvailable,
  ) {
    final available = {...item.qualities.keys, ...extraAvailable};
    if (available.isEmpty) return [requested];
    final ladder = qualityFallbackLadder(requested, available: available);
    if (ladder.isNotEmpty) return ladder;
    // 请求档未声明：从已声明的最高档开始降级
    final start = available.reduce(
      (a, b) => qualityRankOf(a) >= qualityRankOf(b) ? a : b,
    );
    return qualityFallbackLadder(start, available: available);
  }

  /// 仅当前解析代际允许取消在途 LX 请求，避免旧任务误伤新一轮取流；
  /// 原生 worker 还被歌词等调用共用，不在这里整体取消
  void _cancelPending(int epoch, {LxResolver? lx, bool cancelLx = false}) {
    if (epoch != _resolveEpoch) return;
    if (cancelLx) {
      try {
        lx?.cancelPending();
      } catch (_) {}
    }
  }

  /// 按音质键解析：仅请求当前平台插件，不跨平台解析
  Future<MediaItem?> resolveMediaByKey(
    MediaItem item,
    String qualityKey,
  ) async {
    final res = await resolveForPlaybackDetailed(item, qualityKey);
    return res?.$1;
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

  /// 下载回退：跳过 LX，仅按用户所选音质直试原生插件；
  /// accept 用于校验候选地址内容（如拦截错误页）
  Future<(MediaItem, String)?> resolveNativeDetailedByKey(
    MediaItem item,
    String qualityKey, {
    Future<bool> Function(MediaItem item)? accept,
  }) async {
    final plugin = findAdapterByPlatform(item.platform);
    if (plugin == null) return null;
    final current = await _maybeEnrich(plugin, item);
    final res = await _resolveOneDetailed(plugin, current, qualityKey);
    if (res != null && _isHttpUrl(res.$1.mediaUrl)) {
      if (accept == null || await accept(res.$1)) {
        developer.log(
          '解析命中 ${current.platform}:${current.id} '
          'quality=${res.$2}(requested=$qualityKey) via '
          '${plugin.platform}(native-download-retry)',
          name: 'BakaPlugin',
          level: 500,
        );
        return res;
      }
      developer.log(
        '原生下载候选不可用 ${current.platform}:${current.id} '
        'quality=${res.$2}(requested=$qualityKey)',
        name: 'BakaPlugin',
        level: 900,
      );
    }
    final url = current.qualities[qualityKey]?.url;
    if (_isHttpUrl(url)) {
      final candidate = current.copyWith(mediaUrl: url);
      if (accept == null || await accept(candidate)) {
        return (candidate, qualityKey);
      }
    }
    return null;
  }

  /// 单档竞速：LX 立即开始，原生延迟 [hedgeDelay] 启动；
  /// 任一方先返回可用地址即胜出，失败/超时则尽快换下一档
  Future<_TierOutcome> _resolveTierHedged({
    required MusicPlugin plugin,
    required MediaItem item,
    required String quality,
    required LxResolver? lx,
    required bool useLx,
    required bool useNative,
    required Duration remaining,
    required Duration nativeHedgeDelay,
    required int epoch,
  }) {
    if (remaining <= Duration.zero || (!useLx && !useNative)) {
      return Future.value(const _TierOutcome.miss());
    }
    final deadline = DateTime.now().add(remaining);
    final completer = Completer<_TierOutcome>();
    Timer? deadlineTimer;
    Timer? nativeTimer;
    var finished = false;
    var lxDone = !useLx;
    var nativeStarted = false;
    var nativeDone = !useNative;
    var lxTimedOut = false;

    void finish(_TierOutcome outcome) {
      if (finished) return;
      finished = true;
      deadlineTimer?.cancel();
      nativeTimer?.cancel();
      if (!completer.isCompleted) completer.complete(outcome);
    }

    void finishMissIfDone() {
      if (!finished && lxDone && nativeDone) {
        finish(_TierOutcome.miss(lxTimedOut: lxTimedOut));
      }
    }

    void startNative() {
      if (finished || nativeStarted || !useNative) return;
      nativeStarted = true;
      nativeTimer?.cancel();
      final left = deadline.difference(DateTime.now());
      if (left <= Duration.zero) {
        nativeDone = true;
        finishMissIfDone();
        return;
      }
      final limit = left < attemptTimeout ? left : attemptTimeout;
      unawaited(() async {
        (MediaItem, String)? res;
        try {
          res = await _resolveOneDetailed(
            plugin,
            item,
            quality,
            timeout: limit,
          );
        } on PluginCanceledException {
          if (!finished) {
            finish(const _TierOutcome.miss(canceled: true));
          }
          return;
        } catch (_) {
          res = null;
        }
        nativeDone = true;
        if (finished) return;
        if (res != null && _isHttpUrl(res.$1.mediaUrl)) {
          finish(_TierOutcome.hit(res.$1, res.$2, ''));
          // 原生命中后释放仍在执行的 LX 调用
          if (useLx && !lxDone) {
            _cancelPending(epoch, lx: lx, cancelLx: true);
          }
        } else {
          finishMissIfDone();
        }
      }());
    }

    deadlineTimer = Timer(remaining, () {
      if (finished) return;
      finish(_TierOutcome.miss(lxTimedOut: lxTimedOut || (useLx && !lxDone)));
      _cancelPending(epoch, lx: lx, cancelLx: useLx && !lxDone);
    });

    if (useLx) {
      unawaited(() async {
        LxQualityResult result;
        final left = deadline.difference(DateTime.now());
        if (left <= Duration.zero) {
          result = const LxQualityResult(timedOut: true);
        } else {
          final limit = left < attemptTimeout ? left : attemptTimeout;
          final probeLimit =
              limit < const Duration(milliseconds: lxResolveProbeTimeoutMs)
              ? limit
              : const Duration(milliseconds: lxResolveProbeTimeoutMs);
          try {
            result = await lx!.resolveQuality(
              item,
              quality,
              timeout: limit,
              probeTimeout: probeLimit,
            );
          } on PluginCanceledException {
            if (!finished) {
              finish(const _TierOutcome.miss(canceled: true));
            }
            return;
          } catch (_) {
            result = const LxQualityResult();
          }
        }
        lxDone = true;
        if (result.timedOut) lxTimedOut = true;
        if (finished) return;
        final resolved = result.resolved;
        if (resolved != null) {
          finish(
            _TierOutcome.hit(resolved.media, resolved.quality, resolved.via),
          );
          return;
        }
        // LX 未命中时原生无需再等 hedge，立即接管
        startNative();
        finishMissIfDone();
      }());
    }

    if (useNative) {
      nativeTimer = Timer(
        useLx ? nativeHedgeDelay : Duration.zero,
        startNative,
      );
    }

    return completer.future;
  }

  /// 供播放调用：默认音质优先向更低音质降级
  Future<MediaItem?> resolveForPlayback(
    MediaItem item,
    String defaultQualityKey,
  ) {
    return resolveMediaByKey(item, defaultQualityKey);
  }

  /// 供播放调用（返回实际命中音质与取流来源标注，供播放栏显示），仅请求当前平台。
  /// [budget] 为整轮解析预算，LX 与原生同档竞速共享，耗尽后不再等待。
  /// [lxFirst] 为下载等需要 LX 权威优先的场景关闭同档竞速。
  Future<(MediaItem, String, String)?> resolveForPlaybackDetailed(
    MediaItem item,
    String defaultQualityKey, {
    Set<String> excludeQualities = const {},
    bool cascade = true,
    bool lxFirst = false,
    void Function(String quality, int? size, String via)? onTrying,
    Duration? budget,
  }) async {
    final epoch = ++_resolveEpoch;
    final plugin = findAdapterByPlatform(item.platform);
    if (plugin == null) {
      developer.log(
        '无当前平台适配器，拒绝解析: ${item.platform}:${item.id}',
        name: 'BakaPlugin',
        level: 500,
      );
      return null;
    }
    final deadline = DateTime.now().add(budget ?? resolveBudget);
    final current = await _maybeEnrich(plugin, item);
    final lx = lxResolver;
    final lxQualities =
        lx?.qualityOverride(current.platform)?.toSet() ?? const <String>{};
    final nativeQualities = current.qualities.keys.toSet();
    final tried = cascade
        ? _playbackCandidates(current, defaultQualityKey, lxQualities)
        : <String>[defaultQualityKey];
    final candidates = [
      for (final quality in tried)
        if (!excludeQualities.contains(quality)) quality,
    ];
    var lxTimedOut = false;
    for (final quality in candidates) {
      final remaining = deadline.difference(DateTime.now());
      if (remaining <= Duration.zero) break;
      final useLx = lx != null && !lxTimedOut && lxQualities.contains(quality);
      // 原生只尝试已声明档；手动切音质时允许直试所选档
      final useNative =
          nativeQualities.contains(quality) ||
          nativeQualities.isEmpty ||
          (!cascade && quality == defaultQualityKey);
      if (!useLx && !useNative) continue;
      // 上报当前尝试档，供界面实时跟随；原生档 via 置空（与 LX 档区分显示）
      onTrying?.call(
        quality,
        current.qualities[quality]?.size,
        useLx ? (lx.viaLabel(current.platform) ?? '') : '',
      );
      // 下载场景等 LX 单档自然结束；播放场景延后 1s 让原生兜底尽快启动
      final nativeHedgeDelay = lxFirst && useLx
          ? attemptTimeout + const Duration(milliseconds: 500)
          : hedgeDelay;
      final outcome = await _resolveTierHedged(
        plugin: plugin,
        item: current,
        quality: quality,
        lx: lx,
        useLx: useLx,
        useNative: useNative,
        remaining: remaining,
        nativeHedgeDelay: nativeHedgeDelay,
        epoch: epoch,
      );
      if (outcome.canceled) {
        developer.log(
          '解析已取消 ${current.platform}:${current.id} quality=$quality',
          name: 'BakaPlugin',
          level: 500,
        );
        return null;
      }
      final media = outcome.media;
      if (media != null && _isHttpUrl(media.mediaUrl)) {
        developer.log(
          '解析命中 ${current.platform}:${current.id} '
          'quality=${outcome.quality}(requested=$quality) '
          'via=${outcome.via.isEmpty ? plugin.platform : outcome.via}',
          name: 'BakaPlugin',
          level: 500,
        );
        return (media, outcome.quality, outcome.via);
      }
      if (outcome.lxTimedOut) lxTimedOut = true;
    }
    // 后备：使用 qualities 自带的直链
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
