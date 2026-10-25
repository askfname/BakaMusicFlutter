/// 插件本地管理器：
/// 安装/校验/启用排序/订阅更新，注册表持久化到 SharedPreferences，
/// 插件文件存放于应用支持目录 plugins/ 下，文件名为 `<id>.js`
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'plugin_http_client.dart' show isPluginPrivateHost;

/// 插件安装/校验失败的通用错误
class PluginInstallException implements Exception {
  PluginInstallException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 同名已安装更新版本时的冲突，批量安装中可跳过
class PluginVersionConflictException implements Exception {
  PluginVersionConflictException(
    this.message, {
    this.pluginName = '',
    this.installedVersion = '',
  });

  final String message;
  final String pluginName;
  final String installedVersion;

  /// 名单标签
  String label() => (pluginName.isNotEmpty && installedVersion.isNotEmpty)
      ? '$pluginName（$installedVersion）'
      : (pluginName.isNotEmpty ? pluginName : message);

  @override
  String toString() => message;
}

/// 单插件安装清单
class PluginManifest {
  const PluginManifest({
    required this.url,
    this.name,
    this.version,
    this.sha256,
  });

  final String url;
  final String? name;
  final String? version;
  final String? sha256;
}

/// 已安装插件
class InstalledPlugin {
  const InstalledPlugin({
    required this.id,
    required this.name,
    required this.version,
    required this.sourceUrl,
    required this.fileName,
    required this.enabled,
    required this.order,
  });

  final String id;
  final String name;
  final String version;
  final String sourceUrl;
  final String fileName;
  final bool enabled;
  final int order;

  InstalledPlugin copyWith({
    String? id,
    String? name,
    String? version,
    String? sourceUrl,
    String? fileName,
    bool? enabled,
    int? order,
  }) => InstalledPlugin(
    id: id ?? this.id,
    name: name ?? this.name,
    version: version ?? this.version,
    sourceUrl: sourceUrl ?? this.sourceUrl,
    fileName: fileName ?? this.fileName,
    enabled: enabled ?? this.enabled,
    order: order ?? this.order,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'version': version,
    'sourceUrl': sourceUrl,
    'fileName': fileName,
    'enabled': enabled,
    'order': order,
  };

  static InstalledPlugin fromJson(Map<String, dynamic> o) {
    final name = _optString(o, 'name', '未命名插件');
    return InstalledPlugin(
      id: _requiredString(o, 'id'),
      name: name.trim().isEmpty ? '未命名插件' : name,
      version: _optString(o, 'version', '未知版本'),
      sourceUrl: _optString(o, 'sourceUrl', ''),
      fileName: _requiredString(o, 'fileName'),
      enabled: _optBool(o, 'enabled', true),
      order: o['order'] is int ? o['order'] as int : 0,
    );
  }
}

/// 插件订阅（远程清单 URL）
class PluginSubscription {
  const PluginSubscription({
    required this.id,
    required this.name,
    required this.url,
    this.lastUpdated = 0,
  });

  final String id;
  final String name;
  final String url;
  final int lastUpdated;

  PluginSubscription copyWith({int? lastUpdated}) => PluginSubscription(
    id: id,
    name: name,
    url: url,
    lastUpdated: lastUpdated ?? this.lastUpdated,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'url': url,
    'lastUpdated': lastUpdated,
  };

  static PluginSubscription fromJson(Map<String, dynamic> o) =>
      PluginSubscription(
        id: _requiredString(o, 'id'),
        name: _requiredString(o, 'name'),
        url: _requiredString(o, 'url'),
        lastUpdated: o['lastUpdated'] is int ? o['lastUpdated'] as int : 0,
      );
}

/// 批量安装结果：成功数与因版本冲突跳过的清单名
class BatchInstallResult {
  const BatchInstallResult(this.installed, [this.skipped = const []]);

  final int installed;
  final List<String> skipped;

  /// 成功提示后的跳过说明，无跳过时为空
  String skippedNotice() =>
      skipped.isEmpty ? '' : '；已安装更新的 ${skipped.join('、')}，请卸载后重试';
}

/// 插件注册表与文件管理
class PluginManager {
  PluginManager._(this._prefs, this._root);

