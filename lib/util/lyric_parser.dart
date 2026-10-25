import '../models/media_models.dart';
import 'lyric_decrypt.dart';

const int _maxMs = 0x7FFFFFFFFFFFFFFF;

/// 逐字歌词片段
class LyricWord {
  const LyricWord({
    required this.text,
    required this.startMs,
    required this.endMs,
  });

  final String text;
  final int startMs;
  final int endMs;

  LyricWord copyWith({String? text, int? startMs, int? endMs}) => LyricWord(
    text: text ?? this.text,
    startMs: startMs ?? this.startMs,
    endMs: endMs ?? this.endMs,
  );
}

/// 歌词行
class LyricLine {
  const LyricLine({
    required this.timeMs,
    required this.text,
    this.endMs = _maxMs,
    this.words = const [],
  });

  final int timeMs;
  final String text;
  final int endMs;
  final List<LyricWord> words;

  LyricLine copyWith({
    int? timeMs,
    String? text,
    int? endMs,
    List<LyricWord>? words,
  }) => LyricLine(
    timeMs: timeMs ?? this.timeMs,
    text: text ?? this.text,
    endMs: endMs ?? this.endMs,
    words: words ?? this.words,
  );
}

abstract final class LyricParser {
  /// LRC 时间戳，一行内可有多个
  static final RegExp _timestamp = RegExp(
    r'\[(\d{1,3}):(\d{2})(?:[.:](\d{1,3}))?\]',
  );

  /// QRC 行：[startMs,durationMs]正文(逐字时间)
  static final RegExp _qrcLine = RegExp(r'^\[(\d+),(\d+)\](.*)$');

  /// QRC/YRC 逐字时间，显示时移除
  static final RegExp _wordTime = RegExp(r'\(\d+,\d+(?:,\d+)?\)');

  /// 尖括号逐字时间，显示时移除
  static final RegExp _angleWordTime = RegExp(r'<\d[^>]*>');

  /// 数字键字符映射 {"0":"我","1":"的"}，按数字键排序还原文本
  static final RegExp _charMapKey = RegExp(r'"(\d+)"\s*:\s*"((?:\\"|[^"])*)"');

  /// 元信息行 [ti:..]/[ar:..] 等，直接跳过
  static final RegExp _metaTag = RegExp(r'^\[[a-zA-Z]+:.*$');

  /// YRC JSON 行 {"t":123,"c":[{"tx":"字"}]}
  static final RegExp _yrcTime = RegExp(r'"t"\s*:\s*(\d+)');
  static final RegExp _yrcWord = RegExp(r'"tx"\s*:\s*"((?:\\"|[^"])*)"');

  /// QRC 逐字：文字(绝对startMs,时值[,预留])，文字在括号前
  static final RegExp _qrcWord = RegExp(
    r'([^()\[\]]+?)\((\d+),(\d+)(?:,\d+)?\)',
  );

  /// ESLRC/A2 尖括号逐字：<mm:ss.xxx>文字
  static final RegExp _angleStamp = RegExp(
    r'<(\d{1,3}):(\d{2})(?:[.:](\d{1,3}))?>',
  );

  /// 相对偏移逐字（咪咕 lxlyric 等）：<行内偏移ms,时值ms>文字，相对行首
  static final RegExp _relativeAngleWord = RegExp(r'<(\d+),(\d+)>');

  static int _angleToMs(Match m) {
    final minutes = int.tryParse(m.group(1) ?? '') ?? 0;
    final seconds = int.tryParse(m.group(2) ?? '') ?? 0;
    final fraction =
        int.tryParse((m.group(3) ?? '').padRight(3, '0').substring(0, 3)) ?? 0;
    return minutes * 60 * 1000 + seconds * 1000 + fraction;
  }

