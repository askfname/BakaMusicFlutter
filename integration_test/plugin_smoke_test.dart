/// 插件运行时冒烟验证：
///   flutter test integration_test/plugin_smoke_test.dart -d `device-id`
///
/// 覆盖 worker 装载、search 数组包装、缺失方法、JS 异常、超时取消后复用、
/// runtime 端到端（含 BakaHttp 真实网络挂起/重放）、坏插件装载失败，
/// 以及 LX 脚本装载/探针内网拦截/安装激活与 LX 失败回退原生。
library;

import 'dart:convert';
import 'dart:io';

import 'package:baka_music/data/lx_models.dart';
import 'package:baka_music/models/media_models.dart';
import 'package:baka_music/plugin/js_worker.dart';
import 'package:baka_music/plugin/lx_host.dart';
import 'package:baka_music/plugin/lx_resolver.dart';
import 'package:baka_music/plugin/lx_source_manager.dart';
import 'package:baka_music/plugin/music_plugin_runtime.dart';
import 'package:baka_music/plugin/plugin_manager.dart';
import 'package:baka_music/plugin/plugin_router.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

/// 测试插件：CommonJS 导出，覆盖数组返回、对象返回与抛错
const String _pluginSource = r'''
var SONG = {
  id: 342319503,
  songmid: '0039MnYb0qxYhV',
  title: '晴天',
  artist: '周杰伦',
  album: '叶惠美',
  duration: 269,
  coverImg: 'https://example.com/cover.jpg'
};
module.exports = {
  platform: '测试平台',
  supportedQualities: ['128k', '320k', 'flac'],
  version: '1.0.0',
  async search(query, page, type) {
    return [Object.assign({}, SONG, {
      title: '搜索:' + query + ':' + page + ':' + type
    })];
  },
  async getMusicInfo(info) {
    var merged = Object.assign({}, info);
    merged.album = '叶惠美(2003)';
    merged.duration = 270;
    return merged;
  },
  async getMediaSource(info, quality) {
    var res = BakaHttp.request(JSON.stringify({
      url: 'https://example.com/',
      method: 'GET'
    }));
    if (!res || res.indexOf('__error') >= 0) {
      throw new Error('http failed');
    }
    return {
      url: 'https://example.com/audio/' + encodeURIComponent(quality) + '.mp3',
      quality: quality,
      headers: { 'Referer': 'https://example.com/', 'User-Agent': 'baka-test' }
    };
  },
  async boom() {
    throw new Error('故意失败');
  },
  async slow() {
    var s = 0;
    for (var i = 0; i < 5000000; i++) s += i;
    return { total: s };
  }
};
''';

/// 合成 LX 脚本：声明 kw 源与四档音质，取流返回本机地址（用于验证探针拦截）
const String _lxScriptSource = r'''
/*
 * @name 合成LX脚本
 * @version 9.9.9
 * @author BakaSmoke
 */
globalThis.lx.on('request', function (context) {
  if (context.action !== 'musicUrl') return null;
  return 'http://127.0.0.1:9/lx-' + context.source + '-' + context.info.type + '.mp3';
});
globalThis.lx.send('inited', {
  sources: {
    kw: { name: '酷我合成', type: 'music', actions: ['musicUrl'], qualitys: ['96k', '128k', '320k', 'flac'] }
  },
  openDevTools: false
});
''';

/// 合成原生插件：无网络依赖，取流直接返回静态地址
const String _lxNativePluginSource = r'''
module.exports = {
  platform: '酷我音乐',
  supportedQualities: ['96k', '128k', '320k', 'flac'],
  version: '1.0.0',
  async search(query, page) {
    return [{ id: 'kw-1', songmid: 'kw-1', title: '合成:' + query, artist: '测试', duration: 200 }];
  },
  async getMediaSource(info, quality) {
    return { url: 'https://example.com/native-' + quality + '.mp3', quality: quality };
  }
};
''';

String _hashOf(String ch) => List.filled(64, ch).join();

File _writeTempScript(String prefix, String fileName, String content) {
  final dir = Directory.systemTemp.createTempSync(prefix);
  final file = File('${dir.path}${Platform.pathSeparator}$fileName');
  file.writeAsStringSync(content);
  addTearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });
  return file;
}

