// ---------------------------------------------------------------------------
// 应用入口：初始化播放服务、本地存储与插件音源服务后挂载界面
// ---------------------------------------------------------------------------

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'data/app_repository.dart';
import 'data/player_session_store.dart';
import 'service/music_source_service.dart';
import 'service/playback_service.dart';
import 'ui/app.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // 播放服务先初始化：通知栏/锁屏媒体控制依赖 audio_service 宿主
  final playbackController = await PlaybackService.init();
  final prefs = await SharedPreferences.getInstance();
  final repository = AppRepository(prefs);
  final sourceService = await MusicSourceService.create();
  runApp(
    BakaMusicApp(
      repository: repository,
      sourceService: sourceService,
      playbackController: playbackController,
      sessionStore: PlayerSessionStore(prefs),
    ),
  );
}
