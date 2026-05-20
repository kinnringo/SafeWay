import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:frontend/main.dart';

void main() {
  testWidgets('App smoke test', (WidgetTester tester) async {
    // アプリをProviderScopeでラップして起動する
    await tester.pumpWidget(
      const ProviderScope(
        child: SafeWayApp(),
      ),
    );

    // アプリのタイトル文字があるか確認
    expect(find.text('SafeWay'), findsOneWidget);
  });
}
