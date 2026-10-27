package com.playlab.bakamusic

import android.app.DownloadManager
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Environment
import android.os.IBinder
import android.provider.DocumentsContract
import java.io.File
import java.io.IOException
import java.net.HttpURLConnection
import java.net.URL
import java.util.concurrent.ConcurrentLinkedQueue

/// 原生下载入口：默认目录交给系统 DownloadManager，自定义目录走前台服务写入 SAF
object DownloadCoordinator {
    private val invalidChars = Regex("[\\\\/:*?\"<>|]")

    fun enqueue(
        context: Context,
        url: String,
        headers: Map<String, String>,
        title: String,
        artist: String,
        qualityLabel: String,
        fileName: String,
        mimeType: String,
    ): String {
        require(url.startsWith("http://") || url.startsWith("https://")) {
            "下载地址必须为 HTTP(S)"
        }
        val safeName = sanitizeFileName(fileName, mimeType)
        val tree = DownloadDirectoryStore.treeUri(context)
        if (tree != null) {
            val label = DownloadDirectoryStore.current(context)["label"] as? String
                ?: "自定义目录"
            DownloadService.enqueue(
                context,
                DownloadRequest(
                    url = url,
                    headers = headers,
                    fileName = safeName,
                    mimeType = mimeType,
                    title = title,
                    artist = artist,
                    label = label,
                    treeUri = tree,
                ),
            )
            return "已开始下载到 $label"
        }
        return enqueueWithDownloadManager(
            context = context,
            url = url,
            headers = headers,
            title = title,
            artist = artist,
            qualityLabel = qualityLabel,
            fileName = safeName,
            mimeType = mimeType,
        )
    }

    private fun enqueueWithDownloadManager(
        context: Context,
        url: String,
        headers: Map<String, String>,
        title: String,
        artist: String,
        qualityLabel: String,
        fileName: String,
        mimeType: String,
    ): String {
        val manager = context.getSystemService(Context.DOWNLOAD_SERVICE) as DownloadManager
        val (base, ext) = splitName(fileName)
        val dir = File(
            Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_MUSIC),
            "BakaMusic",
        )
        runCatching { dir.mkdirs() }
        var candidate = File(dir, fileName)
        var index = 1
        while (candidate.exists()) {
            candidate = File(dir, "$base ($index)$ext")
            index++
        }
        val request = DownloadManager.Request(Uri.parse(url)).apply {
            setTitle("$title - $artist")
            setDescription("Baka Music · $qualityLabel")
            setMimeType(mimeType)
            setNotificationVisibility(
                DownloadManager.Request.VISIBILITY_VISIBLE_NOTIFY_COMPLETED,
            )
            setDestinationInExternalPublicDir(
                Environment.DIRECTORY_MUSIC,
                "BakaMusic/${candidate.name}",
            )
            setAllowedOverMetered(true)
            setAllowedOverRoaming(true)
            headers.forEach { (key, value) ->
                runCatching { addRequestHeader(key, value) }
            }
        }
        manager.enqueue(request).also { id ->
            // 登记任务，完成广播到达时用于回传歌曲名
            DownloadEvents.track(id, title)
        }
        return "已开始下载到 Music/BakaMusic"
    }

    private fun sanitizeFileName(fileName: String, mimeType: String): String {
        val fallbackExt = if (mimeType.contains("flac", ignoreCase = true)) {
            ".flac"
        } else {
            ".mp3"
        }
        val dot = fileName.lastIndexOf('.')
        val rawBase = if (dot > 0) fileName.substring(0, dot) else fileName
        val rawExt = if (dot > 0) fileName.substring(dot) else fallbackExt
        val base = rawBase
            .replace(invalidChars, "_")
            .trim()
            .ifEmpty { "audio" }
            .take(120)
        val ext = rawExt
            .replace(invalidChars, "_")
            .take(8)
            .ifEmpty { fallbackExt }
        return base + ext
    }

    private fun splitName(fileName: String): Pair<String, String> {
        val dot = fileName.lastIndexOf('.')
        return if (dot > 0) {
            fileName.substring(0, dot) to fileName.substring(dot)
        } else {
            fileName to ""
        }
    }
}

data class DownloadRequest(
    val url: String,
    val headers: Map<String, String>,
    val fileName: String,
    val mimeType: String,
    val title: String,
    val artist: String,
    val label: String,
    val treeUri: Uri,
)

