import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:valometer/utils/astro_math.dart';
import 'package:valometer/utils/histogram.dart';
import 'package:valometer_camera/valometer_camera.dart';

CameraCapabilities _caps({double? fov, double? focal, double? sensorW, double? pitch, double? aperture}) =>
    CameraCapabilities(
      textureId: 0,
      previewAspect: 0.75,
      previewQuarterTurns: 0,
      minIso: 50,
      maxIso: 3200,
      minShutter: 1 / 8000,
      maxShutter: 1,
      minKelvin: 2000,
      maxKelvin: 10000,
      supportsManualExposure: true,
      supportsManualWhiteBalance: true,
      supportsManualFocus: true,
      supportsRaw: true,
      aperture: aperture,
      focalLength: focal,
      lenses: const [],
      activeLensId: 'x',
      fieldOfView: fov,
      sensorWidthMm: sensorW,
      pixelPitchUm: pitch,
    );

void main() {
  group('exposure rules', () {
    test('500 rule', () {
      expect(rule500(24), closeTo(20.8, 0.1));
      expect(rule500(14), closeTo(35.7, 0.1));
    });

    test('NPF rule for a full-frame 24mm f/1.8 with 6 µm pixels', () {
      expect(npfRule(fNumber: 1.8, pixelPitchUm: 6, focalMm: 24), closeTo(10.1, 0.1));
    });

    test('equivalent focal from field of view', () {
      // A 24mm full-frame lens has a 73.7° horizontal FOV.
      expect(equivFocalFromFov(73.74), closeTo(24, 0.1));
    });

    test('stacking frame count', () {
      expect(framesToStack(20, 1), 20);
      expect(framesToStack(0.5, 1), 1);
    });
  });

  group('LensOptics', () {
    test('uses real Android data when available', () {
      final o = LensOptics.fromCapabilities(
          _caps(focal: 6.0, sensorW: 9.6, pitch: 1.2, aperture: 1.7, fov: 77.3));
      expect(o.estimated, isFalse);
      expect(o.focalMm, 6.0);
      expect(o.equivFocalMm, closeTo(22.6, 0.5));
    });

    test('estimates missing iPhone values and flags them', () {
      final o = LensOptics.fromCapabilities(_caps(fov: 73.74, aperture: 1.78));
      expect(o.estimated, isTrue);
      expect(o.equivFocalMm, closeTo(24, 0.1));
      expect(o.focalMm, closeTo(24 / 3.5, 0.1));
    });
  });

  group('Histogram', () {
    Uint8List pixels(int value, int count) {
      final b = Uint8List(count * 4);
      for (var i = 0; i < count; i++) {
        b[i * 4] = value;
        b[i * 4 + 1] = value;
        b[i * 4 + 2] = value;
        b[i * 4 + 3] = 255;
      }
      return b;
    }

    test('counts pixels and finds the peak', () {
      final h = Histogram.fromRgba(pixels(70, 100));
      expect(h.total, 100);
      expect(h.luma[70], 100);
      expect(h.peakPosition, closeTo(70 / 255, 0.001));
      expect(h.astroAdvice, startsWith('Good'));
    });

    test('flags an underexposed frame', () {
      final h = Histogram.fromRgba(pixels(2, 100));
      expect(h.clippedShadows, 1.0);
      expect(h.astroAdvice, startsWith('Underexposed'));
    });

    test('flags clipped highlights', () {
      final h = Histogram.fromRgba(pixels(255, 100));
      expect(h.clippedHighlights, 1.0);
      expect(h.astroAdvice, startsWith('Too bright'));
    });
  });
}
