import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show visibleForTesting;

/// 歌词解密：QRC 加密十六进制串或 QRC XML
abstract final class LyricDecrypt {
  /// QQ 客户端三 DES 密钥
  static final Uint8List _key1 = Uint8List.fromList(
    utf8.encode('!@#)(NHLiuy*\$%^&'),
  );
  static final Uint8List _key2 = Uint8List.fromList(
    utf8.encode('123ZXC!@#)(*\$%^&'),
  );
  static final Uint8List _key3 = Uint8List.fromList(
    utf8.encode('!@#)(*\$%^&abcDEF'),
  );

  static const List<int> _sBox1 = [
    14, 4, 13, 1, 2, 15, 11, 8, 3, 10, 6, 12, 5, 9, 0, 7, //
    0, 15, 7, 4, 14, 2, 13, 1, 10, 6, 12, 11, 9, 5, 3, 8,
    4, 1, 14, 8, 13, 6, 2, 11, 15, 12, 9, 7, 3, 10, 5, 0,
    15, 12, 8, 2, 4, 9, 1, 7, 5, 11, 3, 14, 10, 0, 6, 13,
  ];
  static const List<int> _sBox2 = [
    15, 1, 8, 14, 6, 11, 3, 4, 9, 7, 2, 13, 12, 0, 5, 10, //
    3, 13, 4, 7, 15, 2, 8, 15, 12, 0, 1, 10, 6, 9, 11, 5,
    0, 14, 7, 11, 10, 4, 13, 1, 5, 8, 12, 6, 9, 3, 2, 15,
    13, 8, 10, 1, 3, 15, 4, 2, 11, 6, 7, 12, 0, 5, 14, 9,
  ];
  static const List<int> _sBox3 = [
    10, 0, 9, 14, 6, 3, 15, 5, 1, 13, 12, 7, 11, 4, 2, 8, //
    13, 7, 0, 9, 3, 4, 6, 10, 2, 8, 5, 14, 12, 11, 15, 1,
    13, 6, 4, 9, 8, 15, 3, 0, 11, 1, 2, 12, 5, 10, 14, 7,
    1, 10, 13, 0, 6, 9, 8, 7, 4, 15, 14, 3, 11, 5, 2, 12,
  ];
  static const List<int> _sBox4 = [
    7, 13, 14, 3, 0, 6, 9, 10, 1, 2, 8, 5, 11, 12, 4, 15, //
    13, 8, 11, 5, 6, 15, 0, 3, 4, 7, 2, 12, 1, 10, 14, 9,
    10, 6, 9, 0, 12, 11, 7, 13, 15, 1, 3, 14, 5, 2, 8, 4,
    3, 15, 0, 6, 10, 10, 13, 8, 9, 4, 5, 11, 12, 7, 2, 14,
  ];
  static const List<int> _sBox5 = [
    2, 12, 4, 1, 7, 10, 11, 6, 8, 5, 3, 15, 13, 0, 14, 9, //
    14, 11, 2, 12, 4, 7, 13, 1, 5, 0, 15, 10, 3, 9, 8, 6,
    4, 2, 1, 11, 10, 13, 7, 8, 15, 9, 12, 5, 6, 3, 0, 14,
    11, 8, 12, 7, 1, 14, 2, 13, 6, 15, 0, 9, 10, 4, 5, 3,
  ];
  static const List<int> _sBox6 = [
    12, 1, 10, 15, 9, 2, 6, 8, 0, 13, 3, 4, 14, 7, 5, 11, //
    10, 15, 4, 2, 7, 12, 9, 5, 6, 1, 13, 14, 0, 11, 3, 8,
    9, 14, 15, 5, 2, 8, 12, 3, 7, 0, 4, 10, 1, 13, 11, 6,
    4, 3, 2, 12, 9, 5, 15, 10, 11, 14, 1, 7, 6, 0, 8, 13,
  ];
  static const List<int> _sBox7 = [
    4, 11, 2, 14, 15, 0, 8, 13, 3, 12, 9, 7, 5, 10, 6, 1, //
    13, 0, 11, 7, 4, 9, 1, 10, 14, 3, 5, 12, 2, 15, 8, 6,
    1, 4, 11, 13, 12, 3, 7, 14, 10, 15, 6, 8, 0, 5, 9, 2,
    6, 11, 13, 8, 1, 4, 10, 7, 9, 5, 0, 15, 14, 2, 3, 12,
  ];
  static const List<int> _sBox8 = [
    13, 2, 8, 4, 6, 15, 11, 1, 10, 9, 3, 14, 5, 0, 12, 7, //
    1, 15, 13, 8, 10, 3, 7, 4, 12, 5, 6, 11, 0, 14, 9, 2,
    7, 11, 4, 1, 9, 12, 14, 2, 0, 6, 10, 13, 15, 3, 5, 8,
    2, 1, 14, 7, 4, 10, 8, 13, 15, 12, 9, 0, 3, 5, 6, 11,
  ];

