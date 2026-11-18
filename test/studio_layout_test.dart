import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:valometer/screens/studio/studio_screen.dart';
import 'package:valometer/screens/studio/studio_widgets.dart';
import 'package:valometer/studio/studio_engine.dart';
import 'package:valometer/theme.dart';

/// A small fake night-sky JPEG with a gradient and some stars.
String _fakeSky(Directory dir) {
  final rnd = Random(3);
  final im = img.Image(width: 320, height: 240);
  for (var y = 0; y < 240; y++) {
    for (var x = 0; x < 320; x++) {
      im.setPixelRgb(x, y, 20 + y ~/ 8, 22 + y ~/ 10, 40 + y ~/ 12);
    }
  }
  for (var i = 0; i < 120; i++) {
    final x = rnd.nextInt(318), y = rnd.nextInt(180);
    im.setPixelRgb(x, y, 255, 255, 240);
    im.setPixelRgb(x + 1, y, 200, 200, 200);
  }
  for (var x = 0; x < 320; x++) {
    for (var y = 200 + (sin(x / 30) * 10).round(); y < 240; y++) {
      im.setPixelRgb(x, y, 5, 6, 8);
    }
  }
  final f = File('${dir.path}/sky.jpg')..writeAsBytesSync(img.encodeJpg(im));
  return f.path;
}

void main() {
  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('valometer/camera'),
      (call) async => null,
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMessageHandler(
      'dev.flutter.pigeon.wakelock_plus_platform_interface.WakelockPlusApi.toggle',
      (_) async => const StandardMessageCodec().encodeMessage(<Object?>[null]),
    );
  });

  void phone(WidgetTester tester, Size size) {
    tester.view.physicalSize = size * 3;
    tester.view.devicePixelRatio = 3;
    tester.view.padding = const FakeViewPadding(top: 120, bottom: 60);
    addTearDown(tester.view.reset);
  }

  for (final size in const [Size(360, 740), Size(393, 873)]) {
    testWidgets('setup screen fits ${size.width.toInt()} wide', (tester) async {
      phone(tester, size);
      await tester.pumpWidget(MaterialApp(theme: buildTheme(), home: const StudioScreen()));
      await tester.pumpAndSettle();

      expect(find.text('CHOOSE PHOTOS'), findsOneWidget);
      expect(find.text('Star trails'), findsWidgets);
      expect(find.text('Process'), findsOneWidget);
      expect(find.byIcon(Icons.auto_awesome), findsNothing);
      expect(find.byType(ExpandingCapsule), findsOneWidget);
      expect(tester.takeException(), isNull);
      await expectLater(find.byType(StudioScreen), matchesGoldenFile('goldens/studio_empty_${size.width.toInt()}.png'));

      // The hero is centred on the screen, not pushed right by the capsule.
      final orbit = tester.getCenter(find.text('Stack').first);
      expect((orbit.dx - size.width / 2).abs(), lessThan(1));
      // Photo sources sit below the capsule, not under it.
      expect(tester.getTopLeft(find.text('Sequence')).dy,
          greaterThan(tester.getBottomLeft(find.byType(ExpandingCapsule)).dy));

      final closedWidth = tester.getSize(find.byType(ExpandingCapsule)).width;

      // Tapping an option grows the capsule itself to show its settings.
      await tester.tap(find.byIcon(Icons.satellite_alt_outlined));
      await tester.pumpAndSettle();
      expect(find.byType(Switch), findsOneWidget);
      expect(tester.getSize(find.byType(ExpandingCapsule)).width, greaterThan(closedWidth + 150));
      expect(tester.takeException(), isNull);
      if (size.width == 393) await expectLater(find.byType(StudioScreen), matchesGoldenFile('goldens/studio_flyout.png'));

      // Choosing something shrinks it back.
      await tester.tap(find.byType(Switch));
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pumpAndSettle();
      expect(find.byType(Switch), findsNothing);
      expect(tester.getSize(find.byType(ExpandingCapsule)).width, closedWidth);

      // Re-open, then tap outside: closes too.
      await tester.tap(find.byIcon(Icons.track_changes));
      await tester.pumpAndSettle();
      expect(find.byType(Switch), findsOneWidget);
      await tester.tapAt(Offset(size.width - 6, size.height / 2));
      await tester.pumpAndSettle();
      expect(find.byType(Switch), findsNothing);

      // Switching tool changes the options.
      await tester.tap(find.text('Timelapse'));
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.video_settings), findsOneWidget);
      // A chip choice also closes the capsule.
      await tester.tap(find.byIcon(Icons.video_settings));
      await tester.pumpAndSettle();
      await tester.tap(find.text('60 fps'));
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pumpAndSettle();
      expect(find.text('60 fps'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('photo editor shows the result with editing tools', (tester) async {
    phone(tester, const Size(393, 873));
    final dir = Directory.systemTemp.createTempSync('studio_test');
    addTearDown(() => dir.deleteSync(recursive: true));
    final path = _fakeSky(dir);

    // Decoding and rendering need real async work.
    await tester.runAsync(() async {
      await tester.pumpWidget(MaterialApp(
        theme: buildTheme(),
        home: StudioScreen(initialResult: StudioResult(imagePath: path, framesUsed: 12)),
      ));
      await tester.pump();
      for (var i = 0; i < 20; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 200));
        await tester.pump();
      }
    });
    await tester.pump(const Duration(seconds: 4)); // let the snackbar go
    await expectLater(find.byType(StudioScreen), matchesGoldenFile('goldens/studio_editor.png'));

    expect(find.byIcon(Icons.crop_rotate), findsOneWidget);
    expect(find.byIcon(Icons.ios_share_rounded), findsOneWidget);

    await tester.tap(find.byIcon(Icons.light_mode_outlined));
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 60));
    }
    expect(find.text('Exposure'), findsOneWidget);
    expect(find.text('Export'), findsOneWidget);
    await expectLater(find.byType(StudioScreen), matchesGoldenFile('goldens/studio_editor_light.png'));

    await tester.tap(find.byIcon(Icons.crop_rotate));
    await tester.runAsync(() async {
      for (var i = 0; i < 10; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 200));
        await tester.pump();
      }
    });
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 60));
    }
    expect(find.text('Straighten'), findsOneWidget);
    expect(find.text('Exposure'), findsNothing);
    await expectLater(find.byType(StudioScreen), matchesGoldenFile('goldens/studio_editor_crop.png'));
  });

  testWidgets('photo preview is balanced around the capsule', (tester) async {
    phone(tester, const Size(393, 873));
    final dir = Directory.systemTemp.createTempSync('studio_setup');
    addTearDown(() => dir.deleteSync(recursive: true));
    final sky = _fakeSky(dir);
    final paths = [for (var i = 0; i < 3; i++) File(sky).copySync('${dir.path}/s$i.jpg').path];

    await tester.runAsync(() async {
      await tester.pumpWidget(MaterialApp(theme: buildTheme(), home: StudioScreen(initialPaths: paths)));
      for (var i = 0; i < 10; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
        await tester.pump();
      }
    });
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('3 photos'), findsOneWidget);
    expect(find.text('Reference · 1 / 3'), findsOneWidget);
    expect((tester.getCenter(find.text('Reference · 1 / 3')).dx - 393 / 2).abs(), lessThan(1));
    await expectLater(find.byType(StudioScreen), matchesGoldenFile('goldens/studio_setup.png'));
  });
}
