import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:image_picker/image_picker.dart';
import 'dart:io';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:path_provider/path_provider.dart';
import 'firebase_config.dart';
import 'upload_queue_service.dart';

String _safeUploadUserId(String plantName, String plantNumber, String zoneName) {
  final raw = '${plantName}_${plantNumber}_${zoneName}';
  final safe = raw.replaceAll(RegExp(r'[^\w\d]'), '_');
  return safe.isEmpty ? 'unknown' : safe;
}

class EditPlantationPage extends StatefulWidget {
  final String docId;
  final Map<String, dynamic> data;

  const EditPlantationPage({Key? key, required this.docId, required this.data})
    : super(key: key);

  @override
  State<EditPlantationPage> createState() => _EditPlantationPageState();
}

class _EditPlantationPageState extends State<EditPlantationPage> {
  late TextEditingController _nameController;
  late TextEditingController _descriptionController;
  late TextEditingController _errorController;
  late TextEditingController _girthController;
  late TextEditingController _heightController;
  late TextEditingController _stumpController;
  late TextEditingController _longitudeController;
  late TextEditingController _latitudeController;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.data['plantName'] ?? '');
    Future.microtask(() async {
      await FirebaseConfig.logEvent(
        eventType: 'edit_plantation_opened',
        description: 'Edit plantation page opened',
        details: {'docId': widget.docId},
      );
    });
    _descriptionController = TextEditingController(
      text: widget.data['plantNumber'] ?? '',
    );
    _errorController = TextEditingController(
      text: widget.data['healthStatus'] ?? '',
    );
    _girthController = TextEditingController(text: widget.data['girth'] ?? '');
    _heightController = TextEditingController(text: widget.data['height'] ?? '');
    _stumpController = TextEditingController(text: widget.data['stump'] ?? '');
    _longitudeController = TextEditingController(
      text: widget.data['longitude'] ?? '',
    );
    _latitudeController = TextEditingController(
      text: widget.data['latitude'] ?? '',
    );
  }

  Future<void> _updateRecord() async {
    await FirebaseConfig.logEvent(
      eventType: 'edit_plantation_update_clicked',
      description: 'Edit plantation update clicked',
      details: {'docId': widget.docId},
    );
    await FirebaseFirestore.instance
        .collection('plantation_records')
        .doc(widget.docId)
        .update({
          'plantName': _nameController.text,
          'plantNumber': _descriptionController.text,
          'healthStatus': _errorController.text,
          'girth': _girthController.text,
          'height': _heightController.text,
          'stump': _stumpController.text,
          'longitude': _longitudeController.text,
          'latitude': _latitudeController.text,
          'timestamp': DateTime.now().toIso8601String(),
          'Planted_On':
              widget.data['Planted_On'] ?? DateTime.now().toIso8601String(),
        });
    await FirebaseConfig.logEvent(
      eventType: 'plantation_updated',
      description: 'Plantation record updated',
      isImportant: true,
      details: {
        'docId': widget.docId,
        'plantName': _nameController.text,
        'plantNumber': _descriptionController.text,
        'healthStatus': _errorController.text,
      },
    );
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Record updated successfully')),
    );
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Edit Plantation Record')),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextField(
                  controller: _nameController,
                  decoration: InputDecoration(
                    labelText: 'Plant Name',
                    fillColor: Colors.white,
                    filled: true,
                  ),
                ),
                const SizedBox(height: 20),
                TextField(
                  controller: _descriptionController,
                  decoration: InputDecoration(
                    labelText: 'Plant Number',
                    fillColor: Colors.white,
                    filled: true,
                  ),
                ),
                const SizedBox(height: 20),
                TextField(
                  controller: _girthController,
                  decoration: InputDecoration(
                    labelText: 'Girth',
                    fillColor: Colors.white,
                    filled: true,
                  ),
                ),
                const SizedBox(height: 20),
                TextField(
                  controller: _heightController,
                  decoration: InputDecoration(
                    labelText: 'Height',
                    fillColor: Colors.white,
                    filled: true,
                  ),
                ),
                const SizedBox(height: 20),
                TextField(
                  controller: _stumpController,
                  decoration: InputDecoration(
                    labelText: 'Stump',
                    fillColor: Colors.white,
                    filled: true,
                  ),
                ),
                const SizedBox(height: 20),
                TextField(
                  controller: _longitudeController,
                  decoration: InputDecoration(
                    labelText: 'Longitude',
                    fillColor: Colors.white,
                    filled: true,
                  ),
                ),
                const SizedBox(height: 20),
                TextField(
                  controller: _latitudeController,
                  decoration: InputDecoration(
                    labelText: 'Latitude',
                    fillColor: Colors.white,
                    filled: true,
                  ),
                ),
                const SizedBox(height: 20),
                TextField(
                  controller: _errorController,
                  decoration: InputDecoration(
                    labelText: 'Health Status',
                    fillColor: Colors.white,
                    filled: true,
                  ),
                ),
                const SizedBox(height: 32),
                Container(
                  color: Colors.yellow.withOpacity(0.2),
                  child: _ImagePickerAndUploadSection(
                    docId: widget.docId,
                    nameController: _nameController,
                  ),
                ),
                const SizedBox(height: 32),
                ElevatedButton(
                  onPressed: _updateRecord,
                  child: const Text('Update'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ImagePickerAndUploadSection extends StatefulWidget {
  final String docId;
  final TextEditingController nameController;
  const _ImagePickerAndUploadSection({
    required this.docId,
    required this.nameController,
    Key? key,
  }) : super(key: key);

  @override
  State<_ImagePickerAndUploadSection> createState() =>
      _ImagePickerAndUploadSectionState();
}

class _ImagePickerAndUploadSectionState
    extends State<_ImagePickerAndUploadSection> {
  XFile? _pickedImage;
  bool _uploading = false;
  String? _uploadedUrl;

  Future<void> _pickImage(ImageSource source) async {
    final ImagePicker picker = ImagePicker();
    final XFile? image = await picker.pickImage(source: source);
    if (image != null) {
      try {
        final appDocDir = await getApplicationDocumentsDirectory();
        final stableDir = Directory('${appDocDir.path}/temp_picks');
        if (!await stableDir.exists()) await stableDir.create(recursive: true);
        final ext = image.name.contains('.') ? image.name.split('.').last : 'jpg';
        final stablePath = '${stableDir.path}/pending_image.$ext';
        final bytes = await image.readAsBytes();
        await File(stablePath).writeAsBytes(bytes);
        setState(() { _pickedImage = XFile(stablePath); });
      } catch (_) {
        setState(() { _pickedImage = image; });
      }
    }
  }

  Future<void> _uploadImageToStorage() async {
    if (_pickedImage == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('कृपया आधी फोटो निवडा')),
      );
      return;
    }
    setState(() => _uploading = true);

    final docId = widget.docId;
    final ext = _pickedImage!.name.contains('.') ? _pickedImage!.name.split('.').last : 'jpg';

    // Save a stable local copy first (same pattern as zone_management_page)
    String localImagePath = _pickedImage!.path;
    try {
      final localDir = await getApplicationDocumentsDirectory();
      final safeDocId = docId.replaceAll(RegExp(r'[^\w\d]'), '_');
      final localFilePath = '${localDir.path}/$safeDocId.$ext';
      await File(_pickedImage!.path).copy(localFilePath);
      localImagePath = localFilePath;
    } catch (_) {}

    await FirebaseConfig.logEvent(
      eventType: 'edit_plantation_upload_initiated',
      description: 'Edit plantation image upload initiated',
      details: {'docId': docId},
    );

    try {
      // One fixed path per plant — overwrites on re-upload, no duplicates
      final ref = FirebaseStorage.instance.ref('images/$docId.$ext');
      await ref.putFile(File(localImagePath));
      final imageUrl = await ref.getDownloadURL();

      setState(() => _uploadedUrl = imageUrl);

      await FirebaseFirestore.instance
          .collection('plantation_records')
          .doc(docId)
          .update({'imageUrl': imageUrl, 'localImagePath': localImagePath});

      await FirebaseConfig.logEvent(
        eventType: 'edit_plantation_upload_success',
        description: 'Edit plantation image uploaded to Firebase Storage',
        details: {'docId': docId, 'imageUrl': imageUrl},
      );

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('फोटो यशस्वीरित्या अपलोड झाला')),
        );
      }
    } catch (e) {
      // Firebase Storage failed — queue for retry when connection returns
      final uploadItem = UploadItem(
        id: DateTime.now().millisecondsSinceEpoch.toString(),
        imagePath: localImagePath,
        userId: _safeUploadUserId(widget.nameController.text, docId, ''),
        docId: docId,
        createdAt: DateTime.now(),
      );
      await UploadQueueService.addToQueue(uploadItem);

      await FirebaseFirestore.instance
          .collection('plantation_records')
          .doc(docId)
          .update({'localImagePath': localImagePath});

      await FirebaseConfig.logEvent(
        eventType: 'edit_plantation_upload_error',
        description: 'Edit plantation upload failed — queued for retry',
        details: {'docId': docId, 'queueId': uploadItem.id, 'error': e.toString()},
        isError: true,
      );

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('फोटो रांगेत जोडला — कनेक्शन आल्यावर अपलोड होईल')),
        );
      }
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    print('Building ImagePickerAndUploadSection');
    return Column(
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            IconButton(
              tooltip: 'Gallery',
              icon: const Icon(Icons.photo_library, color: Colors.blue),
              onPressed: () async {
                await FirebaseConfig.logEvent(
                  eventType: 'edit_plantation_pick_image',
                  description: 'Edit plantation pick image (gallery)',
                  details: {'docId': widget.docId},
                );
                _pickImage(ImageSource.gallery);
              },
            ),
            IconButton(
              tooltip: 'Camera',
              icon: const Icon(Icons.camera_alt, color: Colors.orange),
              onPressed: () async {
                await FirebaseConfig.logEvent(
                  eventType: 'edit_plantation_pick_image',
                  description: 'Edit plantation pick image (camera)',
                  details: {'docId': widget.docId},
                );
                _pickImage(ImageSource.camera);
              },
            ),
            _pickedImage != null
                ? SizedBox(
                    width: 80,
                    height: 80,
                    child: Image.file(
                      File(_pickedImage!.path),
                      fit: BoxFit.cover,
                    ),
                  )
                : const Text('फोटो निवडला नाही'),
          ],
        ),
        const SizedBox(height: 8),
        ElevatedButton(
          onPressed: _uploading
              ? null
              : () async {
                  await FirebaseConfig.logEvent(
                    eventType: 'edit_plantation_upload_clicked',
                    description: 'Edit plantation upload clicked',
                    details: {'docId': widget.docId},
                  );
                  _uploadImageToStorage();
                },
          child: _uploading
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('फोटो अपलोड करा'),
        ),
        if (_uploadedUrl != null)
          Padding(
            padding: const EdgeInsets.only(top: 8.0),
            child: Row(
              children: const [
                Icon(Icons.check_circle, color: Colors.green, size: 16),
                SizedBox(width: 4),
                Text('फोटो Firebase Storage मध्ये जतन झाला', style: TextStyle(color: Colors.green)),
              ],
            ),
          ),
      ],
    );
  }
}
