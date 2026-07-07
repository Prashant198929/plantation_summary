import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:plantation_summary/main.dart';
import 'package:plantation_summary/firebase_config.dart';
import 'package:image_picker/image_picker.dart';
import 'dart:io';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:path_provider/path_provider.dart';
import 'dart:async';
import 'upload_queue_service.dart';
import 'package:geolocator/geolocator.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'plant_type_service.dart';
import 'plant_search_field.dart';
import 'mobile_encryption_service.dart';

String _dateKey(DateTime dt) {
  return '${dt.year.toString().padLeft(4, '0')}${dt.month.toString().padLeft(2, '0')}${dt.day.toString().padLeft(2, '0')}';
}

String _safeDocId(String raw) {
  return raw.replaceAll(RegExp(r'[^\w\d]'), '_');
}

String _plantationDocId(String plantNumber, String zoneName) {
  final zoneNum = RegExp(r'(\d+)').firstMatch(zoneName)?.group(1) ?? zoneName;
  return '${zoneNum}_${plantNumber}';
}

String _historicalDocId(String originalDocId) {
  final invertedMs = 9999999999999 - DateTime.now().millisecondsSinceEpoch;
  return '${invertedMs}_${originalDocId}';
}

String _uploadUserId(String plantName, String plantNumber, String zoneId) {
  // Use zoneId (like "Zone 300") instead of zoneName (like "झोन 300")
  // This creates readable IDs like "Mango_1_Zone_300"
  final raw = '${plantName}_${plantNumber}_${zoneId}';
  final safe = _safeDocId(raw);
  return safe.isEmpty ? 'unknown' : safe;
}

Future<String?> _uploadToFirebaseStorage(File file, String docId, String ext) async {
  try {
    // One fixed path per plant — putFile overwrites, no duplicate images in Storage
    final ref = FirebaseStorage.instance.ref('images/$docId.$ext');
    await ref.putFile(file);
    return await ref.getDownloadURL();
  } catch (_) {
    return null;
  }
}

String _translateHealthStatus(String? status) {
  if (status == null || status.isEmpty) return '';
  
  final translations = {
    'pest': 'किडे',
    'Pest': 'किडे',
    'disease': 'रोग',
    'Disease': 'रोग',
    'infected': 'संक्रमित',
    'Infected': 'संक्रमित',
    'water stress': 'पाण्याचा ताण',
    'Water Stress': 'पाण्याचा ताण',
    'nutrient deficiency': 'पोषक तत्वांची कमतरता',
    'Nutrient Deficiency': 'पोषक तत्वांची कमतरता',
    'physical damage': 'शारीरिक नुकसान',
    'Physical Damage': 'शारीरिक नुकसान',
    'other': 'इतर',
    'Other': 'इतर',
    'na': 'लागू नाही',
    'NA': 'लागू नाही',
    'N/A': 'लागू नाही',
  };
  
  return translations[status] ?? status;
}

Future<Position?> _getCurrentLocation(BuildContext context) async {
  try {
    // Check if location services are enabled
    bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('कृपया स्थान सेवा सक्षम करा')),
      );
      return null;
    }

    // Check location permissions
    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('स्थान परवानगी नाकारली')),
        );
        return null;
      }
    }
    
    if (permission == LocationPermission.deniedForever) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('स्थान परवानगी कायमस्वरूपी नाकारली. सेटिंग्जमध्ये जा.')),
      );
      return null;
    }

    // Get current position
    return await Geolocator.getCurrentPosition(
      desiredAccuracy: LocationAccuracy.high,
    );
  } catch (e) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('स्थान मिळवताना त्रुटी: $e')),
    );
    return null;
  }
}

// Helper widget to display plant images — Firebase Storage URL with local fallback
class PlantImage extends StatelessWidget {
  final String? imageUrl;
  final String? localImagePath;
  final double width;
  final double height;

  const PlantImage({
    Key? key,
    this.imageUrl,
    this.localImagePath,
    this.width = 80,
    this.height = 80,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    if (imageUrl != null && imageUrl!.isNotEmpty) {
      return CachedNetworkImage(
        imageUrl: imageUrl!,
        width: width,
        height: height,
        fit: BoxFit.cover,
        placeholder: (context, url) => SizedBox(
          width: width,
          height: height,
          child: Center(child: CircularProgressIndicator()),
        ),
        errorWidget: (context, url, error) {
          if (localImagePath != null && localImagePath!.isNotEmpty &&
              File(localImagePath!).existsSync()) {
            return Image.file(
              File(localImagePath!),
              width: width,
              height: height,
              fit: BoxFit.cover,
              errorBuilder: (context, error, stackTrace) => _buildPlaceholder(),
            );
          }
          return _buildPlaceholder();
        },
      );
    }

    if (localImagePath != null && localImagePath!.isNotEmpty &&
        File(localImagePath!).existsSync()) {
      return Image.file(
        File(localImagePath!),
        width: width,
        height: height,
        fit: BoxFit.cover,
        errorBuilder: (context, error, stackTrace) => _buildPlaceholder(),
      );
    }

    return _buildPlaceholder();
  }

  Widget _buildPlaceholder() {
    return Container(
      width: width,
      height: height,
      color: Colors.grey[300],
      child: Icon(
        Icons.image_not_supported,
        size: width / 2,
        color: Colors.grey[600],
      ),
    );
  }
}

class ZoneManagementPage extends StatefulWidget {
  const ZoneManagementPage({Key? key}) : super(key: key);

  @override
  State<ZoneManagementPage> createState() => _ZoneManagementPageState();
}

class _ZoneManagementPageState extends State<ZoneManagementPage> {
  final TextEditingController _zoneController = TextEditingController();
  String _searchQuery = '';
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    _zoneController.addListener(_onSearchChanged);
    Future.microtask(() async {
      await FirebaseConfig.logEvent(
        eventType: 'zone_management_opened',
        description: 'Zone management page opened',
        userId: loggedInMobile,
      );
    });
  }

  void _onSearchChanged() {
    if (_debounce?.isActive ?? false) _debounce!.cancel();
    _debounce = Timer(const Duration(milliseconds: 800), () {
      final newQuery = _zoneController.text.toLowerCase();
      if (newQuery != _searchQuery) {
        setState(() {
          _searchQuery = newQuery;
        });
      }
    });
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _zoneController.removeListener(_onSearchChanged);
    _zoneController.dispose();
    super.dispose();
  }

