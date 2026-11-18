import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:valometer/screens/sky_screen.dart';
import 'package:valometer/theme.dart';

void main() {
  testWidgets('Sky screen renders a saved location offline without layout errors', (tester) async {
    SharedPreferences.setMockInitialValues({'sky.lat': 18.52, 'sky.lon': 73.86, 'sky.gps': false});
    tester.view.physicalSize = const Size(390 * 3, 844 * 3); // phone-sized
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(MaterialApp(theme: buildTheme(), home: const SkyScreen()));
    // Let the saved location load and the (failing, offline) forecast settle.
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    expect(find.text('18.52° N, 73.86° E'), findsOneWidget);
    expect(find.text('Twilight'), findsOneWidget);
    expect(find.text('Sunset'), findsOneWidget);

    await tester.scrollUntilVisible(find.text('Moon'), 200);
    expect(find.text('Next full moon'), findsOneWidget);

    await tester.scrollUntilVisible(find.text('Milky Way core'), 200);
    expect(find.text('Core rises'), findsOneWidget);

    // Switch nights.
    await tester.scrollUntilVisible(find.text('Tomorrow'), -200);
    await tester.tap(find.text('Tomorrow'));
    await tester.pump();
    expect(tester.takeException(), isNull);
  });
}