  final SharedPreferences _prefs;
  final Directory _root;

  static const int _maxPluginBytes = 5 * 1024 * 1024;
  static const int _maxResponseBytes = 16 * 1024 * 1024;
  static const int _maxRedirects = 5;
  static const String _ua = 'Mozilla/5.0 (Linux; Android) BakaMusic/1.0';

  static Future<PluginManager> create() async {
    final prefs = await SharedPreferences.getInstance();
    final support = await getApplicationSupportDirectory();
    final root = Directory('${support.path}${Platform.pathSeparator}plugins');
    if (!root.existsSync()) root.createSync(recursive: true);
    return PluginManager._(prefs, root);
  }

  /// 启用插件（按 order 升序）
  List<InstalledPlugin> plugins() =>
      _readPlugins().where((p) => p.enabled).toList()
        ..sort((a, b) => a.order.compareTo(b.order));

  List<String> enabledPluginNames() => plugins().map((p) => p.name).toList();

  /// 全部插件（按 order 升序）
  List<InstalledPlugin> allPlugins() =>
      _readPlugins()..sort((a, b) => a.order.compareTo(b.order));

  List<PluginSubscription> subscriptions() => _readSubscriptions();

  File pluginFile(InstalledPlugin plugin) =>
      File('${_root.path}${Platform.pathSeparator}${plugin.fileName}');

  /// 读取插件源码文本（加载到运行时用）
  Future<String> readPluginSource(InstalledPlugin plugin) async {
    final file = pluginFile(plugin);
    if (!file.existsSync()) {
      throw PluginInstallException('插件文件不存在: ${plugin.fileName}');
    }
    return utf8.decode(await file.readAsBytes(), allowMalformed: true);
  }

  /// 插件注册表指纹：插件增删改后推进，调用方据此自动重载运行时
  int dataVersion() => _prefs.getInt('plugins_generation') ?? 0;

  void _touchGeneration() {
    final old = _prefs.getInt('plugins_generation') ?? 0;
    final now = DateTime.now().millisecondsSinceEpoch;
    _prefs.setInt('plugins_generation', old + 1 > now ? old + 1 : now);
  }

  Future<PluginSubscription> addSubscription(String name, String url) async {
    final cleanName = name.trim();
    if (cleanName.isEmpty) throw PluginInstallException('请输入订阅名称');
    if (!isPluginUrl(url)) {
      throw PluginInstallException('订阅地址必须是 HTTPS 的 .json 或 .js 地址');
    }
    final item = PluginSubscription(
      id: _hash(url),
      name: cleanName,
      url: url.trim(),
    );
    final values =
        _readSubscriptions().where((s) => s.url != item.url).toList() + [item];
    _saveSubscriptions(values);
    return item;
  }

  Future<BatchInstallResult> updateSubscription(
    PluginSubscription subscription,
  ) async {
    final result = await installFromUrl(subscription.url);
    _saveSubscriptions(
      _readSubscriptions()
          .map(
            (s) => s.id == subscription.id
                ? s.copyWith(lastUpdated: DateTime.now().millisecondsSinceEpoch)
                : s,
          )
          .toList(),
    );
    return result;
  }

  Future<BatchInstallResult> updateAllSubscriptions() async {
    var total = 0;
    final skipped = <String>[];
    for (final subscription in _readSubscriptions()) {
      final result = await updateSubscription(subscription);
      total += result.installed;
      skipped.addAll(result.skipped);
    }
    return BatchInstallResult(total, _distinct(skipped));
  }

  void removeSubscription(String id) {
    _saveSubscriptions(_readSubscriptions().where((s) => s.id != id).toList());
  }

