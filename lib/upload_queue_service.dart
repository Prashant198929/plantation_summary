import 'dart:io';
import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:http/http.dart' as http;
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'firebase_config.dart';

class UploadQueueService {
  static const String _queueKey = 'upload_queue';
  
  static Future<void> initialize() async {
    final service = FlutterBackgroundService();
    await service.configure(
      iosConfiguration: IosConfiguration(
        autoStart: true,
        onForeground: onStart,
        onBackground: onIosBackground,
      ),
      androidConfiguration: AndroidConfiguration(
        autoStart: true,
        onStart: onStart,
        isForegroundMode: false,
        autoStartOnBoot: true,
      ),
    );
  }
  
  static Future<void> addToQueue(UploadItem item) async {
    final prefs = await SharedPreferences.getInstance();
    final queueJson = prefs.getStringList(_queueKey) ?? [];
    queueJson.add(jsonEncode(item.toJson()));
    await prefs.setStringList(_queueKey, queueJson);
    
    // Start background service if not running
    final service = FlutterBackgroundService();
    if (!await service.isRunning()) {
      await service.startService();
    }
  }
  
  static Future<List<UploadItem>> getQueue() async {
    final prefs = await SharedPreferences.getInstance();
    final queueJson = prefs.getStringList(_queueKey) ?? [];
    return queueJson.map((json) => UploadItem.fromJson(jsonDecode(json))).toList();
  }
  
  static Future<void> removeFromQueue(String id) async {
    final prefs = await SharedPreferences.getInstance();
    final queueJson = prefs.getStringList(_queueKey) ?? [];
    queueJson.removeWhere((json) {
      final item = UploadItem.fromJson(jsonDecode(json));
      return item.id == id;
    });
    await prefs.setStringList(_queueKey, queueJson);
  }
  
  static Future<bool> hasConnectivity() async {
    final connectivityResult = await Connectivity().checkConnectivity();
    return connectivityResult.first != ConnectivityResult.none;
  }
  
  static Future<void> processQueue() async {
    if (!await hasConnectivity()) return;
    
    final queue = await getQueue();
    for (final item in queue) {
      try {
        final success = await _uploadImage(item);
        if (success) {
          await removeFromQueue(item.id);
          await FirebaseConfig.logEvent(
            eventType: 'upload_queue_success',
            description: 'Queued upload successful',
            details: {'itemId': item.id, 'docId': item.docId},
          );
        }
      } catch (e) {
        await FirebaseConfig.logEvent(
          eventType: 'upload_queue_error',
          description: 'Queued upload failed',
          details: {'itemId': item.id, 'error': e.toString()},
        );
      }
    }
  }
  
  static Future<bool> _uploadImage(UploadItem item) async {
    try {
      final file = File(item.imagePath);
      if (!await file.exists()) return false;
      
      var request = http.MultipartRequest(
        'POST',
        Uri.parse('http://80.225.203.181:8081/api/images/upload'),
      );
      request.files.add(await http.MultipartFile.fromPath('file', item.imagePath));
      request.fields['userId'] = item.userId;
      
      final response = await request.send().timeout(Duration(seconds: 30));
      return response.statusCode == 200;
    } catch (e) {
      return false;
    }
  }
}

class UploadItem {
  final String id;
  final String imagePath;
  final String userId;
  final String docId;
  final DateTime createdAt;
  
  UploadItem({
    required this.id,
    required this.imagePath,
    required this.userId,
    required this.docId,
    required this.createdAt,
  });
  
  Map<String, dynamic> toJson() => {
    'id': id,
    'imagePath': imagePath,
    'userId': userId,
    'docId': docId,
    'createdAt': createdAt.toIso8601String(),
  };
  
  factory UploadItem.fromJson(Map<String, dynamic> json) => UploadItem(
    id: json['id'],
    imagePath: json['imagePath'],
    userId: json['userId'],
    docId: json['docId'],
    createdAt: DateTime.parse(json['createdAt']),
  );
}

@pragma('vm:entry-point')
void onStart(ServiceInstance service) async {
  // Process queue every 15 minutes
  service.on('stopService').listen((event) {
    service.stopSelf();
  });
  
  while (true) {
    await UploadQueueService.processQueue();
    await Future.delayed(Duration(minutes: 15));
  }
}

@pragma('vm:entry-point')
Future<bool> onIosBackground(ServiceInstance service) async {
  return true;
}