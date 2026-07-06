import 'package:flutter/foundation.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

class FirebaseConfig {
  static FirebaseApp? _app;
  static FirebaseFirestore? _firestore;

  static final FirebaseOptions vrukshamojaniattendancelogsOptions = FirebaseOptions(
    apiKey: 'AIzaSyCfCKHjzCuuOTt8dZFJc-VDAPuFrkaaQVY',
    appId: '1:436597351597:android:c7ff2ff0649734e5325224',
    messagingSenderId: '436597351597',
    projectId: 'vrukshamojaniattendancelogs',
    storageBucket: 'vrukshamojaniattendancelogs.firebasestorage.app',
  );

  static Future<FirebaseApp> initialize() async {
    final existing = Firebase.apps.where((a) => a.options.projectId == vrukshamojaniattendancelogsOptions.projectId);
    if (existing.isNotEmpty) {
      _app = existing.first;
    } else {
      _app = await Firebase.initializeApp(
        name: 'vrukshamojaniattendancelogs',
        options: vrukshamojaniattendancelogsOptions,
      );
    }
    _firestore = FirebaseFirestore.instanceFor(app: _app!);
    return _app!;
  }

  static FirebaseFirestore get firestore {
    if (_firestore == null) {
      throw Exception('Firebase not initialized. Call FirebaseConfig.initialize first.');
    }
    return _firestore!;
  }

  static bool _isErrorEvent(String eventType) {
    final lower = eventType.toLowerCase();
    return lower.contains('error') ||
        lower.contains('failed') ||
        lower.contains('failure') ||
        lower.contains('exception');
  }

  static Future<void> logEvent({
    required String eventType,
    required String description,
    String? userId,
    Map<String, dynamic>? details,
    String collectionName = 'Register_Logs',
    bool isError = false,
    bool isImportant = false,
  }) async {
    final now = DateTime.now();
    final logLine = '[${now.toIso8601String()}] [$eventType] $description | userId: ${userId ?? "unknown"} | details: ${details ?? {}}';

    if (kDebugMode) debugPrint(logLine);

    if (!isError && !isImportant && !_isErrorEvent(eventType)) return;

    final dateKey = '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
    final logDoc = await firestore.collection(collectionName).doc(dateKey).get();
    String allLogs = logDoc.exists && logDoc.data()?['logs'] is String ? logDoc.data()!['logs'] as String : '';
    allLogs += logLine + '\n';
    await firestore.collection(collectionName).doc(dateKey).set({'logs': allLogs});
  }
}
