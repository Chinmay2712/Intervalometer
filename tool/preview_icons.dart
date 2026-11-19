// Renders the generated icons under the common launcher masks into
// build/icon_preview.png, so a white border or a shrunken logo is easy to spot.
//
//   dart run tool/preview_icons.dart
import 'dart:io';
import 'dart:math';

import 'package:image/image.dart' as img;

const _res = 'android/app/src/main/res';
const _cell = 240;

void main() {
  final fg = img.decodePng(File('$_res/mipmap-xxxhdpi/ic_launcher_foreground.png').readAsBytesSync())!;
  final mono = img.decodePng(File('$_res/mipmap-xxxhdpi/ic_launcher_monochrome.png').readAsBytesSync())!;
  final ios = img.decodePng(File('ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-1024x1024@1x.png').readAsBytesSync())!;
  final round = img.decodePng(File('$_res/mipmap-xxxhdpi/ic_launcher_round.png').readAsBytesSync())!;
  final legacy = img.decodePng(File('$_res/mipmap-xxxhdpi/ic_launcher.png').readAsBytesSync())!;

  // Adaptive icons show the middle 72 of 108 dp.
  final inset = (fg.width * 18 / 108).round();
  final visible = img.copyCrop(fg, x: inset, y: inset, width: fg.width - 2 * inset, height: fg.width - 2 * inset);

  bool circle(double x, double y) => x * x + y * y <= 1;
  bool squircle(double x, double y) => pow(x.abs(), 4) + pow(y.abs(), 4) <= 1;
  bool rounded(double x, double y) {
    const r = 0.45; // iOS-like corner
    final ax = max(0.0, x.abs() - (1 - r)), ay = max(0.0, y.abs() - (1 - r));
    return ax * ax + ay * ay <= r * r;
  }

  bool teardrop(double x, double y) => (x > 0 && y > 0) ? (x <= 1 && y <= 1) : circle(x, y);

  // Light wallpaper so a white rim would be invisible but a dark/white mismatch shows.
  final sheet = img.Image(width: _cell * 4, height: _cell * 2)..clear(img.ColorRgb8(200, 210, 225));
  void put(img.Image src, int col, int row, bool Function(double, double) mask, {img.Color? tint}) {
    const pad = 20, s = _cell - 2 * pad;
    final scaled = img.copyResize(src, width: s, height: s, interpolation: img.Interpolation.average);
    for (var y = 0; y < s; y++) {
      for (var x = 0; x < s; x++) {
        final nx = (x + 0.5) / s * 2 - 1, ny = (y + 0.5) / s * 2 - 1;
        if (!mask(nx, ny)) continue;
        final p = scaled.getPixel(x, y);
        final a = p.a / 255;
        if (a == 0) continue;
        final dst = sheet.getPixel(col * _cell + pad + x, row * _cell + pad + y);
        final c = tint ?? p;
        dst
          ..r = c.r * a + dst.r * (1 - a)
          ..g = c.g * a + dst.g * (1 - a)
          ..b = c.b * a + dst.b * (1 - a);
      }
    }
  }

  put(visible, 0, 0, circle);
  put(visible, 1, 0, squircle);
  put(visible, 2, 0, rounded);
  put(visible, 3, 0, teardrop);
  put(ios, 0, 1, rounded);
  put(round, 1, 1, (_, _) => true);
  put(legacy, 2, 1, (_, _) => true);
  // Themed icon (Android 13): background tone + monochrome in accent tone.
  final themed = img.Image(width: visible.width, height: visible.height)..clear(img.ColorRgb8(40, 52, 80));
  put(themed, 3, 1, circle);
  final monoVisible = img.copyCrop(mono, x: inset, y: inset, width: visible.width, height: visible.height);
  put(monoVisible, 3, 1, circle, tint: img.ColorRgb8(190, 210, 255));

  Directory('build').createSync(recursive: true);
  File('build/icon_preview.png').writeAsBytesSync(img.encodePng(sheet));
  stdout.writeln('build/icon_preview.png');
}