  static const int _desEncrypt = 0;
  static const int _desDecrypt = 1;

  static const int _maxInputLength = 2 * 1024 * 1024;
  static const int _maxDecompressedLength = 5 * 1024 * 1024;

  static int _bitNum(Uint8List a, int b, int c) {
    final byteIndex = b ~/ 32 * 4 + 3 - (b % 32) ~/ 8;
    final bitPosition = 7 - (b % 8);
    final extractedBit = ((a[byteIndex] & 0xFF) >> bitPosition) & 0x01;
    return extractedBit << c;
  }

  static int _bitNumIntR(int a, int b, int c) {
    final extractedBit = ((a & 0xFFFFFFFF) >>> (31 - b)) & 0x00000001;
    return extractedBit << c;
  }

  static int _bitNumIntL(int a, int b, int c) {
    final extractedBit = (a << b) & 0x80000000;
    return extractedBit >>> c;
  }

  static int _sBoxBit(int a) =>
      (a & 0x20) | ((a & 0x1F) >> 1) | ((a & 0x01) << 4);

  static void _ipPermutation(List<int> state, Uint8List inBytes) {
    state[0] =
        _bitNum(inBytes, 57, 31) |
        _bitNum(inBytes, 49, 30) |
        _bitNum(inBytes, 41, 29) |
        _bitNum(inBytes, 33, 28) |
        _bitNum(inBytes, 25, 27) |
        _bitNum(inBytes, 17, 26) |
        _bitNum(inBytes, 9, 25) |
        _bitNum(inBytes, 1, 24) |
        _bitNum(inBytes, 59, 23) |
        _bitNum(inBytes, 51, 22) |
        _bitNum(inBytes, 43, 21) |
        _bitNum(inBytes, 35, 20) |
        _bitNum(inBytes, 27, 19) |
        _bitNum(inBytes, 19, 18) |
        _bitNum(inBytes, 11, 17) |
        _bitNum(inBytes, 3, 16) |
        _bitNum(inBytes, 61, 15) |
        _bitNum(inBytes, 53, 14) |
        _bitNum(inBytes, 45, 13) |
        _bitNum(inBytes, 37, 12) |
        _bitNum(inBytes, 29, 11) |
        _bitNum(inBytes, 21, 10) |
        _bitNum(inBytes, 13, 9) |
        _bitNum(inBytes, 5, 8) |
        _bitNum(inBytes, 63, 7) |
        _bitNum(inBytes, 55, 6) |
        _bitNum(inBytes, 47, 5) |
        _bitNum(inBytes, 39, 4) |
        _bitNum(inBytes, 31, 3) |
        _bitNum(inBytes, 23, 2) |
        _bitNum(inBytes, 15, 1) |
        _bitNum(inBytes, 7, 0);
    state[1] =
        _bitNum(inBytes, 56, 31) |
        _bitNum(inBytes, 48, 30) |
        _bitNum(inBytes, 40, 29) |
        _bitNum(inBytes, 32, 28) |
        _bitNum(inBytes, 24, 27) |
        _bitNum(inBytes, 16, 26) |
        _bitNum(inBytes, 8, 25) |
        _bitNum(inBytes, 0, 24) |
        _bitNum(inBytes, 58, 23) |
        _bitNum(inBytes, 50, 22) |
        _bitNum(inBytes, 42, 21) |
        _bitNum(inBytes, 34, 20) |
        _bitNum(inBytes, 26, 19) |
        _bitNum(inBytes, 18, 18) |
        _bitNum(inBytes, 10, 17) |
        _bitNum(inBytes, 2, 16) |
        _bitNum(inBytes, 60, 15) |
        _bitNum(inBytes, 52, 14) |
        _bitNum(inBytes, 44, 13) |
        _bitNum(inBytes, 36, 12) |
        _bitNum(inBytes, 28, 11) |
        _bitNum(inBytes, 20, 10) |
        _bitNum(inBytes, 12, 9) |
        _bitNum(inBytes, 4, 8) |
        _bitNum(inBytes, 62, 7) |
        _bitNum(inBytes, 54, 6) |
        _bitNum(inBytes, 46, 5) |
        _bitNum(inBytes, 38, 4) |
        _bitNum(inBytes, 30, 3) |
        _bitNum(inBytes, 22, 2) |
        _bitNum(inBytes, 14, 1) |
        _bitNum(inBytes, 6, 0);
  }

