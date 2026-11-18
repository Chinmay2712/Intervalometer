import 'package:flutter_test/flutter_test.dart';
import 'package:valometer/widgets/format_sheet.dart';
import 'package:valometer_camera/valometer_camera.dart';

CameraCapabilities _caps(Map<String, String> formats, {bool raw = false}) => CameraCapabilities.fromMap({
      'textureId': 1,
      'previewAspect': 0.75,
      'previewQuarterTurns': 0,
      'minIso': 100.0,
      'maxIso': 3200.0,
      'minShutter': 0.001,
      'maxShutter': 30.0,
      'minKelvin': 2500.0,
      'maxKelvin': 8000.0,
      'supportsManualExposure': true,
      'supportsManualWhiteBalance': true,
      'supportsManualFocus': true,
      'supportsRaw': raw,
      'lenses': const [],
      'activeLensId': '0',
      'formats': formats,
    });

void main() {
  test('parses format support and ignores unknown entries', () {
    final c = _caps({'heic': 'native', 'png': 'lossless', 'tiff': 'converted', 'webp': 'native', 'dng': 'bogus'});
    expect(c.formats[PhotoFormat.jpeg], FormatSupport.native);
    expect(c.formats[PhotoFormat.heic], FormatSupport.native);
    expect(c.formats[PhotoFormat.png], FormatSupport.lossless);
    expect(c.formats[PhotoFormat.tiff], FormatSupport.converted);
    expect(c.formats.containsKey(PhotoFormat.dng), isFalse);
  });

  test('labels for the camera button', () {
    expect(const FormatChoice(PhotoFormat.jpeg).label, 'JPEG');
    expect(const FormatChoice(PhotoFormat.tiff, alsoRaw: true).label, 'TIFF+RAW');
    expect(const FormatChoice(PhotoFormat.dng, alsoRaw: true).label, 'RAW');
    expect(const FormatChoice(PhotoFormat.dng).savesRaw, isTrue);
  });

  test('falls back to what the camera can do', () {
    final noHeicNoRaw = _caps({'png': 'converted'});
    final a = const FormatChoice(PhotoFormat.heic, alsoRaw: true).fitTo(noHeicNoRaw);
    expect(a.format, PhotoFormat.jpeg);
    expect(a.alsoRaw, isFalse);
    expect(const FormatChoice(PhotoFormat.dng).fitTo(noHeicNoRaw).format, PhotoFormat.jpeg);

    final withRaw = _caps({'dng': 'native'}, raw: true);
    expect(const FormatChoice(PhotoFormat.jpeg, alsoRaw: true).fitTo(withRaw).alsoRaw, isTrue);
  });
}
