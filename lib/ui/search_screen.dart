// ---------------------------------------------------------------------------
// 搜索页
// 悬浮搜索栏 + 搜索历史 + 音源切换 + 结果分页加载
// ---------------------------------------------------------------------------

import 'dart:async';

import 'package:flutter/material.dart';

import '../data/app_repository.dart';
import '../models/media_models.dart';
import '../plugin/plugin_manager.dart';
import '../service/music_source_service.dart';
import 'home_screen.dart';

class SearchScreen extends StatefulWidget {
  const SearchScreen({
    super.key,
    required this.sourceService,
    required this.repository,
    required this.onPlayMedia,
    required this.onInstallPlugin,
    required this.onShowDock,
  });

  final MusicSourceService sourceService;
  final AppRepository repository;

  /// 播放整组搜索结果
  final void Function(MediaItem item, List<MediaItem> queue) onPlayMedia;

  /// 无插件时跳转内嵌设置页安装
  final VoidCallback onInstallPlugin;

  /// 新搜索/清空后确保底座可见
  final VoidCallback onShowDock;

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  final TextEditingController _queryController = TextEditingController();
  final ScrollController _scrollController = ScrollController();

  List<InstalledPlugin> _sources = const [];
  bool _sourcesLoaded = false;
  String? _selectedSourcePlatform;
  String _submittedQuery = '';
  List<MediaItem> _pluginSongs = const [];
  String? _searchError;
  bool _searching = false;
  int _searchPage = 1;
  bool _searchIsEnd = true;
  bool _loadingMore = false;
  String? _loadMoreError;

  /// 搜索任务令牌：过期异步结果直接丢弃
  int _searchToken = 0;