Future<void> _drainLx(LxSourceManager manager) async {
  for (final descriptor in manager.installed()) {
    await manager.uninstall(descriptor.hash);
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('worker 装载并解析平台与音质', (tester) async {
    final worker = await PluginWorker.spawn();
    addTearDown(() async => worker.close());
    final logs = <String>[];
    worker.onLog = (level, message) => logs.add('$level|$message');
    final info = await worker.load('测试插件', _pluginSource);
    expect(info.platform, '测试平台');
    expect(info.qualities, ['128k', '320k', 'flac']);
    expect(worker.isDead, isFalse);
  });

  testWidgets('search 数组被包装为 data 且 id 可还原', (tester) async {
    final worker = await PluginWorker.spawn();
    addTearDown(() async => worker.close());
    await worker.load('测试插件', _pluginSource);
    final raw = await worker.invoke('search', jsonEncode(['晴天', 1, 'music']));
    final map = jsonDecode(raw) as Map<String, dynamic>;
    final data = map['data'] as List;
    expect(data, hasLength(1));
    final song = data.first as Map<String, dynamic>;
    expect(song['title'], '搜索:晴天:1:music');
    expect('${song['id']}', '342319503');
  });

  testWidgets('缺失方法返回空对象、JS 异常映射为 PluginJsErrorException', (tester) async {
    final worker = await PluginWorker.spawn();
    addTearDown(() async => worker.close());
    await worker.load('测试插件', _pluginSource);
    expect(await worker.invoke('notExist', '[]'), '{}');
    await expectLater(
      worker.invoke('boom', '[]'),
      throwsA(isA<PluginJsErrorException>()),
    );
    // 异常后 worker 仍可继续服务
    final raw = await worker.invoke('search', jsonEncode(['a', 2, 'music']));
    expect((jsonDecode(raw) as Map<String, dynamic>)['data'], hasLength(1));
  });

  testWidgets('调用超时后取消，worker 仍可复用', (tester) async {
    final worker = await PluginWorker.spawn();
    addTearDown(() async => worker.close());
    await worker.load('测试插件', _pluginSource);
    await expectLater(
      worker.invoke('slow', '[]', timeout: const Duration(milliseconds: 1)),
      throwsA(isA<PluginWorkerTimeoutException>()),
    );
    await Future<void>.delayed(const Duration(milliseconds: 500));
    final raw = await worker.invoke('search', jsonEncode(['x', 1, 'music']));
    expect((jsonDecode(raw) as Map<String, dynamic>)['data'], hasLength(1));
  });

  testWidgets('runtime 端到端：搜索、详情与真实网络挂起重放', (tester) async {
    final runtime = MusicPluginRuntime();
    addTearDown(runtime.destroy);
    final plugin = await runtime.loadPlugin(
      id: 'smoke',
      name: '测试插件',
      source: _pluginSource,
    );
    expect(plugin, isNotNull);
    final page = await plugin!.search('晴天', 1);
    expect(page.data, hasLength(1));
    final item = page.data.first;
    expect(item.id, '342319503');
    expect(item.platform, '测试平台');
    expect(item.title, '搜索:晴天:1:music');
    expect(item.durationMs, 269000);
    expect(item.artwork, 'https://example.com/cover.jpg');
    expect(item.rawJson, isNotNull);
    final info = await plugin.getMusicInfo(item);
    expect(info, isNotNull);
    expect(info!.durationMs, 270000);
    expect(info.album, '叶惠美');
    // 网络请求在 JS 挂起后由宿主执行并重放，验证完整链路
    final resolved = await plugin.getMediaSource(item, '320k');
    expect(resolved, isNotNull);
    expect(resolved!.mediaUrl, 'https://example.com/audio/320k.mp3');
    expect(resolved.mediaHeaders['Referer'], 'https://example.com/');
    expect(resolved.mediaHeaders['User-Agent'], 'baka-test');
  });

  testWidgets('无导出对象的插件装载失败返回 null', (tester) async {
    final runtime = MusicPluginRuntime();
    addTearDown(runtime.destroy);
    final bad = await runtime.loadPlugin(
      id: 'bad',
      name: '坏插件',
      source: 'module.exports = null;',
    );
    expect(bad, isNull);
  });

  testWidgets('LX 脚本装载声明 source，未声明音质被拒绝', (tester) async {
    final host = LxPluginHost();
    addTearDown(host.destroy);
    final hash = _hashOf('a');
    final sources = await host.loadPlugin(
      hash,
      _lxScriptSource,
      const LxScriptInfo(name: '合成LX脚本'),
    );
    expect(sources.keys, contains('kw'));
    expect(
      sources['kw']!.qualities,
      containsAll(['96k', '128k', '320k', 'flac']),
    );
    await expectLater(
      host.invoke(hash, 'kw', 'master', '{}'),
      throwsA(
        isA<LxHostException>().having(
          (e) => e.message,
          'message',
          contains('LX 不支持该音质'),
        ),
      ),
    );
    await expectLater(
      host.invoke(_hashOf('f'), 'kw', '128k', '{}'),
      throwsA(
        isA<LxHostException>().having(
          (e) => e.message,
          'message',
          contains('LX 脚本未加载'),
        ),
      ),
    );
  });

  testWidgets('LX 取流探针拒绝本机与内网地址', (tester) async {
    final host = LxPluginHost();
    addTearDown(host.destroy);
    final hash = _hashOf('b');
    await host.loadPlugin(
      hash,
      _lxScriptSource,
      const LxScriptInfo(name: '合成LX脚本'),
    );
    await expectLater(
      host.invoke(hash, 'kw', '128k', jsonEncode({'id': 'kw-1'})),
      throwsA(
        isA<LxHostException>().having(
          (e) => e.message,
          'message',
          contains('本机或内网'),
        ),
      ),
    );
  });

  testWidgets('LX 脚本安装、元信息解析与激活质量覆盖', (tester) async {
    final manager = await LxSourceManager.create();
    addTearDown(() async {
      await _drainLx(manager);
      await manager.close();
    });
    await _drainLx(manager);
    final file = _writeTempScript('lx_smoke', 'combo_lx.js', _lxScriptSource);
    final installed = await manager.installLocal(file);
    expect(installed.hash, matches(RegExp(r'^[a-f0-9]{64}$')));
    expect(installed.name, '合成LX脚本');
    expect(installed.version, '9.9.9');
    expect(installed.sourceUrl, isEmpty);
    await manager.setActive(installed.hash);
    expect(manager.active()?.hash, installed.hash);
    expect(manager.activeFor('kw')?.hash, installed.hash);
    expect(manager.activeFor('tx'), isNull);
    expect(
      manager.getQualityOverride('酷我音乐'),
      containsAll(['96k', '128k', '320k', 'flac']),
    );
    expect(manager.getQualityOverride('QQ音乐'), isNull);
    expect(manager.installed().single.active, isTrue);
  });

  testWidgets('LX 权威失败后回退原生插件解析', (tester) async {
    final pluginManager = await PluginManager.create();
    final lxManager = await LxSourceManager.create();
    final runtime = MusicPluginRuntime();
    addTearDown(() async {
      await runtime.destroy();
      await _drainLx(lxManager);
      await lxManager.close();
    });
    await _drainLx(lxManager);
    final lxFile = _writeTempScript('lx_e2e', 'combo_e2e.js', _lxScriptSource);
    final lxInstalled = await lxManager.installLocal(lxFile);
    await lxManager.setActive(lxInstalled.hash);
    await lxManager.loadEnabled();

    final pluginFile = _writeTempScript(
      'lx_native',
      'kw_native.js',
      _lxNativePluginSource,
    );
    final installedPlugin = await pluginManager.installLocal(pluginFile);
    final loaded = await runtime.loadPlugin(
      id: installedPlugin.id,
      name: installedPlugin.name,
      version: installedPlugin.version,
      source: await pluginManager.readPluginSource(installedPlugin),
    );
    expect(loaded, isNotNull);
    final adapter = loaded!;
    expect(adapter.platform, '酷我音乐');

    final router = PluginRouter(pluginManager)
      ..lxResolver = LxResolver(lxManager)
      ..replaceAll([(installedPlugin, adapter)]);

    final item = MediaItem(
      id: 'kw-1',
      platform: '酷我音乐',
      title: '合成曲目',
      artist: '测试',
      qualities: {
        for (final quality in const ['96k', '128k', '320k', 'flac'])
          quality: const QualityInfo(),
      },
    );
    final tries = <String>[];
    final result = await router.resolveForPlaybackDetailed(
      item,
      '128k',
      onTrying: (quality, size, via) => tries.add('$quality|$via'),
    );
    expect(result, isNotNull);
    // 原生命中档：LX 探针拦截失败后回退 JS 插件取流，via 置空
    expect(result!.$2, '128k');
    expect(result.$3, isEmpty);
    expect(result.$1.mediaUrl, 'https://example.com/native-128k.mp3');
    expect(tries.first, '128k| · LX·合成LX脚本');
    expect(tries, contains('96k| · LX·合成LX脚本'));
    expect(tries.last, '128k|');
  });
}
