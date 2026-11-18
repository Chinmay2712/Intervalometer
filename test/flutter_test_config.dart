import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

/// Golden images are made on Windows; fonts render slightly differently on
/// other systems (like the Mac that builds the iOS app), so there the layout
/// checks still run but the pixel comparison is skipped.
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  if (!Platform.isWindows) goldenFileComparator = _SkipGoldens();
  await testMain();
}

class _SkipGoldens extends GoldenFileComparator {
  @override
  Future<bool> compare(Uint8List imageBytes, Uri golden) async => true;

  @override
  Future<void> update(Uri golden, Uint8List imageBytes) async {}
}
