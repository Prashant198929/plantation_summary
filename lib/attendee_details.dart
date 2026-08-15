import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:excel/excel.dart';
import 'dart:io';
import 'dart:typed_data';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'excel_download_helper.dart';
import 'firebase_config.dart';
import 'attendance_support.dart';
import 'place_name_service.dart';
import 'transliteration_service.dart';
import 'main.dart';
import 'mobile_encryption_service.dart';

class AttendeeDetails extends StatefulWidget {
  final int year;
  final int month;
  final List<String>? places;
  final List<String>? zones;
  final FirebaseFirestore firestore;
  final DateTime? startDate;
  final DateTime? endDate;

  const AttendeeDetails({
    Key? key,
    required this.year,
    required this.month,
    required this.places,
    required this.zones,
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
  bool _isSuperAdmin = false;
  String? _monthKey;
  final TextEditingController _nameSearchController = TextEditingController();
  String _nameFilter = '';

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

  List<Map<String, dynamic>> get _visibleRecords {
    final query = _nameFilter.trim().toLowerCase();
    if (query.isEmpty) return records;
    return records.where((r) {
      final name = (r['name'] ?? '').toString().toLowerCase();
      final nameMr = (r['name_mr'] ?? '').toString().toLowerCase();
      return name.contains(query) || nameMr.contains(query);
    }).toList();
  }

  @override
  void dispose() {
    _nameSearchController.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    fetchAttendees();
    _checkSuperAdminRole();
    Future.microtask(() async {
      await FirebaseConfig.logEvent(
        eventType: 'attendee_details_opened',
        description: 'Attendee details opened',
        details: {
          'year': widget.year,
          'month': widget.month,
          'places': widget.places,
          'zones': widget.zones,
        },
      );
    });
  }

  Future<void> _checkSuperAdminRole() async {
    final encryptedMobile = loggedInMobile == null
        ? null
        : MobileEncryptionService.encrypt(loggedInMobile!) ?? loggedInMobile;
    final userQuery = await FirebaseFirestore.instance
        .collection('users')
        .where('mobile', isEqualTo: encryptedMobile)
        .limit(1)
        .get();
    bool isSuperAdmin = false;
    if (userQuery.docs.isNotEmpty) {
      final role = userQuery.docs.first.data()['role']?.toString().toLowerCase();
      isSuperAdmin = role == 'super_admin' || role == 'superadmin' || role == 'admin';
    }
    if (!mounted) return;
    setState(() {
      _isSuperAdmin = isSuperAdmin;
    });
  }

  Future<void> _deleteRecord(Map<String, dynamic> record) async {
    final docId = record['_docId']?.toString();
    final monthKey = _monthKey;
    if (docId == null || monthKey == null) return;
    final displayName = (record['name_mr'] ?? record['name'] ?? '').toString();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('हजेरी नोंद हटवायची?'),
        content: Text('$displayName ची ही हजेरी नोंद कायमची हटवली जाईल. पुढे जायचे आहे का?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('रद्द करा'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('हटवा', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await widget.firestore
          .collection('Attendance')
          .doc(monthKey)
          .collection('records')
          .doc(docId)
          .delete();
      await FirebaseConfig.logEvent(
        eventType: 'attendance_record_deleted',
        description: 'Attendance record deleted',
        userId: loggedInMobile,
        details: {
          'monthKey': monthKey,
          'docId': docId,
          'name': record['name'],
        },
      );
      if (!mounted) return;
      setState(() {
        records.removeWhere((r) => r['_docId'] == docId);
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('हजेरी नोंद हटवली')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('हटवताना त्रुटी: $e')),
      );
    }
  }

  Future<void> fetchAttendees() async {
    final rawStart = widget.startDate;
    final start = rawStart != null
        ? DateTime(rawStart.year, rawStart.month, rawStart.day)
        : DateTime(widget.year, widget.month, 1);
    final rawEnd = widget.endDate;
    final end = rawEnd != null
        ? DateTime(rawEnd.year, rawEnd.month, rawEnd.day, 23, 59, 59, 999)
        : DateTime(widget.year, widget.month + 1, 0, 23, 59, 59);
    final monthKey = AttendanceSupport.monthYearKey(start);
    _monthKey = monthKey;
    final snapshot = await widget.firestore
        .collection('Attendance')
        .doc(monthKey)
        .collection('records')
        .where('date', isGreaterThanOrEqualTo: Timestamp.fromDate(start))
        .where('date', isLessThanOrEqualTo: Timestamp.fromDate(end))
        .orderBy('date', descending: false)
        .get();

    final filterPlaces = (widget.places ?? [])
        .map(_normalizePlace)
        .where((p) => p.isNotEmpty)
        .toSet();
    final filterZonesNormalized = (widget.zones ?? [])
        .map((z) => _normalizeZone(z))
        .where((z) => z.isNotEmpty)
        .toSet();
    final filterZonesRaw = (widget.zones ?? [])
        .map((z) => z.trim().toLowerCase())
        .where((z) => z.isNotEmpty)
        .toSet();

    records = snapshot.docs
        .map((doc) => {...doc.data(), '_docId': doc.id})
        .where((record) {
          String recordPlace = _normalizePlace((record['Location_Mr'] ?? record['Place'])?.toString());
          String recordZone =
              (record['zone'] ?? '').toString().trim().toLowerCase();
          String recordZoneNormalized =
              _normalizeZone(record['zone']?.toString());

          bool zoneMatches = filterZonesRaw.isEmpty
              ? true
              : (filterZonesNormalized.isNotEmpty &&
                      recordZoneNormalized.isNotEmpty)
                  ? filterZonesNormalized.contains(recordZoneNormalized)
                  : filterZonesRaw.contains(recordZone);

          return (filterPlaces.isEmpty || filterPlaces.contains(recordPlace)) &&
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
          if (!isLoading && records.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
              child: TextField(
                controller: _nameSearchController,
                decoration: InputDecoration(
                  hintText: 'नाव शोधा (इंग्रजी किंवा मराठी)',
                  prefixIcon: const Icon(Icons.search),
                  suffixIcon: _nameFilter.isEmpty
                      ? null
                      : IconButton(
                          icon: const Icon(Icons.clear),
                          onPressed: () {
                            _nameSearchController.clear();
                            setState(() => _nameFilter = '');
                          },
                        ),
                  filled: true,
                  fillColor: Colors.white,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: BorderSide.none,
                  ),
                  isDense: true,
                  contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                ),
                onChanged: (value) => setState(() => _nameFilter = value),
              ),
            ),
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
                    : _visibleRecords.isEmpty
                        ? Center(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(Icons.search_off, size: 48, color: Colors.grey[400]),
                                const SizedBox(height: 12),
                                Text(
                                  '"$_nameFilter" साठी कोणतीही नोंद सापडली नाही.',
                                  style: TextStyle(color: Colors.grey[600]),
                                ),
                              ],
                            ),
                          )
                        : _PaginatedAttendeeList(
                            key: ValueKey(_nameFilter),
                            records: _visibleRecords,
                            onShare: _shareAttendeeDetails,
                            onDownload: (ctx) => _shareAttendeeDetails(ctx, download: true),
                            isSuperAdmin: _isSuperAdmin,
                            onDelete: _deleteRecord,
                          ),
          ),
        ],
      ),
    );
  }

  Future<void> _shareAttendeeDetails(BuildContext context, {bool download = false}) async {
    try {
      if (records.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('निर्यात करण्यासाठी कोणतीही नोंद नाही.')),
        );
        return;
      }
      // Same start/end resolution as fetchAttendees(), so the sheet tab name
      // matches what was actually queried.
      final rangeStart = widget.startDate ?? DateTime(widget.year, widget.month, 1);
      final rangeEnd = widget.endDate ?? DateTime(widget.year, widget.month + 1, 0);
      final isSingleDay = widget.startDate != null &&
          widget.endDate != null &&
          widget.startDate!.year == widget.endDate!.year &&
          widget.startDate!.month == widget.endDate!.month &&
          widget.startDate!.day == widget.endDate!.day;
      // Sheet tab name mirrors the selected date/date-range so the exported
      // file's tab tells you what it covers without opening it. Excel tab
      // names can't contain \/?*[]: and cap at 31 chars, so this uses a
      // compact yyyyMMdd form rather than the Marathi header text.
      String fmtSheetDate(DateTime d) =>
          '${d.year}${d.month.toString().padLeft(2, '0')}${d.day.toString().padLeft(2, '0')}';
      final String sheetName;
      if (widget.startDate == null && widget.endDate == null) {
        sheetName = 'Attendees_${widget.year}${widget.month.toString().padLeft(2, '0')}';
      } else if (isSingleDay) {
        sheetName = 'Attendees_${fmtSheetDate(rangeStart)}';
      } else {
        sheetName = 'Attendees_${fmtSheetDate(rangeStart)}_${fmtSheetDate(rangeEnd)}';
      }
      final excel = Excel.createExcel();
      // createExcel() always seeds a blank default sheet ('Sheet1') — rename
      // it in place instead of creating a second sheet, so the exported file
      // has exactly one tab and it opens to the data.
      final defaultSheetName = excel.getDefaultSheet() ?? excel.sheets.keys.first;
      excel.rename(defaultSheetName, sheetName);
      final sheet = excel[sheetName];
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
      final headerPlace = (widget.places?.isNotEmpty == true)
          ? widget.places!.join(', ')
          : (records.isNotEmpty ? (records.first['Location_Mr']?.toString() ?? records.first['Place']?.toString() ?? '') : '');
      // Lookup baithak/hajeri_kramank from main users collection for old records.
      // Attendance docs only ever store the English 'baithak' value, never
      // 'baithak_mr', so the Marathi name always has to come from the users
      // collection (or a phonetic fallback) rather than the record itself.
      await PlaceNameService.fetchAll();
      final needsLookupIds = records
          .where((r) =>
              (r['baithak'] ?? '').toString().trim().isEmpty ||
              (r['hajeri_kramank'] ?? '').toString().trim().isEmpty ||
              (r['baithak_mr'] ?? '').toString().trim().isEmpty ||
              (r['name_mr'] ?? '').toString().trim().isEmpty ||
              (r['baithak_day_mr'] ?? '').toString().trim().isEmpty)
          .map((r) => r['userId']?.toString().trim() ?? '')
          .where((id) => id.isNotEmpty)
          .toSet()
          .toList();
      final userLookup = <String, Map<String, dynamic>>{};
      if (needsLookupIds.isNotEmpty) {
        for (int i = 0; i < needsLookupIds.length; i += 30) {
          final chunk = needsLookupIds.sublist(i, (i + 30).clamp(0, needsLookupIds.length));
          final snap = await FirebaseFirestore.instance.collection('users').where('uid', whereIn: chunk).get();
          for (final doc in snap.docs) {
            final d = doc.data();
            userLookup[d['uid']?.toString() ?? doc.id] = d;
          }
        }
      }
      String getName(Map<String, dynamic> r) {
        final mr = r['name_mr']?.toString().trim() ?? '';
        if (mr.isNotEmpty) return mr;
        final uid = r['userId']?.toString().trim() ?? '';
        final lookupMr = userLookup[uid]?['name_mr']?.toString().trim() ?? '';
        if (lookupMr.isNotEmpty) return lookupMr;
        final en = r['name']?.toString().trim() ?? '';
        final lookupEn = userLookup[uid]?['name']?.toString().trim() ?? '';
        final fallbackEn = en.isNotEmpty ? en : lookupEn;
        return fallbackEn.isNotEmpty ? TransliterationService.toDevanagari(fallbackEn) : '';
      }
      String getBaithak(Map<String, dynamic> r) {
        final mr = r['baithak_mr']?.toString().trim() ?? '';
        if (mr.isNotEmpty) return mr;
        final uid = r['userId']?.toString().trim() ?? '';
        final lookupMr = userLookup[uid]?['baithak_mr']?.toString().trim() ?? '';
        if (lookupMr.isNotEmpty) return lookupMr;
        final v = r['baithak']?.toString().trim() ?? '';
        final english = v.isNotEmpty ? v : (userLookup[uid]?['baithakPlace']?.toString() ?? '');
        return PlaceNameService.suggest(english);
      }
      String getHajeriKramank(Map<String, dynamic> r) {
        final v = r['hajeri_kramank']?.toString().trim() ?? '';
        if (v.isNotEmpty) return v;
        final uid = r['userId']?.toString().trim() ?? '';
        return userLookup[uid]?['hajeri_kramank']?.toString() ??
            userLookup[uid]?['baithakNo']?.toString() ??
            '';
      }
      // The वार column shows the person's fixed weekly baithak day (from
      // registration), not the weekday the attendance date happens to fall
      // on — those are unrelated, since plantation work can happen any day.
      String getVaar(Map<String, dynamic> r) {
        final mr = r['baithak_day_mr']?.toString().trim() ?? '';
        if (mr.isNotEmpty) return mr;
        final uid = r['userId']?.toString().trim() ?? '';
        final lookupMr = userLookup[uid]?['baithak_day_mr']?.toString().trim() ?? '';
        if (lookupMr.isNotEmpty) return lookupMr;
        final en = r['baithak_day']?.toString().trim() ?? '';
        final lookupEn = userLookup[uid]?['baithak_day']?.toString().trim() ?? '';
        final fallbackEn = en.isNotEmpty ? en : lookupEn;
        return AttendanceSupport.toMarathiDayLabel(fallbackEn);
      }
      final topicSet = <String>{};
      for (final record in records) {
        final t = record['Topic']?.toString().trim() ?? '';
        if (t.isNotEmpty) topicSet.addAll(t.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty));
      }
      const _cols = ['A', 'B', 'C', 'D', 'E', 'F'];

      // Row 1: || श्री || — centered across all columns
      sheet.merge(CellIndex.indexByString('A1'), CellIndex.indexByString('F1'));
      final c1 = sheet.cell(CellIndex.indexByString('A1'));
      c1.value = TextCellValue('|| श्री ||');
      c1.cellStyle = CellStyle(horizontalAlign: HorizontalAlign.Center);

      // Row 2: || श्री राम समर्थ || — centered
      sheet.merge(CellIndex.indexByString('A2'), CellIndex.indexByString('F2'));
      final c2 = sheet.cell(CellIndex.indexByString('A2'));
      c2.value = TextCellValue('|| श्री राम समर्थ ||');
      c2.cellStyle = CellStyle(horizontalAlign: HorizontalAlign.Center);

      // Row 3: empty (spacer)

      // Row 4: Place — centered across all columns
      sheet.merge(CellIndex.indexByString('A4'), CellIndex.indexByString('F4'));
      final placeCell = sheet.cell(CellIndex.indexByString('A4'));
      placeCell.value = TextCellValue('श्री सेवेचे ठिकाण: $headerPlace');
      placeCell.cellStyle = CellStyle(horizontalAlign: HorizontalAlign.Center);

      // Row 5: Date — right-aligned across all columns
      sheet.merge(CellIndex.indexByString('A5'), CellIndex.indexByString('F5'));
      final dateCell = sheet.cell(CellIndex.indexByString('A5'));
      dateCell.value = TextCellValue('दि. ${excelEnglishDay(firstDt)}, ${excelEnglishMonth(firstDt)} ${firstDt.day}, ${firstDt.year}');
      dateCell.cellStyle = CellStyle(horizontalAlign: HorizontalAlign.Right);

      // Row 6: empty (spacer)

      // Row 7: कामाचे स्वरूप — unique topics across the filtered records
      sheet.merge(CellIndex.indexByString('A7'), CellIndex.indexByString('F7'));
      final topicCell = sheet.cell(CellIndex.indexByString('A7'));
      topicCell.value = TextCellValue('कामाचे स्वरूप: ${topicSet.join(', ')}');

      // Row 8: empty (spacer)

      // Row 9: Column headers — written directly (not via appendRow, which
      // targets maxRows and would collide with the row 8 spacer left blank above)
      const _hdrs = ['क्रमांक', 'नाव', 'बैठक', 'वार', 'हजेरी क्रमांक', 'झोन'];
      for (int i = 0; i < _hdrs.length; i++) {
        final hc = sheet.cell(CellIndex.indexByString('${_cols[i]}9'));
        hc.value = TextCellValue(_hdrs[i]);
        hc.cellStyle = CellStyle(bold: true);
      }

      int serial = 1;
      for (final record in records) {
        final recordZoneMr = record['zone_mr']?.toString().trim() ?? '';
        sheet.appendRow([
          TextCellValue('$serial'),
          TextCellValue(getName(record)),
          TextCellValue(getBaithak(record)),
          TextCellValue(getVaar(record)),
          TextCellValue(getHajeriKramank(record)),
          TextCellValue(recordZoneMr.isNotEmpty ? recordZoneMr : AttendanceSupport.toMarathiZoneLabel(record['zone']?.toString() ?? '')),
        ]);
        serial++;
      }

      final now = DateTime.now();
      String formatted = '${now.year.toString().padLeft(4, '0')}${now.month.toString().padLeft(2, '0')}${now.day.toString().padLeft(2, '0')}${now.hour.toString().padLeft(2, '0')}${now.minute.toString().padLeft(2, '0')}${now.second.toString().padLeft(2, '0')}';
      final fileName = 'attendee_details_$formatted.xlsx';
      final bytes = excel.encode()!;

      await FirebaseConfig.logEvent(
        eventType: download ? 'attendee_details_downloaded' : 'attendee_details_shared',
        description: download
            ? 'Attendee Details downloaded as Excel'
            : 'Attendee Details shared as Excel',
        details: {
          'timestamp': now.toIso8601String(),
          'type': 'attendance',
        },
      );

      if (download) {
        await downloadExcelFile(
          context: context,
          bytes: Uint8List.fromList(bytes),
          fileName: fileName,
        );
        return;
      }

      final tempDir = await getTemporaryDirectory();
      final file = File('${tempDir.path}/$fileName');
      await file.writeAsBytes(bytes);
      await Share.shareXFiles(
        [XFile(file.path, mimeType: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet')],
        subject: fileName,
      );
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to share Excel: $e')),
      );
    }
  }
}

