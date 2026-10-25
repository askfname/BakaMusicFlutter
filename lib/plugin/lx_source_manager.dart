/// LX 取流脚本仓库：
/// 脚本落盘于应用支持目录 lx-plugins/、加载时做完整性校验，
/// 维护激活态（state.json）与注册表指纹（lx_generation），
/// 并提供平台音质覆盖查询与安装/卸载入口
library;

import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../data/lx_models.dart';
import 'lx_host.dart';
import 'plugin_http_client.dart' show isPluginPrivateHost;

/// LX 脚本安装/校验失败的通用错误
class LxSourceException implements Exception {
  LxSourceException(this.message);

  final String message;

  @override
  String toString() => message;
}

class LxSourceManager {
  LxSourceManager._(this._prefs, this._root);

  static const int maxScriptBytes = 5 * 1024 * 1024;
  static const int _maxScripts = 100;
  static const int _maxRedirects = 5;
  static const String _ua = 'Mozilla/5.0 (Linux; Android) BakaMusic/1.0';

  final SharedPreferences _prefs;
  final Directory _root;

  /// 脚本宿主：解析调用与探针统一走此实例
  final LxPluginHost host = LxPluginHost();

  List<LxPluginDescriptor> _descriptors = const [];
  String? _activeHash;

  static Future<LxSourceManager> create() async {
    final prefs = await SharedPreferences.getInstance();
    final support = await getApplicationSupportDirectory();
    final root = Directory(
      '${support.path}${Platform.pathSeparator}lx-plugins',
    );
    if (!root.existsSync()) root.createSync(recursive: true);
    return LxSourceManager._(prefs, root);
  }

  /// 安装列表（附带激活标记）
  List<LxPluginDescriptor> installed() => [
    for (final d in _descriptors) d.copyWith(active: d.hash == _activeHash),
  ];

  LxPluginDescriptor? active() {
    for (final d in _descriptors) {
      if (d.hash == _activeHash) return d;
    }
    return null;
  }

  /// 某源当前选中的脚本
  LxPluginDescriptor? activeFor(String source) =>
      activeLxPluginForSource(_descriptors, _activeHash, source);

  /// 注册表指纹：LX 增删改/切换后推进，供播放地址缓存失效判断
  int dataVersion() => _prefs.getInt('lx_generation') ?? 0;

  Future<void> _touchGeneration() async {
    final next = (_prefs.getInt('lx_generation') ?? 0) + 1;
    final now = DateTime.now().millisecondsSinceEpoch;
    await _prefs.setInt('lx_generation', next > now ? next : now);
  }

  /// 某平台的 LX 音质集；null 表示走原生插件
  List<String>? getQualityOverride(String platform) {
    final source = lxSourceForPlatform(platform);
    if (source == null) return null;
    final plugin = activeLxPluginForSource(_descriptors, _activeHash, source);
    if (plugin == null) return null;
    return plugin.sources[source]?.qualities.toList();
  }

  /// 启动/刷新时重载全部有效脚本
  Future<void> loadEnabled() async {
    await host.clear();
    final state = _readState();
    final next = <LxPluginDescriptor>[];
    for (final file in _listScriptFiles().take(_maxScripts)) {
      try {
        final bytes = file.readAsBytesSync();
        final code = utf8.decode(bytes, allowMalformed: true);
        _verifyIntegrity(file, code);
        final info = parseLxScriptInfo(code, _nameWithoutExtension(file.path));
        final hash = _sha256Hex(code);
        final sources = await host.loadPlugin(hash, code, info);
        next.add(
          LxPluginDescriptor(
            hash: hash,
            name: info.name,
            description: info.description,
            version: info.version,
            author: info.author,
            homepage: info.homepage,
            sourceUrl: _integritySourceUrl(file) ?? '',
            sources: sources,
          ),
        );
      } catch (error) {
        developer.log(
          'LX 脚本加载失败: ${_baseName(file.path)}',
          name: 'BakaLx',
          level: 1000,
          error: error,
        );
      }
    }
    _descriptors = next;
    _activeHash = state.configured
        ? (next.any((d) => d.hash == state.hash) ? state.hash : null)
        : (next.isEmpty ? null : next.first.hash);
    await _persistState();
    await _touchGeneration();
  }

  Future<void> setActive(String? hash) async {
    if (hash != null && !_descriptors.any((d) => d.hash == hash)) {
      throw LxSourceException('LX 脚本未安装');
    }
    _activeHash = hash;
    await _persistState();
    await _touchGeneration();
  }

  Future<LxPluginDescriptor> installLocal(File file) async {
    if (!FileSystemEntity.isFileSync(file.path)) {
      throw LxSourceException('脚本文件不存在');
    }
    if (_extension(file.path).toLowerCase() != 'js') {
      throw LxSourceException('LX 脚本仅支持 .js 文件');
    }
    final name = _nameWithoutExtension(file.path);
    final fallbackName = name.trim().isEmpty ? _baseName(file.path) : name;
    return _installCode(file.readAsBytesSync(), fallbackName, null);
  }

