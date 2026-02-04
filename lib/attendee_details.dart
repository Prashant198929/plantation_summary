import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:excel/excel.dart';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'firebase_config.dart';

class AttendeeDetails extends StatefulWidget {
  final int year;
  final int month;
  final String? place;
  final String? zone;
  final FirebaseFirestore firestore;
  final DateTime? startDate;
  final DateTime? endDate;

  const AttendeeDetails({
    Key? key,
    required this.year,
    required this.month,
    required this.place,
    required this.zone,
    required this.firestore,
    this.startDate,
    this.endDate,
  }) : super(key: key);

  @override
  State<AttendeeDetails> createState() => _AttendeeDetailsState();
}

class _AttendeeDetailsState extends State<AttendeeDetails> {
  bool isLoading = true;
  List<Map<String, dynamic>> records = [];

  @override
  void initState() {
    super.initState();
    fetchAttendees();
    Future.microtask(() async {
      await FirebaseConfig.logEvent(
        eventType: 'attendee_details_opened',
        description: 'Attendee details opened',
        details: {
          'year': widget.year,
          'month': widget.month,
          'place': widget.place,
          'zone': widget.zone,
        },
      );
    });
  }

  Future<void> fetchAttendees() async {
    final start = widget.startDate ?? DateTime(widget.year, widget.month, 1);
    final end = widget.endDate ??
        DateTime(widget.year, widget.month + 1, 0, 23, 59, 59);
    final snapshot = await widget.firestore
        .collection('Attendance')
        .where('date', isGreaterThanOrEqualTo: Timestamp.fromDate(start))
        .where('date', isLessThanOrEqualTo: Timestamp.fromDate(end))
        .orderBy('date', descending: false)
        .get();

    String filterPlace = (widget.place ?? '').trim().toLowerCase();
    String filterZone = (widget.zone ?? '').trim().toLowerCase();

    records = snapshot.docs
        .map((doc) => doc.data() as Map<String, dynamic>)
        .where((record) {
          String recordPlace =
              (record['Place'] ?? '').toString().trim().toLowerCase();
          String recordZone =
              (record['zone'] ?? '').toString().trim().toLowerCase();
          return (filterPlace.isEmpty || recordPlace == filterPlace) &&
              (filterZone.isEmpty || recordZone == filterZone);
        })
        .toList();

    setState(() {
      isLoading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Attendee Details - ${widget.year}-${widget.month.toString().padLeft(2, '0')}'),
      ),
      body: Column(
        children: [
          Expanded(
            child: isLoading
                ? Center(child: CircularProgressIndicator())
                : records.isEmpty
                    ? Center(child: Text('No records found for this month.'))
                    : _PaginatedAttendeeList(records: records, onDownload: _downloadAttendeeDetails),
          ),
        ],
      ),
    );
  }

  Future<void> _downloadAttendeeDetails(BuildContext context) async {
    try {
      final excel = Excel.createExcel();
      final sheet = excel['Attendees'];
      if (records.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('No attendee records to export.')),
        );
        return;
      }
      // Add dateString column for each record
      final exportRecords = records.map((record) {
        final data = Map<String, dynamic>.from(record);
        if (!data.containsKey('dateString')) {
          final ts = data['date'];
          if (ts is Timestamp) {
            data['dateString'] = ts.toDate().toIso8601String();
          } else if (ts is DateTime) {
            data['dateString'] = ts.toIso8601String();
          } else {
            data['dateString'] = ts?.toString() ?? '';
          }
        }
        return data;
      }).toList();
      // Ensure 'dateString' is included in header
      final headerKeys = exportRecords.first.keys.toList();
      if (!headerKeys.contains('dateString')) {
        headerKeys.add('dateString');
      }
      sheet.appendRow(headerKeys.map((k) => TextCellValue(k.toString())).toList());
      for (final record in exportRecords) {
        final row = headerKeys.map((k) => TextCellValue(record[k]?.toString() ?? '')).toList();
        sheet.appendRow(row);
      }

