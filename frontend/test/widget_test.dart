import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:frontend/main.dart';

void main() {
  testWidgets('App smoke test', (WidgetTester tester) async {
    // アプリを起動する
    await tester.pumpWidget(const SafeWayApp());

    // アプリのタイトル文字があるか確認
    expect(find.text('SafeWay - Phase 1'), findsOneWidget);
  });
}
