// ---------------------------------------------------------------------------
// 设置页
// 播放/下载音质、插件管理（原生插件 + 订阅源 + LX 取流脚本）
// ---------------------------------------------------------------------------

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import '../data/app_repository.dart';
import '../data/lx_models.dart';
import '../models/media_models.dart';
import '../plugin/plugin_manager.dart';
import '../service/music_source_service.dart';
import '../util/download_helper.dart';

String _errorText(Object error, String fallback) {
  if (error is StateError) {
    return error.message.isEmpty ? fallback : error.message;
  }
  final text = '$error';
  return text.isEmpty ? fallback : text;
}

/// 宿主文件选择通道
const MethodChannel _pickerChannel = MethodChannel('baka_music/file_picker');

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({
    super.key,
    required this.sourceService,
    required this.repository,
    this.scrollTrigger = 0,
  });

  final MusicSourceService sourceService;
  final AppRepository repository;

  /// 主页"安装音源插件"入口递增该值以定位插件管理
  final int scrollTrigger;

  @override
  State<SettingsScreen> createState() => SettingsScreenState();
}

class SettingsScreenState extends State<SettingsScreen> {
  PluginManager? _manager;
  List<InstalledPlugin> _plugins = const [];
  List<PluginSubscription> _subscriptions = const [];
  List<LxPluginDescriptor> _lxList = const [];
  bool _loading = false;
  bool _inPluginPage = false;
  bool _installedExpanded = false;
  DownloadDirectoryInfo _downloadDirectory = DownloadDirectoryInfo.fallback;

  /// 返回键优先退出插件配置页（app.dart 返回逻辑检测该状态）
  bool get inPluginPage => _inPluginPage;

  void exitPluginPage() {
    if (_inPluginPage) setState(() => _inPluginPage = false);
  }

  @override
  void initState() {
    super.initState();
    if (widget.scrollTrigger > 0) _inPluginPage = true;
    unawaited(_init());
    unawaited(_loadDownloadDirectory());
  }

