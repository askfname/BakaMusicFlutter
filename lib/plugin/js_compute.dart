/// 插件桥接的同步计算原语：
/// 摘要/HMAC、模幂、字符集解码、zlib/raw/gzip 解压、AES 加解密
/// 全部按“失败返回空串/回退”的契约实现
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:enough_convert/enough_convert.dart';
import 'package:pointycastle/asn1.dart';
import 'package:pointycastle/export.dart';

const int _maxInflateBytes = 8 * 1024 * 1024;

String md5Hex(String value) => md5.convert(utf8.encode(value)).toString();

String sha1Hex(String value) => sha1.convert(utf8.encode(value)).toString();

String sha256Hex(String value) => sha256.convert(utf8.encode(value)).toString();

String sha512Hex(String value) => sha512.convert(utf8.encode(value)).toString();

String hmacSha256Hex(String key, String value) =>
    _hmacHex(sha256, key, value);

String hmacSha1Hex(String key, String value) => _hmacHex(sha1, key, value);

String hmacMd5Hex(String key, String value) => _hmacHex(md5, key, value);

String _hmacHex(Hash hash, String key, String value) {
  try {
    return Hmac(hash, utf8.encode(key)).convert(utf8.encode(value)).toString();
  } catch (_) {
    return '';
  }
}

String _cleanHex(String value, String fallback) {
  var v = value.trim();
  if (v.startsWith('0x')) v = v.substring(2);
  return v.isEmpty ? fallback : v;
}

/// 大数模幂（十六进制），失败返回 "0"
String modPowHex(String baseHex, String expHex, String modHex) {
  try {
    final b = BigInt.parse(_cleanHex(baseHex, '0'), radix: 16);
    final e = BigInt.parse(_cleanHex(expHex, '0'), radix: 16);
    final m = BigInt.parse(_cleanHex(modHex, '1'), radix: 16);
    return b.modPow(e, m).toRadixString(16);
  } catch (_) {
    return '0';
  }
}

/// 宽松 Base64 解码：容忍空白、URL-safe 字母表与缺失填充
Uint8List decodeBase64Lenient(String input) {
  var s = input.replaceAll(RegExp(r'\s+'), '');
  s = s.replaceAll('-', '+').replaceAll('_', '/');
  final rem = s.length % 4;
  if (rem == 1) throw const FormatException('invalid base64');
  if (rem > 0) s = s.padRight(s.length + (4 - rem), '=');
  return base64.decode(s);
}

/// 按字符集名解码字节；未知字符集回退 UTF-8
String textDecode(String base64Text, String charsetName) {
  try {
    return decodeCharset(decodeBase64Lenient(base64Text), charsetName);
  } catch (_) {
    return '';
  }
}

String decodeCharset(List<int> bytes, String charsetName) {
  final key = charsetName.trim().toLowerCase();
  switch (key) {
    case 'utf-8':
    case 'utf8':
      return utf8.decode(bytes, allowMalformed: true);
    case 'gbk':
    case 'gb2312':
    case 'gb-2312':
    case 'gb18030':
    case 'gb-18030':
      return const GbkCodec(allowInvalid: true).decode(bytes);
    case 'big5':
    case 'big-5':
    case 'cp950':
      return const Big5Codec(allowInvalid: true).decode(bytes);
    case 'iso-8859-1':
    case 'iso8859-1':
    case 'latin1':
    case 'latin-1':
      return latin1.decode(bytes);
    case 'us-ascii':
    case 'ascii':
      return String.fromCharCodes(
          bytes.map((b) => b <= 127 ? b : 0xFFFD));
    case 'utf-16':
    case 'utf16':
      return _decodeUtf16(bytes, null);
    case 'utf-16le':
    case 'utf16le':
    case 'utf-16-le':
      return _decodeUtf16(bytes, 'le');
    case 'utf-16be':
    case 'utf16be':
    case 'utf-16-be':
      return _decodeUtf16(bytes, 'be');
    default:
      return utf8.decode(bytes, allowMalformed: true);
  }
}

/// UTF-16 解码：识别 BOM，无 BOM 时 UTF-16 默认大端
String _decodeUtf16(List<int> bytes, String? kind) {
  var start = 0;
  var bigEndian = kind != 'le';
  if (bytes.length >= 2) {
    if (bytes[0] == 0xFF && bytes[1] == 0xFE) {
      start = 2;
      bigEndian = false;
    } else if (bytes[0] == 0xFE && bytes[1] == 0xFF) {
      start = 2;
      bigEndian = true;
    }
  }
  final end = start + ((bytes.length - start) ~/ 2) * 2;
  final units = <int>[];
  for (var i = start; i < end; i += 2) {
    units.add(bigEndian
        ? (bytes[i] << 8) | bytes[i + 1]
        : bytes[i] | (bytes[i + 1] << 8));
  }
  return _utf16UnitsToString(units);
}

