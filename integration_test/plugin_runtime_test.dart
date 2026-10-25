// 插件运行时回归测试（无网络依赖）：
// 1. 插件源码必须按模块脚本求值——顶层 let/const 若落在全局作用域，会与运行时
//    全局（如 var CryptoJs）冲突报 "SyntaxError: redeclaration"，插件静默失效；
// 2. 导出对象、platform/supportedQualities 信息读取、async 方法经
//    stripAsyncAwait + 同步 Promise 垫片调用
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:baka_music/plugin/music_plugin_runtime.dart';

/// 固定装置插件：刻意保留与运行时全局同名的顶层 let，防止回归。
const String _fixtureSource = r'''
"use strict";
const axios = require('axios');
let CryptoJs = null;
try { CryptoJs = require('crypto-js'); } catch (e) { CryptoJs = null; }

async function search(keyword, page, type) {
  return {
    isEnd: true,
    data: [
      { id: 'fx-1', title: keyword + '-1', artist: 'fixture' },
      { id: 'fx-2', title: keyword + '-2', artist: 'fixture' },
    ],
  };
}

async function getTopLists() {
  return [
    {
      title: 'fixture 榜',
      data: [{ id: 'fx-9', title: '榜单歌曲', artist: 'fixture' }],
    },
  ];
}

module.exports = {
  platform: 'fixture',
  version: '1.0.0',
  supportedQualities: ['128k', '320k'],
  search: search,
  getTopLists: getTopLists,
};
''';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('插件运行时：模块作用域求值与方法调用', (tester) async {
    final runtime = MusicPluginRuntime();
    final plugin = await runtime.loadPlugin(
      id: 'fixture',
      name: 'fixture',
      version: '1.0.0',
      source: _fixtureSource,
    );
    expect(plugin, isNotNull);
    expect(plugin!.platform, 'fixture');
    final qualities = plugin.supportedQualities.toList()..sort();
    expect(qualities, ['128k', '320k']);

    final page = await plugin.search('测试', 1);
    expect(page.data.length, 2);
    expect(page.data.first.title, '测试-1');
    expect(page.isEnd, isTrue);

    final groups = await plugin.topLists();
    expect(groups.length, 1);
    expect(groups.first.title, 'fixture 榜');
    expect(groups.first.items.length, 1);
    expect(groups.first.items.first.title, '榜单歌曲');

    await runtime.destroy();
  });
}