  /// QRC 行内逐字切分，失败返回空（调用方回退为整行）
  static List<LyricWord> _parseQrcWords(String body, int lineEndMs) {
    final matches = _qrcWord
        .allMatches(body)
        .where((m) => (m.group(1) ?? '').isNotEmpty);
    final words = <LyricWord>[];
    for (final m in matches) {
      final text = m.group(1)!;
      if (text.isEmpty) continue;
      final start = int.tryParse(m.group(2) ?? '');
      if (start == null) continue;
      final dur = int.tryParse(m.group(3) ?? '') ?? 0;
      final s = start < 0 ? 0 : start;
      final e = start + dur;
      words.add(
        LyricWord(text: text, startMs: s, endMs: e < start ? start : e),
      );
    }
    if (words.isEmpty) return const [];
    // 行尾对齐：末字时值缺失/为 0 时延长到行尾，避免卡拉 OK 提前停住
    return List.generate(words.length, (i) {
      final w = words[i];
      if (i == words.length - 1 && w.endMs <= w.startMs) {
        final end = lineEndMs > w.startMs + 320 ? lineEndMs : w.startMs + 320;
        return w.copyWith(endMs: end);
      }
      return w;
    });
  }

  /// ESLRC/A2 行内尖括号逐字切分，失败返回空
  static List<LyricWord> _parseAngleWords(String body, int lineEndMs) {
    final tags = _angleStamp.allMatches(body).toList();
    if (tags.isEmpty) return const [];
    final words = <LyricWord>[];
    for (var i = 0; i < tags.length; i++) {
      final tag = tags[i];
      final start = _angleToMs(tag);
      final textStart = tag.end.clamp(0, body.length);
      final rawEnd = i + 1 < tags.length ? tags[i + 1].start : body.length;
      final textEnd = rawEnd.clamp(0, body.length);
      final text = textStart <= textEnd
          ? body.substring(textStart, textEnd)
          : '';
      // 末尾悬空时间戳（如酷我行尾补的结束戳）无后随文字则作为上一字结尾
      if (text.isEmpty) {
        if (words.isNotEmpty) {
          final last = words.removeLast();
          words.add(last.copyWith(endMs: start));
        }
        continue;
      }
      final end = i + 1 < tags.length ? _angleToMs(tags[i + 1]) : lineEndMs;
      final e = end > start + 120 ? end : start + 120;
      words.add(LyricWord(text: text, startMs: start, endMs: e));
    }
    return words;
  }

  /// 相对偏移逐字切分，失败返回空
  static List<LyricWord> _parseRelativeAngleWords(
    String body,
    int lineStartMs,
    int lineEndMs,
  ) {
    final tags = _relativeAngleWord.allMatches(body).toList();
    if (tags.isEmpty) return const [];
    final words = <LyricWord>[];
    for (var i = 0; i < tags.length; i++) {
      final tag = tags[i];
      final offset = int.tryParse(tag.group(1) ?? '');
      if (offset == null) continue;
      final start = lineStartMs + offset;
      final dur = int.tryParse(tag.group(2) ?? '') ?? 0;
      final textStart = tag.end.clamp(0, body.length);
      final rawEnd = i + 1 < tags.length ? tags[i + 1].start : body.length;
      final textEnd = rawEnd.clamp(0, body.length);
      final text = textStart <= textEnd
          ? body.substring(textStart, textEnd)
          : '';
      if (text.isEmpty) continue;
      final rawWordEnd = start + dur;
      final end = rawWordEnd < lineEndMs ? rawWordEnd : lineEndMs;
      final s = start > lineStartMs ? start : lineStartMs;
      final e = end > start + 120 ? end : start + 120;
      words.add(LyricWord(text: text, startMs: s, endMs: e));
    }
    return words;
  }

  /// 去掉行内全部时间戳/逐字戳，返回干净正文
  static String _cleanText(String raw) {
    var text = raw.replaceAll(_timestamp, '');
    text = text.replaceAll(_angleWordTime, '');
    text = text.replaceAll(_wordTime, '');
    text = text.trim();
    // [ts]{"0":"我","1":"的"} 或裸 {"0":..}：按数字键排序拼接取值
    if (text.startsWith('{') && text.endsWith('}')) {
      final chars = _charMapKey.allMatches(text).toList();
      if (chars.isNotEmpty && text.contains('"0"')) {
        chars.sort((a, b) {
          final ka = int.tryParse(a.group(1) ?? '') ?? _maxMs;
          final kb = int.tryParse(b.group(1) ?? '') ?? _maxMs;
          return ka.compareTo(kb);
        });
        return chars
            .map(
              (m) => (m.group(2) ?? '')
                  .replaceAll('\\"', '"')
                  .replaceAll('\\\\', '\\'),
            )
            .join()
            .trim();
      }
    }
    return text;
  }

