/// Dart side of Valometer's native camera bridge.
///
/// iOS: AVFoundation (Swift) · Android: Camera2 (Kotlin).
/// The preview is rendered through a Flutter [Texture] whose id is returned
/// by [ValometerCamera.open].
library;

import 'package:flutter/services.dart';

class LensInfo {
  const LensInfo({required this.id, required this.name});
  final String id;
  final String name;

  factory LensInfo.fromMap(Map<dynamic, dynamic> m) =>
      LensInfo(id: m['id'] as String, name: m['name'] as String);
}

/// What the currently opened camera can do. All shutter values are seconds.
class CameraCapabilities {
  const CameraCapabilities({
    required this.textureId,
    required this.previewAspect,
    required this.previewQuarterTurns,
    required this.minIso,
    required this.maxIso,
    required this.minShutter,
    required this.maxShutter,
    required this.minKelvin,
    required this.maxKelvin,
    required this.supportsManualExposure,
    required this.supportsManualWhiteBalance,
    required this.supportsManualFocus,
    required this.supportsRaw,
    required this.aperture,
    required this.focalLength,
    required this.lenses,
    required this.activeLensId,
    this.fieldOfView,
    this.sensorWidthMm,
    this.pixelPitchUm,
    this.formats = const {PhotoFormat.jpeg: FormatSupport.native},
  });

  /// How each output format is produced on this camera. Missing = unavailable.
  final Map<PhotoFormat, FormatSupport> formats;

  /// Horizontal field of view in degrees (long side of the sensor).
  final double? fieldOfView;

  /// Physical sensor width in mm (Android only).
  final double? sensorWidthMm;

  /// Pixel pitch in micrometres (Android only).
  final double? pixelPitchUm;

  final int textureId;

  /// Width / height of the preview as it should be displayed (portrait).
  final double previewAspect;

  /// Extra clockwise quarter turns Flutter must apply to the texture.
  final int previewQuarterTurns;

  final double minIso;
  final double maxIso;
  final double minShutter;
  final double maxShutter;
  final double minKelvin;
  final double maxKelvin;
  final bool supportsManualExposure;
  final bool supportsManualWhiteBalance;
  final bool supportsManualFocus;
  final bool supportsRaw;

  /// f-number of the lens (read-only on almost every phone).
  final double? aperture;

  /// Physical focal length in mm, if the platform reports it.
  final double? focalLength;

  final List<LensInfo> lenses;
  final String activeLensId;

  factory CameraCapabilities.fromMap(Map<dynamic, dynamic> m) {
    double d(String k, double fallback) =>
        (m[k] as num?)?.toDouble() ?? fallback;
    return CameraCapabilities(
      textureId: (m['textureId'] as num).toInt(),
      previewAspect: d('previewAspect', 3 / 4),
      previewQuarterTurns: (m['previewQuarterTurns'] as num?)?.toInt() ?? 0,
      minIso: d('minIso', 50),
      maxIso: d('maxIso', 3200),
      minShutter: d('minShutter', 1 / 8000),
      maxShutter: d('maxShutter', 1),
      minKelvin: d('minKelvin', 2000),
      maxKelvin: d('maxKelvin', 10000),
      supportsManualExposure: m['supportsManualExposure'] == true,
      supportsManualWhiteBalance: m['supportsManualWhiteBalance'] == true,
      supportsManualFocus: m['supportsManualFocus'] == true,
      supportsRaw: m['supportsRaw'] == true,
      aperture: (m['aperture'] as num?)?.toDouble(),
      focalLength: (m['focalLength'] as num?)?.toDouble(),
      lenses: ((m['lenses'] as List?) ?? const [])
          .map((e) => LensInfo.fromMap(e as Map))
          .toList(),
      activeLensId: m['activeLensId'] as String? ?? '',
      fieldOfView: (m['fieldOfView'] as num?)?.toDouble(),
      sensorWidthMm: (m['sensorWidthMm'] as num?)?.toDouble(),
      pixelPitchUm: (m['pixelPitchUm'] as num?)?.toDouble(),
      formats: _parseFormats(m['formats'] as Map?),
    );
  }
}

Map<PhotoFormat, FormatSupport> _parseFormats(Map<dynamic, dynamic>? raw) {
  final out = {PhotoFormat.jpeg: FormatSupport.native};
  raw?.forEach((k, v) {
    final f = PhotoFormat.fromName('$k');
    final s = FormatSupport.fromName('$v');
    if (f != null && s != null) out[f] = s;
  });
  return out;
}

/// Output formats the user can choose for each photo.
enum PhotoFormat {
  jpeg('JPEG', 'jpg', 'image/jpeg'),
  heic('HEIC', 'heic', 'image/heic'),
  png('PNG', 'png', 'image/png'),
  tiff('TIFF', 'tif', 'image/tiff'),

  /// RAW only: just the DNG is saved to the gallery.
  dng('RAW', 'dng', 'image/x-adobe-dng');

  const PhotoFormat(this.label, this.extension, this.mime);
  final String label;
  final String extension;
  final String mime;

  static PhotoFormat? fromName(String name) {
    for (final f in values) {
      if (f.name == name) return f;
    }
    return null;
  }
}

