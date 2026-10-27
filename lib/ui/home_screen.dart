// ---------------------------------------------------------------------------
// 主页与音乐库
// - HomeScreen：问候语 + 每日推荐（平台音源筛选、榜单选择、下载/加歌单）
// - LibraryScreen：我喜欢的音乐 / 导入歌单 / 新建歌单 + 用户歌单列表
// - 共享组件：PluginSongRow / SongRowSkeleton / NoPluginPrompt / 下载与加歌单对话框
// ---------------------------------------------------------------------------

import 'dart:async';
import 'dart:math' as math;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../data/app_repository.dart';
import '../models/media_models.dart';
import '../plugin/plugin_manager.dart';
import '../service/music_source_service.dart';
import '../util/artwork_headers.dart';
import '../util/common_utils.dart';
import '../util/download_helper.dart';
import 'download_feedback.dart';

// ---------------------------------------------------------------------------
// 每日推荐持久化：日期/平台/榜单，跨天或换平台时重新抽取
// ---------------------------------------------------------------------------

const String _dailyDateKey = 'daily_date';
const String _dailyPlatformKey = 'daily_platform';
const String _dailyBoardKey = 'daily_board_id';

String _todayString() {
  final now = DateTime.now();
  String two(int value) => value.toString().padLeft(2, '0');
  return '${now.year}-${two(now.month)}-${two(now.day)}';
}

/// 问候语：按当前小时分段
String homeGreeting() {
  final hour = DateTime.now().hour;
  if (hour <= 4) return '夜深了';
  if (hour <= 8) return '早上好';
  if (hour <= 11) return '上午好';
  if (hour <= 13) return '中午好';
  if (hour <= 18) return '下午好';
  return '晚上好';
}

/// 无插件错误判断
bool isNoPluginError(Object error) => '$error'.contains('无可用插件');

/// 错误文案提取：StateError 取 message，其余取 toString，空值回退默认
String errorTextOf(Object error, String fallback) {
  final text = error is StateError ? error.message : '$error';
  return text.trim().isEmpty ? fallback : text;
}

/// 当日榜单：优先复用当天已选且仍存在的榜单，否则在热门/热歌中随取一个
Future<TopListItem> _resolveDailyBoard(
  SharedPreferences prefs,
  String platform,
  List<TopListItem> boards,
) async {
  if (prefs.getString(_dailyDateKey) == _todayString() &&
      prefs.getString(_dailyPlatformKey) == platform) {
    final savedId = prefs.getString(_dailyBoardKey);
    for (final board in boards) {
      if (board.id == savedId) return board;
    }
  }
  final hot = [
    for (final board in boards)
      if (board.title.contains('热门') || board.title.contains('热歌')) board,
  ];
  final pool = hot.isNotEmpty ? hot : boards;
  final pick = pool[math.Random().nextInt(pool.length)];
  await _saveDailyBoard(prefs, platform, pick);
  return pick;
}

Future<void> _saveDailyBoard(
  SharedPreferences prefs,
  String platform,
  TopListItem board,
) async {
  await prefs.setString(_dailyDateKey, _todayString());
  await prefs.setString(_dailyPlatformKey, platform);
  await prefs.setString(_dailyBoardKey, board.id);
}

// ---------------------------------------------------------------------------
// 主页：问候语 + 每日推荐
// ---------------------------------------------------------------------------

class HomeScreen extends StatefulWidget {
  const HomeScreen({
    super.key,
    required this.sourceService,
    required this.repository,
    required this.onPlayMedia,
    required this.onInstallPlugin,
  });

  final MusicSourceService sourceService;
  final AppRepository repository;

  /// 播放整组每日推荐列表
  final void Function(MediaItem item, List<MediaItem> queue) onPlayMedia;

  /// 无插件时跳转内嵌设置页安装
  final VoidCallback onInstallPlugin;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  List<InstalledPlugin> _sources = const [];
  bool _sourcesLoaded = false;
  String? _dailyPlatform;
  List<TopListGroup> _dailyGroups = const [];
  TopListItem? _dailyBoard;
  List<MediaItem> _dailySongs = const [];
  bool _dailyLoading = false;
  String? _dailyError;
  String _greeting = homeGreeting();
  Timer? _greetingTimer;

