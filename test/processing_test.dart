import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:valometer/studio/processing.dart';
import 'package:valometer/studio/star_align.dart';

Uint8List solid(int w, int h, int v) {
  final b = Uint8List(w * h * 4);
  for (var i = 0; i < b.length; i += 4) {
    b[i] = v;
    b[i + 1] = v;
    b[i + 2] = v;
    b[i + 3] = 255;
  }
  return b;
}

void main() {
  test('star trails keep the brightest pixel', () {
    final t = TrailAccumulator(2, 1);
    final a = Uint8List.fromList([10, 200, 30, 255, 0, 0, 0, 255]);
    final b = Uint8List.fromList([50, 20, 30, 255, 9, 9, 9, 255]);
    t.add(a);
    t.add(b);
    expect(t.rgba, [50, 200, 30, 255, 9, 9, 9, 255]);
  });

  test('mean stack reduces noise', () {
    const w = 64, h = 64, n = 32;
    final rnd = Random(1);
    final acc = StackAccumulator(w, h);
    final rgb = Uint8List(w * h * 3);
    final valid = Uint8List(w * h)..fillRange(0, w * h, 1);
    for (var f = 0; f < n; f++) {
      for (var i = 0; i < rgb.length; i++) {
        rgb[i] = (100 + (rnd.nextDouble() - 0.5) * 60).round(); // ±30 noise
      }
      acc.addPass1(rgb, valid);
    }
    final out = acc.result();
    var maxErr = 0;
    for (var i = 0; i < out.length; i += 4) {
      maxErr = max(maxErr, (out[i] - 100).abs());
    }
    expect(maxErr, lessThan(12)); // single frames are off by up to 30
  });

  test('outlier rejection removes a satellite streak', () {
    const w = 8, h = 8, n = 20;
    final rnd = Random(2);
    final acc = StackAccumulator(w, h, reject: true, kappa: 2.5);
    final valid = Uint8List(w * h)..fillRange(0, w * h, 1);
    final frames = <Uint8List>[];
    for (var f = 0; f < n; f++) {
      final rgb = Uint8List(w * h * 3);
      for (var i = 0; i < rgb.length; i++) {
        rgb[i] = 40 + rnd.nextInt(5);
      }
      if (f == 7) {
        // Satellite crosses pixel 0 in one frame.
        rgb[0] = 255;
        rgb[1] = 255;
        rgb[2] = 255;
      }
      frames.add(rgb);
      acc.addPass1(rgb, valid);
    }
    acc.finishPass1();
    for (final rgb in frames) {
      acc.addPass2(rgb, valid);
    }
    final withRejection = acc.result()[0];

    final plain = StackAccumulator(w, h);
    for (final rgb in frames) {
      plain.addPass1(rgb, valid);
    }
    expect(plain.result()[0], greaterThan(50)); // streak leaks into the mean
    expect(withRejection, lessThan(45)); // streak removed
  });

  test('warp with identity copies; foreground mask keeps ground fixed', () {
    const w = 4, h = 2;
    final src = Uint8List.fromList(List.generate(w * h * 4, (i) => i % 4 == 3 ? 255 : i));
    final dst = Uint8List(w * h * 3);
    final valid = Uint8List(w * h);
    warpFrame(src: src, w: w, h: h, t: Rigid.identity, dst: dst, valid: valid);
    expect(dst.sublist(0, 3), [0, 1, 2]);
    expect(valid.every((v) => v == 1), isTrue);

    // Shift the sky by 1 px; bottom row is foreground and must not move.
    final fg = Uint8List(w * h)..fillRange(w, w * h, 255);
    warpFrame(src: src, w: w, h: h, t: const Rigid(1, 0, 1, 0), foreground: fg, dst: dst, valid: valid);
    expect(valid[0], 0); // sky pixel left of the shifted frame: uncovered
    expect(dst.sublist(3, 6), [0, 1, 2]); // sky moved right by 1
    expect(dst.sublist(w * 3, w * 3 + 3), [16, 17, 18]); // ground unchanged
  });

  test('mask feathering and upscaling stay in range', () {
    final small = Uint8List(4 * 4)..fillRange(8, 16, 255);
    final big = upscaleMask(small, 4, 4, 40, 40);
    featherMask(big, 40, 40, 3);
    expect(big.first, 0);
    expect(big.last, 255);
    expect(big[20 * 40 + 5], inInclusiveRange(1, 254)); // soft edge in the middle
  });

  test('resize keeps a solid colour', () {
    final out = resizeRgba(solid(100, 50, 77), 100, 50, 20, 10);
    expect(out.length, 20 * 10 * 4);
    expect(out.every((v) => v == 77 || v == 255), isTrue);
  });
}
