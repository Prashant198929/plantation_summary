import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:image_picker/image_picker.dart';
import 'dart:io';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:plantation_summary/main.dart';
import 'dart:async';
import 'firebase_config.dart';
import 'package:geolocator/geolocator.dart';
import 'package:path_provider/path_provider.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'plant_type_service.dart';
import 'plant_search_field.dart';
import 'mobile_encryption_service.dart';

String _safeUploadUserId(String plantName, String plantNumber, String zoneName) {
  final raw = '${plantName}_${plantNumber}_${zoneName}';
  final safe = raw.replaceAll(RegExp(r'[^\w\d]'), '_');
  return safe.isEmpty ? 'unknown' : safe;
}

String _translateHealthStatus(String? status) {
  if (status == null || status.isEmpty) return '';
  const translations = {
    'pest': 'किडे', 'Pest': 'किडे',
    'disease': 'रोग', 'Disease': 'रोग',
    'infected': 'संक्रमित', 'Infected': 'संक्रमित',
    'water stress': 'पाण्याचा ताण', 'Water Stress': 'पाण्याचा ताण',
    'nutrient deficiency': 'पोषक तत्वांची कमतरता',
    'Nutrient Deficiency': 'पोषक तत्वांची कमतरता',
    'physical damage': 'शारीरिक नुकसान', 'Physical Damage': 'शारीरिक नुकसान',
    'other': 'इतर', 'Other': 'इतर',
    'na': 'लागू नाही', 'NA': 'लागू नाही', 'N/A': 'लागू नाही',
  };
  return translations[status] ?? status;
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

class PlantationListPage extends StatefulWidget {
  const PlantationListPage({Key? key}) : super(key: key);

  @override
  State<PlantationListPage> createState() => _PlantationListPageState();
}

class _PlantationListPageState extends State<PlantationListPage> {
  String? userZone;
  String? userZoneId;
  bool isSuperAdmin = false;
  bool loading = true;

  final TextEditingController _searchController = TextEditingController();
  final ValueNotifier<String> _searchQuery = ValueNotifier<String>('');

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

  @override
  void dispose() {
    _searchController.dispose();
    _searchQuery.dispose();
    super.dispose();
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
        .where('mobile', isEqualTo: MobileEncryptionService.encrypt(loggedInMobile!) ?? loggedInMobile)
        .limit(1)
        .get();
    if (!mounted) {
      return;
    }
    if (query.docs.isNotEmpty) {
      final data = query.docs.first.data();
      final role = data['role']?.toString().toLowerCase();
      if (role == 'super_admin' || role == 'superadmin' || role == 'admin') {
        setState(() {
          isSuperAdmin = true;
          loading = false;
        });
      } else {
        final zoneName = data['zone'] as String?;
        String? zoneId;
        if (zoneName != null) {
          final zoneQuery = await FirebaseFirestore.instance
              .collection('zones')
              .where('name', isEqualTo: zoneName)
              .limit(1)
              .get();
          if (zoneQuery.docs.isNotEmpty) {
            zoneId = zoneQuery.docs.first.id;
          }
        }
        if (!mounted) return;
        setState(() {
          userZone = zoneName;
          userZoneId = zoneId;
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
        appBar: AppBar(title: const Text('लागवड नोंदी')),
        body: const Center(child: CircularProgressIndicator()),
      );
    }
    if (!isSuperAdmin && userZone == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('लागवड नोंदी')),
        body: const Center(
          child: Text('तुमचा झोन नाही. प्रशासकाशी संपर्क करा.'),
        ),
      );
    }
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('लागवड नोंदी'),
          bottom: TabBar(
            indicatorColor: Colors.white,
            tabs: [
              Tab(text: 'सर्व नोंदी'),
              Tab(text: 'इतर'),
            ],
            onTap: (index) async {
              const tabs = ['सर्व नोंदी', 'इतर'];
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
                  : userZoneId != null
                        ? FirebaseFirestore.instance
                              .collection('plantation_records')
                              .where('zoneId', isEqualTo: userZoneId)
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
                  return Center(child: Text('कोणत्याही लागवड नोंदी आढळल्या नाहीत.'));
                }
                final allPlants = snapshot.data!.docs;
                return ValueListenableBuilder<String>(
                  valueListenable: _searchQuery,
                  builder: (context, searchQuery, _) {
                    final plants = searchQuery.isEmpty
                        ? allPlants
                        : allPlants.where((p) {
                            final d = p.data() as Map<String, dynamic>;
                            final q = searchQuery.toLowerCase();
                            return (d['plantName'] ?? '').toString().toLowerCase().contains(q) ||
                                (d['plantNumber'] ?? '').toString().toLowerCase().contains(q) ||
                                (d['zoneName'] ?? '').toString().toLowerCase().contains(q);
                          }).toList();
                    return Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(12, 12, 12, 6),
                      child: TextField(
                        controller: _searchController,
                        onChanged: (val) => _searchQuery.value = val.trim(),
                        decoration: InputDecoration(
                          hintText: 'रोपाचे नाव, क्रमांक किंवा झोन शोधा...',
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
                                searchQuery.isNotEmpty
                                    ? '"$searchQuery" साठी कोणतेही निकाल नाहीत'
                                    : 'कोणत्याही लागवड नोंदी आढळल्या नाहीत.',
                              ),
                            )
                          : ListView.builder(
                              padding: const EdgeInsets.only(bottom: 16),
                              itemCount: plants.length,
                              itemBuilder: (context, index) {
                                final plant = plants[index];
                                final plantData = plant.data() as Map<String, dynamic>;
                                final bool hasHealthIssue =
                                    plantData['healthStatus'] != null &&
                                    plantData['healthStatus'] != '' &&
                                    plantData['healthStatus'] != 'NA' &&
                                    plantData['healthStatus'] != 'लागू नाही';
                                final zoneNum = (plantData['zoneName'] ?? '')
                                    .toString()
                                    .replaceAll(RegExp(r'[^\d]'), '');
                                return Card(
                                  color: hasHealthIssue ? Colors.red[50] : Colors.white,
                                  child: InkWell(
                                    borderRadius: BorderRadius.circular(12),
                                    onTap: () async {
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
                                                    'रोप क्रमांक: ${plantData['plantNumber']}',
                                                    style: TextStyle(
                                                      color: Colors.black87,
                                                      fontWeight: FontWeight.w500,
                                                    ),
                                                  ),
                                                if (plantData['Planted_On'] != null)
                                                  Text(
                                                    'लागवड केली: ${plantData['Planted_On']}',
                                                    style: TextStyle(
                                                      color: Colors.black87,
                                                      fontWeight: FontWeight.w500,
                                                    ),
                                                  ),
                                                if (plantData['healthStatus'] != null)
                                                  Text(
                                                    'आरोग्य स्थिती: ${_translateHealthStatus(plantData['healthStatus'])}',
                                                    style: TextStyle(
                                                      color: Colors.red[800],
                                                      fontWeight: FontWeight.w600,
                                                    ),
                                                  ),
                                                if (plantData['height'] != null)
                                                  Text(
                                                    'उंची: ${plantData['height']}',
                                                    style: TextStyle(
                                                      color: Colors.black87,
                                                    ),
                                                  ),
                                                if (plantData['girth'] != null)
                                                  Text(
                                                    'परिघ: ${plantData['girth']}',
                                                    style: TextStyle(
                                                      color: Colors.black87,
                                                    ),
                                                  ),
                                                if (plantData['stump'] != null)
                                                  Text(
                                                    'बुंधा: ${plantData['stump']}',
                                                    style: TextStyle(
                                                      color: Colors.black87,
                                                    ),
                                                  ),
                                                if (plantData['longitude'] != null)
                                                  Text(
                                                    'रेखांश: ${plantData['longitude']}',
                                                    style: TextStyle(
                                                      color: Colors.black87,
                                                    ),
                                                  ),
                                                if (plantData['latitude'] != null)
                                                  Text(
                                                    'अक्षांश: ${plantData['latitude']}',
                                                    style: TextStyle(
                                                      color: Colors.black87,
                                                    ),
                                                  ),
                                                if (plantData['biomass'] != null)
                                                  Text(
                                                    'जैवभार: ${plantData['biomass']}',
                                                    style: TextStyle(
                                                      color: Colors.black87,
                                                    ),
                                                  ),
                                                if (plantData['specificLeafArea'] !=
                                                    null)
                                                  Text(
                                                    'विशिष्ट पान क्षेत्र: ${plantData['specificLeafArea']}',
                                                    style: TextStyle(
                                                      color: Colors.black87,
                                                    ),
                                                  ),
                                                if (plantData['longevity'] != null)
                                                  Text(
                                                    'दीर्घायुष्य: ${plantData['longevity']}',
                                                    style: TextStyle(
                                                      color: Colors.black87,
                                                    ),
                                                  ),
                                                if (plantData['leafLitterQuality'] !=
                                                    null)
                                                  Text(
                                                    'पानांच्या कचऱ्याची गुणवत्ता: ${plantData['leafLitterQuality']}',
                                                    style: TextStyle(
                                                      color: Colors.black87,
                                                    ),
                                                  ),
                                                if (plantData['imageUrl'] != null || plantData['localImagePath'] != null)
                                                  Padding(
                                                    padding: const EdgeInsets.only(
                                                      top: 8.0,
                                                    ),
                                                    child: PlantImage(
                                                      imageUrl: plantData['imageUrl'],
                                                      localImagePath: plantData['localImagePath'],
                                                      width: 80,
                                                      height: 80,
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
                                                  'क्र. ${plantData['plantNumber'] ?? ''} · झोन ${zoneNum.isEmpty ? (plantData['zoneName'] ?? '') : zoneNum}',
                                                  style: TextStyle(
                                                    color: Colors.grey[600],
                                                    fontSize: 13,
                                                  ),
                                                ),
                                                if (hasHealthIssue) ...[
                                                  const SizedBox(height: 5),
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
                                                    content: Text('फक्त सुपर अॅडमिन संपादित करू शकतो'),
                                                    backgroundColor: Colors.red,
                                                  ),
                                                );
                                                return;
                                              }
                                              final docId = plant.id;
                                              final plantTypes = await PlantTypeService.fetchAll();
                                              PlantType? selectedPlant = PlantTypeService.resolveFromCache(plantData['plantName'] ?? '');
                                              final nameController = TextEditingController(
                                                text: selectedPlant?.nameMarathi ?? plantData['plantName'] ?? '',
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
                                                        title: Text('रोप तपशील संपादित करा'),
                                                        content: SingleChildScrollView(
                                                          child: Column(
                                                            mainAxisSize: MainAxisSize.min,
                                                            children: [
                                                              const SizedBox(height: 16),
                                                              PlantSearchField(
                                                                plantTypes: plantTypes,
                                                                initialValue: nameController.text,
                                                                onSelected: (p) {
                                                                  selectedPlant = p;
                                                                  nameController.text = p.nameMarathi;
                                                                },
                                                                decoration: InputDecoration(
                                                                  labelText: 'रोपाचे नाव',
                                                                  hintText: 'मराठी / English मध्ये शोधा',
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
                                                                      labelText: 'झोन',
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
                                                                  labelText: 'रोप क्रमांक',
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
                                                                      'किडे',
                                                                      'रोग',
                                                                      'संक्रमित',
                                                                      'पाण्याचा ताण',
                                                                      'पोषक तत्वांची कमतरता',
                                                                      'शारीरिक नुकसान',
                                                                      'इतर',
                                                                      'लागू नाही',
                                                                    ].contains(
                                                                      errorController.text,
                                                                    )
                                                                    ? errorController.text
                                                                    : null,
                                                                decoration: InputDecoration(
                                                                  labelText: 'आरोग्य स्थिती',
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
                                                                          'किडे',
                                                                          'रोग',
                                                                          'संक्रमित',
                                                                          'पाण्याचा ताण',
                                                                          'पोषक तत्वांची कमतरता',
                                                                          'शारीरिक नुकसान',
                                                                          'इतर',
                                                                          'लागू नाही',
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
                                                                  labelText: 'उंची',
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
                                                                  labelText: 'परिघ',
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
                                                                  labelText: 'बुंधा',
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
                                                              Row(
                                                                children: [
                                                                  Expanded(
                                                                    child: TextField(
                                                                      controller: longitudeController,
                                                                      decoration: InputDecoration(
                                                                        labelText: 'रेखांश',
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
                                                                  ),
                                                                  const SizedBox(width: 8),
                                                                  Expanded(
                                                                    child: TextField(
                                                                      controller: latitudeController,
                                                                      decoration: InputDecoration(
                                                                        labelText: 'अक्षांश',
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
                                                                        ScaffoldMessenger.of(context).showSnackBar(
                                                                          SnackBar(content: Text('स्थान यशस्वीरित्या मिळवले!')),
                                                                        );
                                                                      }
                                                                    },
                                                                    icon: Icon(Icons.my_location),
                                                                    color: Colors.blue,
                                                                    tooltip: 'सध्याचे स्थान मिळवा',
                                                                  ),
                                                                ],
                                                              ),
                                                              const SizedBox(height: 16),
                                                              TextField(
                                                                controller: plantedOnController,
                                                                decoration: InputDecoration(
                                                                  labelText: 'लागवड केली',
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
                                                                  labelText: 'जैवभार',
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
                                                                  labelText: 'विशिष्ट पान क्षेत्र',
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
                                                                  labelText: 'दीर्घायुष्य',
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
                                                                  labelText: 'पानांच्या कचऱ्याची गुणवत्ता',
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
                                                                crossAxisAlignment: CrossAxisAlignment.start,
                                                                children: [
                                                                  Row(
                                                                    children: [
                                                                      IconButton(
                                                                        tooltip: 'Gallery',
                                                                        icon: const Icon(Icons.photo_library, color: Colors.blue),
                                                                        onPressed: () async {
                                                                          await FirebaseConfig.logEvent(
                                                                            eventType: 'plantation_edit_pick_image',
                                                                            description: 'Plantation edit pick image (gallery)',
                                                                            userId: loggedInMobile,
                                                                            details: {'docId': plant.id},
                                                                          );
                                                                          final XFile? image = await ImagePicker().pickImage(
                                                                            source: ImageSource.gallery,
                                                                            maxWidth: 1024,
                                                                            maxHeight: 1024,
                                                                            imageQuality: 85,
                                                                          );
                                                                          if (image != null) setState(() => pickedImage = image);
                                                                        },
                                                                      ),
                                                                      IconButton(
                                                                        tooltip: 'Camera',
                                                                        icon: const Icon(Icons.camera_alt, color: Colors.orange),
                                                                        onPressed: () async {
                                                                          await FirebaseConfig.logEvent(
                                                                            eventType: 'plantation_edit_pick_image',
                                                                            description: 'Plantation edit pick image (camera)',
                                                                            userId: loggedInMobile,
                                                                            details: {'docId': plant.id},
                                                                          );
                                                                          final XFile? image = await ImagePicker().pickImage(
                                                                            source: ImageSource.camera,
                                                                            maxWidth: 1024,
                                                                            maxHeight: 1024,
                                                                            imageQuality: 85,
                                                                          );
                                                                          if (image != null) setState(() => pickedImage = image);
                                                                        },
                                                                      ),
                                                                      const SizedBox(width: 8),
                                                                      pickedImage != null
                                                                          ? SizedBox(
                                                                              width: 80,
                                                                              height: 80,
                                                                              child: Image.file(File(pickedImage!.path), fit: BoxFit.cover),
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
                                                                                        const Icon(Icons.broken_image),
                                                                                  ),
                                                                                )
                                                                              : const Text('छायाचित्र निवडलेले नाही')),
                                                                    ],
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
                                                                eventType: 'plantation_edit_cancelled',
                                                                description: 'Plantation edit cancelled',
                                                                userId: loggedInMobile,
                                                                details: {'docId': docId},
                                                              );
                                                              if (dialogContext.mounted) Navigator.pop(dialogContext);
                                                            },
                                                            child: const Text('रद्द करा'),
                                                          ),
                                                          ElevatedButton(
                                                            onPressed: () async {
                                                              await FirebaseConfig.logEvent(
                                                                eventType: 'plantation_edit_saved',
                                                                description: 'Plantation edit saved',
                                                                userId: loggedInMobile,
                                                                details: {'docId': docId},
                                                              );
                                                              final zoneId = selectedZoneId ?? plantData['zoneId'];
                                                              final userId = _safeUploadUserId(
                                                                nameController.text.trim(),
                                                                descriptionController.text.trim(),
                                                                zoneId ?? '',
                                                              );
                                                              Map<String, dynamic> updateData = {
                                                                'plantName': selectedPlant?.nameMarathi ?? nameController.text.trim(),
                                                                'plantTypeId': selectedPlant?.id,
                                                                'zoneId': zoneId,
                                                                'zoneName': zoneController.text,
                                                                'plantNumber': descriptionController.text.trim(),
                                                                'healthStatus': errorController.text.trim().isEmpty ? 'NA' : errorController.text.trim(),
                                                                'height': heightController.text.trim(),
                                                                'girth': girthController.text.trim(),
                                                                'stump': stumpController.text.trim(),
                                                                'longitude': longitudeController.text.trim(),
                                                                'latitude': latitudeController.text.trim(),
                                                                'biomass': biomassController.text.trim(),
                                                                'specificLeafArea': slaController.text.trim(),
                                                                'longevity': longevityController.text.trim(),
                                                                'leafLitterQuality': leafLitterController.text.trim(),
                                                                'Planted_On': plantedOnController.text.trim().isEmpty
                                                                    ? DateTime.now().toIso8601String()
                                                                    : plantedOnController.text.trim(),
                                                              };
                                                              if (pickedImage != null) {
                                                                // Copy image to permanent location
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
                                                                updateData['localImagePath'] = localFilePath;

                                                                final uploadedUrl = await _uploadToFirebaseStorage(
                                                                  File(localFilePath),
                                                                  docId,
                                                                  localExt,
                                                                );
                                                                if (uploadedUrl != null) {
                                                                  updateData['imageUrl'] = uploadedUrl;
                                                                  updateData['uploadStatus'] = 'uploaded';
                                                                } else {
                                                                  updateData['uploadStatus'] = 'queued';
                                                                }
                                                              }
                                                              try {
                                                                final historicalData = Map<String, dynamic>.from(originalData);
                                                                historicalData['originalId'] = docId;
                                                                historicalData['editedAt'] = DateTime.now().toIso8601String();
                                                                final invertedMs = 9999999999999 - DateTime.now().millisecondsSinceEpoch;
                                                                final historyDocId = '${invertedMs}_${docId}';
                                                                await FirebaseFirestore.instance
                                                                    .collection('HistoricalData')
                                                                    .doc(historyDocId)
                                                                    .set(historicalData);

                                                                final currentZoneName =
                                                                    (originalData['zoneName'] ?? '').toString();
                                                                final zoneNum = RegExp(r'(\d+)').firstMatch(currentZoneName)?.group(1) ?? currentZoneName;
                                                                final newDocId =
                                                                    '${zoneNum}_${descriptionController.text.trim()}';

                                                                if (newDocId != docId) {
                                                                  final currentDoc = await FirebaseFirestore.instance
                                                                      .collection('plantation_records')
                                                                      .doc(docId)
                                                                      .get();
                                                                  if (currentDoc.exists) {
                                                                    final mergedData = Map<String, dynamic>.from(
                                                                        currentDoc.data() as Map<String, dynamic>);
                                                                    mergedData.addAll(updateData);
                                                                    await FirebaseFirestore.instance
                                                                        .collection('plantation_records')
                                                                        .doc(newDocId)
                                                                        .set(mergedData);
                                                                    await FirebaseFirestore.instance
                                                                        .collection('plantation_records')
                                                                        .doc(docId)
                                                                        .delete();
                                                                  }
                                                                } else {
                                                                  await FirebaseFirestore.instance
                                                                      .collection('plantation_records')
                                                                      .doc(docId)
                                                                      .update(updateData);
                                                                }
                                                                await FirebaseConfig.logEvent(
                                                                  eventType: 'plantation_updated',
                                                                  description: 'Plantation record updated from list',
                                                                  isImportant: true,
                                                                  details: {
                                                                    'docId': docId,
                                                                    'plantName': nameController.text,
                                                                    'zone': zoneController.text,
                                                                    'plantNumber': descriptionController.text,
                                                                    'healthStatus': errorController.text,
                                                                  },
                                                                );
                                                                if (dialogContext.mounted) Navigator.of(dialogContext).pop();
                                                                Future.microtask(() {
                                                                  ScaffoldMessenger.of(context).showSnackBar(
                                                                    const SnackBar(
                                                                      content: Text('नोंद यशस्वीरित्या अद्यतनित केली.'),
                                                                      backgroundColor: Colors.green,
                                                                    ),
                                                                  );
                                                                });
                                                              } catch (e) {
                                                                if (dialogContext.mounted) {
                                                                  ScaffoldMessenger.of(context).showSnackBar(
                                                                    SnackBar(
                                                                      content: Text('नोंद अद्यतनित करताना त्रुटी: $e'),
                                                                      backgroundColor: Colors.red,
                                                                    ),
                                                                  );
                                                                }
                                                              }
                                                            },
                                                            child: const Text('जतन करा'),
                                                          ),
                                                        ],
                                                      );
                                                    },
                                                  );
                                                },
                                              );
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
            // इतर Tab
            const Center(child: Text('लवकरच उपलब्ध होईल...')),
          ],
        ),
      ),
    );
  }
}
