import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';

// Asks whether a generated Excel export should go through the OS share sheet
// or be saved directly to a location the user picks. Returns null if the
// user dismisses the dialog without choosing either.
Future<bool?> askShareOrDownload(BuildContext context) {
  return showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('अहवाल कसा हवा आहे?'),
      actions: [
        TextButton.icon(
          icon: const Icon(Icons.share),
          label: const Text('शेअर करा'),
          onPressed: () => Navigator.pop(context, false),
        ),
        TextButton.icon(
          icon: const Icon(Icons.download),
          label: const Text('डाउनलोड करा'),
          onPressed: () => Navigator.pop(context, true),
        ),
      ],
    ),
  );
}

// Lets the user pick a save location (Downloads, Drive, etc.) via the native
// Save-As dialog, instead of only offering the OS share sheet.
Future<void> downloadExcelFile({
  required BuildContext context,
  required Uint8List bytes,
  required String fileName,
}) async {
  try {
    final savedPath = await FilePicker.platform.saveFile(
      dialogTitle: 'फाईल कुठे साठवायची ते निवडा',
      fileName: fileName,
      bytes: bytes,
    );
    if (savedPath == null || !context.mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('फाईल डाउनलोड झाली: $fileName')));
    // Open it immediately so the user can see it without hunting through a
    // file manager. Some SAF-picked save locations on Android aren't
    // directly openable by other apps, so fall back to a temp-dir copy
    // (same approach the share flow already uses) if the saved path fails.
    final opened = await OpenFilex.open(savedPath);
    if (opened.type != ResultType.done) {
      final tempDir = await getTemporaryDirectory();
      final tempFile = File('${tempDir.path}/$fileName');
      await tempFile.writeAsBytes(bytes);
      await OpenFilex.open(tempFile.path);
    }
  } catch (e) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('डाउनलोड अयशस्वी: $e')));
  }
}
