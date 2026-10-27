import 'package:flutter/material.dart';

import '../util/download_helper.dart';
import 'app_toast.dart';

/// 开始下载提示：先读取本机目录标签（本地调用），再显示顶部 Toast，
Future<void> showDownloadStartedToast(BuildContext context) async {
  var label = DownloadDirectoryInfo.fallback.label;
  try {
    final directory = await DownloadHelper.directory();
    label = directory.label;
  } catch (_) {
    // 目录查询失败仍按默认目录提示，不阻断下载
  }
  if (!context.mounted) return;
  AppToast.show(context, '已开始下载到 $label', kind: AppToastKind.download);
}

/// 下载失败提示：带上歌曲名，便于用户定位失败的歌曲
void showDownloadFailureToast(BuildContext context, String title) {
  final name = title.trim();
  AppToast.show(
    context,
    name.isEmpty ? '下载失败' : '下载失败：$name',
    kind: AppToastKind.error,
  );
}
