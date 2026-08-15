import 'package:flutter/material.dart';

// One "Vehicle Type + Vehicle No." row, shared by the Add User sheet
// (attendance_page.dart) and the user details edit dialog
// (user_role_management_page.dart) so vehicle editing stays in sync between
// the two places a user's profile can be created/updated.
class VehicleEntry {
  String? type;
  final TextEditingController noCtrl = TextEditingController();

  void dispose() => noCtrl.dispose();

  static List<VehicleEntry> fromStored(dynamic rawVehicles) {
    final entries = <VehicleEntry>[];
    if (rawVehicles is List) {
      for (final v in rawVehicles) {
        if (v is Map) {
          final entry = VehicleEntry()
            ..type = v['type']?.toString()
            ..noCtrl.text = v['no']?.toString() ?? '';
          entries.add(entry);
        }
      }
    }
    return entries;
  }

  static List<Map<String, String>> toStored(List<VehicleEntry> vehicles) {
    return vehicles
        .where((v) => (v.type ?? '').isNotEmpty || v.noCtrl.text.trim().isNotEmpty)
        .map((v) => {'type': v.type ?? '', 'no': v.noCtrl.text.trim()})
        .toList();
  }
}
