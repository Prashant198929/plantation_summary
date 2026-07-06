import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'attendee_details.dart';
import 'firebase_config.dart';
import 'attendance_support.dart';

class AttendanceDetails extends StatefulWidget {
  final int year;
  final String? place;
  final String? zone;
  final FirebaseFirestore firestore;
  final DateTime? startDate;
  final DateTime? endDate;

  const AttendanceDetails({
    Key? key,
    required this.year,
    required this.place,
    required this.zone,
    required this.firestore,
    this.startDate,
    this.endDate,
  }) : super(key: key);

  @override
  State<AttendanceDetails> createState() => _AttendanceDetailsState();
}

class _AttendanceDetailsState extends State<AttendanceDetails> {
  Map<int, List<Map<String, dynamic>>> monthMap = {};
  bool isLoading = true;

  String _normalizeZone(String? zone) {
    if (zone == null) return '';
    final trimmed = zone.toString().trim().toLowerCase();
    if (trimmed.isEmpty) return '';
    final digits = RegExp(r'(\d+)').firstMatch(trimmed)?.group(1) ?? '';
    if (digits.isNotEmpty) {
      final parsed = int.tryParse(digits);
      return parsed != null ? parsed.toString() : digits;
    }
    return trimmed;
  }

  String _normalizePlace(String? place) {
    if (place == null) return '';
    final normalized = place
        .toString()
        .trim()
        .toLowerCase()
        .replaceAll(RegExp(r'\s+'), ' ');
    return normalized;
  }

  @override
  void initState() {
    super.initState();
    fetchAttendance();
    Future.microtask(() async {
      await FirebaseConfig.logEvent(
        eventType: 'attendance_details_opened',
        description: 'Attendance details opened',
        details: {
          'year': widget.year,
          'place': widget.place,
          'zone': widget.zone,
        },
      );
    });
  }

  Future<void> fetchAttendance() async {
    for (int m = 1; m <= 12; m++) {
      monthMap[m] = [];
    }
    DateTime start = widget.startDate ?? DateTime(widget.year, 1, 1);
    DateTime end = widget.endDate ?? DateTime(widget.year, 12, 31, 23, 59, 59);
    final monthKeys = AttendanceSupport.monthYearKeysBetween(start, end);
    final allRecords = <Map<String, dynamic>>[];
    for (final key in monthKeys) {
      final snapshot = await widget.firestore
          .collection('Attendance')
          .doc(key)
          .collection('records')
          .where('date', isGreaterThanOrEqualTo: Timestamp.fromDate(start))
          .where('date', isLessThanOrEqualTo: Timestamp.fromDate(end))
          .orderBy('date', descending: false)
          .get();
      for (final doc in snapshot.docs) {
        allRecords.add(doc.data());
      }
    }

    String filterPlace = _normalizePlace(widget.place);
    String filterZone = (widget.zone ?? '').trim().toLowerCase();
    String filterZoneNormalized = _normalizeZone(widget.zone);

    for (final record in allRecords) {
      DateTime? date;
      if (record['date'] is Timestamp) {
        date = (record['date'] as Timestamp).toDate();
      } else if (record['date'] is DateTime) {
        date = record['date'] as DateTime;
      }
      String recordPlace = _normalizePlace((record['Location_Mr'] ?? record['Place'])?.toString());
      String recordZone = (record['zone'] ?? '')
          .toString()
          .trim()
          .toLowerCase();
      String recordZoneNormalized = _normalizeZone(record['zone']?.toString());

      bool zoneMatches = filterZone.isEmpty
          ? true
          : (filterZoneNormalized.isNotEmpty &&
                  recordZoneNormalized.isNotEmpty)
              ? recordZoneNormalized == filterZoneNormalized
              : recordZone == filterZone;

      bool matches =
          date != null &&
          date.year == widget.year &&
          (filterPlace.isEmpty || recordPlace == filterPlace) &&
          zoneMatches;

      print(
        '[AttendanceDetails] Filter: year=${widget.year}, place="$filterPlace", zone="$filterZone", zoneNormalized="$filterZoneNormalized"',
      );
      print(
        '[AttendanceDetails] Record: date=$date, month=${date?.month}, place="$recordPlace", zone="$recordZone", zoneNormalized="$recordZoneNormalized", matches=$matches',
      );
      print(
        '[AttendanceDetails] Match breakdown: placeMatches=${filterPlace.isEmpty || recordPlace == filterPlace}, zoneMatches=$zoneMatches',
      );
      print(
        '[DEBUG] Record raw: date=$date, month=${date?.month}, Location_Mr="${record['Location_Mr'] ?? record['Place']}", zone="${record['zone']}", matches=$matches',
      );
      if (matches) {
        final month = date!.month;
        print('[DEBUG] Adding record to month $month');
        monthMap[month]!.add(record);
      }
    }
    for (int m = 1; m <= 12; m++) {
      print('[DEBUG] Month $m count: ${monthMap[m]?.length ?? 0}');
    }
    setState(() {
      isLoading = false;
    });
  }

