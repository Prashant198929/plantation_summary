import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:excel/excel.dart';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'firebase_config.dart';
import 'attendance_support.dart';

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
    return place
        .toString()
        .trim()
        .toLowerCase()
        .replaceAll(RegExp(r'\s+'), ' ');
  }

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
    final monthKey = AttendanceSupport.monthYearKey(start);
    final snapshot = await widget.firestore
        .collection('Attendance')
        .doc(monthKey)
        .collection('records')
        .where('date', isGreaterThanOrEqualTo: Timestamp.fromDate(start))
        .where('date', isLessThanOrEqualTo: Timestamp.fromDate(end))
        .orderBy('date', descending: false)
        .get();

    String filterPlace = _normalizePlace(widget.place);
    String filterZone = (widget.zone ?? '').trim().toLowerCase();
    String filterZoneNormalized = _normalizeZone(widget.zone);

    records = snapshot.docs
        .map((doc) => doc.data() as Map<String, dynamic>)
        .where((record) {
          String recordPlace = _normalizePlace((record['Location_Mr'] ?? record['Place'])?.toString());
          String recordZone =
              (record['zone'] ?? '').toString().trim().toLowerCase();
          String recordZoneNormalized =
              _normalizeZone(record['zone']?.toString());

          bool zoneMatches = filterZone.isEmpty
              ? true
              : (filterZoneNormalized.isNotEmpty &&
                      recordZoneNormalized.isNotEmpty)
                  ? recordZoneNormalized == filterZoneNormalized
                  : recordZone == filterZone;

          return (filterPlace.isEmpty || recordPlace == filterPlace) &&
              zoneMatches;
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
        title: Text('उपस्थित तपशील - ${widget.year}-${widget.month.toString().padLeft(2, '0')}'),
      ),
      backgroundColor: const Color(0xFFF5F5F5),
      body: Column(
        children: [
          Expanded(
            child: isLoading
                ? Center(child: CircularProgressIndicator())
                : records.isEmpty
                    ? Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.event_busy, size: 48, color: Colors.grey[400]),
                            const SizedBox(height: 12),
                            Text(
                              'या महिन्यासाठी कोणतीही नोंद आढळली नाही.',
                              style: TextStyle(color: Colors.grey[600]),
                            ),
                          ],
                        ),
                      )
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
          SnackBar(content: Text('निर्यात करण्यासाठी कोणतीही नोंद नाही.')),
        );
        return;
      }
      String excelMarathiDay(DateTime dt) {
        const days = ['सोमवार', 'मंगळवार', 'बुधवार', 'गुरुवार', 'शुक्रवार', 'शनिवार', 'रविवार'];
        return days[dt.weekday - 1];
      }
      String excelEnglishDay(DateTime dt) {
        const days = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];
        return days[dt.weekday - 1];
      }
      String excelEnglishMonth(DateTime dt) {
        const months = ['January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October', 'November', 'December'];
        return months[dt.month - 1];
      }
      DateTime? firstDt;
      final firstDateVal = records.isNotEmpty ? records.first['date'] : null;
      if (firstDateVal is Timestamp) firstDt = firstDateVal.toDate();
      else if (firstDateVal is DateTime) firstDt = firstDateVal;
      firstDt ??= DateTime.now();
      final headerPlace = (widget.place?.isNotEmpty == true)
          ? widget.place!
          : (records.isNotEmpty ? (records.first['Location_Mr']?.toString() ?? records.first['Place']?.toString() ?? '') : '');
      // Lookup baithak/hajeri_kramank from main users collection for old records
      final needsLookupIds = records
          .where((r) => (r['baithak'] ?? '').toString().trim().isEmpty || (r['hajeri_kramank'] ?? '').toString().trim().isEmpty)
          .map((r) => r['userId']?.toString().trim() ?? '')
          .where((id) => id.isNotEmpty)
          .toSet()
          .toList();
      final userLookup = <String, Map<String, dynamic>>{};
      if (needsLookupIds.isNotEmpty) {
        for (int i = 0; i < needsLookupIds.length; i += 30) {
          final chunk = needsLookupIds.sublist(i, (i + 30).clamp(0, needsLookupIds.length));
          final snap = await FirebaseFirestore.instance.collection('users').where(FieldPath.documentId, whereIn: chunk).get();
          for (final doc in snap.docs) {
            userLookup[doc.id] = doc.data();
          }
        }
      }
      String getBaithak(Map<String, dynamic> r) {
        final v = r['baithak']?.toString().trim() ?? '';
        if (v.isNotEmpty) return v;
        final uid = r['userId']?.toString().trim() ?? '';
        return userLookup[uid]?['baithakPlace']?.toString() ?? '';
      }
      String getHajeriKramank(Map<String, dynamic> r) {
        final v = r['hajeri_kramank']?.toString().trim() ?? '';
        if (v.isNotEmpty) return v;
        final uid = r['userId']?.toString().trim() ?? '';
        return userLookup[uid]?['baithakNo']?.toString() ?? '';
      }
      sheet.appendRow([TextCellValue('श्री सेवेचे ठिकाण: $headerPlace')]);
      sheet.appendRow([TextCellValue('दि. ${excelEnglishDay(firstDt)}, ${excelEnglishMonth(firstDt)} ${firstDt.day}, ${firstDt.year}')]);
      sheet.appendRow([TextCellValue('')]);
      sheet.appendRow([
        TextCellValue('क्रमांक'),
        TextCellValue('नाव'),
        TextCellValue('मराठी नाव'),
        TextCellValue('बैठक'),
        TextCellValue('वार'),
        TextCellValue('हजेरी क्रमांक'),
        TextCellValue('काम'),
      ]);
      int serial = 1;
      for (final record in records) {
        DateTime? recDt;
        final dv = record['date'];
        if (dv is Timestamp) recDt = dv.toDate();
        else if (dv is DateTime) recDt = dv;
        sheet.appendRow([
          TextCellValue('$serial'),
          TextCellValue(record['name']?.toString() ?? ''),
          TextCellValue(record['name_mr']?.toString() ?? ''),
          TextCellValue(getBaithak(record)),
          TextCellValue(recDt != null ? excelMarathiDay(recDt) : ''),
          TextCellValue(getHajeriKramank(record)),
          TextCellValue(record['Topic']?.toString() ?? ''),
        ]);
        serial++;
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

    return Container(
      color: const Color(0xFFF5F5F5),
      child: Column(
        children: [
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
              itemCount: pageRecords.length,
              itemBuilder: (context, idx) {
                final record = pageRecords[idx];
                final isPresent = record['status'] == 'Present';
                DateTime? recDate;
                final dv = record['date'];
                if (dv is Timestamp) recDate = dv.toDate();
                else if (dv is DateTime) recDate = dv;
                final formattedDate = recDate != null
                    ? '${recDate.year.toString().padLeft(4, '0')}-${recDate.month.toString().padLeft(2, '0')}-${recDate.day.toString().padLeft(2, '0')}'
                    : '';
                final hajeriKramank = (record['hajeri_kramank'] ?? '').toString();
                final topic = (record['Topic'] ?? 'निर्दिष्ट नाही').toString();

                return Card(
                  margin: const EdgeInsets.symmetric(vertical: 6),
                  elevation: 2,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(12.0),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        CircleAvatar(
                          radius: 20,
                          backgroundColor: isPresent
                              ? const Color(0xFFE8F5E9)
                              : const Color(0xFFFFEBEE),
                          child: Icon(
                            isPresent ? Icons.check_circle : Icons.cancel,
                            color: isPresent ? Colors.green : Colors.red,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                record['name'] ?? '',
                                style: const TextStyle(
                                  fontWeight: FontWeight.bold,
                                  fontSize: 16,
                                ),
                              ),
                              const SizedBox(height: 6),
                              _DetailRow(icon: Icons.calendar_today, text: formattedDate),
                              const SizedBox(height: 3),
                              _DetailRow(icon: Icons.badge, text: 'हजेरी क्रमांक: $hajeriKramank'),
                              const SizedBox(height: 3),
                              _DetailRow(icon: Icons.topic, text: topic),
                            ],
                          ),
                        ),
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 4,
                          ),
                          decoration: BoxDecoration(
                            color: isPresent
                                ? const Color(0xFFE8F5E9)
                                : const Color(0xFFFFEBEE),
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: Text(
                            isPresent ? 'उपस्थित' : (record['status'] ?? ''),
                            style: TextStyle(
                              color: isPresent ? Colors.green[800] : Colors.red[800],
                              fontWeight: FontWeight.bold,
                              fontSize: 12,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text('पृष्ठ ${page + 1} / $totalPages'),
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
            child: SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
                icon: Icon(Icons.download),
                label: Text('यादी डाउनलोड करा'),
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
          ),
        ],
      ),
    );
  }
}

class _DetailRow extends StatelessWidget {
  final IconData icon;
  final String text;
  const _DetailRow({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 14, color: Colors.grey[600]),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            text,
            style: TextStyle(fontSize: 13, color: Colors.grey[700]),
          ),
        ),
      ],
    );
  }
}
