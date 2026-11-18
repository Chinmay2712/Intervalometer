import AVFoundation
import Flutter
import Photos
import UIKit
import UniformTypeIdentifiers

// MARK: - Plugin entry point

public class ValometerCameraPlugin: NSObject, FlutterPlugin {
  private let textures: FlutterTextureRegistry
  private let channel: FlutterMethodChannel
  private var camera: ValometerCameraSession?
  private var encodeCancelled = false

  init(textures: FlutterTextureRegistry, channel: FlutterMethodChannel) {
    self.textures = textures
    self.channel = channel
  }

  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: "valometer/camera", binaryMessenger: registrar.messenger())
    let instance = ValometerCameraPlugin(textures: registrar.textures(), channel: channel)
    registrar.addMethodCallDelegate(instance, channel: channel)
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    switch call.method {
    case "open":
      open(lensId: args["lensId"] as? String, result: result)

    case "setExposure":
      guard let cam = camera else { return result(Self.noCamera) }
      cam.setExposure(
        auto: args["auto"] as? Bool ?? true,
        iso: (args["iso"] as? NSNumber)?.floatValue,
        shutter: (args["shutter"] as? NSNumber)?.doubleValue,
        result: result)

    case "setWhiteBalance":
      guard let cam = camera else { return result(Self.noCamera) }
      cam.setWhiteBalance(
        auto: args["auto"] as? Bool ?? true,
        kelvin: (args["kelvin"] as? NSNumber)?.floatValue,
        result: result)

    case "setFocus":
      guard let cam = camera else { return result(Self.noCamera) }
      cam.setFocus(
        auto: args["auto"] as? Bool ?? true,
        position: (args["position"] as? NSNumber)?.floatValue,
        result: result)

    case "capture":
      guard let cam = camera else { return result(Self.noCamera) }
      cam.capture(format: args["format"] as? String ?? "jpeg", raw: args["raw"] as? Bool ?? false, result: result)

    case "close":
      camera?.close()
      camera = nil
      result(nil)

    case "framesDirectory":
      do { result(try MediaTools.framesDirectory().path) } catch {
        result(FlutterError(code: "io", message: error.localizedDescription, details: nil))
      }

    case "saveToGallery":
      let path = args["path"] as? String ?? ""
      let video = (args["mime"] as? String ?? "").hasPrefix("video/")
      MediaTools.saveToGallery(URL(fileURLWithPath: path), video: video) { id, error in
        DispatchQueue.main.async {
          if let error = error {
            result(FlutterError(code: "save_failed", message: error.localizedDescription, details: nil))
          } else {
            result(id)
          }
        }
      }

    case "galleryExists":
      let ids = args["ids"] as? [String] ?? []
      if args["byName"] as? Bool == true {
        // Not supported on iOS: older captures are left alone.
        result(ids.map { _ in NSNull() })
        return
      }
      MediaTools.galleryExists(ids) { found in
        DispatchQueue.main.async {
          if let found = found { result(found) } else { result(ids.map { _ in NSNull() }) }
        }
      }

    case "encodeVideo":
      let paths = args["paths"] as? [String] ?? []
      let fps = args["fps"] as? Int ?? 30
      let width = args["width"] as? Int ?? 1920
      let height = args["height"] as? Int ?? 1080
      let out = args["outPath"] as? String ?? ""
      encodeCancelled = false
      DispatchQueue.global(qos: .userInitiated).async {
        do {
          try MediaTools.encodeVideo(
            paths: paths, fps: fps, width: width, height: height, outPath: out,
            progress: { done, total in
              DispatchQueue.main.async {
                self.channel.invokeMethod("encodeProgress", arguments: ["done": done, "total": total])
              }
            },
            cancelled: { self.encodeCancelled })
          DispatchQueue.main.async { result(out) }
        } catch {
          try? FileManager.default.removeItem(atPath: out)
          DispatchQueue.main.async {
            result(FlutterError(code: self.encodeCancelled ? "cancelled" : "encode_failed",
                                message: error.localizedDescription, details: nil))
          }
        }
      }

    case "cancelEncode":
      encodeCancelled = true
      result(nil)

    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private static let noCamera = FlutterError(code: "no_camera", message: "Camera is not open.", details: nil)

  private func open(lensId: String?, result: @escaping FlutterResult) {
    AVCaptureDevice.requestAccess(for: .video) { granted in
      DispatchQueue.main.async {
        guard granted else {
          result(FlutterError(
            code: "permission",
            message: "Camera access is off. Turn it on in Settings › Valometer › Camera.",
            details: nil))
          return
        }
        self.camera?.close()
        self.camera = nil

        let lenses = ValometerCameraSession.discoverBackLenses()
        guard let device = lenses.first(where: { $0.uniqueID == lensId })
          ?? lenses.first(where: { $0.deviceType == .builtInWideAngleCamera })
          ?? lenses.first
        else {
          result(FlutterError(code: "no_camera", message: "No back camera found.", details: nil))
          return
        }

        let cam = ValometerCameraSession(device: device, registry: self.textures)
        cam.textureId = self.textures.register(cam)
        self.camera = cam
        cam.start { outcome in
          DispatchQueue.main.async {
            switch outcome {
            case .success(var caps):
              caps["lenses"] = lenses.map { ["id": $0.uniqueID, "name": ValometerCameraSession.lensName($0)] }
              result(caps)
            case .failure(let error):
              cam.close()
              if self.camera === cam { self.camera = nil }
              result(FlutterError(code: "open_failed", message: error.localizedDescription, details: nil))
            }
          }
        }
      }
    }
  }
}