  Future<LxPluginDescriptor> installNetwork(String url) async {
    final clean = url.trim();
    if (!_isLxUrl(clean)) {
      throw LxSourceException('脚本地址必须是 HTTPS 的 .js 地址');
    }
    final bytes = await _fetch(clean);
    return _installCode(bytes, _scriptNameFromUrl(clean), clean);
  }

  Future<void> uninstall(String hash) async {
    await host.unload(hash);
    _deleteQuietly(File(_rootPath('$hash.js')));
    _deleteQuietly(File(_rootPath('$hash.js.integrity.json')));
    _descriptors = [
      for (final d in _descriptors)
        if (d.hash != hash) d,
    ];
    // 卸载启用中脚本后回落原生，不自动启用其他脚本
    if (_activeHash == hash) {
      _activeHash = null;
      await _persistState();
    }
    await _touchGeneration();
  }

  Future<void> close() => host.destroy();

  Future<LxPluginDescriptor> _installCode(
    Uint8List bytes,
    String fallbackName,
    String? sourceUrl,
  ) async {
    if (bytes.length > maxScriptBytes) {
      throw LxSourceException('脚本超过 5 MiB 限制');
    }
    final code = utf8.decode(bytes, allowMalformed: true);
    final hash = _sha256Hex(code);
    for (final existing in _descriptors) {
      if (existing.hash == hash) {
        if (_activeHash != hash) {
          _activeHash = hash;
          await _persistState();
          await _touchGeneration();
        }
        return existing.copyWith(active: true);
      }
    }
    final info = parseLxScriptInfo(code, fallbackName);
    final sources = await host.loadPlugin(hash, code, info);
    File(_rootPath('$hash.js')).writeAsBytesSync(bytes);
    File(_rootPath('$hash.js.integrity.json')).writeAsStringSync(
      jsonEncode(<String, dynamic>{
        'sha256': hash,
        if (sourceUrl != null && sourceUrl.trim().isNotEmpty)
          'sourceUrl': sourceUrl,
        'installedAt': DateTime.now().millisecondsSinceEpoch,
      }),
    );
    final installed = LxPluginDescriptor(
      hash: hash,
      name: info.name,
      description: info.description,
      version: info.version,
      author: info.author,
      homepage: info.homepage,
      sourceUrl: sourceUrl ?? '',
      sources: sources,
    );
    // 同名旧版本视为更新，直接替换文件与宿主
    LxPluginDescriptor? oldSameName;
    for (final d in _descriptors) {
      if (d.hash != hash && d.name == installed.name) {
        oldSameName = d;
        break;
      }
    }
    final old = oldSameName;
    if (old != null) {
      await host.unload(old.hash);
      _deleteQuietly(File(_rootPath('${old.hash}.js')));
      _deleteQuietly(File(_rootPath('${old.hash}.js.integrity.json')));
      _descriptors = [
        for (final d in _descriptors)
          if (d.hash != old.hash) d,
      ];
    }
    final merged = <LxPluginDescriptor>[..._descriptors, installed];
    _descriptors = merged.length > _maxScripts
        ? merged.sublist(merged.length - _maxScripts)
        : merged;
    _activeHash = hash;
    await _persistState();
    await _touchGeneration();
    return installed.copyWith(active: true);
  }

  List<File> _listScriptFiles() {
    final files = <File>[];
    try {
      for (final entry in _root.listSync()) {
        if (!FileSystemEntity.isFileSync(entry.path)) continue;
        if (_extension(entry.path).toLowerCase() != 'js') continue;
        files.add(File(entry.path));
      }
    } catch (_) {}
    files.sort((a, b) => _baseName(a.path).compareTo(_baseName(b.path)));
    return files;
  }

  ({bool configured, String? hash}) _readState() {
    try {
      final decoded = jsonDecode(
        File(_rootPath('state.json')).readAsStringSync(encoding: utf8),
      );
      if (decoded is! Map || !decoded.containsKey('activeHash')) {
        return (configured: false, hash: null);
      }
      final value = decoded['activeHash'];
      if (value == null) return (configured: true, hash: null);
      final text = '$value';
      return (
        configured: true,
        hash: RegExp(r'^[a-f0-9]{64}$').hasMatch(text) ? text : null,
      );
    } catch (_) {
      return (configured: false, hash: null);
    }
  }

  Future<void> _persistState() async {
    try {
      await File(_rootPath('state.json'))
          .writeAsString(jsonEncode({'activeHash': _activeHash}));
    } catch (_) {}
  }

