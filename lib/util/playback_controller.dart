import 'dart:async';

import 'package:audio_service/audio_service.dart' as audio;
import 'package:just_audio/just_audio.dart';

import '../models/media_models.dart';

/// 播放状态快照：UI 轮询同步显示，不阻塞
class PlaybackSnapshot {
  const PlaybackSnapshot({
    this.connected = false,
    this.isPlaying = false,
    this.positionMs = 0,
    this.durationMs = 0,
    this.itemIndex = 0,
    this.itemCount = 0,
    this.ended = false,
    this.buffering = false,
  });

  final bool connected;
  final bool isPlaying;
  final int positionMs;
  final int durationMs;
  final int itemIndex;
  final int itemCount;

  /// 是否播放完毕，用于自动下一首
  final bool ended;

  /// 是否正在缓冲，用于加载动画显示
  final bool buffering;
}

/// 播放控制器：持有播放器并对外提供 UI 控制边界，
/// 同时作为后台播放服务（通知栏/锁屏控制）的处理器
/// just_audio 读取缓存字段，snapshot 不阻塞任意线程
class PlaybackController extends audio.BaseAudioHandler with audio.SeekHandler {
  PlaybackController() {
    _subscriptions.addAll([
      _player.playbackEventStream.listen(
        (_) => _broadcast(),
        onError: (Object e, StackTrace st) => _notifyError('播放器错误: $e'),
      ),
      _player.playerStateStream.listen(_onPlayerState),
      _player.errorStream.listen(
        (e) => _notifyError('播放器错误 ${e.code}: ${e.message ?? '未知错误'}'),
      ),
      _player.currentIndexStream.listen(_onIndexChanged),
      _player.durationStream.listen(
        (d) => _durationMs = d?.inMilliseconds ?? 0,
      ),
      _player.positionStream.listen((p) => _positionMs = p.inMilliseconds),
    ]);
    _connected = true;
    _broadcast();
  }

  final AudioPlayer _player = AudioPlayer();
  final List<StreamSubscription<Object?>> _subscriptions = [];
  final List<void Function(String)> _errorListeners = [];
  final List<void Function()> _audibleListeners = [];
  final List<void Function()> _endedListeners = [];

  List<MediaItem> _queue = const [];
  int _itemIndex = 0;
  int _itemCount = 0;
  int _positionMs = 0;
  int _durationMs = 0;
  bool _connected = false;
  bool _released = false;
  bool _ended = false;
  bool _buffering = false;
  bool _lastCompleted = false;
  bool _lastReadyPlaying = false;

  Future<void> _ops = Future.value();

  /// 串行执行会改动播放源的操作，避免清空与新加载互相打断
  Future<T> _serialize<T>(Future<T> Function() action) {
    final result = _ops.then((_) => action());
    _ops = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }

  /// 订阅播放器异步错误，返回取消订阅函数
  void Function() addErrorListener(void Function(String) listener) {
    _errorListeners.add(listener);
    return () => _errorListeners.remove(listener);
  }

  /// 订阅进入播放状态事件，返回取消订阅函数
  void Function() addAudibleListener(void Function() listener) {
    _audibleListeners.add(listener);
    return () => _audibleListeners.remove(listener);
  }

  /// 订阅播放完毕事件，返回取消订阅函数
  void Function() addEndedListener(void Function() listener) {
    _endedListeners.add(listener);
    return () => _endedListeners.remove(listener);
  }

  /// 播放单曲：整体替换当前播放列表
  Future<void> playItem(MediaItem item) => _serialize(() => _playItem(item));

  Future<void> _playItem(MediaItem item) async {
    final uri = item.mediaUrl;
    if (uri == null || uri.isEmpty) {
      _notifyError('播放失败：当前歌曲没有可用的媒体地址');
      return;
    }
    try {
      _queue = [item];
      _itemIndex = 0;
      _itemCount = 1;
      _ended = false;
      queue.add([_toAudioItem(item)]);
      await _player.setAudioSources([_toSource(item)], initialIndex: 0);
      _startPlayback();
    } on PlayerInterruptedException {
      // 被更新的播放/清空操作打断，属正常切换
    } catch (e) {
      _notifyError('播放失败：$e');
    }
  }

  Future<void> playQueue(List<MediaItem> items, [int startIndex = 0]) =>
      _serialize(() => _playQueue(items, startIndex));

  Future<void> _playQueue(List<MediaItem> items, int startIndex) async {
    final valid = <MediaItem>[];
    for (final item in items) {
      final uri = item.mediaUrl;
      if (uri == null || uri.isEmpty) {
        _notifyError('队列歌曲没有可用的媒体地址');
        return;
      }
      valid.add(item);
    }
    if (valid.isEmpty) {
      await _clear();
      return;
    }
    final index = startIndex.clamp(0, valid.length - 1);
    try {
      _queue = valid;
      _itemIndex = index;
      _itemCount = valid.length;
      _ended = false;
      queue.add(valid.map(_toAudioItem).toList());
      await _player.setAudioSources(
        valid.map(_toSource).toList(),
        initialIndex: index,
      );
      _startPlayback();
    } on PlayerInterruptedException {
      // 被更新的播放/清空操作打断，属正常切换
    } catch (e) {
      _notifyError('播放失败：$e');
    }
  }

  /// 起播不等待 play()：just_audio 的 play Future 直到暂停/播放结束才完成，
  /// 若在串行队列里 await 会阻塞整首歌，导致后续切歌/清空永远排队
  void _startPlayback() {
    unawaited(_player.play().catchError((Object _) {}));
  }

