import 'package:flutter/material.dart';
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

  // Digits from the zone name (e.g. "Zone 42" / "झोन 42" -> "42"), matching
  // functions/migration_lib.js's zoneKey() exactly so live-marked attendance
  // docIds land in the same invertedDate_uid_zoneKey scheme already used by
  // historical sevakdb-migrated records.
  static String zoneKey(String zone) => _normalizeZone(zone);

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

  // The 'zones' collection only stores the Marathi name (e.g. "झोन 1"), so
  // this derives the English label for display, rather than leaking Marathi
  // into the English 'zone' field.
  static String toEnglishZoneLabel(String zone) {
    final trimmed = zone.trim();
    if (trimmed.isEmpty) return '';
    final digits = RegExp(r'(\d+)').firstMatch(trimmed)?.group(1) ?? '';
    return digits.isNotEmpty ? 'Zone $digits' : trimmed;
  }

  // Zone names carry their order as a number embedded in the string ("झोन
  // 7" / "Zone 7"), so plain string sort puts "झोन 10" before "झोन 2" — this
  // compares by that number instead, for every zone dropdown/list in the app.
  static int compareZoneNames(String a, String b) {
    final numA = int.tryParse(RegExp(r'\d+').firstMatch(a)?.group(0) ?? '');
    final numB = int.tryParse(RegExp(r'\d+').firstMatch(b)?.group(0) ?? '');
    if (numA != null && numB != null) return numA.compareTo(numB);
    if (numA != null) return -1;
    if (numB != null) return 1;
    return a.compareTo(b);
  }

  static const Map<String, String> _baithakDayMr = {
    'monday': 'सोमवार',
    'tuesday': 'मंगळवार',
    'wednesday': 'बुधवार',
    'thursday': 'गुरुवार',
    'friday': 'शुक्रवार',
    'saturday': 'शनिवार',
    'sunday': 'रविवार',
  };

  // Registration only requires the English 'baithak_day' (a dropdown), with
  // 'baithak_day_mr' auto-filled from it — but some records only ever got the
  // English value stored, so this covers that gap for display.
  static String toMarathiDayLabel(String day) {
    final trimmed = day.trim();
    if (trimmed.isEmpty) return '';
    return _baithakDayMr[trimmed.toLowerCase()] ?? trimmed;
  }

  // Reverse of _baithakDayMr — used to derive the English 'baithak_day' to
  // store when a session is picked from its Marathi label (BaithakSessions
  // only carries Day_mr).
  static String toEnglishDayLabel(String dayMr) {
    final trimmed = dayMr.trim();
    if (trimmed.isEmpty) return '';
    for (final entry in _baithakDayMr.entries) {
      if (entry.value == trimmed) {
        return entry.key[0].toUpperCase() + entry.key.substring(1);
      }
    }
    return trimmed;
  }

  static Future<List<Map<String, dynamic>>> _fetchMappedUsers(
    FirebaseFirestore firestore,
  ) async {
    final snapshot = await firestore.collection('Shree_Sadasya').get();
    return snapshot.docs.map((doc) {
      final data = doc.data() as Map<String, dynamic>;
      final storedMobile = data['mobile']?.toString();
      final mobile = storedMobile == null || storedMobile.isEmpty
          ? ''
          : (MobileEncryptionService.decrypt(storedMobile) ?? storedMobile);
      return {
        'docId': doc.id,
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
        'gender': data['gender'] ?? '',
        'dob': data['dob'] ?? '',
        'email': data['email'] ?? '',
        'vehicles': data['vehicles'] ?? [],
        'isActive': data['isActive'] ?? true,
      };
    }).toList();
  }

  static Future<List<Map<String, dynamic>>> fetchZoneUsers(
    FirebaseFirestore? secondaryFirestore,
    String? currentZone,
  ) async {
    if (secondaryFirestore == null || currentZone == null) return [];
    try {
      final zoneQueryRaw = currentZone.trim();
      final zoneQueryLower = zoneQueryRaw.toLowerCase();
      final zoneQueryNormalized = _normalizeZone(zoneQueryRaw);
      final allUsers = await _fetchMappedUsers(secondaryFirestore);
      final users = allUsers.where((data) {
        final userZoneRaw = (data['zone'] ?? '').toString().trim();
        final userZoneLower = userZoneRaw.toLowerCase();
        final userZoneNormalized = _normalizeZone(userZoneRaw);
        if (zoneQueryNormalized.isNotEmpty && userZoneNormalized.isNotEmpty) {
          return userZoneNormalized == zoneQueryNormalized;
        }
        return userZoneLower == zoneQueryLower;
      }).toList();
      debugPrint('Matched ${users.length} users for zone "$zoneQueryRaw"');
      return users;
    } catch (e) {
      debugPrint('Error fetching zone users: $e');
      return [];
    }
  }

  // Migrated users' baithak_mr sometimes carries an extra comma that the
  // BaithakSessions/BaithakHalls spelling of the same venue doesn't (e.g.
  // "श्री. भरत म्हसकर, म्हास्करवाडा" vs "श्री. भरत म्हसकर म्हास्करवाडा"), so
  // comparisons here strip punctuation/whitespace differences rather than
  // requiring an exact match.
  static String _normalizePlaceName(String value) =>
      value.replaceAll(',', ' ').replaceAll(RegExp(r'\s+'), ' ').trim();

  // Public wrapper so callers outside this file (e.g. matching a fetched
  // attendance record's baithak_mr against the currently selected hall) can
  // reuse the same punctuation/whitespace-tolerant comparison.
  static String normalizePlaceName(String value) => _normalizePlaceName(value);

  // A baithak session (one hall meeting on one specific day) groups users
  // across zone boundaries, so this looks up by baithak_mr / baithak_day_mr
  // directly on the users collection rather than reusing the zone-scoped
  // fetch above.
  static Future<List<Map<String, dynamic>>> fetchUsersByHallAndDay(
    FirebaseFirestore? userFirestore,
    String? hallMr,
    String? dayMr,
  ) async {
    final hall = (hallMr ?? '').trim();
    final day = (dayMr ?? '').trim();
    if (userFirestore == null || (hall.isEmpty && day.isEmpty)) {
      return [];
    }
    try {
      final normalizedHall = _normalizePlaceName(hall);
      final allUsers = await _fetchMappedUsers(userFirestore);
      final users = allUsers.where((data) {
        if (hall.isNotEmpty &&
            _normalizePlaceName((data['baithak_mr'] ?? '').toString()) !=
                normalizedHall) {
          return false;
        }
        if (day.isNotEmpty &&
            (data['baithak_day_mr'] ?? '').toString().trim() != day) {
          return false;
        }
        return true;
      }).toList();
      debugPrint('Matched ${users.length} users for hall "$hall" / day "$day"');
      return users;
    } catch (e) {
      debugPrint('Error fetching hall/day users: $e');
      return [];
    }
  }

  // Used for the cross-zone "find a member" search — matches on name, the
  // Marathi name, or mobile number across every user regardless of zone.
  static Future<List<Map<String, dynamic>>> searchUsers(
    FirebaseFirestore? userFirestore,
    String query,
  ) async {
    if (userFirestore == null) return [];
    final trimmedQuery = query.trim();
    if (trimmedQuery.isEmpty) return [];
    final lowerQuery = trimmedQuery.toLowerCase();
    try {
      final allUsers = await _fetchMappedUsers(userFirestore);
      return allUsers.where((data) {
        final name = (data['name'] ?? '').toString().toLowerCase();
        final nameMr = (data['name_mr'] ?? '').toString().toLowerCase();
        final mobile = (data['mobile'] ?? '').toString();
        return name.contains(lowerQuery) ||
            nameMr.contains(lowerQuery) ||
            mobile.contains(trimmedQuery);
      }).toList();
    } catch (e) {
      debugPrint('Error searching users: $e');
      return [];
    }
  }

  // Each doc is one real baithak session (a hall on one specific day it
  // actually meets) — not every hall meets every day, and some halls meet on
  // more than one day, so this is a flat list rather than a hall x day
  // cross-join. Each entry carries Hall_mr/Day_mr split out for filtering
  // alongside the combined Session_mr label for display.
  static Future<List<Map<String, dynamic>>> fetchBaithakSessions(
    FirebaseFirestore? secondaryFirestore,
  ) async {
    if (secondaryFirestore == null) return [];
    try {
      final snapshot = await secondaryFirestore
          .collection('BaithakSessions')
          .orderBy('Session_mr', descending: false)
          .get();
      return snapshot.docs
          .map((doc) {
            final data = doc.data();
            return <String, dynamic>{
              'Session_mr': (data['Session_mr'] ?? '').toString(),
              'Hall_mr': (data['Hall_mr'] ?? '').toString(),
              'Hall_En': (data['Hall_En'] ?? '').toString(),
              'Day_mr': (data['Day_mr'] ?? '').toString(),
              'Day': (data['Day'] ?? '').toString(),
              'Zone': (data['Zone'] ?? '').toString(),
              'Zone_mr': (data['Zone_mr'] ?? '').toString(),
            };
          })
          .where((s) => (s['Session_mr'] as String).isNotEmpty)
          .toList();
    } catch (e) {
      debugPrint('Error fetching baithak sessions: $e');
      return [];
    }
  }

  // Scopes the baithak hall dropdown to a single member's own hall (used for
  // non-admin users, who should only ever mark attendance at their own
  // baithak) — reuses the same punctuation/whitespace-tolerant comparison as
  // fetchUsersByHallAndDay so a comma difference doesn't hide the match.
  static List<Map<String, dynamic>> filterSessionsByHall(
    List<Map<String, dynamic>> sessions,
    String? hallMr,
  ) {
    final hall = (hallMr ?? '').trim();
    if (hall.isEmpty) return [];
    final normalizedHall = _normalizePlaceName(hall);
    return sessions
        .where(
          (s) =>
              _normalizePlaceName((s['Hall_mr'] ?? '').toString()) ==
              normalizedHall,
        )
        .toList();
  }

  // Builds the "<Hall_mr>, <Day_mr> (<Hall_En>, <Day_En>)" label from a raw
  // session map (as returned by fetchBaithakSessions) — the single source of
  // truth for how a baithak session is displayed, so every hall/session
  // dropdown in the app (Add User forms, self-registration, attendance
  // marking) reads identically instead of drifting into its own format, e.g.
  // "श्री. भास्कर गायकर, गोळवली, गुरुवार (Shree Bhaskar Gaikar, Golavli, Thursday)".
  //
  // Built from Hall_mr/Day_mr rather than the doc's own Session_mr, because
  // some BaithakSessions docs bake a "(झोन N)" disambiguator into Session_mr
  // itself — needed there since a hall+day can host more than one session
  // under different zones, and Session_mr is the doc ID so it must stay
  // unique — but that zone suffix should never leak into the display label.
  static String sessionLabel(Map<String, dynamic> session) {
    final hallMr = (session['Hall_mr'] as String? ?? '').trim();
    final hallEn = (session['Hall_En'] as String? ?? '').trim();
    final dayMr = (session['Day_mr'] as String? ?? '').trim();
    // Read straight off the doc's own 'Day' field now that it's backfilled,
    // falling back to the Marathi->English map only for a doc that somehow
    // predates the backfill.
    final storedDayEn = (session['Day'] as String? ?? '').trim();
    final dayEn = storedDayEn.isNotEmpty
        ? storedDayEn
        : toEnglishDayLabel(dayMr);
    final cleanSessionMr = dayMr.isNotEmpty ? '$hallMr, $dayMr' : hallMr;
    return hallEn.isNotEmpty
        ? '$cleanSessionMr ($hallEn, $dayEn)'
        : cleanSessionMr;
  }

  // Combined बैठक ठिकाण options for the Add User form — one entry per real
  // baithak session (hall + day), sourced from 'BaithakSessions' so a single
  // pick fills baithakPlace/baithak_mr/baithak_day/baithak_day_mr together
  // instead of 4 separate fields. `label` is built by sessionLabel above.
  static Future<List<Map<String, String>>> fetchBaithakSessionOptions(
    FirebaseFirestore? secondaryFirestore,
  ) async {
    final sessions = await fetchBaithakSessions(secondaryFirestore);
    return sessions
        .map((s) {
          final sessionMr = (s['Session_mr'] as String? ?? '').trim();
          final hallMr = (s['Hall_mr'] as String? ?? '').trim();
          final hallEn = (s['Hall_En'] as String? ?? '').trim();
          final dayMr = (s['Day_mr'] as String? ?? '').trim();
          final storedDayEn = (s['Day'] as String? ?? '').trim();
          final dayEn = storedDayEn.isNotEmpty
              ? storedDayEn
              : toEnglishDayLabel(dayMr);
          final label = sessionLabel(s);
          final zone = (s['Zone'] as String? ?? '').trim();
          final zoneMr = (s['Zone_mr'] as String? ?? '').trim();
          return <String, String>{
            'sessionMr': sessionMr,
            'hallMr': hallMr,
            'hallEn': hallEn,
            'dayMr': dayMr,
            'dayEn': dayEn,
            'label': label,
            'zone': zone,
            'zoneMr': zoneMr,
          };
        })
        .where((o) => o['sessionMr']!.isNotEmpty)
        .toList();
  }

  // Baithak place options (English + Marathi) for the Add User form's
  // बैठक ठिकाण dropdown, sourced from 'BaithakHalls' so the English
  // selection and its Marathi label always come from the same record.
  static Future<List<Map<String, String>>> fetchBaithakPlaceOptions(
    FirebaseFirestore? secondaryFirestore,
  ) async {
    if (secondaryFirestore == null) return [];
    try {
      final snapshot = await secondaryFirestore
          .collection('BaithakHalls')
          .orderBy('HallName_mr', descending: false)
          .get();
      return snapshot.docs
          .map((doc) {
            final data = doc.data();
            return <String, String>{
              'en': (data['HallName_en'] ?? '').toString().trim(),
              'mr': (data['HallName_mr'] ?? '').toString().trim(),
            };
          })
          .where((o) => o['en']!.isNotEmpty)
          .toList();
    } catch (e) {
      debugPrint('Error fetching baithak place options: $e');
      return [];
    }
  }

  // बैठक ठिकाण dropdown for the user-management edit dialog — sourced from
  // 'BaithakSessions' rather than 'BaithakHalls' directly (per product
  // decision, so it only ever lists halls that actually have a session),
  // deduped by Hall_mr since one hall can have several day sessions. Needs
  // the one-time Hall_En backfill onto BaithakSessions to have an English
  // name to show at all (see migrate_baithak_sessions_hall_en.js).
  static Future<List<Map<String, String>>> fetchBaithakHallOptions(
    FirebaseFirestore? secondaryFirestore,
  ) async {
    final sessions = await fetchBaithakSessions(secondaryFirestore);
    final seenHallMr = <String>{};
    final options = <Map<String, String>>[];
    for (final s in sessions) {
      final hallMr = (s['Hall_mr'] as String? ?? '').trim();
      final hallEn = (s['Hall_En'] as String? ?? '').trim();
      if (hallMr.isEmpty || hallEn.isEmpty || !seenHallMr.add(hallMr)) continue;
      options.add({'en': hallEn, 'mr': hallMr});
    }
    options.sort((a, b) => a['en']!.compareTo(b['en']!));
    return options;
  }

  // Vehicle type options for the Add User page's "Add Vehicle" section —
  // lives in the main vrukshamojani project (not hajeri), ordered by the
  // given `order` field rather than alphabetically (so "Dumper" stays last).
  static Future<List<String>> fetchVehicleTypes(
    FirebaseFirestore? userFirestore,
  ) async {
    if (userFirestore == null) return [];
    try {
      final snapshot = await userFirestore
          .collection('Vehicle')
          .orderBy('order', descending: false)
          .get();
      return snapshot.docs
          .map((doc) => (doc.data())['name']?.toString() ?? '')
          .where((name) => name.isNotEmpty)
          .toList();
    } catch (e) {
      debugPrint('Error fetching vehicle types: $e');
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

  // Total historical attendance count per user, tallied from Attendance
  // records across every month doc (they live at
  // Attendance/{monthKey}/records/{docId}, so this needs a collectionGroup
  // query rather than a single collection read). Batched by 30 ids since
  // Firestore's whereIn caps out there.
  static Future<Map<String, int>> fetchAttendanceCounts(
    FirebaseFirestore? secondaryFirestore,
    List<String> userIds,
  ) async {
    if (secondaryFirestore == null) return {};
    final ids = userIds.where((id) => id.isNotEmpty).toSet().toList();
    if (ids.isEmpty) return {};
    final counts = <String, int>{};
    try {
      for (var i = 0; i < ids.length; i += 30) {
        final batch = ids.sublist(i, i + 30 > ids.length ? ids.length : i + 30);
        final snapshot = await secondaryFirestore
            .collectionGroup('records')
            .where('userId', whereIn: batch)
            .get();
        for (final doc in snapshot.docs) {
          final userId = (doc.data())['userId']?.toString();
          if (userId == null || userId.isEmpty) continue;
          counts[userId] = (counts[userId] ?? 0) + 1;
        }
      }
    } catch (e) {
      debugPrint('Error fetching attendance counts: $e');
    }
    return counts;
  }

  // Sorts users by historical attendance count, most-attended first, so
  // pick-lists surface frequent attendees at the top instead of fetch order.
  static List<Map<String, dynamic>> sortByAttendanceCount(
    List<Map<String, dynamic>> users,
    Map<String, int> counts,
  ) {
    final sorted = List<Map<String, dynamic>>.from(users);
    sorted.sort((a, b) {
      final countA = counts[(a['uid'] ?? '').toString()] ?? 0;
      final countB = counts[(b['uid'] ?? '').toString()] ?? 0;
      return countB.compareTo(countA);
    });
    return sorted;
  }

  static Future<DateTime?> selectDate(
    BuildContext context,
    DateTime initialDate, {
    DateTime? minimumDate,
    DateTime? maximumDate,
  }) async {
    return await showDialog<DateTime>(
      context: context,
      builder: (BuildContext context) {
        return _MarathiCalendarDialog(
          initialDate: initialDate,
          minimumDate: minimumDate ?? DateTime(2020),
          maximumDate: maximumDate ?? DateTime(2100),
        );
      },
    );
  }
}

// Marathi weekday headers, ordered Sunday to Saturday.
const List<String> _marathiWeekdaysSunToSat = [
  'रवि',
  'सोम',
  'मंगळ',
  'बुध',
  'गुरु',
  'शुक्र',
  'शनि',
];

const List<String> _marathiMonths = [
  'जानेवारी',
  'फेब्रुवारी',
  'मार्च',
  'एप्रिल',
  'मे',
  'जून',
  'जुलै',
  'ऑगस्ट',
  'सप्टेंबर',
  'ऑक्टोबर',
  'नोव्हेंबर',
  'डिसेंबर',
];

class _MarathiCalendarDialog extends StatefulWidget {
  final DateTime initialDate;
  final DateTime minimumDate;
  final DateTime maximumDate;

  const _MarathiCalendarDialog({
    required this.initialDate,
    required this.minimumDate,
    required this.maximumDate,
  });

  @override
  State<_MarathiCalendarDialog> createState() => _MarathiCalendarDialogState();
}

class _MarathiCalendarDialogState extends State<_MarathiCalendarDialog> {
  late DateTime _selectedDate;
  late DateTime _visibleMonth;

  @override
  void initState() {
    super.initState();
    _selectedDate = widget.initialDate;
    _visibleMonth = DateTime(widget.initialDate.year, widget.initialDate.month);
  }

  bool _isSameDay(DateTime a, DateTime b) {
    return a.year == b.year && a.month == b.month && a.day == b.day;
  }

  bool _isBeforeDay(DateTime a, DateTime b) {
    return DateTime(
      a.year,
      a.month,
      a.day,
    ).isBefore(DateTime(b.year, b.month, b.day));
  }

  bool _isAfterDay(DateTime a, DateTime b) {
    return DateTime(
      a.year,
      a.month,
      a.day,
    ).isAfter(DateTime(b.year, b.month, b.day));
  }

  void _changeMonth(int delta) {
    setState(() {
      _visibleMonth = DateTime(_visibleMonth.year, _visibleMonth.month + delta);
    });
  }

  bool get _canGoPrevMonth {
    final firstOfPrev = DateTime(_visibleMonth.year, _visibleMonth.month - 1);
    final lastOfPrev = DateTime(_visibleMonth.year, _visibleMonth.month, 0);
    return !lastOfPrev.isBefore(
          DateTime(widget.minimumDate.year, widget.minimumDate.month, 1),
        ) ||
        !firstOfPrev.isBefore(
          DateTime(widget.minimumDate.year, widget.minimumDate.month, 1),
        );
  }

  bool get _canGoNextMonth {
    final firstOfNext = DateTime(_visibleMonth.year, _visibleMonth.month + 1);
    return !firstOfNext.isAfter(
      DateTime(widget.maximumDate.year, widget.maximumDate.month, 1),
    );
  }

  @override
  Widget build(BuildContext context) {
    final firstDayOfMonth = DateTime(
      _visibleMonth.year,
      _visibleMonth.month,
      1,
    );
    final daysInMonth = DateTime(
      _visibleMonth.year,
      _visibleMonth.month + 1,
      0,
    ).day;
    // DateTime.weekday: Monday=1 ... Sunday=7. Convert so Sunday=0 ... Saturday=6.
    final leadingBlanks = firstDayOfMonth.weekday % 7;

    final dayCells = <Widget>[];
    for (int i = 0; i < leadingBlanks; i++) {
      dayCells.add(const SizedBox.shrink());
    }
    for (int day = 1; day <= daysInMonth; day++) {
      final date = DateTime(_visibleMonth.year, _visibleMonth.month, day);
      final isSelected = _isSameDay(date, _selectedDate);
      final isDisabled =
          _isBeforeDay(date, widget.minimumDate) ||
          _isAfterDay(date, widget.maximumDate);
      final isToday = _isSameDay(date, DateTime.now());
      dayCells.add(
        GestureDetector(
          onTap: isDisabled ? null : () => setState(() => _selectedDate = date),
          child: Container(
            margin: const EdgeInsets.all(2),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: isSelected ? Colors.green : null,
              shape: BoxShape.circle,
              border: isToday && !isSelected
                  ? Border.all(color: Colors.green)
                  : null,
            ),
            child: Text(
              '$day',
              style: TextStyle(
                color: isDisabled
                    ? Colors.grey.shade400
                    : isSelected
                    ? Colors.white
                    : Colors.black87,
                fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
              ),
            ),
          ),
        ),
      );
    }

    return AlertDialog(
      contentPadding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
      content: SizedBox(
        width: 320,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                IconButton(
                  icon: const Icon(Icons.chevron_left),
                  onPressed: _canGoPrevMonth ? () => _changeMonth(-1) : null,
                ),
                Text(
                  '${_marathiMonths[_visibleMonth.month - 1]} ${_visibleMonth.year}',
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 16,
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.chevron_right),
                  onPressed: _canGoNextMonth ? () => _changeMonth(1) : null,
                ),
              ],
            ),
            GridView.count(
              crossAxisCount: 7,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              children: _marathiWeekdaysSunToSat
                  .map(
                    (label) => Center(
                      child: Text(
                        label,
                        style: const TextStyle(fontWeight: FontWeight.bold),
                      ),
                    ),
                  )
                  .toList(),
            ),
            GridView.count(
              crossAxisCount: 7,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              children: dayCells,
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(null),
          child: const Text('रद्द करा'),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(_selectedDate),
          child: const Text('ठीक आहे'),
        ),
      ],
    );
  }
}
