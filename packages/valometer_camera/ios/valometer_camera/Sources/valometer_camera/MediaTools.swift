import AVFoundation
import Foundation
import ImageIO
import Photos
import UIKit

/// Gallery saving and H.264 timelapse encoding (AVAssetWriter).
enum MediaTools {
  static func framesDirectory() throws -> URL {
    let docs = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
    let dir = docs.appendingPathComponent("Valometer", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
  }

  /// Adds the file to Photos; completes with the asset's local identifier.
  static func saveToGallery(_ url: URL, video: Bool, completion: @escaping (String?, Error?) -> Void) {
    PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
      guard status == .authorized || status == .limited else {
        completion(nil, ValometerCameraSession.err("Photos access is off. Allow it in Settings › Valometer › Photos."))
        return
      }
      var id: String?
      PHPhotoLibrary.shared().performChanges({
        let req = PHAssetCreationRequest.forAsset()
        req.addResource(with: video ? .video : .photo, fileURL: url, options: nil)
        id = req.placeholderForCreatedAsset?.localIdentifier
      }, completionHandler: { _, error in completion(id, error) })
    }
  }

  /// For each asset identifier: still in Photos (true), deleted (false), or
  /// nil if Valometer may not read the library.
  static func galleryExists(_ ids: [String], completion: @escaping ([Bool]?) -> Void) {
    PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
      guard status == .authorized || status == .limited else { return completion(nil) }
      let found = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
      var present = Set<String>()
      found.enumerateObjects { asset, _, _ in present.insert(asset.localIdentifier) }
      completion(ids.map { present.contains($0) })
    }
  }

  /// Encodes images at [paths] into an MP4. Each image is fitted into
  /// width×height (EXIF orientation applied) with black bars if needed.
  static func encodeVideo(
    paths: [String], fps: Int, width: Int, height: Int, outPath: String,
    progress: @escaping (Int, Int) -> Void,
    cancelled: () -> Bool
  ) throws {
    let url = URL(fileURLWithPath: outPath)
    try? FileManager.default.removeItem(at: url)

    let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
    let bitrate = min(max(width * height * fps / 6, 4_000_000), 80_000_000)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
      AVVideoCodecKey: AVVideoCodecType.h264,
      AVVideoWidthKey: width,
      AVVideoHeightKey: height,
      AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: bitrate],
    ])
    input.expectsMediaDataInRealTime = false
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
      kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
      kCVPixelBufferWidthKey as String: width,
      kCVPixelBufferHeightKey as String: height,
    ])
    guard writer.canAdd(input) else { throw ValometerCameraSession.err("Video settings not supported.") }
    writer.add(input)
    guard writer.startWriting() else { throw writer.error ?? ValometerCameraSession.err("Could not start the video.") }
    writer.startSession(atSourceTime: .zero)

    for (i, path) in paths.enumerated() {
      if cancelled() {
        writer.cancelWriting()
        throw ValometerCameraSession.err("Cancelled.")
      }
      try autoreleasepool {
        while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.005) }
        guard let pool = adaptor.pixelBufferPool else { throw writer.error ?? ValometerCameraSession.err("Video writer failed.") }
        var pb: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb)
        guard let buffer = pb else { throw ValometerCameraSession.err("Out of memory for video frames.") }
        draw(path: path, into: buffer, width: width, height: height)
        let time = CMTime(value: CMTimeValue(i), timescale: CMTimeScale(fps))
        if !adaptor.append(buffer, withPresentationTime: time) {
          throw writer.error ?? ValometerCameraSession.err("Could not add frame \(i + 1).")
        }
      }
      progress(i + 1, paths.count)
    }

    input.markAsFinished()
    let done = DispatchSemaphore(value: 0)
    writer.finishWriting { done.signal() }
    done.wait()
    if writer.status != .completed {
      throw writer.error ?? ValometerCameraSession.err("Video could not be finished.")
    }
  }

  private static func draw(path: String, into buffer: CVPixelBuffer, width: Int, height: Int) {
    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    guard let ctx = CGContext(
      data: CVPixelBufferGetBaseAddress(buffer),
      width: width, height: height, bitsPerComponent: 8,
      bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
      space: CGColorSpace(name: CGColorSpace.sRGB)!,
      bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
    ) else { return }
    ctx.setFillColor(UIColor.black.cgColor)
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))

    // Downsampled decode with the EXIF orientation applied.
    guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(width, height),
          ] as CFDictionary)
    else { return }
    let scale = min(CGFloat(width) / CGFloat(image.width), CGFloat(height) / CGFloat(image.height))
    let w = CGFloat(image.width) * scale, h = CGFloat(image.height) * scale
    ctx.interpolationQuality = .high
    ctx.draw(image, in: CGRect(x: (CGFloat(width) - w) / 2, y: (CGFloat(height) - h) / 2, width: w, height: h))
  }
}
