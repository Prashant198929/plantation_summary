import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:image_picker/image_picker.dart';
import 'dart:io';
import 'package:http/http.dart' as http;
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
      setState(() {
        _pickedImage = image;
      });
    }
  }

  Future<void> _uploadImageToServer() async {
    if (_pickedImage == null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('No image selected')));
      return;
    }
    setState(() {
      _uploading = true;
    });
    final userId = _safeUploadUserId(
      widget.nameController.text,
      widget.data['plantNumber']?.toString() ?? '',
      widget.data['zoneName']?.toString() ?? '',
    );
    try {
      var request = http.MultipartRequest(
        'POST',
        Uri.parse('http://80.225.203.181:8081/api/images/upload'),
      );
      request.files.add(
        await http.MultipartFile.fromPath('file', _pickedImage!.path),
      );
      request.fields['userId'] = userId;
      await FirebaseConfig.logEvent(
        eventType: 'edit_plantation_upload_initiated',
        description: 'Edit plantation image upload initiated',
        details: {'docId': widget.docId, 'userId': userId},
      );
      var response = await request.send();
      if (response.statusCode == 200) {
        final filename = _pickedImage!.name;
        final imageUrl =
            'http://80.225.203.181:8081/api/images/view?userId=$userId&filename=$filename';
        setState(() {
          _uploadedUrl = imageUrl;
        });
        await FirebaseConfig.logEvent(
          eventType: 'edit_plantation_upload_success',
          description: 'Edit plantation image uploaded successfully',
          details: {
            'docId': widget.docId,
            'imageUrl': imageUrl,
            'statusCode': response.statusCode,
          },
        );
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Image uploaded! URL: $imageUrl')),
        );
      } else {
        await FirebaseConfig.logEvent(
          eventType: 'edit_plantation_upload_failed',
          description: 'Edit plantation image upload failed',
          details: {
            'docId': widget.docId,
            'statusCode': response.statusCode,
            'error': 'HTTP ${response.statusCode}',
          },
        );
        // Save image path locally for retry/queue
        await FirebaseFirestore.instance.collection('plantation_records').doc(widget.docId).update({
          'localImagePath': _pickedImage!.path,
          'error': 'Image upload failed. Please try again later.',
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Image upload failed. Please try again later.')),
        );
      }
    } catch (e) {
      // Add to upload queue for retry
      if (_pickedImage != null) {
        final uploadItem = UploadItem(
          id: DateTime.now().millisecondsSinceEpoch.toString(),
          imagePath: _pickedImage!.path,
          userId: userId,
          docId: widget.docId,
          createdAt: DateTime.now(),
        );
        await UploadQueueService.addToQueue(uploadItem);
        
        await FirebaseConfig.logEvent(
          eventType: 'edit_plantation_upload_error',
          description: 'Edit plantation upload error - queued for retry',
          details: {
            'docId': widget.docId,
            'queueId': uploadItem.id,
            'error': e.toString(),
          },
        );
        
        await FirebaseFirestore.instance.collection('plantation_records').doc(widget.docId).update({
          'localImagePath': _pickedImage!.path,
          'error': 'Image queued for upload when connection is available.',
        });
        
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Image queued for upload when connection is available.')),
        );
      }
    } finally {
      setState(() {
        _uploading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    print('Building ImagePickerAndUploadSection');
    return Column(
      children: [
        Row(
          children: [
            ElevatedButton.icon(
              onPressed: () async {
                await FirebaseConfig.logEvent(
                  eventType: 'edit_plantation_pick_image',
                  description: 'Edit plantation pick image (gallery)',
                  details: {'docId': widget.docId},
                );
                _pickImage(ImageSource.gallery);
              },
              icon: const Icon(Icons.photo_library),
              label: const Text('Gallery'),
            ),
            const SizedBox(width: 8),
            ElevatedButton.icon(
              onPressed: () async {
                await FirebaseConfig.logEvent(
                  eventType: 'edit_plantation_pick_image',
                  description: 'Edit plantation pick image (camera)',
                  details: {'docId': widget.docId},
                );
                _pickImage(ImageSource.camera);
              },
              icon: const Icon(Icons.camera_alt),
              label: const Text('Camera'),
            ),
            const SizedBox(width: 16),
            _pickedImage != null
                ? SizedBox(
                    width: 80,
                    height: 80,
                    child: Image.file(
                      File(_pickedImage!.path),
                      fit: BoxFit.cover,
                    ),
                  )
                : const Text('No image selected'),
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
                  _uploadImageToServer();
                },
          child: _uploading
              ? const Text('Uploading...')
              : const Text('Upload Image to Server'),
        ),
        if (_uploadedUrl != null)
          Padding(
            padding: const EdgeInsets.only(top: 8.0),
            child: Text('Uploaded URL: $_uploadedUrl'),
          ),
      ],
    );
  }
}
