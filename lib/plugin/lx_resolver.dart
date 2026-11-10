/// LX 取流解析：已配置时优先，超时/失败快速回退原生插件
library;

import 'dart:async';
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

/// 单档 LX 取流结果：timeout 用于短期熔断，skipped 表示无需尝试
class LxQualityResult {
  const LxQualityResult({
    this.resolved,
    this.timedOut = false,
    this.skipped = false,
  });

  final LxResolved? resolved;
  final bool timedOut;
  final bool skipped;
}

/// LX 连续超时后的短期熔断状态
class _LxHealth {
  int consecutiveTimeouts = 0;
  DateTime? cooldownUntil;
}

class LxResolver {
  LxResolver(this._manager);

  final LxSourceManager _manager;

  /// 按 source+脚本 hash 记录健康度，避免一个坏脚本拖慢其它平台
  final Map<String, _LxHealth> _health = {};

  static const int _timeoutsBeforeCooldown = 2;
  static const Duration _cooldown = Duration(minutes: 1);

  /// 当前平台是否由 LX 接管音质集合
  List<String>? qualityOverride(String platform) =>
      _manager.getQualityOverride(platform);

  bool supportsPlatform(String platform) {
    if (_manager.getQualityOverride(platform) == null) return false;
    final source = lxSourceForPlatform(platform);
    return source != null && _manager.activeFor(source) != null;
  }

  /// 播放栏展示用的取流来源标注
  String? viaLabel(String platform) {
    final source = lxSourceForPlatform(platform);
    if (source == null) return null;
    final plugin = _manager.activeFor(source);
    return plugin == null ? null : ' · LX·${plugin.name}';
  }

  /// 中止在途 LX 调用（原生命中时释放脚本 worker）
  void cancelPending() {
    try {
      _manager.host.cancelPending();
    } catch (_) {}
  }

  /// 单档取流：命中返回地址；超时/失败返回空结果，不向调用方抛超时。
  /// [timeout] 覆盖脚本执行与地址探针，由播放层按候选档位分配。
  Future<LxQualityResult> resolveQuality(
    MediaItem item,
    String quality, {
    Duration timeout = const Duration(milliseconds: lxResolveAttemptTimeoutMs),
    Duration probeTimeout = const Duration(
      milliseconds: lxResolveProbeTimeoutMs,
    ),
  }) async {
    final overrideList = _manager.getQualityOverride(item.platform);
    if (overrideList == null) return const LxQualityResult(skipped: true);
    final source = lxSourceForPlatform(item.platform);
    if (source == null) return const LxQualityResult(skipped: true);
    final plugin = _manager.activeFor(source);
    if (plugin == null) return const LxQualityResult(skipped: true);
    final override = overrideList.toSet();
    if (!override.contains(quality)) {
      return const LxQualityResult(skipped: true);
    }
    final healthKey = '$source:${plugin.hash}';
    if (_isCoolingDown(healthKey)) {
      return const LxQualityResult(skipped: true);
    }

    final base = replaceLxMusicQualities(item, override, true);
    final via = ' · LX·${plugin.name}';
    try {
      final url = await _manager.host.invoke(
        plugin.hash,
        source,
        quality,
        jsonEncode(toLxMusicInfo(source, base)),
        timeout: timeout,
        probeTimeout: probeTimeout,
      );
      if (!url.toLowerCase().startsWith('http')) {
        return const LxQualityResult();
      }
      _health.remove(healthKey);
      developer.log(
        '[LX] 解析命中 ${item.platform}:${item.id} quality=$quality '
        'via ${plugin.name}',
        name: 'BakaLx',
        level: 500,
      );
      return LxQualityResult(
        resolved: LxResolved(
          base.copyWith(mediaUrl: url, mediaHeaders: LxPluginHost.mediaHeaders),
          quality,
          via,
        ),
      );
    } on PluginCanceledException {
      // 被另一路候选抢占，不计入失败
      rethrow;
    } on MediaResolveTimeoutException catch (error) {
      _reportTimeout(healthKey);
      developer.log(
        '[LX] $quality 超时，回退原生: $error',
        name: 'BakaLx',
        level: 900,
      );
      return const LxQualityResult(timedOut: true);
    } on LxProbeException catch (error) {
      developer.log('[LX] $quality 地址探针失败: $error', name: 'BakaLx', level: 900);
      return const LxQualityResult();
    } catch (error) {
      developer.log('[LX] $quality 尝试失败: $error', name: 'BakaLx', level: 900);
      return const LxQualityResult();
    }
  }

  /// 带实际命中音质的 LX 解析（保留给非播放路径使用）
  Future<LxOutcome> resolveDetailed(
    MediaItem item,
    String requested, {
    Set<String> exclude = const {},
    bool cascade = true,
    void Function(String quality, int? size, String via)? onTrying,
    Duration budget = const Duration(milliseconds: playResolveBudgetMs),
    Duration attemptTimeout = const Duration(
      milliseconds: lxResolveAttemptTimeoutMs,
    ),
  }) async {
    final overrideList = _manager.getQualityOverride(item.platform);
    if (overrideList == null) return const LxUnsupported();
    final source = lxSourceForPlatform(item.platform);
    if (source == null) return const LxUnsupported();
    final plugin = _manager.activeFor(source);
    if (plugin == null) return const LxUnsupported();
    final override = overrideList.toSet();
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

    final deadline = DateTime.now().add(budget);
    final via = ' · LX·${plugin.name}';
    for (final quality in candidates) {
      final remaining = deadline.difference(DateTime.now());
      if (remaining <= Duration.zero) break;
      onTrying?.call(quality, base.qualities[quality]?.size, via);
      final limit = remaining < attemptTimeout ? remaining : attemptTimeout;
      final result = await resolveQuality(
        base,
        quality,
        timeout: limit,
        probeTimeout: const Duration(milliseconds: lxResolveProbeTimeoutMs),
      );
      final resolved = result.resolved;
      if (resolved != null) return resolved;
    }
    developer.log(
      '[LX] 解析失败 ${item.platform}:${item.id} tried=$candidates',
      name: 'BakaLx',
      level: 500,
    );
    return const LxFailed();
  }

  bool _isCoolingDown(String key) {
    final until = _health[key]?.cooldownUntil;
    if (until == null) return false;
    if (DateTime.now().isBefore(until)) return true;
    _health.remove(key);
    return false;
  }

  void _reportTimeout(String key) {
    final health = _health.putIfAbsent(key, () => _LxHealth());
    health.consecutiveTimeouts++;
    if (health.consecutiveTimeouts >= _timeoutsBeforeCooldown) {
      health.consecutiveTimeouts = 0;
      health.cooldownUntil = DateTime.now().add(_cooldown);
      developer.log(
        '[LX] 连续超时，暂停 LX 取流 1 分钟: $key',
        name: 'BakaLx',
        level: 900,
      );
    }
  }
}
