/// 时长格式化：毫秒 → "分:秒"，无效值显示 0:00
String formatDuration(int milliseconds) {
  if (milliseconds <= 0) return '0:00';
  final seconds = milliseconds ~/ 1000;
  return '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';
}

/// 大小格式化：MB / KB，无效值显示 未知大小
String formatSize(int bytes) {
  if (bytes <= 0) return '未知大小';
  if (bytes < 1024 * 1024) return '${bytes ~/ 1024} KB';
  return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
}