  /// 音源列表/榜单分组/榜单详情/补封面任务令牌：过期异步结果直接丢弃
  int _reloadToken = 0;
  int _groupsToken = 0;
  int _detailToken = 0;
  int _coverFillToken = 0;

  @override
  void initState() {
    super.initState();
    // 注册表代际驱动：内嵌设置页改插件后靠此刷新音源列表
    widget.sourceService.generation.addListener(_onRegistryChanged);
    _scheduleGreeting();
    unawaited(_reloadSources());
  }

  @override
  void dispose() {
    widget.sourceService.generation.removeListener(_onRegistryChanged);
    _greetingTimer?.cancel();
    // 使全部进行中的异步任务失效
    _reloadToken++;
    _groupsToken++;
    _detailToken++;
    _coverFillToken++;
    super.dispose();
  }

  void _onRegistryChanged() {
    if (!mounted) return;
    unawaited(_reloadSources());
  }

  void _scheduleGreeting() {
    final now = DateTime.now();
    final elapsed = now.second * 1000 + now.millisecond;
    _greetingTimer = Timer(Duration(milliseconds: 60000 - elapsed), () {
      if (!mounted) return;
      setState(() => _greeting = homeGreeting());
      _scheduleGreeting();
    });
  }

  /// 重新读取音源列表；平台失效或未选时按“当天已存平台 → 首个插件”兜底
  Future<void> _reloadSources() async {
    final token = ++_reloadToken;
    try {
      await widget.sourceService.refresh();
    } catch (_) {}
    var listed = _sources;
    try {
      listed = widget.sourceService.installedPlugins();
    } catch (_) {}
    final prefs = await SharedPreferences.getInstance();
    if (!mounted || token != _reloadToken) return;
    String? savedPlatform;
    if (prefs.getString(_dailyDateKey) == _todayString()) {
      savedPlatform = prefs.getString(_dailyPlatformKey);
    }
    final current = _dailyPlatform;
    final currentValid =
        current != null && listed.any((p) => p.name == current);
    String? next;
    if (currentValid) {
      next = current;
    } else {
      final savedValid =
          savedPlatform != null && listed.any((p) => p.name == savedPlatform);
      next = savedValid
          ? savedPlatform
          : (listed.isNotEmpty ? listed.first.name : current);
    }
    final platformChanged = next != _dailyPlatform;
    setState(() {
      _sources = listed;
      _sourcesLoaded = true;
      _dailyPlatform = next;
      if (platformChanged) {
        _dailyGroups = const [];
        _dailyBoard = null;
        _dailySongs = const [];
        _dailyError = null;
      }
    });
    if (platformChanged) {
      _groupsToken++;
      _detailToken++;
      await _loadGroups();
    }
  }

  /// 拉取所选平台的榜单分组并确定当日榜单
  Future<void> _loadGroups() async {
    final platform = _dailyPlatform;
    if (platform == null || !_sourcesLoaded) return;
    final token = ++_groupsToken;
    setState(() {
      _dailyLoading = true;
      _dailyError = null;
    });
    try {
      final groups = await widget.sourceService.topListsByPlatform(platform);
      if (!mounted || token != _groupsToken || platform != _dailyPlatform) {
        return;
      }
      final boards = [for (final group in groups) ...group.items];
      if (boards.isEmpty) {
        setState(() {
          _dailyGroups = groups;
          _dailyBoard = null;
          _dailySongs = const [];
          _dailyError = '$platform 暂无可用榜单';
          _dailyLoading = false;
        });
        return;
      }
      final prefs = await SharedPreferences.getInstance();
      if (!mounted || token != _groupsToken || platform != _dailyPlatform) {
        return;
      }
      final pick = await _resolveDailyBoard(prefs, platform, boards);
      if (!mounted || token != _groupsToken || platform != _dailyPlatform) {
        return;
      }
      final previous = _dailyBoard;
      final changed =
          previous == null ||
          previous.id != pick.id ||
          previous.groupTitle != pick.groupTitle;
      setState(() {
        _dailyGroups = groups;
        _dailyBoard = pick;
      });
      if (changed) {
        await _loadDailyDetail();
      } else {
        setState(() => _dailyLoading = false);
      }
    } catch (error) {
      if (!mounted || token != _groupsToken || platform != _dailyPlatform) {
        return;
      }
      setState(() {
        _dailyGroups = const [];
        _dailyBoard = null;
        _dailySongs = const [];
        _dailyError = '榜单加载失败：${errorTextOf(error, '网络异常')}';
        _dailyLoading = false;
      });
    }
  }