/// 自定义目录下载服务：顺序处理队列，前台通知显示进度，完成后保留通知
class DownloadService : Service() {
    companion object {
        private const val CHANNEL_ID = "baka_downloads"
        private const val NOTIFICATION_ID = 9101
        private const val EXTRA_URL = "url"
        private const val EXTRA_HEADERS = "headers"
        private const val EXTRA_FILE_NAME = "file_name"
        private const val EXTRA_MIME = "mime"
        private const val EXTRA_TITLE = "title"
        private const val EXTRA_ARTIST = "artist"
        private const val EXTRA_LABEL = "label"
        private const val EXTRA_TREE = "tree"

        fun enqueue(context: Context, request: DownloadRequest) {
            val intent = Intent(context, DownloadService::class.java).apply {
                putExtra(EXTRA_URL, request.url)
                putExtra(
                    EXTRA_HEADERS,
                    Bundle().apply {
                        request.headers.forEach { (key, value) -> putString(key, value) }
                    },
                )
                putExtra(EXTRA_FILE_NAME, request.fileName)
                putExtra(EXTRA_MIME, request.mimeType)
                putExtra(EXTRA_TITLE, request.title)
                putExtra(EXTRA_ARTIST, request.artist)
                putExtra(EXTRA_LABEL, request.label)
                putExtra(EXTRA_TREE, request.treeUri.toString())
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }
    }

    private val queue = ConcurrentLinkedQueue<DownloadRequest>()
    private val lock = Any()
    private var worker: Thread? = null
    private var currentConnection: HttpURLConnection? = null
    @Volatile private var stopping = false

    override fun onCreate() {
        super.onCreate()
        stopping = false
        createChannel()
        startForeground(
            NOTIFICATION_ID,
            buildProgressNotification(null, 0, -1),
        )
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val request = intent?.let(::parseRequest)
        if (request != null) {
            queue.add(request)
            startWorker()
        } else if (queue.isEmpty() && worker == null) {
            finishService()
        }
        return START_NOT_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onDestroy() {
        stopping = true
        currentConnection?.disconnect()
        currentConnection = null
        worker?.interrupt()
        worker = null
        super.onDestroy()
    }

    private fun parseRequest(intent: Intent): DownloadRequest? {
        val url = intent.getStringExtra(EXTRA_URL) ?: return null
        val tree = intent.getStringExtra(EXTRA_TREE)?.let(Uri::parse) ?: return null
        val headers = intent.getBundleExtra(EXTRA_HEADERS)?.let { bundle ->
            bundle.keySet().associateWith { key -> bundle.getString(key) ?: "" }
        } ?: emptyMap()
        return DownloadRequest(
            url = url,
            headers = headers,
            fileName = intent.getStringExtra(EXTRA_FILE_NAME) ?: "audio.mp3",
            mimeType = intent.getStringExtra(EXTRA_MIME) ?: "audio/mpeg",
            title = intent.getStringExtra(EXTRA_TITLE) ?: "音乐下载",
            artist = intent.getStringExtra(EXTRA_ARTIST) ?: "",
            label = intent.getStringExtra(EXTRA_LABEL) ?: "自定义目录",
            treeUri = tree,
        )
    }

    private fun startWorker() {
        synchronized(lock) {
            if (worker?.isAlive == true) return
            worker = Thread({ drainQueue() }, "baka-download").also { it.start() }
        }
    }

    private fun drainQueue() {
        try {
            while (true) {
                val request = queue.poll() ?: break
                download(request)
            }
        } finally {
            synchronized(lock) { worker = null }
            if (queue.isEmpty()) {
                finishService()
            } else {
                startWorker()
            }
        }
    }

    private fun finishService() {
        @Suppress("DEPRECATION")
        stopForeground(false)
        stopSelf()
    }

    private fun download(request: DownloadRequest) {
        var outputUri: Uri? = null
        var connection: HttpURLConnection? = null
        try {
            notifyProgress(request, 0, -1)
            connection = (URL(request.url).openConnection() as HttpURLConnection).apply {
                connectTimeout = 15_000
                readTimeout = 30_000
                instanceFollowRedirects = true
                requestMethod = "GET"
                request.headers.forEach { (key, value) ->
                    runCatching { setRequestProperty(key, value) }
                }
            }
            currentConnection = connection
            val code = connection.responseCode
            if (code !in 200..299) throw IOException("HTTP $code")
            val total = connection.getHeaderField("Content-Length")?.toLongOrNull() ?: -1L
            val parent = DocumentsContract.buildDocumentUriUsingTree(
                request.treeUri,
                DocumentsContract.getTreeDocumentId(request.treeUri),
            )
            val displayName = uniqueChildName(
                request.treeUri,
                parent,
                request.fileName,
            )
            outputUri = DocumentsContract.createDocument(
                contentResolver,
                parent,
                request.mimeType,
                displayName,
            ) ?: throw IOException("无法在所选目录创建文件")
            val input = connection.inputStream
            val output = contentResolver.openOutputStream(outputUri, "w")
                ?: throw IOException("无法写入所选目录")
            input.use { source ->
                output.use { sink ->
                    val buffer = ByteArray(64 * 1024)
                    var bytes = 0L
                    var lastUpdate = 0L
                    while (true) {
                        if (stopping) throw IOException("下载已取消")
                        val read = source.read(buffer)
                        if (read < 0) break
                        sink.write(buffer, 0, read)
                        bytes += read
                        val now = System.currentTimeMillis()
                        if (now - lastUpdate >= 400) {
                            notifyProgress(request, bytes, total)
                            lastUpdate = now
                        }
                    }
                    sink.flush()
                }
            }
            notifySuccess(request)
        } catch (error: Exception) {
            outputUri?.let { uri ->
                runCatching { DocumentsContract.deleteDocument(contentResolver, uri) }
            }
            notifyFailure(request, error.message ?: "未知错误")
        } finally {
            currentConnection?.disconnect()
            currentConnection = null
        }
    }

    /// 查询目录下已有文件名，冲突时追加 (1)、(2)…
    private fun uniqueChildName(treeUri: Uri, parent: Uri, fileName: String): String {
        val existing = mutableSetOf<String>()
        runCatching {
            val childrenUri = DocumentsContract.buildChildDocumentsUriUsingTree(
                treeUri,
                DocumentsContract.getDocumentId(parent),
            )
            contentResolver.query(
                childrenUri,
                arrayOf(DocumentsContract.Document.COLUMN_DISPLAY_NAME),
                null,
                null,
                null,
            )?.use { cursor ->
                while (cursor.moveToNext()) {
                    cursor.getString(0)?.lowercase()?.let(existing::add)
                }
            }
        }
        val dot = fileName.lastIndexOf('.')
        val base = if (dot > 0) fileName.substring(0, dot) else fileName
        val ext = if (dot > 0) fileName.substring(dot) else ""
        var candidate = fileName
        var index = 1
        while (existing.contains(candidate.lowercase())) {
            candidate = "$base ($index)$ext"
            index++
        }
        return candidate
    }

    private fun createChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        val channel = NotificationChannel(
            CHANNEL_ID,
            "音乐下载",
            NotificationManager.IMPORTANCE_LOW,
        ).apply {
            description = "显示歌曲下载进度"
            setShowBadge(false)
        }
        manager.createNotificationChannel(channel)
    }

    private fun notifyProgress(request: DownloadRequest?, bytes: Long, total: Long) {
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        manager.notify(
            NOTIFICATION_ID,
            buildProgressNotification(request, bytes, total),
        )
    }

    private fun notifySuccess(request: DownloadRequest) {
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        val notification = baseBuilder("下载完成", request.title)
            .setSmallIcon(android.R.drawable.stat_sys_download_done)
            .setContentText("${request.artist} · 已保存到 ${request.label}")
            .setProgress(0, 0, false)
            .setOngoing(false)
            .setAutoCancel(true)
            .build()
        manager.notify(NOTIFICATION_ID, notification)
        DownloadEvents.notifySuccess(request.title)
    }

    private fun notifyFailure(request: DownloadRequest, message: String) {
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        val notification = baseBuilder("下载失败", request.title)
            .setSmallIcon(android.R.drawable.stat_notify_error)
            .setContentText(message.take(80))
            .setProgress(0, 0, false)
            .setOngoing(false)
            .setAutoCancel(true)
            .build()
        manager.notify(NOTIFICATION_ID, notification)
        DownloadEvents.notifyFailure(request.title, message)
    }

    private fun buildProgressNotification(
        request: DownloadRequest?,
        bytes: Long,
        total: Long,
    ): Notification {
        val title = request?.title ?: "准备下载"
        val text = request?.let { "${it.artist} · ${it.label}" } ?: "正在准备下载"
        val builder = baseBuilder(title, text)
            .setSmallIcon(android.R.drawable.stat_sys_download)
            .setOngoing(true)
            .setProgress(100, 0, true)
        if (request != null && total > 0) {
            val percent = ((bytes * 100) / total).toInt().coerceIn(0, 100)
            builder.setProgress(100, percent, false)
                .setSubText("$percent%")
        }
        return builder.build()
    }

    private fun baseBuilder(title: String, text: String): Notification.Builder {
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        return builder
            .setContentTitle(title)
            .setContentText(text)
            .setOnlyAlertOnce(true)
            .setContentIntent(openAppIntent())
    }

    private fun openAppIntent(): PendingIntent {
        val intent = Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }
        val flags = PendingIntent.FLAG_UPDATE_CURRENT or
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                PendingIntent.FLAG_IMMUTABLE
            } else {
                0
            }
        return PendingIntent.getActivity(this, 0, intent, flags)
    }
}