      Directory? downloadsDir;
      try {
        downloadsDir = Directory('/storage/emulated/0/Download');
        if (!await downloadsDir.exists()) {
          downloadsDir = await getExternalStorageDirectory();
        }
      } catch (_) {
        downloadsDir = await getExternalStorageDirectory();
      }
      final path = downloadsDir?.path ?? (await getApplicationDocumentsDirectory()).path;
      final now = DateTime.now();
      String formatted = '${now.year.toString().padLeft(4, '0')}${now.month.toString().padLeft(2, '0')}${now.day.toString().padLeft(2, '0')}${now.hour.toString().padLeft(2, '0')}${now.minute.toString().padLeft(2, '0')}${now.second.toString().padLeft(2, '0')}';
      final fileName = 'attendee_details_$formatted.xlsx';
      final file = File('$path/$fileName');
      await file.writeAsBytes(excel.encode()!);

      await FirebaseConfig.logEvent(
        eventType: 'attendance_report_downloaded',
        description: 'Attendee Details downloaded as Excel',
        details: {
          'timestamp': now.toIso8601String(),
          'type': 'attendance',
        },
      );

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Excel file saved: $path/$fileName')),
      );
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to save Excel: $e')),
      );
    }
  }
}

class _PaginatedAttendeeList extends StatefulWidget {
  final List<Map<String, dynamic>> records;
  final Future<void> Function(BuildContext) onDownload;
  const _PaginatedAttendeeList({required this.records, required this.onDownload});

  @override
  State<_PaginatedAttendeeList> createState() => _PaginatedAttendeeListState();
}

class _PaginatedAttendeeListState extends State<_PaginatedAttendeeList> {
  static const int pageSize = 10;
  int page = 0;

  @override
  Widget build(BuildContext context) {
    final totalPages = (widget.records.length / pageSize).ceil();
    final start = page * pageSize;
    final end = ((page + 1) * pageSize).clamp(0, widget.records.length);
    final pageRecords = widget.records.sublist(start, end);

    return Column(
      children: [
        Expanded(
          child: ListView.builder(
            itemCount: pageRecords.length,
            itemBuilder: (context, idx) {
              final record = pageRecords[idx];
              return ListTile(
                leading: Icon(
                  record['status'] == 'Present'
                      ? Icons.check_circle
                      : Icons.cancel,
                  color: record['status'] == 'Present'
                      ? Colors.green
                      : Colors.red,
                ),
                title: Text(record['name'] ?? ''),
                subtitle: Text(
                  'Time: ${record['time'] ?? ''}\nTopic: ${record['Topic'] ?? 'Not specified'}',
                ),
                trailing: Text(
                  record['status'] ?? '',
                  style: TextStyle(
                    color: record['status'] == 'Present'
                        ? Colors.green
                        : Colors.red,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              );
            },
          ),
        ),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text('Page ${page + 1} of $totalPages'),
            IconButton(
              icon: Icon(Icons.chevron_left),
              onPressed: page > 0
                  ? () async {
                      await FirebaseConfig.logEvent(
                        eventType: 'attendee_page_prev',
                        description: 'Attendee page previous',
                        details: {'page': page},
                      );
                      setState(() => page--);
                    }
                  : null,
            ),
            IconButton(
              icon: Icon(Icons.chevron_right),
              onPressed: page < totalPages - 1
                  ? () async {
                      await FirebaseConfig.logEvent(
                        eventType: 'attendee_page_next',
                        description: 'Attendee page next',
                        details: {'page': page},
                      );
                      setState(() => page++);
                    }
                  : null,
            ),
          ],
        ),
        Padding(
          padding: const EdgeInsets.all(16.0),
          child: ElevatedButton.icon(
            icon: Icon(Icons.download),
            label: Text('Download List'),
            onPressed: widget.records.isEmpty
                ? null
                : () async {
                    await FirebaseConfig.logEvent(
                      eventType: 'attendee_download_clicked',
                      description: 'Attendee download clicked',
                      details: {'count': widget.records.length},
                    );
                    await widget.onDownload(context);
                  },
          ),
        ),
      ],
    );
  }
}
