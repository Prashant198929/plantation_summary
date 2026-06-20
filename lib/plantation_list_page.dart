import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:image_picker/image_picker.dart';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:plantation_summary/main.dart';
import 'dart:async';
import 'firebase_config.dart';

String _safeUploadUserId(String plantName, String plantNumber, String zoneName) {
  final raw = '${plantName}_${plantNumber}_${zoneName}';
  final safe = raw.replaceAll(RegExp(r'[^\w\d]'), '_');
  return safe.isEmpty ? 'unknown' : safe;
}

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
    Future.microtask(() async {
      await FirebaseConfig.logEvent(
        eventType: 'plantation_list_opened',
        description: 'Plantation list page opened',
        userId: loggedInMobile,
      );
    });
  }

  Future<void> _fetchUserZone() async {
    if (loggedInMobile == null) {
      if (!mounted) {
        return;
      }
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
    if (!mounted) {
      return;
    }
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
    if (!isSuperAdmin) {
      return Scaffold(
        appBar: AppBar(title: const Text('Plantation Records')),
        body: const Center(
          child: Text('Only super admin can access Plantation Records.'),
        ),
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
            onTap: (index) async {
              const tabs = ['All Records', 'Other'];
              await FirebaseConfig.logEvent(
                eventType: 'plantation_tab_clicked',
                description: 'Plantation tab clicked',
                userId: loggedInMobile,
                details: {'tab': tabs[index]},
              );
            },
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
                      tileColor:
                          plantData['healthStatus'] != null &&
                              plantData['healthStatus'] != 'NA'
                          ? Colors.red[100]
                          : null,
                      title: Row(
                        children: [
                          Expanded(
                            child: Text(
                              '${plantData['plantName'] ?? ''} (${plantData['zoneName'] ?? ''})',
                            ),
                          ),
                          ElevatedButton(
                            onPressed: () async {
                              await FirebaseConfig.logEvent(
                                eventType: 'plantation_viewed',
                                description: 'Plantation record viewed',
                                details: {
                                  'docId': plant.id,
                                  'plantName': plantData['plantName'],
                                  'zone': plantData['zoneName'],
                                },
                              );
                              showDialog(
                                context: context,
                                builder: (context) => AlertDialog(
                                  title: Text(
                                    plantData['plantName'] ?? 'Plant Details',
                                  ),
                                  content: SingleChildScrollView(
                                    child: Column(
                                      mainAxisSize: MainAxisSize.min,
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        if (plantData['plantNumber'] != null)
                                          Text(
                                            'Plant Number: ${plantData['plantNumber']}',
                                            style: TextStyle(
                                              color: Colors.black87,
                                              fontWeight: FontWeight.w500,
                                            ),
                                          ),
                                        if (plantData['Planted_On'] != null)
                                          Text(
                                            'Planted On: ${plantData['Planted_On']}',
                                            style: TextStyle(
                                              color: Colors.black87,
                                              fontWeight: FontWeight.w500,
                                            ),
                                          ),
                                        if (plantData['healthStatus'] != null)
                                          Text(
                                            'Health Status: ${plantData['healthStatus']}',
                                            style: TextStyle(
                                              color: Colors.red[800],
                                              fontWeight: FontWeight.w600,
                                            ),
                                          ),
                                        if (plantData['height'] != null)
                                          Text(
                                            'Height: ${plantData['height']}',
                                            style: TextStyle(
                                              color: Colors.black87,
                                            ),
                                          ),
                                        if (plantData['girth'] != null)
                                          Text(
                                            'Girth: ${plantData['girth']}',
                                            style: TextStyle(
                                              color: Colors.black87,
                                            ),
                                          ),
                                        if (plantData['stump'] != null)
                                          Text(
                                            'Stump: ${plantData['stump']}',
                                            style: TextStyle(
                                              color: Colors.black87,
                                            ),
                                          ),
                                        if (plantData['longitude'] != null)
                                          Text(
                                            'Longitude: ${plantData['longitude']}',
                                            style: TextStyle(
                                              color: Colors.black87,
                                            ),
                                          ),
                                        if (plantData['latitude'] != null)
                                          Text(
                                            'Latitude: ${plantData['latitude']}',
                                            style: TextStyle(
                                              color: Colors.black87,
                                            ),
                                          ),
                                        if (plantData['biomass'] != null)
                                          Text(
                                            'Biomass: ${plantData['biomass']}',
                                            style: TextStyle(
                                              color: Colors.black87,
                                            ),
                                          ),
                                        if (plantData['specificLeafArea'] !=
                                            null)
                                          Text(
                                            'Specific Leaf Area: ${plantData['specificLeafArea']}',
                                            style: TextStyle(
                                              color: Colors.black87,
                                            ),
                                          ),
                                        if (plantData['longevity'] != null)
                                          Text(
                                            'Longevity: ${plantData['longevity']}',
                                            style: TextStyle(
                                              color: Colors.black87,
                                            ),
                                          ),
                                        if (plantData['leafLitterQuality'] !=
                                            null)
                                          Text(
                                            'Leaf Litter Quality: ${plantData['leafLitterQuality']}',
                                            style: TextStyle(
                                              color: Colors.black87,
                                            ),
                                          ),
                                        if (plantData['localImagePath'] != null && File(plantData['localImagePath']).existsSync())
                                          Padding(
                                            padding: const EdgeInsets.only(
                                              top: 8.0,
                                            ),
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
                                          eventType: 'plantation_details_closed',
                                          description: 'Plantation details closed',
                                          userId: loggedInMobile,
                                          details: {'docId': plant.id},
                                        );
                                        Navigator.pop(context);
                                      },
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
                              await FirebaseConfig.logEvent(
                                eventType: 'plantation_edit_clicked',
                                description: 'Plantation edit clicked',
                                userId: loggedInMobile,
                                details: {
                                  'docId': plant.id,
                                  'plantName': plantData['plantName'],
                                  'zone': plantData['zoneName'],
                                },
                              );
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
                                text: plantData['plantName'] ?? '',
                              );
                              final zoneController = TextEditingController(
                                text: plantData['zoneName'] ?? '',
                              );
                              String? selectedZoneId = plantData['zoneId'];
                              final descriptionController =
                                  TextEditingController(
                                    text: plantData['plantNumber'] ?? '',
                                  );
                              final errorController = TextEditingController(
                                text: plantData['healthStatus'] ?? '',
                              );
                              final heightController = TextEditingController(
                                text: plantData['height']?.toString() ?? '',
                              );
                              final girthController = TextEditingController(
                                text: plantData['girth']?.toString() ?? '',
                              );
                              final stumpController = TextEditingController(
                                text: plantData['stump']?.toString() ?? '',
                              );
                              final longitudeController = TextEditingController(
                                text: plantData['longitude']?.toString() ?? '',
                              );
                              final latitudeController = TextEditingController(
                                text: plantData['latitude']?.toString() ?? '',
                              );
                              final plantedOnController = TextEditingController(
                                text: plantData['Planted_On'] ?? '',
                              );
                              final biomassController = TextEditingController(
                                text: plantData['biomass']?.toString() ?? '',
                              );
                              final slaController = TextEditingController(
                                text:
                                    plantData['specificLeafArea']?.toString() ??
                                    '',
                              );
                              final longevityController = TextEditingController(
                                text: plantData['longevity']?.toString() ?? '',
                              );
                              final leafLitterController =
                                  TextEditingController(
                                    text: plantData['leafLitterQuality'] ?? '',
                                  );
                              final originalData =
                                  Map<String, dynamic>.from(plantData);
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
                                              const SizedBox(height: 16),
                                              TextField(
                                                controller: nameController,
                                                decoration: InputDecoration(
                                                  labelText: 'Plant Name',
                                                  fillColor: Color(0xFFE8F5E9),
                                                  filled: true,
                                                  labelStyle: TextStyle(color: Colors.black87),
                                                  enabledBorder: OutlineInputBorder(
                                                    borderSide: BorderSide(color: Color(0xFFFFB300), width: 1.5),
                                                    borderRadius: BorderRadius.circular(8),
                                                  ),
                                                  focusedBorder: OutlineInputBorder(
                                                    borderSide: BorderSide(color: Color(0xFF388E3C), width: 2),
                                                    borderRadius: BorderRadius.circular(8),
                                                  ),
                                                  contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 22),
                                                ),
                                              ),
                                              const SizedBox(height: 16),
                                              FutureBuilder<QuerySnapshot>(
                                                future: FirebaseFirestore.instance.collection('zones').get(),
                                                builder: (context, zoneSnapshot) {
                                                  if (!zoneSnapshot.hasData) {
                                                    return CircularProgressIndicator();
                                                  }
                                                  final zones = zoneSnapshot.data!.docs;
                                                  return DropdownButtonFormField<String>(
                                                    value: selectedZoneId,
                                                    decoration: InputDecoration(
                                                      labelText: 'Zone',
                                                      fillColor: Color(0xFFE8F5E9),
                                                      filled: true,
                                                      labelStyle: TextStyle(
                                                        color: Colors.black87,
                                                      ),
                                                      enabledBorder:
                                                          OutlineInputBorder(
                                                            borderSide: BorderSide(
                                                              color: Color(
                                                                0xFFFFB300,
                                                              ),
                                                              width: 1.5,
                                                            ),
                                                            borderRadius:
                                                                BorderRadius.circular(
                                                                  8,
                                                                ),
                                                          ),
                                                      focusedBorder:
                                                          OutlineInputBorder(
                                                            borderSide: BorderSide(
                                                              color: Color(
                                                                0xFF388E3C,
                                                              ),
                                                              width: 2,
                                                            ),
                                                            borderRadius:
                                                                BorderRadius.circular(
                                                                  8,
                                                                ),
                                                          ),
                                                    ),
                                                    items: zones.map((zone) {
                                                      return DropdownMenuItem<String>(
                                                        value: zone.id,
                                                        child: Text(zone['name']),
                                                      );
                                                    }).toList(),
                                                    onChanged: (value) {
                                                      setState(() {
                                                        selectedZoneId = value;
                                                        zoneController.text = zones.firstWhere((z) => z.id == value)['name'];
                                                      });
                                                    },
                                                  );
                                                },
                                              ),
                                              const SizedBox(height: 16),
                                              TextField(
                                                controller:
                                                    descriptionController,
                                                decoration: InputDecoration(
                                                  labelText: 'Plant Number',
                                                  fillColor: Color(0xFFE8F5E9),
                                                  filled: true,
                                                  labelStyle: TextStyle(
                                                    color: Colors.black87,
                                                  ),
                                                  enabledBorder:
                                                      OutlineInputBorder(
                                                        borderSide: BorderSide(
                                                          color: Color(
                                                            0xFFFFB300,
                                                          ),
                                                          width: 1.5,
                                                        ),
                                                        borderRadius:
                                                            BorderRadius.circular(
                                                              8,
                                                            ),
                                                      ),
                                                  focusedBorder:
                                                      OutlineInputBorder(
                                                        borderSide: BorderSide(
                                                          color: Color(
                                                            0xFF388E3C,
                                                          ),
                                                          width: 2,
                                                        ),
                                                        borderRadius:
                                                            BorderRadius.circular(
                                                              8,
                                                            ),
                                                      ),
                                                ),
                                              ),
                                              const SizedBox(height: 16),
                                              DropdownButtonFormField<String>(
                                                value:
                                                    [
                                                      'Pest',
                                                      'Disease',
                                                      'Infected',
                                                      'Water Stress',
                                                      'Nutrient Deficiency',
                                                      'Physical Damage',
                                                      'Other',
                                                      'NA',
                                                    ].contains(
                                                      errorController.text,
                                                    )
                                                    ? errorController.text
                                                    : null,
                                                decoration: InputDecoration(
                                                  labelText: 'Health Status',
                                                  fillColor: Color(0xFFE8F5E9),
                                                  filled: true,
                                                  labelStyle: TextStyle(color: Colors.black87),
                                                  enabledBorder: OutlineInputBorder(
                                                    borderSide: BorderSide(color: Color(0xFFFFB300), width: 1.5),
                                                    borderRadius: BorderRadius.circular(8),
                                                  ),
                                                  focusedBorder: OutlineInputBorder(
                                                    borderSide: BorderSide(color: Color(0xFF388E3C), width: 2),
                                                    borderRadius: BorderRadius.circular(8),
                                                  ),
                                                  contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 16),
                                                ),
                                                items:
                                                    [
                                                          'Pest',
                                                          'Disease',
                                                          'Infected',
                                                          'Water Stress',
                                                          'Nutrient Deficiency',
                                                          'Physical Damage',
                                                          'Other',
                                                          'NA',
                                                        ]
                                                        .map(
                                                          (issue) =>
                                                              DropdownMenuItem(
                                                                value: issue,
                                                                child: Text(
                                                                  issue,
                                                                ),
                                                              ),
                                                        )
                                                        .toList(),
                                                onChanged: (value) {
                                                  errorController.text =
                                                      value ?? '';
                                                },
                                              ),
                                              const SizedBox(height: 16),
                                              TextField(
                                                controller: heightController,
                                                decoration: InputDecoration(
                                                  labelText: 'Height',
                                                  fillColor: Color(0xFFE8F5E9),
                                                  filled: true,
                                                  labelStyle: TextStyle(
                                                    color: Colors.black87,
                                                  ),
                                                  enabledBorder:
                                                      OutlineInputBorder(
                                                        borderSide: BorderSide(
                                                          color: Color(
                                                            0xFFFFB300,
                                                          ),
                                                          width: 1.5,
                                                        ),
                                                        borderRadius:
                                                            BorderRadius.circular(
                                                              8,
                                                            ),
                                                      ),
                                                  focusedBorder:
                                                      OutlineInputBorder(
                                                        borderSide: BorderSide(
                                                          color: Color(
                                                            0xFF388E3C,
                                                          ),
                                                          width: 2,
                                                        ),
                                                        borderRadius:
                                                            BorderRadius.circular(
                                                              8,
                                                            ),
                                                      ),
                                                ),
                                              ),
                                              const SizedBox(height: 16),
                                              TextField(
                                                controller: girthController,
                                                decoration: InputDecoration(
                                                  labelText: 'Girth',
                                                  fillColor: Color(0xFFE8F5E9),
                                                  filled: true,
                                                  labelStyle: TextStyle(
                                                    color: Colors.black87,
                                                  ),
                                                  enabledBorder:
                                                      OutlineInputBorder(
                                                        borderSide: BorderSide(
                                                          color: Color(
                                                            0xFFFFB300,
                                                          ),
                                                          width: 1.5,
                                                        ),
                                                        borderRadius:
                                                            BorderRadius.circular(
                                                              8,
                                                            ),
                                                      ),
                                                  focusedBorder:
                                                      OutlineInputBorder(
                                                        borderSide: BorderSide(
                                                          color: Color(
                                                            0xFF388E3C,
                                                          ),
                                                          width: 2,
                                                        ),
                                                        borderRadius:
                                                            BorderRadius.circular(
                                                              8,
                                                            ),
                                                      ),
                                                ),
                                              ),
                                              const SizedBox(height: 16),
                                              TextField(
                                                controller: stumpController,
                                                decoration: InputDecoration(
                                                  labelText: 'Stump',
                                                  fillColor: Color(0xFFE8F5E9),
                                                  filled: true,
                                                  labelStyle: TextStyle(
                                                    color: Colors.black87,
                                                  ),
                                                  enabledBorder:
                                                      OutlineInputBorder(
                                                        borderSide: BorderSide(
                                                          color: Color(
                                                            0xFFFFB300,
                                                          ),
                                                          width: 1.5,
                                                        ),
                                                        borderRadius:
                                                            BorderRadius.circular(
                                                              8,
                                                            ),
                                                      ),
                                                  focusedBorder:
                                                      OutlineInputBorder(
                                                        borderSide: BorderSide(
                                                          color: Color(
                                                            0xFF388E3C,
                                                          ),
                                                          width: 2,
                                                        ),
                                                        borderRadius:
                                                            BorderRadius.circular(
                                                              8,
                                                            ),
                                                      ),
                                                ),
                                              ),
                                              const SizedBox(height: 16),
                                              TextField(
                                                controller: longitudeController,
                                                decoration: InputDecoration(
                                                  labelText: 'Longitude',
                                                  fillColor: Color(0xFFE8F5E9),
                                                  filled: true,
                                                  labelStyle: TextStyle(
                                                    color: Colors.black87,
                                                  ),
                                                  enabledBorder:
                                                      OutlineInputBorder(
                                                        borderSide: BorderSide(
                                                          color: Color(
                                                            0xFFFFB300,
                                                          ),
                                                          width: 1.5,
                                                        ),
                                                        borderRadius:
                                                            BorderRadius.circular(
                                                              8,
                                                            ),
                                                      ),
                                                  focusedBorder:
                                                      OutlineInputBorder(
                                                        borderSide: BorderSide(
                                                          color: Color(
                                                            0xFF388E3C,
                                                          ),
                                                          width: 2,
                                                        ),
                                                        borderRadius:
                                                            BorderRadius.circular(
                                                              8,
                                                            ),
                                                      ),
                                                ),
                                              ),
                                              const SizedBox(height: 16),
                                              TextField(
                                                controller: latitudeController,
                                                decoration: InputDecoration(
                                                  labelText: 'Latitude',
                                                  fillColor: Color(0xFFE8F5E9),
                                                  filled: true,
                                                  labelStyle: TextStyle(
                                                    color: Colors.black87,
                                                  ),
                                                  enabledBorder:
                                                      OutlineInputBorder(
                                                        borderSide: BorderSide(
                                                          color: Color(
                                                            0xFFFFB300,
                                                          ),
                                                          width: 1.5,
                                                        ),
                                                        borderRadius:
                                                            BorderRadius.circular(
                                                              8,
                                                            ),
                                                      ),
                                                  focusedBorder:
                                                      OutlineInputBorder(
                                                        borderSide: BorderSide(
                                                          color: Color(
                                                            0xFF388E3C,
                                                          ),
                                                          width: 2,
                                                        ),
                                                        borderRadius:
                                                            BorderRadius.circular(
                                                              8,
                                                            ),
                                                      ),
                                                ),
                                              ),
                                              const SizedBox(height: 16),
                                              TextField(
                                                controller: plantedOnController,
                                                decoration: InputDecoration(
                                                  labelText: 'Planted On',
                                                  fillColor: Color(0xFFE8F5E9),
                                                  filled: true,
                                                  labelStyle: TextStyle(
                                                    color: Colors.black87,
                                                  ),
                                                  enabledBorder:
                                                      OutlineInputBorder(
                                                        borderSide: BorderSide(
                                                          color: Color(
                                                            0xFFFFB300,
                                                          ),
                                                          width: 1.5,
                                                        ),
                                                        borderRadius:
                                                            BorderRadius.circular(
                                                              8,
                                                            ),
                                                      ),
                                                  focusedBorder:
                                                      OutlineInputBorder(
                                                        borderSide: BorderSide(
                                                          color: Color(
                                                            0xFF388E3C,
                                                          ),
                                                          width: 2,
                                                        ),
                                                        borderRadius:
                                                            BorderRadius.circular(
                                                              8,
                                                            ),
                                                      ),
                                                ),
                                              ),
                                              const SizedBox(height: 16),
                                              TextField(
                                                controller: biomassController,
                                                decoration: InputDecoration(
                                                  labelText: 'Biomass',
                                                  fillColor: Color(0xFFE8F5E9),
                                                  filled: true,
                                                  labelStyle: TextStyle(
                                                    color: Colors.black87,
                                                  ),
                                                  enabledBorder:
                                                      OutlineInputBorder(
                                                        borderSide: BorderSide(
                                                          color: Color(
                                                            0xFFFFB300,
                                                          ),
                                                          width: 1.5,
                                                        ),
                                                        borderRadius:
                                                            BorderRadius.circular(
                                                              8,
                                                            ),
                                                      ),
                                                  focusedBorder:
                                                      OutlineInputBorder(
                                                        borderSide: BorderSide(
                                                          color: Color(
                                                            0xFF388E3C,
                                                          ),
                                                          width: 2,
                                                        ),
                                                        borderRadius:
                                                            BorderRadius.circular(
                                                              8,
                                                            ),
                                                      ),
                                                ),
                                              ),
                                              const SizedBox(height: 16),
                                              TextField(
                                                controller: slaController,
                                                decoration: InputDecoration(
                                                  labelText: 'Specific Leaf Area',
                                                  fillColor: Color(0xFFE8F5E9),
                                                  filled: true,
                                                  labelStyle: TextStyle(color: Colors.black87),
                                                  enabledBorder: OutlineInputBorder(
                                                    borderSide: BorderSide(color: Color(0xFFFFB300), width: 1.5),
                                                    borderRadius: BorderRadius.circular(8),
                                                  ),
                                                  focusedBorder: OutlineInputBorder(
                                                    borderSide: BorderSide(color: Color(0xFF388E3C), width: 2),
                                                    borderRadius: BorderRadius.circular(8),
                                                  ),
                                                  contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 16),
                                                ),
                                              ),
                                              const SizedBox(height: 16),
                                              TextField(
                                                controller: longevityController,
                                                decoration: InputDecoration(
                                                  labelText: 'Longevity',
                                                  fillColor: Color(0xFFE8F5E9),
                                                  filled: true,
                                                  labelStyle: TextStyle(
                                                    color: Colors.black87,
                                                  ),
                                                  enabledBorder:
                                                      OutlineInputBorder(
                                                        borderSide: BorderSide(
                                                          color: Color(
                                                            0xFFFFB300,
                                                          ),
                                                          width: 1.5,
                                                        ),
                                                        borderRadius:
                                                            BorderRadius.circular(
                                                              8,
                                                            ),
                                                      ),
                                                  focusedBorder:
                                                      OutlineInputBorder(
                                                        borderSide: BorderSide(
                                                          color: Color(
                                                            0xFF388E3C,
                                                          ),
                                                          width: 2,
                                                        ),
                                                        borderRadius:
                                                            BorderRadius.circular(
                                                              8,
                                                            ),
                                                      ),
                                                ),
                                              ),
                                              const SizedBox(height: 16),
                                              TextField(
                                                controller:
                                                    leafLitterController,
                                                decoration: InputDecoration(
                                                  labelText: 'Leaf Litter Quality',
                                                  fillColor: Color(0xFFE8F5E9),
                                                  filled: true,
                                                  labelStyle: TextStyle(color: Colors.black87),
                                                  enabledBorder: OutlineInputBorder(
                                                    borderSide: BorderSide(color: Color(0xFFFFB300), width: 1.5),
                                                    borderRadius: BorderRadius.circular(8),
                                                  ),
                                                  focusedBorder: OutlineInputBorder(
                                                    borderSide: BorderSide(color: Color(0xFF388E3C), width: 2),
                                                    borderRadius: BorderRadius.circular(8),
                                                  ),
                                                  contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 16),
                                                ),
                                              ),
                                              const SizedBox(height: 8),
                                              Column(
                                                crossAxisAlignment:
                                                    CrossAxisAlignment.start,
                                                children: [
                                                  Row(
                                                    children: [
                                                      ElevatedButton.icon(
                                                        onPressed: () async {
                                                          await FirebaseConfig.logEvent(
                                                            eventType: 'plantation_edit_pick_image',
                                                            description: 'Plantation edit pick image (gallery)',
                                                            userId: loggedInMobile,
                                                            details: {'docId': plant.id},
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
                                                            eventType: 'plantation_edit_pick_image',
                                                            description: 'Plantation edit pick image (camera)',
                                                            userId: loggedInMobile,
                                                            details: {'docId': plant.id},
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
                                                                File(
                                                                  pickedImage!
                                                                      .path,
                                                                ),
                                                                fit: BoxFit
                                                                    .cover,
                                                              ),
                                                            )
                                                          : (plantData['localImagePath'] != null &&
                                                                    File(plantData['localImagePath']).existsSync()
                                                                ? SizedBox(
                                                                    width: 80,
                                                                    height: 80,
                                                                    child: Image.file(
                                                                      File(
                                                                        plantData['localImagePath'],
                                                                      ),
                                                                      fit: BoxFit.cover,
                                                                      errorBuilder: (context, error, stackTrace) =>
                                                                          const Icon(Icons.broken_image, size: 80),
                                                                    ),
                                                                  )
                                                                : const Text(
                                                                    'No image selected',
                                                                  )),
                                                    ],
                                                  ),
                                                ],
                                              ),
                                              const SizedBox(height: 8),
                                              ElevatedButton(
                                                onPressed: () async {
                                                  await FirebaseConfig.logEvent(
                                                    eventType: 'plantation_edit_upload_clicked',
                                                    description: 'Plantation edit upload clicked',
                                                    userId: loggedInMobile,
                                                    details: {'docId': plant.id},
                                                  );
                                                  await FirebaseConfig.logEvent(
                                                    eventType: 'plantation_edit_upload_initiated',
                                                    description: 'Plantation edit upload initiated',
                                                    userId: loggedInMobile,
                                                    details: {'docId': plant.id},
                                                  );
                                                  if (pickedImage == null) {
                                                    showDialog(
                                                      context: context,
                                                      builder: (context) =>
                                                          AlertDialog(
                                                            title: const Text(
                                                              'Upload Error',
                                                            ),
                                                            content: const Text(
                                                              'No image selected',
                                                            ),
                                                            actions: [
                                                              TextButton(
                                                                onPressed: () =>
                                                                    Navigator.pop(
                                                                      context,
                                                                    ),
                                                                child:
                                                                    const Text(
                                                                      'OK',
                                                                    ),
                                                              ),
                                                            ],
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
                                                    final userId =
                                                        _safeUploadUserId(
                                                      nameController.text,
                                                      descriptionController.text,
                                                      zoneController.text,
                                                    );
                                                    request.fields['userId'] =
                                                        userId;
                                                    var response;
                                                    try {
                                                      response = await request.send().timeout(const Duration(seconds: 10));
                                                    } on TimeoutException catch (_) {
                                                      await FirebaseConfig.logEvent(
                                                        eventType: 'plantation_list_upload_timeout',
                                                        description: 'Plantation list upload timeout',
                                                        userId: loggedInMobile,
                                                        details: {
                                                          'docId': plant.id,
                                                          'error': 'Server timeout',
                                                        },
                                                      );
                                                      showDialog(
                                                        context: context,
                                                        builder: (context) => AlertDialog(
                                                          title: const Text(
                                                            'Upload Error',
                                                          ),
                                                          content: const Text(
                                                            'Error: Server not responding. Please try again later.',
                                                          ),
                                                          actions: [
                                                            TextButton(
                                                              onPressed: () => Navigator.pop(context),
                                                              child: const Text('OK'),
                                                            ),
                                                          ],
                                                        ),
                                                      );
                                                      return;
                                                    } catch (e) {
                                                      await FirebaseConfig.logEvent(
                                                        eventType: 'plantation_list_upload_error',
                                                        description: 'Plantation list upload error',
                                                        userId: loggedInMobile,
                                                        details: {
                                                          'docId': plant.id,
                                                          'error': e.toString(),
                                                        },
                                                      );
                                                      showDialog(
                                                        context: context,
                                                        builder: (context) => AlertDialog(
                                                          title: const Text(
                                                            'Upload Error',
                                                          ),
                                                          content: Text(
                                                            'Error uploading image: $e',
                                                          ),
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
                                                    if (response != null && response.statusCode == 200) {
                                                      final filename = pickedImage!.name;
                                                      final userId =
                                                          _safeUploadUserId(
                                                        nameController.text,
                                                        descriptionController.text,
                                                        zoneController.text,
                                                      );
                                                      final imageUrl =
                                                          'http://80.225.203.181:8081/api/images/view?userId=$userId&filename=$filename';
                                                      await FirebaseConfig.logEvent(
                                                        eventType: 'plantation_list_upload_success',
                                                        description: 'Plantation list image uploaded successfully',
                                                        userId: loggedInMobile,
                                                        details: {
                                                          'docId': plant.id,
                                                          'imageUrl': imageUrl,
                                                          'statusCode': response.statusCode,
                                                        },
                                                      );
                                                      showDialog(
                                                        context: context,
                                                        builder: (context) => AlertDialog(
                                                          title: const Text(
                                                            'Upload Successful',
                                                          ),
                                                          content: Text(
                                                            'Image uploaded! URL: $imageUrl',
                                                          ),
                                                          actions: [
                                                            TextButton(
                                                              onPressed: () => Navigator.pop(context),
                                                              child: const Text('OK'),
                                                            ),
                                                          ],
                                                        ),
                                                      );
                                                    } else if (response != null) {
                                                      await FirebaseConfig.logEvent(
                                                        eventType: 'plantation_list_upload_failed',
                                                        description: 'Plantation list image upload failed',
                                                        userId: loggedInMobile,
                                                        details: {
                                                          'docId': plant.id,
                                                          'statusCode': response.statusCode,
                                                          'error': 'HTTP ${response.statusCode}',
                                                        },
                                                      );
                                                      showDialog(
                                                        context: context,
                                                        builder: (context) => AlertDialog(
                                                          title: const Text(
                                                            'Upload Failed',
                                                          ),
                                                          content: Text(
                                                            'Upload failed: ${response.statusCode}',
                                                          ),
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
                                                    await FirebaseConfig.logEvent(
                                                      eventType: 'plantation_list_upload_exception',
                                                      description: 'Plantation list upload exception',
                                                      userId: loggedInMobile,
                                                      details: {
                                                        'docId': plant.id,
                                                        'error': e.toString(),
                                                      },
                                                    );
                                                    showDialog(
                                                      context: context,
                                                      builder: (context) =>
                                                          AlertDialog(
                                                            title: const Text(
                                                              'Upload Error',
                                                            ),
                                                            content: Text(
                                                              'Error uploading image: $e',
                                                            ),
                                                            actions: [
                                                              TextButton(
                                                                onPressed: () =>
                                                                    Navigator.pop(
                                                                      context,
                                                                    ),
                                                                child:
                                                                    const Text(
                                                                      'OK',
                                                                    ),
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
                                            onPressed: () async {
                                              await FirebaseConfig.logEvent(
                                                eventType: 'plantation_edit_cancelled',
                                                description: 'Plantation edit cancelled',
                                                userId: loggedInMobile,
                                                details: {'docId': docId},
                                              );
                                              Navigator.pop(dialogContext);
                                            },
                                            child: const Text('Cancel'),
                                          ),
                                          ElevatedButton(
                                            onPressed: () async {
                                              await FirebaseConfig.logEvent(
                                                eventType: 'plantation_edit_saved',
                                                description: 'Plantation edit saved',
                                                userId: loggedInMobile,
                                                details: {'docId': docId},
                                              );
                                              Map<String, dynamic>
                                              updateData = {
                                                'plantName': nameController.text,
                                                'zoneId': selectedZoneId,
                                                'zoneName': zoneController.text,
                                                'plantNumber':
                                                    descriptionController.text,
                                                'healthStatus':
                                                    errorController.text,
                                                'height': heightController.text,
                                                'girth': girthController.text,
                                                'stump': stumpController.text,
                                                'longitude': longitudeController.text,
                                                'latitude': latitudeController.text,
                                                'biomass':
                                                    biomassController.text,
                                                'specificLeafArea':
                                                    slaController.text,
                                                'longevity':
                                                    longevityController.text,
                                                'leafLitterQuality':
                                                    leafLitterController.text,
                                                'Planted_On':
                                                    plantedOnController.text
                                                            .trim()
                                                            .isEmpty
                                                        ? DateTime.now().toIso8601String()
                                                        : plantedOnController.text.trim(),
                                              };
                                              if (pickedImage != null) {
                                                updateData['localImagePath'] =
                                                    pickedImage!.path;
                                              }
                                              print(
                                                'DEBUG: Update data: $updateData',
                                              );
                                              try {
                                                final historicalData =
                                                    Map<String, dynamic>.from(originalData);
                                                historicalData['originalId'] =
                                                    docId;
                                                historicalData['editedAt'] =
                                                    DateTime.now().toIso8601String();
                                                final historyName =
                                                    (historicalData['plantName'] ?? '')
                                                        .toString();
                                                final historyZone =
                                                    (historicalData['zoneName'] ??
                                                            '')
                                                        .toString();
                                                final now = DateTime.now();
                                                final dateKey =
                                                    '${now.year.toString().padLeft(4, '0')}${now.month.toString().padLeft(2, '0')}${now.day.toString().padLeft(2, '0')}';
                                                final rawDocId =
                                                    '${dateKey}_${historyName}_${historyZone}';
                                                final historyDocId = rawDocId
                                                    .replaceAll(RegExp(r'[^\w\d]'), '_');
                                                await FirebaseFirestore.instance
                                                    .collection('HistoricalData')
                                                    .doc(historyDocId)
                                                    .set(historicalData);

                                                await FirebaseFirestore.instance
                                                    .collection(
                                                      'plantation_records',
                                                    )
                                                    .doc(docId)
                                                    .update(updateData);
                                                await FirebaseConfig.logEvent(
                                                  eventType: 'plantation_updated',
                                                  description: 'Plantation record updated from list',
                                                  details: {
                                                    'docId': docId,
                                                    'plantName': nameController.text,
                                                    'zone': zoneController.text,
                                                    'plantNumber': descriptionController.text,
                                                    'healthStatus': errorController.text,
                                                  },
                                                );
                                                print(
                                                  'DEBUG: Firestore update successful',
                                                );
                                                Navigator.of(
                                                  dialogContext,
                                                ).pop(); // Close edit dialog
                                                print('DEBUG: Dialog closed');
                                                Future.microtask(() {
                                                  print(
                                                    'DEBUG: Showing SnackBar',
                                                  );
                                                  ScaffoldMessenger.of(
                                                    context,
                                                  ).showSnackBar(
                                                    const SnackBar(
                                                      content: Text(
                                                        'Record updated successfully.',
                                                      ),
                                                      backgroundColor:
                                                          Colors.green,
                                                    ),
                                                  );
                                                });
                                              } catch (e) {
                                                print(
                                                  'DEBUG: Firestore update error: $e',
                                                );
                                                ScaffoldMessenger.of(
                                                  context,
                                                ).showSnackBar(
                                                  SnackBar(
                                                    content: Text(
                                                      'Error updating record: $e',
                                                    ),
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
