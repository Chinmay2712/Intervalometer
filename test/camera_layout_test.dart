import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:valometer/screens/camera_screen.dart';
import 'package:valometer/theme.dart';
import 'package:valometer/ui/scale_dial.dart';

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
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMessageHandler(
      'dev.flutter.pigeon.wakelock_plus_platform_interface.WakelockPlusApi.toggle',
      (_) async => const StandardMessageCodec().encodeMessage(<Object?>[null]),
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
      expect(find.byType(ScaleDial), findsOneWidget);
      expect(find.text('Auto'), findsOneWidget);
      // Dragging the dial switches to manual and shows the new value.
      await tester.drag(find.byType(ScaleDial), const Offset(-120, 0));
      await tester.pumpAndSettle();
      expect(find.text('AUTO'), findsNothing);
      if (size.width == 393) {
        await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/camera_393_drawer.png'));
      }
      await tester.tapAt(const Offset(20, 300));
      await tester.pumpAndSettle();
      expect(find.byType(ScaleDial), findsNothing);

      await tester.tap(find.byIcon(Icons.camera_outlined));
      await tester.pumpAndSettle();
      expect(find.text('2.2mm'), findsOneWidget);
    });
  }

  testWidgets('iPhone: shutters past the sensor limit say they are stacked', (tester) async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('valometer/camera'),
      (call) async => call.method == 'open' ? {..._caps, 'nativeMaxShutter': 1.0} : null,
    );
    tester.view.physicalSize = const Size(360, 740) * 3;
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(MaterialApp(theme: buildTheme(), home: const CameraScreen()));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.shutter_speed_outlined));
    await tester.pumpAndSettle();
    expect(find.textContaining('Stacked:'), findsNothing);
    // Drag towards the long end of the dial.
    for (var i = 0; i < 3; i++) {
      await tester.drag(find.byType(ScaleDial), const Offset(-300, 0));
      await tester.pumpAndSettle();
    }
    expect(find.textContaining('Stacked:'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('camera screen handles larger system text', (tester) async {
    tester.view.physicalSize = const Size(360, 740) * 3;
    tester.view.devicePixelRatio = 3;
    tester.view.padding = const FakeViewPadding(top: 120, bottom: 60);
    tester.platformDispatcher.textScaleFactorTestValue = 1.3;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

    await tester.pumpWidget(MaterialApp(theme: buildTheme(), home: const CameraScreen()));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.tap(find.byIcon(Icons.iso));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
