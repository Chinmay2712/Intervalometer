import 'package:flutter_test/flutter_test.dart';
import 'package:valometer_camera/valometer_camera.dart';

CameraCapabilities _caps({double? native}) => CameraCapabilities.fromMap({
      'textureId': 1,
      'minShutter': 0.0001,
      'maxShutter': 30.0,
      'nativeMaxShutter': ?native,
      'supportsManualExposure': true,
      'lenses': const [],
      'activeLensId': '0',
    });

void main() {
  test('Android-style caps: every shutter is a single exposure', () {
    final c = _caps();
    expect(c.nativeMaxShutter, 30);
    expect(c.framesFor(30), 1);
  });

  test('iPhone-style caps: past the sensor limit, frames are stacked', () {
    final c = _caps(native: 1);
    expect(c.framesFor(1 / 2), 1);
    expect(c.framesFor(1), 1);
    expect(c.framesFor(2), 2);
    expect(c.framesFor(15), 15);
    expect(c.framesFor(30), 30);

    final longer = _caps(native: 1.3);
    expect(longer.framesFor(1.3), 1);
    expect(longer.framesFor(4), 4); // 4 × 1 s
    expect(longer.framesFor(30), 24); // 24 × 1.25 s
  });
}
