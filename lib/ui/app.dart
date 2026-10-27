// ---------------------------------------------------------------------------
// 根组件与主界面
// - 四页常驻（IndexedStack）：主页 / 音乐库 / 搜索 / 设置
// - 悬浮底座显隐（滚动方向驱动）、歌单详情、播放器面板、全屏歌词
// - 返回键逐层消费：全屏歌词 → 播放器 → 歌单详情 → 设置插件页 → 非首页回主页
// ---------------------------------------------------------------------------

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

import '../data/app_repository.dart';
import '../data/player_session_store.dart';
import '../models/media_models.dart';
import '../service/music_source_service.dart';
import '../util/common_utils.dart';
import '../util/download_helper.dart';
import '../util/playback_controller.dart';
import 'app_toast.dart';
import 'download_feedback.dart';
import 'home_screen.dart';
import 'main_view_model.dart';
import 'player_components.dart';
import 'search_screen.dart';
import 'settings_screen.dart';
import 'theme.dart';

/// 宿主屏幕常亮通道
const MethodChannel _screenChannel = MethodChannel('baka_music/screen');

Future<void> _setKeepScreenOn(bool keepOn) async {
  try {
    await _screenChannel.invokeMethod<void>('setKeepScreenOn', keepOn);
  } catch (_) {}
}

/// 应用根组件：主题 + 主界面
class BakaMusicApp extends StatelessWidget {
  const BakaMusicApp({
    super.key,
    required this.repository,
    required this.sourceService,
    required this.playbackController,
    required this.sessionStore,
  });

  final AppRepository repository;
  final MusicSourceService sourceService;
  final PlaybackController playbackController;
  final PlayerSessionStore sessionStore;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'BakaMusic',
      debugShowCheckedModeBanner: false,
      theme: BakaTheme.build(Brightness.light),
      darkTheme: BakaTheme.build(Brightness.dark),
      home: MainScreen(
        repository: repository,
        sourceService: sourceService,
        playbackController: playbackController,
        sessionStore: sessionStore,
      ),
    );
  }
}

/// 主界面
class MainScreen extends StatefulWidget {
  const MainScreen({
    super.key,
    required this.repository,
    required this.sourceService,
    required this.playbackController,
    required this.sessionStore,
  });

