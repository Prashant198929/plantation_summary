import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_core/firebase_core.dart';
import 'main.dart';
import 'mobile_encryption_service.dart';

class AttendanceSupport {
  static Future<FirebaseApp?> initializeSecondaryApp(
    FirebaseFirestore? secondaryFirestore,
  ) async {
    if (secondaryFirestore != null) {
      debugPrint('Firebase already initialized, skipping initialization');
      return null;
    }
    try {
      FirebaseApp? secondaryApp;
      try {
        secondaryApp = Firebase.app('hajeri');
      } catch (e) {
        secondaryApp = await Firebase.initializeApp(
          name: 'hajeri',
          options: const FirebaseOptions(
            apiKey: 'AIzaSyCje2njYdWIMEw1GkNNYbbd2H9g8bYot0c',
            appId: '1:769594690843:android:e1731d35814b10c12e57be',
            messagingSenderId: '769594690843',
            projectId: 'hajeri-465b7',
            storageBucket: 'hajeri-465b7.firebasestorage.app',
          ),
        );
      }
      return secondaryApp;
    } catch (e) {
      debugPrint('Error initializing secondary app: $e');
      return null;
    }
  }

  static Future<List<String>> fetchTopics(
    FirebaseFirestore? secondaryFirestore,
  ) async {
    if (secondaryFirestore == null) return [];
    try {
      final topicsSnapshot = await secondaryFirestore
          .collection('WorkForm')
          .orderBy('Topic', descending: false)
          .get()
          .timeout(Duration(seconds: 10));
      return topicsSnapshot.docs
          .map((doc) => (doc.data())['Topic'] as String?)
          .where((t) => t != null && t.isNotEmpty)
          .cast<String>()
          .toList();
    } catch (e) {
      debugPrint('Error fetching topics: $e');
      return [];
    }
  }

  static Future<List<Map<String, dynamic>>> fetchPlaces(
    FirebaseFirestore? secondaryFirestore,
  ) async {
    if (secondaryFirestore == null) return [];
    try {
      final snapshot = await secondaryFirestore
          .collection('Places')
          .orderBy('PlaceName', descending: false)
          .get();
      return snapshot.docs
          .map((doc) {
            final data = doc.data() as Map<String, dynamic>;
            final placeName = (data['PlaceName'] ?? '') as String;
            return <String, dynamic>{
              'placeName': placeName,
              'locationEn': (data['Location_En'] ?? placeName) as String,
              'locationMr': (data['Location_Mr'] ?? placeName) as String,
            };
          })
          .where((p) => (p['placeName'] as String).isNotEmpty)
          .toList();
    } catch (e) {
      debugPrint('Error fetching places: $e');
      return [];
    }
  }

  static const List<String> _monthNames = [
    'January',
    'February',
    'March',
    'April',
    'May',
    'June',
    'July',
    'August',
    'September',
    'October',
    'November',
    'December',
  ];

  static String monthYearKey(DateTime date) {
    return '${_monthNames[date.month - 1]}_${date.year}';
  }

  static List<String> monthYearKeysBetween(DateTime start, DateTime end) {
    final keys = <String>[];
    DateTime cursor = DateTime(start.year, start.month);
    final endMonth = DateTime(end.year, end.month);
    while (cursor.isBefore(endMonth) || cursor == endMonth) {
      keys.add(monthYearKey(cursor));
      cursor = DateTime(cursor.year, cursor.month + 1);
    }
    return keys;
  }

  static String _normalizeZone(String? zone) {
    if (zone == null) return '';
    final trimmed = zone.toString().trim().toLowerCase();
    if (trimmed.isEmpty) return '';
    final digits = RegExp(r'(\d+)').firstMatch(trimmed)?.group(1) ?? '';
    return digits.isNotEmpty ? digits : trimmed;
  }

  // Some users (e.g. imported from the old SQL data, or custom zone entries
  // at registration) have an English 'zone' like "Zone 1" with no 'zone_mr'
  // filled in. Deriving zone_mr from the zone number keeps attendance records
  // in Marathi instead of leaking the English label through the fallback.
  static String toMarathiZoneLabel(String zone) {
    final trimmed = zone.trim();
    if (trimmed.isEmpty) return '';
    if (trimmed.startsWith('झोन')) return trimmed;
    final digits = RegExp(r'(\d+)').firstMatch(trimmed)?.group(1) ?? '';
    return digits.isNotEmpty ? 'झोन $digits' : trimmed;
  }

