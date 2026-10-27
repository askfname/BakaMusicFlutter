/// 主界面状态模型：
/// 播放编排、歌词加载、会话持久化与插件解析协调都集中在这里，
/// UI 只读取状态并调用动作方法
library;

import 'dart:async';
import 'dart:collection';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../data/app_repository.dart';
import '../data/player_session_store.dart';
import '../models/media_models.dart';
import '../service/music_source_service.dart';
import '../util/download_helper.dart';
import '../util/lyric_parser.dart';
import '../util/playback_controller.dart';

/// 主界面状态模型
class MainViewModel extends ChangeNotifier {
  MainViewModel({
    required this.repository,
    required this.sourceService,
    required this.playbackController,
    required this.sessionStore,
  }) {
    // 跟随设置中的默认播放音质，供加载占位显示
    _defaultPlayQuality = repository.playQuality;
    repository.addListener(_onRepositoryChanged);

    // 恢复播放会话
    final saved = sessionStore.load();
    if (saved != null) {
      final current = saved.current;
      _nowPlaying = current == null
          ? null
          : NowPlaying(
              item: current,
              mediaUrl: '',
              qualityKey: saved.qualityKey,
              size: saved.size,
              loading: false,
            );
      _queue.addAll(saved.queue);
      queueIndex = saved.queueIndex;
      _setPosition(saved.positionMs);
      _setDuration(current?.durationMs ?? 0);
    }

    // 注册播放控制器监听
    _removeErrorListener = playbackController.addErrorListener(_onPlayerError);
    playbackController.addAudibleListener(_onAudible);
    playbackController.addEndedListener(handleTrackEnded);

    unawaited(_pollLoop());
    unawaited(_lyricLoop());
    unawaited(_sessionSaveLoop());
  }

  final AppRepository repository;
  final MusicSourceService sourceService;
  final PlaybackController playbackController;
  final PlayerSessionStore sessionStore;

  /// Toast 出口：由根组件设置，error 控制错误样式
  void Function(String message, {bool? error})? toastHandler;

  final Random _random = Random();

  // ---------------------------------------------------------------- 播放状态

  NowPlaying? _nowPlaying;

  /// 当前播放项（含解析中占位）
  NowPlaying? get nowPlaying => _nowPlaying;

  final List<MediaItem> _queue = [];
  late final UnmodifiableListView<MediaItem> _queueView = UnmodifiableListView(
    _queue,
  );

  /// 播放列表（只读视图）
  List<MediaItem> get playQueue => _queueView;

  int _queueIndex = 0;

  /// 当前曲目在播放列表中的下标
  int get queueIndex => _queueIndex;
  set queueIndex(int value) {
    if (_queueIndex == value) return;
    _queueIndex = value;
    notifyListeners();
  }

  final Map<String, NowPlaying> _resolvedCache = {};
  int _resolvedCacheGen = -1;

  bool _playing = false;

  /// 播放器是否处于播放状态（跟随快照轮询）
  bool get playing => _playing;

  /// 进度（毫秒）：高频更新，独立监听避免整页重建
  final ValueNotifier<int> positionMs = ValueNotifier<int>(0);

  /// 时长（毫秒）：高频更新，独立监听
  final ValueNotifier<int> durationMs = ValueNotifier<int>(0);

  bool _buffering = false;

  /// 是否缓冲中（用于加载动画）
  bool get buffering => _buffering;

  int _serviceItemCount = 0;

  /// 播放服务侧曲目数，用于判断真实播放内容是否存在
  int get serviceItemCount => _serviceItemCount;

  String _defaultPlayQuality = 'flac';

  /// 设置中的默认播放音质：加载占位与解析起点都用它
  String get defaultPlayQuality => _defaultPlayQuality;

  String? _playError;

  /// 播放动作类错误（下载/起播），弹框提示
  String? get playError => _playError;
  set playError(String? value) {
    _playError = value;
    notifyListeners();
  }

  String? _playerError;

  /// 播放器错误（源失败/解码失败），弹框提示
  String? get playerError => _playerError;
  set playerError(String? value) {
    _playerError = value;
    notifyListeners();
  }

  bool _playerErrorRetry = false;

  /// 手动切音质失败时才允许单步降级重试
  bool get playerErrorRetry => _playerErrorRetry;
  set playerErrorRetry(bool value) {
    _playerErrorRetry = value;
    notifyListeners();
  }

