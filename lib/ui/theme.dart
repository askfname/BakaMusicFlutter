/// 应用主题：
/// 深色与浅色两套配色
library;

import 'package:flutter/material.dart';

/// BakaTheme 配色方案
class BakaTheme {
  BakaTheme._();

  /// 深色配色：primary 淡蓝、secondary 淡粉、surface 近黑
  static final ColorScheme darkScheme =
      ColorScheme.fromSeed(
        seedColor: const Color(0xffb5c7ff),
        brightness: Brightness.dark,
      ).copyWith(
        primary: const Color(0xffb5c7ff),
        secondary: const Color(0xffffb1c4),
        surface: const Color(0xff111318),
      );

  /// 浅色配色：primary 深蓝、secondary 深粉、surface 近白
  static final ColorScheme lightScheme =
      ColorScheme.fromSeed(seedColor: const Color(0xff475d92)).copyWith(
        primary: const Color(0xff475d92),
        secondary: const Color(0xff7b5261),
        surface: const Color(0xfff9f9ff),
      );

  /// 构建 MaterialApp 主题
  static ThemeData build(Brightness brightness) => ThemeData(
    colorScheme: brightness == Brightness.dark ? darkScheme : lightScheme,
  );
}
