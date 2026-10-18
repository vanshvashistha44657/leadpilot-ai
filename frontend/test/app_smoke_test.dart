import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';

import 'package:leadpilot_frontend/app.dart';

void main() {
  testWidgets('LeadPilot app shell renders its initial workspace',
      (tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const ui.Size(1200, 800);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(const LeadPilotApp());
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('LeadPilot'), findsOneWidget);
    expect(find.text('Overview'), findsWidgets);
  });
}
