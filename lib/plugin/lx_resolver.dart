/// LX 取流解析：已配置时具权威性
library;

import 'dart:convert';
import 'dart:developer' as developer;

import '../data/lx_models.dart';
import '../models/media_models.dart';
import 'js_worker.dart' show PluginCanceledException;
import 'lx_host.dart' show LxPluginHost, LxProbeException;
import 'lx_source_manager.dart';

/// LX 解析结果：unsupported=无配置走原生；resolved=命中；failed=LX 权威失败
sealed class LxOutcome {
  const LxOutcome();
}

class LxUnsupported extends LxOutcome {
  const LxUnsupported();
}

class LxResolved extends LxOutcome {
  const LxResolved(this.media, this.quality, this.via);

  final MediaItem media;
  final String quality;
  final String via;
}

class LxFailed extends LxOutcome {
  const LxFailed();
}

class LxResolver {
  LxResolver(this._manager);

  final LxSourceManager _manager;

  /// 带实际命中音质的 LX 解析
  Future<LxOutcome> resolveDetailed(
    MediaItem item,
    String requested, {
    Set<String> exclude = const {},
    bool cascade = true,
    void Function(String quality, int? size, String via)? onTrying,
  }) async {
    final overrideList = _manager.getQualityOverride(item.platform);
    if (overrideList == null) return const LxUnsupported();
    final source = lxSourceForPlatform(item.platform);
    if (source == null) return const LxUnsupported();
    final plugin = _manager.activeFor(source);
    if (plugin == null) return const LxUnsupported();
    final override = overrideList.toSet();
    final via = ' · LX·${plugin.name}';
    final base = replaceLxMusicQualities(item, override, true);
    final rawCandidates = cascade
        ? lxQualityFallbacks(requested, override)
        : <String>[requested];
    final candidates = [
      for (final quality in rawCandidates)
        if (override.contains(quality) && !exclude.contains(quality)) quality,
    ];
    if (candidates.isEmpty) {
      developer.log(
        '[LX] 无可用候选 ${item.platform}:${item.id} requested=$requested',
        name: 'BakaLx',
        level: 500,
      );
      return const LxFailed();
    }
    for (final quality in candidates) {
      // 尝试即上报 LX 插件名，供播放栏在 loading 期即显示对应插件
      onTrying?.call(quality, base.qualities[quality]?.size, via);
      // 每档最多试两次，非探针错误直接换下一档
      for (var attempt = 0; attempt < 2; attempt++) {
        try {
          final url = await _manager.host.invoke(
            plugin.hash,
            source,
            quality,
            jsonEncode(toLxMusicInfo(source, base)),
          );
          if (url.toLowerCase().startsWith('http')) {
            developer.log(
              '[LX] 解析命中 ${item.platform}:${item.id} quality=$quality '
              'via ${plugin.name}',
              name: 'BakaLx',
              level: 500,
            );
            return LxResolved(
              base.copyWith(
                mediaUrl: url,
                mediaHeaders: LxPluginHost.mediaHeaders,
              ),
              quality,
              via,
            );
          }
          break;
        } on PluginCanceledException {
          rethrow;
        } on MediaResolveTimeoutException {
          rethrow;
        } catch (error) {
          developer.log(
            '[LX] $quality 尝试失败: $error',
            name: 'BakaLx',
            level: 900,
          );
          if (error is LxProbeException && attempt == 0) continue;
          break;
        }
      }
    }
    developer.log(
      '[LX] 解析失败 ${item.platform}:${item.id} tried=$candidates',
      name: 'BakaLx',
      level: 500,
    );
    return const LxFailed();
  }
}
