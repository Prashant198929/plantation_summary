import 'package:flutter/material.dart';
import 'package:flutter_html/flutter_html.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_svg/flutter_svg.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:plantation_summary/login_page.dart';
import 'package:plantation_summary/plantation_list_page.dart';
import 'package:plantation_summary/broadcast_page.dart';
import 'user_role_management_page.dart';
import 'zone_management_page.dart';
import 'report_page.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:convert';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp();

  // Request notification permission before app starts
  await FirebaseMessaging.instance.requestPermission(
    alert: true,
    badge: true,
    sound: true,
  );

  // Save notification to SharedPreferences
  Future<void> saveNotification(RemoteMessage message) async {
    final prefs = await SharedPreferences.getInstance();
    final List<String> notifications =
        prefs.getStringList('received_notifications') ?? [];
    final notificationData = {
      'title': message.notification?.title ?? '',
      'body': message.notification?.body ?? '',
      'data': message.data,
      'receivedAt': DateTime.now().toIso8601String(),
    };
    notifications.insert(0, jsonEncode(notificationData));
    await prefs.setStringList('received_notifications', notifications);
    debugPrint('Saved notification: $notificationData');
    debugPrint('Current notifications list: $notifications');
  }

  // Listen for foreground push notifications and save them locally
  FirebaseMessaging.onMessage.listen((RemoteMessage message) async {
    await saveNotification(message);
  });

  // Listen for background/terminated notification tap
  FirebaseMessaging.onMessageOpenedApp.listen((RemoteMessage message) async {
    await saveNotification(message);
  });

  // Handle notification that opened the app from terminated state
  final initialMessage = await FirebaseMessaging.instance.getInitialMessage();
  if (initialMessage != null) {
    await saveNotification(initialMessage);
  }

  runApp(const MyApp());
}

// Store the logged-in user's mobile number in memory
String? loggedInMobile;

Future<Map<String, dynamic>?> getCurrentUserDetails(
  BuildContext context,
) async {
  try {
    if (loggedInMobile == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No user is currently logged in.')),
      );
      return null;
    }
    final query = await FirebaseFirestore.instance
        .collection('users')
        .where('mobile', isEqualTo: loggedInMobile)
        .limit(1)
        .get();
    if (query.docs.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('User not found in users collection.')),
      );
      return null;
    }
    final data = query.docs.first.data();
    return {
      'uid': query.docs.first.id,
      'name': data['name'],
      'role': data['role'],
      'mobile': data['mobile'],
      'zone': data['zone'],
    };
  } catch (e) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('Error fetching user details: $e')));
    return null;
  }
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: const LoginPage(),
      title: 'Plantation Summary',
      theme: ThemeData(
        colorScheme: ColorScheme(
          brightness: Brightness.light,
          primary: Colors.green,
          onPrimary: Colors.white,
          secondary: Colors.amber,
          onSecondary: Colors.black,
          error: Colors.red,
          onError: Colors.white,
          background: Color(0xFFF6F8F6),
          onBackground: Colors.black,
          surface: Colors.white,
          onSurface: Colors.black,
        ),
        appBarTheme: AppBarTheme(
          backgroundColor: Colors.green,
          foregroundColor: Colors.white,
          iconTheme: IconThemeData(color: Colors.amber),
        ),
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
            backgroundColor: Colors.green,
            foregroundColor: Colors.white,
            textStyle: TextStyle(fontWeight: FontWeight.bold),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
            ),
          ),
        ),
        inputDecorationTheme: InputDecorationTheme(
          border: OutlineInputBorder(),
          focusedBorder: OutlineInputBorder(
            borderSide: BorderSide(color: Colors.green),
          ),
          labelStyle: TextStyle(color: Colors.green),
        ),
        scaffoldBackgroundColor: Color(0xFFF6F8F6),
      ),
    );
  }
}

class PlantationForm extends StatefulWidget {
  const PlantationForm({super.key});

  @override
  State<PlantationForm> createState() => _PlantationFormState();
}

class _PlantationFormState extends State<PlantationForm> {
  final TextEditingController _zoneController = TextEditingController();
  List<String> _zoneSuggestions = [];
  String? _selectedZone;
  late final Future<Map<String, dynamic>?> _userDetailsFuture;

  @override
  void initState() {
    super.initState();
    _userDetailsFuture = getCurrentUserDetails(context);
  }

  void _showAllZones() async {
    final query = await FirebaseFirestore.instance.collection('zones').get();
    setState(() {
      _zoneSuggestions = query.docs
          .map((doc) => doc['name'] as String)
          .toList();
    });
    showModalBottomSheet(
      context: context,
      builder: (context) => ListView(
        children: _zoneSuggestions
            .map(
              (zone) => ListTile(
                title: Text(zone),
                onTap: () {
                  setState(() {
                    _zoneController.text = zone;
                    _selectedZone = zone;
                    _zoneSuggestions = [];
                  });
                  Navigator.pop(context);
                  _openFilteredPlantList(context);
                },
              ),
            )
            .toList(),
      ),
    );
  }