  static void _invIp(List<int> state, Uint8List inBytes) {
    inBytes[3] =
        (_bitNumIntR(state[1], 7, 7) |
            _bitNumIntR(state[0], 7, 6) |
            _bitNumIntR(state[1], 15, 5) |
            _bitNumIntR(state[0], 15, 4) |
            _bitNumIntR(state[1], 23, 3) |
            _bitNumIntR(state[0], 23, 2) |
            _bitNumIntR(state[1], 31, 1) |
            _bitNumIntR(state[0], 31, 0)) &
        0xFF;
    inBytes[2] =
        (_bitNumIntR(state[1], 6, 7) |
            _bitNumIntR(state[0], 6, 6) |
            _bitNumIntR(state[1], 14, 5) |
            _bitNumIntR(state[0], 14, 4) |
            _bitNumIntR(state[1], 22, 3) |
            _bitNumIntR(state[0], 22, 2) |
            _bitNumIntR(state[1], 30, 1) |
            _bitNumIntR(state[0], 30, 0)) &
        0xFF;
    inBytes[1] =
        (_bitNumIntR(state[1], 5, 7) |
            _bitNumIntR(state[0], 5, 6) |
            _bitNumIntR(state[1], 13, 5) |
            _bitNumIntR(state[0], 13, 4) |
            _bitNumIntR(state[1], 21, 3) |
            _bitNumIntR(state[0], 21, 2) |
            _bitNumIntR(state[1], 29, 1) |
            _bitNumIntR(state[0], 29, 0)) &
        0xFF;
    inBytes[0] =
        (_bitNumIntR(state[1], 4, 7) |
            _bitNumIntR(state[0], 4, 6) |
            _bitNumIntR(state[1], 12, 5) |
            _bitNumIntR(state[0], 12, 4) |
            _bitNumIntR(state[1], 20, 3) |
            _bitNumIntR(state[0], 20, 2) |
            _bitNumIntR(state[1], 28, 1) |
            _bitNumIntR(state[0], 28, 0)) &
        0xFF;
    inBytes[7] =
        (_bitNumIntR(state[1], 3, 7) |
            _bitNumIntR(state[0], 3, 6) |
            _bitNumIntR(state[1], 11, 5) |
            _bitNumIntR(state[0], 11, 4) |
            _bitNumIntR(state[1], 19, 3) |
            _bitNumIntR(state[0], 19, 2) |
            _bitNumIntR(state[1], 27, 1) |
            _bitNumIntR(state[0], 27, 0)) &
        0xFF;
    inBytes[6] =
        (_bitNumIntR(state[1], 2, 7) |
            _bitNumIntR(state[0], 2, 6) |
            _bitNumIntR(state[1], 10, 5) |
            _bitNumIntR(state[0], 10, 4) |
            _bitNumIntR(state[1], 18, 3) |
            _bitNumIntR(state[0], 18, 2) |
            _bitNumIntR(state[1], 26, 1) |
            _bitNumIntR(state[0], 26, 0)) &
        0xFF;
    inBytes[5] =
        (_bitNumIntR(state[1], 1, 7) |
            _bitNumIntR(state[0], 1, 6) |
            _bitNumIntR(state[1], 9, 5) |
            _bitNumIntR(state[0], 9, 4) |
            _bitNumIntR(state[1], 17, 3) |
            _bitNumIntR(state[0], 17, 2) |
            _bitNumIntR(state[1], 25, 1) |
            _bitNumIntR(state[0], 25, 0)) &
        0xFF;
    inBytes[4] =
        (_bitNumIntR(state[1], 0, 7) |
            _bitNumIntR(state[0], 0, 6) |
            _bitNumIntR(state[1], 8, 5) |
            _bitNumIntR(state[0], 8, 4) |
            _bitNumIntR(state[1], 16, 3) |
            _bitNumIntR(state[0], 16, 2) |
            _bitNumIntR(state[1], 24, 1) |
            _bitNumIntR(state[0], 24, 0)) &
        0xFF;
  }