  void _verifyIntegrity(File file, String code) {
    final sidecar = File('${file.path}.integrity.json');
    if (!sidecar.existsSync()) return;
    Map<String, dynamic>? payload;
    try {
      final decoded = jsonDecode(sidecar.readAsStringSync(encoding: utf8));
      if (decoded is Map) payload = Map<String, dynamic>.from(decoded);
    } catch (_) {}
    if (payload == null) return;
    final expected = '${payload['sha256'] ?? ''}'.trim();
    if (expected.isEmpty) return;
    if (_sha256Hex(code).toLowerCase() != expected.toLowerCase()) {
      throw LxSourceException('LX 脚本完整性校验失败');
    }
  }

  String? _integritySourceUrl(File file) {
    try {
      final decoded = jsonDecode(
        File('${file.path}.integrity.json').readAsStringSync(encoding: utf8),
      );
      final url = decoded is Map ? '${decoded['sourceUrl'] ?? ''}' : '';
      return url.trim().isEmpty ? null : url;
    } catch (_) {
      return null;
    }
  }

  bool _isLxUrl(String url) {
    // 仅支持 .js 格式（本地与网络一致）：路径须以 .js 结尾（允许 ?query），且全程 HTTPS
    final clean = url.trim();
    if (clean.isEmpty || clean.length > 8192) return false;
    final uri = Uri.tryParse(clean);
    if (uri == null || uri.scheme.toLowerCase() != 'https') return false;
    return uri.path.toLowerCase().endsWith('.js');
  }

  /// 手动跟随重定向且全程保持 HTTPS（防 http 明文降级），超时 20s，上限 5MiB
  Future<Uint8List> _fetch(String url) async {
    var current = _appendCacheBuster(url);
    if (current.length > 8192) throw LxSourceException('脚本地址过长');
    // dart:io 默认会自动解压 gzip 且响应头仍保留 content-encoding，
    // 与下方手动解压重复触发 "Filter error, bad data"，故关闭自动解压
    final client = HttpClient()..autoUncompress = false;
    client.connectionTimeout = const Duration(seconds: 20);
    try {
      var redirects = 0;
      while (true) {
        final uri = Uri.tryParse(current);
        if (uri == null || uri.host.isEmpty) {
          throw LxSourceException('脚本地址无效');
        }
        if (uri.scheme.toLowerCase() != 'https') {
          throw LxSourceException('脚本重定向必须保持 HTTPS');
        }
        if (await isPluginPrivateHost(uri.host)) {
          throw LxSourceException('脚本不能访问本机或内网地址');
        }
        final request = await client.getUrl(uri);
        request.followRedirects = false;
        request.headers.set(HttpHeaders.userAgentHeader, _ua);
        request.headers.set(HttpHeaders.acceptEncodingHeader, 'gzip, deflate');
        final response = await request.close().timeout(
          const Duration(seconds: 20),
        );
        final code = response.statusCode;
        if (code >= 300 && code <= 399 && redirects < _maxRedirects) {
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
          throw LxSourceException('脚本请求失败：$code');
        }
        Stream<List<int>> stream = response;
        final encoding = (response.headers.value('content-encoding') ?? '')
            .toLowerCase();
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
            if (total > maxScriptBytes) {
              throw LxSourceException('脚本超过 5 MiB 限制');
            }
            builder.add(chunk);
          }
        } on FormatException {
          throw LxSourceException('脚本解压失败');
        }
        return builder.takeBytes();
      }
    } on TimeoutException {
      throw LxSourceException('脚本请求超时');
    } finally {
      client.close(force: true);
    }
  }

  /// 缓存规避参数仅作用于传输 URL（含重定向首跳），保证不取到旧脚本
  String _appendCacheBuster(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null) return url;
    final sep = uri.query.isEmpty ? '?' : '&';
    return '$url${sep}_bakamusic_cache=${DateTime.now().millisecondsSinceEpoch}';
  }

  String _scriptNameFromUrl(String clean) {
    var name = clean.substring(clean.lastIndexOf('/') + 1);
    final query = name.indexOf('?');
    if (query >= 0) name = name.substring(0, query);
    final dot = name.lastIndexOf('.');
    if (dot >= 0) name = name.substring(0, dot);
    return name.trim().isEmpty ? 'lx-script' : name;
  }

  String _sha256Hex(String code) =>
      sha256.convert(utf8.encode(code)).toString();

  String _rootPath(String name) =>
      '${_root.path}${Platform.pathSeparator}$name';

  String _baseName(String path) {
    final slash = path.lastIndexOf(Platform.pathSeparator);
    return slash < 0 ? path : path.substring(slash + 1);
  }

  String _extension(String path) {
    final name = _baseName(path);
    final dot = name.lastIndexOf('.');
    return dot < 0 ? '' : name.substring(dot + 1);
  }

  String _nameWithoutExtension(String path) {
    final name = _baseName(path);
    final dot = name.lastIndexOf('.');
    return dot < 0 ? name : name.substring(0, dot);
  }

  void _deleteQuietly(File file) {
    try {
      if (file.existsSync()) file.deleteSync();
    } catch (_) {}
  }
}
