import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:plantation_summary/main.dart';
import 'package:image_picker/image_picker.dart';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

class ZoneManagementPage extends StatefulWidget {
  const ZoneManagementPage({Key? key}) : super(key: key);

  @override
  State<ZoneManagementPage> createState() => _ZoneManagementPageState();
}

class _ZoneManagementPageState extends State<ZoneManagementPage> {
  final TextEditingController _zoneController = TextEditingController();

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
    if (!await _isSuperAdmin()) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Only super admin can add zones.')),
      );
      return;
    }
    final zoneName = _zoneController.text.trim();
    if (zoneName.isNotEmpty) {
      await FirebaseFirestore.instance.collection('zones').add({
        'name': zoneName,
      });
      _zoneController.clear();
    }
  }

  void _openZone(BuildContext context, String zoneId, String zoneName) {
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
            appBar: AppBar(title: Text('Zone Management')),
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

        return Scaffold(
          appBar: AppBar(title: Text('Zone Management')),
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
                                    data['error'] != null &&
                                    data['error'] != 'NA';
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
      builder: (context) => ZoneDetailPage(zoneId: zoneId, zoneName: zoneName),
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

  Future<void> _pickImage() async {
    final XFile? image = await _picker.pickImage(source: ImageSource.gallery);
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
    try {
      var request = http.MultipartRequest(
        'POST',
        Uri.parse('http://80.225.203.181:8081/api/images/upload'),
      );
      request.files.add(
        await http.MultipartFile.fromPath('file', _pickedImage!.path),
      );
      request.fields['userId'] = _nameController.text.trim().isEmpty
          ? 'unknown'
          : _nameController.text.trim();
      var response = await request.send();
      if (response.statusCode == 200) {
        final filename = _pickedImage!.name;
        final userId = _nameController.text.trim().isEmpty
            ? 'unknown'
            : _nameController.text.trim();
        final imageUrl =
            'http://80.225.203.181:8081/api/images/view?userId=$userId&filename=$filename';
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
    }
  }

  void _addPlant() async {
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
    final biomass = _biomassController.text.trim();
    final sla = _slaController.text.trim();
    final longevity = _longevityController.text.trim();
    final leafLitterQuality = _leafLitterQualityController.text.trim();
    String? localImagePath;
    if (_pickedImage != null) {
      final file = File(_pickedImage!.path);
      final userId = _nameController.text.trim().isEmpty
          ? 'unknown'
          : _nameController.text.trim();
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
        await FirebaseFirestore.instance.collection('plantation_records').add({
          'name': name,
          'description': desc,
          'error': error,
          'height': height,
          'biomass': biomass,
          'specificLeafArea': sla,
          'longevity': longevity,
          'leafLitterQuality': leafLitterQuality,
          'zoneId': widget.zoneId,
          'zoneName': widget.zoneName,
          'timestamp': DateTime.now().toIso8601String(),
          'localImagePath': localImagePath,
        });
        _nameController.clear();
        _descController.clear();
        _errorController.clear();
        _heightController.clear();
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

  void _openPlantListPage() {
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
                          labelText: 'Description',
                          border: OutlineInputBorder(),
                        ),
                      ),
                      const SizedBox(height: 8),
                      DropdownButtonFormField<String>(
                        value: [
                          'Pest',
                          'Disease',
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
                          labelText: 'Issue',
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

class PlantListPage extends StatelessWidget {
  final String zoneId;
  final String zoneName;
  const PlantListPage({required this.zoneId, required this.zoneName, Key? key})
    : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('Plants in $zoneName')),
      body: StreamBuilder<QuerySnapshot>(
        stream: FirebaseFirestore.instance
            .collection('plantation_records')
            .where('zoneId', isEqualTo: zoneId)
            .snapshots(),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return Center(child: CircularProgressIndicator());
          }
          if (!snapshot.hasData) {
            return Center(child: Text('No plants found in this zone.'));
          }
          final plants = snapshot.data!.docs
              .where((doc) => doc['zoneId'] == zoneId)
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
                tileColor: plantData['error'] != null && plantData['error'] != 'NA'
                    ? Colors.red[100]
                    : null,
                title: Text(plantData['name'] ?? ''),
                subtitle: Text(
                  'Description: ${plantData['description'] ?? ''}\nIssue: ${plantData['error'] ?? ''}',
                ),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    ElevatedButton(
                      onPressed: () {
                        showDialog(
                          context: context,
                          builder: (context) {
                            return AlertDialog(
                              title: Text('Plant Details'),
                              content: SingleChildScrollView(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text('Name: ${plantData['name'] ?? ''}'),
                                    Text(
                                      'Description: ${plantData['description'] ?? ''}',
                                    ),
                                    Text('Issue: ${plantData['error'] ?? ''}'),
                                    Text(
                                      'Height: ${plantData['height'] ?? ''}',
                                    ),
                                    Text(
                                      'Biomass: ${plantData['biomass'] ?? ''}',
                                    ),
                                    Text(
                                      'Specific Leaf Area: ${plantData['specificLeafArea'] ?? ''}',
                                    ),
                                    Text(
                                      'Longevity: ${plantData['longevity'] ?? ''}',
                                    ),
                                    Text(
                                      'Leaf Litter Quality: ${plantData['leafLitterQuality'] ?? ''}',
                                    ),
                                    if (plantData['localImagePath'] != null)
                                      Padding(
                                        padding: const EdgeInsets.only(
                                          top: 8.0,
                                        ),
                                        child: Image.file(
                                          File(plantData['localImagePath']),
                                          width: 80,
                                          height: 80,
                                          fit: BoxFit.cover,
                                        ),
                                      ),
                                  ],
                                ),
                              ),
                              actions: [
                                TextButton(
                                  onPressed: () => Navigator.pop(context),
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
                        // Replicate edit logic from details page
                        final nameController = TextEditingController(
                          text: plantData['name'] ?? '',
                        );
                        final descController = TextEditingController(
                          text: plantData['description'] ?? '',
                        );
                        final errorController = TextEditingController(
                          text: plantData['error'] ?? '',
                        );
                        final heightController = TextEditingController(
                          text: plantData['height'] ?? '',
                        );
                        final biomassController = TextEditingController(
                          text: plantData['biomass'] ?? '',
                        );
                        final slaController = TextEditingController(
                          text: plantData['specificLeafArea'] ?? '',
                        );
                        final longevityController = TextEditingController(
                          text: plantData['longevity'] ?? '',
                        );
                        final leafLitterQualityController =
                            TextEditingController(
                              text: plantData['leafLitterQuality'] ?? '',
                            );
                        XFile? pickedImage;
                        await showDialog(
                          context: context,
                          builder: (context) {
                            return StatefulBuilder(
                              builder: (context, setState) {
                                return AlertDialog(
                                  title: Text('Edit Plant'),
                                  content: SingleChildScrollView(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        TextField(
                                          controller: nameController,
                                          decoration: InputDecoration(
                                            labelText: 'Plant Name',
                                          ),
                                        ),
                                        TextField(
                                          controller: descController,
                                          decoration: InputDecoration(
                                            labelText: 'Description',
                                          ),
                                        ),
                                        DropdownButtonFormField<String>(
                                          value:
                                              [
                                                'Pest',
                                                'Disease',
                                                'Water Stress',
                                                'Nutrient Deficiency',
                                                'Physical Damage',
                                                'Other',
                                                'NA',
                                              ].contains(errorController.text)
                                              ? errorController.text
                                              : null,
                                          decoration: const InputDecoration(
                                            labelText: 'Issue',
                                          ),
                                          items:
                                              [
                                                    'Pest',
                                                    'Disease',
                                                    'Water Stress',
                                                    'Nutrient Deficiency',
                                                    'Physical Damage',
                                                    'Other',
                                                    'NA',
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
                                        TextField(
                                          controller: heightController,
                                          decoration: InputDecoration(
                                            labelText: 'Height',
                                          ),
                                        ),
                                        TextField(
                                          controller: biomassController,
                                          decoration: InputDecoration(
                                            labelText: 'Biomass',
                                          ),
                                        ),
                                        TextField(
                                          controller: slaController,
                                          decoration: InputDecoration(
                                            labelText: 'Specific Leaf Area',
                                          ),
                                        ),
                                        TextField(
                                          controller: longevityController,
                                          decoration: InputDecoration(
                                            labelText: 'Longevity',
                                          ),
                                        ),
                                        TextField(
                                          controller:
                                              leafLitterQualityController,
                                          decoration: InputDecoration(
                                            labelText: 'Leaf Litter Quality',
                                          ),
                                        ),
                                        const SizedBox(height: 8),
                                        Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Row(
                                              children: [
                                                ElevatedButton(
                                                  onPressed: () async {
                                                    final ImagePicker picker =
                                                        ImagePicker();
                                                    final XFile? image =
                                                        await picker.pickImage(
                                                          source: ImageSource
                                                              .gallery,
                                                        );
                                                    if (image != null) {
                                                      setState(() {
                                                        pickedImage = image;
                                                      });
                                                    }
                                                  },
                                                  child: const Text(
                                                    'Pick Image',
                                                  ),
                                                ),
                                                const SizedBox(width: 16),
                                                pickedImage != null
                                                    ? SizedBox(
                                                        width: 80,
                                                        height: 80,
                                                        child: Image.file(
                                                          File(
                                                            pickedImage!.path,
                                                          ),
                                                          fit: BoxFit.cover,
                                                        ),
                                                      )
                                                    : (plantData['localImagePath'] !=
                                                              null
                                                          ? SizedBox(
                                                              width: 80,
                                                              height: 80,
                                                              child: Image.file(
                                                                File(
                                                                  plantData['localImagePath'],
                                                                ),
                                                                fit: BoxFit
                                                                    .cover,
                                                              ),
                                                            )
                                                          : const Text(
                                                              'No image selected',
                                                            )),
                                              ],
                                            ),
                                            const SizedBox(height: 8),
                                            ElevatedButton(
                                              onPressed: () async {
                                                if (pickedImage == null) {
                                                  ScaffoldMessenger.of(
                                                    context,
                                                  ).showSnackBar(
                                                    const SnackBar(
                                                      content: Text(
                                                        'No image selected',
                                                      ),
                                                    ),
                                                  );
                                                  return;
                                                }
                                                try {
                                                  var request =
                                                      http.MultipartRequest(
                                                        'POST',
                                                        Uri.parse(
                                                          'http://80.225.203.181:8081/api/images/upload',
                                                        ),
                                                      );
                                                  request.files.add(
                                                    await http
                                                        .MultipartFile.fromPath(
                                                      'file',
                                                      pickedImage!.path,
                                                    ),
                                                  );
                                                  request.fields['userId'] =
                                                      nameController.text
                                                          .trim()
                                                          .isEmpty
                                                      ? 'unknown'
                                                      : nameController.text
                                                            .trim();
                                                  var response = await request
                                                      .send();
                                                  if (response.statusCode ==
                                                      200) {
                                                    final filename =
                                                        pickedImage!.name;
                                                    final userId =
                                                        nameController.text
                                                            .trim()
                                                            .isEmpty
                                                        ? 'unknown'
                                                        : nameController.text
                                                              .trim();
                                                    final imageUrl =
                                                        'http://80.225.203.181:8081/api/images/view?userId=$userId&filename=$filename';
                                                    ScaffoldMessenger.of(
                                                      context,
                                                    ).showSnackBar(
                                                      SnackBar(
                                                        content: Text(
                                                          'Image uploaded! URL: $imageUrl',
                                                        ),
                                                      ),
                                                    );
                                                  } else {
                                                    ScaffoldMessenger.of(
                                                      context,
                                                    ).showSnackBar(
                                                      SnackBar(
                                                        content: Text(
                                                          'Upload failed: ${response.statusCode}',
                                                        ),
                                                      ),
                                                    );
                                                  }
                                                } catch (e) {
                                                  ScaffoldMessenger.of(
                                                    context,
                                                  ).showSnackBar(
                                                    SnackBar(
                                                      content: Text(
                                                        'Error uploading image: $e',
                                                      ),
                                                    ),
                                                  );
                                                }
                                              },
                                              child: const Text(
                                                'Upload Image to Server',
                                              ),
                                            ),
                                          ],
                                        ),
                                      ],
                                    ),
                                  ),
                                  actions: [
                                    TextButton(
                                      onPressed: () => Navigator.pop(context),
                                      child: const Text('Cancel'),
                                    ),
                                    ElevatedButton(
                                      onPressed: () async {
                                        Map<String, dynamic> updateData = {
                                          'name': nameController.text.trim(),
                                          'description': descController.text.trim(),
                                          'error': errorController.text.trim(),
                                          'height': heightController.text.trim(),
                                          'biomass': biomassController.text.trim(),
                                          'specificLeafArea': slaController.text.trim(),
                                          'longevity': longevityController.text.trim(),
                                          'leafLitterQuality': leafLitterQualityController.text.trim(),
                                          // Optionally handle image update logic here
                                        };
                                        print('DEBUG: Update data: $updateData');
                                        try {
                                          await FirebaseFirestore.instance
                                              .collection('plantation_records')
                                              .doc(plant.id)
                                              .update(updateData);
                                          print('DEBUG: Firestore update successful');
                                          Navigator.pop(context);
                                          print('DEBUG: Dialog closed');
                                          Future.microtask(() {
                                            print('DEBUG: Showing SnackBar');
                                            ScaffoldMessenger.of(context).showSnackBar(
                                              const SnackBar(
                                                content: Text('Record updated successfully.'),
                                                backgroundColor: Colors.green,
                                              ),
                                            );
                                          });
                                        } catch (e) {
                                          print('DEBUG: Firestore update error: $e');
                                          ScaffoldMessenger.of(context).showSnackBar(
                                            SnackBar(
                                              content: Text('Error updating record: $e'),
                                              backgroundColor: Colors.red,
                                            ),
                                          );
                                        }
                                      },
                                      child: const Text('Save'),
                                    ),
                                  ],
                                );
                              },
                            );
                          },
                        );
                      },
                      child: const Text('Edit'),
                    ),
                    const SizedBox(width: 8),
                    IconButton(
                      icon: Icon(Icons.close, color: Colors.red),
                      tooltip: 'Delete',
                      onPressed: () async {
                        final confirm = await showDialog<bool>(
                          context: context,
                          builder: (context) => AlertDialog(
                            title: Text('Delete Plant'),
                            content: Text(
                              'Are you sure you want to delete ${plantData['name'] ?? 'this plant'}?',
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
    );
  }
}