  static int _feistelF(int state, Uint8List key) {
    final lrg = Uint8List(6);
    final s0 = state & 0xFFFFFFFF;
    final t1 =
        (_bitNumIntL(s0, 31, 0) |
            ((s0 & 0xF0000000) >>> 1) |
            _bitNumIntL(s0, 4, 5) |
            _bitNumIntL(s0, 3, 6) |
            ((s0 & 0x0F000000) >>> 3) |
            _bitNumIntL(s0, 8, 11) |
            _bitNumIntL(s0, 7, 12) |
            ((s0 & 0x00F00000) >>> 5) |
            _bitNumIntL(s0, 12, 17) |
            _bitNumIntL(s0, 11, 18) |
            ((s0 & 0x000F0000) >>> 7) |
            _bitNumIntL(s0, 16, 23)) &
        0xFFFFFFFF;
    final t2 =
        (_bitNumIntL(s0, 15, 0) |
            ((s0 & 0x0000F000) << 15) |
            _bitNumIntL(s0, 20, 5) |
            _bitNumIntL(s0, 19, 6) |
            ((s0 & 0x00000F00) << 13) |
            _bitNumIntL(s0, 24, 11) |
            _bitNumIntL(s0, 23, 12) |
            ((s0 & 0x000000F0) << 11) |
            _bitNumIntL(s0, 28, 17) |
            _bitNumIntL(s0, 27, 18) |
            ((s0 & 0x0000000F) << 9) |
            _bitNumIntL(s0, 0, 23)) &
        0xFFFFFFFF;
    lrg[0] = (t1 >>> 24) & 0xFF;
    lrg[1] = (t1 >>> 16) & 0xFF;
    lrg[2] = (t1 >>> 8) & 0xFF;
    lrg[3] = (t2 >>> 24) & 0xFF;
    lrg[4] = (t2 >>> 16) & 0xFF;
    lrg[5] = (t2 >>> 8) & 0xFF;
    for (var i = 0; i < 6; i++) {
      lrg[i] = lrg[i] ^ key[i];
    }
    final b0 = lrg[0];
    final b1 = lrg[1];
    final b2 = lrg[2];
    final b3 = lrg[3];
    final b4 = lrg[4];
    final b5 = lrg[5];
    var s =
        ((_sBox1[_sBoxBit(b0 >> 2)] << 28) |
            (_sBox2[_sBoxBit(((b0 & 0x03) << 4) | (b1 >> 4))] << 24) |
            (_sBox3[_sBoxBit(((b1 & 0x0F) << 2) | (b2 >> 6))] << 20) |
            (_sBox4[_sBoxBit(b2 & 0x3F)] << 16) |
            (_sBox5[_sBoxBit(b3 >> 2)] << 12) |
            (_sBox6[_sBoxBit(((b3 & 0x03) << 4) | (b4 >> 4))] << 8) |
            (_sBox7[_sBoxBit(((b4 & 0x0F) << 2) | (b5 >> 6))] << 4) |
            _sBox8[_sBoxBit(b5 & 0x3F)]) &
        0xFFFFFFFF;
    s =
        (_bitNumIntL(s, 15, 0) |
            _bitNumIntL(s, 6, 1) |
            _bitNumIntL(s, 19, 2) |
            _bitNumIntL(s, 20, 3) |
            _bitNumIntL(s, 28, 4) |
            _bitNumIntL(s, 11, 5) |
            _bitNumIntL(s, 27, 6) |
            _bitNumIntL(s, 16, 7) |
            _bitNumIntL(s, 0, 8) |
            _bitNumIntL(s, 14, 9) |
            _bitNumIntL(s, 22, 10) |
            _bitNumIntL(s, 25, 11) |
            _bitNumIntL(s, 4, 12) |
            _bitNumIntL(s, 17, 13) |
            _bitNumIntL(s, 30, 14) |
            _bitNumIntL(s, 9, 15) |
            _bitNumIntL(s, 1, 16) |
            _bitNumIntL(s, 7, 17) |
            _bitNumIntL(s, 23, 18) |
            _bitNumIntL(s, 13, 19) |
            _bitNumIntL(s, 31, 20) |
            _bitNumIntL(s, 26, 21) |
            _bitNumIntL(s, 2, 22) |
            _bitNumIntL(s, 8, 23) |
            _bitNumIntL(s, 18, 24) |
            _bitNumIntL(s, 12, 25) |
            _bitNumIntL(s, 29, 26) |
            _bitNumIntL(s, 5, 27) |
            _bitNumIntL(s, 21, 28) |
            _bitNumIntL(s, 10, 29) |
            _bitNumIntL(s, 3, 30) |
            _bitNumIntL(s, 24, 31)) &
        0xFFFFFFFF;
    return s & 0xFFFFFFFF;
  }