  String? _lastEndedKey;

  /// 播放完毕去重标记
  String? get lastEndedKey => _lastEndedKey;

  List<LyricLine> _lyricLines = const [];

  /// 当前曲目歌词行
  List<LyricLine> get lyricLines => _lyricLines;

  bool _lyricLoading = false;

  /// 歌词是否加载中
  bool get lyricLoading => _lyricLoading;

  int _playMode = 0;

  /// 播放模式：0 顺序播放，1 单曲循环，2 随机播放
  int get playMode => _playMode;
  set playMode(int value) {
    if (_playMode == value) return;
    _playMode = value;
    notifyListeners();
  }

  int _playToken = 0;

  /// Source error 已排除的音质（按曲目累计，避免同一直播流反复重试已失败的高档）
  final Map<String, Set<String>> _playExcludes = {};

  /// 切音质位置保持：轮询暂停跟随快照，直到位置收敛或超时
  int? _holdPositionMs;
  int _holdSinceMs = 0;

  bool _foreground = true;
  bool _disposed = false;
  void Function()? _removeErrorListener;

  // ---------------------------------------------------------------- 对外动作

  /// 播放指定曲目：整轮解析完成后起播，loading 期展示尝试档位
  void startTrack(
    MediaItem item,
    int index, {
    Set<String> excludeQualities = const {},
  }) {
    _playToken++;
    final token = _playToken;
    unawaited(playbackController.clear());
    sourceService.cancelPendingRequests();
    _setPlaying(false);
    _holdPositionMs = null;
    _setPosition(0);
    _setDuration(item.durationMs);
    queueIndex = index;
    // 占位用默认播放音质（实际解析起点），加载中/失败不再误显示最高音质
    final start = _defaultPlayQuality;
    _setNowPlaying(
      NowPlaying(
        item: item,
        mediaUrl: '',
        qualityKey: start,
        size: item.qualities[start]?.size,
        loading: true,
      ),
    );
    unawaited(_resolveAndPlay(token, item, index, excludeQualities));
  }

  Future<void> _resolveAndPlay(
    int token,
    MediaItem item,
    int index,
    Set<String> excludeQualities,
  ) async {
    var resolveEmpty = false;
    var timedOut = false;
    var otherError = false;
    NowPlaying? np;
    final key = item.key;

    if (item.platform == 'BakaMusic') {
      final url = (item.mediaUrl ?? '');
      if (url.toLowerCase().startsWith('http')) {
        var q = '320k';
        for (final k in item.qualities.keys) {
          if (qualityRankOf(k) >= qualityRankOf(q)) q = k;
        }
        np = NowPlaying(item: item, mediaUrl: url, qualityKey: q);
      } else {
        _playError = '该歌曲暂无可用音源';
      }
    } else if (!await playbackController.awaitConnected()) {
      _playError = '播放器连接失败，请重试';
    } else {
      final genNow = sourceService.dataVersion();
      if (_resolvedCacheGen != genNow) {
        _resolvedCache.clear();
        _resolvedCacheGen = genNow;
      }
      if (excludeQualities.isEmpty) {
        final cached = _resolvedCache[key];
        if (cached != null) np = cached;
      }
      if (np == null) {
        (MediaItem, String, String)? r;
        try {
          r = await sourceService
              .resolveForPlaybackDetailed(
                item,
                _defaultPlayQuality,
                excludeQualities: excludeQualities,
                onTrying: (trying, tryingSize, tryingVia) {
                  // 自动逐级重试时界面实时跟随当前尝试档（含 LX 插件名）
                  if (token != _playToken) return;
                  final cur = _nowPlaying;
                  if (cur != null && cur.key == key && cur.loading) {
                    _setNowPlaying(
                      cur.copyWith(
                        qualityKey: trying,
                        size: tryingSize ?? cur.size,
                        via: tryingVia,
                      ),
                    );
                  }
                },
              )
              .timeout(const Duration(milliseconds: playResolveTimeoutMs));
        } on TimeoutException {
          timedOut = true;
        } on MediaResolveTimeoutException {
          timedOut = true;
        } catch (_) {
          otherError = true;
        }
        if (timedOut) {
          if (token == _playToken) {
            final cur = _nowPlaying;
            if (cur?.key == key) _setNowPlaying(cur!.copyWith(loading: false));
            _playerError = '播放器错误 3003：Source error';
            _playerErrorRetry = false;
            notifyListeners();
          }
          return;
        }
        if (otherError) {
          if (token == _playToken) {
            final cur = _nowPlaying;
            if (cur?.key == key) _setNowPlaying(cur!.copyWith(loading: false));
            _playerError = '该歌曲暂无可用音源';
            _playerErrorRetry = false;
            notifyListeners();
          }
          return;
        }
        if (r == null) {
          resolveEmpty = true;
        } else {
          final (res, actualQuality, via) = r;
          final url = (res.mediaUrl ?? '');
          if (url.toLowerCase().startsWith('http')) {
            // res 由详情补全后的条目拷贝而来，展示与缓存均用它
            final displayItem = res.copyWith(
              mediaUrl: null,
              mediaHeaders: const {},
            );
            final backups = res.backupUrls.where((u) => u != url).toList();
            np = NowPlaying(
              item: displayItem,
              mediaUrl: url,
              qualityKey: actualQuality,
              size: res.qualities[actualQuality]?.size,
              headers: res.mediaHeaders,
              loading: false,
              backupUrls: backups,
              via: via,
            );
            _resolvedCache[key] = np;
          }
        }
      }
    }

    if (token != _playToken) return;
    if (np == null) {
      final cur = _nowPlaying;
      if (cur?.key == key) _setNowPlaying(cur!.copyWith(loading: false));
      // 解析返回空（非取消/超时异常）时补齐失败弹窗
      if (resolveEmpty) {
        _playerError = '该歌曲暂无可用音源';
        _playerErrorRetry = false;
        notifyListeners();
      }
      return;
    }
    _queueIndex = index;
    _setNowPlaying(np);
    _setPosition(0);
    _setDuration(item.durationMs);
    unawaited(
      playbackController.playItem(
        np.item.copyWith(mediaUrl: np.mediaUrl, mediaHeaders: np.headers),
      ),
    );
  }

