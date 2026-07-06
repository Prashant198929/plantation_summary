import 'dart:io';
import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'firebase_config.dart';

class UploadQueueService {
  static const String _queueKey = 'upload_queue';

  static Future<void> initialize() async {
    final service = FlutterBackgroundService();
    await service.configure(
      iosConfiguration: IosConfiguration(
        autoStart: false,           // Issue 8 fix: don't auto-start; only start when queue has items
        onForeground: onStart,
        onBackground: onIosBackground,
      ),
      androidConfiguration: AndroidConfiguration(
        autoStart: false,           // Issue 8 fix
        onStart: onStart,
        isForegroundMode: false,
        autoStartOnBoot: false,     // Issue 8 fix: no point running on boot with empty queue
      ),
    );
  }

  static Future<void> addToQueue(UploadItem item) async {
    final prefs = await SharedPreferences.getInstance();
    final queueJson = prefs.getStringList(_queueKey) ?? [];
    queueJson.add(jsonEncode(item.toJson()));
    await prefs.setStringList(_queueKey, queueJson);

    // Start background service only when there is actually something to upload
    final service = FlutterBackgroundService();
    if (!await service.isRunning()) {
      await service.startService();
    }
  }

  static Future<List<UploadItem>> getQueue() async {
    final prefs = await SharedPreferences.getInstance();
    final queueJson = prefs.getStringList(_queueKey) ?? [];
    return queueJson
        .map((json) => UploadItem.fromJson(jsonDecode(json)))
        .toList();
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
    try {
      final connectivityResult = await Connectivity().checkConnectivity();
      for (var result in connectivityResult) {
        if (result != ConnectivityResult.none) return true;
      }
      return false;
    } catch (_) {
      return false;
    }
  }

  static Future<void> processQueue() async {
    if (!await hasConnectivity()) return;

    final queue = await getQueue();
    for (final item in queue) {
      // Issue 5 fix: stale item whose local file was deleted — remove it, don't retry forever
      if (!File(item.imagePath).existsSync()) {
        await removeFromQueue(item.id);
        await FirebaseConfig.logEvent(
          eventType: 'upload_queue_stale',
          description: 'Queued upload removed — local file no longer exists',
          isImportant: true,
          details: {'itemId': item.id, 'imagePath': item.imagePath},
        );
        continue;
      }

      try {
        final imageUrl = await _uploadImage(item);
        if (imageUrl != null) {
          await removeFromQueue(item.id);
          await FirebaseFirestore.instance
              .collection('plantation_records')
              .doc(item.docId)
              .update({
            'imageUrl': imageUrl,
            'uploadStatus': 'uploaded',
          });

          await FirebaseConfig.logEvent(
            eventType: 'upload_queue_success',
            description: 'Queued upload successful',
            isImportant: true,
            details: {
              'itemId': item.id,
              'docId': item.docId,
              'imageUrl': imageUrl,
            },
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

  static Future<String?> _uploadImage(UploadItem item) async {
    try {
      final file = File(item.imagePath);
      // Derive extension from filename — handles both new ('jpg') and old ('Mango_1_Zone88.jpg') formats
      final ext = item.filename.contains('.')
          ? item.filename.split('.').last
          : item.filename.isNotEmpty ? item.filename : 'jpg';
      final ref = FirebaseStorage.instance.ref('images/${item.docId}.$ext');
      await ref.putFile(file);
      return await ref.getDownloadURL();
    } catch (_) {
      return null;
    }
  }
}

class UploadItem {
  final String id;
  final String imagePath;
  final String filename; // Issue 6 fix: added so retry uses the correct server filename
  final String userId;
  final String docId;
  final DateTime createdAt;

  UploadItem({
    required this.id,
    required this.imagePath,
    required this.filename,
    required this.userId,
    required this.docId,
    required this.createdAt,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'imagePath': imagePath,
        'filename': filename,
        'userId': userId,
        'docId': docId,
        'createdAt': createdAt.toIso8601String(),
      };

  factory UploadItem.fromJson(Map<String, dynamic> json) => UploadItem(
        id: json['id'],
        imagePath: json['imagePath'],
        filename: json['filename'] ?? '', // graceful fallback for old queue items
        userId: json['userId'],
        docId: json['docId'],
        createdAt: DateTime.parse(json['createdAt']),
      );
}

@pragma('vm:entry-point')
void onStart(ServiceInstance service) async {
  service.on('stopService').listen((event) {
    service.stopSelf();
  });

  while (true) {
    await UploadQueueService.processQueue();

    // Issue 8 fix: stop the service when queue is empty — it restarts automatically
    // via addToQueue() the next time an item needs uploading
    final remaining = await UploadQueueService.getQueue();
    if (remaining.isEmpty) {
      service.stopSelf();
      return;
    }

    await Future.delayed(const Duration(minutes: 15));
  }
}

@pragma('vm:entry-point')
Future<bool> onIosBackground(ServiceInstance service) async {
  return true;
}
