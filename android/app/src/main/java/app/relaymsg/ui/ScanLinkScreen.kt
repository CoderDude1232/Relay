package app.relaymsg.ui

import android.Manifest
import android.content.pm.PackageManager
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.camera.core.CameraSelector
import androidx.camera.core.ImageAnalysis
import androidx.camera.core.ImageProxy
import androidx.camera.core.Preview
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.camera.view.PreviewView
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxScope
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.core.content.ContextCompat
import androidx.lifecycle.compose.LocalLifecycleOwner
import com.google.zxing.BarcodeFormat
import com.google.zxing.BinaryBitmap
import com.google.zxing.DecodeHintType
import com.google.zxing.MultiFormatReader
import com.google.zxing.PlanarYUVLuminanceSource
import com.google.zxing.common.HybridBinarizer
import java.util.concurrent.Executors

/**
 * Scans another device's linking QR.
 *
 * Decoding is ZXing over CameraX frames rather than ML Kit: it keeps Play
 * Services and a downloaded model out of the app, and one QR format is not worth
 * either. The camera stops the moment a code is recognised — [onScanned] fires
 * exactly once.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ScanLinkScreen(
    status: String?,
    error: String?,
    onScanned: (String) -> Unit,
    onBack: () -> Unit,
) {
    val context = LocalContext.current
    var granted by remember {
        mutableStateOf(
            ContextCompat.checkSelfPermission(context, Manifest.permission.CAMERA) ==
                PackageManager.PERMISSION_GRANTED,
        )
    }
    val request = rememberLauncherForActivityResult(
        ActivityResultContracts.RequestPermission(),
    ) { granted = it }
    LaunchedEffect(Unit) {
        if (!granted) request.launch(Manifest.permission.CAMERA)
    }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("Link a device") },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back")
                    }
                },
            )
        },
    ) { padding ->
        Box(Modifier.fillMaxSize().padding(padding)) {
            when {
                !granted -> Message(
                    "Relay needs the camera to scan the code shown on your other device.",
                )

                // Once a code is in hand the camera is no longer wanted; showing
                // progress also stops a second scan racing the first.
                status != null -> Message(status)

                else -> {
                    CameraPreview(onScanned)
                    Message(
                        "Point this at the code on the device you're adding.",
                        align = Alignment.BottomCenter,
                    )
                }
            }
            error?.let {
                Message(it, align = Alignment.BottomCenter, isError = true)
            }
        }
    }
}

@Composable
private fun BoxScope.Message(
    text: String,
    align: Alignment = Alignment.Center,
    isError: Boolean = false,
) = Text(
    text = text,
    style = MaterialTheme.typography.bodyLarge,
    textAlign = TextAlign.Center,
    color = if (isError) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.onSurface,
    modifier = Modifier.align(align).padding(24.dp),
)

@Composable
private fun CameraPreview(onScanned: (String) -> Unit) {
    val context = LocalContext.current
    val lifecycleOwner = LocalLifecycleOwner.current
    val analysisExecutor = remember { Executors.newSingleThreadExecutor() }
    // Latched so a QR held in frame for several frames only fires once.
    val handled = remember { java.util.concurrent.atomic.AtomicBoolean(false) }

    DisposableEffect(Unit) {
        onDispose { analysisExecutor.shutdown() }
    }

    AndroidView(
        modifier = Modifier.fillMaxSize(),
        factory = { ctx ->
            val previewView = PreviewView(ctx)
            val providerFuture = ProcessCameraProvider.getInstance(ctx)
            providerFuture.addListener({
                val provider = providerFuture.get()
                val preview = Preview.Builder().build().apply {
                    surfaceProvider = previewView.surfaceProvider
                }
                val analysis = ImageAnalysis.Builder()
                    .setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST)
                    .build()
                    .apply {
                        setAnalyzer(analysisExecutor) { image ->
                            val text = image.decodeQr()
                            image.close()
                            if (text != null && handled.compareAndSet(false, true)) {
                                previewView.post { onScanned(text) }
                            }
                        }
                    }

                runCatching {
                    provider.unbindAll()
                    provider.bindToLifecycle(
                        lifecycleOwner,
                        CameraSelector.DEFAULT_BACK_CAMERA,
                        preview,
                        analysis,
                    )
                }
            }, ContextCompat.getMainExecutor(ctx))
            previewView
        },
    )
}

private val reader = MultiFormatReader().apply {
    setHints(mapOf(DecodeHintType.POSSIBLE_FORMATS to listOf(BarcodeFormat.QR_CODE)))
}

/**
 * Decodes one camera frame, or null.
 *
 * CameraX hands back YUV_420_888; ZXing only needs the Y plane, which is the
 * luminance it would compute anyway. Row stride can exceed the width on some
 * devices, so the plane is copied row by row rather than in one go.
 */
private fun ImageProxy.decodeQr(): String? = runCatching {
    val plane = planes[0]
    val buffer = plane.buffer
    val rowStride = plane.rowStride
    val luminance = ByteArray(width * height)
    val row = ByteArray(rowStride)
    for (y in 0 until height) {
        buffer.position(y * rowStride)
        val available = minOf(rowStride, buffer.remaining())
        buffer.get(row, 0, available)
        row.copyInto(luminance, y * width, 0, minOf(width, available))
    }

    val source = PlanarYUVLuminanceSource(
        luminance, width, height, 0, 0, width, height, false,
    )
    reader.decodeWithState(BinaryBitmap(HybridBinarizer(source))).text
}.getOrNull().also { reader.reset() }
