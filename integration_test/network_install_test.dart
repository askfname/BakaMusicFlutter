// 真实网络回归：订阅更新、单链接安装与 LX 网络安装
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:baka_music/plugin/plugin_manager.dart';
import 'package:baka_music/service/music_source_service.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('订阅更新：真实清单链接', (tester) async {
    final manager = await PluginManager.create();
    final saved = await manager.addSubscription(
      '回归订阅',
      'https://music.cwo.cc.cd/api/subscription.json?source=cihedai.json',
    );
    final result = await manager.updateSubscription(saved);
    expect(result.installed, greaterThan(0));
  });

  testWidgets('网络安装：真实插件链接', (tester) async {
    final manager = await PluginManager.create();
    final result = await manager.installNetwork(
      'https://music.cwo.cc.cd/plugins/bilibili.js',
    );
    expect(result.installed, greaterThan(0));
  });

  testWidgets('LX 网络安装：真实脚本链接', (tester) async {
    final service = await MusicSourceService.create();
    final script = await service.installLxNetwork(
      'https://raw.githubusercontent.com/pdone/lx-music-source/main/qdy/latest.js',
    );
    expect(script.name, isNotEmpty);
  });
}