  @override
  void initState() {
    super.initState();
    // 注册表代际驱动：内嵌设置页改插件后靠此刷新
    widget.sourceService.generation.addListener(_onRegistryChanged);
    _scrollController.addListener(_onScroll);
    unawaited(_reloadSources());
    // 初始为历史视图：确保底座可见
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _submittedQuery.isEmpty) widget.onShowDock();
    });
  }

  @override
  void dispose() {
    widget.sourceService.generation.removeListener(_onRegistryChanged);
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    _queryController.dispose();
    _searchToken++;
    super.dispose();
  }

  void _onRegistryChanged() {
    if (!mounted) return;
    unawaited(_reloadThenSearch());
  }

  Future<void> _reloadThenSearch() async {
    await _reloadSources();
    if (!mounted) return;
    if (_submittedQuery.isNotEmpty) await _runSearch();
  }

  /// 重新读取音源列表；当前源失效时回退首个插件
  Future<void> _reloadSources() async {
    try {
      await widget.sourceService.refresh();
    } catch (_) {}
    var listed = _sources;
    try {
      listed = widget.sourceService.installedPlugins();
    } catch (_) {}
    if (!mounted) return;
    final selected = _selectedSourcePlatform;
    final selectedValid =
        selected != null && listed.any((p) => p.name == selected);
    setState(() {
      _sources = listed;
      _sourcesLoaded = true;
      _selectedSourcePlatform = selectedValid
          ? selected
          : (listed.isNotEmpty ? listed.first.name : selected);
    });
  }

  bool get _atEnd {
    if (!_scrollController.hasClients) return false;
    return _scrollController.position.extentAfter <= 0;
  }

  void _onScroll() {
    if (_atEnd) _loadMore();
  }

  /// 列表内容变化后补查一次是否已触底（内容不足一屏时链式续载）
  void _scheduleMaybeLoadMore() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_atEnd) _loadMore();
    });
  }

  void _submitSearch(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return;
    if (_queryController.text != trimmed) _queryController.text = trimmed;
    setState(() => _submittedQuery = trimmed);
    widget.onShowDock();
    FocusManager.instance.primaryFocus?.unfocus();
    // 新搜索从顶部看，避免残留滚动位置导致跳动
    if (_scrollController.hasClients) _scrollController.jumpTo(0);
    unawaited(widget.repository.addSearch(trimmed));
    unawaited(_runSearch());
  }

  void _clearQuery() {
    _queryController.clear();
    setState(() {
      _submittedQuery = '';
      _pluginSongs = const [];
      _searchError = null;
      _loadMoreError = null;
      _searchPage = 1;
      _searchIsEnd = true;
    });
    // 搜索清空后内容可能不足一屏：直接显示底座，避免隐藏态下无处可滑
    widget.onShowDock();
  }

  void _selectSource(String name) {
    if (_selectedSourcePlatform == name) return;
    setState(() => _selectedSourcePlatform = name);
    if (_submittedQuery.isNotEmpty) unawaited(_runSearch());
  }

  /// 发起搜索：从第一页开始，结果替换列表
  Future<void> _runSearch() async {
    final token = ++_searchToken;
    final submitted = _submittedQuery;
    if (submitted.isEmpty) {
      setState(() {
        _pluginSongs = const [];
        _searchError = null;
        _loadMoreError = null;
        _searchPage = 1;
        _searchIsEnd = true;
      });
      return;
    }
    if (!_sourcesLoaded) return;
    if (_sources.isEmpty) {
      await _reloadSources();
      if (!mounted || token != _searchToken) return;
    }
    setState(() {
      _searchPage = 1;
      _searchIsEnd = true;
      _loadMoreError = null;
      _searchError = null;
      _searching = true;
    });
    final targetPlatform =
        _selectedSourcePlatform ??
        (_sources.isNotEmpty ? _sources.first.name : null);
    if (_sources.isEmpty || targetPlatform == null) {
      setState(() {
        _searching = false;
        _pluginSongs = const [];
        _searchError = null;
      });
      return;
    }
    try {
      final page = await widget.sourceService.searchByPlatform(
        targetPlatform,
        submitted,
      );
      if (!mounted || token != _searchToken) return;
      setState(() {
        _pluginSongs = page.data;
        _searchPage = 1;
        _searchIsEnd = page.isEnd || page.data.isEmpty;
        _searchError = page.data.isEmpty
            ? '在 $targetPlatform 没有找到“$submitted”，可切换上方音源重试'
            : null;
      });
    } catch (error) {
      if (!mounted || token != _searchToken) return;
      setState(() {
        _pluginSongs = const [];
        _searchError = isNoPluginError(error)
            ? (_sources.isEmpty ? null : '音源插件加载中，请稍后重试')
            : errorTextOf(error, '音源搜索失败');
        _searchIsEnd = true;
      });
    } finally {
      if (mounted && token == _searchToken) {
        setState(() => _searching = false);
        _scheduleMaybeLoadMore();
      }
    }
  }

  /// 加载下一页：按 key 去重合并，最多 50 页
  void _loadMore() {
    final hasNoPlugin = _sourcesLoaded && _sources.isEmpty;
    if (_loadingMore ||
        _searching ||
        _searchIsEnd ||
        _submittedQuery.isEmpty ||
        !_sourcesLoaded ||
        hasNoPlugin) {
      return;
    }
    if (_sources.isEmpty) return;
    if (_searchPage >= 50) {
      setState(() => _searchIsEnd = true);
      return;
    }
    final target =
        _selectedSourcePlatform ??
        (_sources.isNotEmpty ? _sources.first.name : null);
    if (target == null || !_sources.any((p) => p.name == target)) return;
    final query = _submittedQuery;
    final platform = _selectedSourcePlatform;
    final next = _searchPage + 1;
    setState(() {
      _loadingMore = true;
      _loadMoreError = null;
    });
    unawaited(() async {
      try {
        final page = await widget.sourceService.searchByPlatform(
          target,
          query,
          next,
        );
        if (!mounted ||
            query != _submittedQuery ||
            platform != _selectedSourcePlatform) {
          return;
        }
        setState(() {
          final known = {for (final song in _pluginSongs) song.key};
          _pluginSongs = [
            ..._pluginSongs,
            for (final song in page.data)
              if (!known.contains(song.key)) song,
          ];
          _searchPage = next;
          _searchIsEnd = page.isEnd || page.data.isEmpty;
        });
      } catch (error) {
        if (!mounted ||
            query != _submittedQuery ||
            platform != _selectedSourcePlatform) {
          return;
        }
        if (_sources.isEmpty || isNoPluginError(error)) {
          setState(() {
            _searchIsEnd = true;
            _loadMoreError = null;
          });
        } else {
          setState(() => _loadMoreError = '请检查网络或切换音源后重试');
        }
      } finally {
        if (mounted) {
          setState(() => _loadingMore = false);
          _scheduleMaybeLoadMore();
        }
      }
    }());
  }

  Future<void> _confirmClearHistory() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('清空搜索历史'),
        content: const Text('确定清空全部搜索历史吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(
              '清空',
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await widget.repository.clearSearchHistory();
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hasNoPlugin = _sourcesLoaded && _sources.isEmpty;
    return ListenableBuilder(
      listenable: widget.repository,
      builder: (context, _) {
        final history = widget.repository.searchHistory;
        final favorites = widget.repository.favorites;
        return Stack(
          children: [
            ListView(
              controller: _scrollController,
              // 顶部为悬浮搜索栏预留，底部为悬浮底座预留
              padding: const EdgeInsets.only(top: 96, bottom: 190),
              children: _submittedQuery.isEmpty
                  ? _historyChildren(theme, history, hasNoPlugin)
                  : _resultChildren(theme, favorites, hasNoPlugin),
            ),
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: Padding(
                padding: const EdgeInsets.only(left: 18, right: 18, top: 18),
                child: Card(
                  elevation: 0,
                  margin: EdgeInsets.zero,
                  color: theme.colorScheme.surfaceContainerLow,
                  clipBehavior: Clip.antiAlias,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(30),
                  ),
                  child: SizedBox(
                    height: 56,
                    child: TextField(
                      controller: _queryController,
                      onChanged: (_) => setState(() {}),
                      textInputAction: TextInputAction.search,
                      onSubmitted: _submitSearch,
                      textAlignVertical: TextAlignVertical.center,
                      decoration: InputDecoration(
                        hintText: '搜索歌曲',
                        prefixIcon: const Icon(Icons.search),
                        suffixIcon: _queryController.text.isEmpty
                            ? null
                            : IconButton(
                                onPressed: _clearQuery,
                                tooltip: '清除',
                                icon: const Icon(Icons.clear),
                              ),
                        border: InputBorder.none,
                        contentPadding: EdgeInsets.zero,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  /// 历史视图：搜索历史 + 清空入口 + 无插件引导
  List<Widget> _historyChildren(
    ThemeData theme,
    List<String> history,
    bool hasNoPlugin,
  ) {
    return [
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 6),
        child: Row(
          children: [
            const Expanded(
              child: Text(
                '搜索历史',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              ),
            ),
            if (history.isNotEmpty)
              TextButton(
                onPressed: _confirmClearHistory,
                child: const Text('清空'),
              ),
          ],
        ),
      ),
      if (history.isEmpty)
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 4),
          child: Text(
            '暂无搜索历史，输入关键词开始探索音乐',
            style: TextStyle(
              fontSize: 13,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        )
      else ...[
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 18),
          child: Wrap(
            spacing: 8,
            runSpacing: 6,
            children: [
              for (final entry in history)
                InputChip(
                  label: Text(
                    entry,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 12),
                  ),
                  onPressed: () => _submitSearch(entry),
                  onDeleted: () =>
                      unawaited(widget.repository.removeSearch(entry)),
                  deleteIcon: const Icon(Icons.close, size: 16),
                  deleteButtonTooltipMessage: '删除该条历史',
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(24),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 8),
      ],
      if (hasNoPlugin) NoPluginPrompt(onInstallClick: widget.onInstallPlugin),
    ];
  }

  /// 结果视图：音源筛选 + 结果列表 + 分页加载
  List<Widget> _resultChildren(
    ThemeData theme,
    Set<String> favorites,
    bool hasNoPlugin,
  ) {
    return [
      if (!hasNoPlugin)
        SizedBox(
          height: 40,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 4),
            itemCount: _sources.length,
            separatorBuilder: (_, _) => const SizedBox(width: 8),
            itemBuilder: (context, index) {
              final source = _sources[index];
              return FilterChip(
                selected: source.name == _selectedSourcePlatform,
                onSelected: (_) => _selectSource(source.name),
                showCheckmark: false,
                label: Text(source.name, style: const TextStyle(fontSize: 12)),
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
                '搜索结果',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
              ),
            ),
            if (_submittedQuery.isNotEmpty)
              TextButton(onPressed: _clearQuery, child: const Text('清除搜索')),
          ],
        ),
      ),
      if (!hasNoPlugin && _searchError != null)
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 8),
          child: Text(
            _searchError!,
            style: TextStyle(color: theme.colorScheme.error),
          ),
        ),
      if (hasNoPlugin)
        NoPluginPrompt(onInstallClick: widget.onInstallPlugin)
      else if (_searching)
        for (var i = 0; i < 8; i++) const SongRowSkeleton()
      else
        for (final item in _pluginSongs)
          PluginSongRow(
            item: item,
            favorite: favorites.contains(item.key),
            onPlay: () => widget.onPlayMedia(item, _pluginSongs),
            onToggleFavorite: () =>
                unawaited(widget.repository.toggleFavorite(item)),
            onDownload: () => downloadMediaWithQualityDialog(
              context,
              widget.sourceService,
              item,
            ),
            onAddPlaylist: () =>
                addMediaToPlaylistWithDialog(context, widget.repository, item),
          ),
      if (!hasNoPlugin &&
          _submittedQuery.isNotEmpty &&
          _pluginSongs.isNotEmpty &&
          (!_searchIsEnd || _loadMoreError != null))
        Padding(
          padding: const EdgeInsets.all(12),
          child: Center(
            child: _loadingMore
                ? Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        '正在加载下一页',
                        style: TextStyle(
                          fontSize: 12,
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  )
                : _loadMoreError != null
                ? Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        '下一页加载失败，$_loadMoreError',
                        style: TextStyle(
                          fontSize: 12,
                          color: theme.colorScheme.error,
                        ),
                      ),
                      TextButton(onPressed: _loadMore, child: const Text('重试')),
                    ],
                  )
                : Text(
                    '上滑加载更多',
                    style: TextStyle(
                      fontSize: 12,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
          ),
        ),
    ];
  }
}