/// How the camera produces a format.
enum FormatSupport {
  /// Encoded by the camera itself.
  native,

  /// Encoded by Valometer from the uncompressed photo (no quality loss).
  lossless,

  /// Converted by Valometer from the camera's JPEG.
  converted;

  static FormatSupport? fromName(String name) {
    for (final f in values) {
      if (f.name == name) return f;
    }
    return null;
  }
}

class CaptureResult {
  const CaptureResult({this.jpegPath, this.photoPath, this.rawPath, this.galleryIds = const {}});

  /// JPEG working copy kept inside the app (thumbnail, histogram, Studio).
  /// Saved to the gallery only when JPEG is the chosen format.
  final String? jpegPath;

  /// The photo in the chosen format (saved to the gallery). Null for RAW only.
  final String? photoPath;
  final String? rawPath;

  /// File path → gallery identifier (content URI / Photos asset id) for
  /// every file that was added to the gallery.
  final Map<String, String> galleryIds;

  factory CaptureResult.fromMap(Map<dynamic, dynamic> m) => CaptureResult(
        jpegPath: m['jpegPath'] as String?,
        photoPath: m['photoPath'] as String?,
        rawPath: m['rawPath'] as String?,
        galleryIds: {
          for (final e in ((m['gallery'] as Map?) ?? const {}).entries) '${e.key}': '${e.value}',
        },
      );
}

class ValometerCamera {
  ValometerCamera._();
  static final ValometerCamera instance = ValometerCamera._();

  static const MethodChannel _channel = MethodChannel('valometer/camera');

  /// Asks for camera permission (if needed), opens [lensId] (or the default
  /// back wide camera) and starts the preview.
  Future<CameraCapabilities> open({String? lensId}) async {
    final res = await _channel.invokeMapMethod<dynamic, dynamic>(
      'open',
      {'lensId': lensId},
    );
    return CameraCapabilities.fromMap(res!);
  }

  /// [auto] = true returns to continuous auto-exposure.
  Future<void> setExposure({
    required bool auto,
    double? iso,
    double? shutterSeconds,
  }) =>
      _channel.invokeMethod('setExposure', {
        'auto': auto,
        'iso': iso,
        'shutter': shutterSeconds,
      });

  Future<void> setWhiteBalance({required bool auto, double? kelvin}) =>
      _channel.invokeMethod('setWhiteBalance', {
        'auto': auto,
        'kelvin': kelvin,
      });

  /// [position] 0.0 = closest focus, 1.0 = infinity.
  Future<void> setFocus({required bool auto, double? position}) =>
      _channel.invokeMethod('setFocus', {
        'auto': auto,
        'position': position,
      });

  /// Takes one photo with the current settings and saves it to the gallery
  /// (album "Valometer") in [format]. With [raw] the DNG is saved too
  /// ([PhotoFormat.dng] always saves it).
  Future<CaptureResult> capture({PhotoFormat format = PhotoFormat.jpeg, bool raw = false}) async {
    final res = await _channel.invokeMapMethod<dynamic, dynamic>(
      'capture',
      {
        'format': format == PhotoFormat.dng ? 'none' : format.name,
        'raw': raw || format == PhotoFormat.dng,
      },
    );
    return CaptureResult.fromMap(res ?? const {});
  }

  Future<void> close() => _channel.invokeMethod('close');

  // ------------------------------------------------------------ media tools

  /// Folder where Valometer keeps its own copies of captured photos.
  Future<String> framesDirectory() async => (await _channel.invokeMethod<String>('framesDirectory'))!;

  /// Adds a file to the phone's gallery (Photos / Pictures/Valometer, or
  /// Movies/Valometer for videos).
  /// Adds [path] to the gallery; returns its gallery identifier if known.
  Future<String?> saveToGallery(String path, {String mime = 'image/jpeg'}) =>
      _channel.invokeMethod<String>('saveToGallery', {'path': path, 'mime': mime});

  /// For each gallery identifier (or file name with [byName], Android only):
  /// true = still in the gallery, false = deleted, null = can't tell.
  Future<List<bool?>> galleryExists(List<String> ids, {bool byName = false}) async {
    if (ids.isEmpty) return const [];
    final res = await _channel.invokeListMethod<dynamic>('galleryExists', {'ids': ids, 'byName': byName});
    return [for (final v in res ?? const []) v as bool?];
  }

  void Function(int done, int total)? _encodeProgress;

  /// Encodes [paths] into an H.264 MP4 at [fps]. Images are fitted into
  /// [width]×[height] (both even). Returns [outPath].
  Future<String> encodeVideo({
    required List<String> paths,
    required int fps,
    required int width,
    required int height,
    required String outPath,
    void Function(int done, int total)? onProgress,
  }) async {
    _encodeProgress = onProgress;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'encodeProgress') {
        final m = call.arguments as Map;
        _encodeProgress?.call((m['done'] as num).toInt(), (m['total'] as num).toInt());
      }
    });
    try {
      return (await _channel.invokeMethod<String>('encodeVideo', {
        'paths': paths,
        'fps': fps,
        'width': width,
        'height': height,
        'outPath': outPath,
      }))!;
    } finally {
      _encodeProgress = null;
    }
  }

  Future<void> cancelEncode() => _channel.invokeMethod('cancelEncode');
}