  Future<bool> _isSuperAdmin() async {
    if (loggedInMobile == null) return false;
    final query = await FirebaseFirestore.instance
        .collection('users')
        .where('mobile', isEqualTo: MobileEncryptionService.encrypt(loggedInMobile!) ?? loggedInMobile)
        .limit(1)
        .get();
    if (query.docs.isNotEmpty) {
      final data = query.docs.first.data();
      final role = data['role']?.toString().toLowerCase();
      if (role == 'super_admin' || role == 'superadmin' || role == 'admin') {
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
    );
    if (!await _isSuperAdmin()) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('फक्त सुपर प्रशासक झोन जोडू शकतात.')),
      );
      return;
    }
    
    // Show dialog to enter zone number
    final TextEditingController zoneNumberController = TextEditingController();
    final zoneNumber = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('नवीन झोन जोडा'),
        content: TextField(
          controller: zoneNumberController,
          keyboardType: TextInputType.number,
          decoration: InputDecoration(
            labelText: 'झोन क्रमांक प्रविष्ट करा',
            hintText: 'उदा: 32',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, null),
            child: Text('रद्द करा'),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.pop(context, zoneNumberController.text.trim());
            },
            child: Text('जतन करा'),
          ),
        ],
      ),
    );
    
    if (zoneNumber != null && zoneNumber.isNotEmpty) {
      // Validate: must be a number
      if (int.tryParse(zoneNumber) == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('कृपया फक्त क्रमांक प्रविष्ट करा (उदा: 88)'),
            backgroundColor: Colors.red,
          ),
        );
        return;
      }

      // Check if zone already exists — doc ID is the plain number
      final existing = await FirebaseFirestore.instance
          .collection('zones')
          .doc(zoneNumber)
          .get();

      if (existing.exists) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('झोन $zoneNumber आधीच अस्तित्वात आहे.'),
            backgroundColor: Colors.red,
            duration: Duration(seconds: 3),
          ),
        );
        return;
      }

      final zoneName = 'झोन $zoneNumber';

      await FirebaseFirestore.instance
          .collection('zones')
          .doc(zoneNumber)           // document ID = plain number e.g. "88"
          .set({
            'name': zoneName,
            'zoneNumber': zoneNumber,
            'createdAt': FieldValue.serverTimestamp(),
          });

      await FirebaseConfig.logEvent(
        eventType: 'zone_added',
        description: 'New zone added',
        userId: loggedInMobile,
        isImportant: true,
        details: {'zoneName': zoneName, 'zoneNumber': zoneNumber},
      );

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('झोन "$zoneName" यशस्वीरित्या जोडले गेले'),
          backgroundColor: Colors.green,
        ),
      );
    }
  }

  Future<void> _runMigration(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('रोप नाव सुधारणा'),
        content: const Text(
          'हे सर्व plantation_records आणि HistoricalData मधील रोपांची नावे मराठीत सुधारेल.\n\nचालू ठेवायचे का?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('रद्द करा'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('सुरू करा'),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => const AlertDialog(
        content: Row(
          children: [
            CircularProgressIndicator(),
            SizedBox(width: 16),
            Text('सुधारणा चालू आहे...'),
          ],
        ),
      ),
    );

    try {
      final result = await PlantTypeService.migrateExistingRecords();
      if (context.mounted) Navigator.of(context).pop();
      if (context.mounted) {
        showDialog(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('सुधारणा पूर्ण'),
            content: Text(
              '✓ जुळले: ${result['matched']} नोंदी\n'
              '⚠ आढावा आवश्यक: ${result['unmatched']} नोंदी\n\n'
              '${(result['unmatched'] ?? 0) > 0 ? 'Firebase Console → plantation_records → plantTypeId == "__review__" फिल्टर करा.' : 'सर्व नोंदी यशस्वीरित्या सुधारल्या!'}',
            ),
            actions: [
              ElevatedButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('ठीक आहे'),
              ),
            ],
          ),
        );
      }
    } catch (e) {
      if (context.mounted) Navigator.of(context).pop();
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('सुधारणा अयशस्वी: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<QuerySnapshot>(
      future: loggedInMobile == null
          ? null
          : FirebaseFirestore.instance
                .collection('users')
                .where('mobile', isEqualTo: MobileEncryptionService.encrypt(loggedInMobile!) ?? loggedInMobile)
                .limit(1)
                .get(),
      builder: (context, userSnapshot) {
        if (userSnapshot.connectionState == ConnectionState.waiting) {
        return Scaffold(
          appBar: AppBar(title: Text('रोप व्यवस्थापन')),
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
        final isSuperAdmin = userRole == 'super_admin' || userRole == 'superadmin';
        final isAdmin = userRole == 'admin';
        final isZonalAdmin = userRole == 'zonal_admin';
        final hasAccess = isSuperAdmin || isAdmin || isZonalAdmin;
        // admin sees all zones; zonal_admin sees only their zone
        final showAllZones = isSuperAdmin || isAdmin;

        if (!hasAccess) {
          return Scaffold(
            appBar: AppBar(title: Text('रोप व्यवस्थापन')),
            body: Center(
              child: Text('या पृष्ठात प्रवेश अधिकृत नाही.'),
            ),
          );
        }

        return Scaffold(
          appBar: AppBar(
            title: Text('रोप व्यवस्थापन'),
            actions: [
              if (isSuperAdmin)
                IconButton(
                  icon: const Icon(Icons.sync),
                  tooltip: 'रोप नाव सुधारणा (Migration)',
                  onPressed: () => _runMigration(context),
                ),
            ],
          ),
          body: Column(
            children: [
              if (showAllZones)
                Padding(
                  padding: const EdgeInsets.all(12.0),
                  child: Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _zoneController,
                          decoration: InputDecoration(
                            labelText: 'झोन शोधा',
                            hintText: 'झोन क्रमांक टाइप करा...',
                            suffixIcon: _searchQuery.isNotEmpty
                                ? IconButton(
                                    icon: Icon(Icons.clear),
                                    onPressed: () {
                                      _zoneController.clear();
                                    },
                                  )
                                : null,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      ElevatedButton(
                        onPressed: _addZone,
                        child: Text('झोन जोडा'),
                      ),
                    ],
                  ),
                ),
              Expanded(
                child: _ZoneListWidget(
                  searchQuery: _searchQuery,
                  isSuperAdmin: showAllZones,
                  userZone: userZone,
                  onZoneUpdated: () => setState(() {}),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _ZoneListWidget extends StatelessWidget {
  final String searchQuery;
  final bool isSuperAdmin;
  final String? userZone;
  final VoidCallback onZoneUpdated;

  const _ZoneListWidget({
    required this.searchQuery,
    required this.isSuperAdmin,
    required this.userZone,
    required this.onZoneUpdated,
  });

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<QuerySnapshot>(
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
        final allZones = snapshot.data!.docs;
        
        // Filter zones based on search query
        final zones = allZones.where((zone) {
          final zoneName = (zone['name'] ?? '').toString().toLowerCase();
          return searchQuery.isEmpty || zoneName.contains(searchQuery);
        }).toList();
        
        if (zones.isEmpty && searchQuery.isNotEmpty) {
          return Center(
            child: Text('No zones found matching "$searchQuery"'),
          );
        }
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
                        data['healthStatus'] != 'NA' &&
                        data['healthStatus'] != 'लागू नाही';
                  });
                  highlightZone = plants.isNotEmpty;
                }
                return Card(
                  color: highlightZone ? Colors.red[50] : Colors.white,
                  child: ListTile(
                    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                    leading: const CircleAvatar(
                      backgroundColor: Color(0xFF2E7D32),
                    ),
                    title: Text(
                      zoneName,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    subtitle: highlightZone
                        ? const Text(
                            '⚠ काही रोपे लक्ष देण्याची गरज',
                            style: TextStyle(color: Colors.red, fontSize: 12),
                          )
                        : null,
                    trailing: const Icon(Icons.chevron_right, color: Color(0xFF2E7D32)),
                    onTap: () async {
                      await FirebaseConfig.logEvent(
                        eventType: 'zone_details_opened',
                        description: 'Zone details opened',
                        userId: loggedInMobile,
                        details: {'zoneId': zoneId, 'zoneName': zoneName},
                      );
                      if (!isSuperAdmin &&
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
                      onZoneUpdated();
                    },
                  ),
                );
              },
            );
          },
        );
      },
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

  final TextEditingController _searchController = TextEditingController();
  final ValueNotifier<String> _searchQuery = ValueNotifier<String>('');

  @override
  void dispose() {
    _searchController.dispose();
    _searchQuery.dispose();
    super.dispose();
  }

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
        .where('mobile', isEqualTo: MobileEncryptionService.encrypt(loggedInMobile!) ?? loggedInMobile)
        .limit(1)
        .get();
    bool isSuper = false;
    if (query.docs.isNotEmpty) {
      final data = query.docs.first.data();
      final role = data['role']?.toString().toLowerCase();
      if (role == 'super_admin' || role == 'superadmin' ||
          role == 'admin' || role == 'zonal_admin') {
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

  Future<void> _showEditPlantDialog(String plantId, Map<String, dynamic> plantData) async {
    final plantTypes = await PlantTypeService.fetchAll();
    if (!mounted) return;
    PlantType? selectedPlant = PlantTypeService.resolveFromCache(plantData['plantName'] ?? '');
    final nameController = TextEditingController(text: selectedPlant?.nameMarathi ?? plantData['plantName'] ?? '');
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
    final scaffoldContext = context;

    showDialog(
      context: scaffoldContext,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (dialogContext, setState) {
            return AlertDialog(
              title: Text('रोप संपादित करा'),
              content: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    PlantSearchField(
                      plantTypes: plantTypes,
                      onSelected: (p) {
                        selectedPlant = p;
                        nameController.text = p.nameMarathi;
                      },
                      decoration: const InputDecoration(
                        labelText: 'रोपाचे नाव',
                        border: OutlineInputBorder(),
                        hintText: 'मराठी / English मध्ये शोधा',
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: descController,
                      decoration: InputDecoration(
                        labelText: 'रोप क्रमांक',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 12),
                    DropdownButtonFormField<String>(
                      value: [
                        'किडे',
                        'रोग',
                        'संक्रमित',
                        'पाण्याचा ताण',
                        'पोषक तत्वांची कमतरता',
                        'शारीरिक नुकसान',
                        'इतर',
                        'लागू नाही'
                      ].contains(errorController.text)
                          ? errorController.text
                          : null,
                      decoration: InputDecoration(
                        labelText: 'आरोग्य स्थिती',
                        border: OutlineInputBorder(),
                      ),
                      items: [
                        'किडे',
                        'रोग',
                        'संक्रमित',
                        'पाण्याचा ताण',
                        'पोषक तत्वांची कमतरता',
                        'शारीरिक नुकसान',
                        'इतर',
                        'लागू नाही'
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
                        labelText: 'उंची',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: girthController,
                      decoration: InputDecoration(
                        labelText: 'परिघ',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: stumpController,
                      decoration: InputDecoration(
                        labelText: 'बुंधा',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: longitudeController,
                            decoration: InputDecoration(
                              labelText: 'रेखांश',
                              border: OutlineInputBorder(),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: TextField(
                            controller: latitudeController,
                            decoration: InputDecoration(
                              labelText: 'अक्षांश',
                              border: OutlineInputBorder(),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        IconButton(
                          onPressed: () async {
                            Position? position = await _getCurrentLocation(context);
                            if (position != null) {
                              setState(() {
                                longitudeController.text = position.longitude.toString();
                                latitudeController.text = position.latitude.toString();
                              });
                            }
                          },
                          icon: Icon(Icons.my_location),
                          color: Colors.blue,
                          tooltip: 'सध्याचे स्थान मिळवा',
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: plantedOnController,
                      decoration: InputDecoration(
                        labelText: 'लागवड केली',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: biomassController,
                      decoration: InputDecoration(
                        labelText: 'जैवभार',
                        border: OutlineInputBorder(),
                        floatingLabelBehavior: FloatingLabelBehavior.auto,
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: slaController,
                      decoration: InputDecoration(
                        labelText: 'विशिष्ट पान क्षेत्र',
                        border: OutlineInputBorder(),
                        floatingLabelBehavior: FloatingLabelBehavior.auto,
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: longevityController,
                      decoration: InputDecoration(
                        labelText: 'दीर्घायुष्य',
                        border: OutlineInputBorder(),
                        floatingLabelBehavior: FloatingLabelBehavior.auto,
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: leafLitterQualityController,
                      decoration: InputDecoration(
                        labelText: 'पानांच्या कचऱ्याची गुणवत्ता',
                        border: OutlineInputBorder(),
                        floatingLabelBehavior: FloatingLabelBehavior.auto,
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
                            labelText: 'झोन',
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
                                  eventType: 'plant_edit_pick_image',
                                  description: 'Plant edit pick image (gallery)',
                                  userId: loggedInMobile,
                                  details: {'plantId': plantId},
                                );
                                final ImagePicker picker = ImagePicker();
                                final XFile? image = await picker.pickImage(
                                  source: ImageSource.gallery,
                                  maxWidth: 1024,
                                  maxHeight: 1024,
                                  imageQuality: 85,
                                );
                                if (image != null) {
                                  try {
                                    final appDocDir = await getApplicationDocumentsDirectory();
                                    final stableDir = Directory('${appDocDir.path}/temp_picks');
                                    if (!await stableDir.exists()) await stableDir.create(recursive: true);
                                    final ext = image.name.contains('.') ? image.name.split('.').last : 'jpg';
                                    final stablePath = '${stableDir.path}/pending_image.$ext';
                                    final bytes = await image.readAsBytes();
                                    await File(stablePath).writeAsBytes(bytes);
                                    setState(() { pickedImage = XFile(stablePath); });
                                  } catch (_) {
                                    setState(() { pickedImage = image; });
                                  }
                                }
                              },
                            ),
                            IconButton(
                              tooltip: 'Camera',
                              icon: const Icon(Icons.camera_alt, color: Colors.orange),
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
                                  maxWidth: 1024,
                                  maxHeight: 1024,
                                  imageQuality: 85,
                                );
                                if (image != null) {
                                  try {
                                    final appDocDir = await getApplicationDocumentsDirectory();
                                    final stableDir = Directory('${appDocDir.path}/temp_picks');
                                    if (!await stableDir.exists()) await stableDir.create(recursive: true);
                                    final ext = image.name.contains('.') ? image.name.split('.').last : 'jpg';
                                    final stablePath = '${stableDir.path}/pending_image.$ext';
                                    final bytes = await image.readAsBytes();
                                    await File(stablePath).writeAsBytes(bytes);
                                    setState(() { pickedImage = XFile(stablePath); });
                                  } catch (_) {
                                    setState(() { pickedImage = image; });
                                  }
                                }
                              },
                            ),
                            pickedImage != null
                                ? SizedBox(
                                    width: 80,
                                    height: 80,
                                    child: Image.file(
                                      File(pickedImage!.path),
                                      fit: BoxFit.cover,
                                    ),
                                  )
                                : (((plantData['imageUrl'] as String?)?.isNotEmpty ?? false) ||
                                        (plantData['localImagePath'] != null &&
                                            File(plantData['localImagePath']).existsSync())
                                    ? PlantImage(
                                        imageUrl: plantData['imageUrl'],
                                        localImagePath: plantData['localImagePath'],
                                        width: 80,
                                        height: 80,
                                      )
                                    : const Text('फोटो निवडला नाही')),
                          ],
                        ),
                        const SizedBox(height: 8),
                        if (pickedImage != null)
                          const Text(
                            'जतन केल्यावर फोटो अपलोड होईल',
                            style: TextStyle(fontSize: 12, color: Colors.grey),
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
                    if (dialogContext.mounted) Navigator.pop(dialogContext);
                  },
                  child: const Text('रद्द करा'),
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
                      if (dialogContext.mounted) Navigator.pop(dialogContext);
                      Future.microtask(() => ScaffoldMessenger.of(scaffoldContext).showSnackBar(
                        SnackBar(content: Text('फक्त सुपर अॅडमिन रोप संपादित करू शकतो.')),
                      ));
                      return;
                    }

                    final name = nameController.text.trim();
                    if (name.isEmpty) {
                      if (dialogContext.mounted) Navigator.pop(dialogContext);
                      Future.microtask(() => ScaffoldMessenger.of(scaffoldContext).showSnackBar(
                        SnackBar(content: Text('रोपाचे नाव आवश्यक आहे.')),
                      ));
                      return;
                    }

                    String? localImagePath = plantData['localImagePath'];
                    String? newImageUrl;

                    if (pickedImage != null) {
                      // Copy to permanent local storage
                      final file = File(pickedImage!.path);
                      final appDocDir = await getApplicationDocumentsDirectory();
                      final localDir = Directory('${appDocDir.path}/images');
                      if (!await localDir.exists()) {
                        await localDir.create(recursive: true);
                      }
                      final localExt = pickedImage!.name.contains('.') ? pickedImage!.name.split('.').last : 'jpg';
                      final safeDocId = plantId.replaceAll(':', '-');
                      final localFilePath = '${localDir.path}/$safeDocId.$localExt';
                      await file.copy(localFilePath);
                      localImagePath = localFilePath;

                      newImageUrl = await _uploadToFirebaseStorage(
                        File(localFilePath),
                        plantId,
                        localExt,
                      );
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
                          _historicalDocId(plantId);
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

                      final updatedFields = {
                        'plantName': selectedPlant?.nameMarathi ?? name,
                        'plantTypeId': selectedPlant?.id,
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
                        'zoneId': plantData['zoneId'],
                        'zoneName': zoneName,
                        'Planted_On': plantedOnController.text.trim().isEmpty
                            ? DateTime.now().toIso8601String()
                            : plantedOnController.text.trim(),
                        'localImagePath': localImagePath,
                        if (newImageUrl != null) 'imageUrl': newImageUrl,
                      };

                      final currentZoneName =
                          (originalData['zoneName'] ?? widget.zoneName).toString();
                      final zoneNum =
                          RegExp(r'(\d+)').firstMatch(currentZoneName)?.group(1) ?? currentZoneName;
                      final newDocId =
                          '${zoneNum}_${descController.text.trim()}';

                      if (newDocId != plantId) {
                        final currentDoc = await FirebaseFirestore.instance
                            .collection('plantation_records')
                            .doc(plantId)
                            .get();
                        if (currentDoc.exists) {
                          final mergedData = Map<String, dynamic>.from(
                              currentDoc.data() as Map<String, dynamic>);
                          mergedData.addAll(updatedFields);
                          await FirebaseFirestore.instance
                              .collection('plantation_records')
                              .doc(newDocId)
                              .set(mergedData);
                          await FirebaseFirestore.instance
                              .collection('plantation_records')
                              .doc(plantId)
                              .delete();
                        }
                      } else {
                        await FirebaseFirestore.instance
                            .collection('plantation_records')
                            .doc(plantId)
                            .update(updatedFields);
                      }
                      
                      if (dialogContext.mounted) Navigator.pop(dialogContext);
                      Future.microtask(() {
                        ScaffoldMessenger.of(scaffoldContext).showSnackBar(
                          SnackBar(
                            content: Text('रोप यशस्वीरित्या अद्यतनित केले!'),
                            backgroundColor: Colors.green,
                          ),
                        );
                      });
                    } catch (e) {
                      if (dialogContext.mounted) Navigator.pop(dialogContext);
                      Future.microtask(() => ScaffoldMessenger.of(scaffoldContext).showSnackBar(
                        SnackBar(
                          content: Text('रोप अद्यतनित करताना त्रुटी: $e'),
                          backgroundColor: Colors.red,
                        ),
                      ));
                    }
                  },
                  child: const Text('बदल जतन करा'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Future<void> _showAddPlantDialog() async {
    final plantTypes = await PlantTypeService.fetchAll();
    if (!mounted) return;
    PlantType? selectedPlant;
    final nameController = TextEditingController();
    final descController = TextEditingController();
    final errorController = TextEditingController(text: 'लागू नाही');
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
    final scaffoldContext = context;

    showDialog(
      context: scaffoldContext,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (dialogContext, setState) {
            return AlertDialog(
              title: Text('नवीन रोप जोडा'),
              content: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    PlantSearchField(
                      plantTypes: plantTypes,
                      initialValue: nameController.text,
                      onSelected: (p) {
                        selectedPlant = p;
                        nameController.text = p.nameMarathi;
                      },
                      decoration: const InputDecoration(
                        labelText: 'रोपाचे नाव',
                        border: OutlineInputBorder(),
                        hintText: 'मराठी / English मध्ये शोधा',
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: descController,
                      decoration: InputDecoration(
                        labelText: 'रोप क्रमांक',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 12),
                    DropdownButtonFormField<String>(
                        value: [
                          'किडे',
                          'रोग',
                          'संक्रमित',
                          'पाण्याचा ताण',
                          'पोषक तत्वांची कमतरता',
                          'शारीरिक नुकसान',
                          'इतर',
                          'लागू नाही'
                        ].contains(errorController.text)
                          ? errorController.text
                          : null,
                      decoration: InputDecoration(
                        labelText: 'आरोग्य स्थिती',
                        border: OutlineInputBorder(),
                      ),
                        items: [
                          'किडे',
                          'रोग',
                          'संक्रमित',
                          'पाण्याचा ताण',
                          'पोषक तत्वांची कमतरता',
                          'शारीरिक नुकसान',
                          'इतर',
                          'लागू नाही'
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
                        labelText: 'उंची',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: girthController,
                      decoration: InputDecoration(
                        labelText: 'परिघ',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: stumpController,
                      decoration: InputDecoration(
                        labelText: 'बुंधा',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: longitudeController,
                            decoration: InputDecoration(
                              labelText: 'रेखांश',
                              border: OutlineInputBorder(),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: TextField(
                            controller: latitudeController,
                            decoration: InputDecoration(
                              labelText: 'अक्षांश',
                              border: OutlineInputBorder(),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        IconButton(
                          onPressed: () async {
                            Position? position = await _getCurrentLocation(context);
                            if (position != null) {
                              setState(() {
                                longitudeController.text = position.longitude.toString();
                                latitudeController.text = position.latitude.toString();
                              });
                            }
                          },
                          icon: const Icon(Icons.my_location),
                          color: Colors.blue,
                          tooltip: 'सध्याचे स्थान मिळवा',
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: biomassController,
                      decoration: InputDecoration(
                        labelText: 'जैवभार',
                        border: OutlineInputBorder(),
                        floatingLabelBehavior: FloatingLabelBehavior.auto,
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: slaController,
                      decoration: InputDecoration(
                        labelText: 'विशिष्ट पान क्षेत्र',
                        border: OutlineInputBorder(),
                        floatingLabelBehavior: FloatingLabelBehavior.auto,
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: longevityController,
                      decoration: InputDecoration(
                        labelText: 'दीर्घायुष्य',
                        border: OutlineInputBorder(),
                        floatingLabelBehavior: FloatingLabelBehavior.auto,
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: leafLitterQualityController,
                      decoration: InputDecoration(
                        labelText: 'पानांच्या कचऱ्याची गुणवत्ता',
                        border: OutlineInputBorder(),
                        floatingLabelBehavior: FloatingLabelBehavior.auto,
                      ),
                    ),
                    const SizedBox(height: 12),
                    // Image picker field
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
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
                                  eventType: 'plant_add_pick_image',
                                  description: 'Plant add pick image (gallery)',
                                  userId: loggedInMobile,
                                );
                                final ImagePicker picker = ImagePicker();
                                final XFile? image = await picker.pickImage(
                                  source: ImageSource.gallery,
                                  maxWidth: 1024,
                                  maxHeight: 1024,
                                  imageQuality: 85,
                                );
                                if (image != null) {
                                  try {
                                    final appDocDir = await getApplicationDocumentsDirectory();
                                    final stableDir = Directory('${appDocDir.path}/temp_picks');
                                    if (!await stableDir.exists()) await stableDir.create(recursive: true);
                                    final ext = image.name.contains('.') ? image.name.split('.').last : 'jpg';
                                    final stablePath = '${stableDir.path}/pending_image.$ext';
                                    final bytes = await image.readAsBytes();
                                    await File(stablePath).writeAsBytes(bytes);
                                    setState(() { pickedImage = XFile(stablePath); });
                                  } catch (_) {
                                    setState(() { pickedImage = image; });
                                  }
                                }
                              },
                            ),
                            IconButton(
                              tooltip: 'Camera',
                              icon: const Icon(Icons.camera_alt, color: Colors.orange),
                              onPressed: () async {
                                await FirebaseConfig.logEvent(
                                  eventType: 'plant_add_pick_image',
                                  description: 'Plant add pick image (camera)',
                                  userId: loggedInMobile,
                                );
                                final ImagePicker picker = ImagePicker();
                                final XFile? image = await picker.pickImage(
                                  source: ImageSource.camera,
                                  maxWidth: 1024,
                                  maxHeight: 1024,
                                  imageQuality: 85,
                                );
                                if (image != null) {
                                  try {
                                    final appDocDir = await getApplicationDocumentsDirectory();
                                    final stableDir = Directory('${appDocDir.path}/temp_picks');
                                    if (!await stableDir.exists()) await stableDir.create(recursive: true);
                                    final ext = image.name.contains('.') ? image.name.split('.').last : 'jpg';
                                    final stablePath = '${stableDir.path}/pending_image.$ext';
                                    final bytes = await image.readAsBytes();
                                    await File(stablePath).writeAsBytes(bytes);
                                    setState(() { pickedImage = XFile(stablePath); });
                                  } catch (_) {
                                    setState(() { pickedImage = image; });
                                  }
                                }
                              },
                            ),
                            pickedImage != null
                                ? SizedBox(
                                    width: 80,
                                    height: 80,
                                    child: Image.file(
                                      File(pickedImage!.path),
                                      fit: BoxFit.cover,
                                    ),
                                  )
                                : const Text('फोटो निवडला नाही'),
                          ],
                        ),
                        const SizedBox(height: 8),
                        if (pickedImage != null)
                          const Text(
                            'जतन केल्यावर फोटो अपलोड होईल',
                            style: TextStyle(fontSize: 12, color: Colors.grey),
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
                    if (dialogContext.mounted) Navigator.pop(dialogContext);
                  },
                  child: const Text('रद्द करा'),
                ),
                ElevatedButton(
                  onPressed: () async {
                    await FirebaseConfig.logEvent(
                      eventType: 'plant_add_confirmed',
                      description: 'Plant add confirmed',
                      userId: loggedInMobile,
                    );
                    if (!_isSuperAdmin) {
                      if (dialogContext.mounted) Navigator.pop(dialogContext);
                      Future.microtask(() => ScaffoldMessenger.of(scaffoldContext).showSnackBar(
                        SnackBar(content: Text('फक्त सुपर अॅडमिन रोप जोडू शकतो.')),
                      ));
                      return;
                    }

                    final name = nameController.text.trim();
                    if (name.isEmpty) {
                      if (dialogContext.mounted) Navigator.pop(dialogContext);
                      Future.microtask(() => ScaffoldMessenger.of(scaffoldContext).showSnackBar(
                        SnackBar(content: Text('रोपाचे नाव आवश्यक आहे.')),
                      ));
                      return;
                    }

                    final plantNumber = descController.text.trim();
                    if (plantNumber.isEmpty) {
                      if (dialogContext.mounted) Navigator.pop(dialogContext);
                      Future.microtask(() => ScaffoldMessenger.of(scaffoldContext).showSnackBar(
                        SnackBar(content: Text('रोप क्रमांक आवश्यक आहे.')),
                      ));
                      return;
                    }

                    // Check if plant number already exists in this zone
                    final existingPlants = await FirebaseFirestore.instance
                        .collection('plantation_records')
                        .where('zoneId', isEqualTo: widget.zoneId)
                        .where('plantNumber', isEqualTo: plantNumber)
                        .get();

                    if (existingPlants.docs.isNotEmpty) {
                      final existingDoc = existingPlants.docs.first;
                      final existingData = existingDoc.data() as Map<String, dynamic>;
                      final existingPlantName = existingData['plantName'] ?? 'अज्ञात रोप';

                      final confirm = await showDialog<bool>(
                        context: dialogContext,
                        builder: (ctx) => AlertDialog(
                          title: const Text('रोप बदला'),
                          content: Text(
                            'झोनमध्ये क्रमांक "$plantNumber" वर आधीच "$existingPlantName" आहे.\n\n'
                            'जुन्या रोपाची सर्व माहिती इतिहासात जतन होईल आणि नवीन रोप लावले जाईल.\n\n'
                            'पुढे जायचे का?',
                          ),
                          actions: [
                            TextButton(
                              onPressed: () => Navigator.pop(ctx, false),
                              child: const Text('रद्द करा'),
                            ),
                            ElevatedButton(
                              onPressed: () => Navigator.pop(ctx, true),
                              style: ElevatedButton.styleFrom(backgroundColor: Colors.orange),
                              child: const Text('जुने रोप हटवा व नवीन लावा'),
                            ),
                          ],
                        ),
                      );

                      if (confirm != true) return;

                      // Save old plant to HistoricalData
                      final oldData = Map<String, dynamic>.from(existingData);
                      oldData['originalId'] = existingDoc.id;
                      oldData['replacedAt'] = DateTime.now().toIso8601String();
                      oldData['replacedByUser'] = loggedInMobile;
                      oldData['historyReason'] = 'plant_replaced';

                      await FirebaseFirestore.instance
                          .collection('HistoricalData')
                          .doc(_historicalDocId(existingDoc.id))
                          .set(oldData);

                      // Remove old plant record
                      await FirebaseFirestore.instance
                          .collection('plantation_records')
                          .doc(existingDoc.id)
                          .delete();
                    }

                    // Generate doc ID once — format: plantNumber_zoneNumber_isoTimestamp
                    final docId = _plantationDocId(plantNumber, widget.zoneName);
                    String? localImagePath;
                    String? newImageUrl;

                    if (pickedImage != null) {
                      final file = File(pickedImage!.path);
                      final appDocDir = await getApplicationDocumentsDirectory();
                      final localDir = Directory('${appDocDir.path}/images');
                      if (!await localDir.exists()) {
                        await localDir.create(recursive: true);
                      }
                      final localExt = pickedImage!.name.contains('.') ? pickedImage!.name.split('.').last : 'jpg';
                      final safeDocId = docId.replaceAll(':', '-');
                      final localFilePath = '${localDir.path}/$safeDocId.$localExt';
                      await file.copy(localFilePath);
                      localImagePath = localFilePath;

                      newImageUrl = await _uploadToFirebaseStorage(
                        File(localFilePath),
                        docId,
                        localExt,
                      );
                      if (newImageUrl == null) {
                        final uploadItem = UploadItem(
                          id: DateTime.now().millisecondsSinceEpoch.toString(),
                          imagePath: localFilePath,
                          filename: localExt,
                          userId: docId,
                          docId: docId,
                          createdAt: DateTime.now(),
                        );
                        await UploadQueueService.addToQueue(uploadItem);
                      }
                    }

                    try {
                      await FirebaseFirestore.instance
                          .collection('plantation_records')
                          .doc(docId)
                          .set({
                            'plantName': selectedPlant?.nameMarathi ?? name,
                            'plantTypeId': selectedPlant?.id,
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
                            if (newImageUrl != null) 'imageUrl': newImageUrl,
                          });
                      
                      if (dialogContext.mounted) Navigator.pop(dialogContext);
                      Future.microtask(() => ScaffoldMessenger.of(scaffoldContext).showSnackBar(
                        SnackBar(
                          content: Text('रोप यशस्वीरित्या जोडले!'),
                          backgroundColor: Colors.green,
                        ),
                      ));
                    } catch (e) {
                      if (dialogContext.mounted) Navigator.pop(dialogContext);
                      Future.microtask(() => ScaffoldMessenger.of(scaffoldContext).showSnackBar(
                        SnackBar(
                          content: Text('रोप जोडताना त्रुटी: $e'),
                          backgroundColor: Colors.red,
                        ),
                      ));
                    }
                  },
                  child: const Text('रोप जोडा'),
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
        appBar: AppBar(title: Text(widget.zoneName)),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    return Scaffold(
      appBar: AppBar(title: Text(widget.zoneName)),
      floatingActionButton: _isSuperAdmin
          ? FloatingActionButton.extended(
              onPressed: () async {
                await FirebaseConfig.logEvent(
                  eventType: 'add_plant_dialog_opened',
                  description: 'Add plant dialog opened',
                  userId: loggedInMobile,
                  details: {'zoneId': widget.zoneId, 'zoneName': widget.zoneName},
                );
                _showAddPlantDialog();
              },
              backgroundColor: const Color(0xFF2E7D32),
              icon: const Icon(Icons.add),
              label: const Text('रोप जोडा'),
            )
          : null,
      body: StreamBuilder<QuerySnapshot>(
        stream: FirebaseFirestore.instance
            .collection('plantation_records')
            .where('zoneId', isEqualTo: widget.zoneId)
            .snapshots(),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          if (!snapshot.hasData || snapshot.data!.docs.isEmpty) {
            return const Center(
              child: Text('या झोनमध्ये अद्याप कोणतेही रोप नाही.'),
            );
          }

          final allPlants = snapshot.data!.docs
              .where((doc) => doc['zoneId'] == widget.zoneId)
              .toList()
            ..sort((a, b) {
              final aTime = (a.data() as Map)['timestamp'] ?? '';
              final bTime = (b.data() as Map)['timestamp'] ?? '';
              return bTime.compareTo(aTime);
            });

          if (allPlants.isEmpty) {
            return const Center(
              child: Text('या झोनमध्ये अद्याप कोणतेही रोप नाही.'),
            );
          }

          return ValueListenableBuilder<String>(
            valueListenable: _searchQuery,
            builder: (context, searchQuery, _) {
              final plants = searchQuery.isEmpty
                  ? allPlants
                  : allPlants.where((p) {
                      final d = p.data() as Map<String, dynamic>;
                      final q = searchQuery.toLowerCase();
                      return (d['plantName'] ?? '').toString().toLowerCase().contains(q) ||
                          (d['plantNumber'] ?? '').toString().toLowerCase().contains(q);
                    }).toList();

              return Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 12, 12, 6),
                    child: TextField(
                      controller: _searchController,
                      onChanged: (val) => _searchQuery.value = val.trim(),
                      decoration: InputDecoration(
                        hintText: 'रोपाचे नाव किंवा क्रमांक शोधा...',
                        prefixIcon: const Icon(Icons.search),
                        suffixIcon: searchQuery.isNotEmpty
                            ? IconButton(
                                icon: const Icon(Icons.clear),
                                onPressed: () {
                                  _searchController.clear();
                                  _searchQuery.value = '';
                                },
                              )
                            : null,
                      ),
                    ),
                  ),
                  if (searchQuery.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          '${plants.length} निकाल',
                          style: TextStyle(color: Colors.grey[600], fontSize: 13),
                        ),
                      ),
                    ),
                  Expanded(
                    child: plants.isEmpty
                        ? Center(
                            child: Text(
                              '"$searchQuery" साठी कोणतेही निकाल नाहीत',
                            ),
                          )
                        : ListView.builder(
                            padding: const EdgeInsets.only(bottom: 80),
                            itemCount: plants.length,
                            itemBuilder: (context, index) {
                              final plant = plants[index];
                              final plantData = plant.data() as Map<String, dynamic>;
                              final bool hasHealthIssue =
                                  plantData['healthStatus'] != null &&
                                  plantData['healthStatus'] != '' &&
                                  plantData['healthStatus'] != 'NA' &&
                                  plantData['healthStatus'] != 'लागू नाही';

                              return Card(
                                color: hasHealthIssue ? Colors.red[50] : Colors.white,
                                child: InkWell(
                                  borderRadius: BorderRadius.circular(12),
                                  onTap: () async {
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
                                      builder: (ctx) => AlertDialog(
                                        title: Text(plantData['plantName'] ?? 'रोप तपशील'),
                                        content: SingleChildScrollView(
                                          child: Column(
                                            crossAxisAlignment: CrossAxisAlignment.start,
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              if (plantData['imageUrl'] != null || plantData['localImagePath'] != null)
                                                Center(
                                                  child: ClipRRect(
                                                    borderRadius: BorderRadius.circular(8),
                                                    child: PlantImage(
                                                      imageUrl: plantData['imageUrl'],
                                                      localImagePath: plantData['localImagePath'],
                                                      width: 120,
                                                      height: 120,
                                                    ),
                                                  ),
                                                ),
                                              const SizedBox(height: 12),
                                              _detailRow('रोप क्रमांक', plantData['plantNumber']),
                                              _detailRow('लागवड केली', plantData['Planted_On']),
                                              if (hasHealthIssue)
                                                _detailRow('आरोग्य स्थिती', _translateHealthStatus(plantData['healthStatus']), isAlert: true),
                                              _detailRow('उंची', plantData['height']),
                                              _detailRow('परिघ', plantData['girth']),
                                              _detailRow('बुंधा', plantData['stump']),
                                              _detailRow('रेखांश', plantData['longitude']),
                                              _detailRow('अक्षांश', plantData['latitude']),
                                              _detailRow('जैवभार', plantData['biomass']),
                                              _detailRow('विशिष्ट पान क्षेत्र', plantData['specificLeafArea']),
                                              _detailRow('दीर्घायुष्य', plantData['longevity']),
                                              _detailRow('पानांच्या कचऱ्याची गुणवत्ता', plantData['leafLitterQuality']),
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
                                                details: {'plantId': plant.id},
                                              );
                                              Navigator.pop(ctx);
                                            },
                                            child: const Text('बंद करा'),
                                          ),
                                        ],
                                      ),
                                    );
                                  },
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                                    child: Row(
                                      children: [
                                        ClipRRect(
                                          borderRadius: BorderRadius.circular(8),
                                          child: PlantImage(
                                            imageUrl: plantData['imageUrl'],
                                            localImagePath: plantData['localImagePath'],
                                            width: 60,
                                            height: 60,
                                          ),
                                        ),
                                        const SizedBox(width: 12),
                                        Expanded(
                                          child: Column(
                                            crossAxisAlignment: CrossAxisAlignment.start,
                                            children: [
                                              Text(
                                                plantData['plantName'] ?? '',
                                                style: const TextStyle(
                                                  fontWeight: FontWeight.w600,
                                                  fontSize: 15,
                                                ),
                                              ),
                                              const SizedBox(height: 3),
                                              Text(
                                                'क्र. ${plantData['plantNumber'] ?? ''}',
                                                style: TextStyle(
                                                  color: Colors.grey[600],
                                                  fontSize: 13,
                                                ),
                                              ),
                                              if (hasHealthIssue) ...[
                                                const SizedBox(height: 4),
                                                Container(
                                                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                                                  decoration: BoxDecoration(
                                                    color: Colors.red[100],
                                                    borderRadius: BorderRadius.circular(4),
                                                  ),
                                                  child: Text(
                                                    _translateHealthStatus(plantData['healthStatus']),
                                                    style: TextStyle(
                                                      color: Colors.red[800],
                                                      fontSize: 11,
                                                      fontWeight: FontWeight.w500,
                                                    ),
                                                  ),
                                                ),
                                              ],
                                            ],
                                          ),
                                        ),
                                        IconButton(
                                          icon: const Icon(Icons.edit_outlined),
                                          color: const Color(0xFF2E7D32),
                                          onPressed: () async {
                                            await FirebaseConfig.logEvent(
                                              eventType: 'plant_edit_clicked',
                                              description: 'Plant edit clicked',
                                              userId: loggedInMobile,
                                              details: {
                                                'zoneId': widget.zoneId,
                                                'plantId': plant.id,
                                              },
                                            );
                                            _showEditPlantDialog(plant.id, plantData);
                                          },
                                        ),
                                        IconButton(
                                          icon: const Icon(Icons.delete_outline),
                                          color: Colors.red[400],
                                          onPressed: () async {
                                            await FirebaseConfig.logEvent(
                                              eventType: 'plant_delete_clicked',
                                              description: 'Plant delete clicked',
                                              userId: loggedInMobile,
                                              details: {
                                                'zoneId': widget.zoneId,
                                                'plantId': plant.id,
                                              },
                                            );
                                            final confirm = await showDialog<bool>(
                                              context: context,
                                              builder: (ctx) => AlertDialog(
                                                title: const Text('रोप हटवा'),
                                                content: Text(
                                                  '"${plantData['plantName'] ?? 'हे रोप'}" हटवायचे आहे का?\n\nमाहिती इतिहासात जतन होईल.',
                                                ),
                                                actions: [
                                                  TextButton(
                                                    onPressed: () => Navigator.pop(ctx, false),
                                                    child: const Text('रद्द करा'),
                                                  ),
                                                  TextButton(
                                                    onPressed: () => Navigator.pop(ctx, true),
                                                    child: Text(
                                                      'हटवा',
                                                      style: TextStyle(color: Colors.red[700]),
                                                    ),
                                                  ),
                                                ],
                                              ),
                                            );
                                            if (confirm == true) {
                                              final historicalData = Map<String, dynamic>.from(plantData);
                                              historicalData['originalId'] = plant.id;
                                              historicalData['deletedAt'] = DateTime.now().toIso8601String();
                                              historicalData['historyReason'] = 'plant_deleted';
                                              await FirebaseFirestore.instance
                                                  .collection('HistoricalData')
                                                  .doc(_historicalDocId(plant.id))
                                                  .set(historicalData);
                                              await FirebaseFirestore.instance
                                                  .collection('plantation_records')
                                                  .doc(plant.id)
                                                  .delete();
                                            }
                                          },
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              );
                            },
                          ),
                  ),
                ],
              );
            },
          );
        },
      ),
    );
  }
}

Widget _detailRow(String label, dynamic value, {bool isAlert = false}) {
  if (value == null || value.toString().isEmpty) return const SizedBox.shrink();
  return Padding(
    padding: const EdgeInsets.only(bottom: 4),
    child: RichText(
      text: TextSpan(
        style: const TextStyle(fontSize: 14, color: Colors.black87),
        children: [
          TextSpan(text: '$label: ', style: const TextStyle(fontWeight: FontWeight.w600)),
          TextSpan(
            text: value.toString(),
            style: TextStyle(color: isAlert ? Colors.red[800] : Colors.black87),
          ),
        ],
      ),
    ),
  );
}
