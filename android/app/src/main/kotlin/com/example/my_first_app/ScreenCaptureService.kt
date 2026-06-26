package com.example.my_first_app

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.graphics.Bitmap
import android.graphics.PixelFormat
import android.hardware.display.DisplayManager
import android.hardware.display.VirtualDisplay
import android.media.ImageReader
import android.media.projection.MediaProjection
import android.media.projection.MediaProjectionManager
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.os.IBinder
import android.util.DisplayMetrics
import java.io.File
import java.io.FileOutputStream

/**
 * MediaProjection을 보유하고, 요청 시 화면 한 프레임을 PNG로 저장하는 포그라운드 서비스.
 */
class ScreenCaptureService : Service() {

    companion object {
        @Volatile var instance: ScreenCaptureService? = null
        val isReady: Boolean get() = instance?.projection != null
        private const val CHANNEL_ID = "screencap"
        private const val NOTI_ID = 99
    }

    private var projection: MediaProjection? = null
    private var imageReader: ImageReader? = null
    private var virtualDisplay: VirtualDisplay? = null
    private var width = 0
    private var height = 0
    private var density = 0
    private lateinit var handler: Handler
    private lateinit var handlerThread: HandlerThread

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        handlerThread = HandlerThread("capture").apply { start() }
        handler = Handler(handlerThread.looper)
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        startAsForeground()
        val resultCode = intent?.getIntExtra("resultCode", 0) ?: 0
        @Suppress("DEPRECATION")
        val data: Intent? = intent?.getParcelableExtra("data")
        if (resultCode != 0 && data != null) {
            setupProjection(resultCode, data)
        }
        instance = this
        return START_NOT_STICKY
    }

    private fun startAsForeground() {
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val ch = NotificationChannel(
                CHANNEL_ID, "화면 인식", NotificationManager.IMPORTANCE_LOW
            )
            nm.createNotificationChannel(ch)
        }
        val noti: Notification =
            Notification.Builder(this, CHANNEL_ID)
                .setContentTitle("포켓몬 약점 - 화면 인식 준비됨")
                .setSmallIcon(android.R.drawable.ic_menu_search)
                .build()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(
                NOTI_ID, noti,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION
            )
        } else {
            startForeground(NOTI_ID, noti)
        }
    }

    private fun setupProjection(resultCode: Int, data: Intent) {
        val mpm = getSystemService(Context.MEDIA_PROJECTION_SERVICE) as MediaProjectionManager
        val metrics = resources.displayMetrics
        width = metrics.widthPixels
        height = metrics.heightPixels
        density = metrics.densityDpi

        projection = mpm.getMediaProjection(resultCode, data)
        // Android 14+ 필수: 콜백 등록
        projection?.registerCallback(object : MediaProjection.Callback() {
            override fun onStop() {
                releaseProjection()
            }
        }, handler)

        imageReader = ImageReader.newInstance(
            width, height, PixelFormat.RGBA_8888, 2
        )
        virtualDisplay = projection?.createVirtualDisplay(
            "pkmn-capture",
            width, height, density,
            DisplayManager.VIRTUAL_DISPLAY_FLAG_AUTO_MIRROR,
            imageReader!!.surface, null, handler
        )
    }

    /** 최신 프레임을 PNG로 저장하고 경로를 콜백으로 반환 */
    fun captureFrame(callback: (String?) -> Unit) {
        handler.post {
            try {
                android.util.Log.d("PKMNOCR", "captureFrame start, reader=${imageReader != null}")
                var image = imageReader?.acquireLatestImage()
                var tries = 0
                while (image == null && tries < 10) {
                    Thread.sleep(50)
                    image = imageReader?.acquireLatestImage()
                    tries++
                }
                if (image == null) {
                    callback(null); return@post
                }
                val plane = image.planes[0]
                val buffer = plane.buffer
                val pixelStride = plane.pixelStride
                val rowStride = plane.rowStride
                val rowPadding = rowStride - pixelStride * width
                val bmp = Bitmap.createBitmap(
                    width + rowPadding / pixelStride, height, Bitmap.Config.ARGB_8888
                )
                bmp.copyPixelsFromBuffer(buffer)
                image.close()
                val cropped = Bitmap.createBitmap(bmp, 0, 0, width, height)
                bmp.recycle()

                val file = File(cacheDir, "screen.png")
                FileOutputStream(file).use { out ->
                    cropped.compress(Bitmap.CompressFormat.PNG, 100, out)
                }
                cropped.recycle()
                android.util.Log.d("PKMNOCR", "captureFrame saved: ${file.absolutePath}")
                callback(file.absolutePath)
            } catch (e: Exception) {
                android.util.Log.e("PKMNOCR", "captureFrame error", e)
                callback(null)
            }
        }
    }

    private fun releaseProjection() {
        virtualDisplay?.release(); virtualDisplay = null
        imageReader?.close(); imageReader = null
        projection = null
    }

    override fun onDestroy() {
        releaseProjection()
        handlerThread.quitSafely()
        instance = null
        super.onDestroy()
    }
}
