/// 播放器组件集：
/// 底部悬浮播放底座、全屏播放页、歌词视图、歌单详情页与封面取色装饰
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

import '../data/song_record.dart';
import '../models/media_models.dart';
import '../util/artwork_headers.dart';
import '../util/common_utils.dart';
import '../util/cover_colors.dart';
import '../util/lyric_parser.dart';

// ------------------------------------------------------------------ 基础部件

/// 颜色隐式动画：首帧直接落在目标色，目标变化时按给定时长过渡
class _AnimatedColor extends StatefulWidget {
  const _AnimatedColor({
    required this.target,
    this.duration = const Duration(milliseconds: 400),
    required this.builder,
  });

  final Color target;
  final Duration duration;
  final Widget Function(BuildContext context, Color color) builder;

  @override
  State<_AnimatedColor> createState() => _AnimatedColorState();
}

class _AnimatedColorState extends State<_AnimatedColor>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: widget.duration,
    value: 1,
  );
  late Color _from = widget.target;

  @override
  void didUpdateWidget(covariant _AnimatedColor old) {
    super.didUpdateWidget(old);
    if (old.target == widget.target) return;
    _from = Color.lerp(_from, old.target, _controller.value)!;
    _controller.duration = widget.duration;
    _controller.forward(from: 0);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        final t = Curves.fastOutSlowIn.transform(_controller.value);
        return widget.builder(context, Color.lerp(_from, widget.target, t)!);
      },
    );
  }
}

/// 系统状态栏/导航栏图标明暗适配：
/// 浅色背景用深色图标，离开覆盖层后自动恢复下层区域设置
class _SystemBarsEffect extends StatelessWidget {
  const _SystemBarsEffect({required this.lightBackground, required this.child});

  final bool lightBackground;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: lightBackground
            ? Brightness.dark
            : Brightness.light,
        statusBarBrightness: lightBackground
            ? Brightness.light
            : Brightness.dark,
        systemNavigationBarColor: Colors.transparent,
        systemNavigationBarIconBrightness: lightBackground
            ? Brightness.dark
            : Brightness.light,
        systemNavigationBarContrastEnforced: false,
      ),
      child: child,
    );
  }
}

/// 封面主色异步解析：命中缓存同步给出，未命中后台解析后刷新；
/// 用于播放底座与歌单页的深浅自适应
class CoverDominantBuilder extends StatefulWidget {
  const CoverDominantBuilder({
    super.key,
    required this.artwork,
    required this.builder,
  });

  final String? artwork;
  final Widget Function(BuildContext context, Color? dominant) builder;

  @override
  State<CoverDominantBuilder> createState() => _CoverDominantBuilderState();
}

class _CoverDominantBuilderState extends State<CoverDominantBuilder> {
  Color? _dominant;
  int _token = 0;

  @override
  void initState() {
    super.initState();
    _resolve();
  }

  @override
  void didUpdateWidget(covariant CoverDominantBuilder old) {
    super.didUpdateWidget(old);
    if (old.artwork != widget.artwork) _resolve(notify: true);
  }

  void _resolve({bool notify = false}) {
    final art = widget.artwork;
    final hasArt = art != null && art.isNotEmpty;
    final cached = CoverColors.cachedDominant(art);
    // 新封面尚未解析时保留旧主色，避免先闪回主题默认色
    final next = cached ?? (hasArt ? _dominant : null);
    if (notify) {
      setState(() => _dominant = next);
    } else {
      _dominant = next;
    }
    if (!hasArt || cached != null) return;
    final token = ++_token;
    CoverColors.dominant(art).then((color) {
      if (!mounted || token != _token || color == null) return;
      setState(() => _dominant = color);
    });
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, _dominant);
}

/// 封面渐变色异步解析：切换封面时先用上一封面的已解析色过渡，
/// 避免经过默认主题色造成闪烁
class CoverGradientBuilder extends StatefulWidget {
  const CoverGradientBuilder({
    super.key,
    required this.artwork,
    required this.builder,
  });

  final String? artwork;
  final Widget Function(BuildContext context, Color start, Color end) builder;

  @override
  State<CoverGradientBuilder> createState() => _CoverGradientBuilderState();
}

class _CoverGradientBuilderState extends State<CoverGradientBuilder> {
  (Color, Color)? _colors;
  int _token = 0;

  @override
  void initState() {
    super.initState();
    _resolve();
  }

  @override
  void didUpdateWidget(covariant CoverGradientBuilder old) {
    super.didUpdateWidget(old);
    if (old.artwork != widget.artwork) _resolve(notify: true);
  }

  void _resolve({bool notify = false}) {
    final art = widget.artwork;
    final hasArt = art != null && art.isNotEmpty;
    final next = hasArt
        ? (CoverColors.cachedGradient(art) ?? CoverColors.lastResolvedGradient)
        : null;
    if (notify) {
      setState(() => _colors = next);
    } else {
      _colors = next;
    }
    if (!hasArt || CoverColors.cachedGradient(art) != null) return;
    final token = ++_token;
    CoverColors.gradient(art).then((value) {
      if (!mounted || token != _token || value == null) return;
      setState(() => _colors = value);
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final start = _colors?.$1 ?? scheme.secondaryContainer;
    final end = _colors?.$2 ?? scheme.surfaceContainerLow;
    return _AnimatedCoverGradient(
      start: start,
      end: end,
      builder: widget.builder,
    );
  }
}

/// 渐变双色隐式动画：首帧直接落在目标色，切换封面时两色同步过渡
class _AnimatedCoverGradient extends StatefulWidget {
  const _AnimatedCoverGradient({
    required this.start,
    required this.end,
    required this.builder,
  });

  final Color start;
  final Color end;
  final Widget Function(BuildContext context, Color start, Color end) builder;

  @override
  State<_AnimatedCoverGradient> createState() => _AnimatedCoverGradientState();
}

class _AnimatedCoverGradientState extends State<_AnimatedCoverGradient>
    with SingleTickerProviderStateMixin {
  static const Duration _duration = Duration(milliseconds: 600);

  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: _duration,
    value: 1,
  );
  late Color _fromStart = widget.start;
  late Color _fromEnd = widget.end;

  @override
  void didUpdateWidget(covariant _AnimatedCoverGradient old) {
    super.didUpdateWidget(old);
    if (old.start == widget.start && old.end == widget.end) return;
    final t = Curves.fastOutSlowIn.transform(_controller.value);
    _fromStart = Color.lerp(_fromStart, old.start, t)!;
    _fromEnd = Color.lerp(_fromEnd, old.end, t)!;
    _controller.forward(from: 0);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        final t = Curves.fastOutSlowIn.transform(_controller.value);
        return widget.builder(
          context,
          Color.lerp(_fromStart, widget.start, t)!,
          Color.lerp(_fromEnd, widget.end, t)!,
        );
      },
    );
  }
}

// ------------------------------------------------------------------ 底部底座

