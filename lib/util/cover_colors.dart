/// 封面取色：从封面图提取悬浮底座主色与播放器渐变色，缩放小图后按区域平均，
/// 两组结果均带 LRU 内存缓存（上限 60），避免重建时回落默认色闪烁
library;

import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/widgets.dart';

import 'artwork_headers.dart';

/// 简单 LRU：命中或写入时移动到队尾，超出容量淘汰队首
class _Lru<K, V> {
  _Lru(this.maxSize);

  final int maxSize;
  final LinkedHashMap<K, V> _map = LinkedHashMap<K, V>();

  V? get(K key) {
    if (!_map.containsKey(key)) return null;
    final value = _map.remove(key);
    _map[key] = value as V;
    return value;
  }

  void put(K key, V value) {
    _map.remove(key);
    _map[key] = value;
    while (_map.length > maxSize) {
      _map.remove(_map.keys.first);
    }
  }

  void clear() => _map.clear();
}

/// 封面取色工具：主色用于播放底座，渐变色用于播放器/歌词背景
class CoverColors {
  CoverColors._();

  static const int _maxCache = 60;

  static final _Lru<String, Color> _dominantCache = _Lru<String, Color>(
    _maxCache,
  );
  static final _Lru<String, (Color, Color)> _gradientCache =
      _Lru<String, (Color, Color)>(_maxCache);

  /// 最近一次成功解出的渐变：切换封面时从旧色直切新色，不经过默认色
  static (Color, Color)? lastResolvedGradient;

  /// 同步读取主色缓存（未命中返回 null）
  static Color? cachedDominant(String? artwork) {
    if (artwork == null || artwork.isEmpty) return null;
    return _dominantCache.get(artwork);
  }

  /// 同步读取渐变缓存（未命中返回 null）
  static (Color, Color)? cachedGradient(String? artwork) {
    if (artwork == null || artwork.isEmpty) return null;
    return _gradientCache.get(artwork);
  }

  /// 播放底座主色：可见像素平均色，失败或无有效像素返回 null
  static Future<Color?> dominant(String? artwork) async {
    if (artwork == null || artwork.isEmpty) return null;
    final cached = _dominantCache.get(artwork);
    if (cached != null) return cached;
    final pixels = await _loadPixels(artwork);
    if (pixels == null) return null;
    var r = 0, g = 0, b = 0;
    var count = 0;
    for (var i = 0; i + 3 < pixels.length; i += 4) {
      if (pixels[i + 3] < 128) continue;
      r += pixels[i];
      g += pixels[i + 1];
      b += pixels[i + 2];
      count++;
    }
    if (count == 0) return null;
    final color = Color.fromARGB(255, r ~/ count, g ~/ count, b ~/ count);
    _dominantCache.put(artwork, color);
    return color;
  }

  /// 封面渐变：左上半区与右下半区平均色；两色过近时压暗终点
  static Future<(Color, Color)?> gradient(String? artwork) async {
    if (artwork == null || artwork.isEmpty) return null;
    final cached = _gradientCache.get(artwork);
    if (cached != null) return cached;
    final pixels = await _loadPixels(artwork);
    if (pixels == null) return null;
    final result = _gradientFromPixels(pixels);
    if (result != null) {
      _gradientCache.put(artwork, result);
      lastResolvedGradient = result;
    }
    return result;
  }

  /// 仅清理内存缓存（供测试或内存压力场景调用）
  static void clearCache() {
    _dominantCache.clear();
    _gradientCache.clear();
    lastResolvedGradient = null;
  }

  /// 加载封面并缩放到 48x48 的 RGBA 像素（宽高等分为 24 格，每格 2x2）
  static Future<Uint8List?> _loadPixels(String artwork) async {
    if (!artwork.toLowerCase().startsWith('http')) return null;
    try {
      final image = await _decodeImage(artwork);
      if (image == null) return null;
      final scaled = await _scale(image, 48, 48);
      image.dispose();
      if (scaled == null) return null;
      final data = await scaled.toByteData(format: ui.ImageByteFormat.rawRgba);
      scaled.dispose();
      if (data == null) return null;
      return data.buffer.asUint8List();
    } catch (_) {
      return null;
    }
  }

  static Future<ui.Image?> _decodeImage(String artwork) {
    final completer = Completer<ui.Image?>();
    final provider = CachedNetworkImageProvider(
      artwork,
      headers: kArtworkHeaders,
    );
    final stream = provider.resolve(ImageConfiguration.empty);
    late ImageStreamListener listener;
    listener = ImageStreamListener(
      (info, _) {
        stream.removeListener(listener);
        completer.complete(info.image);
      },
      onError: (_, _) {
        stream.removeListener(listener);
        completer.complete(null);
      },
    );
    stream.addListener(listener);
    return completer.future;
  }

  static Future<ui.Image?> _scale(ui.Image src, int width, int height) async {
    try {
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      canvas.drawImageRect(
        src,
        Rect.fromLTWH(0, 0, src.width.toDouble(), src.height.toDouble()),
        Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
        Paint()..filterQuality = FilterQuality.medium,
      );
      return await recorder.endRecording().toImage(width, height);
    } catch (_) {
      return null;
    }
  }

  static (Color, Color)? _gradientFromPixels(Uint8List pixels) {
    // 48x48 像素按 2x2 归并为 24x24 网格，x+y<24 为左上半区
    var r1 = 0, g1 = 0, b1 = 0, c1 = 0;
    var r2 = 0, g2 = 0, b2 = 0, c2 = 0;
    for (var y = 0; y < 48; y++) {
      for (var x = 0; x < 48; x++) {
        final i = (y * 48 + x) * 4;
        if (pixels[i + 3] < 128) continue;
        final cell = (x >> 1) + (y >> 1);
        if (cell < 24) {
          r1 += pixels[i];
          g1 += pixels[i + 1];
          b1 += pixels[i + 2];
          c1++;
        } else {
          r2 += pixels[i];
          g2 += pixels[i + 1];
          b2 += pixels[i + 2];
          c2++;
        }
      }
    }
    if (c1 == 0 || c2 == 0) return null;
    var start = Color.fromARGB(255, r1 ~/ c1, g1 ~/ c1, b1 ~/ c1);
    var end = Color.fromARGB(255, r2 ~/ c2, g2 ~/ c2, b2 ~/ c2);
    final dr = (start.r - end.r) * 255.0;
    final dg = (start.g - end.g) * 255.0;
    final db = (start.b - end.b) * 255.0;
    if (dr * dr + dg * dg + db * db < 40.0 * 40.0) {
      end = Color.from(
        alpha: 1,
        red: (end.r * 0.72).clamp(0.0, 1.0),
        green: (end.g * 0.72).clamp(0.0, 1.0),
        blue: (end.b * 0.72).clamp(0.0, 1.0),
      );
    }
    start = Color.from(alpha: 1, red: start.r, green: start.g, blue: start.b);
    return (start, end);
  }
}
