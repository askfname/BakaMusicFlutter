package com.playlab.bakamusic

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.provider.DocumentsContract

/// 下载目录设置：默认使用公共 Music/BakaMusic，可选 SAF 自定义目录
object DownloadDirectoryStore {
    const val DEFAULT_LABEL = "Music/BakaMusic"

    private const val PREFS = "baka_downloads"
    private const val KEY_TREE_URI = "tree_uri"
    private const val KEY_LABEL = "label"

    /// 返回仍持有写权限的自定义目录；权限丢失时自动清理并回退默认目录
    fun treeUri(context: Context): Uri? {
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val raw = prefs.getString(KEY_TREE_URI, null) ?: return null
        val uri = runCatching { Uri.parse(raw) }.getOrNull() ?: return null
        val grant = context.contentResolver.persistedUriPermissions.firstOrNull {
            it.uri == uri && it.isWritePermission
        }
        if (grant == null) {
            clear(context)
            return null
        }
        return uri
    }

    fun current(context: Context): Map<String, Any?> {
        val uri = treeUri(context) ?: return mapOf(
            "label" to DEFAULT_LABEL,
            "custom" to false,
        )
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val label = queryLabel(context, uri)
            ?: prefs.getString(KEY_LABEL, null)?.takeIf { it.isNotBlank() }
            ?: "自定义目录"
        return mapOf("label" to label, "custom" to true)
    }

    fun save(context: Context, uri: Uri, label: String) {
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .edit()
            .putString(KEY_TREE_URI, uri.toString())
            .putString(KEY_LABEL, label)
            .apply()
    }

    fun clear(context: Context) {
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val raw = prefs.getString(KEY_TREE_URI, null)
        if (raw != null) {
            runCatching {
                val uri = Uri.parse(raw)
                val flags = Intent.FLAG_GRANT_READ_URI_PERMISSION or
                    Intent.FLAG_GRANT_WRITE_URI_PERMISSION
                context.contentResolver.releasePersistableUriPermission(uri, flags)
            }
        }
        prefs.edit().clear().apply()
    }

    /// 读取目录显示名，失败时退回文档 ID 的最后一段
    fun queryLabel(context: Context, uri: Uri): String? {
        runCatching {
            val documentId = DocumentsContract.getTreeDocumentId(uri)
            val documentUri = DocumentsContract.buildDocumentUriUsingTree(uri, documentId)
            context.contentResolver.query(
                documentUri,
                arrayOf(DocumentsContract.Document.COLUMN_DISPLAY_NAME),
                null,
                null,
                null,
            )?.use { cursor ->
                if (cursor.moveToFirst()) {
                    return cursor.getString(0)?.takeIf { it.isNotBlank() }
                }
            }
            return documentId.substringAfterLast(':')
                .substringAfterLast('/')
                .takeIf { it.isNotBlank() }
        }
        return null
    }
}