/// 底部悬浮播放底座：随封面主色染色，含进度条与四个 Tab
class BottomPlayerDock extends StatefulWidget {
  const BottomPlayerDock({
    super.key,
    required this.now,
    required this.playing,
    required this.buffering,
    required this.positionMs,
    required this.durationMs,
    required this.onPrev,
    required this.onToggle,
    required this.onNext,
    required this.onOpenPlayer,
    required this.onSeek,
    required this.selectedTab,
    required this.onSelectTab,
  });

  final NowPlaying? now;
  final bool playing;
  final bool buffering;
  final ValueListenable<int> positionMs;
  final ValueListenable<int> durationMs;
  final VoidCallback onPrev;
  final VoidCallback onToggle;
  final VoidCallback onNext;
  final VoidCallback onOpenPlayer;
  final ValueChanged<int> onSeek;
  final int selectedTab;
  final ValueChanged<int> onSelectTab;

  @override
  State<BottomPlayerDock> createState() => _BottomPlayerDockState();
}

class _BottomPlayerDockState extends State<BottomPlayerDock> {
  Color? _artworkBg;
  int _token = 0;

  @override
  void initState() {
    super.initState();
    _syncArtwork();
  }

  @override
  void didUpdateWidget(covariant BottomPlayerDock old) {
    super.didUpdateWidget(old);
    if (old.now?.item.artwork != widget.now?.item.artwork) _syncArtwork();
  }

