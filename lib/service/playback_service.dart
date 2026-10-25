import 'package:audio_service/audio_service.dart';

import '../util/playback_controller.dart';

/// 后台播放服务入口：初始化通知栏/锁屏媒体控制，
/// 同一 isolate 内返回可直接使用的播放控制器
class PlaybackService {
  PlaybackService._();

  static PlaybackController? _controller;

  static PlaybackController? get controller => _controller;

  static Future<PlaybackController> init() async {
    final controller = PlaybackController();
    _controller = controller;
    await AudioService.init(
      builder: () => controller,
      config: const AudioServiceConfig(
        androidNotificationChannelId: 'com.playlab.bakamusic.playback',
        androidNotificationChannelName: '播放',
        androidNotificationOngoing: true,
      ),
    );
    return controller;
  }
}
