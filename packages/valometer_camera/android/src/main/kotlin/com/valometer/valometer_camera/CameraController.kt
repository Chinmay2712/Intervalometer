package com.valometer.valometer_camera

import android.annotation.SuppressLint
import android.content.Context
import android.graphics.ImageFormat
import android.graphics.SurfaceTexture
import android.hardware.camera2.CameraCaptureSession
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraDevice
import android.hardware.camera2.CameraManager
import android.hardware.camera2.CaptureFailure
import android.hardware.camera2.CaptureRequest
import android.hardware.camera2.CaptureResult
import android.hardware.camera2.DngCreator
import android.hardware.camera2.TotalCaptureResult
import android.hardware.camera2.params.OutputConfiguration
import android.hardware.camera2.params.SessionConfiguration
import android.media.ExifInterface
import android.media.Image
import android.media.ImageReader
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.util.Size
import io.flutter.view.TextureRegistry
import java.io.File
import java.io.FileOutputStream
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.concurrent.Executor
import kotlin.math.abs
import kotlin.math.min

/**
 * One opened back camera, driven through Camera2 with full manual control.
 * All camera work runs on [handler]'s thread; callbacks are invoked on that thread.
 */
class CameraController(
    private val context: Context,
    textures: TextureRegistry,
    private val cameraId: String,
) {
    private val manager = context.getSystemService(Context.CAMERA_SERVICE) as CameraManager
    private val chars: CameraCharacteristics = manager.getCameraCharacteristics(cameraId)

    private val thread = HandlerThread("ValometerCamera").apply { start() }
    private val handler = Handler(thread.looper)
    private val executor = Executor { handler.post(it) }

    private val producer: TextureRegistry.SurfaceProducer = textures.createSurfaceProducer()

    private var device: CameraDevice? = null
    private var session: CameraCaptureSession? = null
    private val saver = java.util.concurrent.Executors.newSingleThreadExecutor()
    private var jpegReader: ImageReader? = null
    private var rawReader: ImageReader? = null
    private var pendingShot: PendingShot? = null
    private var closed = false

    // ---- Static camera facts ----

    private val capabilities = chars.get(CameraCharacteristics.REQUEST_AVAILABLE_CAPABILITIES)?.toSet() ?: emptySet()
    private val manualSensor = CameraCharacteristics.REQUEST_AVAILABLE_CAPABILITIES_MANUAL_SENSOR in capabilities
    private val sensorOrientation = chars.get(CameraCharacteristics.SENSOR_ORIENTATION) ?: 90
    private val isoRange = chars.get(CameraCharacteristics.SENSOR_INFO_SENSITIVITY_RANGE)
    private val exposureRange = chars.get(CameraCharacteristics.SENSOR_INFO_EXPOSURE_TIME_RANGE)
    private val minFocusDiopters = chars.get(CameraCharacteristics.LENS_INFO_MINIMUM_FOCUS_DISTANCE) ?: 0f
    private val awbModes = chars.get(CameraCharacteristics.CONTROL_AWB_AVAILABLE_MODES)?.toSet() ?: emptySet()
    private val afModes = chars.get(CameraCharacteristics.CONTROL_AF_AVAILABLE_MODES)?.toSet() ?: emptySet()
    private val streamMap = chars.get(CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP)
    private val rawSize: Size? =
        if (CameraCharacteristics.REQUEST_AVAILABLE_CAPABILITIES_RAW in capabilities)
            streamMap?.getOutputSizes(ImageFormat.RAW_SENSOR)?.maxByOrNull { it.width.toLong() * it.height }
        else null

    /** Android 16+ can set an exact colour temperature (CCT mode). */
    private val cctRange: android.util.Range<Int>? =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.BAKLAVA) {
            val modes = chars.get(CameraCharacteristics.COLOR_CORRECTION_AVAILABLE_MODES)?.toSet() ?: emptySet()
            if (CaptureRequest.COLOR_CORRECTION_MODE_CCT in modes)
                chars.get(CameraCharacteristics.COLOR_CORRECTION_COLOR_TEMPERATURE_RANGE)
            else null
        } else null

    // ---- User-controlled state (read on the camera thread) ----

    @Volatile private var autoExposure = true
    @Volatile private var iso = 800
    @Volatile private var exposureNs = 1_000_000_000L / 30
    @Volatile private var autoWb = true
    @Volatile private var kelvin = 4000
    @Volatile private var autoFocus = true
    @Volatile private var focusPosition = 1.0 // 1 = infinity

    // ---- Lifecycle ----

    @SuppressLint("MissingPermission") // checked by the plugin before open()
    fun open(callback: (kotlin.Result<Map<String, Any?>>) -> Unit) {
        producer.setCallback(object : TextureRegistry.SurfaceProducer.Callback {
            override fun onSurfaceAvailable() {
                handler.post { if (device != null && !closed) createSession(null) }
            }

            override fun onSurfaceCleanup() {
                handler.post {
                    session?.close()
                    session = null
                }
            }
        })

        val previewSize = choosePreviewSize()
        producer.setSize(previewSize.width, previewSize.height)

        try {
            manager.openCamera(cameraId, object : CameraDevice.StateCallback() {
                override fun onOpened(camera: CameraDevice) {
                    if (closed) {
                        camera.close()
                        return
                    }
                    device = camera
                    createSession { ok ->
                        callback(
                            if (ok) kotlin.Result.success(describe(previewSize))
                            else kotlin.Result.failure(IllegalStateException("Could not start the camera session."))
                        )
                    }
                }

                override fun onDisconnected(camera: CameraDevice) {
                    camera.close()
                    device = null
                }

                override fun onError(camera: CameraDevice, error: Int) {
                    camera.close()
                    device = null
                    callback(kotlin.Result.failure(IllegalStateException("Camera error $error")))
                }
            }, handler)
        } catch (e: Exception) {
            callback(kotlin.Result.failure(e))
        }
    }

    fun close() {
        closed = true
        handler.post {
            pendingShot?.fail(IllegalStateException("Camera closed."))
            pendingShot = null
            session?.close()
            device?.close()
            jpegReader?.close()
            rawReader?.close()
            session = null
            device = null
            producer.release()
            saver.shutdown()
            thread.quitSafely()
        }
    }

    private fun choosePreviewSize(): Size {
        val sizes = streamMap?.getOutputSizes(SurfaceTexture::class.java) ?: return Size(1440, 1080)
        val fourByThree = sizes.filter { abs(it.width.toDouble() / it.height - 4.0 / 3.0) < 0.01 && it.width <= 1920 }
        return fourByThree.maxByOrNull { it.width.toLong() * it.height }
            ?: sizes.minByOrNull { abs(it.width - 1440) }
            ?: Size(1440, 1080)
    }

    private fun createSession(onDone: ((Boolean) -> Unit)?) {
        val cam = device ?: return onDone?.invoke(false) ?: Unit

        if (jpegReader == null) {
            val jpegSize = streamMap?.getOutputSizes(ImageFormat.JPEG)?.maxByOrNull { it.width.toLong() * it.height }
                ?: Size(4000, 3000)
            jpegReader = ImageReader.newInstance(jpegSize.width, jpegSize.height, ImageFormat.JPEG, 2).apply {
                setOnImageAvailableListener({ r -> onJpeg(r) }, handler)
            }
            rawSize?.let { s ->
                rawReader = ImageReader.newInstance(s.width, s.height, ImageFormat.RAW_SENSOR, 2).apply {
                    setOnImageAvailableListener({ r -> onRaw(r) }, handler)
                }
            }
        }

        val outputs = mutableListOf(
            OutputConfiguration(producer.surface),
            OutputConfiguration(jpegReader!!.surface),
        )
        rawReader?.let { outputs += OutputConfiguration(it.surface) }

        val config = SessionConfiguration(
            SessionConfiguration.SESSION_REGULAR,
            outputs,
            executor,
            object : CameraCaptureSession.StateCallback() {
                override fun onConfigured(s: CameraCaptureSession) {
                    session = s
                    startPreview()
                    onDone?.invoke(true)
                }

                override fun onConfigureFailed(s: CameraCaptureSession) {
                    onDone?.invoke(false)
                }
            }
        )
        try {
            cam.createCaptureSession(config)
        } catch (e: Exception) {
            onDone?.invoke(false)
        }
    }

    private fun describe(previewSize: Size): Map<String, Any?> {
        val turns = if (producer.handlesCropAndRotation()) 0 else sensorOrientation / 90
        val focal = chars.get(CameraCharacteristics.LENS_INFO_AVAILABLE_FOCAL_LENGTHS)?.firstOrNull()
        val sensorSize = chars.get(CameraCharacteristics.SENSOR_INFO_PHYSICAL_SIZE)
        val pixelArray = chars.get(CameraCharacteristics.SENSOR_INFO_PIXEL_ARRAY_SIZE)
        val pixelPitchUm = if (sensorSize != null && pixelArray != null && pixelArray.width > 0)
            sensorSize.width * 1000.0 / pixelArray.width else null
        val fieldOfView = if (sensorSize != null && focal != null && focal > 0f)
            Math.toDegrees(2 * kotlin.math.atan(sensorSize.width / (2.0 * focal))) else null
        val minK = cctRange?.lower ?: 2500
        val maxK = cctRange?.upper ?: 8000
        return mapOf(
            "textureId" to producer.id(),
            "previewAspect" to min(previewSize.width, previewSize.height).toDouble() /
                maxOf(previewSize.width, previewSize.height),
            "previewQuarterTurns" to turns,
            "minIso" to (isoRange?.lower ?: 100).toDouble(),
            "maxIso" to (isoRange?.upper ?: 3200).toDouble(),
            "minShutter" to (exposureRange?.lower ?: 100_000L) / 1e9,
            "maxShutter" to (exposureRange?.upper ?: 1_000_000_000L) / 1e9,
            "minKelvin" to minK.toDouble(),
            "maxKelvin" to maxK.toDouble(),
            "supportsManualExposure" to (manualSensor && isoRange != null && exposureRange != null),
            "supportsManualWhiteBalance" to (cctRange != null || awbModes.size > 2),
            "supportsManualFocus" to (manualSensor && minFocusDiopters > 0f),
            "supportsRaw" to (rawReader != null),
            "formats" to buildMap {
                put("jpeg", "native")
                if (ImageConverter.heicSupported) put("heic", "converted")
                put("png", "converted")
                put("tiff", "converted")
                if (rawReader != null) put("dng", "native")
            },
            "aperture" to chars.get(CameraCharacteristics.LENS_INFO_AVAILABLE_APERTURES)?.firstOrNull()?.toDouble(),
            "focalLength" to focal?.toDouble(),
            "fieldOfView" to fieldOfView,
            "sensorWidthMm" to sensorSize?.width?.toDouble(),
            "pixelPitchUm" to pixelPitchUm,
            "activeLensId" to cameraId,
        )
    }

    // ---- Controls ----

    fun setExposure(auto: Boolean, iso: Double?, shutterSeconds: Double?) {
        autoExposure = auto || !manualSensor
        iso?.let { v -> this.iso = clampIso(v.toInt()) }
        shutterSeconds?.let { s -> exposureNs = clampExposure((s * 1e9).toLong()) }
        handler.post { startPreview() }
    }

    fun setWhiteBalance(auto: Boolean, kelvin: Double?) {
        autoWb = auto
        kelvin?.let { this.kelvin = it.toInt() }
        handler.post { startPreview() }
    }

    fun setFocus(auto: Boolean, position: Double?) {
        autoFocus = auto || !manualSensor || minFocusDiopters <= 0f
        position?.let { focusPosition = it.coerceIn(0.0, 1.0) }
        handler.post { startPreview() }
    }

    private fun clampIso(v: Int) = isoRange?.let { v.coerceIn(it.lower, it.upper) } ?: v
    private fun clampExposure(v: Long) = exposureRange?.let { v.coerceIn(it.lower, it.upper) } ?: v

    private fun startPreview() {
        val cam = device ?: return
        val s = session ?: return
        try {
            val b = cam.createCaptureRequest(CameraDevice.TEMPLATE_PREVIEW)
            b.addTarget(producer.surface)
            applyControls(b, forPreview = true)
            s.setRepeatingRequest(b.build(), null, handler)
        } catch (_: Exception) {
            // Session may be closing; the next open() will restart the preview.
        }
    }

    private fun applyControls(b: CaptureRequest.Builder, forPreview: Boolean) {
        b.set(CaptureRequest.CONTROL_MODE, CaptureRequest.CONTROL_MODE_AUTO)

        // Exposure
        if (autoExposure) {
            b.set(CaptureRequest.CONTROL_AE_MODE, CaptureRequest.CONTROL_AE_MODE_ON)
        } else {
            var exp = exposureNs
            var sens = iso
            // Keep the live view responsive: cap preview frames at 1/4 s and
            // brighten with ISO instead, so framing still works with 30 s shots.
            if (forPreview && exp > PREVIEW_MAX_EXPOSURE_NS) {
                sens = clampIso((sens.toDouble() * exp / PREVIEW_MAX_EXPOSURE_NS).toInt())
                exp = PREVIEW_MAX_EXPOSURE_NS
            }
            b.set(CaptureRequest.CONTROL_AE_MODE, CaptureRequest.CONTROL_AE_MODE_OFF)
            b.set(CaptureRequest.SENSOR_EXPOSURE_TIME, exp)
            b.set(CaptureRequest.SENSOR_SENSITIVITY, sens)
            b.set(CaptureRequest.SENSOR_FRAME_DURATION, exp)
        }

        // White balance
        if (autoWb) {
            b.set(CaptureRequest.CONTROL_AWB_MODE, CaptureRequest.CONTROL_AWB_MODE_AUTO)
        } else if (cctRange != null && Build.VERSION.SDK_INT >= Build.VERSION_CODES.BAKLAVA) {
            b.set(CaptureRequest.CONTROL_AWB_MODE, CaptureRequest.CONTROL_AWB_MODE_OFF)
            b.set(CaptureRequest.COLOR_CORRECTION_MODE, CaptureRequest.COLOR_CORRECTION_MODE_CCT)
            b.set(CaptureRequest.COLOR_CORRECTION_COLOR_TEMPERATURE, kelvin.coerceIn(cctRange.lower, cctRange.upper))
            b.set(CaptureRequest.COLOR_CORRECTION_COLOR_TINT, 0)
        } else {
            b.set(CaptureRequest.CONTROL_AWB_MODE, awbPresetFor(kelvin))
        }

        // Focus
        if (autoFocus) {
            if (CaptureRequest.CONTROL_AF_MODE_CONTINUOUS_PICTURE in afModes) {
                b.set(CaptureRequest.CONTROL_AF_MODE, CaptureRequest.CONTROL_AF_MODE_CONTINUOUS_PICTURE)
            }
        } else {
            b.set(CaptureRequest.CONTROL_AF_MODE, CaptureRequest.CONTROL_AF_MODE_OFF)
            // Diopters: 0 = infinity, minFocusDiopters = closest.
            b.set(CaptureRequest.LENS_FOCUS_DISTANCE, ((1.0 - focusPosition) * minFocusDiopters).toFloat())
        }
    }

    /** Fallback for phones without CCT mode: nearest AWB preset. */
    private fun awbPresetFor(k: Int): Int {
        val presets = listOf(
            2700 to CaptureRequest.CONTROL_AWB_MODE_INCANDESCENT,
            3000 to CaptureRequest.CONTROL_AWB_MODE_WARM_FLUORESCENT,
            4200 to CaptureRequest.CONTROL_AWB_MODE_FLUORESCENT,
            5500 to CaptureRequest.CONTROL_AWB_MODE_DAYLIGHT,
            6500 to CaptureRequest.CONTROL_AWB_MODE_CLOUDY_DAYLIGHT,
            7500 to CaptureRequest.CONTROL_AWB_MODE_SHADE,
        ).filter { it.second in awbModes }
        return presets.minByOrNull { abs(it.first - k) }?.second ?: CaptureRequest.CONTROL_AWB_MODE_AUTO
    }

    // ---- Capture ----

    /**
     * [format]: "jpeg", "heic", "png", "tiff" or "none" (RAW only). The JPEG
     * is always kept in the app as a working copy; other formats are
     * converted from it.
     */
    fun capture(format: String, raw: Boolean, callback: (kotlin.Result<Map<String, Any?>>) -> Unit) {
        handler.post {
            val cam = device
            val s = session
            val jpeg = jpegReader
            if (cam == null || s == null || jpeg == null) {
                callback(kotlin.Result.failure(IllegalStateException("Camera is not ready.")))
                return@post
            }
            if (pendingShot != null) {
                callback(kotlin.Result.failure(IllegalStateException("Still saving the previous photo.")))
                return@post
            }
            val wantRaw = raw && rawReader != null
            if (format == "none" && !wantRaw) {
                callback(kotlin.Result.failure(IllegalStateException("This camera can't shoot RAW.")))
                return@post
            }
            val shot = PendingShot(format, wantRaw, callback)
            pendingShot = shot

            try {
                val b = cam.createCaptureRequest(CameraDevice.TEMPLATE_STILL_CAPTURE)
                b.addTarget(jpeg.surface)
                if (wantRaw) {
                    b.addTarget(rawReader!!.surface)
                    b.set(CaptureRequest.STATISTICS_LENS_SHADING_MAP_MODE, CaptureRequest.STATISTICS_LENS_SHADING_MAP_MODE_ON)
                }
                applyControls(b, forPreview = false)
                b.set(CaptureRequest.JPEG_ORIENTATION, sensorOrientation)
                // Converted formats start from a near-lossless JPEG.
                b.set(CaptureRequest.JPEG_QUALITY, (if (format == "jpeg" || format == "none") 95 else 100).toByte())

                s.capture(b.build(), object : CameraCaptureSession.CaptureCallback() {
                    override fun onCaptureCompleted(
                        session: CameraCaptureSession,
                        request: CaptureRequest,
                        result: TotalCaptureResult
                    ) {
                        shot.result = result
                        tryFinish(shot)
                    }

                    override fun onCaptureFailed(
                        session: CameraCaptureSession,
                        request: CaptureRequest,
                        failure: CaptureFailure
                    ) {
                        failShot(shot, IllegalStateException("Capture failed (reason ${failure.reason})."))
                    }
                }, handler)

                // Safety net: never leave Dart waiting forever.
                val timeoutMs = (if (autoExposure) 0L else exposureNs / 1_000_000) + 15_000
                handler.postDelayed({
                    if (pendingShot === shot) failShot(shot, IllegalStateException("Capture timed out."))
                }, timeoutMs)
            } catch (e: Exception) {
                failShot(shot, e)
            }
        }
    }

    private fun onJpeg(reader: ImageReader) {
        val image = reader.acquireNextImage() ?: return
        val shot = pendingShot
        if (shot == null) {
            image.close()
            return
        }
        val buffer = image.planes[0].buffer
        shot.jpeg = ByteArray(buffer.remaining()).also { buffer.get(it) }
        image.close()
        tryFinish(shot)
    }

    private fun onRaw(reader: ImageReader) {
        val image = reader.acquireNextImage() ?: return
        val shot = pendingShot
        if (shot == null) {
            image.close()
            return
        }
        shot.raw?.close()
        shot.raw = image
        tryFinish(shot)
    }

    private fun failShot(shot: PendingShot, e: Throwable) {
        if (pendingShot === shot) pendingShot = null
        shot.fail(e)
    }

    private fun tryFinish(shot: PendingShot) {
        if (pendingShot !== shot) return
        val jpeg = shot.jpeg ?: return
        val result = shot.result ?: return
        if (shot.wantRaw && shot.raw == null) return
        pendingShot = null

        // Writing/converting can take seconds: keep it off the camera thread.
        saver.execute { saveShot(shot, jpeg, result) }
    }

    private fun saveShot(shot: PendingShot, jpeg: ByteArray, result: CaptureResult) {
        try {
            val dir = framesDirectory(context)
            val stamp = SimpleDateFormat("yyyyMMdd_HHmmss_SSS", Locale.US).format(Date())
            val out = mutableMapOf<String, Any?>()

            val jpegFile = File(dir, "VAL_$stamp.jpg")
            jpegFile.writeBytes(jpeg)
            out["jpegPath"] = jpegFile.absolutePath
            val gallery = mutableMapOf<String, String>()
            out["gallery"] = gallery
            when (shot.format) {
                "jpeg" -> {
                    gallery[jpegFile.absolutePath] = MediaTools.saveToGallery(context, jpegFile, "image/jpeg")
                    out["photoPath"] = jpegFile.absolutePath
                }
                "heic", "png", "tiff" -> {
                    val ext = if (shot.format == "tiff") "tif" else shot.format
                    val file = File(dir, "VAL_$stamp.$ext")
                    ImageConverter.convert(jpeg, shot.format, file)
                    gallery[file.absolutePath] = MediaTools.saveToGallery(context, file, "image/${shot.format}")
                    out["photoPath"] = file.absolutePath
                }
            }

            shot.raw?.let { rawImage ->
                val dngFile = File(dir, "VAL_$stamp.dng")
                DngCreator(chars, result).use { dng ->
                    dng.setOrientation(exifOrientation())
                    FileOutputStream(dngFile).use { dng.writeImage(it, rawImage) }
                }
                rawImage.close()
                shot.raw = null
                gallery[dngFile.absolutePath] = MediaTools.saveToGallery(context, dngFile, "image/x-adobe-dng")
                out["rawPath"] = dngFile.absolutePath
            }
            shot.callback(kotlin.Result.success(out))
        } catch (e: OutOfMemoryError) {
            shot.fail(IllegalStateException("Not enough memory to convert this photo. Try JPEG or HEIC."))
        } catch (e: Exception) {
            shot.fail(e)
        }
    }

    private fun exifOrientation() = when (sensorOrientation) {
        90 -> ExifInterface.ORIENTATION_ROTATE_90
        180 -> ExifInterface.ORIENTATION_ROTATE_180
        270 -> ExifInterface.ORIENTATION_ROTATE_270
        else -> ExifInterface.ORIENTATION_NORMAL
    }

    private class PendingShot(
        val format: String,
        val wantRaw: Boolean,
        val callback: (kotlin.Result<Map<String, Any?>>) -> Unit,
    ) {
        var jpeg: ByteArray? = null
        var raw: Image? = null
        var result: CaptureResult? = null
        private var done = false

        fun fail(e: Throwable) {
            raw?.close()
            raw = null
            if (!done) {
                done = true
                callback(kotlin.Result.failure(e))
            }
        }
    }

    companion object {
        /** Where captures are kept (also listed by the Studio as sequences). */
        fun framesDirectory(context: Context): File =
            File(context.getExternalFilesDir(null) ?: context.filesDir, "Valometer").apply { mkdirs() }

        private const val PREVIEW_MAX_EXPOSURE_NS = 250_000_000L // 1/4 s
    }
}