/// 按 UTF-16 码元序列拼装字符串，未配对代理项替换为 U+FFFD
String _utf16UnitsToString(List<int> units) {
  final buf = StringBuffer();
  for (var i = 0; i < units.length; i++) {
    final u = units[i];
    if (u >= 0xD800 && u <= 0xDBFF) {
      if (i + 1 < units.length &&
          units[i + 1] >= 0xDC00 &&
          units[i + 1] <= 0xDFFF) {
        buf.writeCharCode(
            0x10000 + ((u - 0xD800) << 10) + (units[i + 1] - 0xDC00));
        i++;
      } else {
        buf.writeCharCode(0xFFFD);
      }
    } else if (u >= 0xDC00 && u <= 0xDFFF) {
      buf.writeCharCode(0xFFFD);
    } else {
      buf.writeCharCode(u);
    }
  }
  return buf.toString();
}

/// zlib 或 raw-deflate 解压（供 pako.inflate 兼容实现使用），返回 Base64；失败返回空串
String inflateBase64(String base64Text) {
  try {
    final input = decodeBase64Lenient(base64Text);
    if (input.length > _maxInflateBytes) return '';
    final List<int> raw;
    if (input.length >= 2 && input[0] == 0x1f && input[1] == 0x8b) {
      final out = _decompressLimited(input, _maxInflateBytes, isGzip: true);
      if (out == null) return '';
      raw = out;
    } else {
      final out = _decompressLimited(input, _maxInflateBytes) ??
          _decompressLimited(input, _maxInflateBytes, raw: true);
      if (out == null) return '';
      raw = out;
    }
    if (raw.length > _maxInflateBytes) return '';
    return base64.encode(raw);
  } catch (_) {
    return '';
  }
}

List<int>? _decompressLimited(List<int> input, int limit,
    {bool raw = false, bool isGzip = false}) {
  try {
    final out = <int>[];
    final sink = _LimitedByteSink(out, limit);
    final converter = isGzip
        ? gzip.decoder.startChunkedConversion(sink)
        : ZLibDecoder(raw: raw).startChunkedConversion(sink);
    converter.add(input);
    converter.close();
    return out;
  } catch (_) {
    return null;
  }
}

class _LimitedByteSink implements Sink<List<int>> {
  _LimitedByteSink(this._out, this._limit);

  final List<int> _out;
  final int _limit;

  @override
  void add(List<int> data) {
    if (_out.length + data.length > _limit) {
      throw const FormatException('inflate 输出超限');
    }
    _out.addAll(data);
  }

  @override
  void close() {}
}

/// AES 加密（PKCS7=CBC/ECB），返回 Base64；失败返回空串
String aesEncrypt(String mode, String key, String iv, String plain) {
  try {
    final out = _aesProcess(
      encrypt: true,
      mode: mode,
      keyBytes: utf8.encode(key),
      ivBytes: utf8.encode(iv),
      input: utf8.encode(plain),
    );
    return base64.encode(out);
  } catch (_) {
    return '';
  }
}

/// AES 解密，返回 UTF-8 文本；失败返回空串
String aesDecrypt(String mode, String key, String iv, String base64Cipher) {
  try {
    final out = _aesProcess(
      encrypt: false,
      mode: mode,
      keyBytes: utf8.encode(key),
      ivBytes: utf8.encode(iv),
      input: decodeBase64Lenient(base64Cipher),
    );
    return utf8.decode(out, allowMalformed: true);
  } catch (_) {
    return '';
  }
}

Uint8List _aesProcess({
  required bool encrypt,
  required String mode,
  required List<int> keyBytes,
  required List<int> ivBytes,
  required List<int> input,
}) {
  final normalizedMode = mode.toUpperCase();
  if (normalizedMode != 'ECB' && normalizedMode != 'CBC') {
    throw ArgumentError.value(mode, 'mode', '仅支持 ECB/CBC');
  }
  final secret = _normalizeAesKey(keyBytes);
  final padded = normalizedMode == 'ECB'
      ? PaddedBlockCipherImpl(PKCS7Padding(), ECBBlockCipher(AESEngine()))
      : PaddedBlockCipherImpl(PKCS7Padding(), CBCBlockCipher(AESEngine()));
  final CipherParameters params = normalizedMode == 'ECB'
      ? KeyParameter(secret)
      : ParametersWithIV<KeyParameter>(KeyParameter(secret), _copyOf16(ivBytes));
  padded.init(
      encrypt, PaddedBlockCipherParameters<CipherParameters?, CipherParameters?>(params, null));
  return padded.process(Uint8List.fromList(input));
}

/// 非标准长度密钥按 16/24/32 补零（超长截断为 32）
Uint8List _normalizeAesKey(List<int> bytes) {
  if (bytes.length == 16 || bytes.length == 24 || bytes.length == 32) {
    return Uint8List.fromList(bytes);
  }
  var target = 32;
  for (final t in const [16, 24, 32]) {
    if (t > bytes.length) {
      target = t;
      break;
    }
  }
  final out = Uint8List(target);
  final n = bytes.length < target ? bytes.length : target;
  out.setRange(0, n, bytes);
  return out;
}

