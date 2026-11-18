import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:valometer/screens/camera_screen.dart';
import 'package:valometer/theme.dart';

const _caps = {
  'textureId': 1,
  'previewAspect': 0.75,
  'previewQuarterTurns': 0,
  'minIso': 100.0,
  'maxIso': 6400.0,
  'minShutter': 0.0001,
  'maxShutter': 30.0,
  'minKelvin': 2500.0,
  'maxKelvin': 8000.0,
  'supportsManualExposure': true,
  'supportsManualWhiteBalance': true,
  'supportsManualFocus': true,
  'supportsRaw': true,
  'aperture': 1.8,
  'focalLength': 5.6,
  'lenses': [
    {'id': '0', 'name': '5.6mm'},
    {'id': '2', 'name': '2.2mm'},
  ],
  'activeLensId': '0',
  'formats': {'heic': 'converted', 'png': 'converted', 'tiff': 'converted', 'dng': 'native'},
};

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({'photo_format': 'tiff', 'photo_also_raw': true});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('valometer/camera'),
      (call) async => call.method == 'open' ? _caps : null,
    );
  });

  for (final size in const [Size(360, 740), Size(393, 873), Size(430, 932)]) {
    testWidgets('camera screen fits ${size.width.toInt()}×${size.height.toInt()}', (tester) async {
      tester.view.physicalSize = size * 3;
      tester.view.devicePixelRatio = 3;
      tester.view.padding = const FakeViewPadding(top: 120, bottom: 60);
      addTearDown(tester.view.reset);

      await tester.pumpWidget(MaterialApp(theme: buildTheme(), home: const CameraScreen()));
      await tester.pumpAndSettle();

      expect(find.text('FORMAT'), findsOneWidget);
      expect(find.text('TIFF+RAW'), findsOneWidget);
      expect(find.text('5.6mm'), findsWidgets);
      expect(find.text('Studio'), findsNothing);

      if (size.width == 393) {
        await expectLater(find.byType(CameraScreen), matchesGoldenFile('goldens/camera_393.png'));
      }

      // Each pro icon opens its own drawer.
      await tester.tap(find.byIcon(Icons.shutter_speed_outlined));
      await tester.pumpAndSettle();
      expect(find.text('Shutter speed'), findsOneWidget);
      expect(find.byType(Slider), findsOneWidget);
      if (size.width == 393) {
        await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/camera_393_drawer.png'));
      }
      await tester.tapAt(const Offset(20, 300));
      await tester.pumpAndSettle();
      expect(find.byType(Slider), findsNothing);

      await tester.tap(find.byIcon(Icons.camera_outlined));
      await tester.pumpAndSettle();
      expect(find.text('2.2mm'), findsOneWidget);
    });
  }
}
