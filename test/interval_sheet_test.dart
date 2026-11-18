import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:valometer/intervalometer.dart';
import 'package:valometer/theme.dart';
import 'package:valometer/widgets/interval_sheet.dart';

void main() {
  // Small phones and landscape: the sheet must fit or scroll, never overflow.
  for (final size in const [Size(360, 640), Size(393, 852), Size(852, 393)]) {
    testWidgets('interval sheet fits ${size.width.toInt()}×${size.height.toInt()}', (tester) async {
      tester.view.physicalSize = size * 3;
      tester.view.devicePixelRatio = 3;
      tester.view.padding = const FakeViewPadding(top: 120, bottom: 60);
      addTearDown(tester.view.reset);

      await tester.pumpWidget(MaterialApp(
        theme: buildTheme(),
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => showIntervalSheet(context, initial: const IntervalSettings(), shutterSeconds: 30),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.text('Start delay'), findsOneWidget);
      expect(find.text('Time from the start of one shot to the start of the next.'), findsOneWidget);
      await tester.ensureVisible(find.text('Done'));
      await tester.pumpAndSettle();
      expect(find.text('Done').hitTestable(), findsOneWidget);
    });
  }
}