/// iv.toByteArray().copyOf(16)：不足补零、超长截断
Uint8List _copyOf16(List<int> bytes) => _fitBytes(bytes, 16);

/// 按目标长度补零或截断。
Uint8List _fitBytes(List<int> bytes, int size) {
  final out = Uint8List(size);
  final n = bytes.length < size ? bytes.length : size;
  out.setRange(0, n, bytes);
  return out;
}

final Random _secureRandom = Random.secure();

/// 生成指定长度的随机字节（0..1MiB）并 Base64 编码；
/// 越界抛错
String randomBytesBase64(int size) {
  if (size < 0 || size > 1024 * 1024) {
    throw ArgumentError('LX random byte size is invalid');
  }
  final bytes = Uint8List(size);
  for (var i = 0; i < size; i++) {
    bytes[i] = _secureRandom.nextInt(256);
  }
  return base64.encode(bytes);
}

/// AES 加密二进制数据（mode 形如 aes-128-cbc/aes-256-ecb），输入输出均为 Base64；
/// KEY 按 mode 位数补零/截断，IV 固定 16 字节；失败返回空串
String aesEncryptBytes(
    String mode, String dataB64, String keyB64, String ivB64) {
  try {
    final match =
        RegExp(r'^aes-(\d+)-(cbc|ecb)$').firstMatch(mode.trim().toLowerCase());
    if (match == null) return '';
    final bits = int.parse(match.group(1)!);
    if (bits != 128 && bits != 192 && bits != 256) return '';
    final out = _aesProcess(
      encrypt: true,
      mode: match.group(2)!.toUpperCase(),
      keyBytes: _fitBytes(decodeBase64Lenient(keyB64), bits ~/ 8),
      ivBytes: _fitBytes(decodeBase64Lenient(ivB64), 16),
      input: decodeBase64Lenient(dataB64),
    );
    return base64.encode(out);
  } catch (_) {
    return '';
  }
}

/// RSA 公钥加密（原始模幂，无填充）：
/// pem 为 SubjectPublicKeyInfo（PUBLIC KEY）格式，输出按模长左对齐大端的 Base64
String rsaEncryptBase64(String dataB64, String pem) {
  try {
    final der = _pemToDer(pem);
    if (der.isEmpty) return '';
    final spki = ASN1Parser(der).nextObject();
    if (spki is! ASN1Sequence) return '';
    final spkiElements = spki.elements;
    if (spkiElements == null) return '';
    ASN1BitString? bitString;
    for (final element in spkiElements) {
      if (element is ASN1BitString) {
        bitString = element;
        break;
      }
    }
    final keyBytes = bitString?.stringValues;
    if (keyBytes == null || keyBytes.isEmpty) return '';
    final rsaKey = ASN1Parser(Uint8List.fromList(keyBytes)).nextObject();
    if (rsaKey is! ASN1Sequence) return '';
    final parts = rsaKey.elements;
    if (parts == null || parts.length < 2) return '';
    if (parts[0] is! ASN1Integer || parts[1] is! ASN1Integer) return '';
    final modulus = (parts[0] as ASN1Integer).integer;
    final exponent = (parts[1] as ASN1Integer).integer;
    if (modulus == null || exponent == null || modulus <= BigInt.zero) return '';
    final data = decodeBase64Lenient(dataB64);
    final message = data.isEmpty
        ? BigInt.zero
        : BigInt.parse(
            data.map((b) => b.toRadixString(16).padLeft(2, '0')).join(),
            radix: 16,
          );
    if (message >= modulus) return '';
    final encrypted = message.modPow(exponent, modulus);
    final modLen = (modulus.bitLength + 7) ~/ 8;
    final hex = encrypted.toRadixString(16).padLeft(modLen * 2, '0');
    final out = Uint8List(modLen);
    for (var i = 0; i < modLen; i++) {
      out[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return base64.encode(out);
  } catch (_) {
    return '';
  }
}

/// 去除 PEM 头尾标签与空白后解码为 DER
Uint8List _pemToDer(String pem) {
  final body = pem
      .replaceAll(RegExp(r'-----[^-]+-----'), '')
      .replaceAll(RegExp(r'\s+'), '');
  if (body.isEmpty) return Uint8List(0);
  return decodeBase64Lenient(body);
}

/// zlib（带 wrapper）压缩，输入输出均为 Base64
/// 失败或输入超限返回空串
String deflateBase64(String base64Text) {
  try {
    final input = decodeBase64Lenient(base64Text);
    if (input.length > _maxInflateBytes) return '';
    return base64.encode(zlib.encode(input));
  } catch (_) {
    return '';
  }
}
