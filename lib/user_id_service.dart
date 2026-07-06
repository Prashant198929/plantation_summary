import 'package:cloud_firestore/cloud_firestore.dart';

// Assigns clean, sequential, human-readable IDs for new users — used for
// display in reports/attendance instead of Firebase Auth's random UID.
// Firestore has no native auto-increment, so this uses a transactional
// counter document to avoid collisions between concurrent registrations.
//
// The counter is seeded to MAX(MemberMasterId) from the legacy sevakdb
// import, so IDs assigned here never collide with historical member IDs
// once that data is imported into this collection.
class UserIdService {
  static final DocumentReference<Map<String, dynamic>> _counterRef =
      FirebaseFirestore.instance.collection('counters').doc('userId');

  static Future<String> nextId() {
    return FirebaseFirestore.instance.runTransaction<String>((transaction) async {
      final snapshot = await transaction.get(_counterRef);
      final current = (snapshot.data()?['value'] as num?)?.toInt() ?? 0;
      final next = current + 1;
      transaction.set(_counterRef, {'value': next}, SetOptions(merge: true));
      return next.toString();
    });
  }
}
