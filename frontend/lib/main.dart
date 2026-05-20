import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'core/theme.dart';
import 'screens/map_screen.dart';

void main() {
  runApp(
    const ProviderScope(
      child: SafeWayApp(),
    ),
  );
}

class SafeWayApp extends StatelessWidget {
  const SafeWayApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'SafeWay - Phase 1',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.lightTheme,
      home: const MapScreen(),
    );
  }
}