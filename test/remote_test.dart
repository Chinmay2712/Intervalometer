import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:valometer/remote/remote_plan.dart';
import 'package:valometer/screens/remote_screen.dart';
import 'package:valometer/theme.dart';

void main() {
  group('RemotePlan', () {
    test('gap after photo waits for exposure + saving + gap', () {
      const p = RemotePlan(startDelay: 5, exposure: 30, saveTime: 10, gap: 3, shots: 10);
      expect(p.period, 43);
      expect(p.overlaps, isFalse);
      expect(p.total, const Duration(seconds: 5 + 9 * 43 + 40));
    });

    test('fixed interval shorter than the photo is flagged', () {
      const p = RemotePlan(timing: RemoteTiming.fixedInterval, exposure: 30, saveTime: 10, interval: 20);
      expect(p.period, 20);
      expect(p.overlaps, isTrue);
      expect(p.copyWith(interval: 40).overlaps, isFalse);
    });

    test('open-ended runs have no total', () {
      expect(const RemotePlan(shots: 0).total, isNull);
    });

    test('round-trips through JSON', () {
      const p = RemotePlan(startDelay: 7, timing: RemoteTiming.fixedInterval, exposure: 4, saveTime: 2, gap: 1, interval: 9, shots: 0);
      expect(RemotePlan.fromJson(p.toJson()), p);
    });
  });

  group('RemoteSession', () {
    testWidgets('presses after the start delay, then every period, then stops', (tester) async {
      var now = DateTime(2026, 11, 24, 22);
      final presses = <DateTime>[];
      final s = RemoteSession(
        clock: () => now,
        press: () async {
          presses.add(now);
          return true;
        },
      );
      Future<void> advance(int seconds) async {
        for (var i = 0; i < seconds; i++) {
          now = now.add(const Duration(seconds: 1));
          await tester.pump(const Duration(seconds: 1));
        }
      }

      s.start(const RemotePlan(startDelay: 5, exposure: 2, saveTime: 1, gap: 1, shots: 3));
      expect(s.phase, RemotePhase.countdown);
      await advance(4);
      expect(presses, isEmpty);
      await advance(1);
      expect(presses.length, 1);
      await advance(4); // period = 2 + 1 + 1
      expect(presses.length, 2);
      await advance(4);
      expect(presses.length, 3);
      expect(s.phase, RemotePhase.done);
      await advance(10);
      expect(presses.length, 3);
      s.dispose();
    });

    testWidgets('pauses when the iPhone is gone and retries on resume', (tester) async {
      var now = DateTime(2026);
      var connected = false;
      var count = 0;
      final s = RemoteSession(clock: () => now, press: () async {
        if (connected) count++;
        return connected;
      });
      s.start(const RemotePlan(startDelay: 1, exposure: 1, saveTime: 1, gap: 1, shots: 2));
      now = now.add(const Duration(seconds: 1));
      await tester.pump(const Duration(seconds: 1));
      expect(s.phase, RemotePhase.paused);
      expect(s.taken, 0);
      connected = true;
      s.resume();
      await tester.pump(const Duration(milliseconds: 1));
      expect(count, 1);
      expect(s.phase, RemotePhase.running);
      s.reset();
      expect(s.phase, RemotePhase.idle);
      s.dispose();
    });
  });

  group('RemoteScreen', () {
    late List<String> calls;
    setUp(() {
      calls = [];
      SharedPreferences.setMockInitialValues({});
      final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(const MethodChannel('valometer/remote'), (call) async {
        calls.add(call.method);
        return switch (call.method) {
          'start' => {'phoneName': 'realme 7', 'state': 'connected', 'name': 'Chinmay\'s iPhone', 'registered': true},
          'pairedDevices' => [
              {'name': 'Chinmay\'s iPhone', 'address': 'AA:BB'},
            ],
          'press' => true,
          _ => null,
        };
      });
      messenger.setMockMessageHandler(
        'dev.flutter.pigeon.wakelock_plus_platform_interface.WakelockPlusApi.toggle',
        (_) async => const StandardMessageCodec().encodeMessage(<Object?>[null]),
      );
    });

    for (final size in const [Size(360, 740), Size(393, 873)]) {
      testWidgets('fits ${size.width.toInt()} wide and runs a sequence', (tester) async {
        tester.view.physicalSize = size * 3;
        tester.view.devicePixelRatio = 3;
        addTearDown(tester.view.reset);

        await tester.pumpWidget(MaterialApp(theme: buildTheme(), home: const RemoteScreen()));
        await tester.pump();
        await tester.pump();

        expect(find.text('Connected to Chinmay\'s iPhone'), findsOneWidget);
        expect(tester.takeException(), isNull);

        if (size.width == 393) {
          await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/remote_393.png'));
        }

        // Fixed interval shorter than the photo: warning, Start blocked.
        await tester.tap(find.text('Fixed interval'));
        await tester.pump();
        expect(find.textContaining('start to start'), findsOneWidget);
        await tester.tap(find.text('Gap after photo'));
        await tester.pump();

        // Self-timer preset: one photo after 10 s.
        await tester.tap(find.text('Self-timer'));
        await tester.pump();
        await tester.scrollUntilVisible(find.text('Gap between photos'), 200);
        expect(find.text('Gap between photos'), findsOneWidget);
        await tester.tap(find.text('Start'));
        await tester.pump();
        expect(find.text('First photo in'), findsOneWidget);
        if (size.width == 393) {
          await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/remote_393_running.png'));
        }
        await tester.pump(const Duration(seconds: 11));
        await tester.pump();
        expect(calls.where((c) => c == 'press').length, 1);
        expect(find.textContaining('Done'), findsWidgets);
        expect(tester.takeException(), isNull);

        await tester.pumpWidget(const SizedBox());
        await tester.pump(const Duration(seconds: 5));
      });
    }

    testWidgets('explains when the phone can\'t be a Bluetooth keyboard', (tester) async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('valometer/remote'),
        (call) async => call.method == 'start'
            ? throw PlatformException(code: 'unsupported', message: 'This phone can\'t act as a Bluetooth keyboard.')
            : null,
      );
      await tester.pumpWidget(MaterialApp(theme: buildTheme(), home: const RemoteScreen()));
      await tester.pump();
      await tester.pump();
      expect(find.text('Remote unavailable'), findsOneWidget);
      expect(find.text('Connect the iPhone to start'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });
  });
}