// MARK: - Camera session

final class ValometerCameraSession: NSObject, FlutterTexture, AVCaptureVideoDataOutputSampleBufferDelegate {
  let device: AVCaptureDevice
  weak var registry: FlutterTextureRegistry?
  var textureId: Int64 = 0

  private let session = AVCaptureSession()
  private let videoOutput = AVCaptureVideoDataOutput()
  private let photoOutput = AVCapturePhotoOutput()
  private let sessionQueue = DispatchQueue(label: "valometer.camera.session")
  private let videoQueue = DispatchQueue(label: "valometer.camera.video")

  private let bufferLock = NSLock()
  private var latestBuffer: CVPixelBuffer?
  private var inFlight: [Int64: PhotoCaptureProcessor] = [:]
  private var closed = false

  init(device: AVCaptureDevice, registry: FlutterTextureRegistry) {
    self.device = device
    self.registry = registry
  }

  static func discoverBackLenses() -> [AVCaptureDevice] {
    AVCaptureDevice.DiscoverySession(
      deviceTypes: [.builtInUltraWideCamera, .builtInWideAngleCamera, .builtInTelephotoCamera],
      mediaType: .video,
      position: .back
    ).devices
  }

  /// 35 mm-equivalent focal length from the field of view, as the iPhone
  /// Camera app shows it (e.g. "13mm", "24mm", "120mm").
  static func lensName(_ d: AVCaptureDevice) -> String {
    let fov = Double(d.activeFormat.videoFieldOfView) * .pi / 180
    guard fov > 0 else { return d.localizedName }
    return "\(Int((18 / tan(fov / 2)).rounded()))mm"
  }

  // MARK: Lifecycle

  func start(completion: @escaping (Result<[String: Any], Error>) -> Void) {
    sessionQueue.async {
      do {
        try self.configure()
        self.session.startRunning()
        completion(.success(self.capabilities()))
      } catch {
        completion(.failure(error))
      }
    }
  }

  private func configure() throws {
    session.beginConfiguration()
    defer { session.commitConfiguration() }

    session.sessionPreset = .photo

    let input = try AVCaptureDeviceInput(device: device)
    guard session.canAddInput(input) else { throw Self.err("Cannot use this camera.") }
    session.addInput(input)

    videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
    videoOutput.alwaysDiscardsLateVideoFrames = true
    videoOutput.setSampleBufferDelegate(self, queue: videoQueue)
    guard session.canAddOutput(videoOutput) else { throw Self.err("Cannot start the preview.") }
    session.addOutput(videoOutput)

    guard session.canAddOutput(photoOutput) else { throw Self.err("Cannot take photos with this camera.") }
    session.addOutput(photoOutput)

    // The app is portrait-only: rotate both preview frames and photos by 90°.
    for connection in [videoOutput.connection(with: .video), photoOutput.connection(with: .video)] {
      if let c = connection, c.isVideoRotationAngleSupported(90) {
        c.videoRotationAngle = 90
      }
    }
  }

