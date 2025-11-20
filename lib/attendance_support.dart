import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_core/firebase_core.dart';
import 'main.dart';

class AttendanceSupport {
  static Future<FirebaseApp?> initializeSecondaryApp(
    FirebaseFirestore? secondaryFirestore,
  ) async {
    if (secondaryFirestore != null) {
      print('Firebase already initialized, skipping initialization');
      return null;
    }
    try {
      FirebaseApp? secondaryApp;
      print('Attempting to get existing Firebase app "hajeri"...');
      try {
        secondaryApp = Firebase.app('hajeri');
        print('Successfully retrieved hajeri app');
      } catch (e) {
        print('[INFO] Firebase app "hajeri" not found, initializing new app...');
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
      print('Initializing Firestore instance...');
      return secondaryApp;
    } catch (e) {
      print('Error initializing secondary app: $e');
      print('Stack trace: ${StackTrace.current}');
      return null;
    }
  }

  static Future<List<String>> fetchTopics(
    FirebaseFirestore? secondaryFirestore,
  ) async {
    if (secondaryFirestore == null) return [];
    try {
      final query = secondaryFirestore
          .collection('WorkForm')
          .orderBy('Topic', descending: false);
      final topicsSnapshot = await query.get().timeout(Duration(seconds: 10));
      final topics = topicsSnapshot.docs
          .map(
            (doc) => (doc.data() as Map<String, dynamic>)['Topic'] as String?,
          )
          .where((topic) => topic != null && topic.isNotEmpty)
          .cast<String>()
          .toList();
      return topics;
    } catch (e) {
      print('Error fetching topics: $e');
      return [];
    }
  }

  static Future<List<String>> fetchPlaces(
    FirebaseFirestore? secondaryFirestore,
  ) async {
    if (secondaryFirestore == null) return [];
    try {
      final snapshot = await secondaryFirestore
          .collection('Places')
          .orderBy('PlaceName', descending: false)
          .get();
      final places = snapshot.docs
          .map(
            (doc) =>
                (doc.data() as Map<String, dynamic>)['PlaceName'] as String?,
          )
          .where((placeName) => placeName != null && placeName.isNotEmpty)
          .cast<String>()
          .toList();
      return places;
    } catch (e) {
      print('Error fetching places: $e');
      return [];
    }
  }

  static Future<List<Map<String, dynamic>>> fetchZoneUsers(
    FirebaseFirestore? secondaryFirestore,
    String? currentZone,
  ) async {
    if (secondaryFirestore == null || currentZone == null) return [];
    try {
      final zoneQuery = (currentZone ?? '').trim().toLowerCase();
      print('Querying users for zone: "$zoneQuery"');
      final snapshot = await secondaryFirestore!.collection('users').get();
      print('Fetched ${snapshot.docs.length} users from Firestore');
      for (final doc in snapshot.docs) {
        final data = doc.data() as Map<String, dynamic>;
        print('User: ${data['name']}, raw zone: "${data['zone']}"');
      }
      final users = snapshot.docs
          .where((doc) {
            final data = doc.data() as Map<String, dynamic>;
            final userZone = (data['zone'] ?? '')
                .toString()
                .trim()
                .toLowerCase();
            return userZone == zoneQuery;
          })
          .map((doc) {
            final data = doc.data() as Map<String, dynamic>;
            return {
              'uid': doc.id,
              'name': data['name'] ?? '',
              'mobile': data['mobile'] ?? '',
              'zone': data['zone'] ?? '',
            };
          })
          .toList();
      print('Matched ${users.length} users for zone "$zoneQuery"');
      return users;
    } catch (e) {
      print('Error fetching zone users: $e');
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
      print('Error fetching user zone: $e');
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