  /// 本地安装：.js 单脚本以文件名命名；.json 清单名取清单 name
  Future<InstalledPlugin> installLocal(File file) async {
    if (!file.existsSync() || !FileSystemEntity.isFileSync(file.path)) {
      throw PluginInstallException('插件文件不存在');
    }
    final baseName = _baseName(file.path);
    final ext = _extension(baseName).toLowerCase();
    if (ext != 'js' && ext != 'json') {
      throw PluginInstallException('本地插件仅支持 .js / .json 文件');
    }
    if (ext == 'json') {
      // 本地清单：名取清单 name
      final text = await file.readAsString();
      if (utf8.encode(text).length > _maxPluginBytes) {
        throw PluginInstallException('插件超过 5 MiB 限制');
      }
      final sources = _readManifestEntries(text, null);
      if (sources.isEmpty) throw PluginInstallException('清单中没有可用插件');
      InstalledPlugin? last;
      var count = 0;
      final skipped = <String>[];
      // 倒序安装，版本冲突单条跳过
      for (final src in sources.reversed) {
        try {
          final bytes = await _requestBytes(src.url);
          _verifyHash(bytes, src.sha256, src.url);
          last = _register(
            PluginManifest(
              url: src.url,
              name: src.name,
              version: src.version,
              sha256: src.sha256,
            ),
            bytes,
          );
          count++;
        } on PluginVersionConflictException catch (e) {
          skipped.add(e.label());
        }
      }
      if (count == 0 && skipped.isNotEmpty) {
        throw PluginVersionConflictException(
          '已安装更新的 ${_distinct(skipped).join('、')}，请卸载后重试',
        );
      }
      if (last == null) throw PluginInstallException('清单安装失败');
      return last;
    }
    final bytes = await file.readAsBytes();
    if (bytes.length > _maxPluginBytes) {
      throw PluginInstallException('插件超过 5 MiB 限制');
    }
    final text = utf8.decode(bytes, allowMalformed: true);
    // 单个 js：以文件名命名
    final name = _nameWithoutExtension(baseName);
    return _register(
      PluginManifest(
        url: 'local://$baseName',
        name: name.isEmpty ? baseName : name,
        version: extractVersion(text) ?? '本地文件',
      ),
      bytes,
      placeFirst: true,
    );
  }

  Future<BatchInstallResult> installNetwork(String url) => installFromUrl(url);

  Future<BatchInstallResult> installFromUrl(String url) async {
    final clean = url.trim();
    if (!isPluginUrl(clean)) {
      throw PluginInstallException('插件地址必须是 HTTPS 的 .json 或 .js 地址');
    }
    final bytes = await _requestBytes(clean);
    final text = utf8.decode(bytes, allowMalformed: true).trimLeft();
    if (text.startsWith('{')) {
      final base = Uri.tryParse(clean)?.toString() ?? clean;
      final sources = _readManifestEntries(text, base);
      // 倒序安装；名取清单 name（缺失拒绝），版本冲突单条跳过
      var count = 0;
      final skipped = <String>[];
      for (final src in sources.reversed) {
        final entryName = src.name?.trim() ?? '';
        if (entryName.isEmpty) {
          throw PluginInstallException('不支持的链接：清单条目缺少插件名称');
        }
        try {
          final pluginBytes = await _requestBytes(src.url);
          _verifyHash(pluginBytes, src.sha256, src.url);
          _register(
            PluginManifest(
              url: src.url,
              name: entryName,
              version: src.version,
              sha256: src.sha256,
            ),
            pluginBytes,
          );
          count++;
        } on PluginVersionConflictException catch (e) {
          skipped.add(e.label());
        }
      }
      if (count == 0 && skipped.isNotEmpty) {
        throw PluginVersionConflictException(
          '已安装更新的 ${_distinct(skipped).join('、')}，请卸载后重试',
        );
      }
      if (count == 0) throw PluginInstallException('清单中没有可用插件');
      return BatchInstallResult(count, _distinct(skipped));
    }
    _verifyHash(bytes, null, clean);
    final jsText = utf8.decode(bytes, allowMalformed: true);
    // 单个 js：以 URL 文件名命名
    final uri = Uri.tryParse(clean);
    var fileName = '';
    if (uri != null && uri.pathSegments.isNotEmpty) {
      final last = uri.pathSegments.last;
      final dot = last.lastIndexOf('.');
      fileName = dot < 0 ? last : last.substring(0, dot);
    }
    if (fileName.isEmpty) fileName = '网络插件';
    // 单个安装默认排序置于首位
    _register(
      PluginManifest(
        url: clean,
        name: fileName,
        version: extractVersion(jsText),
      ),
      bytes,
      placeFirst: true,
    );
    return const BatchInstallResult(1);
  }