  func close() {
    sessionQueue.async {
      self.closed = true
      if self.session.isRunning { self.session.stopRunning() }
    }
    registry?.unregisterTexture(textureId)
  }

  private func capabilities() -> [String: Any] {
    let f = device.activeFormat
    let bayer = photoOutput.availableRawPhotoPixelFormatTypes.filter { AVCapturePhotoOutput.isBayerRAWPixelFormat($0) }
    return [
      "textureId": textureId,
      "previewAspect": 3.0 / 4.0,  // .photo preset = 4:3 sensor, shown in portrait
      "previewQuarterTurns": 0,
      "minIso": Double(f.minISO),
      "maxIso": Double(f.maxISO),
      "minShutter": CMTimeGetSeconds(f.minExposureDuration),
      "maxShutter": CMTimeGetSeconds(f.maxExposureDuration),
      "minKelvin": 2000.0,
      "maxKelvin": 10000.0,
      "supportsManualExposure": device.isExposureModeSupported(.custom),
      "supportsManualWhiteBalance": device.isWhiteBalanceModeSupported(.locked),
      "supportsManualFocus": device.isLockingFocusWithCustomLensPositionSupported,
      "supportsRaw": !bayer.isEmpty,
      "formats": formatSupport(rawAvailable: !bayer.isEmpty),
      "aperture": Double(device.lensAperture),
      // Horizontal FOV (long side of the sensor). iOS does not expose the
      // physical sensor size, so the Dart side derives the 35 mm equivalent.
      "fieldOfView": Double(f.videoFieldOfView),
      "activeLensId": device.uniqueID,
    ]
  }

  // MARK: Preview texture

  func copyPixelBuffer() -> Unmanaged<CVPixelBuffer>? {
    bufferLock.lock()
    defer { bufferLock.unlock() }
    guard let buffer = latestBuffer else { return nil }
    return Unmanaged.passRetained(buffer)
  }

