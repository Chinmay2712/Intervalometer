package com.valometer.valometer_camera

import java.util.Locale

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.pm.PackageManager
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraManager
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result
import io.flutter.plugin.common.PluginRegistry
import io.flutter.view.TextureRegistry

/** Flutter entry point: routes "valometer/camera" calls to [CameraController]. */
class ValometerCameraPlugin :
    FlutterPlugin,
    ActivityAware,
    MethodCallHandler,
    PluginRegistry.RequestPermissionsResultListener {

    private lateinit var channel: MethodChannel
    private lateinit var context: Context
    private lateinit var textures: TextureRegistry
    private var activityBinding: ActivityPluginBinding? = null
    private var camera: CameraController? = null
    private var remote: RemoteTrigger? = null
    private var pendingPermission: Pair<() -> Unit, () -> Unit>? = null
    private val main = Handler(Looper.getMainLooper())

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        textures = binding.textureRegistry
        channel = MethodChannel(binding.binaryMessenger, "valometer/camera")
        channel.setMethodCallHandler(this)
        remote = RemoteTrigger(context, binding.binaryMessenger)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
        camera?.close()
        camera = null
        remote?.dispose()
        remote = null
    }

    // ---- ActivityAware (needed for the runtime permission prompt) ----

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activityBinding = binding
        remote?.activity = binding.activity
        binding.addRequestPermissionsResultListener(this)
    }

    override fun onDetachedFromActivityForConfigChanges() = onDetachedFromActivity()

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) =
        onAttachedToActivity(binding)

    override fun onDetachedFromActivity() {
        activityBinding?.removeRequestPermissionsResultListener(this)
        activityBinding = null
        remote?.activity = null
    }

    // ---- Method calls ----

    override fun onMethodCall(call: MethodCall, result: Result) {
        when (call.method) {
            "open" -> ensureCameraPermission(
                onGranted = { open(call.argument<String>("lensId"), result) },
                onDenied = {
                    result.error(
                        "permission",
                        "Camera access is off. Allow it in Settings › Apps › Valometer › Permissions.",
                        null
                    )
                }
            )

            "setExposure" -> withCamera(result) {
                it.setExposure(
                    auto = call.argument<Boolean>("auto") ?: true,
                    iso = call.argument<Number>("iso")?.toDouble(),
                    shutterSeconds = call.argument<Number>("shutter")?.toDouble()
                )
                result.success(null)
            }

            "setWhiteBalance" -> withCamera(result) {
                it.setWhiteBalance(
                    auto = call.argument<Boolean>("auto") ?: true,
                    kelvin = call.argument<Number>("kelvin")?.toDouble()
                )
                result.success(null)
            }

            "setFocus" -> withCamera(result) {
                it.setFocus(
                    auto = call.argument<Boolean>("auto") ?: true,
                    position = call.argument<Number>("position")?.toDouble()
                )
                result.success(null)
            }

            "capture" -> withCamera(result) {
                it.capture(
                    format = call.argument<String>("format") ?: "jpeg",
                    raw = call.argument<Boolean>("raw") ?: false,
                ) { outcome ->
                    main.post {
                        outcome.fold(
                            onSuccess = { map -> result.success(map) },
                            onFailure = { e -> result.error("capture_failed", e.message, null) }
                        )
                    }
                }
            }

            "close" -> {
                camera?.close()
                camera = null
                result.success(null)
            }

            "framesDirectory" -> result.success(CameraController.framesDirectory(context).absolutePath)

            "galleryExists" -> {
                val ids = call.argument<List<String>>("ids") ?: emptyList()
                val byName = call.argument<Boolean>("byName") ?: false
                background {
                    val found = if (byName) MediaTools.galleryExistsByName(context, ids)
                    else MediaTools.galleryExists(context, ids)
                    main.post { result.success(found) }
                }
            }

            "saveToGallery" -> {
                val path = call.argument<String>("path")!!
                val mime = call.argument<String>("mime") ?: "image/jpeg"
                background {
                    try {
                        val id = MediaTools.saveToGallery(context, java.io.File(path), mime)
                        main.post { result.success(id) }
                    } catch (e: Exception) {
                        main.post { result.error("save_failed", e.message, null) }
                    }
                }
            }

            "encodeVideo" -> {
                val paths = call.argument<List<String>>("paths")!!
                val fps = call.argument<Int>("fps") ?: 30
                val width = call.argument<Int>("width")!!
                val height = call.argument<Int>("height")!!
                val out = call.argument<String>("outPath")!!
                encodeCancelled = false
                background {
                    try {
                        MediaTools.encodeVideo(
                            paths, fps, width, height, out,
                            progress = { done, total ->
                                main.post { channel.invokeMethod("encodeProgress", mapOf("done" to done, "total" to total)) }
                            },
                            cancelled = { encodeCancelled },
                        )
                        main.post { result.success(out) }
                    } catch (e: InterruptedException) {
                        java.io.File(out).delete()
                        main.post { result.error("cancelled", "Cancelled.", null) }
                    } catch (e: Exception) {
                        java.io.File(out).delete()
                        main.post { result.error("encode_failed", e.message ?: e.toString(), null) }
                    }
                }
            }

            "cancelEncode" -> {
                encodeCancelled = true
                result.success(null)
            }

            else -> result.notImplemented()
        }
    }

    @Volatile private var encodeCancelled = false

    private fun background(block: () -> Unit) = Thread(block, "ValometerMedia").start()

    private inline fun withCamera(result: Result, block: (CameraController) -> Unit) {
        val cam = camera
        if (cam == null) result.error("no_camera", "Camera is not open.", null) else block(cam)
    }

    private fun open(lensId: String?, result: Result) {
        camera?.close()
        camera = null

        val manager = context.getSystemService(Context.CAMERA_SERVICE) as CameraManager
        val backIds = manager.cameraIdList.filter {
            manager.getCameraCharacteristics(it)
                .get(CameraCharacteristics.LENS_FACING) == CameraCharacteristics.LENS_FACING_BACK
        }
        val id = backIds.firstOrNull { it == lensId } ?: backIds.firstOrNull()
        if (id == null) {
            result.error("no_camera", "No back camera found.", null)
            return
        }
        val lenses = backIds.map { mapOf("id" to it, "name" to lensName(manager, it)) }

        val cam = CameraController(context, textures, id)
        camera = cam
        cam.open { outcome ->
            main.post {
                outcome.fold(
                    onSuccess = { caps -> result.success(caps + ("lenses" to lenses)) },
                    onFailure = { e ->
                        cam.close()
                        if (camera === cam) camera = null
                        result.error("open_failed", e.message, null)
                    }
                )
            }
        }
    }

    private fun lensName(manager: CameraManager, id: String): String {
        val focal = manager.getCameraCharacteristics(id)
            .get(CameraCharacteristics.LENS_INFO_AVAILABLE_FOCAL_LENGTHS)?.firstOrNull()
        return if (focal != null) "${"%.1f".format(Locale.US, focal)}mm" else "Lens $id"
    }

    // ---- Permissions ----

    private fun ensureCameraPermission(onGranted: () -> Unit, onDenied: () -> Unit) {
        if (context.checkSelfPermission(Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED) {
            onGranted()
            return
        }
        val activity: Activity = activityBinding?.activity ?: return onDenied()
        pendingPermission = onGranted to onDenied
        activity.requestPermissions(arrayOf(Manifest.permission.CAMERA), PERMISSION_REQUEST)
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ): Boolean {
        if (remote?.onRequestPermissionsResult(requestCode, grantResults) == true) return true
        if (requestCode != PERMISSION_REQUEST) return false
        val pending = pendingPermission ?: return true
        pendingPermission = null
        if (grantResults.firstOrNull() == PackageManager.PERMISSION_GRANTED) pending.first() else pending.second()
        return true
    }

    companion object {
        private const val PERMISSION_REQUEST = 4207
    }
}
