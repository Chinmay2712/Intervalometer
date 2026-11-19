import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Tests use real fonts (so text and icons are visible instead of blocks).
/// Golden images are made on Windows; fonts render slightly differently on
/// other systems (like the Mac that builds the iOS app), so there the layout
/// checks still run but the pixel comparison is skipped.
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  // Real fonts everywhere, so layout checks measure the same text as on a
  // phone; pixel comparison only where the goldens were made.
  await _loadFonts();
  if (!Platform.isWindows) goldenFileComparator = _SkipGoldens();
  await testMain();
}

Future<void> _loadFonts() async {
  // Flutter ships Roboto and Material Icons in its cache.
  final flutterRoot = Platform.environment['FLUTTER_ROOT'];
  if (flutterRoot == null) return;
  final dir = '$flutterRoot/bin/cache/artifacts/material_fonts';
  Future<void> load(String family, List<String> files) async {
    final loader = FontLoader(family);
    for (final f in files) {
      final file = File(f);
      if (file.existsSync()) loader.addFont(Future.value(ByteData.sublistView(file.readAsBytesSync())));
    }
    await loader.load();
  }

  await load('Roboto', [
    '$dir/roboto-regular.ttf',
    '$dir/roboto-medium.ttf',
    '$dir/roboto-bold.ttf',
  ]);
  await load('MaterialIcons', ['$dir/materialicons-regular.otf']);
  await load('Readout', ['assets/fonts/RobotoCondensed-Regular.ttf', 'assets/fonts/RobotoCondensed-Bold.ttf']);
}

class _SkipGoldens extends GoldenFileComparator {
  @override
  Future<bool> compare(Uint8List imageBytes, Uri golden) async => true;

  @override
  Future<void> update(Uri golden, Uint8List imageBytes) async {}
}
