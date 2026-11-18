package com.valometer.valometer_camera

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Matrix
import android.media.ExifInterface
import android.media.MediaCodecList
import android.media.MediaFormat
import androidx.heifwriter.HeifWriter
import java.io.BufferedOutputStream
import java.io.ByteArrayInputStream
import java.io.File
import java.io.FileOutputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * Turns the camera's JPEG into the format the user picked (Camera2 only
 * encodes JPEG). Pixels are rotated upright, so no viewer depends on
 * EXIF orientation.
 */
object ImageConverter {

    /** True if the phone has an HEVC/HEIC hardware encoder (needed for HEIC). */
    val heicSupported: Boolean by lazy {
        try {
            MediaCodecList(MediaCodecList.REGULAR_CODECS).codecInfos.any { info ->
                info.isEncoder && info.supportedTypes.any {
                    it.equals(MediaFormat.MIMETYPE_IMAGE_ANDROID_HEIC, true) ||
                        it.equals(MediaFormat.MIMETYPE_VIDEO_HEVC, true)
                }
            }
        } catch (_: Throwable) {
            false
        }
    }

    /** Writes [jpeg] to [out] as "heic", "png" or "tiff". */
    fun convert(jpeg: ByteArray, format: String, out: File) {
        val degrees = exifRotation(jpeg)
        val decoded = BitmapFactory.decodeByteArray(jpeg, 0, jpeg.size, BitmapFactory.Options().apply {
            inPreferredConfig = Bitmap.Config.ARGB_8888
        }) ?: throw IllegalStateException("Could not decode the photo for conversion.")
        try {
            when (format) {
                "heic" -> writeHeic(decoded, degrees, out)
                "png" -> upright(decoded, degrees).let { bmp ->
                    try {
                        BufferedOutputStream(FileOutputStream(out), 1 shl 20).use {
                            bmp.compress(Bitmap.CompressFormat.PNG, 100, it)
                        }
                    } finally {
                        if (bmp !== decoded) bmp.recycle()
                    }
                }
                "tiff" -> writeTiff(decoded, degrees, out)
                else -> throw IllegalArgumentException("Unknown format $format")
            }
        } catch (e: Throwable) {
            out.delete()
            throw e
        } finally {
            decoded.recycle()
        }
    }

    private fun exifRotation(jpeg: ByteArray): Int = try {
        when (ExifInterface(ByteArrayInputStream(jpeg)).getAttributeInt(
            ExifInterface.TAG_ORIENTATION, ExifInterface.ORIENTATION_NORMAL
        )) {
            ExifInterface.ORIENTATION_ROTATE_90 -> 90
            ExifInterface.ORIENTATION_ROTATE_180 -> 180
            ExifInterface.ORIENTATION_ROTATE_270 -> 270
            else -> 0
        }
    } catch (_: Exception) {
        0
    }

    private fun upright(src: Bitmap, degrees: Int): Bitmap {
        if (degrees == 0) return src
        val m = Matrix().apply { postRotate(degrees.toFloat()) }
        return Bitmap.createBitmap(src, 0, 0, src.width, src.height, m, true)
    }

    private fun writeHeic(bmp: Bitmap, degrees: Int, out: File) {
        // HEIC stores rotation in its own header, which every viewer respects.
        val writer = HeifWriter.Builder(out.absolutePath, bmp.width, bmp.height, HeifWriter.INPUT_MODE_BITMAP)
            .setQuality(95)
            .setRotation(degrees)
            .build()
        try {
            writer.start()
            writer.addBitmap(bmp)
            writer.stop(30_000)
        } finally {
            writer.close()
        }
    }

    /**
     * Baseline TIFF: 8-bit RGB, uncompressed, one row per strip. Rows are
     * produced already rotated, so no second full-size bitmap is needed.
     */
    private fun writeTiff(src: Bitmap, degrees: Int, out: File) {
        val w = if (degrees == 90 || degrees == 270) src.height else src.width
        val h = if (degrees == 90 || degrees == 270) src.width else src.height
        val rowBytes = w * 3
        val entries = 12
        val ifdSize = 2 + entries * 12 + 4
        val bpsOffset = 8 + ifdSize                 // 3 × SHORT
        val resOffset = bpsOffset + 6                // 2 × RATIONAL (x, y)
        val softwareOffset = resOffset + 16
        val software = "Valometer\u0000".toByteArray(Charsets.US_ASCII)
        val stripOffsetsOffset = softwareOffset + software.size
        val stripCountsOffset = stripOffsetsOffset + 4 * h
        val dataOffset = stripCountsOffset + 4 * h

        BufferedOutputStream(FileOutputStream(out), 1 shl 20).use { os ->
            val head = ByteBuffer.allocate(dataOffset).order(ByteOrder.LITTLE_ENDIAN)
            head.put('I'.code.toByte()).put('I'.code.toByte()).putShort(42).putInt(8)
            head.putShort(entries.toShort())
            fun tag(id: Int, type: Int, count: Int, value: Int) {
                head.putShort(id.toShort()).putShort(type.toShort()).putInt(count)
                if (type == 3 && count == 1) head.putShort(value.toShort()).putShort(0) else head.putInt(value)
            }
            tag(256, 4, 1, w)                       // ImageWidth
            tag(257, 4, 1, h)                       // ImageLength
            tag(258, 3, 3, bpsOffset)               // BitsPerSample
            tag(259, 3, 1, 1)                       // Compression: none
            tag(262, 3, 1, 2)                       // Photometric: RGB
            tag(273, 4, h, stripOffsetsOffset)      // StripOffsets
            tag(277, 3, 1, 3)                       // SamplesPerPixel
            tag(278, 4, 1, 1)                       // RowsPerStrip
            tag(279, 4, h, stripCountsOffset)       // StripByteCounts
            tag(282, 5, 1, resOffset)               // XResolution
            tag(283, 5, 1, resOffset + 8)           // YResolution
            tag(305, 2, software.size, softwareOffset) // Software
            head.putInt(0)                          // no next IFD
            repeat(3) { head.putShort(8) }
            head.putInt(72).putInt(1).putInt(72).putInt(1)
            head.put(software)
            for (r in 0 until h) head.putInt(dataOffset + r * rowBytes)
            repeat(h) { head.putInt(rowBytes) }
            os.write(head.array())

            val line = IntArray(w)
            val bytes = ByteArray(rowBytes)
            val sw = src.width
            val sh = src.height
            for (r in 0 until h) {
                when (degrees) {
                    // Output row r = source column r, read bottom to top.
                    90 -> { src.getPixels(line, 0, 1, r, 0, 1, sh); line.reverse() }
                    // Output row r = source column (sw-1-r), top to bottom.
                    270 -> src.getPixels(line, 0, 1, sw - 1 - r, 0, 1, sh)
                    180 -> { src.getPixels(line, 0, sw, 0, sh - 1 - r, sw, 1); line.reverse() }
                    else -> src.getPixels(line, 0, sw, 0, r, sw, 1)
                }
                var j = 0
                for (c in line) {
                    bytes[j++] = (c shr 16).toByte()
                    bytes[j++] = (c shr 8).toByte()
                    bytes[j++] = c.toByte()
                }
                os.write(bytes)
            }
        }
    }
}
