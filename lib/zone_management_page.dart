import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:plantation_summary/main.dart';
import 'package:plantation_summary/firebase_config.dart';
import 'package:image_picker/image_picker.dart';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'dart:async';
import 'upload_queue_service.dart';

String _dateKey(DateTime dt) {
  return '${dt.year.toString().padLeft(4, '0')}${dt.month.toString().padLeft(2, '0')}${dt.day.toString().padLeft(2, '0')}';
}

String _safeDocId(String raw) {
  return raw.replaceAll(RegExp(r'[^\w\d]'), '_');
}

String _plantationDocId(String name, String zoneName) {
  final dateKey = _dateKey(DateTime.now());
  return _safeDocId('${dateKey}_${name}_${zoneName}');
}

String _historicalDocId(String name, String zoneName) {
  final dateKey = _dateKey(DateTime.now());
  return _safeDocId('${dateKey}_${name}_${zoneName}');
}

String _uploadUserId(String plantName, String plantNumber, String zoneName) {
  final raw = '${plantName}_${plantNumber}_${zoneName}';
  final safe = _safeDocId(raw);
  return safe.isEmpty ? 'unknown' : safe;
}

class ZoneManagementPage extends StatefulWidget {
  const ZoneManagementPage({Key? key}) : super(key: key);

  @override
  State<ZoneManagementPage> createState() => _ZoneManagementPageState();
}

class _ZoneManagementPageState extends State<ZoneManagementPage> {
  final TextEditingController _zoneController = TextEditingController();

  @override
  void initState() {
    super.initState();
    Future.microtask(() async {
      await FirebaseConfig.logEvent(
        eventType: 'zone_management_opened',
        description: 'Zone management page opened',
        userId: loggedInMobile,
      );
    });
  }

  Future<bool> _isSuperAdmin() async {
    if (loggedInMobile == null) return false;
    final query = await FirebaseFirestore.instance
        .collection('users')
        .where('mobile', isEqualTo: loggedInMobile)
        .limit(1)
        .get();
    if (query.docs.isNotEmpty) {
      final data = query.docs.first.data();
      if (data['role']?.toString().toLowerCase() == 'super_admin' ||
          data['role']?.toString().toLowerCase() == 'superadmin') {
        return true;
      }
    }
    return false;
  }