  static void _desKeySetup(Uint8List key, List<Uint8List> schedule, int mode) {
    const keyRndShift = [1, 1, 2, 2, 2, 2, 2, 2, 1, 2, 2, 2, 2, 2, 2, 1];
    const keyPermC = [
      56, 48, 40, 32, 24, 16, 8, 0, 57, 49, 41, 33, 25, 17, //
      9, 1, 58, 50, 42, 34, 26, 18, 10, 2, 59, 51, 43, 35,
    ];
    const keyPermD = [
      62, 54, 46, 38, 30, 22, 14, 6, 61, 53, 45, 37, 29, 21, //
      13, 5, 60, 52, 44, 36, 28, 20, 12, 4, 27, 19, 11, 3,
    ];
    const keyCompression = [
      13, 16, 10, 23, 0, 4, 2, 27, 14, 5, 20, 9, //
      22, 18, 11, 3, 25, 7, 15, 6, 26, 19, 12, 1,
      40, 51, 30, 36, 46, 54, 29, 39, 50, 44, 32, 47,
      43, 48, 38, 55, 33, 52, 45, 41, 49, 35, 28, 31,
    ];
    var c = 0;
    var d = 0;
    for (var i = 0; i < 28; i++) {
      c |= _bitNum(key, keyPermC[i], 31 - i);
      d |= _bitNum(key, keyPermD[i], 31 - i);
    }
    for (var i = 0; i < 16; i++) {
      final shift = keyRndShift[i];
      c = ((c << shift) | (c >>> (28 - shift))) & 0xFFFFFFF0;
      d = ((d << shift) | (d >>> (28 - shift))) & 0xFFFFFFF0;
      final toGen = mode == _desDecrypt ? 15 - i : i;
      final sched = Uint8List(6);
      schedule[toGen] = sched;
      for (var j = 0; j < 24; j++) {
        sched[j ~/ 8] |= _bitNumIntR(c, keyCompression[j], 7 - (j % 8));
      }
      for (var j = 24; j < 48; j++) {
        sched[j ~/ 8] |= _bitNumIntR(
          d & 0xFFFFFFFF,
          keyCompression[j] - 27,
          7 - (j % 8),
        );
      }
    }
  }

