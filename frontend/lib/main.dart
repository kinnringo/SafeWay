import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart'; // 地図表示用
import 'package:latlong2/latlong.dart';      // 座標管理用

void main() {
  runApp(const SafeWayApp());
}

class SafeWayApp extends StatelessWidget {
  const SafeWayApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'SafeWay',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blueGrey),
        useMaterial3: true,
      ),
      home: const MapScreen(),
    );
  }
}

class MapScreen extends StatelessWidget {
  const MapScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('SafeWay - Phase 1'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
      ),
      body: FlutterMap(
        options: const MapOptions(
          // 初期位置を前橋駅に設定
          initialCenter: LatLng(36.3895, 139.0634), 
          initialZoom: 15.0,
        ),
        children: [
          TileLayer(
            // OpenStreetMapのタイルを使用
            urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
            userAgentPackageName: 'com.example.frontend',
          ),
        ],
      ),
    );
  }
}