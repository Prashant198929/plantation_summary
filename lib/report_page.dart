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

class ReportPage extends StatelessWidget {
  const ReportPage({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    Future.microtask(() async {
      await FirebaseConfig.logEvent(
        eventType: 'report_page_opened',
        description: 'Report page opened',
      );
    });
    return Scaffold(
      appBar: AppBar(title: const Text('अहवाल')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const SizedBox(height: 8),
          _ReportCard(
            icon: Icons.map_outlined,
            title: 'झोन नुसार अहवाल',
            description: 'एक किंवा अधिक झोन निवडा आणि Excel अहवाल शेअर करा.',
            onTap: () async {
              await FirebaseConfig.logEvent(
                eventType: 'zone_wise_report_clicked',
                description: 'Zone wise report clicked',
              );
              await showDialog<void>(
                context: context,
                builder: (context) => _ZoneSelectionDialog(),
              );
            },
          ),
          const SizedBox(height: 12),
          _ReportCard(
            icon: Icons.forest_outlined,
            title: 'सर्व रोपांचा अहवाल',
            description: 'संपूर्ण लागवड नोंदी व इतिहासासह Excel अहवाल शेअर करा.',
            onTap: () async {
              await FirebaseConfig.logEvent(
                eventType: 'all_plants_report_clicked',
                description: 'All plants report clicked',
              );
              final download = await askShareOrDownload(context);
              if (download == null || !context.mounted) return;
              // Show loading indicator
              showDialog(
                context: context,
                barrierDismissible: false,
                builder: (ctx) => const AlertDialog(
                  content: Row(
                    children: [
                      CircularProgressIndicator(),
                      SizedBox(width: 16),
                      Text('अहवाल तयार होत आहे...'),
                    ],
                  ),
                ),
              );
              try {
                final plants = await _fetchPlantsWithHistory();
                if (context.mounted) Navigator.of(context).pop();
                if (context.mounted) {
                  await _generateAndShareExcel(
                    plants,
                    context,
                    fileName: 'all_plants_report.xlsx',
                    download: download,
                  );
                }
              } catch (_) {
                if (context.mounted) Navigator.of(context).pop();
              }
              await FirebaseConfig.logEvent(
                eventType: 'report_generated',
                description: 'All Plants Report generated',
                details: {
                  'timestamp': DateTime.now().toIso8601String(),
                  'type': 'all_plants',
                },
              );
            },
          ),
        ],
      ),
    );
  }
}

class _ReportCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String description;
  final VoidCallback onTap;

  const _ReportCard({
    required this.icon,
    required this.title,
    required this.description,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Container(
                width: 52,
                height: 52,
                decoration: BoxDecoration(
                  color: const Color(0xFFE8F5E9),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(icon, color: const Color(0xFF2E7D32), size: 28),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 15,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      description,
                      style: TextStyle(color: Colors.grey[600], fontSize: 13),
                    ),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right, color: Color(0xFF2E7D32)),
            ],
          ),
        ),
      ),
    );
  }
}

class _ZoneSelectionDialog extends StatefulWidget {
  @override
  State<_ZoneSelectionDialog> createState() => _ZoneSelectionDialogState();
}

class _ZoneSelectionDialogState extends State<_ZoneSelectionDialog> {
  List<String> _zones = [];
  Set<String> _selectedZones = {};
  String _searchQuery = '';
  bool _generating = false;

  final TextEditingController _searchController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _fetchZones();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _fetchZones() async {
    final query = await FirebaseFirestore.instance.collection('zones').get();
    if (!mounted) return;
    setState(() {
      _zones = query.docs.map((doc) => doc['name'] as String).toList()
        ..sort(AttendanceSupport.compareZoneNames);
    });
  }

  List<String> get _filteredZones {
    if (_searchQuery.isEmpty) return _zones;
    return _zones
        .where((z) => z.toLowerCase().contains(_searchQuery.toLowerCase()))
        .toList();
  }

  bool get _allFilteredSelected =>
      _filteredZones.isNotEmpty &&
      _filteredZones.every(_selectedZones.contains);

