package com.playlab.bakamusic

import android.app.DownloadManager
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.Build
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import java.util.ArrayDeque
import java.util.concurrent.ConcurrentHashMap

/// 真实下载状态回传：成功/失败 + 歌曲名
/// - 默认目录：监听 DownloadManager 完成广播
/// - 自定义目录：由 DownloadService 直接上报
object DownloadEvents {
    private const val CHANNEL = "baka_music/download_events"
    private const val MAX_PENDING = 8

    private val mainHandler = Handler(Looper.getMainLooper())
    private val pending = ArrayDeque<Map<String, Any?>>()
    private val titles = ConcurrentHashMap<Long, String>()

    private var sink: EventChannel.EventSink? = null
    private var receiver: BroadcastReceiver? = null

    /// 注册事件通道与系统下载完成广播
    fun attach(context: Context, messenger: BinaryMessenger) {
        EventChannel(messenger, CHANNEL).setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(
                    arguments: Any?,
                    events: EventChannel.EventSink?,
                ) {
                    sink = events
                    flushPending()
                }

                override fun onCancel(arguments: Any?) {
                    sink = null
                }
            },
        )
        registerReceiver(context.applicationContext)
    }

    /// 登记 DownloadManager 任务，完成广播到达时据此找回歌曲名
    fun track(downloadId: Long, title: String) {
        if (titles.size >= 64) {
            titles.keys.firstOrNull()?.let(titles::remove)
        }
        titles[downloadId] = title
    }

    fun notifySuccess(title: String) = emit("success", title, "")

    fun notifyFailure(title: String, message: String) =
        emit("failure", title, message)

    private fun registerReceiver(context: Context) {
        if (receiver != null) return
        val target = object : BroadcastReceiver() {
            override fun onReceive(context: Context, intent: Intent) {
                if (intent.action != DownloadManager.ACTION_DOWNLOAD_COMPLETE) return
                val id = intent.getLongExtra(DownloadManager.EXTRA_DOWNLOAD_ID, -1L)
                if (id < 0) return
                // 非本应用登记的任务直接忽略
                val title = titles.remove(id) ?: return
                val manager = context.getSystemService(Context.DOWNLOAD_SERVICE)
                    as? DownloadManager
                val status = manager?.let { queryStatus(it, id) }
                    ?: DownloadManager.STATUS_FAILED
                if (status == DownloadManager.STATUS_SUCCESSFUL) {
                    notifySuccess(title)
                } else {
                    notifyFailure(title, "系统下载失败")
                }
            }
        }
        receiver = target
        val filter = IntentFilter(DownloadManager.ACTION_DOWNLOAD_COMPLETE)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            context.registerReceiver(target, filter, Context.RECEIVER_EXPORTED)
        } else {
            context.registerReceiver(target, filter)
        }
    }

    /// 查询任务状态；查询失败按失败处理
    private fun queryStatus(manager: DownloadManager, id: Long): Int {
        return runCatching {
            manager.query(DownloadManager.Query().setFilterById(id))?.use { cursor ->
                if (cursor.moveToFirst()) {
                    cursor.getInt(
                        cursor.getColumnIndexOrThrow(DownloadManager.COLUMN_STATUS),
                    )
                } else {
                    DownloadManager.STATUS_FAILED
                }
            } ?: DownloadManager.STATUS_FAILED
        }.getOrDefault(DownloadManager.STATUS_FAILED)
    }

    /// 事件统一切主线程发送；无监听时缓存，Flutter 订阅后补发
    private fun emit(status: String, title: String, message: String) {
        val payload = mapOf(
            "status" to status,
            "title" to title,
            "message" to message,
        )
        mainHandler.post {
            val target = sink
            if (target != null) {
                val sent = runCatching { target.success(payload) }.isSuccess
                if (sent) return@post
            }
            synchronized(pending) {
                if (pending.size >= MAX_PENDING) pending.removeFirst()
                pending.addLast(payload)
            }
        }
    }

    private fun flushPending() {
        mainHandler.post {
            val target = sink ?: return@post
            synchronized(pending) {
                while (pending.isNotEmpty()) {
                    val payload = pending.removeFirst()
                    if (runCatching { target.success(payload) }.isFailure) {
                        pending.addFirst(payload)
                        return@post
                    }
                }
            }
        }
    }
}
