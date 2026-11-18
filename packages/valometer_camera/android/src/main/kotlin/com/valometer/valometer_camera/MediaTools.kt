package com.valometer.valometer_camera

import android.content.ContentValues
import android.content.Context
import android.graphics.Bitmap
import android.graphics.Color
import android.graphics.ImageDecoder
import android.graphics.Paint
import android.graphics.RectF
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.media.MediaMuxer
import android.os.Environment
import android.provider.MediaStore
import java.io.File
import kotlin.math.min

/** Gallery saving and H.264 timelapse encoding (MediaCodec + MediaMuxer). */
object MediaTools {

    /**
     * Copies [file] into Pictures/Valometer or Movies/Valometer and returns
     * the gallery item's content URI (used later to notice deletions).
     */
    fun saveToGallery(context: Context, file: File, mime: String): String {
        val video = mime.startsWith("video/")
        val resolver = context.contentResolver
        val values = ContentValues().apply {
            put(MediaStore.MediaColumns.DISPLAY_NAME, file.name)
            put(MediaStore.MediaColumns.MIME_TYPE, mime)
            put(
                MediaStore.MediaColumns.RELATIVE_PATH,
                (if (video) Environment.DIRECTORY_MOVIES else Environment.DIRECTORY_PICTURES) + "/Valometer"
            )
            put(MediaStore.MediaColumns.IS_PENDING, 1)
        }
        val collection = if (video)
            MediaStore.Video.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
        else
            MediaStore.Images.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
        val uri = resolver.insert(collection, values) ?: throw IllegalStateException("Gallery refused the file.")
        resolver.openOutputStream(uri)?.use { os -> file.inputStream().use { it.copyTo(os) } }
        values.clear()
        values.put(MediaStore.MediaColumns.IS_PENDING, 0)
        resolver.update(uri, values, null, null)
        return uri.toString()
    }

    /**
     * For each content URI: true if it is still in the gallery, false if the
     * user deleted it (items in the trash count as deleted), null if unknown.
     */
    fun galleryExists(context: Context, ids: List<String>): List<Boolean?> = ids.map { id ->
        try {
            context.contentResolver.query(
                android.net.Uri.parse(id), arrayOf(MediaStore.MediaColumns._ID), null, null, null
            )?.use { it.count > 0 } ?: false
        } catch (_: SecurityException) {
            null
        } catch (_: Exception) {
            false
        }
    }

    /**
     * Older captures saved before IDs were recorded: looks them up by file
     * name in Pictures/Valometer and Movies/Valometer.
     */
    fun galleryExistsByName(context: Context, names: List<String>): List<Boolean?> {
        val present = HashSet<String>()
        try {
            for (collection in listOf(
                MediaStore.Images.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY),
                MediaStore.Video.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY),
            )) {
                context.contentResolver.query(
                    collection,
                    arrayOf(MediaStore.MediaColumns.DISPLAY_NAME),
                    "${MediaStore.MediaColumns.RELATIVE_PATH} LIKE ?",
                    arrayOf("%Valometer%"),
                    null
                )?.use { c ->
                    while (c.moveToNext()) present += c.getString(0) ?: continue
                }
            }
        } catch (_: Exception) {
            return names.map { null }
        }
        return names.map { it in present }
    }

    /**
     * Encodes [paths] (any images Android can decode) into an MP4 at [fps].
     * Each image is scaled to fit [width]×[height] (EXIF orientation applied),
     * with black bars if the aspect differs.
     */
    fun encodeVideo(
        paths: List<String>,
        fps: Int,
        width: Int,
        height: Int,
        outPath: String,
        progress: (done: Int, total: Int) -> Unit,
        cancelled: () -> Boolean,
    ) {
        val format = MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_AVC, width, height).apply {
            setInteger(MediaFormat.KEY_COLOR_FORMAT, MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface)
            setInteger(MediaFormat.KEY_BIT_RATE, (width.toLong() * height * fps / 6).coerceIn(4_000_000, 80_000_000).toInt())
            setInteger(MediaFormat.KEY_FRAME_RATE, fps)
            setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, 1)
            setInteger(MediaFormat.KEY_MAX_B_FRAMES, 0) // keeps output order = input order
        }
        val codec = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_VIDEO_AVC)
        codec.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
        val surface = codec.createInputSurface()
        codec.start()

        val muxer = MediaMuxer(outPath, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
        var track = -1
        var muxing = false
        var framesOut = 0L
        val info = MediaCodec.BufferInfo()
        val paint = Paint(Paint.FILTER_BITMAP_FLAG)

        fun drain(endOfStream: Boolean) {
            if (endOfStream) codec.signalEndOfInputStream()
            var idleLoops = 0
            while (true) {
                val index = codec.dequeueOutputBuffer(info, 10_000)
                when {
                    index == MediaCodec.INFO_TRY_AGAIN_LATER -> {
                        if (!endOfStream || ++idleLoops > 500) return
                    }
                    index == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                        track = muxer.addTrack(codec.outputFormat)
                        muxer.start()
                        muxing = true
                    }
                    index >= 0 -> {
                        val buffer = codec.getOutputBuffer(index)!!
                        if (info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG != 0) info.size = 0
                        if (info.size > 0 && muxing) {
                            // Evenly spaced timestamps regardless of how fast we drew.
                            info.presentationTimeUs = framesOut * 1_000_000L / fps
                            framesOut++
                            buffer.position(info.offset)
                            buffer.limit(info.offset + info.size)
                            muxer.writeSampleData(track, buffer, info)
                        }
                        codec.releaseOutputBuffer(index, false)
                        if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) return
                    }
                }
            }
        }

        try {
            paths.forEachIndexed { i, path ->
                if (cancelled()) throw InterruptedException("Cancelled")
                val bitmap = decodeScaled(path, width, height)
                val canvas = surface.lockHardwareCanvas()
                try {
                    canvas.drawColor(Color.BLACK)
                    val scale = min(width.toFloat() / bitmap.width, height.toFloat() / bitmap.height)
                    val w = bitmap.width * scale
                    val h = bitmap.height * scale
                    canvas.drawBitmap(bitmap, null, RectF((width - w) / 2, (height - h) / 2, (width + w) / 2, (height + h) / 2), paint)
                } finally {
                    surface.unlockCanvasAndPost(canvas)
                    bitmap.recycle()
                }
                drain(false)
                progress(i + 1, paths.size)
            }
            drain(true)
        } finally {
            try { codec.stop() } catch (_: Exception) {}
            codec.release()
            surface.release()
            try { if (muxing) muxer.stop() } catch (_: Exception) {}
            muxer.release()
        }
        if (framesOut == 0L) throw IllegalStateException("The video encoder produced no frames.")
    }

    /** Decodes with EXIF orientation applied, downsampled to about the target size. */
    private fun decodeScaled(path: String, maxW: Int, maxH: Int): Bitmap {
        val source = ImageDecoder.createSource(File(path))
        return ImageDecoder.decodeBitmap(source) { decoder, info, _ ->
            val s = min(maxW.toFloat() / info.size.width, maxH.toFloat() / info.size.height)
            if (s < 1f) decoder.setTargetSize((info.size.width * s).toInt().coerceAtLeast(1), (info.size.height * s).toInt().coerceAtLeast(1))
            decoder.allocator = ImageDecoder.ALLOCATOR_SOFTWARE
        }
    }
}