  void _toggleAll() {
    setState(() {
      if (_allFilteredSelected) {
        for (final z in _filteredZones) {
          _selectedZones.remove(z);
        }
      } else {
        _selectedZones.addAll(_filteredZones);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final filtered = _filteredZones;

    return AlertDialog(
      titlePadding: const EdgeInsets.fromLTRB(20, 20, 20, 0),
      contentPadding: const EdgeInsets.fromLTRB(0, 12, 0, 0),
      title: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.map_outlined, color: Color(0xFF2E7D32)),
              const SizedBox(width: 8),
              const Text('झोन निवडा', style: TextStyle(fontSize: 17)),
              const Spacer(),
              if (_selectedZones.isNotEmpty)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: const Color(0xFF2E7D32),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    '${_selectedZones.length} निवडले',
                    style: const TextStyle(color: Colors.white, fontSize: 12),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _searchController,
            onChanged: (val) => setState(() => _searchQuery = val.trim()),
            decoration: InputDecoration(
              hintText: 'झोन शोधा...',
              prefixIcon: const Icon(Icons.search, size: 20),
              suffixIcon: _searchQuery.isNotEmpty
                  ? IconButton(
                      icon: const Icon(Icons.clear, size: 18),
                      onPressed: () {
                        _searchController.clear();
                        setState(() => _searchQuery = '');
                      },
                    )
                  : null,
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            ),
          ),
        ],
      ),
      content: _zones.isEmpty
          ? const SizedBox(
              height: 100,
              child: Center(child: CircularProgressIndicator()),
            )
          : SizedBox(
              width: 320,
              height: 340,
              child: Column(
                children: [
                  // Select all row
                  if (filtered.isNotEmpty)
                    InkWell(
                      onTap: _toggleAll,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                        child: Row(
                          children: [
                            Checkbox(
                              value: _allFilteredSelected,
                              activeColor: const Color(0xFF2E7D32),
                              onChanged: (_) => _toggleAll(),
                            ),
                            Text(
                              _allFilteredSelected ? 'सर्व अनिवड करा' : 'सर्व निवडा',
                              style: const TextStyle(
                                fontWeight: FontWeight.w600,
                                color: Color(0xFF2E7D32),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  const Divider(height: 1),
                  Expanded(
                    child: filtered.isEmpty
                        ? Center(
                            child: Text(
                              '"$_searchQuery" साठी झोन आढळला नाही',
                              style: TextStyle(color: Colors.grey[600]),
                            ),
                          )
                        : ListView.builder(
                            itemCount: filtered.length,
                            itemBuilder: (context, index) {
                              final zone = filtered[index];
                              final selected = _selectedZones.contains(zone);
                              return CheckboxListTile(
                                dense: true,
                                title: Text(zone),
                                value: selected,
                                activeColor: const Color(0xFF2E7D32),
                                controlAffinity: ListTileControlAffinity.leading,
                                onChanged: (checked) {
                                  setState(() {
                                    if (checked == true) {
                                      _selectedZones.add(zone);
                                    } else {
                                      _selectedZones.remove(zone);
                                    }
                                  });
                                  Future.microtask(() async {
                                    await FirebaseConfig.logEvent(
                                      eventType: 'zone_filter_toggled',
                                      description: 'Zone filter toggled',
                                      details: {
                                        'zone': zone,
                                        'selected': checked == true,
                                      },
                                    );
                                  });
                                },
                              );
                            },
                          ),
                  ),
                ],
              ),
            ),
      actions: [
        TextButton(
          onPressed: _generating
              ? null
              : () async {
                  await FirebaseConfig.logEvent(
                    eventType: 'zone_report_cancelled',
                    description: 'Zone report cancelled',
                  );
                  Navigator.pop(context);
                },
          child: const Text('रद्द करा'),
        ),
        ElevatedButton(
          onPressed: _generating
              ? null
              : () async {
                  await FirebaseConfig.logEvent(
                    eventType: 'zone_report_generate_clicked',
                    description: 'Zone report generate clicked',
                    details: {'zones': _selectedZones.toList()},
                  );
                  if (_selectedZones.isEmpty) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('कृपया किमान एक झोन निवडा.')),
                    );
                    return;
                  }
                  final download = await askShareOrDownload(context);
                  if (download == null || !context.mounted) return;
                  setState(() => _generating = true);
                  try {
                    final plants = await _fetchPlantsWithHistory(
                      zones: _selectedZones.toList(),
                    );
                    if (context.mounted) {
                      await _generateAndShareExcel(
                        plants,
                        context,
                        zones: _selectedZones.toList(),
                        download: download,
                      );
                    }
                    await FirebaseConfig.logEvent(
                      eventType: 'report_generated',
                      description: 'Zone Wise Report generated',
                      details: {
                        'timestamp': DateTime.now().toIso8601String(),
                        'type': 'zone_wise',
                        'zones': _selectedZones.toList(),
                      },
                    );
                  } finally {
                    if (mounted) setState(() => _generating = false);
                  }
                  if (mounted) Navigator.pop(context);
                },
          child: _generating
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Colors.white,
                  ),
                )
              : const Text('अहवाल तयार करा'),
        ),
      ],
    );
  }
}

Future<List<Map<String, dynamic>>> _fetchPlantsWithHistory({
  List<String>? zones,
}) async {
  final plants = <Map<String, dynamic>>[];
  if (zones == null || zones.isEmpty) {
    final currentQuery =
        await FirebaseFirestore.instance.collection('plantation_records').get();
    plants.addAll(
      currentQuery.docs.map((doc) => doc.data() as Map<String, dynamic>),
    );
    final historicalQuery =
        await FirebaseFirestore.instance.collection('HistoricalData').get();
    plants.addAll(
      historicalQuery.docs.map((doc) {
        final data = Map<String, dynamic>.from(doc.data());
        data['_reportFlag'] = data['editedAt'] != null ? 'R' : '';
        return data;
      }),
    );
    return plants;
  }

  for (final zone in zones) {
    final currentQuery = await FirebaseFirestore.instance
        .collection('plantation_records')
        .where('zoneName', isEqualTo: zone)
        .get();
    plants.addAll(
      currentQuery.docs.map((doc) => doc.data() as Map<String, dynamic>),
    );
    final historicalQuery = await FirebaseFirestore.instance
        .collection('HistoricalData')
        .where('zoneName', isEqualTo: zone)
        .get();
    plants.addAll(
      historicalQuery.docs.map((doc) {
        final data = Map<String, dynamic>.from(doc.data());
        data['_reportFlag'] = data['editedAt'] != null ? 'R' : '';
        return data;
      }),
    );
  }
  return plants;
}