  static Uint8List _desCrypt(Uint8List input, List<Uint8List> keySchedule) {
    final state = List<int>.filled(2, 0);
    _ipPermutation(state, input);
    for (var idx = 0; idx < 15; idx++) {
      final t = state[1];
      state[1] = _feistelF(state[1], keySchedule[idx]) ^ state[0];
      state[0] = t;
    }
    state[0] = _feistelF(state[1], keySchedule[15]) ^ state[0];
    _invIp(state, input);
    return input;
  }

  static Uint8List _funcDes(Uint8List buff, Uint8List key, int length) {
    final schedule = List<Uint8List>.generate(16, (_) => Uint8List(6));
    _desKeySetup(key, schedule, _desEncrypt);
    final output = Uint8List(length);
    for (var i = 0; i < length; i += 8) {
      final end = i + 8 < buff.length ? i + 8 : buff.length;
      final block = Uint8List(8)..setRange(0, end - i, buff, i);
      _desCrypt(block, schedule);
      final copyLen = 8 < length - i ? 8 : length - i;
      output.setRange(i, i + copyLen, block.sublist(0, copyLen));
    }
    return output;
  }

  static Uint8List _funcDdes(Uint8List buff, Uint8List key, int length) {
    final schedule = List<Uint8List>.generate(16, (_) => Uint8List(6));
    _desKeySetup(key, schedule, _desDecrypt);
    final output = Uint8List(length);
    for (var i = 0; i < length; i += 8) {
      final end = i + 8 < buff.length ? i + 8 : buff.length;
      final block = Uint8List(8)..setRange(0, end - i, buff, i);
      _desCrypt(block, schedule);
      final copyLen = 8 < length - i ? 8 : length - i;
      output.setRange(i, i + copyLen, block.sublist(0, copyLen));
    }
    return output;
  }

  /// QRC 解码：KEY1 解密 → KEY2 加密 → KEY3 解密
  static Uint8List _lyricDecode(Uint8List content) {
    final length = content.length;
    var result = _funcDdes(content, _key1, length);
    result = _funcDes(result, _key2, length);
    result = _funcDdes(result, _key3, length);
    return result;
  }

  static Uint8List _safeInflate(Uint8List data) {
    if (data.length > _maxInputLength) {
      throw ArgumentError('Input too large for decompression');
    }
    // 部分 QRC 数据解出后是 zlib 包装流（78 9C 等），其余为裸 deflate，
    // 按头部魔数自动选择解码器，否则 Filter error 导致歌词回退为原始十六进制串
    final zlibWrapped =
        data.length >= 2 &&
        (data[0] & 0x0F) == 8 &&
        (((data[0] << 8) | data[1]) % 31) == 0;
    final out = BytesBuilder(copy: false);
    final sink = _LimitedByteSink(out, _maxDecompressedLength);
    final converter = ZLibDecoder(raw: !zlibWrapped)
        .startChunkedConversion(sink);
    try {
      converter.add(data);
      converter.close();
    } on FormatException {
      // 流尾多余填充字节（DES 分组对齐补零）允许忽略
      if (out.length == 0) rethrow;
    }
    return out.takeBytes();
  }

  static final RegExp _lrcTimestampHint = RegExp(r'\[\d{2}:\d{2}[.:]\d{2,3}\]');
  static final RegExp _hexOnly = RegExp(r'^[0-9a-fA-F]+$');

  static bool isQRCEncrypted(String lyrics) {
    if (lyrics.isEmpty) return false;
    final trimmed = lyrics.trim();
    if (trimmed.length < 32) return false;
    if (trimmed.length % 16 != 0) return false;
    if (!_hexOnly.hasMatch(trimmed)) return false;
    if (_lrcTimestampHint.hasMatch(trimmed)) return false;
    return true;
  }

