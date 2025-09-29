import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:image_picker/image_picker.dart';
import 'dart:io';
import 'package:http/http.dart' as http;

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

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.data['name'] ?? '');
    _descriptionController = TextEditingController(
      text: widget.data['description'] ?? '',
    );
    _errorController = TextEditingController(text: widget.data['error'] ?? '');
  }

  Future<void> _updateRecord() async {
    await FirebaseFirestore.instance
        .collection('plantation_records')
        .doc(widget.docId)
        .update({
          'name': _nameController.text,
          'description': _descriptionController.text,
          'error': _errorController.text,
          'timestamp': DateTime.now().toIso8601String(),
        });
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Record updated successfully')),
    );
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Edit Plantation Record')),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: SingleChildScrollView(
          child: Column(
            children: [
              TextField(
                controller: _nameController,
                decoration: const InputDecoration(labelText: 'Name'),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _descriptionController,
                decoration: const InputDecoration(labelText: 'Description'),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _errorController,
                decoration: const InputDecoration(labelText: 'Error'),
              ),
              const SizedBox(height: 24),
              Container(
                color: Colors.yellow.withOpacity(0.2),
                child: _ImagePickerAndUploadSection(
                  docId: widget.docId,
                  nameController: _nameController,
                ),
              ),
              const SizedBox(height: 24),
              ElevatedButton(
                onPressed: _updateRecord,
                child: const Text('Update'),
              ),
            ],
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

  Future<void> _pickImage() async {
    final ImagePicker picker = ImagePicker();
    final XFile? image = await picker.pickImage(source: ImageSource.gallery);
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
    try {
      var request = http.MultipartRequest(
        'POST',
        Uri.parse('http://80.225.203.181:8081/api/images/upload'),
      );
      request.files.add(
        await http.MultipartFile.fromPath('file', _pickedImage!.path),
      );
      final userId = widget.nameController.text.isEmpty
          ? 'unknown'
          : widget.nameController.text;
      request.fields['userId'] = userId;
      var response = await request.send();
      if (response.statusCode == 200) {
        final filename = _pickedImage!.name;
        final imageUrl =
            'http://80.225.203.181:8081/api/images/view?userId=$userId&filename=$filename';
        setState(() {
          _uploadedUrl = imageUrl;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Image uploaded! URL: $imageUrl')),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Upload failed: ${response.statusCode}')),
        );
      }
    } catch (e) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Error uploading image: $e')));
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
            ElevatedButton(
              onPressed: _pickImage,
              child: const Text('Pick Image'),
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
          onPressed: _uploading ? null : _uploadImageToServer,
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