Future<void> _generateAndShareExcel(
  List<Map<String, dynamic>> plants,
  BuildContext context, {
  String fileName = 'zone_report.xlsx',
  List<String>? zones,
  bool download = false,
}) async {
  try {
    final excel = Excel.createExcel();
    final sheet = excel['Plants'];
    const _cols = ['A', 'B', 'C', 'D', 'E', 'F', 'G', 'H', 'I', 'J'];
    final now = DateTime.now();

    // Row 1: || श्री || — centered across all columns
    sheet.merge(CellIndex.indexByString('A1'), CellIndex.indexByString('J1'));
    final c1 = sheet.cell(CellIndex.indexByString('A1'));
    c1.value = TextCellValue('|| श्री ||');
    c1.cellStyle = CellStyle(horizontalAlign: HorizontalAlign.Center);

    // Row 2: || श्री राम समर्थ || — centered
    sheet.merge(CellIndex.indexByString('A2'), CellIndex.indexByString('J2'));
    final c2 = sheet.cell(CellIndex.indexByString('A2'));
    c2.value = TextCellValue('|| श्री राम समर्थ ||');
    c2.cellStyle = CellStyle(horizontalAlign: HorizontalAlign.Center);

    // Row 3: empty (spacer)

    // Row 4: Zone(s) — centered across all columns
    sheet.merge(CellIndex.indexByString('A4'), CellIndex.indexByString('J4'));
    final zoneCell = sheet.cell(CellIndex.indexByString('A4'));
    zoneCell.value = TextCellValue('झोन: ${(zones != null && zones.isNotEmpty) ? zones.join(', ') : 'सर्व'}');
    zoneCell.cellStyle = CellStyle(horizontalAlign: HorizontalAlign.Center);

    // Row 5: Date — right-aligned across all columns
    sheet.merge(CellIndex.indexByString('A5'), CellIndex.indexByString('J5'));
    final dateCell = sheet.cell(CellIndex.indexByString('A5'));
    dateCell.value = TextCellValue('दि. ${now.day}/${now.month}/${now.year}');
    dateCell.cellStyle = CellStyle(horizontalAlign: HorizontalAlign.Right);

    // Row 6: empty (spacer)

    // Row 7: Column headers — written directly (not via appendRow, which
    // targets maxRows and would collide with the row 6 spacer left blank above)
    const _hdrs = [
      'नाव',
      'झोन',
      'वनस्पती क्रमांक',
      'आरोग्य स्थिती',
      'उंची',
      'बायोमास',
      'विशिष्ट पान क्षेत्र',
      'दीर्घायुष्य',
      'पानांच्या कचऱ्याची गुणवत्ता',
      'बदल ध्वज',
    ];
    for (int i = 0; i < _hdrs.length; i++) {
      final hc = sheet.cell(CellIndex.indexByString('${_cols[i]}7'));
      hc.value = TextCellValue(_hdrs[i]);
      hc.cellStyle = CellStyle(bold: true);
    }
    for (final plant in plants) {
      sheet.appendRow([
        TextCellValue(plant['plantName']?.toString() ?? ''),
        TextCellValue(plant['zoneName']?.toString() ?? ''),
        TextCellValue(plant['plantNumber']?.toString() ?? ''),
        TextCellValue(plant['healthStatus']?.toString() ?? ''),
        TextCellValue(plant['height']?.toString() ?? ''),
        TextCellValue(plant['biomass']?.toString() ?? ''),
        TextCellValue(plant['specificLeafArea']?.toString() ?? ''),
        TextCellValue(plant['longevity']?.toString() ?? ''),
        TextCellValue(plant['leafLitterQuality']?.toString() ?? ''),
        TextCellValue(plant['_reportFlag']?.toString() ?? ''),
      ]);
    }
    final bytes = excel.encode()!;

    if (!context.mounted) return;

    if (download) {
      await downloadExcelFile(
        context: context,
        bytes: Uint8List.fromList(bytes),
        fileName: fileName,
      );
      return;
    }

    final tempDir = await getTemporaryDirectory();
    final tempFile = File('${tempDir.path}/$fileName');
    await tempFile.writeAsBytes(bytes);
    await Share.shareXFiles(
      [XFile(tempFile.path, mimeType: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet')],
      subject: fileName,
    );
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Excel शेअर करण्यात अयशस्वी: $e')),
      );
    }
  }
}
