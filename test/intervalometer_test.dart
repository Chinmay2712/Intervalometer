import 'package:flutter_test/flutter_test.dart';
import 'package:valometer/intervalometer.dart';
import 'package:valometer/utils/exposure.dart';

void main() {
  group('Intervalometer', () {
    test('takes the requested number of shots then finishes', () async {
      var shots = 0;
      final seq = Intervalometer(
        shoot: () async => shots++,
        tick: const Duration(milliseconds: 5),
      );
      await seq.start(const IntervalSettings(startDelaySeconds: 0, intervalSeconds: 0.02, shots: 3));
      expect(shots, 3);
      expect(seq.shotsTaken, 3);
      expect(seq.phase, SequencePhase.done);
    });

    test('stop() ends an unlimited sequence', () async {
      var shots = 0;
      final seq = Intervalometer(
        shoot: () async => shots++,
        tick: const Duration(milliseconds: 5),
      );
      final run = seq.start(const IntervalSettings(startDelaySeconds: 0, intervalSeconds: 0.01, shots: 0));
      await Future<void>.delayed(const Duration(milliseconds: 60));
      seq.stop();
      await run;
      expect(seq.phase, SequencePhase.stopped);
      expect(shots, greaterThan(1));
    });

    test('gives up after 3 failures in a row', () async {
      final seq = Intervalometer(
        shoot: () async => throw Exception('boom'),
        tick: const Duration(milliseconds: 5),
      );
      await seq.start(const IntervalSettings(startDelaySeconds: 0, intervalSeconds: 0.01, shots: 10));
      expect(seq.phase, SequencePhase.failed);
      expect(seq.failures, 3);
    });

    test('estimates total time', () {
      const s = IntervalSettings(startDelaySeconds: 5, intervalSeconds: 10, shots: 3);
      expect(s.estimatedTotal(2), const Duration(seconds: 27));
      expect(const IntervalSettings(shots: 0).estimatedTotal(1), isNull);
    });
  });

  group('exposure helpers', () {
    test('formats shutter speeds', () {
      expect(formatShutter(1 / 250), '1/250');
      expect(formatShutter(0.998), '1"');
      expect(formatShutter(30), '30"');
      expect(formatShutter(2.5), '2.5"');
    });

    test('stopsWithin keeps hardware limits', () {
      final s = stopsWithin(kShutterStops, 1 / 10000, 0.998);
      expect(s.first, 1 / 10000);
      expect(s.last, 0.998);
      expect(s, isNot(contains(1.0)));
    });
  });
}