  void togglePlay() {
    final cur = _nowPlaying;
    if (cur != null &&
        cur.mediaUrl.isEmpty &&
        !cur.loading &&
        _serviceItemCount <= 0) {
      startTrack(cur.item, _queueIndex);
      return;
    }
    if (cur?.loading == true) return;
    unawaited(playbackController.toggle());
  }

  void playItems(List<MediaItem> items, int index) {
    if (items.isEmpty || index < 0 || index >= items.length) return;
    _queue
      ..clear()
      ..addAll(items);
    startTrack(items[index], index);
  }

  void playMediaItem(MediaItem item, List<MediaItem> context) {
    final idx = context.indexWhere(
      (it) => it.platform == item.platform && it.id == item.id,
    );
    if (idx >= 0) {
      playItems(context, idx);
    } else {
      playItems([item], 0);
    }
  }

  void playAt(int index) {
    if (index < 0 || index >= _queue.length) return;
    if (index == _queueIndex && _nowPlaying?.loading == false) {
      final np = _nowPlaying;
      if (np != null && (_serviceItemCount > 0 || np.mediaUrl.isNotEmpty)) {
        return;
      }
    }
    startTrack(_queue[index], index);
  }

  void advance(int delta, {bool silent = false}) {
    if (_queue.isEmpty) return;
    final next = (_queueIndex + delta).clamp(0, _queue.length - 1);
    if (next == _queueIndex) {
      if (!silent) {
        _toast(delta > 0 ? '已是最后一首' : '已是第一首');
      }
      return;
    }
    startTrack(_queue[next], next);
  }

  void stepNext() {
    if (_playMode == 2 && _queue.length > 1) {
      final indices = [
        for (var i = 0; i < _queue.length; i++)
          if (i != _queueIndex) i,
      ];
      final ni = indices[_random.nextInt(indices.length)];
      startTrack(_queue[ni], ni);
      return;
    }
    advance(1);
  }

  void stepPrev() => advance(-1);

  /// 当前显示档的下一低档（仅歌曲已声明的），没有则返回 null
  String? lowerQualityKey(MediaItem item, String fromKey) {
    final idx = qualityKeysOrdered.indexOf(fromKey);
    if (idx < 0) return null;
    for (final key in qualityKeysOrdered.sublist(0, idx).reversed) {
      if (item.qualities.containsKey(key)) return key;
    }
    return null;
  }

