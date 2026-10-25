import 'package:baka_music/models/media_models.dart';
import 'package:baka_music/util/common_utils.dart';
import 'package:baka_music/util/lyric_decrypt.dart';
import 'package:baka_music/util/lyric_parser.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('QRC 解密', () {
    test('加密串往返：XML → 加密 → 解密 → 富 QRC', () {
      const xml =
          '<?xml version="1.0"?><LyricContent>'
          '[1000,2000]你(1000,500)好(1500,500)'
          '[3000,1000]再(3000,500)见(3500,500)'
          '</LyricContent>';
      final cipher = LyricDecrypt.debugEncodeQrc(xml);
      expect(LyricDecrypt.isQRCEncrypted(cipher), isTrue);
      expect(
        LyricDecrypt.autoDecryptLyric(cipher),
        '[1000,2000]你(1000,500)好(1500,500)\n'
        '[3000,1000]再(3000,500)见(3500,500)',
      );
    });

    test('普通 LRC 与非法输入原样返回', () {
      const lrc = '[00:01.000]你好\n[00:03.500]世界';
      expect(LyricDecrypt.autoDecryptLyric(lrc), lrc);
      const garbage = 'zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz';
      expect(LyricDecrypt.isQRCEncrypted(garbage), isFalse);
      expect(LyricDecrypt.autoDecryptLyric(garbage), garbage);
      expect(LyricDecrypt.autoDecryptLyric(null), isNull);
    });
  });

  group('歌词解析', () {
    test('标准 LRC：行尾截断到下一行', () {
      final lines = LyricParser.parse(
        const LyricSource(rawLrc: '[00:01.000]你好\n[00:03.500]世界'),
      );
      expect(lines.length, 2);
      expect(lines[0].timeMs, 1000);
      expect(lines[0].text, '你好');
      expect(lines[0].endMs, 3500);
      expect(lines[1].timeMs, 3500);
      expect(lines[1].endMs, 11500);
    });

    test('富 QRC 逐字时间轴', () {
      final lines = LyricParser.parse(
        const LyricSource(rawLrc: '[1000,2000]你(1000,500)好(1500,500)'),
      );
      expect(lines.length, 1);
      expect(lines[0].text, '你好');
      expect(lines[0].endMs, 3000);
      expect(lines[0].words.length, 2);
      expect(lines[0].words[0].startMs, 1000);
      expect(lines[0].words[0].endMs, 1500);
      expect(lines[0].words[1].startMs, 1500);
      expect(lines[0].words[1].endMs, 2000);
    });

    test('无时间戳纯文本按行分配', () {
      final lines = LyricParser.parse(const LyricSource(rawLrc: '第一行\n第二行'));
      expect(lines.length, 2);
      expect(lines[0].timeMs, 0);
      expect(lines[0].endMs, 3000);
      expect(lines[1].timeMs, 3000);
      expect(lines[1].endMs, 6000);
    });

    test('空来源返回空列表', () {
      expect(LyricParser.parse(null), isEmpty);
      expect(LyricParser.parse(const LyricSource(rawLrc: '   ')), isEmpty);
    });
  });

  group('格式化', () {
    test('formatDuration', () {
      expect(formatDuration(0), '0:00');
      expect(formatDuration(-1), '0:00');
      expect(formatDuration(65000), '1:05');
    });

    test('formatSize', () {
      expect(formatSize(0), '未知大小');
      expect(formatSize(2048), '2 KB');
      expect(formatSize(3 * 1024 * 1024), '3.0 MB');
    });
  });
}