  void _addZone() async {
    await FirebaseConfig.logEvent(
      eventType: 'add_zone_clicked',
      description: 'Add zone clicked',
      userId: loggedInMobile,
      details: {'zoneName': _zoneController.text.trim()},
    );
    if (!await _isSuperAdmin()) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Only super admin can add zones.')),
      );
      return;
    }
    final zoneName = _zoneController.text.trim();
    if (zoneName.isNotEmpty) {
      final zoneDocId = _safeDocId(zoneName);
      await FirebaseFirestore.instance
          .collection('zones')
          .doc(zoneDocId)
          .set({
            'name': zoneName,
          });
      _zoneController.clear();
    }
  }

  void _openZone(BuildContext context, String zoneId, String zoneName) async {
    await FirebaseConfig.logEvent(
      eventType: 'zone_details_clicked',
      description: 'Zone details clicked',
      userId: loggedInMobile,
      details: {'zoneId': zoneId, 'zoneName': zoneName},
    );
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) =>
            ZoneDetailPage(zoneId: zoneId, zoneName: zoneName),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<QuerySnapshot>(
      future: loggedInMobile == null
          ? null
          : FirebaseFirestore.instance
                .collection('users')
                .where('mobile', isEqualTo: loggedInMobile)
                .limit(1)
                .get(),
      builder: (context, userSnapshot) {
        if (userSnapshot.connectionState == ConnectionState.waiting) {
          return Scaffold(
            appBar: AppBar(title: Text('Plant Management')),
            body: Center(child: CircularProgressIndicator()),
          );
        }
        String? userRole;
        String? userZone;
        if (userSnapshot.hasData &&
            userSnapshot.data != null &&
            userSnapshot.data!.docs.isNotEmpty) {
          final data =
              userSnapshot.data!.docs.first.data() as Map<String, dynamic>;
          userRole = data['role']?.toString().toLowerCase();
          userZone = data['zone'];
        }
        bool isSuperAdmin =
            userRole == 'super_admin' || userRole == 'superadmin';

        if (!isSuperAdmin) {
          return Scaffold(
            appBar: AppBar(title: Text('Plant Management')),
            body: Center(
              child: Text('Only super admin can access Plant Management.'),
            ),
          );
        }

        return Scaffold(
          appBar: AppBar(title: Text('Plant Management')),
          body: Column(
            children: [
              Padding(
                padding: const EdgeInsets.all(12.0),
                child: Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _zoneController,
                        decoration: InputDecoration(
                          labelText: 'Zone Name',
                          border: OutlineInputBorder(),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    ElevatedButton(
                      onPressed: _addZone,
                      child: Text('Add Zone'),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: StreamBuilder<QuerySnapshot>(
                  stream: isSuperAdmin
                      ? FirebaseFirestore.instance
                            .collection('zones')
                            .snapshots()
                      : FirebaseFirestore.instance
                            .collection('zones')
                            .where('name', isEqualTo: userZone)
                            .snapshots(),
                  builder: (context, snapshot) {
                    if (snapshot.connectionState == ConnectionState.waiting) {
                      return Center(child: CircularProgressIndicator());
                    }
                    if (!snapshot.hasData || snapshot.data!.docs.isEmpty) {
                      return Center(child: Text('No zones found.'));
                    }
                    final zones = snapshot.data!.docs;
                    return FutureBuilder<QuerySnapshot>(
                      future: FirebaseFirestore.instance
                          .collection('plantation_records')
                          .get(),
                      builder: (context, plantSnapshot) {
                        return ListView.builder(
                          itemCount: zones.length,
                          itemBuilder: (context, index) {
                            final zone = zones[index];
                            final zoneId = zone.id;
                            final zoneName = zone['name'] ?? 'Unknown';
                            bool highlightZone = false;
                            if (plantSnapshot.hasData) {
                              final plants = plantSnapshot.data!.docs.where((doc) {
                                final data = doc.data();
                                if (data is! Map<String, dynamic>) return false;
                                return data.containsKey('zoneId') &&
                                    data['zoneId'] == zoneId &&
                                    data['healthStatus'] != null &&
                                    data['healthStatus'] != 'NA';
                              });
                              highlightZone = plants.isNotEmpty;
                            }
                            return ListTile(
                              tileColor: highlightZone ? Colors.red[100] : null,
                              title: Text(zoneName),
                              trailing: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  ElevatedButton(
onPressed: () async {
  await FirebaseConfig.logEvent(
    eventType: 'zone_details_opened',
    description: 'Zone details opened',
    userId: loggedInMobile,
    details: {'zoneId': zoneId, 'zoneName': zoneName},
  );
  if (!(isSuperAdmin) &&
      userZone != null &&
      zoneName != userZone) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Please select your zone for details'),
        backgroundColor: Colors.red,
      ),
    );
    return;
  }
  await Navigator.push(
    context,
    MaterialPageRoute(
      builder: (context) => PlantListPage(zoneId: zoneId, zoneName: zoneName),
    ),
  );
  setState(() {});
},
                                    child: Text('Details'),
                                  ),
                                ],
                              ),
                            );
                          },
                        );
                      },
                    );
                  },
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class ZoneDetailPage extends StatefulWidget {
  final String zoneId;
  final String zoneName;
  const ZoneDetailPage({required this.zoneId, required this.zoneName, Key? key})
    : super(key: key);

  @override
  State<ZoneDetailPage> createState() => _ZoneDetailPageState();
}

class _ZoneDetailPageState extends State<ZoneDetailPage> {
  final TextEditingController _nameController = TextEditingController();
  final TextEditingController _descController = TextEditingController();
  final TextEditingController _errorController = TextEditingController();
  final TextEditingController _heightController = TextEditingController();
  final TextEditingController _girthController = TextEditingController();
  final TextEditingController _stumpController = TextEditingController();
  final TextEditingController _longitudeController = TextEditingController();
  final TextEditingController _latitudeController = TextEditingController();
  final TextEditingController _biomassController = TextEditingController();
  final TextEditingController _slaController = TextEditingController();
  final TextEditingController _longevityController = TextEditingController();
  final TextEditingController _leafLitterQualityController =
      TextEditingController();

  bool _isSuperAdmin = false;
  bool _checkedRole = false;

  XFile? _pickedImage;
  final ImagePicker _picker = ImagePicker();

  @override
  void initState() {
    super.initState();
    _checkRole();
    Future.microtask(() async {
      await FirebaseConfig.logEvent(
        eventType: 'zone_detail_opened',
        description: 'Zone detail opened',
        userId: loggedInMobile,
        details: {'zoneId': widget.zoneId, 'zoneName': widget.zoneName},
      );
    });
  }

  Future<void> _checkRole() async {
    if (loggedInMobile == null) {
      setState(() {
        _isSuperAdmin = false;
        _checkedRole = true;
      });
      return;
    }
    final query = await FirebaseFirestore.instance
        .collection('users')
        .where('mobile', isEqualTo: loggedInMobile)
        .limit(1)
        .get();
    bool isSuper = false;
    if (query.docs.isNotEmpty) {
      final data = query.docs.first.data();
      if (data['role']?.toString().toLowerCase() == 'super_admin' ||
          data['role']?.toString().toLowerCase() == 'superadmin') {
        isSuper = true;
      }
    }
    setState(() {
      _isSuperAdmin = isSuper;
      _checkedRole = true;
    });
  }

  Future<void> _pickImage(ImageSource source) async {
    await FirebaseConfig.logEvent(
      eventType: 'pick_image_clicked',
      description: 'Pick image clicked',
      userId: loggedInMobile,
      details: {'zoneId': widget.zoneId, 'zoneName': widget.zoneName, 'source': source.name},
    );
    final XFile? image = await _picker.pickImage(source: source);
    if (image != null) {
      setState(() {
        _pickedImage = image;
      });
    }
  }

  Future<void> _uploadImageToServer() async {
    await FirebaseConfig.logEvent(
      eventType: 'upload_image_clicked',
      description: 'Upload image clicked',
      userId: loggedInMobile,
      details: {'zoneId': widget.zoneId, 'zoneName': widget.zoneName},
    );
    await FirebaseConfig.logEvent(
      eventType: 'upload_image_initiated',
      description: 'Upload image initiated',
      userId: loggedInMobile,
      details: {'zoneId': widget.zoneId, 'zoneName': widget.zoneName},
    );
    if (_pickedImage == null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('No image selected')));
      return;
    }
    try {
      var request = http.MultipartRequest(
        'POST',
        Uri.parse('http://80.225.203.181:8081/api/images/upload'),
      );
      request.files.add(
        await http.MultipartFile.fromPath('file', _pickedImage!.path),
      );
      final uploadUserId = _uploadUserId(
        _nameController.text.trim(),
        _descController.text.trim(),
        widget.zoneName,
      );
      request.fields['userId'] = uploadUserId;
      var response = await request.send();
      if (response.statusCode == 200) {
        final filename = _pickedImage!.name;
        final userId = _uploadUserId(
          _nameController.text.trim(),
          _descController.text.trim(),
          widget.zoneName,
        );
        final imageUrl =
            'http://80.225.203.181:8081/api/images/view?userId=$userId&filename=$filename';
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Image uploaded! URL: $imageUrl')),
        );
      } else {
        // Add to upload queue for retry
        if (_pickedImage != null) {
          final userId = _uploadUserId(
            _nameController.text.trim(),
            _descController.text.trim(),
            widget.zoneName,
          );
          final docId = _plantationDocId(userId, widget.zoneName);
          final uploadItem = UploadItem(
            id: DateTime.now().millisecondsSinceEpoch.toString(),
            imagePath: _pickedImage!.path,
            userId: userId,
            docId: docId,
            createdAt: DateTime.now(),
          );
          await UploadQueueService.addToQueue(uploadItem);
          
          await FirebaseFirestore.instance
              .collection('plantation_records')
              .doc(docId)
              .set({
                'plantName': _nameController.text.trim(),
                'plantNumber': _descController.text.trim(),
                'healthStatus': _errorController.text.trim().isEmpty
                    ? 'NA'
                    : _errorController.text.trim(),
                'uploadStatus': 'queued',
                'height': _heightController.text.trim(),
                'girth': _girthController.text.trim(),
                'stump': _stumpController.text.trim(),
                'longitude': _longitudeController.text.trim(),
                'latitude': _latitudeController.text.trim(),
                'biomass': _biomassController.text.trim(),
                'specificLeafArea': _slaController.text.trim(),
                'longevity': _longevityController.text.trim(),
                'leafLitterQuality': _leafLitterQualityController.text.trim(),
                'zoneId': widget.zoneId,
                'zoneName': widget.zoneName,
                'timestamp': DateTime.now().toIso8601String(),
                'Planted_On': DateTime.now().toIso8601String(),
                'localImagePath': _pickedImage!.path,
              });
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Image queued for upload when connection is available.')),
          );
        }
      }
    } catch (e) {
      // Add to upload queue for retry
      if (_pickedImage != null) {
        final userId = _uploadUserId(
          _nameController.text.trim(),
          _descController.text.trim(),
          widget.zoneName,
        );
        final docId = _plantationDocId(userId, widget.zoneName);
        final uploadItem = UploadItem(
          id: DateTime.now().millisecondsSinceEpoch.toString(),
          imagePath: _pickedImage!.path,
          userId: userId,
          docId: docId,
          createdAt: DateTime.now(),
        );
        await UploadQueueService.addToQueue(uploadItem);
        
        await FirebaseFirestore.instance
            .collection('plantation_records')
            .doc(docId)
            .set({
              'plantName': _nameController.text.trim(),
              'plantNumber': _descController.text.trim(),
              'healthStatus': _errorController.text.trim().isEmpty
                  ? 'NA'
                  : _errorController.text.trim(),
              'uploadStatus': 'queued',
              'height': _heightController.text.trim(),
              'girth': _girthController.text.trim(),
              'stump': _stumpController.text.trim(),
              'longitude': _longitudeController.text.trim(),
              'latitude': _latitudeController.text.trim(),
              'biomass': _biomassController.text.trim(),
              'specificLeafArea': _slaController.text.trim(),
              'longevity': _longevityController.text.trim(),
              'leafLitterQuality': _leafLitterQualityController.text.trim(),
              'zoneId': widget.zoneId,
              'zoneName': widget.zoneName,
              'timestamp': DateTime.now().toIso8601String(),
              'Planted_On': DateTime.now().toIso8601String(),
              'localImagePath': _pickedImage!.path,
            });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Image queued for upload when connection is available.')),
        );
      }
    }
  }

  void _addPlant() async {
    await FirebaseConfig.logEvent(
      eventType: 'add_plant_clicked',
      description: 'Add plant clicked',
      userId: loggedInMobile,
      details: {'zoneId': widget.zoneId, 'zoneName': widget.zoneName},
    );
    if (!_isSuperAdmin) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Only super admin can add plants.')),
      );
      return;
    }
    final name = _nameController.text.trim();
    final desc = _descController.text.trim();
    final error = _errorController.text.trim();
    final height = _heightController.text.trim();
    final girth = _girthController.text.trim();
    final stump = _stumpController.text.trim();
    final longitude = _longitudeController.text.trim();
    final latitude = _latitudeController.text.trim();
    final biomass = _biomassController.text.trim();
    final sla = _slaController.text.trim();
    final longevity = _longevityController.text.trim();
    final leafLitterQuality = _leafLitterQualityController.text.trim();
    String? localImagePath;
    if (_pickedImage != null) {
      final file = File(_pickedImage!.path);
      final userId = _uploadUserId(name, desc, widget.zoneName);
      final appDocDir = await getApplicationDocumentsDirectory();
      final localDir = Directory('${appDocDir.path}/images/$userId');
      if (!await localDir.exists()) {
        await localDir.create(recursive: true);
      }
      final localFileName =
          '${DateTime.now().millisecondsSinceEpoch}_${_pickedImage!.name}';
      final localFilePath = '${localDir.path}/$localFileName';
      await file.copy(localFilePath);
      localImagePath = localFilePath;
    }
    if (name.isNotEmpty) {
      try {
        final docId = _plantationDocId(name, widget.zoneName);
        await FirebaseFirestore.instance
            .collection('plantation_records')
            .doc(docId)
            .set({
              'plantName': name,
              'plantNumber': desc,
              'healthStatus': error,
              'height': height,
              'girth': girth,
              'stump': stump,
              'longitude': longitude,
              'latitude': latitude,
              'biomass': biomass,
              'specificLeafArea': sla,
              'longevity': longevity,
              'leafLitterQuality': leafLitterQuality,
              'zoneId': widget.zoneId,
              'zoneName': widget.zoneName,
              'timestamp': DateTime.now().toIso8601String(),
              'Planted_On': DateTime.now().toIso8601String(),
              'localImagePath': localImagePath,
            });
        _nameController.clear();
        _descController.clear();
        _errorController.clear();
        _heightController.clear();
        _girthController.clear();
        _stumpController.clear();
        _longitudeController.clear();
        _latitudeController.clear();
        _biomassController.clear();
        _slaController.clear();
        _longevityController.clear();
        _leafLitterQualityController.clear();
        setState(() {
          _pickedImage = null;
        });
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Plant saved successfully!')));
      } catch (e) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Error saving plant: $e')));
      }
    }
  }

  void _openPlantListPage() async {
    await FirebaseConfig.logEvent(
      eventType: 'show_plant_list_clicked',
      description: 'Show plant list clicked',
      userId: loggedInMobile,
      details: {'zoneId': widget.zoneId, 'zoneName': widget.zoneName},
    );
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) =>
            PlantListPage(zoneId: widget.zoneId, zoneName: widget.zoneName),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!_checkedRole) {
      return Scaffold(
        appBar: AppBar(title: Text('Zone: ${widget.zoneName}')),
        body: Center(child: CircularProgressIndicator()),
      );
    }
    return Scaffold(
      appBar: AppBar(title: Text('Zone: ${widget.zoneName}')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(12.0),
            child: ElevatedButton(
              onPressed: _openPlantListPage,
              child: const Text('Show Plant List'),
            ),
          ),
          if (_isSuperAdmin)
            Expanded(
              child: Padding(
                padding: const EdgeInsets.all(12.0),
                child: SingleChildScrollView(
                  child: Column(
                    children: [
                      TextField(
                        controller: _nameController,
                        decoration: InputDecoration(
                          labelText: 'Plant Name',
                          border: OutlineInputBorder(),
                        ),
                      ),
                      const SizedBox(height: 8),
                      TextField(
                        controller: _descController,
                        decoration: InputDecoration(
                          labelText: 'Plant Number',
                          border: OutlineInputBorder(),
                        ),
                      ),
                      const SizedBox(height: 8),
                      DropdownButtonFormField<String>(
                        value: [
                          'Pest',
                          'Disease',
                          'Infected',
                          'Water Stress',
                          'Nutrient Deficiency',
                          'Physical Damage',
                          'Other',
                          'NA'
                        ].contains(_errorController.text)
                            ? _errorController.text
                            : null,
                        items: [
                          'Pest',
                          'Disease',
                          'Infected',
                          'Water Stress',
                          'Nutrient Deficiency',
                          'Physical Damage',
                          'Other',
                          'NA'
                        ]
                            .map((issue) => DropdownMenuItem(
                                  value: issue,
                                  child: Text(issue),
                                ))
                            .toList(),
                        onChanged: (value) {
                          _errorController.text = value ?? '';
                        },
                        decoration: InputDecoration(
                          labelText: 'Health Status',
                          border: OutlineInputBorder(),
                        ),
                      ),
                      const SizedBox(height: 8),
                      TextField(
                        controller: _heightController,
                        decoration: InputDecoration(
                          labelText: 'Height',
                          border: OutlineInputBorder(),
                        ),
                      ),
                      const SizedBox(height: 8),
                      TextField(
                        controller: _girthController,
                        decoration: InputDecoration(
                          labelText: 'Girth',
                          border: OutlineInputBorder(),
                        ),
                      ),
                      const SizedBox(height: 8),
                      TextField(
                        controller: _stumpController,
                        decoration: InputDecoration(
                          labelText: 'Stump',
                          border: OutlineInputBorder(),
                        ),
                      ),
                      const SizedBox(height: 8),
                      TextField(
                        controller: _longitudeController,
                        decoration: InputDecoration(
                          labelText: 'Longitude',
                          border: OutlineInputBorder(),
                        ),
                      ),
                      const SizedBox(height: 8),
                      TextField(
                        controller: _latitudeController,
                        decoration: InputDecoration(
                          labelText: 'Latitude',
                          border: OutlineInputBorder(),
                        ),
                      ),
                      const SizedBox(height: 8),
                      TextField(
                        controller: _biomassController,
                        decoration: InputDecoration(
                          labelText: 'Biomass',
                          border: OutlineInputBorder(),
                        ),
                      ),
                      const SizedBox(height: 8),
                      TextField(
                        controller: _slaController,
                        decoration: InputDecoration(
                          labelText: 'Specific Leaf Area',
                          border: OutlineInputBorder(),
                        ),
                      ),
                      const SizedBox(height: 8),
                      TextField(
                        controller: _longevityController,
                        decoration: InputDecoration(
                          labelText: 'Longevity',
                          border: OutlineInputBorder(),
                        ),
                      ),
                      const SizedBox(height: 8),
                      TextField(
                        controller: _leafLitterQualityController,
                        decoration: InputDecoration(
                          labelText: 'Leaf Litter Quality',
                          border: OutlineInputBorder(),
                        ),
                      ),
                      const SizedBox(height: 8),
                      // Image picker field
                      Row(
                        children: [
                          ElevatedButton.icon(
                            onPressed: () => _pickImage(ImageSource.gallery),
                            icon: const Icon(Icons.photo_library),
                            label: const Text('Gallery'),
                          ),
                          const SizedBox(width: 8),
                          ElevatedButton.icon(
                            onPressed: () => _pickImage(ImageSource.camera),
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
                        onPressed: _uploadImageToServer,
                        child: const Text('Upload Image to Server'),
                      ),
                      const SizedBox(height: 8),
                      ElevatedButton(
                        onPressed: _addPlant,
                        child: Text('Add Plant'),
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class PlantListPage extends StatefulWidget {
  final String zoneId;
  final String zoneName;
  const PlantListPage({required this.zoneId, required this.zoneName, Key? key})
    : super(key: key);

  @override
  State<PlantListPage> createState() => _PlantListPageState();
}

class _PlantListPageState extends State<PlantListPage> {
  bool _isSuperAdmin = false;
  bool _checkedRole = false;

  @override
  void initState() {
    super.initState();
    _checkRole();
    Future.microtask(() async {
      await FirebaseConfig.logEvent(
        eventType: 'plant_list_opened',
        description: 'Plant list opened',
        userId: loggedInMobile,
        details: {'zoneId': widget.zoneId, 'zoneName': widget.zoneName},
      );
    });
  }

  Future<void> _checkRole() async {
    if (loggedInMobile == null) {
      setState(() {
        _isSuperAdmin = false;
        _checkedRole = true;
      });
      return;
    }
    final query = await FirebaseFirestore.instance
        .collection('users')
        .where('mobile', isEqualTo: loggedInMobile)
        .limit(1)
        .get();
    bool isSuper = false;
    if (query.docs.isNotEmpty) {
      final data = query.docs.first.data();
      if (data['role']?.toString().toLowerCase() == 'super_admin' ||
          data['role']?.toString().toLowerCase() == 'superadmin') {
        isSuper = true;
      }
    }
    setState(() {
      _isSuperAdmin = isSuper;
      _checkedRole = true;
    });
  }

  // TODO List
  // - [ ] Analyze the current edit dialog implementation
  // - [ ] Add a dropdown to select a new zone in the edit dialog
  // - [ ] Update the database with the new zone when changes are saved
  // - [ ] Verify that the plant appears under the correct zone in the zone management tab
  // - [ ] Test the implementation to ensure it works as expected

  void _showEditPlantDialog(String plantId, Map<String, dynamic> plantData) {
    final nameController = TextEditingController(text: plantData['plantName'] ?? '');
    final descController = TextEditingController(text: plantData['plantNumber'] ?? '');
    final errorController = TextEditingController(
      text: plantData['healthStatus'] ?? '',
    );
    final heightController = TextEditingController(text: plantData['height'] ?? '');
    final girthController = TextEditingController(text: plantData['girth'] ?? '');
    final stumpController = TextEditingController(text: plantData['stump'] ?? '');
    final longitudeController = TextEditingController(text: plantData['longitude'] ?? '');
    final latitudeController = TextEditingController(text: plantData['latitude'] ?? '');
    final plantedOnController = TextEditingController(
      text: plantData['Planted_On'] ?? '',
    );
    final biomassController = TextEditingController(text: plantData['biomass'] ?? '');
    final slaController = TextEditingController(text: plantData['specificLeafArea'] ?? '');
    final longevityController = TextEditingController(text: plantData['longevity'] ?? '');
    final leafLitterQualityController = TextEditingController(text: plantData['leafLitterQuality'] ?? '');
    final originalData = Map<String, dynamic>.from(plantData);
    XFile? pickedImage;

    showDialog(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setState) {
            return AlertDialog(
              title: Text('Edit Plant'),
              content: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    TextField(
                      controller: nameController,
                      decoration: InputDecoration(
                        labelText: 'Plant Name',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: descController,
                      decoration: InputDecoration(
                        labelText: 'Plant Number',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 12),
                    DropdownButtonFormField<String>(
                        value: [
                          'Pest',
                          'Disease',
                          'Infected',
                          'Water Stress',
                          'Nutrient Deficiency',
                          'Physical Damage',
                          'Other',
                          'NA'
                        ].contains(errorController.text)
                          ? errorController.text
                          : null,
                      decoration: InputDecoration(
                        labelText: 'Health Status',
                        border: OutlineInputBorder(),
                      ),
                        items: [
                          'Pest',
                          'Disease',
                          'Infected',
                          'Water Stress',
                          'Nutrient Deficiency',
                          'Physical Damage',
                          'Other',
                          'NA'
                        ]
                          .map(
                            (issue) => DropdownMenuItem(
                              value: issue,
                              child: Text(issue),
                            ),
                          )
                          .toList(),
                      onChanged: (value) {
                        errorController.text = value ?? '';
                      },
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: heightController,
                      decoration: InputDecoration(
                        labelText: 'Height',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: girthController,
                      decoration: InputDecoration(
                        labelText: 'Girth',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: stumpController,
                      decoration: InputDecoration(
                        labelText: 'Stump',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: longitudeController,
                      decoration: InputDecoration(
                        labelText: 'Longitude',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: latitudeController,
                      decoration: InputDecoration(
                        labelText: 'Latitude',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: plantedOnController,
                      decoration: InputDecoration(
                        labelText: 'Planted On',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: biomassController,
                      decoration: InputDecoration(
                        labelText: 'Biomass',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: slaController,
                      decoration: InputDecoration(
                        labelText: 'Specific Leaf Area',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: longevityController,
                      decoration: InputDecoration(
                        labelText: 'Longevity',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: leafLitterQualityController,
                      decoration: InputDecoration(
                        labelText: 'Leaf Litter Quality',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 12),
                    FutureBuilder<QuerySnapshot>(
                      future: FirebaseFirestore.instance.collection('zones').get(),
                      builder: (context, zoneSnapshot) {
                        if (!zoneSnapshot.hasData) {
                          return CircularProgressIndicator();
                        }
                        final zones = zoneSnapshot.data!.docs;
                        return DropdownButtonFormField<String>(
                          value: plantData['zoneId'],
                          decoration: InputDecoration(
                            labelText: 'Zone',
                            border: OutlineInputBorder(),
                          ),
                          items: zones.map((zone) {
                            return DropdownMenuItem<String>(
                              value: zone.id,
                              child: Text(zone['name']),
                            );
                          }).toList(),
                          onChanged: (value) {
                            plantData['zoneId'] = value;
                          },
                        );
                      },
                    ),
                    const SizedBox(height: 12),
                    // Image picker field
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            ElevatedButton.icon(
                              onPressed: () async {
                                await FirebaseConfig.logEvent(
                                  eventType: 'plant_edit_pick_image',
                                  description: 'Plant edit pick image (gallery)',
                                  userId: loggedInMobile,
                                  details: {'plantId': plantId},
                                );
                                final ImagePicker picker = ImagePicker();
                                final XFile? image = await picker.pickImage(
                                  source: ImageSource.gallery,
                                );
                                if (image != null) {
                                  setState(() {
                                    pickedImage = image;
                                  });
                                }
                              },
                              icon: const Icon(Icons.photo_library),
                              label: const Text('Gallery'),
                            ),
                            const SizedBox(width: 8),
                            ElevatedButton.icon(
                              onPressed: () async {
                                await FirebaseConfig.logEvent(
                                  eventType: 'plant_edit_pick_image',
                                  description: 'Plant edit pick image (camera)',
                                  userId: loggedInMobile,
                                  details: {'plantId': plantId},
                                );
                                final ImagePicker picker = ImagePicker();
                                final XFile? image = await picker.pickImage(
                                  source: ImageSource.camera,
                                );
                                if (image != null) {
                                  setState(() {
                                    pickedImage = image;
                                  });
                                }
                              },
                              icon: const Icon(Icons.camera_alt),
                              label: const Text('Camera'),
                            ),
                            const SizedBox(width: 16),
                            pickedImage != null
                                ? SizedBox(
                                    width: 80,
                                    height: 80,
                                    child: Image.file(
                                      File(pickedImage!.path),
                                      fit: BoxFit.cover,
                                    ),
                                  )
                                : (plantData['localImagePath'] != null &&
                                        File(plantData['localImagePath']).existsSync()
                                    ? SizedBox(
                                        width: 80,
                                        height: 80,
                                        child: Image.file(
                                          File(plantData['localImagePath']),
                                          fit: BoxFit.cover,
                                          errorBuilder: (context, error, stackTrace) =>
                                              const Icon(Icons.broken_image, size: 80),
                                        ),
                                      )
                                    : const Text('No image selected')),
                          ],
                        ),
                        const SizedBox(height: 12),
                        ElevatedButton(
                          onPressed: () async {
                            await FirebaseConfig.logEvent(
                              eventType: 'plant_edit_upload_clicked',
                              description: 'Plant edit upload clicked',
                              userId: loggedInMobile,
                              details: {'plantId': plantId},
                            );
                            await FirebaseConfig.logEvent(
                              eventType: 'plant_edit_upload_initiated',
                              description: 'Plant edit upload initiated',
                              userId: loggedInMobile,
                              details: {'plantId': plantId},
                            );
                            if (pickedImage == null) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                  content: Text('No image selected'),
                                ),
                              );
                              return;
                            }
                            try {
                              var request = http.MultipartRequest(
                                'POST',
                                Uri.parse('http://80.225.203.181:8081/api/images/upload'),
                              );
                              request.files.add(
                                await http.MultipartFile.fromPath(
                                  'file',
                                  pickedImage!.path,
                                ),
                              );
                              final uploadUserId = _uploadUserId(
                                nameController.text.trim(),
                                descController.text.trim(),
                                widget.zoneName,
                              );
                              request.fields['userId'] = uploadUserId;
                              var response;
                              try {
                                response = await request.send().timeout(const Duration(seconds: 10));
                              } on TimeoutException catch (_) {
                                // Add to upload queue for retry
                                final userId = _uploadUserId(
                                  nameController.text.trim(),
                                  descController.text.trim(),
                                  widget.zoneName,
                                );
                                final docId = _plantationDocId(userId, widget.zoneName);
                                final uploadItem = UploadItem(
                                  id: DateTime.now().millisecondsSinceEpoch.toString(),
                                  imagePath: pickedImage!.path,
                                  userId: userId,
                                  docId: docId,
                                  createdAt: DateTime.now(),
                                );
                                await UploadQueueService.addToQueue(uploadItem);
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(content: Text('Server not responding. Image queued for upload when connection is available.')),
                                );
                                return;
                              } catch (e) {
                                // Add to upload queue for retry
                                final userId = _uploadUserId(
                                  nameController.text.trim(),
                                  descController.text.trim(),
                                  widget.zoneName,
                                );
                                final docId = _plantationDocId(userId, widget.zoneName);
                                final uploadItem = UploadItem(
                                  id: DateTime.now().millisecondsSinceEpoch.toString(),
                                  imagePath: pickedImage!.path,
                                  userId: userId,
                                  docId: docId,
                                  createdAt: DateTime.now(),
                                );
                                await UploadQueueService.addToQueue(uploadItem);
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(content: Text('Error uploading image. Queued for retry when connection is available.')),
                                );
                                return;
                              }
                              if (response != null && response.statusCode == 200) {
                                final filename = pickedImage!.name;
                                final userId = _uploadUserId(
                                  nameController.text.trim(),
                                  descController.text.trim(),
                                  widget.zoneName,
                                );
                                final imageUrl =
                                    'http://80.225.203.181:8081/api/images/view?userId=$userId&filename=$filename';
                                await FirebaseConfig.logEvent(
                                  eventType: 'plant_edit_upload_success',
                                  description: 'Plant edit image uploaded successfully',
                                  userId: loggedInMobile,
                                  details: {
                                    'plantId': plantId,
                                    'imageUrl': imageUrl,
                                    'statusCode': response.statusCode,
                                  },
                                );
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(content: Text('Image uploaded! URL: $imageUrl')),
                                );
                              } else if (response != null) {
                                await FirebaseConfig.logEvent(
                                  eventType: 'plant_edit_upload_failed',
                                  description: 'Plant edit image upload failed',
                                  userId: loggedInMobile,
                                  details: {
                                    'plantId': plantId,
                                    'statusCode': response.statusCode,
                                    'error': 'HTTP ${response.statusCode}',
                                  },
                                );
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(
                                    content: Text('Upload failed: ${response.statusCode}'),
                                  ),
                                );
                              }
                            } catch (e) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(content: Text('Error uploading image: $e')),
                              );
                            }
                          },
                          child: const Text('Upload Image to Server'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () async {
                    await FirebaseConfig.logEvent(
                      eventType: 'plant_edit_cancelled',
                      description: 'Plant edit cancelled',
                      userId: loggedInMobile,
                      details: {'plantId': plantId},
                    );
                    Navigator.pop(context);
                  },
                  child: const Text('Cancel'),
                ),
                ElevatedButton(
                  onPressed: () async {
                    await FirebaseConfig.logEvent(
                      eventType: 'plant_edit_save_clicked',
                      description: 'Plant edit save clicked',
                      userId: loggedInMobile,
                      details: {'plantId': plantId},
                    );
                    if (!_isSuperAdmin) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text('Only super admin can edit plants.')),
                      );
                      return;
                    }
                    
                    final name = nameController.text.trim();
                    if (name.isEmpty) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text('Plant name is required.')),
                      );
                      return;
                    }

                    String? localImagePath = plantData['localImagePath'];
                    if (pickedImage != null) {
                      final file = File(pickedImage!.path);
                      final userId = _uploadUserId(
                        nameController.text.trim(),
                        descController.text.trim(),
                        widget.zoneName,
                      );
                      final appDocDir = await getApplicationDocumentsDirectory();
                      final localDir = Directory('${appDocDir.path}/images/$userId');
                      if (!await localDir.exists()) {
                        await localDir.create(recursive: true);
                      }
                      final localFileName =
                          '${DateTime.now().millisecondsSinceEpoch}_${pickedImage!.name}';
                      final localFilePath = '${localDir.path}/$localFileName';
                      await file.copy(localFilePath);
                      localImagePath = localFilePath;
                    }

                    try {
                      final historicalData = Map<String, dynamic>.from(originalData);
                      historicalData['originalId'] = plantId;
                      historicalData['editedAt'] =
                          DateTime.now().toIso8601String();
                      final historyName =
                          (historicalData['plantName'] ?? '').toString();
                      final historyZone =
                          (historicalData['zoneName'] ?? widget.zoneName)
                              .toString();
                      final historyDocId =
                          _historicalDocId(historyName, historyZone);
                      await FirebaseFirestore.instance
                          .collection('HistoricalData')
                          .doc(historyDocId)
                          .set(historicalData);

                      // Get the zone name for the selected zoneId
                      final zoneSnapshot = await FirebaseFirestore.instance
                          .collection('zones')
                          .doc(plantData['zoneId'])
                          .get();
                      final zoneName = zoneSnapshot.data()?['name'] ?? '';
                      
                      await FirebaseFirestore.instance.collection('plantation_records').doc(plantId).update({
                        'plantName': name,
                        'plantNumber': descController.text.trim(),
                        'healthStatus': errorController.text.trim().isEmpty ? 'NA' : errorController.text.trim(),
                        'height': heightController.text.trim(),
                        'girth': girthController.text.trim(),
                        'stump': stumpController.text.trim(),
                        'longitude': longitudeController.text.trim(),
                        'latitude': latitudeController.text.trim(),
                        'biomass': biomassController.text.trim(),
                        'specificLeafArea': slaController.text.trim(),
                        'longevity': longevityController.text.trim(),
                        'leafLitterQuality': leafLitterQualityController.text.trim(),
                        'zoneId': plantData['zoneId'], // Update zoneId
                        'zoneName': zoneName, // Update zoneName
                        'Planted_On': plantedOnController.text.trim().isEmpty
                            ? DateTime.now().toIso8601String()
                            : plantedOnController.text.trim(),
                        'localImagePath': localImagePath,
                      });
                      
                      Navigator.pop(context);
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text('Plant updated successfully!'),
                          backgroundColor: Colors.green,
                        ),
                      );
                    } catch (e) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text('Error updating plant: $e'),
                          backgroundColor: Colors.red,
                        ),
                      );
                    }
                  },
                  child: const Text('Save Changes'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  void _showAddPlantDialog() {
    final nameController = TextEditingController();
    final descController = TextEditingController();
    final errorController = TextEditingController();
    final heightController = TextEditingController();
    final girthController = TextEditingController();
    final stumpController = TextEditingController();
    final longitudeController = TextEditingController();
    final latitudeController = TextEditingController();
    final biomassController = TextEditingController();
    final slaController = TextEditingController();
    final longevityController = TextEditingController();
    final leafLitterQualityController = TextEditingController();
    XFile? pickedImage;

    showDialog(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setState) {
            return AlertDialog(
              title: Text('Add New Plant'),
              content: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    TextField(
                      controller: nameController,
                      decoration: InputDecoration(
                        labelText: 'Plant Name',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: descController,
                      decoration: InputDecoration(
                        labelText: 'Plant Number',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 12),
                    DropdownButtonFormField<String>(
                      value: [
                        'Pest',
                        'Disease',
                        'Infected',
                        'Water Stress',
                        'Nutrient Deficiency',
                        'Physical Damage',
                        'Other',
                        'NA'
                      ].contains(errorController.text)
                          ? errorController.text
                          : null,
                      decoration: InputDecoration(
                        labelText: 'Health Status',
                        border: OutlineInputBorder(),
                      ),
                      items: [
                        'Pest',
                        'Disease',
                        'Infected',
                        'Water Stress',
                        'Nutrient Deficiency',
                        'Physical Damage',
                        'Other',
                        'NA'
                      ]
                          .map(
                            (issue) => DropdownMenuItem(
                              value: issue,
                              child: Text(issue),
                            ),
                          )
                          .toList(),
                      onChanged: (value) {
                        errorController.text = value ?? '';
                      },
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: heightController,
                      decoration: InputDecoration(
                        labelText: 'Height',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: girthController,
                      decoration: InputDecoration(
                        labelText: 'Girth',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: stumpController,
                      decoration: InputDecoration(
                        labelText: 'Stump',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: longitudeController,
                      decoration: InputDecoration(
                        labelText: 'Longitude',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: latitudeController,
                      decoration: InputDecoration(
                        labelText: 'Latitude',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: biomassController,
                      decoration: InputDecoration(
                        labelText: 'Biomass',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: slaController,
                      decoration: InputDecoration(
                        labelText: 'Specific Leaf Area',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: longevityController,
                      decoration: InputDecoration(
                        labelText: 'Longevity',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: leafLitterQualityController,
                      decoration: InputDecoration(
                        labelText: 'Leaf Litter Quality',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 12),
                    // Image picker field
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            ElevatedButton.icon(
                              onPressed: () async {
                                await FirebaseConfig.logEvent(
                                  eventType: 'plant_add_pick_image',
                                  description: 'Plant add pick image (gallery)',
                                  userId: loggedInMobile,
                                );
                                final ImagePicker picker = ImagePicker();
                                final XFile? image = await picker.pickImage(
                                  source: ImageSource.gallery,
                                );
                                if (image != null) {
                                  setState(() {
                                    pickedImage = image;
                                  });
                                }
                              },
                              icon: const Icon(Icons.photo_library),
                              label: const Text('Gallery'),
                            ),
                            const SizedBox(width: 8),
                            ElevatedButton.icon(
                              onPressed: () async {
                                await FirebaseConfig.logEvent(
                                  eventType: 'plant_add_pick_image',
                                  description: 'Plant add pick image (camera)',
                                  userId: loggedInMobile,
                                );
                                final ImagePicker picker = ImagePicker();
                                final XFile? image = await picker.pickImage(
                                  source: ImageSource.camera,
                                );
                                if (image != null) {
                                  setState(() {
                                    pickedImage = image;
                                  });
                                }
                              },
                              icon: const Icon(Icons.camera_alt),
                              label: const Text('Camera'),
                            ),
                            const SizedBox(width: 16),
                            pickedImage != null
                                ? SizedBox(
                                    width: 80,
                                    height: 80,
                                    child: Image.file(
                                      File(pickedImage!.path),
                                      fit: BoxFit.cover,
                                    ),
                                  )
                                : const Text('No image selected'),
                          ],
                        ),
                        const SizedBox(height: 12),
                        ElevatedButton(
                          onPressed: () async {
                            await FirebaseConfig.logEvent(
                              eventType: 'plant_add_upload_clicked',
                              description: 'Plant add upload clicked',
                              userId: loggedInMobile,
                            );
                            await FirebaseConfig.logEvent(
                              eventType: 'plant_add_upload_initiated',
                              description: 'Plant add upload initiated',
                              userId: loggedInMobile,
                            );
                            if (pickedImage == null) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                  content: Text('No image selected'),
                                ),
                              );
                              return;
                            }
                            try {
                              var request = http.MultipartRequest(
                                'POST',
                                Uri.parse('http://80.225.203.181:8081/api/images/upload'),
                              );
                              request.files.add(
                                await http.MultipartFile.fromPath(
                                  'file',
                                  pickedImage!.path,
                                ),
                              );
                              final uploadUserId = _uploadUserId(
                                nameController.text.trim(),
                                descController.text.trim(),
                                widget.zoneName,
                              );
                              request.fields['userId'] = uploadUserId;
                              var response;
                              try {
                                response = await request.send().timeout(const Duration(seconds: 10));
                              } on TimeoutException catch (_) {
                                // Add to upload queue for retry
                                final userId = _uploadUserId(
                                  nameController.text.trim(),
                                  descController.text.trim(),
                                  widget.zoneName,
                                );
                                final docId = _plantationDocId(userId, widget.zoneName);
                                final uploadItem = UploadItem(
                                  id: DateTime.now().millisecondsSinceEpoch.toString(),
                                  imagePath: pickedImage!.path,
                                  userId: userId,
                                  docId: docId,
                                  createdAt: DateTime.now(),
                                );
                                await UploadQueueService.addToQueue(uploadItem);
                                await FirebaseConfig.logEvent(
                                  eventType: 'plant_add_upload_timeout',
                                  description: 'Plant add upload timeout - queued for retry',
                                  userId: loggedInMobile,
                                  details: {
                                    'queueId': uploadItem.id,
                                    'error': 'Server timeout',
                                  },
                                );
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(content: Text('Server not responding. Image queued for upload when connection is available.')),
                                );
                                return;
                              } catch (e) {
                                // Add to upload queue for retry
                                final userId = _uploadUserId(
                                  nameController.text.trim(),
                                  descController.text.trim(),
                                  widget.zoneName,
                                );
                                final docId = _plantationDocId(userId, widget.zoneName);
                                final uploadItem = UploadItem(
                                  id: DateTime.now().millisecondsSinceEpoch.toString(),
                                  imagePath: pickedImage!.path,
                                  userId: userId,
                                  docId: docId,
                                  createdAt: DateTime.now(),
                                );
                                await UploadQueueService.addToQueue(uploadItem);
                                await FirebaseConfig.logEvent(
                                  eventType: 'plant_add_upload_error',
                                  description: 'Plant add upload error - queued for retry',
                                  userId: loggedInMobile,
                                  details: {
                                    'queueId': uploadItem.id,
                                    'error': e.toString(),
                                  },
                                );
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(content: Text('Error uploading image. Queued for retry when connection is available.')),
                                );
                                return;
                              }
                              if (response != null && response.statusCode == 200) {
                                final filename = pickedImage!.name;
                                final userId = _uploadUserId(
                                  nameController.text.trim(),
                                  descController.text.trim(),
                                  widget.zoneName,
                                );
                                final imageUrl =
                                    'http://80.225.203.181:8081/api/images/view?userId=$userId&filename=$filename';
                                await FirebaseConfig.logEvent(
                                  eventType: 'plant_add_upload_success',
                                  description: 'Plant add image uploaded successfully',
                                  userId: loggedInMobile,
                                  details: {
                                    'imageUrl': imageUrl,
                                    'statusCode': response.statusCode,
                                  },
                                );
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(content: Text('Image uploaded! URL: $imageUrl')),
                                );
                              } else if (response != null) {
                                await FirebaseConfig.logEvent(
                                  eventType: 'plant_add_upload_failed',
                                  description: 'Plant add image upload failed',
                                  userId: loggedInMobile,
                                  details: {
                                    'statusCode': response.statusCode,
                                    'error': 'HTTP ${response.statusCode}',
                                  },
                                );
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(
                                    content: Text('Upload failed: ${response.statusCode}'),
                                  ),
                                );
                              }
                            } catch (e) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(content: Text('Error uploading image: $e')),
                              );
                            }
                          },
                          child: const Text('Upload Image to Server'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () async {
                    await FirebaseConfig.logEvent(
                      eventType: 'plant_add_cancelled',
                      description: 'Plant add cancelled',
                      userId: loggedInMobile,
                    );
                    Navigator.pop(context);
                  },
                  child: const Text('Cancel'),
                ),
                ElevatedButton(
                  onPressed: () async {
                    await FirebaseConfig.logEvent(
                      eventType: 'plant_add_confirmed',
                      description: 'Plant add confirmed',
                      userId: loggedInMobile,
                    );
                    if (!_isSuperAdmin) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text('Only super admin can add plants.')),
                      );
                      return;
                    }
                    
                    final name = nameController.text.trim();
                    if (name.isEmpty) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text('Plant name is required.')),
                      );
                      return;
                    }

                    String? localImagePath;
                    if (pickedImage != null) {
                      final file = File(pickedImage!.path);
                      final userId = _uploadUserId(
                        nameController.text.trim(),
                        descController.text.trim(),
                        widget.zoneName,
                      );
                      final appDocDir = await getApplicationDocumentsDirectory();
                      final localDir = Directory('${appDocDir.path}/images/$userId');
                      if (!await localDir.exists()) {
                        await localDir.create(recursive: true);
                      }
                      final localFileName =
                          '${DateTime.now().millisecondsSinceEpoch}_${pickedImage!.name}';
                      final localFilePath = '${localDir.path}/$localFileName';
                      await file.copy(localFilePath);
                      localImagePath = localFilePath;
                    }

                    try {
                      final docId = _plantationDocId(name, widget.zoneName);
                      await FirebaseFirestore.instance
                          .collection('plantation_records')
                          .doc(docId)
                          .set({
                            'plantName': name,
                            'plantNumber': descController.text.trim(),
                            'healthStatus':
                                errorController.text.trim().isEmpty
                                    ? 'NA'
                                    : errorController.text.trim(),
                            'height': heightController.text.trim(),
                            'girth': girthController.text.trim(),
                            'stump': stumpController.text.trim(),
                            'longitude': longitudeController.text.trim(),
                            'latitude': latitudeController.text.trim(),
                            'biomass': biomassController.text.trim(),
                            'specificLeafArea': slaController.text.trim(),
                            'longevity': longevityController.text.trim(),
                            'leafLitterQuality': leafLitterQualityController.text.trim(),
                            'zoneId': widget.zoneId,
                            'zoneName': widget.zoneName,
                            'timestamp': DateTime.now().toIso8601String(),
                            'Planted_On': DateTime.now().toIso8601String(),
                            'localImagePath': localImagePath,
                          });
                      
                      Navigator.pop(context);
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text('Plant added successfully!'),
                          backgroundColor: Colors.green,
                        ),
                      );
                    } catch (e) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text('Error adding plant: $e'),
                          backgroundColor: Colors.red,
                        ),
                      );
                    }
                  },
                  child: const Text('Add Plant'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!_checkedRole) {
      return Scaffold(
        appBar: AppBar(title: Text('Plants in ${widget.zoneName}')),
        body: Center(child: CircularProgressIndicator()),
      );
    }

    return Scaffold(
      appBar: AppBar(title: Text('Plants in ${widget.zoneName}')),
      body: Column(
        children: [
          if (_isSuperAdmin)
            Padding(
              padding: const EdgeInsets.all(12.0),
              child: ElevatedButton(
                onPressed: () async {
                  await FirebaseConfig.logEvent(
                    eventType: 'add_plant_dialog_opened',
                    description: 'Add plant dialog opened',
                    userId: loggedInMobile,
                    details: {'zoneId': widget.zoneId, 'zoneName': widget.zoneName},
                  );
                  _showAddPlantDialog();
                },
                child: const Text('Add Plant'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.green,
                  foregroundColor: Colors.white,
                ),
              ),
            ),
          Expanded(
            child: StreamBuilder<QuerySnapshot>(
              stream: FirebaseFirestore.instance
                  .collection('plantation_records')
                  .where('zoneId', isEqualTo: widget.zoneId)
                  .snapshots(),
              builder: (context, snapshot) {
                if (snapshot.connectionState == ConnectionState.waiting) {
                  return Center(child: CircularProgressIndicator());
                }
                if (!snapshot.hasData) {
                  return Center(child: Text('No plants found in this zone.'));
                }
                final plants = snapshot.data!.docs
                    .where((doc) => doc['zoneId'] == widget.zoneId)
                    .toList();
                if (plants.isEmpty) {
                  return Center(child: Text('No plants found in this zone.'));
                }
                plants.sort((a, b) {
                  final aTime = a['timestamp'] ?? '';
                  final bTime = b['timestamp'] ?? '';
                  return bTime.compareTo(aTime);
                });
                return ListView.builder(
                  itemCount: plants.length,
                  itemBuilder: (context, index) {
                    final plant = plants[index];
                    final plantData = plant.data() as Map<String, dynamic>;
                    return ListTile(
                      tileColor: plantData['healthStatus'] != null &&
                              plantData['healthStatus'] != 'NA'
                          ? Colors.red[100]
                          : null,
                      title: Text(plantData['plantName'] ?? ''),
                      subtitle: Text(
                        'Plant Number: ${plantData['plantNumber'] ?? ''}\nHealth Status: ${plantData['healthStatus'] ?? ''}',
                      ),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          ElevatedButton(
                            onPressed: () async {
                              await FirebaseConfig.logEvent(
                                eventType: 'plant_details_clicked',
                                description: 'Plant details clicked',
                                userId: loggedInMobile,
                                details: {
                                  'zoneId': widget.zoneId,
                                  'zoneName': widget.zoneName,
                                  'plantId': plant.id,
                                  'plantName': plantData['plantName'],
                                },
                              );
                              showDialog(
                                context: context,
                                builder: (context) {
                                  return AlertDialog(
                                    title: Text('Plant Details'),
                                    content: SingleChildScrollView(
                                      child: Column(
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        children: [
                                          Text('Plant Name: ${plantData['plantName'] ?? ''}'),
                                          Text('Plant Number: ${plantData['plantNumber'] ?? ''}'),
                                          Text('Planted On: ${plantData['Planted_On'] ?? ''}'),
                                          Text(
                                            'Health Status: ${plantData['healthStatus'] ?? ''}',
                                          ),
                                          Text('Height: ${plantData['height'] ?? ''}'),
                                          Text('Girth: ${plantData['girth'] ?? ''}'),
                                          Text('Stump: ${plantData['stump'] ?? ''}'),
                                          Text('Longitude: ${plantData['longitude'] ?? ''}'),
                                          Text('Latitude: ${plantData['latitude'] ?? ''}'),
                                          Text('Biomass: ${plantData['biomass'] ?? ''}'),
                                          Text('Specific Leaf Area: ${plantData['specificLeafArea'] ?? ''}'),
                                          Text('Longevity: ${plantData['longevity'] ?? ''}'),
                                          Text('Leaf Litter Quality: ${plantData['leafLitterQuality'] ?? ''}'),
                                          if (plantData['localImagePath'] != null && File(plantData['localImagePath']).existsSync())
                                            Padding(
                                              padding: const EdgeInsets.only(top: 8.0),
                                              child: Image.file(
                                                File(plantData['localImagePath']),
                                                width: 80,
                                                height: 80,
                                                fit: BoxFit.cover,
                                                errorBuilder: (context, error, stackTrace) =>
                                                    const Icon(Icons.broken_image, size: 80),
                                              ),
                                            ),
                                        ],
                                      ),
                                    ),
                                    actions: [
                                      TextButton(
                                        onPressed: () async {
                                          await FirebaseConfig.logEvent(
                                            eventType: 'plant_details_closed',
                                            description: 'Plant details closed',
                                            userId: loggedInMobile,
                                            details: {
                                              'zoneId': widget.zoneId,
                                              'zoneName': widget.zoneName,
                                              'plantId': plant.id,
                                            },
                                          );
                                          Navigator.pop(context);
                                        },
                                        child: const Text('Close'),
                                      ),
                                    ],
                                  );
                                },
                              );
                            },
                            child: const Text('Details'),
                          ),
                          const SizedBox(width: 8),
                          ElevatedButton(
                            onPressed: () async {
                              await FirebaseConfig.logEvent(
                                eventType: 'plant_edit_clicked',
                                description: 'Plant edit clicked',
                                userId: loggedInMobile,
                                details: {
                                  'zoneId': widget.zoneId,
                                  'zoneName': widget.zoneName,
                                  'plantId': plant.id,
                                  'plantName': plantData['plantName'],
                                },
                              );
                              _showEditPlantDialog(plant.id, plantData);
                            },
                            child: const Text('Edit'),
                          ),
                          const SizedBox(width: 8),
                          IconButton(
                            icon: Icon(Icons.close, color: Colors.red),
                            tooltip: 'Delete',
                            onPressed: () async {
                              await FirebaseConfig.logEvent(
                                eventType: 'plant_delete_clicked',
                                description: 'Plant delete clicked',
                                userId: loggedInMobile,
                                details: {
                                  'zoneId': widget.zoneId,
                                  'zoneName': widget.zoneName,
                                  'plantId': plant.id,
                                  'plantName': plantData['plantName'],
                                },
                              );
                              final confirm = await showDialog<bool>(
                                context: context,
                                builder: (context) => AlertDialog(
                                  title: Text('Delete Plant'),
                                  content: Text(
                                    'Are you sure you want to delete ${plantData['plantName'] ?? 'this plant'}?',
                                  ),
                                  actions: [
                                    TextButton(
                                      onPressed: () => Navigator.pop(context, false),
                                      child: Text('Cancel'),
                                    ),
                                    TextButton(
                                      onPressed: () => Navigator.pop(context, true),
                                      child: Text(
                                        'Delete',
                                        style: TextStyle(color: Colors.red),
                                      ),
                                    ),
                                  ],
                                ),
                              );
                              if (confirm == true) {
                                final historicalData =
                                    Map<String, dynamic>.from(plantData);
                                historicalData['originalId'] = plant.id;
                                historicalData['deletedAt'] =
                                    DateTime.now().toIso8601String();
                                await FirebaseFirestore.instance
                                    .collection('HistoricalData')
                                    .add(historicalData);

                                await FirebaseFirestore.instance
                                    .collection('plantation_records')
                                    .doc(plant.id)
                                    .delete();
                              }
                            },
                          ),
                        ],
                      ),
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