  @override
  Future<void> stop() => _serialize(() async {
    await _player.stop();
    await super.stop();
  });

  /// 切换曲目时调用：停止播放并清空队列状态，避免残留失效地址
  Future<void> clear() => _serialize(_clear);

  Future<void> _clear() async {
    await _player.stop();
    _queue = const [];
    _itemIndex = 0;
    _itemCount = 0;
    _ended = false;
    queue.add(const []);
    mediaItem.add(null);
    try {
      await _player.setAudioSources(const []);
    } catch (_) {
      // 列表已停止，清空失败不影响后续整体替换
    }
  }

  Future<void> toggle() async {
    if (_player.playing) {
      await _player.pause();
    } else {
      await _player.play();
    }
  }

  Future<void> next() async {
    try {
      await _player.seekToNext();
    } catch (_) {
      // 已在队尾，忽略
    }
  }

  Future<void> previous() async {
    try {
      await _player.seekToPrevious();
    } catch (_) {
      // 已在队首，忽略
    }
  }

  Future<void> seekTo(int positionMs) async {
    try {
      await _player.seek(
        Duration(milliseconds: positionMs < 0 ? 0 : positionMs),
      );
    } catch (_) {
      // 播放器未就绪时忽略
    }
  }

  /// 等待播放控制器连接建立（同 isolate 内即时可用）
  Future<bool> awaitConnected({int timeoutMs = 6000}) async => !_released;

  /// 供轮询调用：返回最近状态缓存，不阻塞
  PlaybackSnapshot snapshot() => PlaybackSnapshot(
    connected: _connected,
    isPlaying: _player.playing,
    positionMs: _positionMs < 0 ? 0 : _positionMs,
    durationMs: _durationMs > 0 ? _durationMs : 0,
    itemIndex: _itemIndex < 0 ? 0 : _itemIndex,
    itemCount: _itemCount,
    ended: _ended,
    buffering: _buffering,
  );

  Future<void> release() => _serialize(_release);

  Future<void> _release() async {
    if (_released) return;
    _released = true;
    for (final s in _subscriptions) {
      await s.cancel();
    }
    _subscriptions.clear();
    await _player.dispose();
  }

  @override
  Future<void> play() => _player.play();

  @override
  Future<void> pause() => _player.pause();

  @override
  Future<void> seek(Duration position) => seekTo(position.inMilliseconds);

  @override
  Future<void> skipToNext() => next();

  @override
  Future<void> skipToPrevious() => previous();

  /// 播放请求头随音频源一起交给播放器底层；
  /// 重定向逐跳重发头由平台播放栈决定（Android Media3 默认重发）
  AudioSource _toSource(MediaItem item) => AudioSource.uri(
    Uri.parse(item.mediaUrl!),
    tag: item,
    headers: item.mediaHeaders.isEmpty
        ? null
        : Map<String, String>.of(item.mediaHeaders),
  );

  audio.MediaItem _toAudioItem(MediaItem item) => audio.MediaItem(
    id: item.key,
    title: item.title,
    artist: item.artist,
    album: item.album.isEmpty ? null : item.album,
    duration: item.durationMs > 0
        ? Duration(milliseconds: item.durationMs)
        : null,
    artUri: item.artwork == null ? null : Uri.tryParse(item.artwork!),
  );

  void _onPlayerState(PlayerState state) {
    _buffering =
        state.processingState == ProcessingState.buffering ||
        state.processingState == ProcessingState.loading;
    final completed = state.processingState == ProcessingState.completed;
    if (completed && !_lastCompleted) {
      _ended = true;
      for (final l in List.of(_endedListeners)) {
        try {
          l();
        } catch (_) {
          // 单个监听器异常不影响其它监听器
        }
      }
    }
    _lastCompleted = completed;
    final readyPlaying =
        state.playing && state.processingState == ProcessingState.ready;
    if (readyPlaying && !_lastReadyPlaying) {
      for (final l in List.of(_audibleListeners)) {
        try {
          l();
        } catch (_) {
          // 单个监听器异常不影响其它监听器
        }
      }
    }
    _lastReadyPlaying = readyPlaying;
  }

  void _onIndexChanged(int? index) {
    if (index == null) return;
    _itemIndex = index;
    if (index < _queue.length) {
      mediaItem.add(_toAudioItem(_queue[index]));
    }
  }

  void _broadcast() {
    playbackState.add(
      audio.PlaybackState(
        controls: [
          audio.MediaControl.skipToPrevious,
          if (_player.playing)
            audio.MediaControl.pause
          else
            audio.MediaControl.play,
          audio.MediaControl.skipToNext,
        ],
        androidCompactActionIndices: const [0, 1, 2],
        processingState: _toProcessingState(_player.processingState),
        playing: _player.playing,
        updatePosition: _player.position,
        bufferedPosition: _player.bufferedPosition,
        speed: _player.speed,
        queueIndex: _player.currentIndex,
      ),
    );
  }

  void _notifyError(String message) {
    for (final l in List.of(_errorListeners)) {
      try {
        l(message);
      } catch (_) {
        // 单个监听器异常不影响其它监听器
      }
    }
  }

  audio.AudioProcessingState _toProcessingState(ProcessingState state) =>
      switch (state) {
        ProcessingState.idle => audio.AudioProcessingState.idle,
        ProcessingState.loading => audio.AudioProcessingState.loading,
        ProcessingState.buffering => audio.AudioProcessingState.buffering,
        ProcessingState.ready => audio.AudioProcessingState.ready,
        ProcessingState.completed => audio.AudioProcessingState.completed,
      };
}