  void setEnabled(String id, bool enabled) {
    _savePlugins(
      _readPlugins()
          .map((p) => p.id == id ? p.copyWith(enabled: enabled) : p)
          .toList(),
    );
  }

  void remove(String id) {
    final current = _readPlugins();
    InstalledPlugin? found;
    for (final p in current) {
      if (p.id == id) {
        found = p;
        break;
      }
    }
    if (found == null) return;
    _deleteQuietly(pluginFile(found));
    _savePlugins(current.where((p) => p.id != id).toList());
  }

  void move(String id, int delta) {
    // 已安装列表整体按 order 相邻交换，启用/禁用统一处理；
    // 实际播放优先级取启用子集的相对顺序，与展示顺序一致
    final full = _readPlugins()..sort((a, b) => a.order.compareTo(b.order));
    final from = full.indexWhere((p) => p.id == id);
    if (from < 0) return;
    final to = (from + delta).clamp(0, full.length - 1);
    if (from == to) return;
    final item = full.removeAt(from);
    full.insert(to, item);
    _persistPlugins([
      for (var i = 0; i < full.length; i++) full[i].copyWith(order: i),
    ]);
  }

  InstalledPlugin _register(
    PluginManifest manifest,
    Uint8List bytes, {
    bool placeFirst = false,
  }) {
    if (bytes.length > _maxPluginBytes) {
      throw PluginInstallException('插件超过 5 MiB 限制');
    }
    // 安装名即展示名，缺失直接拒绝
    final displayName = manifest.name?.trim() ?? '';
    if (displayName.isEmpty) throw PluginInstallException('不支持的链接');
    final extractedVersion = extractVersion(
      utf8.decode(bytes, allowMalformed: true),
    );
    final manifestVersion = manifest.version?.trim() ?? '';
    final version = manifestVersion.isNotEmpty
        ? manifestVersion
        : (extractedVersion ?? '未知版本');
    final id = _hash(manifest.url);
    final current = _readPlugins();
    InstalledPlugin? oldSameUrl;
    for (final p in current) {
      if (p.id == id) {
        oldSameUrl = p;
        break;
      }
    }
    // 同名去重：新版本替换旧版本
    InstalledPlugin? oldSamePlatform;
    for (final p in current) {
      if (p.name == displayName && p.id != id) {
        oldSamePlatform = p;
        break;
      }
    }
    if (oldSamePlatform != null) {
      // 未知版本跳过新旧比较
      final comparable = oldSamePlatform.version != '未知版本' && version != '未知版本';
      if (comparable && compareVersion(oldSamePlatform.version, version) > 0) {
        throw PluginVersionConflictException(
          '已安装更新的 $displayName（${oldSamePlatform.version}），请卸载后重试',
          pluginName: displayName,
          installedVersion: oldSamePlatform.version,
        );
      }
      _deleteQuietly(pluginFile(oldSamePlatform));
    }
    var minOrder = 0;
    if (current.isNotEmpty) {
      minOrder = current.map((p) => p.order).reduce((a, b) => a < b ? a : b);
    }
    final plugin = InstalledPlugin(
      id: id,
      name: displayName,
      version: version,
      sourceUrl: manifest.url,
      fileName: '$id.js',
      enabled: oldSameUrl?.enabled ?? oldSamePlatform?.enabled ?? true,
      // 存量更新保持原位；单个新装排序置于首位，批量新装追加
      order:
          oldSameUrl?.order ??
          oldSamePlatform?.order ??
          (placeFirst ? minOrder - 1 : current.length),
    );
    final file = File(
      '${_root.path}${Platform.pathSeparator}${plugin.fileName}',
    );
    file.writeAsBytesSync(bytes);
    final oldId = oldSamePlatform?.id;
    final next = [...current.where((p) => p.id != id && p.id != oldId), plugin];
    _savePlugins(next);
    return plugin;
  }