  /// 拉取当日榜单详情；缺失封面的歌曲随后台搜索任务补齐
  Future<void> _loadDailyDetail() async {
    final platform = _dailyPlatform;
    final board = _dailyBoard;
    final token = ++_detailToken;
    if (platform == null || board == null) return;
    setState(() {
      _dailyLoading = true;
      _dailyError = null;
    });
    try {
      final page = await widget.sourceService.topListDetailByPlatform(
        platform,
        board,
      );
      if (!mounted || token != _detailToken || platform != _dailyPlatform) {
        return;
      }
      setState(() {
        _dailySongs = page.data;
        if (page.data.isEmpty) {
          _dailyError = '“${board.title}”暂无歌曲，可切换上方榜单重试';
        }
      });
      if (page.data.any(
        (song) => song.artwork == null || song.artwork!.isEmpty,
      )) {
        _startCoverFill(List.of(page.data), platform, token);
      }
    } catch (error) {
      if (!mounted || token != _detailToken || platform != _dailyPlatform) {
        return;
      }
      setState(() {
        _dailySongs = const [];
        _dailyError = '榜单加载失败：${errorTextOf(error, '网络异常')}';
      });
    } finally {
      if (mounted && token == _detailToken && platform == _dailyPlatform) {
        setState(() => _dailyLoading = false);
      }
    }
  }

  /// 补封面：按“歌名 + 歌手”搜索同曲并回填 artwork/qualities，
  /// 平台或榜单切换后任务立即失效（令牌校验）
  void _startCoverFill(
    List<MediaItem> snapshot,
    String platform,
    int detailToken,
  ) {
    final fillToken = ++_coverFillToken;
    unawaited(() async {
      for (final song in snapshot) {
        if (fillToken != _coverFillToken || detailToken != _detailToken) return;
        final artwork = song.artwork;
        if (artwork != null && artwork.isNotEmpty) continue;
        final query = '${song.title} ${song.artist}'.trim();
        if (query.isEmpty) continue;
        SearchPage<MediaItem>? page;
        try {
          page = await widget.sourceService.searchByPlatform(platform, query);
        } catch (_) {
          continue;
        }
        if (fillToken != _coverFillToken || detailToken != _detailToken) return;
        final candidates = page.data;
        MediaItem? hit;
        for (final candidate in candidates) {
          final art = candidate.artwork;
          if (candidate.id == song.id && art != null && art.isNotEmpty) {
            hit = candidate;
            break;
          }
        }
        final found = hit;
        if (found == null) continue;
        if (!mounted) return;
        if (fillToken != _coverFillToken || detailToken != _detailToken) return;
        setState(() {
          _dailySongs = [
            for (final current in _dailySongs)
              if (current.platform == song.platform &&
                  current.id == song.id &&
                  (current.artwork == null || current.artwork!.isEmpty))
                current.copyWith(
                  artwork: found.artwork,
                  qualities: found.qualities.isNotEmpty
                      ? found.qualities
                      : current.qualities,
                )
              else
                current,
          ];
        });
      }
    }());
  }

  void _selectPlatform(String name) {
    if (_dailyPlatform == name) return;
    setState(() {
      _dailyPlatform = name;
      _dailyGroups = const [];
      _dailyBoard = null;
      _dailySongs = const [];
      _dailyError = null;
    });
    _groupsToken++;
    _detailToken++;
    unawaited(_loadGroups());
  }

  void _selectDailyBoard(TopListItem board) {
    final platform = _dailyPlatform;
    if (platform != null) {
      unawaited(() async {
        try {
          final prefs = await SharedPreferences.getInstance();
          await _saveDailyBoard(prefs, platform, board);
        } catch (_) {}
      }());
    }
    setState(() => _dailyBoard = board);
    unawaited(_loadDailyDetail());
  }

  Future<void> _openDownloadQuality(MediaItem item) =>
      downloadMediaWithQualityDialog(context, widget.sourceService, item);

