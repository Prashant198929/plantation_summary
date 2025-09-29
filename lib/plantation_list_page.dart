import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:image_picker/image_picker.dart';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:plantation_summary/main.dart';

class PlantationListPage extends StatefulWidget {
  const PlantationListPage({Key? key}) : super(key: key);

  @override
  State<PlantationListPage> createState() => _PlantationListPageState();
}

class _PlantationListPageState extends State<PlantationListPage> {
  String? userZone;
  bool isSuperAdmin = false;
  bool loading = true;

  @override
  void initState() {
    super.initState();
    _fetchUserZone();
  }

  Future<void> _fetchUserZone() async {
    if (loggedInMobile == null) {
      setState(() {
        loading = false;
      });
      return;
    }
    final query = await FirebaseFirestore.instance
        .collection('users')
        .where('mobile', isEqualTo: loggedInMobile)
        .limit(1)
        .get();
    if (query.docs.isNotEmpty) {
      final data = query.docs.first.data();
      if (data['role']?.toString().toLowerCase() == 'super_admin' ||
          data['role']?.toString().toLowerCase() == 'superadmin') {
        setState(() {
          isSuperAdmin = true;
          loading = false;
        });
      } else {
        setState(() {
          userZone = data['zone'];
          isSuperAdmin = false;
          loading = false;
        });
      }
    } else {
      setState(() {
        loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (loading) {
      return Scaffold(
        appBar: AppBar(title: const Text('Plantation Records')),
        body: const Center(child: CircularProgressIndicator()),
      );
    }
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Plantation Records'),
          bottom: TabBar(
            indicatorColor: Colors.white,
            tabs: [
              Tab(text: 'All Records'),
              Tab(text: 'Other'),
            ],
          ),
        ),
        body: TabBarView(
          children: [
            // All Records Tab
            StreamBuilder<QuerySnapshot>(
              stream: isSuperAdmin
                  ? FirebaseFirestore.instance
                        .collection('plantation_records')
                        .snapshots()
                  : FirebaseFirestore.instance
                        .collection('plantation_records')
                        .where('zoneName', isEqualTo: userZone)
                        .snapshots(),
              builder: (context, snapshot) {
                if (snapshot.connectionState == ConnectionState.waiting) {
                  return Center(child: CircularProgressIndicator());
                }
                if (!snapshot.hasData || snapshot.data!.docs.isEmpty) {
                  return Center(child: Text('No plantation records found.'));
                }
                final plants = snapshot.data!.docs;
                return ListView.builder(
                  itemCount: plants.length,
                  itemBuilder: (context, index) {
                    final plant = plants[index];
                    final plantData = plant.data() as Map<String, dynamic>;
                    return ListTile(
                      tileColor: plantData['error'] != null && plantData['error'] != 'NA'
                          ? Colors.red[100]
                          : null,
                      title: Row(
                        children: [
                          Expanded(
                            child: Text(
                              '${plantData['name'] ?? ''} (${plantData['zoneName'] ?? ''})',
                            ),
                          ),
                          ElevatedButton(
                            onPressed: () {
                              showDialog(
                                context: context,
                                builder: (context) => AlertDialog(
                                  title: Text(plantData['name'] ?? 'Plant Details'),
                                  content: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      if (plantData['zoneName'] != null)
                                        Text('Zone: ${plantData['zoneName']}'),
                                      if (plantData['description'] != null)
                                        Text(
                                          'Description: ${plantData['description']}',
                                        ),
                                      if (plantData['error'] != null)
                                        Text('Issue: ${plantData['error']}'),
                                      if (plantData['height'] != null)
                                        Text('Height: ${plantData['height']}'),
                                      if (plantData['biomass'] != null)
                                        Text('Biomass: ${plantData['biomass']}'),
                                      if (plantData['specificLeafArea'] != null)
                                        Text(
                                          'Specific Leaf Area: ${plantData['specificLeafArea']}',
                                        ),
                                      if (plantData['longevity'] != null)
                                        Text('Longevity: ${plantData['longevity']}'),
                                      if (plantData['leafLitterQuality'] != null)
                                        Text(
                                          'Leaf Litter Quality: ${plantData['leafLitterQuality']}',
                                        ),
                                      if (plantData['localImagePath'] != null)
                                        Padding(
                                          padding: const EdgeInsets.only(top: 8.0),
                                          child: Image.file(
                                            File(plantData['localImagePath']),
                                            width: 80,
                                            height: 80,
                                            fit: BoxFit.cover,
                                          ),
                                        ),
                                    ],
                                  ),
                                  actions: [
                                    TextButton(
                                      onPressed: () => Navigator.pop(context),
                                      child: const Text('Close'),
                                    ),
                                  ],
                                ),
                              );
                            },
                            child: const Text('Details'),
                          ),
                          const SizedBox(width: 8),
                          ElevatedButton(
                            onPressed: () async {
                              if (!isSuperAdmin) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(
                                    content: Text('Only Super Admin can edit'),
                                    backgroundColor: Colors.red,
                                  ),
                                );
                                return;
                              }
                              final docId = plant.id;
                              final nameController = TextEditingController(
                                text: plantData['name'] ?? '',
                              );
                              final zoneController = TextEditingController(
                                text: plantData['zoneName'] ?? '',
                              );
                              final descriptionController = TextEditingController(
                                text: plantData['description'] ?? '',
                              );
                              final errorController = TextEditingController(
                                text: plantData['error'] ?? '',
                              );
                              final heightController = TextEditingController(
                                text: plantData['height']?.toString() ?? '',
                              );
                              final biomassController = TextEditingController(
                                text: plantData['biomass']?.toString() ?? '',
                              );
                              final slaController = TextEditingController(
                                text: plantData['specificLeafArea']?.toString() ?? '',
                              );
                              final longevityController = TextEditingController(
                                text: plantData['longevity']?.toString() ?? '',
                              );
                              final leafLitterController = TextEditingController(
                                text: plantData['leafLitterQuality'] ?? '',
                              );
                              XFile? pickedImage;

                              await showDialog(
                                context: context,
                                builder: (dialogContext) {
                                  return StatefulBuilder(
                                    builder: (context, setState) {
                                      return AlertDialog(
                                        title: Text('Edit Plant Details'),
                                        content: SingleChildScrollView(
                                          child: Column(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              TextField(
                                                controller: nameController,
                                                decoration: const InputDecoration(
                                                  labelText: 'Name',
                                                ),
                                              ),
                                              TextField(
                                                controller: zoneController,
                                                decoration: const InputDecoration(
                                                  labelText: 'Zone',
                                                ),
                                              ),
                                              TextField(
                                                controller: descriptionController,
                                                decoration: const InputDecoration(
                                                  labelText: 'Description',
                                                ),
                                              ),
                                              DropdownButtonFormField<String>(
                                                value: [
                                                  'Pest',
                                                  'Disease',
                                                  'Water Stress',
                                                  'Nutrient Deficiency',
                                                  'Physical Damage',
                                                  'Other',
                                                  'NA'
                                                ].contains(errorController.text)
                                                    ? errorController.text
                                                    : null,
                                                decoration: const InputDecoration(labelText: 'Issue'),
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
                                                  errorController.text = value ?? '';
                                                },
                                              ),
                                              TextField(
                                                controller: heightController,
                                                decoration: const InputDecoration(
                                                  labelText: 'Height',
                                                ),
                                              ),
                                              TextField(
                                                controller: biomassController,
                                                decoration: const InputDecoration(
                                                  labelText: 'Biomass',
                                                ),
                                              ),
                                              TextField(
                                                controller: slaController,
                                                decoration: const InputDecoration(
                                                  labelText: 'Specific Leaf Area',
                                                ),
                                              ),
                                              TextField(
                                                controller: longevityController,
                                                decoration: const InputDecoration(
                                                  labelText: 'Longevity',
                                                ),
                                              ),
                                              TextField(
                                                controller: leafLitterController,
                                                decoration: const InputDecoration(
                                                  labelText: 'Leaf Litter Quality',
                                                ),
                                              ),
                                              const SizedBox(height: 8),
                                              Column(
                                                crossAxisAlignment: CrossAxisAlignment.start,
                                                children: [
                                                  Row(
                                                    children: [
                                                      ElevatedButton(
                                                        onPressed: () async {
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
                                                        child: const Text('Pick Image'),
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
                                                          : (plantData['localImagePath'] != null
                                                              ? SizedBox(
                                                                  width: 80,
                                                                  height: 80,
                                                                  child: Image.file(
                                                                    File(plantData['localImagePath']),
                                                                    fit: BoxFit.cover,
                                                                  ),
                                                                )
                                                              : const Text('No image selected')),
                                                    ],
                                                  ),
                                                ],
                                              ),
                                              const SizedBox(height: 8),
                                              ElevatedButton(
                                                onPressed: () async {
                                                if (pickedImage == null) {
                                                  showDialog(
                                                    context: context,
                                                    builder: (context) => AlertDialog(
                                                      title: const Text('Upload Error'),
                                                      content: const Text('No image selected'),
                                                      actions: [
                                                        TextButton(
                                                          onPressed: () => Navigator.pop(context),
                                                          child: const Text('OK'),
                                                        ),
                                                      ],
                                                    ),
                                                  );
                                                  return;
                                                }
                                                try {
                                                  var request = http.MultipartRequest(
                                                    'POST',
                                                    Uri.parse(
                                                      'http://80.225.203.181:8081/api/images/upload',
                                                    ),
                                                  );
                                                  request.files.add(
                                                    await http.MultipartFile.fromPath(
                                                      'file',
                                                      pickedImage!.path,
                                                    ),
                                                  );
                                                  request.fields['userId'] =
                                                      nameController.text.isEmpty
                                                      ? 'unknown'
                                                      : nameController.text;
                                                  var response = await request.send();
                                                  if (response.statusCode == 200) {
                                                    final filename = pickedImage!.name;
                                                    final userId = nameController.text.isEmpty
                                                      ? 'unknown'
                                                      : nameController.text;
                                                    final imageUrl =
                                                      'http://80.225.203.181:8081/api/images/view?userId=$userId&filename=$filename';
                                                    showDialog(
                                                      context: context,
                                                      builder: (context) => AlertDialog(
                                                        title: const Text('Upload Successful'),
                                                        content: Text('Image uploaded! URL: $imageUrl'),
                                                        actions: [
                                                          TextButton(
                                                            onPressed: () => Navigator.pop(context),
                                                            child: const Text('OK'),
                                                          ),
                                                        ],
                                                      ),
                                                    );
                                                  } else {
                                                    showDialog(
                                                      context: context,
                                                      builder: (context) => AlertDialog(
                                                        title: const Text('Upload Failed'),
                                                        content: Text('Upload failed: ${response.statusCode}'),
                                                        actions: [
                                                          TextButton(
                                                            onPressed: () => Navigator.pop(context),
                                                            child: const Text('OK'),
                                                          ),
                                                        ],
                                                      ),
                                                    );
                                                  }
                                                } catch (e) {
                                                  showDialog(
                                                    context: context,
                                                    builder: (context) => AlertDialog(
                                                      title: const Text('Upload Error'),
                                                      content: Text('Error uploading image: $e'),
                                                      actions: [
                                                        TextButton(
                                                          onPressed: () => Navigator.pop(context),
                                                          child: const Text('OK'),
                                                        ),
                                                      ],
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
                                        ),
                                        actions: [
                                          TextButton(
                                            onPressed: () => Navigator.pop(dialogContext),
                                            child: const Text('Cancel'),
                                          ),
                                          ElevatedButton(
                                            onPressed: () async {
                                              Map<String, dynamic> updateData = {
                                                'name': nameController.text,
                                                'zoneName': zoneController.text,
                                                'description':
                                                    descriptionController.text,
                                                'error': errorController.text,
                                                'height': heightController.text,
                                                'biomass': biomassController.text,
                                                'specificLeafArea':
                                                    slaController.text,
                                                'longevity': longevityController.text,
                                                'leafLitterQuality':
                                                    leafLitterController.text,
                                              };
                                              if (pickedImage != null) {
                                                updateData['localImagePath'] =
                                                    pickedImage!.path;
                                              }
                                              print('DEBUG: Update data: $updateData');
                                              try {
                                                await FirebaseFirestore.instance
                                                    .collection('plantation_records')
                                                    .doc(docId)
                                                    .update(updateData);
                                                print('DEBUG: Firestore update successful');
                                                Navigator.of(dialogContext).pop(); // Close edit dialog
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
                        ],
                      ),
                    );
                  },
                );
              },
            ),
            // Other Tab (empty or for future use)
            Center(child: Text('Other tab content')),
          ],
        ),
      ),
    );
  }
}