  final AppRepository repository;
  final MusicSourceService sourceService;
  final PlaybackController playbackController;
  final PlayerSessionStore sessionStore;

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen>
    with SingleTickerProviderStateMixin {
  late final MainViewModel _vm;
  late final Listenable _appState;
  late final AnimationController _dockController;

  final GlobalKey<PlayerSheetState> _sheetKey = GlobalKey<PlayerSheetState>();
  final GlobalKey<SettingsScreenState> _settingsKey =
      GlobalKey<SettingsScreenState>();
  final GlobalKey<_LyricFullscreenOverlayState> _lyricKey =
      GlobalKey<_LyricFullscreenOverlayState>();

  /// 被全屏覆盖时给底座传哨兵进度：不订阅真实进度即无界面更新
  final ValueNotifier<int> _frozenZero = ValueNotifier<int>(0);

  // 界面状态
  int _selectedTab = 0;
  int _settingsScrollTrigger = 0;
  bool _expanded = false;
  bool _showQueue = false;
  bool _importNotice = false;
  String? _playlistSheet;
  bool _lyricFullscreen = false;

  // 底座显隐动画状态
  bool _dockGone = false;
  bool _dockLastTarget = true;
  int _dockRunningDur = 350;
  double _dockHPx = 0;
  double _dockAcc = 0;
  int _dockAccT = 0;
  double _dockWasted = 0;

  String? _lastNowKey;
  StreamSubscription<DownloadEvent>? _downloadEvents;

  @override
  void initState() {
    super.initState();
    _vm = MainViewModel(
      repository: widget.repository,
      sourceService: widget.sourceService,
      playbackController: widget.playbackController,
      sessionStore: widget.sessionStore,
    );
    _appState = Listenable.merge([_vm, widget.repository]);
    _vm.toastHandler = _showToast;
    _lastNowKey = _vm.nowPlaying?.key;
    _dockController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 350),
    );
    _vm.addListener(_onVmChanged);
    // 订阅原生真实下载状态：失败时带上歌曲名提示
    _downloadEvents = DownloadHelper.events.listen(
      _onDownloadEvent,
      onError: (_) {},
    );
    // 启动即确保底座可见
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _settleDock(show: true, durMs: 350);
    });
  }

  @override
  void dispose() {
    unawaited(_downloadEvents?.cancel());
    _downloadEvents = null;
    _vm.removeListener(_onVmChanged);
    _vm.toastHandler = null;
    _dockController.dispose();
    _frozenZero.dispose();
    _vm.dispose();
    super.dispose();
  }

  /// 原生下载完成广播：成功依赖系统通知，失败才提示
  void _onDownloadEvent(DownloadEvent event) {
    if (!event.failed || !mounted) return;
    showDownloadFailureToast(context, event.title);
  }

  // --------------------------------------------------------------- 底座显隐

  // 阈值与时长系数 px 值按屏幕密度（约 2.67）折算为 dp：
  // 96px≈36dp、120px≈45dp、2000px/s≈750dp/s、200px≈75dp、90000px≈33700dp

  double _dockHideY() => _dockHPx > 0 ? _dockHPx + 64 : 800;

  int _durationForDist(double dist) {
    final ms = (33700 / math.max(dist, 36)).round();
    if (ms < 280) return 280;
    if (ms > 650) return 650;
    return ms;
  }

  void _settleDock({required bool show, required int durMs}) {
    if (show == _dockLastTarget &&
        _dockController.isAnimating &&
        (durMs - _dockRunningDur).abs() <= 60) {
      return;
    }
    _dockLastTarget = show;
    _dockRunningDur = durMs;
    _dockController.stop();
    if (show && _dockGone) {
      setState(() => _dockGone = false);
    }
    _dockController.duration = Duration(milliseconds: durMs);
    // 中断时该 Future 永不完成
    unawaited(
      _dockController.animateTo(show ? 0 : 1).then((_) {
        if (!show && mounted) {
          setState(() => _dockGone = true);
        }
      }),
    );
  }

  /// 滚动通知驱动：内容上滑隐藏、下滑显示；无法滚动时滑动显示（安全网）
  bool _onScrollNotification(ScrollNotification notification) {
    final metrics = notification.metrics;
    if (metrics.axis != Axis.vertical) return false;
    // 仅靠底部预留空间可滚动时视为不可滚动页：底座保持显示
    if (metrics.maxScrollExtent <= 190) {
      if (!_dockLastTarget) _settleDock(show: true, durMs: 350);
      return false;
    }
    if (notification is ScrollUpdateNotification) {
      final delta = notification.scrollDelta ?? 0;
      if (delta != 0) {
        // 手指向下为正（与 Compose consumed.y 同向，故取反）
        final dy = -delta;
        _dockWasted = 0;
        // 已滑到底部时自动显示，避免到底后还需再滑一次
        if (metrics.extentAfter <= 0) {
          _dockAcc = 0;
          _settleDock(show: true, durMs: 350);
          return false;
        }
        final now = DateTime.now().millisecondsSinceEpoch;
        if (now - _dockAccT > 250 ||
            (_dockAcc != 0 && (_dockAcc < 0) != (dy < 0))) {
          _dockAcc = 0;
        }
        _dockAcc += dy;
        _dockAccT = now;
        if (_dockAcc.abs() > 36) {
          _settleDock(
            show: _dockAcc > 0,
            durMs: _durationForDist(_dockAcc.abs()),
          );
        }
      }
    } else if (notification is OverscrollNotification) {
      // 滑动完全不被消费时的安全网：累计超过 45dp 即显示底座
      final dy = -notification.overscroll;
      if (dy != 0) {
        if (_dockWasted != 0 && (_dockWasted < 0) != (dy < 0)) {
          _dockWasted = 0;
        }
        _dockWasted += dy;
        if (_dockWasted.abs() > 45) {
          _dockWasted = 0;
          _settleDock(show: true, durMs: 400);
        }
      }
    } else if (notification is ScrollEndNotification) {
      // 轻 flick 或本手势累计位移不足不触发
      final velocity =
          notification.dragDetails?.velocity.pixelsPerSecond.dy ?? 0;
      if (velocity.abs() > 750 && _dockAcc.abs() > 75) {
        _settleDock(
          show: velocity > 0,
          durMs: _durationForDist(
            math.max(_dockAcc.abs(), velocity.abs() * 0.3),
          ),
        );
      }
    }
    return false;
  }

  void _onVmChanged() {
    // 从任意歌曲列表选中并播放新歌曲时，确保底座可见
    final key = _vm.nowPlaying?.key;
    if (key != _lastNowKey) {
      _lastNowKey = key;
      _settleDock(show: true, durMs: 350);
    }
  }

  void _showToast(String message, {bool? error}) {
    if (!mounted) return;
    AppToast.show(
      context,
      message,
      kind: error == true ? AppToastKind.error : AppToastKind.info,
    );
  }

  // --------------------------------------------------------------- 交互动作

  void _onSelectTab(int index) {
    setState(() {
      _selectedTab = index;
      _playlistSheet = null;
    });
    // 切页时收起键盘：隐藏页的搜索框可能仍持有焦点
    FocusManager.instance.primaryFocus?.unfocus();
    // 切页即显示底座：新页可能不可滚动，避免隐藏态下无处可滑
    _settleDock(show: true, durMs: 350);
  }

  /// 主页/搜索页"安装音源插件"入口：跳到设置 Tab 并展开插件管理
  void _jumpToPluginSettings() {
    setState(() {
      _selectedTab = 3;
      _settingsScrollTrigger++;
      _playlistSheet = null;
    });
  }

  bool get _settingsInPluginPage =>
      _selectedTab == 3 && (_settingsKey.currentState?.inPluginPage ?? false);

  /// 返回是否被消费；未被消费时由 PopScope 兜底交给系统
  bool _handleBack() {
    if (_lyricFullscreen) {
      final overlay = _lyricKey.currentState;
      if (overlay != null) {
        overlay.dismissAnimated();
      } else {
        setState(() => _lyricFullscreen = false);
      }
      return true;
    }
    if (_expanded) {
      final sheet = _sheetKey.currentState;
      if (sheet != null) {
        sheet.dismissAnimated();
      } else {
        setState(() {
          _expanded = false;
          _showQueue = false;
        });
      }
      return true;
    }
    if (_playlistSheet != null) {
      setState(() => _playlistSheet = null);
      _settleDock(show: true, durMs: 350);
      return true;
    }
    if (_settingsInPluginPage) {
      _settingsKey.currentState?.exitPluginPage();
      return true;
    }
    if (_selectedTab != 0) {
      setState(() => _selectedTab = 0);
      _settleDock(show: true, durMs: 350);
      return true;
    }
    return false;
  }

  // --------------------------------------------------------------- 播放器弹窗

  Future<void> _openDownloadDialog() async {
    final item = _vm.nowPlaying?.item;
    if (item == null) return;
    final quality = await showDownloadQualityDialog(context, item);
    if (quality == null || !mounted) return;
    await showDownloadStartedToast(context);
    if (!mounted) return;
    final message = await _vm.downloadItem(item, quality);
    if (!mounted) return;
    // 入队失败立即提示；已经入队的下载失败由原生事件回传
    if (message == null) showDownloadFailureToast(context, item.title);
  }

  Future<void> _openAddPlaylistDialog() async {
    final item = _vm.nowPlaying?.item;
    if (item == null) return;
    await addMediaToPlaylistWithDialog(context, widget.repository, item);
  }

  /// 切换播放音质：当前音质以 "● " 前缀 + 主色加粗标识
  Future<void> _openSwitchQualityDialog() async {
    final item = _vm.nowPlaying?.item;
    if (item == null) return;
    final current = _vm.nowPlaying;
    final currentQuality =
        (current != null && current.key == '${item.platform}:${item.id}')
        ? current.qualityKey
        : null;
    final qualities = item.qualities.keys.toList()
      ..sort((a, b) => qualityRankOf(b).compareTo(qualityRankOf(a)));
    if (qualities.isEmpty) qualities.add('320k');
    final selected = await showDialog<String>(
      context: context,
      builder: (dialogContext) {
        final theme = Theme.of(dialogContext);
        return AlertDialog(
          title: const Text('切换播放音质'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final quality in qualities)
                  TextButton(
                    onPressed: () => Navigator.pop(dialogContext, quality),
                    child: Text(
                      '${quality == currentQuality ? '● ' : ''}'
                      '${_qualitySizeLabelOf(item, quality)}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: quality == currentQuality
                            ? theme.colorScheme.primary
                            : theme.colorScheme.onSurface,
                        fontWeight: quality == currentQuality
                            ? FontWeight.bold
                            : FontWeight.normal,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
    if (selected == null) return;
    _vm.switchQuality(item, selected);
  }

  String _qualitySizeLabelOf(MediaItem item, String quality) {
    final size = item.qualities[quality]?.size;
    return size == null ? quality : '$quality · ${formatSize(size)}';
  }

  /// 对话框覆盖层：点遮罩外关闭
  Widget _dialogOverlay({
    required VoidCallback onDismiss,
    required Widget dialog,
  }) {
    return Positioned.fill(
      child: Stack(
        children: [
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: onDismiss,
              child: const ColoredBox(color: Color(0x8A000000)),
            ),
          ),
          Center(child: dialog),
        ],
      ),
    );
  }

  // --------------------------------------------------------------- 界面构建

  @override
  Widget build(BuildContext context) {
    final progressActive = !_expanded && !_lyricFullscreen;
    final canPop =
        !_expanded &&
        !_lyricFullscreen &&
        _playlistSheet == null &&
        _selectedTab == 0 &&
        !_settingsInPluginPage;
    return PopScope(
      canPop: canPop,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        // canPop 为陈旧值且无处可消费时的兜底：直接退出应用
        if (!_handleBack()) unawaited(SystemNavigator.pop());
      },
      child: Scaffold(
        body: ListenableBuilder(
          listenable: _appState,
          builder: (context, _) => Stack(
            children: [
              _buildContent(),
              // 底座常驻（显隐只做位移+透明度）：悬浮于内容与歌单详情之上
              if (!_dockGone) _buildDock(progressActive),
              if (_expanded) _buildPlayerSheet(),
              if (_lyricFullscreen)
                Positioned.fill(
                  child: _LyricFullscreenOverlay(
                    key: _lyricKey,
                    viewModel: _vm,
                    onClosed: () {
                      if (mounted) setState(() => _lyricFullscreen = false);
                    },
                  ),
                ),
              if (_vm.playError != null)
                _dialogOverlay(
                  onDismiss: () => _vm.playError = null,
                  dialog: AlertDialog(
                    title: const Text('播放提示'),
                    content: Text(_vm.playError!),
                    actions: [
                      TextButton(
                        onPressed: () => _vm.playError = null,
                        child: const Text('确定'),
                      ),
                    ],
                  ),
                ),
              if (_vm.playerError != null)
                _dialogOverlay(
                  onDismiss: () => _vm.playerError = null,
                  dialog: _PlayerErrorDialog(
                    message: _vm.playerError!,
                    retryVisible: _vm.playerErrorRetry,
                    onNext: () {
                      _vm.playerError = null;
                      _vm.stepNext();
                    },
                    onClose: () => _vm.playerError = null,
                    onRetry: _vm.retryLowerQuality,
                  ),
                ),
              if (_importNotice)
                _dialogOverlay(
                  onDismiss: () => setState(() => _importNotice = false),
                  dialog: AlertDialog(
                    title: const Text('导入歌单'),
                    content: const Text('歌单导入功能暂未开放，敬请期待'),
                    actions: [
                      TextButton(
                        onPressed: () => setState(() => _importNotice = false),
                        child: const Text('确定'),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// 内容层：四页常驻 + 歌单详情全屏页（盖在内容之上、悬浮底座之下）
  Widget _buildContent() {
    return Positioned.fill(
      child: NotificationListener<ScrollNotification>(
        onNotification: _onScrollNotification,
        child: Stack(
          children: [
            Positioned.fill(
              child: SafeArea(
                bottom: false,
                child: IndexedStack(
                  index: _selectedTab,
                  children: [
                    HomeScreen(
                      sourceService: widget.sourceService,
                      repository: widget.repository,
                      onPlayMedia: _vm.playMediaItem,
                      onInstallPlugin: _jumpToPluginSettings,
                    ),
                    LibraryScreen(
                      repository: widget.repository,
                      onOpenPlaylist: (name) {
                        setState(() => _playlistSheet = name);
                        _settleDock(show: true, durMs: 350);
                      },
                      onImportPlaylist: () =>
                          setState(() => _importNotice = true),
                    ),
                    SearchScreen(
                      sourceService: widget.sourceService,
                      repository: widget.repository,
                      onPlayMedia: _vm.playMediaItem,
                      onInstallPlugin: _jumpToPluginSettings,
                      onShowDock: () => _settleDock(show: true, durMs: 350),
                    ),
                    SettingsScreen(
                      key: _settingsKey,
                      sourceService: widget.sourceService,
                      repository: widget.repository,
                      scrollTrigger: _settingsScrollTrigger,
                    ),
                  ],
                ),
              ),
            ),
            if (_playlistSheet != null) _buildPlaylistSheet(),
          ],
        ),
      ),
    );
  }

  Widget _buildPlaylistSheet() {
    final name = _playlistSheet!;
    return Positioned.fill(
      child: ListenableBuilder(
        listenable: widget.repository,
        builder: (context, _) {
          final songs = widget.repository.playlistSongs(name);
          return PlaylistDetailScreen(
            name: name,
            songs: songs,
            onPlay: (record) {
              final items = [for (final song in songs) song.toMediaItem()];
              final index = items.indexWhere(
                (item) =>
                    item.platform == record.platform && item.id == record.id,
              );
              if (index >= 0) {
                _vm.playItems(items, index);
              } else {
                _vm.playMediaItem(record.toMediaItem(), const []);
              }
            },
            onRemove: (record) => unawaited(
              widget.repository.removeFromPlaylist(name, record.key),
            ),
            onDeletePlaylist: name == AppRepository.favoriteSheet
                ? null
                : () {
                    unawaited(widget.repository.deletePlaylist(name));
                    setState(() => _playlistSheet = null);
                    _settleDock(show: true, durMs: 350);
                  },
            onClose: () {
              setState(() => _playlistSheet = null);
              _settleDock(show: true, durMs: 350);
            },
          );
        },
      ),
    );
  }

  Widget _buildDock(bool progressActive) {
    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      child: _MeasureSize(
        onChanged: (size) => _dockHPx = size.height,
        child: AnimatedBuilder(
          animation: _dockController,
          builder: (context, child) {
            final t = _dockController.value;
            return Transform.translate(
              offset: Offset(0, t * _dockHideY()),
              child: Opacity(opacity: 1 - t, child: child),
            );
          },
          child: BottomPlayerDock(
            now: _vm.nowPlaying,
            playing: _vm.playing,
            buffering: _vm.buffering,
            positionMs: progressActive ? _vm.positionMs : _frozenZero,
            durationMs: progressActive ? _vm.durationMs : _frozenZero,
            onPrev: _vm.stepPrev,
            onToggle: _vm.togglePlay,
            onNext: _vm.stepNext,
            onOpenPlayer: () {
              setState(() {
                _showQueue = false;
                _expanded = true;
              });
            },
            onSeek: _vm.seekTo,
            selectedTab: _selectedTab,
            onSelectTab: _onSelectTab,
          ),
        ),
      ),
    );
  }

  Widget _buildPlayerSheet() {
    final now = _vm.nowPlaying;
    final favorites = widget.repository.favorites;
    return Positioned.fill(
      child: PlayerSheet(
        key: _sheetKey,
        now: now,
        playing: _vm.playing,
        buffering: _vm.buffering,
        queue: _vm.playQueue,
        queueIndex: _vm.queueIndex,
        positionMs: _vm.positionMs,
        durationMs: _vm.durationMs,
        lyricLines: _vm.lyricLines,
        lyricLoading: _vm.lyricLoading,
        onToggle: _vm.togglePlay,
        onPrev: _vm.stepPrev,
        onNext: _vm.stepNext,
        onSeek: _vm.seekTo,
        onPlayAt: _vm.playAt,
        isFavorite: now != null && favorites.contains(now.key),
        onToggleFavorite: () {
          final current = _vm.nowPlaying;
          if (current != null) {
            unawaited(widget.repository.toggleFavorite(current.item));
          }
        },
        onOpenAddPlaylist: () => unawaited(_openAddPlaylistDialog()),
        onOpenDownload: () => unawaited(_openDownloadDialog()),
        onOpenSwitchQuality: () => unawaited(_openSwitchQualityDialog()),
        onClose: () {
          setState(() {
            _expanded = false;
            _showQueue = false;
          });
        },
        showQueue: _showQueue,
        onToggleQueue: () => setState(() => _showQueue = !_showQueue),
        playMode: _vm.playMode,
        onModeChange: (mode) => _vm.playMode = mode,
        onOpenLyricFullscreen: () => setState(() => _lyricFullscreen = true),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 全屏歌词覆盖层
// ---------------------------------------------------------------------------

class _LyricFullscreenOverlay extends StatefulWidget {
  const _LyricFullscreenOverlay({
    super.key,
    required this.viewModel,
    required this.onClosed,
  });

  final MainViewModel viewModel;
  final VoidCallback onClosed;

  @override
  State<_LyricFullscreenOverlay> createState() =>
      _LyricFullscreenOverlayState();
}

class _LyricFullscreenOverlayState extends State<_LyricFullscreenOverlay>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 300),
  );

  bool _closing = false;
  double? _navBottom;

  @override
  void initState() {
    super.initState();
    // 全屏沉浸：进入隐藏系统栏，退出恢复
    unawaited(
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky),
    );
    unawaited(_setKeepScreenOn(true));
    _controller.forward();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // 打开首帧快照一次导航栏高度并永久冻结
    _navBottom ??= MediaQuery.viewPaddingOf(context).bottom;
  }

  /// 先播退出动画，动画播完才真正关闭
  void dismissAnimated() {
    if (_closing) return;
    _closing = true;
    _controller.duration = const Duration(milliseconds: 250);
    _controller.reverse().whenCompleteOrCancel(() {
      if (mounted) widget.onClosed();
    });
  }

  @override
  void dispose() {
    unawaited(SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge));
    unawaited(_setKeepScreenOn(false));
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final viewModel = widget.viewModel;
    final now = viewModel.nowPlaying;
    return CoverGradientBuilder(
      artwork: now?.item.artwork,
      builder: (context, start, end) {
        final light =
            (start.computeLuminance() + end.computeLuminance()) / 2 > 0.6;
        final baseColor = light ? Colors.black : Colors.white;
        return AnnotatedRegion<SystemUiOverlayStyle>(
          value: SystemUiOverlayStyle(
            statusBarIconBrightness: light ? Brightness.dark : Brightness.light,
            systemNavigationBarIconBrightness: light
                ? Brightness.dark
                : Brightness.light,
          ),
          child: AnimatedBuilder(
            animation: _controller,
            builder: (context, child) {
              final t = _controller.value;
              // 进入：淡入 + 自底部上滑；退出：淡出 + 轻微缩小
              final offsetY = _closing
                  ? 0.0
                  : (1 - t) * MediaQuery.sizeOf(context).height;
              final scale = _closing ? 1 - 0.04 * (1 - t) : 1.0;
              return Opacity(
                opacity: t,
                child: Transform.translate(
                  offset: Offset(0, offsetY),
                  child: Transform.scale(scale: scale, child: child),
                ),
              );
            },
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [start, end],
                ),
              ),
              child: GestureDetector(
                // 独立全屏层：拦截穿透点击
                behavior: HitTestBehavior.opaque,
                onTap: () {},
                child: TweenAnimationBuilder<Color?>(
                  tween: ColorTween(end: baseColor),
                  duration: const Duration(milliseconds: 600),
                  builder: (context, animated, _) {
                    final content = animated ?? baseColor;
                    final sub = content.withValues(alpha: 0.7);
                    // 全屏未播放歌词更浅，与副标题 0.7 区分
                    final inactive = content.withValues(alpha: 0.45);
                    return Padding(
                      padding: EdgeInsets.fromLTRB(24, 32, 24, _navBottom ?? 0),
                      child: Column(
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      '歌词',
                                      style: TextStyle(
                                        fontWeight: FontWeight.bold,
                                        fontSize: 20,
                                        color: content,
                                      ),
                                    ),
                                    Text(
                                      now == null
                                          ? ''
                                          : '${now.item.title} · '
                                                '${now.item.artist}',
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        fontSize: 12,
                                        color: sub,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              IconButton(
                                onPressed: dismissAnimated,
                                tooltip: '退出全屏',
                                color: content,
                                icon: const Icon(Icons.fullscreen_exit),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          Expanded(
                            child: ValueListenableBuilder<int>(
                              valueListenable: viewModel.positionMs,
                              builder: (context, positionMs, _) => LyricsView(
                                lines: viewModel.lyricLines,
                                positionMs: positionMs,
                                loading:
                                    viewModel.lyricLoading &&
                                    viewModel.nowPlaying != null,
                                playing: viewModel.playing,
                                markerFraction: 0.24,
                                fontScale: 1.35,
                                centered: true,
                                activeColor: content,
                                inactiveColor: inactive,
                                onSeek: viewModel.seekTo,
                                lineGap: 10,
                              ),
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// 播放失败对话框：5 秒倒计时自动下一曲
// ---------------------------------------------------------------------------

class _PlayerErrorDialog extends StatefulWidget {
  const _PlayerErrorDialog({
    required this.message,
    required this.retryVisible,
    required this.onNext,
    required this.onClose,
    required this.onRetry,
  });

  final String message;

  /// 是否展示"换更低音质重试"
  final bool retryVisible;
  final VoidCallback onNext;
  final VoidCallback onClose;
  final VoidCallback onRetry;

  @override
  State<_PlayerErrorDialog> createState() => _PlayerErrorDialogState();
}

class _PlayerErrorDialogState extends State<_PlayerErrorDialog> {
  static const int _countdownSeconds = 5;
  static const ButtonStyle _compactButton = ButtonStyle(
    padding: WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 8)),
  );

  int _remaining = _countdownSeconds;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _startCountdown();
  }

  @override
  void didUpdateWidget(_PlayerErrorDialog oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 消息变化即重启倒计时
    if (oldWidget.message != widget.message) {
      _timer?.cancel();
      _remaining = _countdownSeconds;
      _startCountdown();
    }
  }

  void _startCountdown() {
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) return;
      setState(() => _remaining -= 1);
      if (_remaining <= 0) {
        timer.cancel();
        widget.onNext();
      }
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('播放失败'),
      content: Text(widget.message),
      actions: [
        TextButton(
          style: _compactButton,
          onPressed: widget.onNext,
          child: Text('下一曲 (${_remaining}s)', maxLines: 1),
        ),
        TextButton(
          style: _compactButton,
          onPressed: widget.onClose,
          child: const Text('关闭', maxLines: 1),
        ),
        if (widget.retryVisible)
          TextButton(
            style: _compactButton,
            onPressed: widget.onRetry,
            child: const Text('换更低音质重试', maxLines: 1),
          ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// 布局尺寸测量：底座高度上报
// ---------------------------------------------------------------------------

class _MeasureSize extends SingleChildRenderObjectWidget {
  const _MeasureSize({required this.onChanged, required super.child});

  final ValueChanged<Size> onChanged;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _MeasureSizeRenderObject(onChanged);

  @override
  void updateRenderObject(
    BuildContext context,
    _MeasureSizeRenderObject renderObject,
  ) {
    renderObject.onChanged = onChanged;
  }
}

class _MeasureSizeRenderObject extends RenderProxyBox {
  _MeasureSizeRenderObject(this.onChanged);

  ValueChanged<Size> onChanged;
  Size? _oldSize;

  @override
  void performLayout() {
    super.performLayout();
    final size = child?.size;
    if (size != null && size != _oldSize) {
      _oldSize = size;
      WidgetsBinding.instance.addPostFrameCallback((_) => onChanged(size));
    }
  }
}