  Future<Uint8List> _requestBytes(String url) async {
    // 追加缓存规避参数，防止 CDN 或代理返回旧清单或旧插件
    final wireUrl = _appendCacheBuster(url);
    // dart:io 默认会自动解压 gzip 且响应头仍保留 content-encoding，
    // 与下方手动解压重复触发 "Filter error, bad data"，故关闭自动解压
    final client = HttpClient()..autoUncompress = false;
    client.connectionTimeout = const Duration(seconds: 15);
    try {
      var current = wireUrl;
      var redirects = 0;
      while (true) {
        final uri = Uri.tryParse(current);
        if (uri == null || uri.host.isEmpty) {
          throw PluginInstallException('插件请求地址无效');
        }
        // 仅接受 HTTPS 重定向
        if (uri.scheme.toLowerCase() != 'https') {
          throw PluginInstallException('插件重定向必须保持 HTTPS');
        }
        if (await isPluginPrivateHost(uri.host)) {
          throw PluginInstallException('插件不能访问本机或内网地址');
        }
        final request = await client.getUrl(uri);
        request.followRedirects = false;
        request.headers.set(HttpHeaders.userAgentHeader, _ua);
        request.headers.set(HttpHeaders.acceptHeader, '*/*');
        request.headers.set(HttpHeaders.acceptEncodingHeader, 'gzip, deflate');
        final response = await request.close().timeout(
          const Duration(seconds: 15),
        );
        final code = response.statusCode;
        if (_redirectCodes.contains(code) && redirects < _maxRedirects) {
          final location =
              response.headers.value(HttpHeaders.locationHeader)?.trim() ?? '';
          if (location.isNotEmpty) {
            try {
              await response.drain<void>();
            } catch (_) {}
            current = uri.resolve(location).toString();
            redirects++;
            continue;
          }
        }
        if (code < 200 || code > 299) {
          try {
            await response.drain<void>();
          } catch (_) {}
          throw PluginInstallException('插件请求失败：$code');
        }
        if (response.contentLength > _maxResponseBytes) {
          throw PluginInstallException('响应超过 16 MiB 限制');
        }
        final encoding = (response.headers.value('content-encoding') ?? '')
            .toLowerCase();
        Stream<List<int>> stream = response;
        if (encoding.contains('gzip')) {
          stream = gzip.decoder.bind(response);
        } else if (encoding.contains('deflate')) {
          stream = ZLibDecoder().bind(response);
        }
        final builder = BytesBuilder(copy: false);
        var total = 0;
        try {
          await for (final chunk in stream) {
            total += chunk.length;
            if (total > _maxResponseBytes) {
              throw PluginInstallException('响应超过 16 MiB 限制');
            }
            builder.add(chunk);
          }
        } on FormatException {
          throw PluginInstallException('响应解压失败');
        }
        return builder.takeBytes();
      }
    } on TimeoutException {
      throw PluginInstallException('插件请求超时');
    } finally {
      client.close(force: true);
    }
  }

  static const Set<int> _redirectCodes = {301, 302, 303, 307, 308};

  /// 缓存规避参数仅作用于传输 URL，注册 id 仍使用原始 URL
  String _appendCacheBuster(String url) {
    if (!url.toLowerCase().startsWith('http')) return url;
    final uri = Uri.tryParse(url);
    if (uri == null) return url;
    final sep = uri.query.isEmpty ? '?' : '&';
    return '$url${sep}_bakamusic_cache=${DateTime.now().millisecondsSinceEpoch}';
  }

