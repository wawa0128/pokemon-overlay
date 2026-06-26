package com.example.my_first_app

import android.content.Context
import android.net.Uri
import com.google.mlkit.vision.common.InputImage
import com.google.mlkit.vision.text.TextRecognition
import com.google.mlkit.vision.text.korean.KoreanTextRecognizerOptions
import java.io.File

/** 네이티브 ML Kit 한국어 OCR (오버레이/메인 어느 엔진에서 호출해도 동작) */
object OcrEngine {
    fun recognize(context: Context, path: String, callback: (List<String>) -> Unit) {
        try {
            val image = InputImage.fromFilePath(context, Uri.fromFile(File(path)))
            val recognizer =
                TextRecognition.getClient(KoreanTextRecognizerOptions.Builder().build())
            recognizer.process(image)
                .addOnSuccessListener { vt ->
                    val lines = ArrayList<String>()
                    for (block in vt.textBlocks) {
                        for (line in block.lines) {
                            if (line.text.isNotBlank()) lines.add(line.text)
                        }
                    }
                    if (lines.isEmpty() && vt.text.isNotBlank()) lines.add(vt.text)
                    android.util.Log.d("PKMNOCR", "ocr lines=${lines.size}: ${lines.joinToString("|")}")
                    recognizer.close()
                    callback(lines)
                }
                .addOnFailureListener { e ->
                    android.util.Log.e("PKMNOCR", "ocr fail", e)
                    recognizer.close()
                    callback(emptyList())
                }
        } catch (e: Exception) {
            android.util.Log.e("PKMNOCR", "ocr exception", e)
            callback(emptyList())
        }
    }
}