  /// Source error 自动降档用：按全局顺序取下一低档（不要求已声明）
  String? nextLowerOrdered(String fromKey, Set<String> exclude) {
    final idx = qualityKeysOrdered.indexOf(fromKey);
    if (idx < 0) return null;
    for (final key in qualityKeysOrdered.sublist(0, idx).reversed) {
      if (!exclude.contains(key)) return key;
    }
    return null;
  }

  /// 手动切音质失败后的单步降级：只低一档，不自动级联
  void retryLowerQuality() {
    final cur = _nowPlaying;
    if (cur == null) return;
    _playerError = null;
    _playerErrorRetry = false;
    final lower = lowerQualityKey(cur.item, cur.qualityKey);
    if (lower != null) switchQuality(cur.item, lower);
    notifyListeners();
  }

  /// 解析并入队下载，失败返回 null，由调用方带歌曲名提示
  Future<String?> downloadItem(MediaItem item, String quality) async {
    try {
      final resolved = await sourceService.resolveForDownload(item, quality);
      if (resolved == null) throw StateError('下载失败');
      return await DownloadHelper.enqueueByKey(resolved.$1, resolved.$2);
    } catch (_) {
      return null;
    }
  }

  /// 手动切换音质：只试所选单档，起播后恢复原进度
  void switchQuality(MediaItem item, String newKey) {
    // 与 startTrack 同一代际：旧任务与旧流的回调不再触碰新一轮 loading
    _playToken++;
    final token = _playToken;
    sourceService.cancelPendingRequests();
    _holdPositionMs = null;
    unawaited(_runSwitchQuality(token, item, newKey));
  }