  static Future<List<Map<String, dynamic>>> fetchZoneUsers(
    FirebaseFirestore? secondaryFirestore,
    String? currentZone,
  ) async {
    if (secondaryFirestore == null || currentZone == null) return [];
    try {
      final zoneQueryRaw = (currentZone ?? '').trim();
      final zoneQueryLower = zoneQueryRaw.toLowerCase();
      final zoneQueryNormalized = _normalizeZone(zoneQueryRaw);
      final snapshot = await secondaryFirestore!.collection('users').get();
      final users = snapshot.docs
          .where((doc) {
            final data = doc.data() as Map<String, dynamic>;
            final userZoneRaw = (data['zone'] ?? '').toString().trim();
            final userZoneLower = userZoneRaw.toLowerCase();
            final userZoneNormalized = _normalizeZone(userZoneRaw);
            if (zoneQueryNormalized.isNotEmpty &&
                userZoneNormalized.isNotEmpty) {
              return userZoneNormalized == zoneQueryNormalized;
            }
            return userZoneLower == zoneQueryLower;
          })
          .map((doc) {
            final data = doc.data() as Map<String, dynamic>;
            final storedMobile = data['mobile']?.toString();
            final mobile = storedMobile == null || storedMobile.isEmpty
                ? ''
                : (MobileEncryptionService.decrypt(storedMobile) ?? storedMobile);
            return {
              'uid': data['uid'] ?? doc.id,
              'name': data['name'] ?? '',
              'name_mr': data['name_mr'] ?? '',
              'mobile': mobile,
              'zone': data['zone'] ?? '',
              'zone_mr': data['zone_mr'] ?? '',
              'baithak': data['baithakPlace'] ?? data['baithak'] ?? '',
              'baithak_mr': data['baithak_mr'] ?? '',
              'baithak_day': data['baithak_day'] ?? '',
              'baithak_day_mr': data['baithak_day_mr'] ?? '',
              'hajeri_kramank': data['baithakNo'] ?? data['hajeri_kramank'] ?? '',
              'hall': data['hall'] ?? '',
              'hall_mr': data['hall_mr'] ?? '',
              'gender': data['gender'] ?? '',
              'dob': data['dob'] ?? '',
              'isActive': data['isActive'] ?? true,
            };
          })
          .toList();
      debugPrint('Matched ${users.length} users for zone "$zoneQueryRaw"');
      return users;
    } catch (e) {
      debugPrint('Error fetching zone users: $e');
      return [];
    }
  }

  static Future<String?> fetchCurrentUserZone(BuildContext context) async {
    try {
      final userDetails = await getCurrentUserDetails(context);
      if (userDetails != null && userDetails['zone'] != null) {
        return userDetails['zone'];
      } else {
        return 'Not Assigned';
      }
    } catch (e) {
      debugPrint('Error fetching user zone: $e');
      return 'Not Assigned';
    }
  }

  static Future<DateTime?> selectDate(
    BuildContext context,
    DateTime initialDate,
  ) async {
    DateTime selectedDate = initialDate;
    return await showDialog<DateTime>(
      context: context,
      builder: (BuildContext context) {
        return CupertinoAlertDialog(
          content: SizedBox(
            height: 250,
            child: CupertinoDatePicker(
              mode: CupertinoDatePickerMode.date,
              initialDateTime: initialDate,
              minimumDate: DateTime(2020),
              maximumDate: DateTime(2100),
              onDateTimeChanged: (DateTime newDate) {
                selectedDate = newDate;
              },
            ),
          ),
          actions: [
            CupertinoDialogAction(
              child: Text('Cancel'),
              onPressed: () => Navigator.of(context).pop(null),
            ),
            CupertinoDialogAction(
              child: Text('OK'),
              onPressed: () => Navigator.of(context).pop(selectedDate),
            ),
          ],
        );
      },
    );
  }
}