  /// 清单条目（url 已解析为绝对地址且强制 HTTPS，上限 100 条）
  List<_RemoteSource> _readManifestEntries(String raw, String? baseUrl) {
    final dynamic decoded;
    try {
      decoded = jsonDecode(raw);
    } catch (_) {
      throw PluginInstallException('清单格式无效');
    }
    if (decoded is! Map) throw PluginInstallException('清单格式无效');
    final entries = decoded['plugins'];
    final out = <_RemoteSource>[];
    if (entries is! List) return out;
    for (final item in entries) {
      if (item is! Map) continue;
      var pluginUrl = '${item['url'] ?? ''}'.trim();
      if (pluginUrl.isEmpty) continue;
      if (baseUrl != null) {
        final base = Uri.tryParse(baseUrl);
        if (base != null) {
          pluginUrl = base.resolve(pluginUrl).toString();
        }
      }
      // 清单条目同样要求使用 HTTPS
      if (!pluginUrl.toLowerCase().startsWith('https://')) continue;
      final rawSha = '${item['sha256'] ?? ''}'.trim();
      final sha = parseExpectedSha256(
        rawSha.isNotEmpty ? rawSha : '${item['integrity'] ?? ''}'.trim(),
      );
      final entryName = '${item['name'] ?? ''}'.trim();
      final entryVersion = '${item['version'] ?? ''}'.trim();
      out.add(
        _RemoteSource(
          pluginUrl,
          sha,
          entryName.isEmpty ? null : entryName,
          entryVersion.isEmpty ? null : entryVersion,
        ),
      );
      if (out.length >= 100) break;
    }
    return out;
  }

  void _verifyHash(Uint8List bytes, String? expected, String urlForMsg) {
    if (expected == null || expected.trim().isEmpty) return;
    final actual = _hashBytes(bytes).toLowerCase();
    if (actual != expected.toLowerCase()) {
      throw PluginInstallException('插件校验失败：$urlForMsg');
    }
  }

  List<InstalledPlugin> _readPlugins() =>
      _decode(_prefs.getString('plugins'), InstalledPlugin.fromJson);

  void _savePlugins(List<InstalledPlugin> values) =>
      _persistPlugins(_reorder(values));

  void _persistPlugins(List<InstalledPlugin> values) {
    _prefs.setString(
      'plugins',
      jsonEncode([for (final item in values) item.toJson()]),
    );
    _touchGeneration();
  }

  List<PluginSubscription> _readSubscriptions() =>
      _decode(_prefs.getString('subscriptions'), PluginSubscription.fromJson);

  void _saveSubscriptions(List<PluginSubscription> values) {
    _prefs.setString(
      'subscriptions',
      jsonEncode([for (final item in values) item.toJson()]),
    );
  }

  /// 注册表解码失败时整体回退为空列表
  static List<T> _decode<T>(
    String? raw,
    T Function(Map<String, dynamic>) parser,
  ) {
    try {
      final dynamic decoded = jsonDecode(raw ?? '[]');
      if (decoded is! List) return const [];
      return [for (final item in decoded) parser(_requireObject(item))];
    } catch (_) {
      return const [];
    }
  }

  static Map<String, dynamic> _requireObject(dynamic value) {
    if (value is! Map) throw const FormatException('not an object');
    return Map<String, dynamic>.from(value);
  }

  List<InstalledPlugin> _reorder(List<InstalledPlugin> values) {
    final sorted = List<InstalledPlugin>.of(values)
      ..sort((a, b) {
        final c = a.order.compareTo(b.order);
        return c != 0 ? c : a.id.compareTo(b.id);
      });
    return [
      for (var i = 0; i < sorted.length; i++) sorted[i].copyWith(order: i),
    ];
  }

  static void _deleteQuietly(File file) {
    try {
      if (file.existsSync()) file.deleteSync();
    } catch (_) {}
  }

  static List<String> _distinct(List<String> values) {
    final out = <String>[];
    for (final value in values) {
      if (!out.contains(value)) out.add(value);
    }
    return out;
  }

  static String _baseName(String path) {
    final uri = Uri.file(path);
    return uri.pathSegments.isEmpty ? path : uri.pathSegments.last;
  }

  /// 点号后部分，无点或点在末尾为 ""
  static String _extension(String name) {
    final dot = name.lastIndexOf('.');
    return dot < 0 || dot == name.length - 1 ? '' : name.substring(dot + 1);
  }

  /// 无点返回自身，点在开头返回 ""
  static String _nameWithoutExtension(String name) {
    final dot = name.lastIndexOf('.');
    return dot < 0 ? name : name.substring(0, dot);
  }