  static bool isQrcXml(String text) =>
      text.isNotEmpty &&
      text.contains('<?xml') &&
      text.contains('LyricContent');

  static final RegExp _qrcLineSplit = RegExp(
    r'\[(\d+),(\d+)\]([\s\S]*?)(?=\[\d+,\d+\]|$)',
  );
  static final RegExp _qrcWordKeep = RegExp(r'([^()]*?)\((\d+),(\d+)\)');
  static final RegExp _kanaTag = RegExp(r'\[kana:.*?\]');
  static final RegExp _wordTimeStrip = RegExp(r'\(\d+,\d+\)');

  /// QRC XML → 保留逐字时间轴的富 QRC
  /// [行首ms,行时值]文字(字首ms,字时值)…
  static String convertQrcXmlToRichQrc(String xml) {
    final lines = <String>[];
    for (final lm in _qrcLineSplit.allMatches(xml)) {
      final lineStart = lm.group(1) ?? '';
      final lineDur = lm.group(2) ?? '';
      final body = (lm.group(3) ?? '').replaceAll(_kanaTag, '');
      final chunks = StringBuffer();
      for (final wm in _qrcWordKeep.allMatches(body)) {
        chunks
          ..write(wm.group(1) ?? '')
          ..write('(')
          ..write(wm.group(2) ?? '')
          ..write(',')
          ..write(wm.group(3) ?? '')
          ..write(')');
      }
      final lineText = chunks.toString();
      if (lineText.replaceAll(_wordTimeStrip, '').trim().isNotEmpty) {
        lines.add('[$lineStart,$lineDur]$lineText');
      }
    }
    return lines.join('\n');
  }

  static String _decryptQRCLyric(String encryptedHex) {
    final trimmed = encryptedHex.trim();
    final bytes = Uint8List(trimmed.length ~/ 2);
    for (var i = 0; i < bytes.length; i++) {
      bytes[i] = int.parse(trimmed.substring(i * 2, i * 2 + 2), radix: 16);
    }
    final decrypted = _lyricDecode(bytes);
    final decompressed = _safeInflate(decrypted);
    return utf8.decode(decompressed, allowMalformed: true);
  }

  /// 加密串解密、QRC XML 转富 QRC
  /// 普通 LRC/纯文本原样返回；失败时返回原文
  static String? autoDecryptLyric(String? lyrics) {
    if (lyrics == null || lyrics.isEmpty) return lyrics;
    if (isQRCEncrypted(lyrics)) {
      try {
        final decrypted = _decryptQRCLyric(lyrics);
        return isQrcXml(decrypted)
            ? convertQrcXmlToRichQrc(decrypted)
            : decrypted;
      } catch (_) {
        return lyrics;
      }
    }
    if (isQrcXml(lyrics)) return convertQrcXmlToRichQrc(lyrics);
    return lyrics;
  }

  /// 仅供测试：按解密链的逆过程构造 QRC 加密串，验证解密实现自洽
  @visibleForTesting
  static String debugEncodeQrc(String plain) {
    final compressed = ZLibEncoder(raw: true).convert(utf8.encode(plain));
    var payload = Uint8List.fromList(compressed);
    if (payload.length % 8 != 0) {
      final padded = Uint8List(payload.length + 8 - payload.length % 8);
      padded.setRange(0, payload.length, payload);
      payload = padded;
    }
    var out = _funcDes(payload, _key3, payload.length);
    out = _funcDdes(out, _key2, out.length);
    out = _funcDes(out, _key1, out.length);
    final hex = StringBuffer();
    for (final b in out) {
      hex.write(b.toRadixString(16).padLeft(2, '0'));
    }
    return hex.toString();
  }
}

class _LimitedByteSink implements Sink<List<int>> {
  _LimitedByteSink(this._out, this._limit);

  final BytesBuilder _out;
  final int _limit;

  @override
  void add(List<int> data) {
    if (_out.length + data.length > _limit) {
      throw const FormatException('inflate 输出超限');
    }
    _out.add(data);
  }

  @override
  void close() {}
}
