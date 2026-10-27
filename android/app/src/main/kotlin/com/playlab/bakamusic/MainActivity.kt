package com.playlab.bakamusic

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.OpenableColumns
import android.view.WindowManager
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream

/// 宿主 Activity：承载 Flutter 引擎（audio_service 要求继承 AudioServiceActivity），
/// 并实现文件选择、屏幕常亮与下载目录/入队宿主通道
class MainActivity : AudioServiceActivity() {
    private var pendingPickResult: MethodChannel.Result? = null
    private var pendingDirectoryResult: MethodChannel.Result? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        requestNotificationPermissionIfNeeded()
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // 文件选择：ACTION_OPEN_DOCUMENT，返回 {name, bytes}，取消返回 null
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, FILE_PICKER_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "pickFile" -> pickFile(result)
                    else -> result.notImplemented()
                }
            }

        // 屏幕常亮：全屏歌词页进入/退出时切换 FLAG_KEEP_SCREEN_ON
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, SCREEN_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "setKeepScreenOn" -> {
                        val keepOn = call.arguments as? Boolean ?: false
                        if (keepOn) {
                            window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                        } else {
                            window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                        }
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }

        // 下载：目录选择/查询/重置 + 原生下载入队
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, DOWNLOAD_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "getDirectory" -> result.success(DownloadDirectoryStore.current(this))
                    "pickDirectory" -> pickDownloadDirectory(result)
                    "resetDirectory" -> {
                        DownloadDirectoryStore.clear(this)
                        result.success(DownloadDirectoryStore.current(this))
                    }
                    "enqueue" -> enqueueDownload(call, result)
                    else -> result.notImplemented()
                }
            }

        // 下载状态：默认目录监听系统完成广播，自定义目录由下载服务上报
        DownloadEvents.attach(this, flutterEngine.dartExecutor.binaryMessenger)
    }

    // ------------------------------------------------------------ 下载目录

    private fun pickDownloadDirectory(result: MethodChannel.Result) {
        if (pendingDirectoryResult != null) {
            result.error("busy", "已有目录选择正在进行", null)
            return
        }
        pendingDirectoryResult = result
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
            addFlags(
                Intent.FLAG_GRANT_READ_URI_PERMISSION or
                    Intent.FLAG_GRANT_WRITE_URI_PERMISSION or
                    Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION,
            )
        }
        @Suppress("DEPRECATION")
        startActivityForResult(intent, REQUEST_PICK_DIRECTORY)
    }

    private fun enqueueDownload(call: MethodCall, result: MethodChannel.Result) {
        val args = call.arguments as? Map<*, *> ?: run {
            result.error("bad_args", "下载参数无效", null)
            return
        }
        val url = (args["url"] as? String)?.trim().orEmpty()
        if (!url.startsWith("http://") && !url.startsWith("https://")) {
            result.error("bad_url", "下载地址必须为 HTTP(S)", null)
            return
        }
        val headers = (args["headers"] as? Map<*, *>)?.entries?.mapNotNull { entry ->
            val key = entry.key as? String
            val value = entry.value as? String
            if (key != null && value != null) key to value else null
        }?.toMap() ?: emptyMap()
        val fileName = (args["fileName"] as? String)?.takeIf { it.isNotBlank() }
            ?: "audio.mp3"
        val mimeType = (args["mimeType"] as? String)?.takeIf { it.isNotBlank() }
            ?: "audio/mpeg"
        val title = (args["title"] as? String)?.takeIf { it.isNotBlank() } ?: "音乐下载"
        val artist = (args["artist"] as? String).orEmpty()
        val qualityLabel = (args["qualityLabel"] as? String).orEmpty()
        try {
            val message = DownloadCoordinator.enqueue(
                context = this,
                url = url,
                headers = headers,
                title = title,
                artist = artist,
                qualityLabel = qualityLabel,
                fileName = fileName,
                mimeType = mimeType,
            )
            result.success(message)
        } catch (error: Exception) {
            result.error("enqueue_failed", error.message ?: "无法开始下载", null)
        }
    }

    // ------------------------------------------------------------ 文件选择

    private fun pickFile(result: MethodChannel.Result) {
        if (pendingPickResult != null) {
            result.error("busy", "已有文件选择正在进行", null)
            return
        }
        pendingPickResult = result
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = "*/*"
            putExtra(
                Intent.EXTRA_MIME_TYPES,
                arrayOf(
                    "application/javascript",
                    "text/javascript",
                    "application/json",
                    "text/plain",
                    "application/octet-stream",
                ),
            )
        }
        @Suppress("DEPRECATION")
        startActivityForResult(intent, REQUEST_PICK_FILE)
    }

    @Suppress("DEPRECATION")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode == REQUEST_PICK_DIRECTORY) {
            val result = pendingDirectoryResult
            pendingDirectoryResult = null
            if (result == null) return
            val uri = if (resultCode == RESULT_OK) data?.data else null
            if (uri == null) {
                result.success(null)
                return
            }
            try {
                val flags = Intent.FLAG_GRANT_READ_URI_PERMISSION or
                    Intent.FLAG_GRANT_WRITE_URI_PERMISSION
                contentResolver.takePersistableUriPermission(uri, flags)
                val label = DownloadDirectoryStore.queryLabel(this, uri)
                    ?: "自定义目录"
                DownloadDirectoryStore.save(this, uri, label)
                result.success(DownloadDirectoryStore.current(this))
            } catch (error: Exception) {
                result.error(
                    "directory_failed",
                    error.message ?: "无法保存目录权限",
                    null,
                )
            }
            return
        }
        if (requestCode == REQUEST_PICK_FILE) {
            val result = pendingPickResult
            pendingPickResult = null
            if (result == null) return
            val uri = if (resultCode == RESULT_OK) data?.data else null
            if (uri == null) {
                result.success(null)
                return
            }
            try {
                result.success(readFileMap(uri))
            } catch (error: Exception) {
                result.error("read_failed", error.message ?: "读取文件失败", null)
            }
            return
        }
        super.onActivityResult(requestCode, resultCode, data)
    }

    private fun readFileMap(uri: Uri): Map<String, Any?> {
        val bytes = contentResolver.openInputStream(uri)?.use { input ->
            ByteArrayOutputStream().use { output ->
                val buffer = ByteArray(64 * 1024)
                var total = 0
                while (true) {
                    val read = input.read(buffer)
                    if (read < 0) break
                    total += read
                    if (total > MAX_PICK_BYTES) {
                        throw IllegalStateException("文件超过 5 MiB 限制")
                    }
                    output.write(buffer, 0, read)
                }
                output.toByteArray()
            }
        } ?: throw IllegalStateException("无法打开文件")
        return mapOf("name" to queryDisplayName(uri), "bytes" to bytes)
    }

    private fun queryDisplayName(uri: Uri): String {
        contentResolver
            .query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)
            ?.use { cursor ->
                if (cursor.moveToFirst()) {
                    val index = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                    if (index >= 0) return cursor.getString(index) ?: ""
                }
            }
        return uri.lastPathSegment ?: ""
    }

    // ------------------------------------------------------------ 通知权限

    /// Android 13+ 需要运行时通知权限，前台播放通知才能显示
    private fun requestNotificationPermissionIfNeeded() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return
        if (checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) ==
            PackageManager.PERMISSION_GRANTED
        ) {
            return
        }
        requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), REQUEST_NOTIFICATIONS)
    }

    private companion object {
        const val FILE_PICKER_CHANNEL = "baka_music/file_picker"
        const val SCREEN_CHANNEL = "baka_music/screen"
        const val DOWNLOAD_CHANNEL = "baka_music/downloads"
        const val REQUEST_PICK_FILE = 1001
        const val REQUEST_PICK_DIRECTORY = 1003
        const val REQUEST_NOTIFICATIONS = 1002
        const val MAX_PICK_BYTES = 5 * 1024 * 1024
    }
}
