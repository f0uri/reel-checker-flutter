package com.youssef.reelchecker

import android.content.ContentValues
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import android.provider.Settings
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.security.MessageDigest

/**
 * Native side of the "reelchecker" MethodChannel — the calls Dart
 * makes through lib/services/platform.dart:
 *  - getSignatureSha256: SHA-256 of the APK signing certificate
 *    (uppercase hex, no colons) — v4.4.6: the Dart side refuses to
 *    run a build that is not signed with our key.
 *  - getDeviceId: Settings.Secure.ANDROID_ID (survives reinstall /
 *    clear-data; changes only on factory reset or a new phone)
 *  - getDeviceModel / getVersionName / getVersionCode
 *  - getSharedText: text shared from Instagram (ACTION_SEND,
 *    text/plain) — consumed once per read; also delivered while the
 *    app is already running (launchMode singleTop + onNewIntent)
 *  - saveToDownloads: copy a file Dart already downloaded into the
 *    public Downloads folder (MediaStore on API 29+, direct file
 *    write below that — same as the native app's manual path)
 *  - updateApkPath / installApk: the OTA update APK in the
 *    app-private external files dir, opened with the installer via
 *    FileProvider (authority com.youssef.reelchecker.fileprovider)
 */
class MainActivity : FlutterActivity() {

    private var pendingSharedText: String? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        extractSharedText(intent)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "reelchecker")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "getDeviceId" -> result.success(
                        Settings.Secure.getString(
                            contentResolver, Settings.Secure.ANDROID_ID
                        )
                    )
                    "getSignatureSha256" -> result.success(getSignatureSha256())
                    "getDeviceModel" -> result.success(Build.MODEL)
                    "getVersionName" -> result.success(packageInfoVersionName())
                    "getVersionCode" -> result.success(packageInfoVersionCode())
                    "getSharedText" -> {
                        val text = pendingSharedText
                        pendingSharedText = null
                        result.success(text)
                    }
                    "saveToDownloads" -> {
                        val sourcePath = call.argument<String>("sourcePath") ?: ""
                        val fileName = call.argument<String>("fileName") ?: ""
                        val mimeType = call.argument<String>("mimeType")
                            ?: "application/octet-stream"
                        Thread {
                            result.success(
                                saveToDownloads(sourcePath, fileName, mimeType)
                            )
                        }.start()
                    }
                    "updateApkPath" -> result.success(updateApkFile().absolutePath)
                    "installApk" -> result.success(installApk())
                    else -> result.notImplemented()
                }
            }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        extractSharedText(intent)
    }

    private fun extractSharedText(intent: Intent?) {
        if (intent == null) return
        if (Intent.ACTION_SEND == intent.action && "text/plain" == intent.type) {
            val text = intent.getStringExtra(Intent.EXTRA_TEXT)
            if (!text.isNullOrBlank()) pendingSharedText = text
        }
    }

    /** SHA-256 of the APK signing certificate (uppercase hex, no
     *  colons). Empty string when it cannot be read — the Dart side
     *  treats that as "cannot verify" and allows the app, so a
     *  broken check never bricks the genuine build. */
    private fun getSignatureSha256(): String {
        return try {
            val info = if (Build.VERSION.SDK_INT >= 28) {
                packageManager.getPackageInfo(
                    packageName, PackageManager.GET_SIGNING_CERTIFICATES)
            } else {
                @Suppress("DEPRECATION")
                packageManager.getPackageInfo(
                    packageName, PackageManager.GET_SIGNATURES)
            }
            val sigs = if (Build.VERSION.SDK_INT >= 28) {
                info.signingInfo?.apkContentsSigners
            } else {
                @Suppress("DEPRECATION")
                info.signatures
            }
            val sig = sigs?.firstOrNull() ?: return ""
            val md = MessageDigest.getInstance("SHA-256")
            md.digest(sig.toByteArray()).joinToString("") { "%02X".format(it) }
        } catch (e: Exception) {
            ""
        }
    }

    private fun packageInfoVersionName(): String {
        return try {
            @Suppress("DEPRECATION")
            packageManager.getPackageInfo(packageName, 0).versionName ?: ""
        } catch (e: Exception) {
            ""
        }
    }

    private fun packageInfoVersionCode(): Int {
        return try {
            @Suppress("DEPRECATION")
            val info = packageManager.getPackageInfo(packageName, 0)
            if (Build.VERSION.SDK_INT >= 28) info.longVersionCode.toInt()
            else info.versionCode
        } catch (e: Exception) {
            0
        }
    }

    private fun updateApkFile(): File {
        return File(getExternalFilesDir(null), "reel-checker-update.apk")
    }

    private fun installApk(): Boolean {
        return try {
            val apk = updateApkFile()
            if (!apk.exists()) return false
            val uri: Uri = FileProvider.getUriForFile(
                this, "com.youssef.reelchecker.fileprovider", apk
            )
            val intent = Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(uri, "application/vnd.android.package-archive")
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
            startActivity(intent)
            true
        } catch (e: Exception) {
            false
        }
    }

    /** Copy [sourcePath] into the public Downloads folder as
     * [fileName]. Returns true on success. */
    private fun saveToDownloads(
        sourcePath: String,
        fileName: String,
        mimeType: String
    ): Boolean {
        val source = File(sourcePath)
        if (!source.exists() || fileName.isEmpty()) return false
        return try {
            if (Build.VERSION.SDK_INT >= 29) {
                val values = ContentValues().apply {
                    put(MediaStore.Downloads.DISPLAY_NAME, fileName)
                    put(MediaStore.Downloads.MIME_TYPE, mimeType)
                    put(
                        MediaStore.Downloads.RELATIVE_PATH,
                        Environment.DIRECTORY_DOWNLOADS
                    )
                    put(MediaStore.Downloads.IS_PENDING, 1)
                }
                val resolver = contentResolver
                val uri = resolver.insert(
                    MediaStore.Downloads.EXTERNAL_CONTENT_URI, values
                ) ?: return false
                try {
                    resolver.openOutputStream(uri)?.use { out ->
                        FileInputStream(source).use { input ->
                            input.copyTo(out)
                        }
                    } ?: return false
                    val ready = ContentValues().apply {
                        put(MediaStore.Downloads.IS_PENDING, 0)
                    }
                    resolver.update(uri, ready, null, null)
                    true
                } catch (e: Exception) {
                    try {
                        resolver.delete(uri, null, null)
                    } catch (ignored: Exception) {
                    }
                    false
                }
            } else {
                val dir = Environment.getExternalStoragePublicDirectory(
                    Environment.DIRECTORY_DOWNLOADS
                )
                if (!dir.exists()) dir.mkdirs()
                val dest = File(dir, fileName)
                FileInputStream(source).use { input ->
                    FileOutputStream(dest).use { out ->
                        input.copyTo(out)
                    }
                }
                dest.exists() && dest.length() > 0
            }
        } catch (e: Exception) {
            false
        }
    }
}
