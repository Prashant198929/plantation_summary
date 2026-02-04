import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'attendee_details.dart';
import 'firebase_config.dart';

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
    final snapshot = await widget.firestore
        .collection('Attendance')
        .where('date', isGreaterThanOrEqualTo: Timestamp.fromDate(start))
        .where('date', isLessThanOrEqualTo: Timestamp.fromDate(end))
        .orderBy('date', descending: false)
        .get();

    String filterPlace = (widget.place ?? '').trim().toLowerCase();
    String filterZone = (widget.zone ?? '').trim().toLowerCase();

    for (final doc in snapshot.docs) {
      final record = doc.data();
      DateTime? date;
      if (record['date'] is Timestamp) {
        date = (record['date'] as Timestamp).toDate();
      } else if (record['date'] is DateTime) {
        date = record['date'] as DateTime;
      }
      String recordPlace = (record['Place'] ?? '')
          .toString()
          .trim()
          .toLowerCase();
      String recordZone = (record['zone'] ?? '')
          .toString()
          .trim()
          .toLowerCase();

      bool matches =
          date != null &&
          date.year == widget.year &&
          (filterPlace.isEmpty || recordPlace == filterPlace) &&
          (filterZone.isEmpty || recordZone == filterZone);

      print(
        '[AttendanceDetails] Record: date=$date, month=${date?.month}, place="$recordPlace", zone="$recordZone", matches=$matches',
      );

      print(
        '[DEBUG] Record raw: date=$date, month=${date?.month}, Place="${record['Place']}", zone="${record['zone']}", matches=$matches',
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('Attendance Details - ${widget.year}')),
      body: isLoading
          ? Center(child: CircularProgressIndicator())
          : Column(
              children: [
                if (widget.startDate != null || widget.endDate != null)
                  Padding(
                    padding: const EdgeInsets.all(8.0),
                    child: Row(
                      children: [
                        if (widget.startDate != null)
                          Text(
                            'Start Date: ${widget.startDate!.year.toString().padLeft(4, '0')}-${widget.startDate!.month.toString().padLeft(2, '0')}-${widget.startDate!.day.toString().padLeft(2, '0')}',
                            style: TextStyle(fontWeight: FontWeight.bold),
                          ),
                        if (widget.endDate != null)
                          Padding(
                            padding: const EdgeInsets.only(left: 16.0),
                            child: Text(
                              'End Date: ${widget.endDate!.year.toString().padLeft(4, '0')}-${widget.endDate!.month.toString().padLeft(2, '0')}-${widget.endDate!.day.toString().padLeft(2, '0')}',
                              style: TextStyle(fontWeight: FontWeight.bold),
                            ),
                          ),
                      ],
                    ),
                  ),
                Expanded(
                  child: ListView(
                    children: [
                      ...List.generate(12, (i) {
                        final month = i + 1;
                        final records = monthMap[month]!;
                        return Padding(
                          padding: const EdgeInsets.symmetric(
                            vertical: 8.0,
                            horizontal: 16.0,
                          ),
                          child: Row(
                            children: [
                              Expanded(
                                flex: 3,
                                child: Text(
                                  [
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
                                  ][month - 1],
                                  style: TextStyle(fontWeight: FontWeight.bold),
                                ),
                              ),
                              Expanded(
                                flex: 2,
                                child: Center(
                                  child: Text(
                                    '${records.length}',
                                    style: TextStyle(
                                      fontWeight: FontWeight.bold,
                                      fontSize: 16,
                                    ),
                                  ),
                                ),
                              ),
                              Expanded(
                                flex: 3,
                                child: Align(
                                  alignment: Alignment.centerRight,
                                  child: ElevatedButton(
                                    child: Text('Details'),
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
                                ),
                              ),
                            ],
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