  void _syncArtwork() {
    final art = widget.now?.item.artwork;
    final cached = CoverColors.cachedDominant(art);
    _artworkBg = cached;
    if (art == null || art.isEmpty || cached != null) return;
    final token = ++_token;
    CoverColors.dominant(art).then((color) {
      if (!mounted || token != _token || color == null) return;
      setState(() => _artworkBg = color);
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final navBottom = MediaQuery.viewPaddingOf(context).bottom;
    final art = widget.now?.item.artwork;
    final targetContainer = (art == null || art.isEmpty)
        ? scheme.secondaryContainer
        : (_artworkBg ?? scheme.secondaryContainer);
    return Padding(
      padding: EdgeInsets.fromLTRB(12, 4, 12, 8 + navBottom),
      child: _AnimatedColor(
        target: targetContainer,
        duration: const Duration(milliseconds: 600),
        builder: (context, container) {
          final contentTarget = container.computeLuminance() > 0.6
              ? Colors.black
              : Colors.white;
          return _AnimatedColor(
            target: contentTarget,
            duration: const Duration(milliseconds: 600),
            builder: (context, content) => _buildDock(container, content),
          );
        },
      ),
    );
  }

  Widget _buildDock(Color container, Color content) {
    final now = widget.now;
    final enabled = now != null;
    final showLoading = now?.loading == true || widget.buffering;
    final subContent = content.withValues(alpha: 0.7);
    final buttonTint = enabled ? content : content.withValues(alpha: 0.38);
    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: container,
        borderRadius: BorderRadius.circular(28),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.22),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          InkWell(
            onTap: widget.onOpenPlayer,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(
                children: [
                  _thumb(now, showLoading),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            now?.item.title ?? '暂无播放',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              color: content,
                            ),
                          ),
                          Text(
                            now != null
                                ? '${now.item.artist} · ${formatDuration(now.item.durationMs)} · ${MusicQuality.labelOf(now.qualityKey)}${now.size != null ? ' · ${formatSize(now.size!)}' : ''} · ${now.item.platform}${now.via}'
                                : '点击搜索结果开始播放',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 12, color: subContent),
                          ),
                        ],
                      ),
                    ),
                  ),
                  Transform.translate(
                    offset: const Offset(8, 0),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          onPressed: enabled ? widget.onPrev : null,
                          tooltip: '上一首',
                          color: buttonTint,
                          disabledColor: buttonTint,
                          icon: const Icon(Icons.skip_previous),
                        ),
                        IconButton(
                          onPressed: enabled ? widget.onToggle : null,
                          tooltip: '播放暂停',
                          color: buttonTint,
                          disabledColor: buttonTint,
                          icon: Icon(
                            widget.playing ? Icons.pause : Icons.play_arrow,
                          ),
                        ),
                        IconButton(
                          onPressed: enabled ? widget.onNext : null,
                          tooltip: '下一首',
                          color: buttonTint,
                          disabledColor: buttonTint,
                          icon: const Icon(Icons.skip_next),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: SizedBox(
              height: 16,
              child: ValueListenableBuilder<int>(
                valueListenable: widget.positionMs,
                builder: (context, pos, _) => ValueListenableBuilder<int>(
                  valueListenable: widget.durationMs,
                  builder: (context, dur, _) => _DockSeekBar(
                    positionMs: pos,
                    durationMs: dur,
                    contentColor: content,
                    onSeek: widget.onSeek,
                  ),
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            child: Row(
              children: [
                Expanded(
                  child: _DockTabItem(
                    label: '主页',
                    icon: Icons.home,
                    selected: widget.selectedTab == 0,
                    contentColor: content,
                    onTap: () => widget.onSelectTab(0),
                  ),
                ),
                Expanded(
                  child: _DockTabItem(
                    label: '音乐库',
                    icon: Icons.library_music,
                    selected: widget.selectedTab == 1,
                    contentColor: content,
                    onTap: () => widget.onSelectTab(1),
                  ),
                ),
                Expanded(
                  child: _DockTabItem(
                    label: '搜索',
                    icon: Icons.search,
                    selected: widget.selectedTab == 2,
                    contentColor: content,
                    onTap: () => widget.onSelectTab(2),
                  ),
                ),
                Expanded(
                  child: _DockTabItem(
                    label: '设置',
                    icon: Icons.settings,
                    selected: widget.selectedTab == 3,
                    contentColor: content,
                    onTap: () => widget.onSelectTab(3),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _thumb(NowPlaying? now, bool showLoading) {
    final art = now?.item.artwork;
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: SizedBox(
        width: 44,
        height: 44,
        child: ColoredBox(
          color: const Color(0xffdbe1ff),
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (art == null || art.isEmpty)
                const Center(child: Icon(Icons.music_note, color: Colors.white))
              else
                CachedNetworkImage(
                  imageUrl: art,
                  httpHeaders: kArtworkHeaders,
                  fit: BoxFit.cover,
                  errorWidget: (_, _, _) => const SizedBox.shrink(),
                ),
              if (showLoading)
                ColoredBox(
                  color: Colors.black.withValues(alpha: 0.45),
                  child: const Center(
                    child: SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                        color: Colors.white,
                        strokeWidth: 2,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 悬浮底座分隔线兼进度条：拖动时加粗并显示滑块
class _DockSeekBar extends StatefulWidget {
  const _DockSeekBar({
    required this.positionMs,
    required this.durationMs,
    required this.contentColor,
    required this.onSeek,
  });

  final int positionMs;
  final int durationMs;
  final Color contentColor;
  final ValueChanged<int> onSeek;

  @override
  State<_DockSeekBar> createState() => _DockSeekBarState();
}

class _DockSeekBarState extends State<_DockSeekBar> {
  bool _scrubbing = false;
  double _scrubFrac = 0;

  @override
  Widget build(BuildContext context) {
    final enabled = widget.durationMs > 0;
    final liveFrac = enabled
        ? (widget.positionMs / widget.durationMs).clamp(0.0, 1.0)
        : 0.0;
    final shownFrac = _scrubbing ? _scrubFrac : liveFrac;
    final lineH = _scrubbing ? 3.0 : 2.0;
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final dotLeft = width <= 8
            ? 0.0
            : (width * shownFrac - 4).clamp(0.0, width - 8);
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onHorizontalDragStart: enabled
              ? (d) => setState(() {
                  _scrubbing = true;
                  _scrubFrac = width <= 0
                      ? 0
                      : (d.localPosition.dx / width).clamp(0.0, 1.0);
                })
              : null,
          onHorizontalDragUpdate: enabled
              ? (d) => setState(() {
                  _scrubFrac = (_scrubFrac + (d.primaryDelta ?? 0) / width)
                      .clamp(0.0, 1.0);
                })
              : null,
          onHorizontalDragEnd: enabled
              ? (_) {
                  setState(() => _scrubbing = false);
                  widget.onSeek((_scrubFrac * widget.durationMs).toInt());
                }
              : null,
          onHorizontalDragCancel: enabled
              ? () => setState(() => _scrubbing = false)
              : null,
          child: Stack(
            children: [
              Center(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: SizedBox(
                    height: lineH,
                    child: Row(
                      children: [
                        Container(
                          width: width * shownFrac,
                          height: lineH,
                          color: widget.contentColor,
                        ),
                        Expanded(
                          child: Container(
                            height: lineH,
                            color: widget.contentColor.withValues(alpha: 0.2),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              if (_scrubbing)
                Positioned(
                  left: dotLeft,
                  top: (constraints.maxHeight - 8) / 2,
                  child: Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      color: widget.contentColor,
                      borderRadius: BorderRadius.circular(4),
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

/// 底座 Tab 项：选中态背景药丸高亮
class _DockTabItem extends StatelessWidget {
  const _DockTabItem({
    required this.label,
    required this.icon,
    required this.selected,
    required this.contentColor,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final bool selected;
  final Color contentColor;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final pill = selected
        ? contentColor.withValues(alpha: 0.22)
        : Colors.transparent;
    final tint = selected ? contentColor : contentColor.withValues(alpha: 0.62);
    return Material(
      color: pill,
      borderRadius: BorderRadius.circular(24),
      child: InkWell(
        borderRadius: BorderRadius.circular(24),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: Center(child: Icon(icon, size: 26, color: tint)),
        ),
      ),
    );
  }
}

// ------------------------------------------------------------------ 播放页

/// 全屏播放页：封面渐变幻彩背景 + 封面信息 +
/// 进度条 + 控制行 + 内嵌歌词；showQueue 时切换为队列列表
/// 经 `GlobalKey<PlayerSheetState>` 调 [PlayerSheetState.dismissAnimated] 收起
class PlayerSheet extends StatefulWidget {
  const PlayerSheet({
    super.key,
    required this.now,
    required this.playing,
    required this.buffering,
    required this.queue,
    required this.queueIndex,
    required this.positionMs,
    required this.durationMs,
    required this.lyricLines,
    required this.lyricLoading,
    required this.onToggle,
    required this.onPrev,
    required this.onNext,
    required this.onSeek,
    required this.onPlayAt,
    required this.isFavorite,
    required this.onToggleFavorite,
    required this.onOpenAddPlaylist,
    required this.onOpenDownload,
    required this.onOpenSwitchQuality,
    required this.onClose,
    required this.showQueue,
    required this.onToggleQueue,
    required this.playMode,
    required this.onModeChange,
    required this.onOpenLyricFullscreen,
  });

  final NowPlaying? now;
  final bool playing;
  final bool buffering;
  final List<MediaItem> queue;
  final int queueIndex;
  final ValueListenable<int> positionMs;
  final ValueListenable<int> durationMs;
  final List<LyricLine> lyricLines;
  final bool lyricLoading;
  final VoidCallback onToggle;
  final VoidCallback onPrev;
  final VoidCallback onNext;
  final ValueChanged<int> onSeek;
  final ValueChanged<int> onPlayAt;
  final bool isFavorite;
  final VoidCallback onToggleFavorite;
  final VoidCallback onOpenAddPlaylist;
  final VoidCallback onOpenDownload;
  final VoidCallback onOpenSwitchQuality;
  final VoidCallback onClose;
  final bool showQueue;
  final VoidCallback onToggleQueue;
  final int playMode;
  final ValueChanged<int> onModeChange;
  final VoidCallback onOpenLyricFullscreen;

  @override
  State<PlayerSheet> createState() => PlayerSheetState();
}

class PlayerSheetState extends State<PlayerSheet>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 300),
  );
  late final Animation<Offset> _offset =
      Tween(begin: const Offset(0, 1), end: Offset.zero).animate(
        CurvedAnimation(
          parent: _controller,
          curve: Curves.fastOutSlowIn,
          reverseCurve: const Cubic(0.8, 0, 0.6, 1),
        ),
      );

  double? _frozenTop;
  double? _frozenBottom;
  bool _closing = false;

  @override
  void initState() {
    super.initState();
    _controller.forward();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final padding = MediaQuery.viewPaddingOf(context);
    _frozenTop ??= padding.top;
    _frozenBottom ??= padding.bottom;
  }

  /// 先播退出动画，动画播完才真正关闭（避免固定延时与动画错位导致的闪烁）
  void dismissAnimated() {
    if (_closing) return;
    _closing = true;
    _controller.reverse().whenComplete(() {
      if (mounted) widget.onClose();
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final top = _frozenTop ?? 0;
    final bottom = _frozenBottom ?? 0;
    return CoverGradientBuilder(
      artwork: widget.now?.item.artwork,
      builder: (context, start, end) {
        final light =
            (start.computeLuminance() + end.computeLuminance()) / 2 > 0.6;
        return _SystemBarsEffect(
          lightBackground: light,
          child: SlideTransition(
            position: _offset,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () {},
              child: Material(
                color: Colors.transparent,
                child: Ink(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [start, end],
                    ),
                  ),
                  child: Padding(
                    padding: EdgeInsets.fromLTRB(0, top + 8, 0, bottom + 8),
                    child: _AnimatedColor(
                      target: light ? Colors.black : Colors.white,
                      duration: const Duration(milliseconds: 600),
                      builder: (context, content) => Column(
                        children: [
                          _buildHeader(content),
                          if (widget.showQueue)
                            Expanded(child: _buildQueue(content))
                          else
                            Expanded(child: _buildPlayer(content)),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildHeader(Color content) {
    final enabled = widget.now != null;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Row(
        children: [
          Transform.translate(
            offset: const Offset(-8, 0),
            child: IconButton(
              onPressed: dismissAnimated,
              tooltip: '关闭',
              color: content,
              icon: const Icon(Icons.keyboard_arrow_down),
            ),
          ),
          Expanded(
            child: Transform.translate(
              offset: const Offset(-8, 0),
              child: Text(
                widget.showQueue ? '播放列表' : '正在播放',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  color: content,
                ),
              ),
            ),
          ),
          IconButton(
            onPressed: enabled ? widget.onOpenDownload : null,
            tooltip: '下载',
            color: content,
            disabledColor: content,
            icon: const Icon(Icons.download),
          ),
          IconButton(
            onPressed: widget.onToggleQueue,
            tooltip: widget.showQueue ? '返回播放页' : '播放列表',
            color: content,
            icon: const Icon(Icons.queue_music),
          ),
        ],
      ),
    );
  }

  Widget _buildQueue(Color content) {
    final subContent = content.withValues(alpha: 0.7);
    final scheme = Theme.of(context).colorScheme;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 4),
          child: Row(
            children: [
              _QueueModePill(
                label: '顺序',
                icon: Icons.repeat,
                selected: widget.playMode == 0,
                contentColor: content,
                onTap: () => widget.onModeChange(0),
              ),
              const SizedBox(width: 8),
              _QueueModePill(
                label: '单曲循环',
                icon: Icons.repeat_one,
                selected: widget.playMode == 1,
                contentColor: content,
                onTap: () => widget.onModeChange(1),
              ),
              const SizedBox(width: 8),
              _QueueModePill(
                label: '随机',
                icon: Icons.shuffle,
                selected: widget.playMode == 2,
                contentColor: content,
                onTap: () => widget.onModeChange(2),
              ),
            ],
          ),
        ),
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.symmetric(vertical: 4),
            itemCount: widget.queue.length,
            itemBuilder: (context, index) {
              final item = widget.queue[index];
              final active = index == widget.queueIndex;
              return InkWell(
                onTap: () => widget.onPlayAt(index),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: ListTile(
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 4,
                    ),
                    leading: SizedBox(
                      width: 44,
                      height: 44,
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(10),
                        child: ColoredBox(
                          color: active
                              ? scheme.primaryContainer
                              : const Color(0xffdbe1ff),
                          child: (item.artwork == null || item.artwork!.isEmpty)
                              ? Center(
                                  child: Icon(
                                    Icons.music_note,
                                    color: active
                                        ? scheme.onPrimaryContainer
                                        : Colors.white,
                                  ),
                                )
                              : CachedNetworkImage(
                                  imageUrl: item.artwork!,
                                  httpHeaders: kArtworkHeaders,
                                  fit: BoxFit.cover,
                                  errorWidget: (_, _, _) =>
                                      const SizedBox.shrink(),
                                ),
                        ),
                      ),
                    ),
                    title: Text(
                      item.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontWeight: active
                            ? FontWeight.bold
                            : FontWeight.normal,
                        color: content,
                      ),
                    ),
                    subtitle: Text(
                      '${item.artist} · ${item.platform}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: subContent),
                    ),
                    trailing: active && widget.playing
                        ? Icon(Icons.equalizer, color: content)
                        : null,
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildPlayer(Color content) {
    final subContent = content.withValues(alpha: 0.7);
    final lyricInactive = content.withValues(alpha: 0.45);
    final now = widget.now;
    final art = now?.item.artwork;
    final hasArt = art != null && art.isNotEmpty;
    return LayoutBuilder(
      builder: (context, constraints) {
        // 封面固定 320dp，高度不足时压缩并给歌词留空间
        final coverSize = math.min(
          320.0,
          math.max(96.0, constraints.maxHeight - 371),
        );
        return Column(
          children: [
            const SizedBox(height: 12),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Center(
                child: SizedBox(
                  width: coverSize,
                  height: coverSize,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(16),
                    child: ColoredBox(
                      color: const Color(0xffdbe1ff),
                      child: hasArt
                          ? CachedNetworkImage(
                              imageUrl: art,
                              httpHeaders: kArtworkHeaders,
                              fit: BoxFit.cover,
                              errorWidget: (_, _, _) => const Center(
                                child: Icon(
                                  Icons.music_note,
                                  size: 112,
                                  color: Colors.white,
                                ),
                              ),
                            )
                          : const Center(
                              child: Icon(
                                Icons.music_note,
                                size: 112,
                                color: Colors.white,
                              ),
                            ),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 24),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Expanded(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          now?.item.title ?? '暂无播放',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 22,
                            fontWeight: FontWeight.bold,
                            color: content,
                          ),
                        ),
                        Text(
                          now?.item.artist ?? '',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 16, color: content),
                        ),
                        Text(
                          now != null
                              ? '${formatDuration(now.item.durationMs)} · ${MusicQuality.labelOf(now.qualityKey)}${now.size != null ? ' · ${formatSize(now.size!)}' : ''} · ${now.item.platform}${now.via}'
                              : '从搜索或歌单中选择歌曲播放',
                          style: TextStyle(fontSize: 12, color: subContent),
                        ),
                      ],
                    ),
                  ),
                  Transform.translate(
                    offset: const Offset(8, 12),
                    child: IconButton(
                      onPressed: now != null
                          ? widget.onOpenSwitchQuality
                          : null,
                      tooltip: '音质',
                      color: content,
                      disabledColor: content,
                      icon: const Icon(Icons.high_quality),
                    ),
                  ),
                ],
              ),
            ),
            _PlayerSeekZone(
              trackKey: now?.key,
              positionMs: widget.positionMs,
              durationMs: widget.durationMs,
              timeColor: subContent,
              contentColor: content,
              onSeek: widget.onSeek,
            ),
            _buildControls(content),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '歌词',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        color: content,
                      ),
                    ),
                  ),
                  SizedBox(
                    width: 32,
                    height: 32,
                    child: IconButton(
                      padding: EdgeInsets.zero,
                      onPressed: widget.onOpenLyricFullscreen,
                      tooltip: '全屏歌词',
                      color: content,
                      icon: const Icon(Icons.fullscreen, size: 20),
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: ValueListenableBuilder<int>(
                  valueListenable: widget.positionMs,
                  builder: (context, pos, _) => LyricsView(
                    lines: widget.lyricLines,
                    positionMs: pos,
                    loading: widget.lyricLoading && now != null,
                    playing: widget.playing,
                    centered: true,
                    activeColor: content,
                    inactiveColor: lyricInactive,
                    onSeek: widget.onSeek,
                    showLoadingSpinner: false,
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildControls(Color content) {
    final enabled = widget.now != null;
    final loading = widget.now?.loading == true || widget.buffering;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          IconButton(
            onPressed: enabled ? widget.onToggleFavorite : null,
            tooltip: '收藏',
            color: content,
            disabledColor: content,
            icon: Icon(
              widget.isFavorite ? Icons.favorite : Icons.favorite_border,
            ),
          ),
          SizedBox(
            width: 48,
            height: 48,
            child: IconButton(
              padding: EdgeInsets.zero,
              onPressed: enabled ? widget.onPrev : null,
              tooltip: '上一首',
              color: content,
              disabledColor: content,
              iconSize: 36,
              icon: const Icon(Icons.skip_previous),
            ),
          ),
          if (loading && enabled)
            SizedBox(
              width: 64,
              height: 64,
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: CircularProgressIndicator(
                  color: content,
                  strokeWidth: 3,
                ),
              ),
            )
          else
            SizedBox(
              width: 64,
              height: 64,
              child: IconButton(
                padding: EdgeInsets.zero,
                onPressed: enabled ? widget.onToggle : null,
                tooltip: '播放',
                color: content,
                disabledColor: content,
                iconSize: 54,
                icon: Icon(widget.playing ? Icons.pause : Icons.play_arrow),
              ),
            ),
          SizedBox(
            width: 48,
            height: 48,
            child: IconButton(
              padding: EdgeInsets.zero,
              onPressed: enabled ? widget.onNext : null,
              tooltip: '下一首',
              color: content,
              disabledColor: content,
              iconSize: 36,
              icon: const Icon(Icons.skip_next),
            ),
          ),
          IconButton(
            onPressed: enabled ? widget.onOpenAddPlaylist : null,
            tooltip: '加歌单',
            color: content,
            disabledColor: content,
            icon: const Icon(Icons.playlist_add),
          ),
        ],
      ),
    );
  }
}

/// 播放模式药丸（顺序 / 单曲循环 / 随机）
class _QueueModePill extends StatelessWidget {
  const _QueueModePill({
    required this.label,
    required this.icon,
    required this.selected,
    required this.contentColor,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final bool selected;
  final Color contentColor;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: selected
          ? contentColor.withValues(alpha: 0.22)
          : Colors.transparent,
      shape: StadiumBorder(
        side: selected
            ? BorderSide.none
            : BorderSide(color: contentColor.withValues(alpha: 0.35)),
      ),
      child: InkWell(
        customBorder: const StadiumBorder(),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: SizedBox(
            height: 32,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 14, color: contentColor),
                const SizedBox(width: 6),
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: selected ? FontWeight.bold : FontWeight.normal,
                    color: contentColor,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 自定义进度条：始终可见的圆点滑块；拖动时本地预览、松手后暂持目标进度
class _PlayerSeekZone extends StatefulWidget {
  const _PlayerSeekZone({
    required this.trackKey,
    required this.positionMs,
    required this.durationMs,
    required this.timeColor,
    required this.contentColor,
    required this.onSeek,
  });

  final String? trackKey;
  final ValueListenable<int> positionMs;
  final ValueListenable<int> durationMs;
  final Color timeColor;
  final Color contentColor;
  final ValueChanged<int> onSeek;

  @override
  State<_PlayerSeekZone> createState() => _PlayerSeekZoneState();
}

class _PlayerSeekZoneState extends State<_PlayerSeekZone> {
  bool _seeking = false;
  double _seekFrac = 0;
  int? _seekTarget;
  Timer? _seekClearTimer;

  @override
  void initState() {
    super.initState();
    widget.positionMs.addListener(_onPositionTick);
  }

  @override
  void didUpdateWidget(covariant _PlayerSeekZone old) {
    super.didUpdateWidget(old);
    if (old.positionMs != widget.positionMs) {
      old.positionMs.removeListener(_onPositionTick);
      widget.positionMs.addListener(_onPositionTick);
    }
    if (old.trackKey != widget.trackKey) {
      _seekClearTimer?.cancel();
      _seekClearTimer = null;
      _seeking = false;
      _seekFrac = 0;
      _seekTarget = null;
    }
  }

  void _onPositionTick() {
    final target = _seekTarget;
    if (target == null) return;
    if ((widget.positionMs.value - target).abs() < 1500) {
      _seekClearTimer?.cancel();
      _seekClearTimer = null;
      if (!mounted) return;
      setState(() => _seekTarget = null);
    }
  }

  @override
  void dispose() {
    _seekClearTimer?.cancel();
    widget.positionMs.removeListener(_onPositionTick);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: ValueListenableBuilder<int>(
        valueListenable: widget.positionMs,
        builder: (context, positionMs, _) => ValueListenableBuilder<int>(
          valueListenable: widget.durationMs,
          builder: (context, durationMs, _) {
            final hasDur = durationMs > 0;
            final scheme = Theme.of(context).colorScheme;
            final progressActive = hasDur
                ? widget.contentColor.withValues(alpha: 0.6)
                : scheme.onSurface.withValues(alpha: 0.38);
            final progressInactive = hasDur
                ? widget.contentColor.withValues(alpha: 0.5)
                : scheme.onSurface.withValues(alpha: 0.12);
            final dotColor = hasDur
                ? widget.contentColor
                : scheme.onSurface.withValues(alpha: 0.38);
            final liveFrac = hasDur
                ? (positionMs / durationMs).clamp(0.0, 1.0)
                : 0.0;
            final shownMs = _seeking && hasDur
                ? (_seekFrac * durationMs).round()
                : (_seekTarget != null && hasDur ? _seekTarget! : positionMs);
            final frac = _seeking ? _seekFrac : liveFrac;
            return Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  height: 28,
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final width = constraints.maxWidth;
                      final dotLeft = width <= 10
                          ? 0.0
                          : (width * frac - 5).clamp(0.0, width - 10);
                      return GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onHorizontalDragStart: hasDur
                            ? (d) => setState(() {
                                _seeking = true;
                                _seekFrac = width <= 0
                                    ? 0
                                    : (d.localPosition.dx / width).clamp(
                                        0.0,
                                        1.0,
                                      );
                              })
                            : null,
                        onHorizontalDragUpdate: hasDur
                            ? (d) => setState(() {
                                _seekFrac =
                                    (_seekFrac + (d.primaryDelta ?? 0) / width)
                                        .clamp(0.0, 1.0);
                              })
                            : null,
                        onHorizontalDragEnd: hasDur
                            ? (_) {
                                setState(() => _seeking = false);
                                final target = (_seekFrac * durationMs).round();
                                _seekTarget = target;
                                _seekClearTimer?.cancel();
                                _seekClearTimer = Timer(
                                  const Duration(milliseconds: 5000),
                                  () {
                                    if (mounted) {
                                      setState(() => _seekTarget = null);
                                    }
                                  },
                                );
                                widget.onSeek(target);
                              }
                            : null,
                        onHorizontalDragCancel: hasDur
                            ? () => setState(() => _seeking = false)
                            : null,
                        child: Stack(
                          children: [
                            Center(
                              child: Row(
                                children: [
                                  Container(
                                    width: width * frac,
                                    height: 5,
                                    decoration: BoxDecoration(
                                      color: progressActive,
                                      borderRadius: BorderRadius.circular(4),
                                    ),
                                  ),
                                  Expanded(
                                    child: Align(
                                      alignment: Alignment.center,
                                      child: Container(
                                        height: 3,
                                        decoration: BoxDecoration(
                                          color: progressInactive,
                                          borderRadius: BorderRadius.circular(
                                            4,
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            Positioned(
                              left: dotLeft,
                              top: 9,
                              child: Container(
                                width: 10,
                                height: 10,
                                decoration: BoxDecoration(
                                  color: dotColor,
                                  shape: BoxShape.circle,
                                ),
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                ),
                Row(
                  children: [
                    Text(
                      formatDuration(shownMs),
                      style: TextStyle(fontSize: 12, color: widget.timeColor),
                    ),
                    const Spacer(),
                    Text(
                      formatDuration(durationMs),
                      style: TextStyle(fontSize: 12, color: widget.timeColor),
                    ),
                  ],
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

// ------------------------------------------------------------------ 歌词视图

/// 歌词视图：本地位移插值 ticker（有逐字歌词 60ms、否则 80ms）+ 锚点跟随滚动；用户拖动暂停跟随，松手 3 秒后自动恢复
class LyricsView extends StatefulWidget {
  const LyricsView({
    super.key,
    required this.lines,
    required this.positionMs,
    this.loading = false,
    this.playing = true,
    this.markerFraction = 0.24,
    this.fontScale = 1,
    this.centered = false,
    this.activeColor,
    this.inactiveColor,
    this.onSeek,
    this.showLoadingSpinner = true,
    this.lineGap = 5,
  });

  final List<LyricLine> lines;
  final int positionMs;
  final bool loading;
  final bool playing;
  final double markerFraction;
  final double fontScale;
  final bool centered;
  final Color? activeColor;
  final Color? inactiveColor;
  final ValueChanged<int>? onSeek;
  final bool showLoadingSpinner;
  final double lineGap;

  @override
  State<LyricsView> createState() => _LyricsViewState();
}

class _LyricsViewState extends State<LyricsView> with WidgetsBindingObserver {
  final ScrollController _controller = ScrollController();
  final Stopwatch _clock = Stopwatch()..start();
  final Map<int, GlobalKey> _itemKeys = {};

  Timer? _ticker;
  Timer? _resumeFollowTimer;

  bool _follow = true;
  bool _uiActive = true;
  bool _hasKaraoke = false;
  int _lastAnchorIndex = 0;
  int? _lastSeenIndex;

  late int _basePosMs = widget.positionMs;
  late int _baseUptimeMs = _clock.elapsedMilliseconds;
  late int _displayPosMs = widget.positionMs;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    _uiActive = lifecycle == null || lifecycle == AppLifecycleState.resumed;
    _resetForLines();
    _restartTicker();
  }

  @override
  void didUpdateWidget(covariant LyricsView old) {
    super.didUpdateWidget(old);
    if (!identical(old.lines, widget.lines)) {
      _resetForLines();
      _restartTicker();
      return;
    }
    if (old.positionMs != widget.positionMs) {
      _basePosMs = widget.positionMs;
      _baseUptimeMs = _clock.elapsedMilliseconds;
      if (!widget.playing) _displayPosMs = widget.positionMs;
    }
    if (old.playing != widget.playing) _restartTicker();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final active = state == AppLifecycleState.resumed;
    if (active == _uiActive) return;
    _uiActive = active;
    if (active) {
      _restartTicker();
    } else {
      _ticker?.cancel();
      _ticker = null;
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _ticker?.cancel();
    _resumeFollowTimer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _resetForLines() {
    _itemKeys.clear();
    for (var i = 0; i < widget.lines.length; i++) {
      _itemKeys[i] = GlobalKey();
    }
    _hasKaraoke = widget.lines.any((line) => line.words.isNotEmpty);
    _basePosMs = widget.positionMs;
    _baseUptimeMs = _clock.elapsedMilliseconds;
    _displayPosMs = widget.positionMs;
    _follow = true;
    _lastSeenIndex = null;
    _lastAnchorIndex = _currentIndexFor(_displayPosMs);
    _resumeFollowTimer?.cancel();
    _resumeFollowTimer = null;
    final index = _lastAnchorIndex;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(_scrollToAnchor(index, false));
    });
  }

  void _restartTicker() {
    _ticker?.cancel();
    _ticker = null;
    if (!widget.playing) {
      _displayPosMs = _basePosMs;
      return;
    }
    if (!_uiActive) return;
    final stepMs = _hasKaraoke ? 60 : 80;
    _ticker = Timer.periodic(Duration(milliseconds: stepMs), (_) {
      if (!mounted) return;
      setState(() {
        _displayPosMs =
            _basePosMs + (_clock.elapsedMilliseconds - _baseUptimeMs);
      });
    });
  }

  int _currentIndexFor(int posMs) {
    final lines = widget.lines;
    if (lines.isEmpty) return 0;
    var lo = 0;
    var hi = lines.length - 1;
    var ans = 0;
    while (lo <= hi) {
      final mid = (lo + hi) >> 1;
      if (lines[mid].timeMs <= posMs) {
        ans = mid;
        lo = mid + 1;
      } else {
        hi = mid - 1;
      }
    }
    return ans;
  }

  ({double top, double height})? _itemViewportMetrics(int index) {
    final ro =
        _itemKeys[index]?.currentContext?.findRenderObject() as RenderBox?;
    if (ro == null || !ro.attached || !_controller.hasClients) return null;
    final viewport = RenderAbstractViewport.maybeOf(ro);
    if (viewport == null) return null;
    final itemOffset = viewport.getOffsetToReveal(ro, 0.0).offset;
    return (
      top: itemOffset - _controller.position.pixels,
      height: ro.size.height,
    );
  }

  double _averageItemHeight() {
    var total = 0.0;
    var count = 0;
    for (final key in _itemKeys.values) {
      final ro = key.currentContext?.findRenderObject() as RenderBox?;
      if (ro != null && ro.attached && ro.hasSize && ro.size.height > 0) {
        total += ro.size.height;
        count++;
      }
    }
    if (count == 0) return 32;
    return total / count;
  }

  double _clampScroll(double value) {
    final position = _controller.position;
    return value.clamp(position.minScrollExtent, position.maxScrollExtent);
  }

  Future<void> _scrollToAnchor(int index, bool animated) async {
    if (!mounted || !_controller.hasClients || widget.lines.isEmpty) return;
    final i = index.clamp(0, widget.lines.length - 1);
    final position = _controller.position;
    final anchorPx = position.viewportDimension * widget.markerFraction;
    try {
      final rect = _itemViewportMetrics(i);
      if (rect != null) {
        final visible =
            rect.top + rect.height > 0 && rect.top < position.viewportDimension;
        if (visible) {
          final delta = rect.top + rect.height / 2 - anchorPx;
          if (delta.abs() > 1) {
            if (animated) {
              await _controller.animateTo(
                _clampScroll(position.pixels + delta),
                duration: const Duration(milliseconds: 150),
                curve: Curves.fastOutSlowIn,
              );
            } else {
              _controller.jumpTo(_clampScroll(position.pixels + delta));
            }
          }
          return;
        }
      }
      final avg = _averageItemHeight();
      final estimate = _clampScroll(avg * i + avg / 2 - anchorPx);
      if (animated) {
        await _controller.animateTo(
          estimate,
          duration: const Duration(milliseconds: 200),
          curve: Curves.fastOutSlowIn,
        );
      } else {
        _controller.jumpTo(estimate);
      }
      // 两阶段校正：估算落地后用实测偏差修正
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted || !_controller.hasClients) return;
      final after = _itemViewportMetrics(i);
      if (after == null) return;
      final fix = after.top + after.height / 2 - anchorPx;
      if (animated) {
        if (fix.abs() > 2 && fix.abs() < after.height) {
          await _controller.animateTo(
            _clampScroll(_controller.position.pixels + fix),
            duration: const Duration(milliseconds: 200),
            curve: Curves.fastOutSlowIn,
          );
        } else if (fix.abs() >= after.height) {
          _controller.jumpTo(_clampScroll(_controller.position.pixels + fix));
        }
      } else {
        if (fix.abs() > 1) {
          _controller.jumpTo(_clampScroll(_controller.position.pixels + fix));
        }
      }
    } catch (_) {
      // 滚动期间状态变化导致的异常直接忽略
    }
  }

  void _onCurrentIndexChanged(int index) {
    if (!_follow) {
      _lastAnchorIndex = index;
      return;
    }
    final jumped = (index - _lastAnchorIndex).abs() > 3;
    _lastAnchorIndex = index;
    unawaited(_scrollToAnchor(index, !jumped));
  }

  bool _onScrollNotification(ScrollNotification notification) {
    if (notification is ScrollStartNotification) {
      if (notification.dragDetails != null) {
        _resumeFollowTimer?.cancel();
        _resumeFollowTimer = null;
        _follow = false;
      }
    } else if (notification is ScrollEndNotification) {
      if (notification.dragDetails != null) {
        _resumeFollowTimer?.cancel();
        _resumeFollowTimer = Timer(const Duration(milliseconds: 3000), () {
          if (!mounted) return;
          _follow = true;
          final index = _currentIndexFor(_displayPosMs);
          _lastAnchorIndex = index;
          unawaited(_scrollToAnchor(index, true));
        });
      }
    }
    return false;
  }

  Widget _buildStatusText(String text, Color color, Color spinnerColor) {
    if (widget.showLoadingSpinner) {
      return Center(
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: spinnerColor,
              ),
            ),
            const SizedBox(width: 8),
            Text(text, style: TextStyle(color: color)),
          ],
        ),
      );
    }
    return Align(
      alignment: Alignment.topCenter,
      child: Padding(
        padding: const EdgeInsets.only(top: 56),
        child: Text(text, style: TextStyle(color: color)),
      ),
    );
  }

  Widget _buildLine(
    int index,
    int currentIndex,
    Color activeColor,
    Color inactiveColor,
  ) {
    final line = widget.lines[index];
    final active = index == currentIndex;
    final onSeek = widget.onSeek;
    Widget content;
    if (active && line.words.isNotEmpty) {
      // 逐字卡拉OK：已唱完、当前渐变、未到用暗色
      final spans = <TextSpan>[];
      for (final word in line.words) {
        final span = word.endMs - word.startMs;
        final frac = ((_displayPosMs - word.startMs) / (span <= 0 ? 1 : span))
            .clamp(0.0, 1.0);
        final Color color;
        if (frac >= 1) {
          color = activeColor;
        } else if (frac <= 0) {
          color = inactiveColor;
        } else {
          color = Color.lerp(inactiveColor, activeColor, frac)!;
        }
        spans.add(
          TextSpan(
            text: word.text,
            style: TextStyle(color: color),
          ),
        );
      }
      content = Text.rich(
        TextSpan(children: spans),
        textAlign: widget.centered ? TextAlign.center : TextAlign.start,
        style: TextStyle(
          fontSize: 17 * widget.fontScale,
          fontWeight: FontWeight.bold,
        ),
      );
    } else {
      final text = line.text.trim().isEmpty ? ' ' : line.text;
      content = Text(
        text,
        textAlign: widget.centered ? TextAlign.center : TextAlign.start,
        style: TextStyle(
          fontSize: (active ? 17 : 14) * widget.fontScale,
          fontWeight: active ? FontWeight.bold : FontWeight.w600,
          color: active ? activeColor : inactiveColor,
        ),
      );
    }
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onSeek != null ? () => onSeek(line.timeMs) : null,
      child: Padding(
        padding: EdgeInsets.symmetric(vertical: widget.lineGap),
        child: SizedBox(width: double.infinity, child: content),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final activeColor = widget.activeColor ?? scheme.primary;
    final inactiveColor = widget.inactiveColor ?? scheme.onSurfaceVariant;
    if (widget.loading) {
      return _buildStatusText('歌词加载中', inactiveColor, activeColor);
    }
    if (widget.lines.isEmpty) {
      if (widget.showLoadingSpinner) {
        return Center(
          child: Text('暂无歌词', style: TextStyle(color: inactiveColor)),
        );
      }
      return Align(
        alignment: Alignment.topCenter,
        child: Padding(
          padding: const EdgeInsets.only(top: 56),
          child: Text('暂无歌词', style: TextStyle(color: inactiveColor)),
        ),
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final padBottom = constraints.maxHeight * 0.5;
        final index = _currentIndexFor(_displayPosMs);
        if (_lastSeenIndex != index) {
          final isFirst = _lastSeenIndex == null;
          _lastSeenIndex = index;
          if (!isFirst) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (!mounted) return;
              _onCurrentIndexChanged(index);
            });
          }
        }
        return NotificationListener<ScrollNotification>(
          onNotification: _onScrollNotification,
          child: ListView.builder(
            controller: _controller,
            padding: EdgeInsets.only(top: 16, bottom: padBottom),
            itemCount: widget.lines.length,
            itemBuilder: (context, i) => KeyedSubtree(
              key: _itemKeys[i] ??= GlobalKey(),
              child: _buildLine(i, index, activeColor, inactiveColor),
            ),
          ),
        );
      },
    );
  }
}

// ------------------------------------------------------------------ 歌单详情

/// 全屏歌单详情页：沉浸大图头 + 歌单名 + 播放全部 + 歌曲列表；移出歌曲/删除歌单走确认弹窗
class PlaylistDetailScreen extends StatefulWidget {
  const PlaylistDetailScreen({
    super.key,
    required this.name,
    required this.songs,
    required this.onPlay,
    required this.onRemove,
    this.onDeletePlaylist,
    required this.onClose,
  });

  final String name;
  final List<SongRecord> songs;
  final ValueChanged<SongRecord> onPlay;
  final ValueChanged<SongRecord> onRemove;
  final VoidCallback? onDeletePlaylist;
  final VoidCallback onClose;

  @override
  State<PlaylistDetailScreen> createState() => _PlaylistDetailScreenState();
}

class _PlaylistDetailScreenState extends State<PlaylistDetailScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 250),
  );
  late final Animation<double> _fade = CurvedAnimation(
    parent: _controller,
    curve: const Interval(0, 0.8, curve: Curves.easeOut),
  );
  late final Animation<Offset> _slide = Tween(
    begin: const Offset(0, 0.25),
    end: Offset.zero,
  ).animate(CurvedAnimation(parent: _controller, curve: Curves.fastOutSlowIn));

  @override
  void initState() {
    super.initState();
    _controller.forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _confirmDeletePlaylist() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除歌单'),
        content: Text('确定删除歌单“${widget.name}”吗？其中的歌曲将被清空。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(
              '删除',
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        ],
      ),
    );
    if (confirmed == true) widget.onDeletePlaylist?.call();
  }

  Future<void> _confirmRemoveSong(SongRecord record) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('移出歌曲'),
        content: Text('确定将“${record.title}”移出歌单吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(
              '移出',
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        ],
      ),
    );
    if (confirmed == true) widget.onRemove(record);
  }

  Widget _buildHeader(
    ColorScheme scheme,
    Color titleColor,
    Color subColor,
    Color buttonContent,
  ) {
    final firstArtwork = widget.songs.isEmpty
        ? null
        : widget.songs.first.artwork;
    final hasArt = firstArtwork != null && firstArtwork.isNotEmpty;
    return SizedBox(
      height: 360,
      child: Stack(
        fit: StackFit.expand,
        children: [
          // 仅对封面做透明渐隐，避免透明黑参与渐变产生灰黑遮罩
          ShaderMask(
            shaderCallback: (rect) => const LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Colors.white, Colors.white, Colors.transparent],
              stops: [0, 0.55, 1],
            ).createShader(rect),
            blendMode: BlendMode.dstIn,
            child: hasArt
                ? CachedNetworkImage(
                    imageUrl: firstArtwork,
                    httpHeaders: kArtworkHeaders,
                    fit: BoxFit.cover,
                    errorWidget: (_, _, _) => const SizedBox.shrink(),
                  )
                : ColoredBox(
                    color: scheme.surfaceContainerLow,
                    child: Center(
                      child: Icon(
                        Icons.music_note,
                        size: 72,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
          ),
          Padding(
            padding: const EdgeInsets.all(22),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.end,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  widget.name,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 26,
                    color: titleColor,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  '共 ${widget.songs.length} 首',
                  style: TextStyle(fontSize: 13, color: subColor),
                ),
                const SizedBox(height: 12),
                FilledButton(
                  onPressed: widget.songs.isNotEmpty
                      ? () => widget.onPlay(widget.songs.first)
                      : null,
                  style: FilledButton.styleFrom(
                    backgroundColor: titleColor,
                    foregroundColor: buttonContent,
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                  ),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.play_arrow, size: 18),
                      SizedBox(width: 6),
                      Text('播放全部'),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSongRow(SongRecord record) {
    final art = record.artwork;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: ListTile(
        onTap: () => widget.onPlay(record),
        leading: SizedBox(
          width: 48,
          height: 48,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: ColoredBox(
              color: const Color(0xffdbe1ff),
              child: (art == null || art.isEmpty)
                  ? const Center(
                      child: Icon(Icons.music_note, color: Colors.white),
                    )
                  : CachedNetworkImage(
                      imageUrl: art,
                      httpHeaders: kArtworkHeaders,
                      fit: BoxFit.cover,
                      errorWidget: (_, _, _) => const SizedBox.shrink(),
                    ),
            ),
          ),
        ),
        title: Text(
          record.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        subtitle: Text(
          '${record.artist} · ${formatDuration(record.durationMs)} · ${MusicQuality.labelOf(record.qualityKey)}${record.size != null ? ' · ${formatSize(record.size!)}' : ''} · ${record.platform}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        trailing: IconButton(
          onPressed: () => _confirmRemoveSong(record),
          tooltip: '移出歌单',
          icon: const Icon(Icons.delete_outline),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return CoverDominantBuilder(
      artwork: widget.songs.isEmpty ? null : widget.songs.first.artwork,
      builder: (context, dominant) {
        final scheme = Theme.of(context).colorScheme;
        final dark = Theme.of(context).brightness == Brightness.dark;
        final coverLight = dominant != null
            ? dominant.computeLuminance() > 0.55
            : !dark;
        final titleTarget = coverLight ? const Color(0xFF191C1E) : Colors.white;
        final subTarget = coverLight
            ? const Color(0xFF191C1E).withValues(alpha: 0.75)
            : Colors.white.withValues(alpha: 0.8);
        final buttonContentTarget = coverLight
            ? Colors.white
            : const Color(0xFF191C1E);
        return _SystemBarsEffect(
          lightBackground: coverLight,
          child: FadeTransition(
            opacity: _fade,
            child: SlideTransition(
              position: _slide,
              child: Material(
                color: scheme.surface,
                child: _AnimatedColor(
                  target: titleTarget,
                  duration: const Duration(milliseconds: 400),
                  builder: (context, titleColor) => _AnimatedColor(
                    target: subTarget,
                    duration: const Duration(milliseconds: 400),
                    builder: (context, subColor) => _AnimatedColor(
                      target: buttonContentTarget,
                      duration: const Duration(milliseconds: 400),
                      builder: (context, buttonContent) => Stack(
                        children: [
                          ListView.builder(
                            padding: const EdgeInsets.only(bottom: 190),
                            itemCount:
                                1 +
                                (widget.songs.isEmpty
                                    ? 1
                                    : widget.songs.length),
                            itemBuilder: (context, index) {
                              if (index == 0) {
                                return _buildHeader(
                                  scheme,
                                  titleColor,
                                  subColor,
                                  buttonContent,
                                );
                              }
                              if (widget.songs.isEmpty) {
                                return SizedBox(
                                  height: 200,
                                  child: Center(
                                    child: Text(
                                      '歌单为空，可从搜索结果收藏或添加歌曲',
                                      style: TextStyle(
                                        color: scheme.onSurfaceVariant,
                                      ),
                                    ),
                                  ),
                                );
                              }
                              return _buildSongRow(widget.songs[index - 1]);
                            },
                          ),
                          Positioned(
                            top: 0,
                            left: 0,
                            right: 0,
                            child: SafeArea(
                              bottom: false,
                              child: Padding(
                                padding: const EdgeInsets.only(
                                  left: 4,
                                  right: 8,
                                  top: 8,
                                ),
                                child: Row(
                                  children: [
                                    IconButton(
                                      onPressed: widget.onClose,
                                      tooltip: '返回',
                                      color: titleColor,
                                      icon: const Icon(Icons.arrow_back),
                                    ),
                                    const Spacer(),
                                    if (widget.onDeletePlaylist != null)
                                      IconButton(
                                        onPressed: _confirmDeletePlaylist,
                                        tooltip: '删除歌单',
                                        color: titleColor,
                                        icon: const Icon(Icons.delete),
                                      ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
