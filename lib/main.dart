import 'package:flutter/material.dart';
import 'package:flutter_html/flutter_html.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_svg/flutter_svg.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_app_check/firebase_app_check.dart';
import 'package:plantation_summary/login_page.dart';
import 'package:plantation_summary/plantation_list_page.dart';
import 'package:plantation_summary/broadcast_page.dart';
import 'package:plantation_summary/attendance_page.dart';
import 'user_role_management_page.dart';
import 'zone_management_page.dart';
import 'report_page.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:convert';
import 'firebase_config.dart';
import 'firebase_options.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );
  await FirebaseConfig.initialize();
  await FirebaseAppCheck.instance.activate(
    androidProvider: AndroidProvider.debug,
    appleProvider: AppleProvider.debug,
  );

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

  // Listen for FCM token refresh and update Firestore
  FirebaseMessaging.instance.onTokenRefresh.listen((String newToken) async {
    if (loggedInMobile != null) {
      final query = await FirebaseFirestore.instance
          .collection('users')
          .where('mobile', isEqualTo: loggedInMobile)
          .limit(1)
          .get();
      if (query.docs.isNotEmpty) {
        await query.docs.first.reference.update({'fcmToken': newToken});
      }
      // Log event to vrukshamojaniattendancelogs Firestore
      await FirebaseConfig.initialize();
      await FirebaseConfig.logEvent(
        eventType: 'token_refresh',
        description: 'FCM token refreshed',
        userId: loggedInMobile,
        details: {'newToken': newToken},
        collectionName: 'Register_Logs',
      );
    }
  });

  // Also update Firestore with the current token at startup
  final currentToken = await FirebaseMessaging.instance.getToken();
  if (loggedInMobile != null && currentToken != null) {
    final query = await FirebaseFirestore.instance
        .collection('users')
        .where('mobile', isEqualTo: loggedInMobile)
        .limit(1)
        .get();
    if (query.docs.isNotEmpty) {
      await query.docs.first.reference.update({'fcmToken': currentToken});
    }
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
    return


      MaterialApp(
      home: const LoginPage(),
      title: 'Plantation Summary',
      theme: ThemeData(
        colorScheme: ColorScheme(
          brightness: Brightness.light,
          primary: Color(0xFF388E3C), // Deep green
          onPrimary: Colors.white,
          secondary: Color(0xFFFFB300), // Vivid amber
          onSecondary: Colors.black,
          error: Color(0xFFD32F2F), // Strong red
          onError: Colors.white,
          background: Color(0xFFF1F8E9), // Light green background
          onBackground: Colors.black,
          surface: Color(0xFFFFFFFF),
          onSurface: Colors.black,
        ),
        appBarTheme: AppBarTheme(
          backgroundColor: Color(0xFF388E3C),
          foregroundColor: Colors.white,
          iconTheme: IconThemeData(color: Color(0xFFFFB300)),
          titleTextStyle: TextStyle(
            color: Color(0xFFFFB300),
            fontWeight: FontWeight.bold,
            fontSize: 22,
          ),
        ),
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
            backgroundColor: Color(0xFF388E3C),
            foregroundColor: Colors.white,
            textStyle: TextStyle(fontWeight: FontWeight.bold),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
            ),
            elevation: 3,
            shadowColor: Color(0xFFB2DFDB),
          ),
        ),
        inputDecorationTheme: InputDecorationTheme(
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
          focusedBorder: OutlineInputBorder(
            borderSide: BorderSide(color: Color(0xFF388E3C)),
            borderRadius: BorderRadius.circular(10),
          ),
          labelStyle: TextStyle(color: Color(0xFF388E3C)),
          fillColor: Color(0xFFE8F5E9),
          filled: true,
        ),
        scaffoldBackgroundColor: Color(0xFFF1F8E9),
        cardColor: Color(0xFFE8F5E9),
        // Removed tabBarTheme due to type incompatibility with Flutter version
        snackBarTheme: SnackBarThemeData(
          backgroundColor: Color(0xFF388E3C),
          contentTextStyle: TextStyle(color: Colors.white),
        ),
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
        const SnackBar(content: Text('Please select a zone name to filter.')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 8,
      child: Scaffold(
        appBar: AppBar(
          title: Center(
            child: Text('श्री', style: const TextStyle(color: Colors.orange)),
          ),
          backgroundColor: Colors.white,
          iconTheme: const IconThemeData(color: Colors.orange),
          bottom: TabBar(
            tabs: const [
              Tab(text: 'Home'),
              Tab(text: 'Plant Management'),
              Tab(text: 'All Plant Records'),
              Tab(text: 'Broadcast Message'),
              Tab(text: 'Reports'),
              Tab(text: 'Users'),
              Tab(text: 'Attendance'),
              Tab(text: 'Contact'),
            ],
            labelColor: Colors.orange,
            indicatorColor: Colors.orange,
            isScrollable: true,
            onTap: (index) async {
              const tabs = [
                'Home',
                'Plant Management',
                'All Plant Records',
                'Broadcast Message',
                'Reports',
                'Users',
                'Attendance',
                'Contact',
              ];
              await FirebaseConfig.logEvent(
                eventType: 'tab_clicked',
                description: 'Tab selected: ${tabs[index]}',
                userId: loggedInMobile,
                details: {'tab': tabs[index]},
              );
            },
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
                                    FutureBuilder(
                                      future: Future.wait([
                                        FirebaseFirestore.instance.collection('plantation_records').get(),
                                        FirebaseFirestore.instance.collection('zones').get(),
                                      ]),
                                      builder: (context, snapshot) {
                                        if (snapshot.connectionState != ConnectionState.done) {
                                          return const CircularProgressIndicator();
                                        }
                                        if (!snapshot.hasData) {
                                          return const SizedBox();
                                        }
                                        final plantDocs = (snapshot.data as List)[0].docs;
                                        final zoneDocs = (snapshot.data as List)[1].docs;
                                        final totalPlants = plantDocs.length;
                                        final totalZones = zoneDocs.length;
                                        final plantNames = plantDocs
                                            .map((doc) {
                                              final data = doc.data() as Map<String, dynamic>;
                                              final name = data['name'];
                                              return name?.toString();
                                            })
                                            .where((name) => name != null && name is String && name.isNotEmpty)
                                            .toSet()
                                            .toList();
                                        return Row(
                                          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                                          children: [
                                            Expanded(
                                              child: Column(
                                                children: [
                                                  const Text('Total Plants', style: TextStyle(fontWeight: FontWeight.bold)),
                                                  Text('$totalPlants', style: const TextStyle(fontSize: 20)),
                                                ],
                                              ),
                                            ),
                                            Expanded(
                                              child: Column(
                                                children: [
                                                  const Text('Zone Count', style: TextStyle(fontWeight: FontWeight.bold)),
                                                  Text('$totalZones', style: const TextStyle(fontSize: 20)),
                                                ],
                                              ),
                                            ),
                                            Expanded(
                                              child: Column(
                                                children: [
                                                  const Text('Types of Plant', style: TextStyle(fontWeight: FontWeight.bold)),
                                                  Text('${plantNames.length}', style: const TextStyle(fontSize: 20)),
                                                ],
                                              ),
                                            ),
                                          ],
                                        );
                                      },
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
                                      onPressed: () async {
                                        await FirebaseConfig.logEvent(
                                          eventType: 'sign_out_clicked',
                                          description: 'Sign out clicked',
                                          userId: loggedInMobile,
                                        );
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
                // Plant Management Tab
                ZoneManagementPage(),
                // All Plant Records Tab
                const PlantationListPage(),
                // Broadcast Message Tab
                (isSuperAdmin)
                    ? const BroadcastPage()
                    : Padding(
                        padding: const EdgeInsets.only(top: 24.0, left: 16.0),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Only super admin can access Broadcast.',
                              style: TextStyle(color: Colors.red),
                            ),
                          ],
                        ),
                      ),
                // Reports Tab
                (isSuperAdmin)
                    ? const ReportPage()
                    : Padding(
                        padding: const EdgeInsets.only(top: 24.0, left: 16.0),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Only super admin can access Reports.',
                              style: TextStyle(color: Colors.red),
                            ),
                          ],
                        ),
                      ),
                // Users Tab
                (isSuperAdmin)
                    ? const UserRoleManagementPage()
                    : Padding(
                        padding: const EdgeInsets.only(top: 24.0, left: 16.0),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Only super admin can access Users.',
                              style: TextStyle(color: Colors.red),
                            ),
                          ],
                        ),
                      ),
                // Attendance Tab
                (isSuperAdmin)
                    ? AttendancePage(userFirestore: FirebaseFirestore.instance)
                    : Padding(
                        padding: const EdgeInsets.only(top: 24.0, left: 16.0),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Only super admin can access Attendance.',
                              style: TextStyle(color: Colors.red),
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
                        onPressed: () async {
                          await FirebaseConfig.logEvent(
                            eventType: 'about_clicked',
                            description: 'About clicked',
                            userId: loggedInMobile,
                          );
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
                        onPressed: () async {
                          await FirebaseConfig.logEvent(
                            eventType: 'contact_clicked',
                            description: 'Contact Us clicked',
                            userId: loggedInMobile,
                          );
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
                                    'Plant Number: ${plantData['description']}',
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
