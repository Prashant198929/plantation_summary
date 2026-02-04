import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:excel/excel.dart';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'firebase_config.dart';

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
      appBar: AppBar(title: const Text('Reports')),
      body: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.start,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            const SizedBox(height: 40),
            ElevatedButton(
              onPressed: () async {
                await FirebaseConfig.logEvent(
                  eventType: 'zone_wise_report_clicked',
                  description: 'Zone wise report clicked',
                );
                final zonesQuery = await showDialog<List<String>>(
                  context: context,
                  builder: (context) => _ZoneSelectionDialog(),
                );
                if (zonesQuery != null && zonesQuery.isNotEmpty) {
                  // TODO: Generate Excel for selected zones and download locally
                }
              },
              child: const Text('Zone Wise Report'),
            ),
            const SizedBox(height: 24),
            ElevatedButton(
              onPressed: () async {
                await FirebaseConfig.logEvent(
                  eventType: 'all_plants_report_clicked',
                  description: 'All plants report clicked',
                );
                final plants = await _fetchPlantsWithHistory();
                await _generateAndSaveExcel(
                  plants,
                  context,
                  fileName: 'all_plants_report.xlsx',
                );
                await FirebaseConfig.logEvent(
                  eventType: 'report_generated',
                  description: 'All Plants Report generated',
                  details: {
                    'timestamp': DateTime.now().toIso8601String(),
                    'type': 'all_plants',
                  },
                );
              },
              child: const Text('All Plants Report'),
            ),
          ],
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

  @override
  void initState() {
    super.initState();
    _fetchZones();
  }

  Future<void> _fetchZones() async {
    final query = await FirebaseFirestore.instance.collection('zones').get();
    setState(() {
      _zones = query.docs.map((doc) => doc['name'] as String).toList();
    });
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Select Zones'),
      content: _zones.isEmpty
          ? const CircularProgressIndicator()
          : SizedBox(
              width: 300,
              height: 400,
              child: ListView(
                children: _zones
                    .map((zone) => CheckboxListTile(
                          title: Text(zone),
                          value: _selectedZones.contains(zone),
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
                        ))
                    .toList(),
              ),
            ),
      actions: [
        TextButton(
          onPressed: () async {
            await FirebaseConfig.logEvent(
              eventType: 'zone_report_cancelled',
              description: 'Zone report cancelled',
            );
            Navigator.pop(context, <String>[]);
          },
          child: const Text('Cancel'),
        ),
        ElevatedButton(
          onPressed: () async {
            await FirebaseConfig.logEvent(
              eventType: 'zone_report_generate_clicked',
              description: 'Zone report generate clicked',
              details: {'zones': _selectedZones.toList()},
            );
            if (_selectedZones.isEmpty) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Please select at least one zone.')),
              );
              return;
            }
            final plants = await _fetchPlantsWithHistory(
              zones: _selectedZones.toList(),
            );
            // Generate Excel
            await _generateAndSaveExcel(plants, context);
            await FirebaseConfig.logEvent(
              eventType: 'report_generated',
              description: 'Zone Wise Report generated',
              details: {
                'timestamp': DateTime.now().toIso8601String(),
                'type': 'zone_wise',
                'zones': _selectedZones.toList(),
              },
            );
            Navigator.pop(context, _selectedZones.toList());
          },
          child: const Text('Generate Report'),
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

Future<void> _generateAndSaveExcel(List<Map<String, dynamic>> plants, BuildContext context, {String fileName = 'zone_report.xlsx'}) async {
  try {
    // Import these at the top of the file:
    // import 'package:excel/excel.dart';
    // import 'dart:io';
    // import 'package:path_provider/path_provider.dart';
    final excel = Excel.createExcel();
    final sheet = excel['Plants'];
    sheet.appendRow([
      TextCellValue('Name'),
      TextCellValue('Zone'),
      TextCellValue('Plant Number'),
      TextCellValue('Issue'),
      TextCellValue('Height'),
      TextCellValue('Biomass'),
      TextCellValue('Specific Leaf Area'),
      TextCellValue('Longevity'),
      TextCellValue('Leaf Litter Quality'),
      TextCellValue('Change Flag'),
    ]);
    for (final plant in plants) {
      sheet.appendRow([
        TextCellValue(plant['name']?.toString() ?? ''),
        TextCellValue(plant['zoneName']?.toString() ?? ''),
        TextCellValue(plant['description']?.toString() ?? ''),
        TextCellValue(plant['error']?.toString() ?? ''),
        TextCellValue(plant['height']?.toString() ?? ''),
        TextCellValue(plant['biomass']?.toString() ?? ''),
        TextCellValue(plant['specificLeafArea']?.toString() ?? ''),
        TextCellValue(plant['longevity']?.toString() ?? ''),
        TextCellValue(plant['leafLitterQuality']?.toString() ?? ''),
        TextCellValue(plant['_reportFlag']?.toString() ?? ''),
      ]);
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
    final file = File('$path/$fileName');
    await file.writeAsBytes(excel.encode()!);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Excel file saved: $path/$fileName')),
    );
  } catch (e) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Failed to save Excel: $e')),
    );
  }
}