  Future<void> _runSwitchQuality(
    int token,
    MediaItem item,
    String newKey,
  ) async {
    final keepPos = playbackController.snapshot().positionMs;
    final itemKey = item.key;
    // 先清旧流：旧流随后可听/报错会提前关掉新一轮 loading
    await playbackController.clear();
    final before = _nowPlaying;
    if (before != null && before.key == itemKey) {
      _setNowPlaying(
        before.copyWith(
          qualityKey: newKey,
          size: item.qualities[newKey]?.size ?? before.size,
          loading: true,
        ),
      );
    }

    (MediaItem, String, String)? pair;
    try {
      pair = await sourceService
          .resolveForPlaybackDetailed(
            item,
            newKey,
            cascade: false,
            onTrying: (trying, tryingSize, tryingVia) {
              if (token != _playToken) return;
              final cur = _nowPlaying;
              if (cur != null && cur.key == itemKey && cur.loading) {
                _setNowPlaying(
                  cur.copyWith(
                    qualityKey: trying,
                    size: tryingSize ?? cur.size,
                    via: tryingVia,
                  ),
                );
              }
            },
          )
          .timeout(const Duration(milliseconds: playResolveTimeoutMs));
    } on TimeoutException {
      _switchQualityFailed(token, itemKey, item, newKey, timeout: true);
      return;
    } on MediaResolveTimeoutException {
      _switchQualityFailed(token, itemKey, item, newKey, timeout: true);
      return;
    } catch (_) {
      _switchQualityFailed(token, itemKey, item, newKey, timeout: false);
      return;
    }
    if (pair == null) {
      _switchQualityFailed(token, itemKey, item, newKey, timeout: false);
      return;
    }

    final (res, q, via) = pair;
    final url = res.mediaUrl ?? '';
    if (!url.toLowerCase().startsWith('http')) {
      _switchQualityFailed(token, itemKey, item, newKey, timeout: false);
      return;
    }
    if (token != _playToken) return;
    final np = NowPlaying(
      item: res.copyWith(mediaUrl: null, mediaHeaders: const {}),
      mediaUrl: url,
      qualityKey: q,
      size: res.qualities[q]?.size,
      headers: res.mediaHeaders,
      loading: false,
      backupUrls: res.backupUrls.where((u) => u != url).toList(),
      via: via,
    );
    if (_resolvedCacheGen == sourceService.dataVersion()) {
      _resolvedCache[itemKey] = np;
    }
    _setNowPlaying(np);
    // 起播新流前先保持住当前位置，避免轮询跟随归零导致进度条与歌词来回跳
    _holdPositionMs = keepPos;
    _holdSinceMs = DateTime.now().millisecondsSinceEpoch;
    _setPosition(keepPos);
    unawaited(
      playbackController.playItem(
        np.item.copyWith(mediaUrl: url, mediaHeaders: res.mediaHeaders),
      ),
    );

    for (var i = 0; i < 40; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 250));
      if (token != _playToken) return;
      if (playbackController.snapshot().durationMs > 0) break;
    }
    if (token != _playToken) return;
    await playbackController.seekTo(keepPos);
  }

  void _switchQualityFailed(
    int token,
    String itemKey,
    MediaItem item,
    String newKey, {
    required bool timeout,
  }) {
    if (token != _playToken) return;
    final cur = _nowPlaying;
    if (cur?.key == itemKey) _setNowPlaying(cur!.copyWith(loading: false));
    _playerError = timeout ? '播放器错误 3003：Source error' : '该歌曲暂无可用音源';
    _playerErrorRetry = lowerQualityKey(item, newKey) != null;
    notifyListeners();
  }

  void seekTo(int pos) {
    // 用户手动接管进度：解除切音质的位置保持，跟随用户目标
    _holdPositionMs = null;
    unawaited(playbackController.seekTo(pos));
  }

  /// 播放完毕自动切歌：按播放模式决定重播/随机/下一首
  void handleTrackEnded() {
    final cur = _nowPlaying;
    final guard = '${cur?.key}@$_queueIndex';
    if (cur == null || _lastEndedKey == guard) return;
    _lastEndedKey = guard;
    if (_playMode == 1) {
      if (_queueIndex >= 0 && _queueIndex < _queue.length) {
        _lastEndedKey = null;
        startTrack(_queue[_queueIndex], _queueIndex);
      }
    } else if (_playMode == 2) {
      if (_queue.length > 1) {
        final indices = [
          for (var i = 0; i < _queue.length; i++)
            if (i != _queueIndex) i,
        ];
        final ni = indices[_random.nextInt(indices.length)];
        startTrack(_queue[ni], ni);
      }
    } else {
      advance(1, silent: true);
    }
  }

  /// 前台状态切换：回到前台立刻刷新一次快照
  void setForeground(bool fg) {
    _foreground = fg;
    if (!fg || _disposed) return;
    final s = playbackController.snapshot();
    _setPlaying(s.isPlaying);
    _setBuffering(s.buffering);
    _setServiceItemCount(s.itemCount);
    if (s.itemCount > 0) _setPosition(s.positionMs);
    if (s.durationMs > 0) _setDuration(s.durationMs);
    if (s.ended) handleTrackEnded();
  }

  // ---------------------------------------------------------------- 内部监听

  void _onPlayerError(String msg) {
    final cur = _nowPlaying;
    // 源错误（403/断连等多为单 CDN 边缘故障）：有备用地址时静默切换，不弹框
    // 耗尽才走失败弹窗。解码类错误不适用备用源，直接弹框
    final isSourceError =
        msg.contains('Source error') ||
        msg.contains('2001') ||
        msg.contains('2004') ||
        msg.contains('3003');
    // 自动换源/降档重试期间，同一失败会被播放器错误流与加载异常各报一次；
    // 加载中的后续上报直接忽略，避免重试尚未结束时误弹失败框
    if (cur != null && cur.loading && isSourceError) return;
    String? next;
    if (cur != null && isSourceError) {
      for (final u in cur.backupUrls) {
        if (u.toLowerCase().startsWith('http') && u != cur.mediaUrl) {
          next = u;
          break;
        }
      }
    }
    if (cur != null && next != null) {
      final remaining = cur.backupUrls.where((u) => u != next).toList();
      final switched = cur.copyWith(
        mediaUrl: next,
        backupUrls: remaining,
        loading: true,
      );
      _setNowPlaying(switched);
      final cached = _resolvedCache[cur.key];
      if (cached != null) {
        _resolvedCache[cur.key] = switched.copyWith(loading: false);
      }
      unawaited(
        playbackController.playItem(
          cur.item.copyWith(mediaUrl: next, mediaHeaders: cur.headers),
        ),
      );
      return;
    }
    // Source error 且无备用地址时自动降档重试，耗尽才弹框
    if (cur != null && isSourceError && !cur.loading) {
      final key = cur.key;
      final failed = cur.qualityKey;
      // LX 直链失败时先同档直试原生（同档 URL 不同源，原生可能可用），避免误降档
      if (cur.via.contains('LX')) {
        _setNowPlaying(cur.copyWith(loading: true, via: ''));
        unawaited(_lxFallbackNative(cur, failed, msg));
        return;
      }
      final acc = {...?_playExcludes[key], failed};
      _playExcludes[key] = acc;
      // 按全局顺序降档（LX 声明集常大于原生 qualities，不能仅看已声明）
      final lower = nextLowerOrdered(failed, acc);
      if (lower != null) {
        startTrack(cur.item, _queueIndex, excludeQualities: acc);
        return;
      }
    }
    _playerError = msg;
    _playerErrorRetry = false;
    final latest = _nowPlaying;
    if (latest?.loading == true) {
      _setNowPlaying(latest!.copyWith(loading: false));
    }
    notifyListeners();
  }

  Future<void> _lxFallbackNative(
    NowPlaying cur,
    String failed,
    String originalMsg,
  ) async {
    final token = ++_playToken;
    final key = cur.key;
    (MediaItem, String, String)? native;
    try {
      native = await sourceService.resolveNativeDetailed(cur.item, failed);
    } catch (_) {
      native = null;
    }
    if (token != _playToken) return;
    if (native != null) {
      final (res, q, via) = native;
      final url = res.mediaUrl ?? '';
      if (url.toLowerCase().startsWith('http')) {
        _playExcludes.remove(key);
        final displayItem = res.copyWith(
          mediaUrl: null,
          mediaHeaders: const {},
        );
        final backups = res.backupUrls.where((u) => u != url).toList();
        final np = NowPlaying(
          item: displayItem,
          mediaUrl: url,
          qualityKey: q,
          size: res.qualities[q]?.size,
          headers: res.mediaHeaders,
          loading: false,
          backupUrls: backups,
          via: via,
        );
        _resolvedCache[key] = np;
        _setNowPlaying(np);
        unawaited(
          playbackController.playItem(
            np.item.copyWith(mediaUrl: url, mediaHeaders: res.mediaHeaders),
          ),
        );
        return;
      }
    }
    // 原生同档亦无可用时转入常规降档（排除已失败档）
    final acc = {...?_playExcludes[key], failed};
    _playExcludes[key] = acc;
    final lower = nextLowerOrdered(failed, acc);
    if (lower != null) {
      unawaited(playbackController.clear());
      startTrack(cur.item, _queueIndex, excludeQualities: acc);
    } else {
      _playerError = originalMsg;
      _playerErrorRetry = false;
      final latest = _nowPlaying;
      if (latest?.key == key && latest!.loading) {
        _setNowPlaying(latest.copyWith(loading: false));
      }
      notifyListeners();
    }
  }

  void _onAudible() {
    final cur = _nowPlaying;
    if (cur?.loading == true) {
      _setNowPlaying(cur!.copyWith(loading: false));
    }
    // 真正起播说明重试已成功，清掉可能残留的失败提示
    if (_playerError != null) {
      _playerError = null;
      _playerErrorRetry = false;
      notifyListeners();
    }
    // 起播成功即清该曲目的降档记忆，下次重播仍从高档试起
    if (cur != null) _playExcludes.remove(cur.key);
  }

  void _onRepositoryChanged() {
    final q = repository.playQuality;
    if (q != _defaultPlayQuality) {
      _defaultPlayQuality = q;
      notifyListeners();
    }
  }

  // ---------------------------------------------------------------- 循环任务

  Future<void> _pollLoop() async {
    var lastPosSaveMs = 0;
    while (!_disposed) {
      // 三档轮询：前台播放中 250ms（进度条/歌词），前台暂停/空闲 1000ms，
      // 后台 4000ms 且不做高频界面更新（后台切歌由 ended 事件驱动）
      final fg = _foreground;
      final active = _nowPlaying != null && (_playing || _buffering);
      await Future<void>.delayed(
        Duration(milliseconds: !fg ? 4000 : (active ? 250 : 1000)),
      );
      if (_disposed) return;
      final s = playbackController.snapshot();
      _setPlaying(s.isPlaying);
      _setBuffering(s.buffering);
      _setServiceItemCount(s.itemCount);
      if (!fg) {
        // 后台：只做会话进度落盘（SharedPreferences，非界面状态）
        if (_nowPlaying != null && s.isPlaying) {
          final now = DateTime.now().millisecondsSinceEpoch;
          if (now - lastPosSaveMs > 10000) {
            lastPosSaveMs = now;
            unawaited(sessionStore.savePosition(s.positionMs));
          }
        }
        if (s.ended) handleTrackEnded();
        continue;
      }
      final hold = _holdPositionMs;
      if (hold != null && s.itemCount > 0) {
        // 切音质保持中：收敛到保持点附近或超时才解除
        if ((s.positionMs - hold).abs() < 1500 ||
            DateTime.now().millisecondsSinceEpoch - _holdSinceMs > 10000) {
          _holdPositionMs = null;
          _setPosition(s.positionMs);
        }
      } else if (s.itemCount > 0) {
        _setPosition(s.positionMs);
      }
      if (s.durationMs > 0) _setDuration(s.durationMs);

      // 进度落盘改为时间节流（10s 且播放中）
      if (_nowPlaying != null && s.isPlaying) {
        final now = DateTime.now().millisecondsSinceEpoch;
        if (now - lastPosSaveMs > 10000) {
          lastPosSaveMs = now;
          unawaited(sessionStore.savePosition(positionMs.value));
        }
      }

      if (s.ended) handleTrackEnded();
    }
  }

  Future<void> _lyricLoop() async {
    while (!_disposed) {
      final currentKey = _nowPlaying?.key;
      if (currentKey != null) {
        final item = _nowPlaying!.item;
        _lyricLoading = true;
        notifyListeners();
        List<LyricLine> lines;
        try {
          final source = await sourceService
              .lyrics(item)
              .timeout(const Duration(milliseconds: playResolveTimeoutMs));
          lines = LyricParser.parse(source);
        } catch (_) {
          lines = LyricParser.parse(null);
        }
        if (_disposed) return;
        _lyricLines = lines;
        _lyricLoading = false;
        notifyListeners();
      }
      // 等待曲目切换
      while (!_disposed && _nowPlaying?.key == currentKey) {
        await Future<void>.delayed(const Duration(milliseconds: 500));
      }
    }
  }

  Future<void> _sessionSaveLoop() async {
    var lastSig = '';
    while (!_disposed) {
      await Future<void>.delayed(const Duration(seconds: 15));
      if (_disposed) return;
      final np = _nowPlaying;
      final q = List<MediaItem>.of(_queue);
      // 位置按 10s 桶参与签名，避免纯进度推进导致每轮都判脏
      final posBucket = positionMs.value ~/ 10000;
      final firstId = q.isEmpty ? '' : q.first.id;
      final lastId = q.isEmpty ? '' : q.last.id;
      final sig =
          '${np?.key}@${np?.qualityKey}@$_queueIndex@${q.length}@$firstId@$lastId@$posBucket';
      if (sig == lastSig) continue;
      lastSig = sig;
      try {
        await sessionStore.save(
          queue: q,
          queueIndex: _queueIndex,
          current: np?.item,
          qualityKey: np?.qualityKey,
          size: np?.size,
          positionMs: positionMs.value,
        );
      } catch (_) {}
    }
  }

  // ---------------------------------------------------------------- 工具方法

  void _setNowPlaying(NowPlaying? value) {
    _nowPlaying = value;
    notifyListeners();
  }

  void _setPlaying(bool value) {
    if (_playing == value) return;
    _playing = value;
    notifyListeners();
  }

  void _setBuffering(bool value) {
    if (_buffering == value) return;
    _buffering = value;
    notifyListeners();
  }

  void _setServiceItemCount(int value) {
    if (_serviceItemCount == value) return;
    _serviceItemCount = value;
    notifyListeners();
  }

  void _setPosition(int value) {
    final clamped = value < 0 ? 0 : value;
    if (positionMs.value == clamped) return;
    positionMs.value = clamped;
  }

  void _setDuration(int value) {
    final clamped = value < 0 ? 0 : value;
    if (durationMs.value == clamped) return;
    durationMs.value = clamped;
  }

  void _toast(String message, {bool? error}) =>
      toastHandler?.call(message, error: error);

  @override
  void dispose() {
    _disposed = true;
    _removeErrorListener?.call();
    repository.removeListener(_onRepositoryChanged);
    positionMs.dispose();
    durationMs.dispose();
    super.dispose();
  }
}