  func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
    guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
    bufferLock.lock()
    latestBuffer = buffer
    bufferLock.unlock()
    let id = textureId
    DispatchQueue.main.async { [weak self] in
      self?.registry?.textureFrameAvailable(id)
    }
  }

  // MARK: Manual controls

  private func configureDevice(_ result: @escaping FlutterResult, _ body: @escaping (AVCaptureDevice) throws -> Void) {
    sessionQueue.async {
      do {
        try self.device.lockForConfiguration()
        defer { self.device.unlockForConfiguration() }
        try body(self.device)
        DispatchQueue.main.async { result(nil) }
      } catch {
        DispatchQueue.main.async {
          result(FlutterError(code: "config_failed", message: error.localizedDescription, details: nil))
        }
      }
    }
  }

  func setExposure(auto: Bool, iso: Float?, shutter: Double?, result: @escaping FlutterResult) {
    configureDevice(result) { d in
      if auto {
        if d.isExposureModeSupported(.continuousAutoExposure) { d.exposureMode = .continuousAutoExposure }
        return
      }
      guard d.isExposureModeSupported(.custom) else { throw Self.err("Manual exposure is not supported on this lens.") }
      let f = d.activeFormat
      let isoValue = min(max(iso ?? d.iso, f.minISO), f.maxISO)
      var duration = shutter.map { CMTimeMakeWithSeconds($0, preferredTimescale: 1_000_000) } ?? d.exposureDuration
      if CMTimeCompare(duration, f.minExposureDuration) < 0 { duration = f.minExposureDuration }
      if CMTimeCompare(duration, f.maxExposureDuration) > 0 { duration = f.maxExposureDuration }
      d.setExposureModeCustom(duration: duration, iso: isoValue, completionHandler: nil)
    }
  }

  func setWhiteBalance(auto: Bool, kelvin: Float?, result: @escaping FlutterResult) {
    configureDevice(result) { d in
      if auto {
        if d.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) { d.whiteBalanceMode = .continuousAutoWhiteBalance }
        return
      }
      guard d.isWhiteBalanceModeSupported(.locked) else { throw Self.err("Manual white balance is not supported.") }
      let tt = AVCaptureDevice.WhiteBalanceTemperatureAndTintValues(temperature: kelvin ?? 4000, tint: 0)
      var g = d.deviceWhiteBalanceGains(for: tt)
      let maxGain = d.maxWhiteBalanceGain
      g.redGain = min(max(g.redGain, 1), maxGain)
      g.greenGain = min(max(g.greenGain, 1), maxGain)
      g.blueGain = min(max(g.blueGain, 1), maxGain)
      d.setWhiteBalanceModeLocked(with: g, completionHandler: nil)
    }
  }

  func setFocus(auto: Bool, position: Float?, result: @escaping FlutterResult) {
    configureDevice(result) { d in
      if auto {
        if d.isFocusModeSupported(.continuousAutoFocus) { d.focusMode = .continuousAutoFocus }
        return
      }
      guard d.isLockingFocusWithCustomLensPositionSupported else { throw Self.err("Manual focus is not supported on this lens.") }
      // AVFoundation: 0.0 = closest, 1.0 = furthest — same convention as the Dart API.
      d.setFocusModeLocked(lensPosition: min(max(position ?? 1, 0), 1), completionHandler: nil)
    }
  }

  // MARK: Capture

  private var hevcAvailable: Bool { photoOutput.availablePhotoCodecTypes.contains(.hevc) }
  private var uncompressedAvailable: Bool {
    photoOutput.availablePhotoPixelFormatTypes.contains(kCVPixelFormatType_32BGRA)
  }

  private func formatSupport(rawAvailable: Bool) -> [String: String] {
    var map: [String: String] = [
      "jpeg": "native",
      "heic": hevcAvailable ? "native" : "converted",
      "png": uncompressedAvailable ? "lossless" : "converted",
      "tiff": uncompressedAvailable ? "lossless" : "converted",
    ]
    if rawAvailable { map["dng"] = "native" }
    return map
  }

  /// [format]: "jpeg", "heic", "png", "tiff" or "none" (RAW only).
  func capture(format: String, raw: Bool, result: @escaping FlutterResult) {
    sessionQueue.async {
      guard !self.closed else {
        DispatchQueue.main.async { result(FlutterError(code: "no_camera", message: "Camera is closed.", details: nil)) }
        return
      }
      let rawType = raw
        ? self.photoOutput.availableRawPhotoPixelFormatTypes.first(where: { AVCapturePhotoOutput.isBayerRAWPixelFormat($0) })
        : nil
      if format == "none" && rawType == nil {
        DispatchQueue.main.async { result(FlutterError(code: "capture_failed", message: "This camera can't shoot RAW.", details: nil)) }
        return
      }
      // Encode natively where the camera can; PNG/TIFF start from the
      // uncompressed photo (lossless) unless RAW is also wanted.
      var processed: [String: Any] = [AVVideoCodecKey: AVVideoCodecType.jpeg]
      var uncompressed = false
      if format == "heic" && self.hevcAvailable {
        processed = [AVVideoCodecKey: AVVideoCodecType.hevc]
      } else if (format == "png" || format == "tiff") && rawType == nil && self.uncompressedAvailable {
        processed = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        uncompressed = true
      }
      let settings: AVCapturePhotoSettings
      if let rawType {
        settings = AVCapturePhotoSettings(rawPixelFormatType: rawType, processedFormat: processed)
      } else {
        settings = AVCapturePhotoSettings(format: processed)
      }
      settings.flashMode = .off
      // No multi-frame fusion: we want the exact exposure the user dialled in.
      settings.photoQualityPrioritization = .speed

      let id = settings.uniqueID
      let processor = PhotoCaptureProcessor(format: format, uncompressed: uncompressed) { [weak self] outcome in
        self?.sessionQueue.async { self?.inFlight[id] = nil }
        DispatchQueue.main.async {
          switch outcome {
          case .success(let map): result(map)
          case .failure(let error):
            result(FlutterError(code: "capture_failed", message: error.localizedDescription, details: nil))
          }
        }
      }
      self.inFlight[id] = processor
      self.photoOutput.capturePhoto(with: settings, delegate: processor)
    }
  }

  static func err(_ message: String) -> NSError {
    NSError(domain: "Valometer", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
  }
}