  static const _monthNames = [
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF5F5F5),
      appBar: AppBar(title: Text('उपस्थिती तपशील - ${widget.year}')),
      body: isLoading
          ? Center(child: CircularProgressIndicator())
          : Column(
              children: [
                if (widget.startDate != null || widget.endDate != null)
                  Container(
                    margin: const EdgeInsets.fromLTRB(12, 12, 12, 4),
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: const Color(0xFFE8F5E9),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(Icons.date_range, color: Colors.green[800]),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              if (widget.startDate != null)
                                Text(
                                  'प्रारंभ तारीख: ${widget.startDate!.year.toString().padLeft(4, '0')}-${widget.startDate!.month.toString().padLeft(2, '0')}-${widget.startDate!.day.toString().padLeft(2, '0')}',
                                  style: TextStyle(
                                    fontWeight: FontWeight.bold,
                                    color: Colors.green[900],
                                  ),
                                ),
                              if (widget.endDate != null)
                                Padding(
                                  padding: const EdgeInsets.only(top: 4.0),
                                  child: Text(
                                    'समाप्ती तारीख: ${widget.endDate!.year.toString().padLeft(4, '0')}-${widget.endDate!.month.toString().padLeft(2, '0')}-${widget.endDate!.day.toString().padLeft(2, '0')}',
                                    style: TextStyle(
                                      fontWeight: FontWeight.bold,
                                      color: Colors.green[900],
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                Expanded(
                  child: ListView(
                    padding: const EdgeInsets.symmetric(
                      vertical: 8,
                      horizontal: 12,
                    ),
                    children: [
                      ...List.generate(12, (i) {
                        final month = i + 1;
                        final records = monthMap[month]!;
                        final hasRecords = records.isNotEmpty;
                        return Card(
                          margin: const EdgeInsets.symmetric(vertical: 6),
                          elevation: hasRecords ? 2 : 0.5,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              vertical: 8.0,
                              horizontal: 12.0,
                            ),
                            child: Row(
                              children: [
                                CircleAvatar(
                                  radius: 20,
                                  backgroundColor: hasRecords
                                      ? const Color(0xFFE8F5E9)
                                      : Colors.grey[200],
                                  child: Icon(
                                    Icons.calendar_month,
                                    color: hasRecords
                                        ? Colors.green[800]
                                        : Colors.grey[500],
                                  ),
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Text(
                                    _monthNames[month - 1],
                                    style: TextStyle(
                                      fontWeight: FontWeight.bold,
                                      fontSize: 16,
                                      color: hasRecords
                                          ? Colors.black87
                                          : Colors.grey[600],
                                    ),
                                  ),
                                ),
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 10,
                                    vertical: 4,
                                  ),
                                  decoration: BoxDecoration(
                                    color: hasRecords
                                        ? const Color(0xFFE8F5E9)
                                        : Colors.grey[200],
                                    borderRadius: BorderRadius.circular(20),
                                  ),
                                  child: Text(
                                    '${records.length}',
                                    style: TextStyle(
                                      fontWeight: FontWeight.bold,
                                      fontSize: 14,
                                      color: hasRecords
                                          ? Colors.green[800]
                                          : Colors.grey[600],
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 12),
                                ElevatedButton(
                                  style: hasRecords
                                      ? null
                                      : ElevatedButton.styleFrom(
                                          backgroundColor: Colors.grey[300],
                                          foregroundColor: Colors.grey[700],
                                          elevation: 0,
                                        ),
                                  child: Text('तपशील'),
                                  onPressed: () async {
                                    await FirebaseConfig.logEvent(
                                      eventType: 'attendance_month_details_clicked',
                                      description: 'Attendance month details clicked',
                                      details: {
                                        'year': widget.year,
                                        'month': month,
                                        'place': widget.place,
                                        'zone': widget.zone,
                                      },
                                    );
                                    Navigator.push(
                                      context,
                                      MaterialPageRoute(
                                        builder: (context) => AttendeeDetails(
                                          year: widget.year,
                                          month: month,
                                          place: widget.place,
                                          zone: widget.zone,
                                          firestore: widget.firestore,
                                          startDate:
                                              (widget.startDate != null &&
                                                  (widget.startDate !=
                                                      DateTime(
                                                        widget.year,
                                                        1,
                                                        1,
                                                      )))
                                              ? widget.startDate
                                              : null,
                                          endDate:
                                              (widget.endDate != null &&
                                                  (widget.endDate !=
                                                      DateTime(
                                                        widget.year,
                                                        12,
                                                        31,
                                                        23,
                                                        59,
                                                        59,
                                                      )))
                                              ? widget.endDate
                                              : null,
                                        ),
                                      ),
                                    );
                                  },
                                ),
                              ],
                            ),
                          ),
                        );
                      }),
                    ],
                  ),
                ),
              ],
            ),
    );
  }
}
