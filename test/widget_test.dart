// ---------------------------------------------------------------------------
// 界面组件冒烟测试：不依赖插件的纯 UI 行为
// ---------------------------------------------------------------------------

import 'package:baka_music/data/app_repository.dart';
import 'package:baka_music/ui/home_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('加歌单对话框：无自建歌单时提供默认歌单选项', (tester) async {
    String? picked;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => ElevatedButton(
            onPressed: () async {
              picked = await showAddPlaylistDialog(context, const []);
            },
            child: const Text('打开'),
          ),
        ),
      ),
    );

    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();

    expect(find.text('添加到我的歌单'), findsOneWidget);
    expect(find.text(AppRepository.defaultSheet), findsOneWidget);

    await tester.tap(find.text(AppRepository.defaultSheet));
    await tester.pumpAndSettle();

    expect(picked, AppRepository.defaultSheet);
  });
}