// MARK: - Per-shot delegate

final class PhotoCaptureProcessor: NSObject, AVCapturePhotoCaptureDelegate {
  private let completion: (Result<[String: Any], Error>) -> Void
  private let format: String
  private let uncompressed: Bool
  private var processed: AVCapturePhoto?
  private var rawData: Data?
  private var captureError: Error?

  init(format: String, uncompressed: Bool, completion: @escaping (Result<[String: Any], Error>) -> Void) {
    self.format = format
    self.uncompressed = uncompressed
    self.completion = completion
  }

  func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
    if let error = error {
      captureError = error
      return
    }
    if photo.isRawPhoto {
      rawData = photo.fileDataRepresentation()
    } else {
      processed = photo
    }
  }

  func photoOutput(_ output: AVCapturePhotoOutput, didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings, error: Error?) {
    if let error = error ?? captureError {
      completion(.failure(error))
      return
    }
    // Conversion can take a moment on 48 MP photos.
    DispatchQueue.global(qos: .userInitiated).async { self.save() }
  }

  private func save() {
    do {
      let dir = try Self.outputDirectory()
      let stamp = Self.timestamp()
      var map: [String: Any] = [:]
      var gallery: [URL] = []
      func url(_ ext: String) -> URL { dir.appendingPathComponent("VAL_\(stamp).\(ext)") }

      if let photo = processed {
        let jpegURL = url("jpg")
        if uncompressed {
          // BGRA photo: encode PNG/TIFF losslessly plus a JPEG working copy.
          guard let cg = photo.cgImageRepresentation() else { throw ImageWriter.err("No image data.") }
          let meta = photo.metadata
          try ImageWriter.write(cg, metadata: meta, to: jpegURL, type: .jpeg)
          let out = url(format == "tiff" ? "tif" : "png")
          try ImageWriter.write(cg, metadata: meta, to: out, type: format == "tiff" ? .tiff : .png)
          map["photoPath"] = out.path
          gallery.append(out)
        } else {
          guard let data = photo.fileDataRepresentation() else { throw ImageWriter.err("No image data.") }
          if Self.isHeic(data) {
            let heicURL = url("heic")
            try data.write(to: heicURL)
            try ImageWriter.transcode(data, to: jpegURL, type: .jpeg)
            map["photoPath"] = heicURL.path
            gallery.append(heicURL)
          } else {
            try data.write(to: jpegURL)
            switch format {
            case "jpeg":
              map["photoPath"] = jpegURL.path
              gallery.append(jpegURL)
            case "heic", "png", "tiff":
              let ext = format == "tiff" ? "tif" : format
              let type: UTType = format == "heic" ? .heic : (format == "png" ? .png : .tiff)
              let out = url(ext)
              try ImageWriter.transcode(data, to: out, type: type)
              map["photoPath"] = out.path
              gallery.append(out)
            default:
              break  // RAW only: the JPEG stays in the app as a working copy.
            }
          }
        }
        map["jpegPath"] = jpegURL.path
      }
      if let raw = rawData {
        let rawURL = url("dng")
        try raw.write(to: rawURL)
        map["rawPath"] = rawURL.path
        gallery.append(rawURL)
      }
      Self.saveToPhotos(gallery) { ids in
        map["gallery"] = ids
        self.completion(.success(map))
      }
    } catch {
      completion(.failure(error))
    }
  }

  private static func isHeic(_ data: Data) -> Bool {
    guard let src = CGImageSourceCreateWithData(data as CFData, nil),
          let type = CGImageSourceGetType(src) as String? else { return false }
    return UTType(type)?.conforms(to: .heic) == true
  }

  private static func outputDirectory() throws -> URL {
    let docs = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
    let dir = docs.appendingPathComponent("Valometer", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
  }

  private static func timestamp() -> String {
    let f = DateFormatter()
    f.dateFormat = "yyyyMMdd_HHmmss_SSS"
    f.locale = Locale(identifier: "en_US_POSIX")
    return f.string(from: Date())
  }

  /// Adds each file to the Photos library as its own asset (photo and DNG).
  /// Completes with file path → asset identifier.
  private static func saveToPhotos(_ urls: [URL], done: @escaping ([String: String]) -> Void) {
    guard !urls.isEmpty else { return done([:]) }
    PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
      guard status == .authorized || status == .limited else { return done([:]) }
      var ids: [String: String] = [:]
      PHPhotoLibrary.shared().performChanges({
        for url in urls {
          let req = PHAssetCreationRequest.forAsset()
          req.addResource(with: .photo, fileURL: url, options: nil)
          if let id = req.placeholderForCreatedAsset?.localIdentifier { ids[url.path] = id }
        }
      }, completionHandler: { ok, _ in done(ok ? ids : [:]) })
    }
  }
}