  void _openFilteredPlantList(BuildContext context) {
    final zoneName = _selectedZone?.trim() ?? '';
    if (zoneName.isNotEmpty) {
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (context) => FilteredPlantListPage(zoneName: zoneName),
        ),
      );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please select a zone name to filter.'),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 7,
      child: Scaffold(
        appBar: AppBar(
          title: Center(
            child: Text('श्री', style: const TextStyle(color: Colors.orange)),
          ),
          backgroundColor: Colors.white,
          iconTheme: const IconThemeData(color: Colors.orange),
          bottom: const TabBar(
            tabs: [
              Tab(text: 'Home'),
              Tab(text: 'Zone Management'),
              Tab(text: 'All Plant Records'),
              Tab(text: 'Broadcast Message'),
              Tab(text: 'Reports'),
              Tab(text: 'Users'),
              Tab(text: 'Contact'),
            ],
            labelColor: Colors.orange,
            indicatorColor: Colors.orange,
            isScrollable: true,
          ),
        ),
        body: FutureBuilder<Map<String, dynamic>?>(
          future: _userDetailsFuture,
          builder: (context, snapshot) {
            final isSuperAdmin =
                snapshot.connectionState == ConnectionState.done &&
                snapshot.hasData &&
                snapshot.data != null &&
                (snapshot.data!['role']?.toString().toLowerCase() ==
                        'super_admin' ||
                    snapshot.data!['role']?.toString().toLowerCase() ==
                        'superadmin');
            return TabBarView(
              children: [
                // Home Tab
                Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Builder(
                    builder: (context) {
                      Widget zoneImage = const SizedBox();
                      if (snapshot.connectionState == ConnectionState.done &&
                          snapshot.hasData &&
                          snapshot.data != null &&
                          snapshot.data!['zone'] != null) {
                        final zoneRaw = snapshot.data!['zone']
                            .toString()
                            .toLowerCase();
                        final zoneNumber = zoneRaw.replaceAll(
                          RegExp(r'[^0-9]'),
                          '',
                        );
                        final svgPath = 'assets/zone_images/$zoneNumber.svg';
                        zoneImage = SvgPicture.asset(
                          svgPath,
                          height: 480,
                          width: double.infinity,
                          fit: BoxFit.contain,
                        );
                      }
                      return LayoutBuilder(
                        builder: (context, constraints) {
                          return SingleChildScrollView(
                            child: ConstrainedBox(
                              constraints: BoxConstraints(
                                minHeight: constraints.maxHeight,
                              ),
                              child: IntrinsicHeight(
                                child: Column(
                                  children: [
                                    StatefulBuilder(
                                      builder: (context, setZoneState) {
                                        return Column(
                                          children: [
                                            FutureBuilder<QuerySnapshot>(
                                              future: FirebaseFirestore.instance.collection('zones').get(),
                                              builder: (context, zoneSnapshot) {
                                                List<String> zones = [];
                                                if (zoneSnapshot.connectionState == ConnectionState.done &&
                                                    zoneSnapshot.hasData) {
                                                  zones = zoneSnapshot.data!.docs
                                                      .map((doc) => doc['name'] as String)
                                                      .toList();
                                                }
                                                return Row(
                                                  children: [
                                                    Expanded(
                                                      child: DropdownButtonFormField<String>(
                                                        value: _selectedZone,
                                                        decoration: const InputDecoration(
                                                          labelText: 'Zone Name',
                                                          border: OutlineInputBorder(),
                                                        ),
                                                        items: zones
                                                            .map((zone) => DropdownMenuItem(
                                                                  value: zone,
                                                                  child: Text(zone),
                                                                ))
                                                            .toList(),
                                                        onChanged: (value) {
                                                          setState(() {
                                                            _selectedZone = value;
                                                          });
                                                        },
                                                      ),
                                                    ),
                                                    IconButton(
                                                      icon: const Icon(Icons.menu),
                                                      tooltip: 'More options',
                                                      onPressed: () {
                                                        // Implement menu logic here
                                                        showModalBottomSheet(
                                                          context: context,
                                                          builder: (context) => ListView(
                                                            children: [
                                                              ListTile(
                                                                leading: const Icon(Icons.info),
                                                                title: const Text('Zone Info'),
                                                                onTap: () {
                                                                  Navigator.pop(context);
                                                                  // Implement zone info logic
                                                                },
                                                              ),
                                                              ListTile(
                                                                leading: const Icon(Icons.settings),
                                                                title: const Text('Settings'),
                                                                onTap: () {
                                                                  Navigator.pop(context);
                                                                  // Implement settings logic
                                                                },
                                                              ),
                                                            ],
                                                          ),
                                                        );
                                                      },
                                                    ),
                                                  ],
                                                );
                                              },
                                            ),
                                          ],
                                        );
                                      },
                                    ),
                                    const SizedBox(height: 16),
                                    ElevatedButton(
                                      onPressed: () =>
                                          _openFilteredPlantList(context),
                                      child: const Text('Filter'),
                                    ),
                                    const SizedBox(height: 24),
                                    if (snapshot.connectionState ==
                                            ConnectionState.done &&
                                        snapshot.hasData &&
                                        snapshot.data != null &&
                                        snapshot.data!['zone'] != null)
                                      Text(
                                        snapshot.data!['zone'].toString(),
                                        style: const TextStyle(
                                          fontSize: 24,
                                          fontWeight: FontWeight.bold,
                                          color: Colors.orange,
                                        ),
                                      ),
                                    zoneImage,
                                    const SizedBox(height: 32),
                                    Spacer(),
                                    ElevatedButton(
                                      onPressed: () {
                                        Navigator.pushReplacement(
                                          context,
                                          MaterialPageRoute(
                                            builder: (context) =>
                                                const LoginPage(),
                                          ),
                                        );
                                      },
                                      child: const Text('Sign Out'),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          );
                        },
                      );
                    },
                  ),
                ),
                // Zone Management Tab
                Padding(
                  padding: const EdgeInsets.only(top: 24.0, left: 16.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      ElevatedButton(
                        onPressed: () {
                          if (!isSuperAdmin) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text(
                                  'Only super admin can access this feature.',
                                ),
                                backgroundColor: Colors.red,
                              ),
                            );
                            return;
                          }
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (context) => const ZoneManagementPage(),
                            ),
                          );
                        },
                        child: const Text('Zone Management'),
                      ),
                    ],
                  ),
                ),
                // All Plant Records Tab
                const PlantationListPage(),
                // Broadcast Message Tab
                Padding(
                  padding: const EdgeInsets.only(top: 24.0, left: 16.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      ElevatedButton(
                        onPressed: () {
                          if (!isSuperAdmin) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text(
                                  'Only super admin can access this feature.',
                                ),
                                backgroundColor: Colors.red,
                              ),
                            );
                            return;
                          }
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (context) => const BroadcastPage(),
                            ),
                          );
                        },
                        child: const Text('Broadcast'),
                      ),
                    ],
                  ),
                ),
                // Reports Tab
                Padding(
                  padding: const EdgeInsets.only(top: 24.0, left: 16.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      ElevatedButton(
                        onPressed: () {
                          if (!isSuperAdmin) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text(
                                  'Only super admin can access this feature.',
                                ),
                                backgroundColor: Colors.red,
                              ),
                            );
                            return;
                          }
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (context) => const ReportPage(),
                            ),
                          );
                        },
                        child: const Text('All Plant Reports'),
                      ),
                      const SizedBox(height: 16),
                      const SizedBox(height: 16),
                    ],
                  ),
                ),
                // Users Tab
                Padding(
                  padding: const EdgeInsets.only(top: 24.0, left: 16.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      ElevatedButton(
                        onPressed: () {
                          if (!isSuperAdmin) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text(
                                  'Only super admin can access this feature.',
                                ),
                                backgroundColor: Colors.red,
                              ),
                            );
                            return;
                          }
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (context) =>
                                  const UserRoleManagementPage(),
                            ),
                          );
                        },
                        child: const Text('User Role Management'),
                      ),
                    ],
                  ),
                ),
                // Contact Tab
                Padding(
                  padding: const EdgeInsets.only(top: 24.0, left: 16.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      ElevatedButton(
                        onPressed: () {
                          showAboutDialog(
                            context: context,
                            applicationName: 'Plantation Summary',
                            applicationVersion: '1.0.0',
                            children: [
                              Text('This app helps manage plantation records.'),
                            ],
                          );
                        },
                        child: const Text('About'),
                      ),
                      const SizedBox(height: 16),
                      ElevatedButton(
                        onPressed: () {
                          showDialog(
                            context: context,
                            builder: (context) => AlertDialog(
                              title: const Text('Contact Us'),
                              content: const Text(
                                'Email: support@plantation.com\nPhone: +91-9004223393',
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
                        child: const Text('Contact Us'),
                      ),
                    ],
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

/* ZoneSuggestionField removed: reverting to original logic in _PlantationFormState */

class FilteredPlantListPage extends StatelessWidget {
  final String zoneName;
  const FilteredPlantListPage({required this.zoneName, Key? key})
    : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('Plants in $zoneName')),
      body: StreamBuilder<QuerySnapshot>(
        stream: FirebaseFirestore.instance
            .collection('plantation_records')
            .where('zoneName', isEqualTo: zoneName)
            .snapshots(),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return Center(child: CircularProgressIndicator());
          }
          if (!snapshot.hasData || snapshot.data!.docs.isEmpty) {
            return Center(child: Text('No plants found in this zone.'));
          }
          final plants = snapshot.data!.docs;
          return ListView.builder(
            itemCount: plants.length,
            itemBuilder: (context, index) {
              final plant = plants[index];
              final plantData = plant.data() as Map<String, dynamic>;
              return ListTile(
                tileColor:
                    plantData['error'] != null && plantData['error'] != 'NA'
                    ? Colors.red[100]
                    : null,
                title: Row(
                  children: [
                    Expanded(child: Text(plantData['name'] ?? '')),
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