  Future<void> _openAddPlaylist(MediaItem item) =>
      addMediaToPlaylistWithDialog(context, widget.repository, item);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hasNoPlugin = _sourcesLoaded && _sources.isEmpty;
    return ListenableBuilder(
      listenable: widget.repository,
      builder: (context, _) {
        final favorites = widget.repository.favorites;
        return ListView(
          // 悬浮底座预留，避免末尾内容被遮挡
          padding: const EdgeInsets.only(bottom: 190),
          children: [
            Padding(
              padding: const EdgeInsets.only(left: 22, right: 22, top: 18),
              child: Text(
                _greeting,
                style: const TextStyle(
                  fontSize: 28,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 6),
              child: Text(
                '发现属于你的音乐',
                style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
              ),
            ),
            if (!hasNoPlugin)
              SizedBox(
                height: 40,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 18,
                    vertical: 4,
                  ),
                  itemCount: _sources.length,
                  separatorBuilder: (_, _) => const SizedBox(width: 8),
                  itemBuilder: (context, index) {
                    final source = _sources[index];
                    return FilterChip(
                      selected: source.name == _dailyPlatform,
                      onSelected: (_) => _selectPlatform(source.name),
                      showCheckmark: false,
                      label: Text(
                        source.name,
                        style: const TextStyle(fontSize: 12),
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(24),
                      ),
                      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    );
                  },
                ),
              ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 8),
              child: Row(
                children: [
                  const Expanded(
                    child: Text(
                      '每日推荐',
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  if (!hasNoPlugin)
                    _DailyBoardDropdown(
                      boards: [
                        for (final group in _dailyGroups) ...group.items,
                      ],
                      selected: _dailyBoard,
                      enabled: !_dailyLoading,
                      onSelect: _selectDailyBoard,
                    ),
                ],
              ),
            ),
            if (!hasNoPlugin && _dailyError != null)
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 22,
                  vertical: 8,
                ),
                child: Text(
                  _dailyError!,
                  style: TextStyle(color: theme.colorScheme.error),
                ),
              ),
            if (hasNoPlugin)
              NoPluginPrompt(onInstallClick: widget.onInstallPlugin)
            else if (_dailyLoading)
              for (var i = 0; i < 8; i++) const SongRowSkeleton()
            else
              for (final item in _dailySongs)
                PluginSongRow(
                  item: item,
                  favorite: favorites.contains(item.key),
                  onPlay: () => widget.onPlayMedia(item, _dailySongs),
                  onToggleFavorite: () =>
                      unawaited(widget.repository.toggleFavorite(item)),
                  onDownload: () => _openDownloadQuality(item),
                  onAddPlaylist: () => _openAddPlaylist(item),
                ),
          ],
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// 音乐库：我喜欢的音乐 / 导入歌单 / 新建歌单 + 我的歌单列表
// ---------------------------------------------------------------------------

class LibraryScreen extends StatefulWidget {
  const LibraryScreen({
    super.key,
    required this.repository,
    required this.onOpenPlaylist,
    required this.onImportPlaylist,
  });

  final AppRepository repository;

  /// 打开歌单详情（含“我喜欢的音乐”）
  final ValueChanged<String> onOpenPlaylist;

  /// 导入歌单入口，由上层弹出输入框
  final VoidCallback onImportPlaylist;

  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen> {
  final TextEditingController _createNameController = TextEditingController();

  @override
  void dispose() {
    _createNameController.dispose();
    super.dispose();
  }

  /// 新建歌单对话框：名称非空才可创建
  Future<void> _openCreatePlaylist() async {
    _createNameController.clear();
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('新建歌单'),
        content: TextField(
          controller: _createNameController,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: '歌单名称',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('取消'),
          ),
          ValueListenableBuilder<TextEditingValue>(
            valueListenable: _createNameController,
            builder: (context, value, _) => TextButton(
              onPressed: value.text.trim().isNotEmpty
                  ? () {
                      Navigator.pop(dialogContext);
                      unawaited(widget.repository.createPlaylist(value.text));
                    }
                  : null,
              child: const Text('创建'),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListenableBuilder(
      listenable: widget.repository,
      builder: (context, _) {
        final names = widget.repository.userPlaylistNames;
        return ListView(
          // 悬浮底座预留，避免末尾内容被遮挡
          padding: const EdgeInsets.only(bottom: 190),
          children: [
            const Padding(
              padding: EdgeInsets.only(left: 22, right: 22, top: 18),
              child: Text(
                '音乐库',
                style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 6),
              child: Text(
                '收藏与自建歌单都在这里',
                style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(18),
              child: Row(
                children: [
                  Expanded(
                    child: _HomeTile(
                      title: '我喜欢的音乐',
                      icon: Icons.favorite,
                      color: const Color(0xffffd9e2),
                      onTap: () =>
                          widget.onOpenPlaylist(AppRepository.favoriteSheet),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _HomeTile(
                      title: '导入歌单',
                      icon: Icons.add,
                      color: const Color(0xffd8f0e3),
                      onTap: widget.onImportPlaylist,
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 4),
              child: Row(
                children: [
                  const Expanded(
                    child: Text(
                      '我的歌单',
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  Text(
                    '共 ${names.length} 个',
                    style: TextStyle(
                      fontSize: 12,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14),
              child: Column(
                children: [
                  _LibraryPlaylistRow(
                    title: '新建歌单',
                    subtitle: '创建属于你的歌单',
                    icon: Icons.add,
                    iconBg: const Color(0xffd8f0e3),
                    onTap: _openCreatePlaylist,
                  ),
                  for (final name in names) ...[
                    const SizedBox(height: 10),
                    _UserPlaylistRow(
                      repository: widget.repository,
                      name: name,
                      onTap: () => widget.onOpenPlaylist(name),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 8),
          ],
        );
      },
    );
  }
}

/// 功能磁贴：彩色卡片 + 图标 + 标题
class _HomeTile extends StatelessWidget {
  const _HomeTile({
    required this.title,
    required this.icon,
    required this.color,
    required this.onTap,
  });

  final String title;
  final IconData icon;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 84,
      child: Card(
        margin: EdgeInsets.zero,
        elevation: 0,
        color: color,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Icon(icon, size: 26, color: const Color(0xff314568)),
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    color: Color(0xff25334c),
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

/// 歌单行：封面（或占位图标）+ 标题/副标题 + 右箭头
class _LibraryPlaylistRow extends StatelessWidget {
  const _LibraryPlaylistRow({
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.iconBg,
    required this.onTap,
    this.artwork,
  });

  final String title;
  final String subtitle;
  final IconData icon;
  final Color iconBg;
  final VoidCallback onTap;
  final String? artwork;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final art = artwork;
    final placeholder = ColoredBox(
      color: iconBg,
      child: Center(
        child: Icon(icon, size: 26, color: const Color(0xff314568)),
      ),
    );
    return Card(
      margin: EdgeInsets.zero,
      elevation: 0,
      color: theme.colorScheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(14),
                child: SizedBox(
                  width: 48,
                  height: 48,
                  child: art == null || art.isEmpty
                      ? placeholder
                      : CachedNetworkImage(
                          imageUrl: art,
                          httpHeaders: kArtworkHeaders,
                          fit: BoxFit.cover,
                          errorWidget: (_, _, _) => placeholder,
                        ),
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                    Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(
                Icons.chevron_right,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 自建歌单行：封面取歌单首曲封面，为空时保持默认图标
class _UserPlaylistRow extends StatelessWidget {
  const _UserPlaylistRow({
    required this.repository,
    required this.name,
    required this.onTap,
  });

  final AppRepository repository;
  final String name;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final songs = repository.playlistSongs(name);
    return _LibraryPlaylistRow(
      title: name,
      subtitle: songs.isEmpty ? '空歌单' : '共 ${songs.length} 首',
      icon: Icons.library_music,
      iconBg: const Color(0xffe7dcff),
      artwork: songs.isNotEmpty ? songs.first.artwork : null,
      onTap: onTap,
    );
  }
}

// ---------------------------------------------------------------------------
// 共享小组件（Home / Library / Search 三页复用）
// ---------------------------------------------------------------------------

/// 插件歌曲行：标题/信息 + 收藏/下载/加歌单操作
class PluginSongRow extends StatelessWidget {
  const PluginSongRow({
    super.key,
    required this.item,
    required this.favorite,
    required this.onPlay,
    required this.onToggleFavorite,
    required this.onDownload,
    required this.onAddPlaylist,
  });

  final MediaItem item;
  final bool favorite;
  final VoidCallback onPlay;
  final VoidCallback onToggleFavorite;
  final VoidCallback onDownload;
  final VoidCallback onAddPlaylist;

  @override
  Widget build(BuildContext context) {
    final quality = _bestQualityKey(item);
    final size = quality == null ? null : item.qualities[quality]?.size;
    final art = item.artwork;
    final subtitle =
        '${item.artist} · ${formatDuration(item.durationMs)} · ${quality ?? '未知音质'}'
        '${size != null ? ' · ${formatSize(size)}' : ''} · ${item.platform}';
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: ListTile(
        onTap: onPlay,
        leading: ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: SizedBox(
            width: 48,
            height: 48,
            child: ColoredBox(
              color: const Color(0xffdbe1ff),
              child: art == null || art.isEmpty
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
          item.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        subtitle: Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          spacing: 4,
          children: [
            _rowAction(
              favorite ? Icons.favorite : Icons.favorite_border,
              '收藏',
              onToggleFavorite,
            ),
            _rowAction(Icons.download, '下载', onDownload),
            _rowAction(Icons.playlist_add, '添加歌单', onAddPlaylist),
          ],
        ),
      ),
    );
  }

  Widget _rowAction(IconData icon, String tooltip, VoidCallback onPressed) =>
      IconButton(
        onPressed: onPressed,
        tooltip: tooltip,
        icon: Icon(icon),
        constraints: const BoxConstraints.tightFor(width: 40, height: 40),
        padding: EdgeInsets.zero,
      );
}

/// 可用音质中最高档；无音质信息返回 null
String? _bestQualityKey(MediaItem item) {
  if (item.qualities.isEmpty) return null;
  var best = item.qualities.keys.first;
  for (final key in item.qualities.keys) {
    if (qualityRankOf(key) > qualityRankOf(best)) best = key;
  }
  return best;
}

/// 歌曲行骨架屏：呼吸闪烁占位
class SongRowSkeleton extends StatefulWidget {
  const SongRowSkeleton({super.key});

  @override
  State<SongRowSkeleton> createState() => _SongRowSkeletonState();
}

class _SongRowSkeletonState extends State<SongRowSkeleton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final base = Theme.of(context).colorScheme.surfaceContainerHighest;
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        final placeholder = base.withValues(
          alpha: 0.35 + 0.65 * _controller.value,
        );
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 72),
            child: Row(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(14),
                  child: SizedBox(
                    width: 56,
                    height: 56,
                    child: ColoredBox(color: placeholder),
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _bar(placeholder, height: 16, widthFactor: 0.55),
                      const SizedBox(height: 8),
                      _bar(placeholder, height: 12, widthFactor: 0.85),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _bar(
    Color color, {
    required double height,
    required double widthFactor,
  }) => FractionallySizedBox(
    alignment: Alignment.centerLeft,
    widthFactor: widthFactor,
    child: Container(
      height: height,
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(4),
      ),
    ),
  );
}

/// 无插件引导：安装音源插件
class NoPluginPrompt extends StatelessWidget {
  const NoPluginPrompt({super.key, required this.onInstallClick});

  final VoidCallback onInstallClick;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 32),
      child: Column(
        children: [
          Container(
            width: 88,
            height: 88,
            decoration: BoxDecoration(
              color: scheme.primaryContainer,
              borderRadius: BorderRadius.circular(28),
            ),
            child: Icon(
              Icons.extension,
              size: 44,
              color: scheme.onPrimaryContainer,
            ),
          ),
          const SizedBox(height: 16),
          const Text(
            '音乐世界，从这里开始',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          Text(
            '安装音源插件，获取音乐信息',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 14, color: scheme.onSurfaceVariant),
          ),
          const SizedBox(height: 20),
          FilledButton(onPressed: onInstallClick, child: const Text('安装音源插件')),
        ],
      ),
    );
  }
}

/// 选择下载音质：返回选中的音质键，取消返回 null
Future<String?> showDownloadQualityDialog(
  BuildContext context,
  MediaItem item,
) {
  final keys = item.qualities.keys.toList()
    ..sort((a, b) => qualityRankOf(b).compareTo(qualityRankOf(a)));
  if (keys.isEmpty) keys.add('320k');
  return showDialog<String>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('选择下载音质'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final quality in keys)
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, quality),
                child: Text(_qualityLabel(item, quality)),
              ),
          ],
        ),
      ),
    ),
  );
}

String _qualityLabel(MediaItem item, String quality) {
  final size = item.qualities[quality]?.size;
  return size == null ? quality : '$quality · ${formatSize(size)}';
}

/// 添加到我的歌单：返回选中的歌单名，取消返回 null
Future<String?> showAddPlaylistDialog(
  BuildContext context,
  List<String> playlistNames,
) {
  final options = playlistNames.isEmpty
      ? const [AppRepository.defaultSheet]
      : playlistNames;
  return showDialog<String>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('添加到我的歌单'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final playlist in options)
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, playlist),
                child: Text(
                  playlist,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
          ],
        ),
      ),
    ),
  );
}

/// 下载流程：选择音质 → 提示目标目录 → 解析地址 → 入队下载；
/// 失败时提示歌曲名，后续真实下载失败由原生事件补充提示
Future<void> downloadMediaWithQualityDialog(
  BuildContext context,
  MusicSourceService sourceService,
  MediaItem item,
) async {
  final quality = await showDownloadQualityDialog(context, item);
  if (quality == null || !context.mounted) return;
  await showDownloadStartedToast(context);
  if (!context.mounted) return;
  try {
    final resolved = await sourceService.resolveForDownload(item, quality);
    if (resolved == null) throw StateError('下载失败');
    await DownloadHelper.enqueueByKey(resolved.$1, resolved.$2);
  } catch (_) {
    if (context.mounted) showDownloadFailureToast(context, item.title);
  }
}

/// 加歌单流程：选择歌单 → 写入本地
Future<void> addMediaToPlaylistWithDialog(
  BuildContext context,
  AppRepository repository,
  MediaItem item,
) async {
  final playlist = await showAddPlaylistDialog(
    context,
    repository.userPlaylistNames,
  );
  if (playlist == null) return;
  await repository.addToPlaylist(playlist, item);
}

/// 榜单下拉选择：宽 220 / 高 300，重名榜单带分组前缀
class _DailyBoardDropdown extends StatelessWidget {
  const _DailyBoardDropdown({
    required this.boards,
    required this.selected,
    required this.enabled,
    required this.onSelect,
  });

  final List<TopListItem> boards;
  final TopListItem? selected;
  final bool enabled;
  final ValueChanged<TopListItem> onSelect;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final titleCounts = <String, int>{};
    for (final board in boards) {
      titleCounts[board.title] = (titleCounts[board.title] ?? 0) + 1;
    }
    String labelOf(TopListItem board) {
      if ((titleCounts[board.title] ?? 0) > 1 && board.groupTitle.isNotEmpty) {
        return '${board.groupTitle} · ${board.title}';
      }
      return board.title.isEmpty ? '未知榜单' : board.title;
    }

    final current = selected;
    final usable = enabled && boards.isNotEmpty;
    final triggerColor = usable
        ? theme.colorScheme.primary
        : theme.colorScheme.onSurface.withValues(alpha: 0.38);
    return Padding(
      padding: const EdgeInsets.only(left: 8),
      child: PopupMenuButton<TopListItem>(
        enabled: usable,
        tooltip: '',
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints(
          minWidth: 220,
          maxWidth: 220,
          maxHeight: 300,
        ),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        onSelected: (board) {
          final isSelected =
              current != null &&
              board.id == current.id &&
              board.groupTitle == current.groupTitle;
          if (!isSelected) onSelect(board);
        },
        itemBuilder: (context) => [
          for (final board in boards)
            PopupMenuItem<TopListItem>(
              value: board,
              height: 48,
              padding: const EdgeInsets.only(left: 20, right: 12),
              child: _menuItem(theme, board, labelOf, current),
            ),
        ],
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(
                child: Text(
                  current == null ? '选择榜单' : labelOf(current),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 14, color: triggerColor),
                ),
              ),
              Icon(Icons.arrow_drop_down, color: triggerColor),
            ],
          ),
        ),
      ),
    );
  }

  Widget _menuItem(
    ThemeData theme,
    TopListItem board,
    String Function(TopListItem) labelOf,
    TopListItem? current,
  ) {
    final isSelected =
        current != null &&
        board.id == current.id &&
        board.groupTitle == current.groupTitle;
    return Row(
      children: [
        Expanded(
          child: Text(
            labelOf(board),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: isSelected
                  ? theme.colorScheme.primary
                  : theme.colorScheme.onSurface,
              fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
            ),
          ),
        ),
        if (isSelected)
          Icon(Icons.check, size: 20, color: theme.colorScheme.primary),
      ],
    );
  }
}
