import 'package:flutter_test/flutter_test.dart';
import 'package:valometer/studio/frame_sources.dart';

void main() {
  test('parses capture time from file names', () {
    expect(captureTime('/x/VAL_20261106_231502_250.jpg'), DateTime(2026, 11, 6, 23, 15, 2, 250));
    expect(captureTime('/x/VAL_20261106_231502_250.dng'), isNull);
    expect(captureTime('/x/IMG_0001.jpg'), isNull);
  });

  test('groups captures into sequences and drops lone shots', () {
    String at(int h, int m, int s) =>
        '/d/VAL_20261106_${h.toString().padLeft(2, '0')}${m.toString().padLeft(2, '0')}${s.toString().padLeft(2, '0')}_000.jpg';
    final paths = [
      // Sequence A: 22:00:00 every 10 s × 4
      for (var i = 0; i < 4; i++) at(22, 0, i * 10),
      // Lone shot at 22:40
      at(22, 40, 0),
      // Sequence B: 23:30 every 5 min × 3 (gaps under 15 min)
      for (var i = 0; i < 3; i++) at(23, 30 + i * 5, 0),
    ];
    final seqs = groupSequences(paths.reversed);
    expect(seqs, hasLength(2));
    expect(seqs.first.length, 3); // newest first
    expect(seqs.last.length, 4);
    expect(seqs.last.paths.first, at(22, 0, 0)); // in time order
  });
}