  /// 判断是否为 HTTPS 的 .json/.js 插件地址
  static bool isPluginUrl(String url) {
    final uri = Uri.tryParse(url.trim());
    if (uri == null) return false;
    final path = uri.path.toLowerCase();
    return uri.scheme.toLowerCase() == 'https' &&
        (path.endsWith('.json') || path.endsWith('.js'));
  }

  /// 解析期望的 SHA-256：64 位 hex 或 sha256-base64
  static String? parseExpectedSha256(String? value) {
    if (value == null || value.trim().isEmpty) return null;
    final v = value.trim();
    if (RegExp(r'^[a-fA-F0-9]{64}$').hasMatch(v)) return v.toLowerCase();
    final match = RegExp(r'^sha256-([A-Za-z0-9+/=]+)$').firstMatch(v);
    if (match == null) throw PluginInstallException('插件 SHA-256 非法');
    final List<int> digest;
    try {
      digest = base64.decode(match.group(1)!);
    } catch (_) {
      throw PluginInstallException('插件 SHA-256 非法');
    }
    if (digest.length != 32) throw PluginInstallException('插件 SHA-256 非法');
    return [for (final byte in digest) byte.toRadixString(16).padLeft(2, '0')]
        .join();
  }

  static String _hashBytes(List<int> bytes) => sha256.convert(bytes).toString();

  static String _hash(String value) =>
      _hashBytes(utf8.encode(value)).substring(0, 24);

  /// 从 JS 源码提取版本号：键可带引号，排除 version_code 等复合键；
  /// 版本号以数字开头，导出定义在末尾故取最后一个
  static String? extractVersion(String js) {
    final reg = RegExp(
      '''[^A-Za-z0-9_\$]["']?version["']?\\s*:\\s*["']([^"']{1,32})["']''',
    );
    final values = <String>[];
    for (final match in reg.allMatches(js)) {
      final value = match.group(1)!.trim();
      if (value.isNotEmpty) values.add(value);
    }
    String? last;
    for (final value in values) {
      if (_looksVersioned(value)) last = value;
    }
    if (last != null) return last;
    return values.isEmpty ? null : values.last;
  }

  static bool _looksVersioned(String value) {
    final first = value.codeUnitAt(0);
    if (first >= 0x30 && first <= 0x39) return true;
    if ((value[0] == 'v' || value[0] == 'V') && value.length > 1) {
      final second = value.codeUnitAt(1);
      return second >= 0x30 && second <= 0x39;
    }
    return false;
  }

  /// 简单版本比较：大于 0 表示旧版本更新，小于 0 表示新版本更新，等于 0 相同
  static int compareVersion(String oldV, String newV) {
    List<int> parts(String v) {
      var text = v.trim();
      while (text.startsWith('v') || text.startsWith('V')) {
        text = text.substring(1);
      }
      return [
        for (final part in text.split(RegExp(r'[.\-_]')))
          int.tryParse(part.replaceAll(RegExp(r'[^0-9]'), '')) ?? 0,
      ];
    }

    final a = parts(oldV);
    final b = parts(newV);
    final length = a.length > b.length ? a.length : b.length;
    for (var i = 0; i < length; i++) {
      final x = i < a.length ? a[i] : 0;
      final y = i < b.length ? b[i] : 0;
      if (x != y) return x - y;
    }
    return 0;
  }
}

class _RemoteSource {
  const _RemoteSource(this.url, this.sha256, this.name, this.version);

  final String url;
  final String? sha256;
  final String? name;
  final String? version;
}

String _requiredString(Map<String, dynamic> o, String key) {
  final value = o[key];
  if (value is String) return value;
  throw FormatException('missing $key');
}

String _optString(Map<String, dynamic> o, String key, String fallback) =>
    o[key]?.toString() ?? fallback;

bool _optBool(Map<String, dynamic> o, String key, bool fallback) {
  final value = o[key];
  if (value is bool) return value;
  if (value is String) {
    if (value.toLowerCase() == 'true') return true;
    if (value.toLowerCase() == 'false') return false;
  }
  return fallback;
}
