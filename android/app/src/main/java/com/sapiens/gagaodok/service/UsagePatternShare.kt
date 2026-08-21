package com.sapiens.gagaodok.service

import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import androidx.core.content.FileProvider
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

internal fun writeUsagePatternExport(context: Context, json: String): Pair<String, android.net.Uri> {
    val fileName = "gagaodok-usage-pattern-${
        SimpleDateFormat("yyyyMMdd-HHmmss", Locale.US).format(Date())
    }.json"
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
        val resolver = context.contentResolver
        val values = ContentValues().apply {
            put(MediaStore.Downloads.DISPLAY_NAME, fileName)
            put(MediaStore.Downloads.MIME_TYPE, "application/json")
            put(MediaStore.Downloads.RELATIVE_PATH, "${Environment.DIRECTORY_DOWNLOADS}/Gagaodok")
            put(MediaStore.Downloads.IS_PENDING, 1)
        }
        val uri = checkNotNull(
            resolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values)
        ) { "통계 파일을 만들 수 없습니다." }
        try {
            checkNotNull(resolver.openOutputStream(uri)).bufferedWriter().use { it.write(json) }
            values.clear()
            values.put(MediaStore.Downloads.IS_PENDING, 0)
            resolver.update(uri, values, null, null)
            return fileName to uri
        } catch (error: Throwable) {
            resolver.delete(uri, null, null)
            throw error
        }
    }

    val exportDir = File(context.cacheDir, "exports").apply { mkdirs() }
    val file = File(exportDir, fileName).apply { writeText(json) }
    return fileName to FileProvider.getUriForFile(context, "${context.packageName}.files", file)
}

internal fun shareUsagePatternExport(context: Context, fileName: String, uri: android.net.Uri) {
    val sendIntent = Intent(Intent.ACTION_SEND).apply {
        type = "application/json"
        putExtra(Intent.EXTRA_STREAM, uri)
        putExtra(Intent.EXTRA_TITLE, fileName)
        addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
    }
    context.startActivity(Intent.createChooser(sendIntent, "사용 패턴 통계 공유"))
}