  @override
  void didUpdateWidget(SettingsScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.scrollTrigger != oldWidget.scrollTrigger &&
        widget.scrollTrigger > 0) {
      setState(() => _inPluginPage = true);
    }
  }

  Future<void> _init() async {
    try {
      final manager = await PluginManager.create();
      if (!mounted) return;
      setState(() {
        _manager = manager;
        _plugins = manager.allPlugins();
        _subscriptions = manager.subscriptions();
      });
    } catch (_) {}
    await _loadLx();
  }

  Future<void> _loadLx() async {
    try {
      await widget.sourceService.ensureLxLoaded();
    } catch (_) {}
    try {
      final list = widget.sourceService.installedLx();
      if (!mounted) return;
      setState(() => _lxList = list);
    } catch (_) {}
  }

  void _refresh() {
    final manager = _manager;
    if (manager == null) return;
    setState(() {
      _plugins = manager.allPlugins();
      _subscriptions = manager.subscriptions();
    });
  }

  void _lxRefresh() {
    try {
      final list = widget.sourceService.installedLx();
      if (mounted) setState(() => _lxList = list);
    } catch (_) {}
  }

  void _notify(String message, {String title = '插件管理'}) {
    if (!mounted) return;
    unawaited(
      showDialog<void>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: Text(title),
          content: Text(message),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('确定'),
            ),
          ],
        ),
      ),
    );
  }

  /// 确认弹窗
  Future<bool> _confirm(
    String title,
    String message,
    String confirmLabel,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(
              confirmLabel,
              style: TextStyle(
                color: Theme.of(dialogContext).colorScheme.error,
              ),
            ),
          ),
        ],
      ),
    );
    return confirmed == true;
  }

  /// 音质单选弹窗：降序展示，当前项高亮
  Future<String?> _showQualityDialog(String title, String current) {
    final scheme = Theme.of(context).colorScheme;
    return showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(title),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final key in qualityKeysOrdered.reversed)
                TextButton(
                  onPressed: () => Navigator.pop(dialogContext, key),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          MusicQuality.labelOf(key),
                          style: TextStyle(
                            color: key == current
                                ? scheme.primary
                                : scheme.onSurface,
                            fontWeight: key == current
                                ? FontWeight.bold
                                : FontWeight.normal,
                          ),
                        ),
                      ),
                      if (key == current)
                        Icon(Icons.check, color: scheme.primary),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Future<String?> _showTextInputDialog({
    required String title,
    required String label,
    required String confirmLabel,
  }) {
    return showDialog<String>(
      context: context,
      builder: (_) => _TextInputDialog(
        title: title,
        label: label,
        confirmLabel: confirmLabel,
      ),
    );
  }

  Future<void> _pickPlayQuality() async {
    final key = await _showQualityDialog(
      '默认播放音质',
      widget.repository.playQuality,
    );
    if (key == null || !mounted) return;
    await widget.repository.setPlayQuality(key);
    if (mounted) setState(() {});
  }

  Future<void> _pickDownloadQuality() async {
    final key = await _showQualityDialog(
      '默认下载音质',
      widget.repository.downloadQuality,
    );
    if (key == null || !mounted) return;
    await widget.repository.setDownloadQuality(key);
    if (mounted) setState(() {});
  }

  Future<void> _loadDownloadDirectory() async {
    try {
      final info = await DownloadHelper.directory();
      if (mounted) setState(() => _downloadDirectory = info);
    } catch (_) {}
  }

  /// 下载目录：自定义 SAF 目录或恢复默认公共 Music/BakaMusic
  Future<void> _openDownloadDirectory() async {
    final current = _downloadDirectory;
    final action = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('下载目录'),
        content: Text(
          current.custom
              ? '当前自定义目录：${current.label}\n下载完成后文件直接保存在该目录。'
              : '当前目录：${current.label}\n文件保存到系统音乐目录，其他应用也可访问。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, 'pick'),
            child: const Text('更改目录'),
          ),
          if (current.custom)
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, 'reset'),
              child: Text(
                '恢复默认',
                style: TextStyle(
                  color: Theme.of(dialogContext).colorScheme.error,
                ),
              ),
            ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('取消'),
          ),
        ],
      ),
    );
    if (!mounted || action == null) return;
    if (action == 'pick') {
      try {
        final picked = await DownloadHelper.pickDirectory();
        if (!mounted || picked == null) return;
        setState(() => _downloadDirectory = picked);
        _notify('已切换下载目录：${picked.label}', title: '下载设置');
      } catch (error) {
        _notify('选择目录失败：${_errorText(error, '未知错误')}', title: '下载设置');
      }
      return;
    }
    if (action == 'reset') {
      try {
        final info = await DownloadHelper.resetDirectory();
        if (!mounted) return;
        setState(() => _downloadDirectory = info);
        _notify('已恢复默认目录：${info.label}', title: '下载设置');
      } catch (error) {
        _notify('恢复默认目录失败：${_errorText(error, '未知错误')}', title: '下载设置');
      }
    }
  }

  /// 打开系统文件选择器，取消返回 null
  Future<({String name, Uint8List bytes})?> _pickFile() async {
    final result = await _pickerChannel.invokeMapMethod<String, Object?>(
      'pickFile',
    );
    if (result == null) return null;
    final bytes = result['bytes'];
    if (bytes is! Uint8List) throw StateError('无法读取文件内容');
    return (name: '${result['name'] ?? ''}', bytes: bytes);
  }

  Future<void> _installLocalPlugin() async {
    final manager = _manager;
    if (manager == null) return;
    ({String name, Uint8List bytes})? picked;
    try {
      picked = await _pickFile();
    } catch (error) {
      _notify('安装失败：${_errorText(error, '未知错误')}');
      return;
    }
    if (picked == null) return;
    try {
      var name = picked.name.trim();
      if (name.isEmpty) name = 'plugin.js';
      final lower = name.toLowerCase();
      if (!lower.endsWith('.js') && !lower.endsWith('.json')) {
        name = '$name.js';
      }
      name = _fileNameOf(name);
      if (name.isEmpty) name = 'plugin.js';
      final target = await _writeTempFile(name, picked.bytes);
      try {
        final plugin = await manager.installLocal(target);
        unawaited(MusicSourceService.refreshAll());
        _notify('已安装插件：${plugin.name} ${plugin.version}');
      } finally {
        _deleteQuietly(target);
      }
    } catch (error) {
      _notify('安装失败：${_errorText(error, '未知错误')}');
    }
    _refresh();
  }

  Future<void> _installNetworkPlugin() async {
    final manager = _manager;
    if (manager == null) return;
    final url = await _showTextInputDialog(
      title: '网络安装插件',
      label: '插件地址（JSON 或 JS）',
      confirmLabel: '安装',
    );
    if (url == null) return;
    setState(() => _loading = true);
    try {
      final result = await manager.installNetwork(url);
      try {
        await MusicSourceService.refreshAll();
      } catch (_) {}
      _notify('安装完成，导入 ${result.installed} 个插件${result.skippedNotice()}');
      _refresh();
    } catch (error) {
      _notify('安装失败：${_errorText(error, '未知错误')}');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _installLocalLx() async {
    ({String name, Uint8List bytes})? picked;
    try {
      picked = await _pickFile();
    } catch (error) {
      _notify('安装失败：${_errorText(error, '未知错误')}');
      return;
    }
    if (picked == null) return;
    try {
      var name = picked.name.trim();
      if (name.isEmpty) name = 'lx.js';
      if (!name.toLowerCase().endsWith('.js')) name = '$name.js';
      name = _fileNameOf(name);
      if (name.isEmpty) name = 'lx.js';
      final target = await _writeTempFile(name, picked.bytes);
      try {
        final script = await widget.sourceService.installLxLocal(target);
        _notify('已安装 LX 脚本：${script.name}');
      } finally {
        _deleteQuietly(target);
      }
    } catch (error) {
      _notify('安装失败：${_errorText(error, '未知错误')}');
    }
    _lxRefresh();
  }

  Future<void> _installNetworkLx() async {
    final url = await _showTextInputDialog(
      title: '网络安装 LX 脚本',
      label: '脚本地址（HTTPS 的 JS）',
      confirmLabel: '安装',
    );
    if (url == null) return;
    setState(() => _loading = true);
    try {
      final script = await widget.sourceService.installLxNetwork(url);
      _notify('安装完成：${script.name}');
    } catch (error) {
      _notify('安装失败：${_errorText(error, '未知错误')}');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
    _lxRefresh();
  }

  Future<void> _addSubscription() async {
    final manager = _manager;
    if (manager == null) return;
    final input = await showDialog<({String name, String url})>(
      context: context,
      builder: (_) => const _SubscriptionDialog(),
    );
    if (input == null) return;
    try {
      final saved = await manager.addSubscription(input.name, input.url);
      _notify('订阅已保存：${saved.name}');
      _refresh();
    } catch (error) {
      _notify('保存失败：${_errorText(error, '未知错误')}');
    }
  }

  Future<void> _updateSubscription(PluginSubscription item) async {
    final manager = _manager;
    if (manager == null) return;
    setState(() => _loading = true);
    try {
      final result = await manager.updateSubscription(item);
      try {
        await MusicSourceService.refreshAll();
      } catch (_) {}
      _notify(
        '${item.name} 更新完成，导入 ${result.installed} 个插件${result.skippedNotice()}',
      );
      _refresh();
    } catch (error) {
      _notify('更新失败：${_errorText(error, '未知错误')}');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _confirmDeleteSubscription(PluginSubscription item) async {
    final manager = _manager;
    if (manager == null) return;
    final ok = await _confirm(
      '删除订阅',
      '确定删除订阅“${item.name}”吗？已安装的插件不受影响。',
      '删除',
    );
    if (!ok) return;
    manager.removeSubscription(item.id);
    _refresh();
    _notify('已删除订阅：${item.name}');
  }

  Future<void> _confirmRemovePlugin(InstalledPlugin item) async {
    final manager = _manager;
    if (manager == null) return;
    final ok = await _confirm('卸载插件', '确定卸载“${item.name}”吗？', '卸载');
    if (!ok) return;
    manager.remove(item.id);
    _refresh();
    _notify('已卸载：${item.name}');
    unawaited(MusicSourceService.refreshAll());
  }

  Future<void> _confirmRemoveLx(LxPluginDescriptor item) async {
    final ok = await _confirm('卸载 LX 脚本', '确定卸载“${item.name}”吗？', '卸载');
    if (!ok) return;
    try {
      await widget.sourceService.uninstallLx(item.hash);
    } catch (_) {}
    _lxRefresh();
  }

  void _togglePlugin(InstalledPlugin item, bool enabled) {
    _manager?.setEnabled(item.id, enabled);
    _refresh();
    unawaited(MusicSourceService.refreshAll());
  }

  void _movePlugin(int oldIndex, int newIndex) {
    final manager = _manager;
    if (manager == null) return;
    if (newIndex == oldIndex) return;
    final item = _plugins[oldIndex];
    manager.move(item.id, newIndex - oldIndex);
    _refresh();
    unawaited(MusicSourceService.refreshAll());
  }

  Future<void> _toggleLx(LxPluginDescriptor item, bool enabled) async {
    try {
      if (enabled) {
        await widget.sourceService.setActiveLx(item.hash);
      } else if (item.active) {
        await widget.sourceService.setActiveLx(null);
      }
    } catch (_) {}
    _lxRefresh();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (_inPluginPage) return _buildPluginPage(theme);
    final enabledCount = _plugins.where((p) => p.enabled).length;
    LxPluginDescriptor? activeLx;
    for (final item in _lxList) {
      if (item.active) {
        activeLx = item;
        break;
      }
    }
    final pluginSummary = _plugins.isEmpty && _lxList.isEmpty
        ? '未安装插件'
        : '原生 $enabledCount/${_plugins.length} · LX ${activeLx?.name ?? '未启用'}';
    return _buildMainPage(theme, pluginSummary);
  }

  String get _downloadDirectoryLabel {
    final info = _downloadDirectory;
    return info.custom ? '自定义：${info.label}' : info.label;
  }

  Widget _buildMainPage(ThemeData theme, String pluginSummary) {
    return ListView(
      // 嵌入主页时底座以覆盖层悬浮，需预留空间
      padding: const EdgeInsets.only(top: 18, bottom: 190),
      children: [
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 22, vertical: 18),
          child: Text(
            '设置',
            style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold),
          ),
        ),
        _SettingGroup(
          title: '播放',
          children: [
            _SettingRow(
              '默认播放音质',
              MusicQuality.labelOf(widget.repository.playQuality),
              Icons.high_quality,
              onTap: () => unawaited(_pickPlayQuality()),
            ),
            _SettingRow(
              '默认下载音质',
              MusicQuality.labelOf(widget.repository.downloadQuality),
              Icons.download,
              onTap: () => unawaited(_pickDownloadQuality()),
            ),
          ],
        ),
        _SettingGroup(
          title: '下载与文件',
          children: [
            _SettingRow(
              '下载目录',
              _downloadDirectoryLabel,
              Icons.folder,
              onTap: () => unawaited(_openDownloadDirectory()),
            ),
            const _SettingRow('下载后转码', '关闭', Icons.transform),
          ],
        ),
        _SettingGroup(
          title: '插件',
          children: [
            _SettingRow(
              '插件管理',
              pluginSummary,
              Icons.extension,
              onTap: () => setState(() => _inPluginPage = true),
            ),
          ],
        ),
        const _SettingGroup(
          title: '界面',
          children: [
            _SettingRow('主题颜色', '跟随系统动态取色', Icons.palette),
            _SettingRow('关于 Baka Music', 'v1.0.0', Icons.info),
          ],
        ),
      ],
    );
  }

  Widget _buildPluginPage(ThemeData theme) {
    return ListView(
      padding: const EdgeInsets.only(top: 8, bottom: 190),
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 4, right: 18, top: 8),
          child: Row(
            children: [
              IconButton(
                onPressed: () => setState(() => _inPluginPage = false),
                tooltip: '返回',
                icon: const Icon(Icons.arrow_back),
              ),
              const SizedBox(width: 4),
              const Text(
                '插件管理',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
              ),
            ],
          ),
        ),
        const _SectionHeader('原生插件'),
        _SettingsGroupCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _buildInstallButtons(
                onInstallLocal: () => unawaited(_installLocalPlugin()),
                onInstallNetwork: () => unawaited(_installNetworkPlugin()),
              ),
              ListTile(
                onTap: () =>
                    setState(() => _installedExpanded = !_installedExpanded),
                title: const Text(
                  '已安装插件',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                subtitle: Text(
                  '禁用或删除插件，长按拖动可调整优先级',
                  style: TextStyle(
                    fontSize: 12,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                trailing: Icon(
                  _installedExpanded ? Icons.expand_less : Icons.expand_more,
                  semanticLabel: '展开',
                ),
              ),
              if (_installedExpanded && _plugins.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(16),
                  child: Text('暂无已安装插件'),
                ),
              if (_installedExpanded && _plugins.isNotEmpty)
                ReorderableListView.builder(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  buildDefaultDragHandles: false,
                  itemCount: _plugins.length,
                  onReorderItem: _movePlugin,
                  proxyDecorator: (child, index, animation) => Material(
                    elevation: 16,
                    color: theme.colorScheme.surfaceContainerHigh,
                    borderRadius: BorderRadius.circular(12),
                    child: child,
                  ),
                  itemBuilder: (context, index) {
                    final plugin = _plugins[index];
                    return ReorderableDelayedDragStartListener(
                      key: ValueKey(plugin.id),
                      index: index,
                      child: ListTile(
                        leading: const Icon(Icons.drag_handle),
                        title: Text(
                          '${index + 1}. ${plugin.name}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text(
                          '${plugin.version} · ${plugin.enabled ? '已启用' : '已禁用'}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Switch(
                              value: plugin.enabled,
                              onChanged: (value) =>
                                  _togglePlugin(plugin, value),
                            ),
                            IconButton(
                              onPressed: () =>
                                  unawaited(_confirmRemovePlugin(plugin)),
                              tooltip: '卸载',
                              icon: const Icon(Icons.delete),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              const Divider(height: 1),
              Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  children: [
                    const Expanded(
                      child: Text(
                        '订阅源',
                        style: TextStyle(fontWeight: FontWeight.bold),
                      ),
                    ),
                    TextButton.icon(
                      onPressed: () => unawaited(_addSubscription()),
                      icon: const Icon(Icons.add),
                      label: const Text('添加订阅'),
                    ),
                  ],
                ),
              ),
              if (_subscriptions.isEmpty)
                const Padding(
                  padding: EdgeInsets.only(
                    left: 16,
                    right: 16,
                    top: 8,
                    bottom: 16,
                  ),
                  child: Text('暂无订阅，点击添加订阅'),
                )
              else
                for (final item in _subscriptions) _subscriptionTile(item),
            ],
          ),
        ),
        const _SectionHeader('LX 取流脚本'),
        _SettingsGroupCard(child: _buildLxGroup(theme)),
      ],
    );
  }

  Widget _buildInstallButtons({
    required VoidCallback onInstallLocal,
    required VoidCallback onInstallNetwork,
  }) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Row(
        children: [
          Expanded(
            child: FilledButton.icon(
              onPressed: _loading ? null : onInstallLocal,
              icon: const Icon(Icons.folder_open),
              label: const Text('本地安装'),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: FilledButton.icon(
              onPressed: _loading ? null : onInstallNetwork,
              icon: _loading
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.language),
              label: Text(_loading ? '处理中' : '网络安装'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _subscriptionTile(PluginSubscription item) {
    return ListTile(
      leading: const Icon(Icons.rss_feed),
      title: Text(item.name),
      subtitle: Text(item.url, maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            onPressed: _loading
                ? null
                : () => unawaited(_updateSubscription(item)),
            tooltip: '更新订阅',
            icon: const Icon(Icons.refresh),
          ),
          IconButton(
            onPressed: _loading
                ? null
                : () => unawaited(_confirmDeleteSubscription(item)),
            tooltip: '删除订阅',
            icon: const Icon(Icons.delete),
          ),
        ],
      ),
    );
  }

  /// LX 组：激活状态摘要 + 安装按钮 + 脚本列表（开关互斥单选）
  Widget _buildLxGroup(ThemeData theme) {
    LxPluginDescriptor? active;
    for (final item in _lxList) {
      if (item.active) {
        active = item;
        break;
      }
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 16, right: 16, top: 12),
          child: Text(
            active != null
                ? '当前启用：${active.name}${active.version.isNotEmpty ? ' ${active.version}' : ''}'
                : '未启用（各音源走原生插件）',
            style: TextStyle(
              fontSize: 12,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        _buildInstallButtons(
          onInstallLocal: () => unawaited(_installLocalLx()),
          onInstallNetwork: () => unawaited(_installNetworkLx()),
        ),
        for (final item in _lxList)
          ListTile(
            key: ValueKey(item.hash),
            title: Text(
              item.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: Text(
              _lxSubtitle(item),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Switch(
                  value: item.active,
                  onChanged: (value) => unawaited(_toggleLx(item, value)),
                ),
                IconButton(
                  onPressed: () => unawaited(_confirmRemoveLx(item)),
                  tooltip: '卸载',
                  icon: const Icon(Icons.delete),
                ),
              ],
            ),
            onTap: () => unawaited(_toggleLx(item, !item.active)),
          ),
        if (_lxList.isEmpty)
          Padding(
            padding: const EdgeInsets.only(
              left: 16,
              right: 16,
              top: 8,
              bottom: 16,
            ),
            child: Text(
              '暂无 LX 脚本：安装后对应音源优先走 LX 取流',
              style: TextStyle(
                fontSize: 12,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
      ],
    );
  }

  String _lxSubtitle(LxPluginDescriptor item) {
    final sources = item.sources.keys.join('/');
    final parts = <String>[
      if (item.version.isNotEmpty) item.version,
      if (sources.isNotEmpty) sources,
      if (item.author.isNotEmpty) item.author,
    ];
    return parts.join(' · ');
  }
}

/// 去掉路径前缀，仅保留文件名
String _fileNameOf(String name) {
  var result = name;
  final slash = result.lastIndexOf('/');
  if (slash >= 0) result = result.substring(slash + 1);
  final backslash = result.lastIndexOf('\\');
  if (backslash >= 0) result = result.substring(backslash + 1);
  return result.trim();
}

/// 选择结果暂存到缓存目录（安装后即删除）
Future<File> _writeTempFile(String name, Uint8List bytes) async {
  final dir = await getTemporaryDirectory();
  final target = File('${dir.path}${Platform.pathSeparator}$name');
  await target.writeAsBytes(bytes, flush: true);
  return target;
}

void _deleteQuietly(File file) {
  try {
    if (file.existsSync()) file.deleteSync();
  } catch (_) {}
}

/// 设置分组：标题 + 卡片容器
class _SettingGroup extends StatelessWidget {
  const _SettingGroup({required this.title, required this.children});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _SectionHeader(title),
        _SettingsGroupCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: children,
          ),
        ),
      ],
    );
  }
}

/// 分组小标题：主色加粗
class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.title);

  final String title;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(left: 22, top: 18, bottom: 6),
      child: Text(
        title,
        style: TextStyle(
          color: theme.colorScheme.primary,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }
}

/// 分组卡片容器：surfaceContainerLow，深浅色跟随主题
class _SettingsGroupCard extends StatelessWidget {
  const _SettingsGroupCard({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 14),
      elevation: 0,
      color: theme.colorScheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
      clipBehavior: Clip.antiAlias,
      child: child,
    );
  }
}

