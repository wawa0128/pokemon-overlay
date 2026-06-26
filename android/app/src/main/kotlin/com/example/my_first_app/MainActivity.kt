package com.example.my_first_app

import android.app.Activity
import android.content.Intent
import android.media.projection.MediaProjectionManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val channelName = "pokemon/ocr"
    private var pendingResult: MethodChannel.Result? = null
    private val reqCode = 4321
    private val mainHandler = Handler(Looper.getMainLooper())

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        setupOcrChannel(flutterEngine.dartExecutor.binaryMessenger)
    }

    /** OCR 채널을 주어진 엔진(메인 또는 오버레이)에 등록 */
    private fun setupOcrChannel(messenger: BinaryMessenger) {
        MethodChannel(messenger, channelName).setMethodCallHandler { call, result ->
            when (call.method) {
                "log" -> {
                    android.util.Log.d("PKMNOCR", call.arguments?.toString() ?: "")
                    result.success(true)
                }
                // 화면 캡처 권한 요청 (메인 액티비티에서만 호출됨)
                "requestProjection" -> {
                    if (ScreenCaptureService.isReady) {
                        result.success(true)
                    } else {
                        pendingResult = result
                        val mpm = getSystemService(MEDIA_PROJECTION_SERVICE)
                                as MediaProjectionManager
                        startActivityForResult(mpm.createScreenCaptureIntent(), reqCode)
                    }
                }
                "isProjectionReady" -> result.success(ScreenCaptureService.isReady)
                // 오버레이 엔진에도 이 채널을 등록 (메인이 showOverlay 직후 호출)
                "prepareOverlayEngine" -> {
                    try {
                        val overlayEngine =
                            FlutterEngineCache.getInstance().get("myCachedEngine")
                        if (overlayEngine != null) {
                            setupOcrChannel(overlayEngine.dartExecutor.binaryMessenger)
                            android.util.Log.d("PKMNOCR", "overlay engine channel registered")
                            result.success(true)
                        } else {
                            android.util.Log.d("PKMNOCR", "overlay engine not found")
                            result.success(false)
                        }
                    } catch (e: Exception) {
                        result.success(false)
                    }
                }
                // 캡처 + OCR 을 한 번에 (오버레이가 직접 호출) → 인식된 텍스트 줄 목록
                "captureAndOcr" -> {
                    val svc = ScreenCaptureService.instance
                    if (svc == null) {
                        result.error("NO_PROJECTION", "화면 캡처 권한이 없습니다", null)
                    } else {
                        svc.captureFrame { path ->
                            if (path == null) {
                                mainHandler.post { result.success(ArrayList<String>()) }
                            } else {
                                OcrEngine.recognize(applicationContext, path) { lines ->
                                    mainHandler.post { result.success(ArrayList(lines)) }
                                }
                            }
                        }
                    }
                }
                "stopProjection" -> {
                    stopService(Intent(this, ScreenCaptureService::class.java))
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == reqCode) {
            if (resultCode == Activity.RESULT_OK && data != null) {
                val intent = Intent(this, ScreenCaptureService::class.java).apply {
                    putExtra("resultCode", resultCode)
                    putExtra("data", data)
                }
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    startForegroundService(intent)
                } else {
                    startService(intent)
                }
                pendingResult?.success(true)
            } else {
                pendingResult?.success(false)
            }
            pendingResult = null
        }
    }
}