// MARK: - Format conversion (ImageIO)

enum ImageWriter {
  static func err(_ message: String) -> NSError {
    NSError(domain: "Valometer", code: 2, userInfo: [NSLocalizedDescriptionKey: message])
  }

  /// Re-encodes an encoded photo (JPEG/HEIC) as [type], keeping its metadata.
  static func transcode(_ data: Data, to url: URL, type: UTType) throws {
    guard let src = CGImageSourceCreateWithData(data as CFData, nil),
          let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else { throw err("Could not read the photo.") }
    let meta = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any] ?? [:]
    try write(cg, metadata: meta, to: url, type: type)
  }

  /// Writes [cg]. JPEG/HEIC keep the EXIF orientation tag; PNG and TIFF get
  /// upright pixels because many apps ignore orientation in those formats.
  static func write(_ cg: CGImage, metadata: [String: Any], to url: URL, type: UTType) throws {
    var meta = metadata
    var image = cg
    let orientationKey = kCGImagePropertyOrientation as String
    if type == .png || type == .tiff {
      let o = (meta[orientationKey] as? NSNumber)?.uint32Value ?? 1
      image = upright(cg, orientation: CGImagePropertyOrientation(rawValue: o) ?? .up) ?? cg
      meta[orientationKey] = 1
      if var tiff = meta[kCGImagePropertyTIFFDictionary as String] as? [String: Any] {
        tiff[kCGImagePropertyTIFFOrientation as String] = 1
        meta[kCGImagePropertyTIFFDictionary as String] = tiff
      }
    }
    if type == .jpeg || type == .heic {
      meta[kCGImageDestinationLossyCompressionQuality as String] = 0.95
    }
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else {
      throw err("This iPhone can't write \(type.preferredFilenameExtension ?? "that format").")
    }
    CGImageDestinationAddImage(dest, image, meta as CFDictionary)
    guard CGImageDestinationFinalize(dest) else { throw err("Could not save the photo.") }
  }

  /// Rotates pixels so the image no longer needs an orientation tag.
  private static func upright(_ cg: CGImage, orientation: CGImagePropertyOrientation) -> CGImage? {
    let w = cg.width, h = cg.height
    let swap: Bool
    switch orientation {
    case .up: return cg
    case .down: swap = false
    case .right, .left: swap = true
    default: return cg  // mirrored variants never come from the back camera
    }
    let ow = swap ? h : w, oh = swap ? w : h
    guard let ctx = CGContext(data: nil, width: ow, height: oh, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
    // CoreGraphics origin is bottom-left.
    switch orientation {
    case .down:
      ctx.translateBy(x: CGFloat(ow), y: CGFloat(oh))
      ctx.rotate(by: .pi)
    case .right:  // EXIF 6: display = stored image turned 90 degrees clockwise
      ctx.translateBy(x: 0, y: CGFloat(oh))
      ctx.rotate(by: -.pi / 2)
    case .left:   // EXIF 8: turned 90 degrees counter-clockwise
      ctx.translateBy(x: CGFloat(ow), y: 0)
      ctx.rotate(by: .pi / 2)
    default: break
    }
    ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
    return ctx.makeImage()
  }
}