class _SettingRow extends StatelessWidget {
  const _SettingRow(this.title, this.value, this.icon, {this.onTap});

  final String title;
  final String value;
  final IconData icon;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Icon(icon),
      title: Text(title),
      subtitle: Text(value, maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: const Icon(Icons.chevron_right),
      onTap: onTap,
    );
  }
}

/// 单输入框弹窗：内容非空才能确认
class _TextInputDialog extends StatefulWidget {
  const _TextInputDialog({
    required this.title,
    required this.label,
    required this.confirmLabel,
  });

  final String title;
  final String label;
  final String confirmLabel;

  @override
  State<_TextInputDialog> createState() => _TextInputDialogState();
}

class _TextInputDialogState extends State<_TextInputDialog> {
  final TextEditingController _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: TextField(
        controller: _controller,
        autofocus: true,
        onChanged: (_) => setState(() {}),
        decoration: InputDecoration(
          labelText: widget.label,
          border: const OutlineInputBorder(),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        TextButton(
          onPressed: _controller.text.trim().isEmpty
              ? null
              : () => Navigator.pop(context, _controller.text),
          child: Text(widget.confirmLabel),
        ),
      ],
    );
  }
}

/// 添加订阅弹窗：名称 + 地址
class _SubscriptionDialog extends StatefulWidget {
  const _SubscriptionDialog();

  @override
  State<_SubscriptionDialog> createState() => _SubscriptionDialogState();
}

class _SubscriptionDialogState extends State<_SubscriptionDialog> {
  final TextEditingController _name = TextEditingController();
  final TextEditingController _url = TextEditingController();

  @override
  void dispose() {
    _name.dispose();
    _url.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('添加插件订阅'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _name,
            autofocus: true,
            onChanged: (_) => setState(() {}),
            decoration: const InputDecoration(
              labelText: '订阅名称',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _url,
            decoration: const InputDecoration(
              labelText: '订阅地址（JSON 或 JS）',
              border: OutlineInputBorder(),
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        TextButton(
          onPressed: _name.text.trim().isEmpty
              ? null
              : () =>
                    Navigator.pop(context, (name: _name.text, url: _url.text)),
          child: const Text('保存'),
        ),
      ],
    );
  }
}