  static List<LyricLine> parse(LyricSource? source) {
    final escaped = (source?.rawLrc ?? '')
        .replaceAll('\r', '')
        .replaceAll('\\n', '\n')
        .replaceAll('\\r', '\n');
    if (escaped.trim().isEmpty) return const [];
    // QQ 等来源的 QRC 加密串/QRC XML 先还原为富 QRC 再解析
    final raw =
        LyricDecrypt.autoDecryptLyric(escaped)?.replaceAll('\r', '') ?? '';
    if (raw.trim().isEmpty) return const [];

    final parsed = <LyricLine>[];
    final plainFallback = <String>[];

    for (final line in raw.split('\n')) {
      final trimmed = line.trim();
      if (trimmed.isEmpty || _metaTag.hasMatch(trimmed)) continue;

      // 1) 标准 LRC（含一行多时间戳）：行内若带逐字戳则一并保留
      final stamps = _timestamp.allMatches(trimmed).toList();
      if (stamps.isNotEmpty) {
        final lastStamp = stamps.last;
        final bodyStart = (lastStamp.end).clamp(0, trimmed.length);
        final body = trimmed.substring(bodyStart);
        final lineStart0 = _stampToMs(lastStamp);
        final angleWords = body.contains('<') && _angleStamp.hasMatch(body)
            ? _parseAngleWords(body, _maxMs)
            : const <LyricWord>[];
        final qrcWords = angleWords.isEmpty && body.contains('(')
            ? _parseQrcWords(body, _maxMs)
            : const <LyricWord>[];
        final relWords =
            angleWords.isEmpty && qrcWords.isEmpty && body.contains('<')
            ? _parseRelativeAngleWords(body, lineStart0, _maxMs)
            : const <LyricWord>[];
        final words = angleWords.isNotEmpty
            ? angleWords
            : (qrcWords.isNotEmpty ? qrcWords : relWords);
        final String text;
        if (words.isNotEmpty) {
          final joined = words.map((w) => w.text).join().trim();
          text = joined.isNotEmpty ? joined : _cleanText(trimmed);
        } else {
          text = _cleanText(trimmed);
        }
        for (final m in stamps) {
          final start = _stampToMs(m);
          // 尖括号时间为绝对时间可直接用；QRC 式 (ms,ms) 已是绝对时间，直接用
          final shifted = words.isNotEmpty && words.first.startMs < start - 5000
              ? words
                    .map(
                      (w) => w.copyWith(
                        startMs: w.startMs + (start - words.first.startMs),
                        endMs: w.endMs == _maxMs
                            ? _maxMs
                            : w.endMs + (start - words.first.startMs),
                      ),
                    )
                    .toList()
              : words;
          parsed.add(LyricLine(timeMs: start, text: text, words: shifted));
        }
        continue;
      }

      // 2) QRC 行 [startMs,durMs]文字(startMs,durMs)…
      final qrc = _qrcLine.firstMatch(trimmed);
      if (qrc != null) {
        final start = int.tryParse(qrc.group(1) ?? '');
        if (start == null) continue;
        final dur = int.tryParse(qrc.group(2) ?? '') ?? 3000;
        final body = qrc.group(3) ?? '';
        final words = _parseQrcWords(body, start + dur);
        final String text;
        if (words.isNotEmpty) {
          final joined = words.map((w) => w.text).join().trim();
          text = joined.isNotEmpty ? joined : _cleanText(body);
        } else {
          text = _cleanText(body);
        }
        if (text.isNotEmpty) {
          parsed.add(
            LyricLine(
              timeMs: start,
              text: text,
              endMs: start + dur,
              words: words,
            ),
          );
        }
        continue;
      }

      // 3) YRC JSON 行：拼接 tx 字段为正文
      if (trimmed.startsWith('{"') && trimmed.endsWith('}')) {
        final t = _yrcTime.firstMatch(trimmed)?.group(1);
        if (t != null) {
          final tMs = int.tryParse(t);
          if (tMs != null) {
            final text = _cleanText(
              _yrcWord
                  .allMatches(trimmed)
                  .map(
                    (m) => (m.group(1) ?? '')
                        .replaceAll('\\"', '"')
                        .replaceAll('\\\\', '\\'),
                  )
                  .join(),
            );
            if (text.isNotEmpty) parsed.add(LyricLine(timeMs: tMs, text: text));
            continue;
          }
        }
        final mapped = _cleanText(trimmed);
        if (mapped.isNotEmpty && mapped != trimmed) {
          plainFallback.add(mapped);
          continue;
        }
        // 无法解读的裸 JSON 行直接丢弃
        continue;
      }

      // 4) 纯文本行：暂存，仅当全篇无时间戳时作为后备；
      // 解密失败残留的 QRC 十六进制串（超长无空格纯 hex）直接丢弃，避免整屏乱码
      final text = _cleanText(trimmed);
      if (text.isEmpty) continue;
      if (text.length > 500 && !text.contains(RegExp(r'\s')) && _isHex(text)) {
        continue;
      }
      if (!text.startsWith('[') || !text.endsWith(']')) plainFallback.add(text);
    }

    if (parsed.isNotEmpty) {
      final indexed = <(int, LyricLine)>[
        for (var i = 0; i < parsed.length; i++) (i, parsed[i]),
      ];
      indexed.sort((a, b) {
        final c = a.$2.timeMs.compareTo(b.$2.timeMs);
        return c != 0 ? c : a.$1.compareTo(b.$1);
      });
      final sorted = [for (final e in indexed) e.$2];
      // 回填行尾/字尾：无声明时截断到下一行行首，避免高亮拖尾、滚动提前量错位
      return List.generate(sorted.length, (i) {
        final l = sorted[i];
        final nextStart = i + 1 < sorted.length ? sorted[i + 1].timeMs : null;
        final int end;
        if (l.endMs != _maxMs && (nextStart == null || l.endMs <= nextStart)) {
          end = l.endMs;
        } else if (nextStart != null) {
          end = nextStart;
        } else if (l.endMs != _maxMs) {
          end = l.endMs;
        } else {
          end = l.timeMs + 8000;
        }
        final minEnd = l.timeMs + 320;
        final adjustedEnd = end > minEnd ? end : minEnd;
        final words = l.words.isEmpty
            ? const <LyricWord>[]
            : List.generate(l.words.length, (wi) {
                final w = l.words[wi];
                final int wEnd;
                if (wi == l.words.length - 1) {
                  wEnd = (w.endMs == _maxMs || w.endMs > adjustedEnd)
                      ? adjustedEnd
                      : w.endMs;
                } else {
                  final nStart = l.words[wi + 1].startMs;
                  // 后字提前（插件相对/绝对时间混用）时把前字截断到后字开头
                  wEnd = w.endMs > nStart ? nStart : w.endMs;
                }
                final minWordEnd = w.startMs + 120;
                return w.copyWith(endMs: wEnd > minWordEnd ? wEnd : minWordEnd);
              });
        return l.copyWith(endMs: adjustedEnd, words: words);
      });
    }

    // 全篇无时间戳：按行递增分配时间戳，确保可展示
    return List.generate(plainFallback.length, (index) {
      final s = index * 3000;
      return LyricLine(timeMs: s, text: plainFallback[index], endMs: s + 3000);
    });
  }

  static int _stampToMs(Match m) {
    final minutes = int.tryParse(m.group(1) ?? '') ?? 0;
    final seconds = int.tryParse(m.group(2) ?? '') ?? 0;
    final fraction =
        int.tryParse((m.group(3) ?? '').padRight(3, '0').substring(0, 3)) ?? 0;
    return minutes * 60 * 1000 + seconds * 1000 + fraction;
  }

  static bool _isHex(String text) {
    for (final unit in text.codeUnits) {
      final isHex =
          (unit >= 0x30 && unit <= 0x39) ||
          (unit >= 0x61 && unit <= 0x66) ||
          (unit >= 0x41 && unit <= 0x46);
      if (!isHex) {
        return false;
      }
    }
    return true;
  }
}
