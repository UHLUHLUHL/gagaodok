package com.sapiens.gagaodok.ui.screens

import android.view.ViewGroup
import androidx.camera.core.CameraSelector
import androidx.camera.core.ImageAnalysis
import androidx.camera.core.ImageProxy
import androidx.camera.core.Preview
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.camera.view.PreviewView
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.core.content.ContextCompat
import androidx.lifecycle.compose.LocalLifecycleOwner
import com.google.mlkit.vision.barcode.BarcodeScanner
import com.google.mlkit.vision.barcode.BarcodeScannerOptions
import com.google.mlkit.vision.barcode.BarcodeScanning
import com.google.mlkit.vision.barcode.common.Barcode
import com.google.mlkit.vision.common.InputImage
import com.sapiens.gagaodok.sync.SyncPairingScanGate
import com.sapiens.gagaodok.ui.theme.KakaoText
import com.sapiens.gagaodok.ui.theme.KakaoTheme

@Composable
fun SyncPairingScanner(onScanned: (String) -> Unit, onCancel: () -> Unit) {
    val context = LocalContext.current
    val lifecycleOwner = LocalLifecycleOwner.current
    val colors = KakaoTheme.colors
    val executor = remember(context) { ContextCompat.getMainExecutor(context) }
    val gate = remember(onScanned) { SyncPairingScanGate(onScanned) }
    val scanner = remember {
        val options = BarcodeScannerOptions.Builder()
            .setBarcodeFormats(Barcode.FORMAT_QR_CODE)
            .build()
        BarcodeScanning.getClient(options)
    }
    val providerFuture = remember(context) { ProcessCameraProvider.getInstance(context) }
    val previewView = remember(context) {
        PreviewView(context).apply {
            layoutParams = ViewGroup.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.MATCH_PARENT,
            )
            scaleType = PreviewView.ScaleType.FILL_CENTER
        }
    }

    DisposableEffect(lifecycleOwner, scanner) {
        val bind = Runnable {
            val provider = providerFuture.get()
            val preview = Preview.Builder().build().also { it.surfaceProvider = previewView.surfaceProvider }
            val analysis = ImageAnalysis.Builder()
                .setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST)
                .build()
                .also { it.setAnalyzer(executor, PairingQrAnalyzer(scanner, gate)) }
            provider.unbindAll()
            provider.bindToLifecycle(lifecycleOwner, CameraSelector.DEFAULT_BACK_CAMERA, preview, analysis)
        }
        providerFuture.addListener(bind, executor)
        onDispose {
            if (providerFuture.isDone) runCatching { providerFuture.get().unbindAll() }
            scanner.close()
        }
    }

    Box(Modifier.fillMaxSize().background(colors.surface)) {
        AndroidView(factory = { previewView }, modifier = Modifier.fillMaxSize())
        Text(
            "가가오독 합류 QR을 사각형 안에 맞추세요",
            style = KakaoText.caption,
            color = colors.textPrimary,
            modifier = Modifier
                .align(Alignment.TopCenter)
                .padding(18.dp)
                .background(colors.surface)
                .padding(horizontal = 12.dp, vertical = 8.dp),
        )
        Text(
            "취소",
            style = KakaoText.listName,
            color = colors.textPrimary,
            modifier = Modifier
                .align(Alignment.BottomCenter)
                .padding(24.dp)
                .background(colors.surface)
                .clickable(onClick = onCancel)
                .padding(horizontal = 18.dp, vertical = 10.dp),
        )
    }
}

private class PairingQrAnalyzer(
    private val scanner: BarcodeScanner,
    private val gate: SyncPairingScanGate,
) : ImageAnalysis.Analyzer {
    override fun analyze(imageProxy: ImageProxy) {
        val mediaImage = imageProxy.image
        if (mediaImage == null) {
            imageProxy.close()
            return
        }
        val image = InputImage.fromMediaImage(mediaImage, imageProxy.imageInfo.rotationDegrees)
        scanner.process(image)
            .addOnSuccessListener { codes ->
                codes.firstOrNull { it.format == Barcode.FORMAT_QR_CODE }
                    ?.rawValue
                    ?.let(gate::offer)
            }
            .addOnCompleteListener { imageProxy.close() }
    }
}