class _PaginatedAttendeeList extends StatefulWidget {
  final List<Map<String, dynamic>> records;
  final Future<void> Function(BuildContext) onShare;
  final Future<void> Function(BuildContext) onDownload;
  final bool isSuperAdmin;
  final Future<void> Function(Map<String, dynamic>) onDelete;
  const _PaginatedAttendeeList({
    Key? key,
    required this.records,
    required this.onShare,
    required this.onDownload,
    required this.isSuperAdmin,
    required this.onDelete,
  }) : super(key: key);

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
                final zoneMr = (record['zone_mr'] ?? record['zone'] ?? '').toString();
                final markedByName =
                    (record['markedBy_name_mr'] ?? record['markedBy_name'] ?? '')
                        .toString();

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
                              _DetailRow(icon: Icons.map, text: 'झोन: ${zoneMr.isNotEmpty ? zoneMr : '—'}'),
                              const SizedBox(height: 3),
                              _DetailRow(icon: Icons.badge, text: 'हजेरी क्रमांक: $hajeriKramank'),
                              const SizedBox(height: 3),
                              _DetailRow(icon: Icons.topic, text: topic),
                              const SizedBox(height: 3),
                              _DetailRow(
                                icon: Icons.person_pin_circle,
                                text: 'नोंदणी करणारे: ${markedByName.isNotEmpty ? markedByName : '—'}',
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 8),
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
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
                            if (widget.isSuperAdmin)
                              IconButton(
                                icon: const Icon(Icons.delete_outline, color: Colors.red),
                                tooltip: 'हजेरी नोंद हटवा',
                                onPressed: () => widget.onDelete(record),
                              ),
                          ],
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
            child: Row(
              children: [
                Expanded(
                  child: ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                    icon: Icon(Icons.share),
                    label: Text('शेअर करा'),
                    onPressed: widget.records.isEmpty
                        ? null
                        : () async {
                            await FirebaseConfig.logEvent(
                              eventType: 'attendee_share_clicked',
                              description: 'Attendee share clicked',
                              details: {'count': widget.records.length},
                            );
                            await widget.onShare(context);
                          },
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                    icon: Icon(Icons.download),
                    label: Text('डाउनलोड करा'),
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
