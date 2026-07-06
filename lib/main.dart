import 'package:flutter/material.dart';
import 'package:flutter_html/flutter_html.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_svg/flutter_svg.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
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
import 'dart:async';
import 'dart:convert';
import 'firebase_config.dart';
import 'firebase_options.dart';
import 'mobile_encryption_service.dart';
import 'upload_queue_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );
  await FirebaseConfig.initialize();

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
          .where('mobile', isEqualTo: MobileEncryptionService.encrypt(loggedInMobile!) ?? loggedInMobile)
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
        isImportant: true,
      );
    }
  });

  // Also update Firestore with the current token at startup
  try {
    final currentToken = await FirebaseMessaging.instance.getToken();
    if (loggedInMobile != null && currentToken != null) {
      final query = await FirebaseFirestore.instance
          .collection('users')
          .where('mobile', isEqualTo: MobileEncryptionService.encrypt(loggedInMobile!) ?? loggedInMobile)
          .limit(1)
          .get();
      if (query.docs.isNotEmpty) {
        await query.docs.first.reference.update({'fcmToken': currentToken});
      }
    }
  } catch (e) {
    debugPrint('Failed to get FCM token: $e');
    // Continue app startup even if FCM token retrieval fails
  }

  // Initialize upload queue service
  await UploadQueueService.initialize();

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
        .where('mobile', isEqualTo: MobileEncryptionService.encrypt(loggedInMobile!) ?? loggedInMobile)
        .limit(1)
        .get();
    if (query.docs.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('User not found in users collection.')),
      );
      return null;
    }
    final data = query.docs.first.data();
    final storedMobile = data['mobile']?.toString();
    return {
      'uid': query.docs.first.id,
      'name': data['name'],
      'name_mr': data['name_mr'] ?? '',
      'role': data['role'],
      'mobile': storedMobile == null ? '' : (MobileEncryptionService.decrypt(storedMobile) ?? storedMobile),
      'zone': data['zone'],
      'zone_mr': data['zone_mr'] ?? '',
      'baithak': data['baithakPlace'] ?? data['baithak'] ?? '',
      'baithak_mr': data['baithak_mr'] ?? '',
      'baithak_day': data['baithak_day'] ?? '',
      'baithak_day_mr': data['baithak_day_mr'] ?? '',
      'hall': data['hall'] ?? '',
      'hall_mr': data['hall_mr'] ?? '',
      'gender': data['gender'] ?? '',
      'dob': data['dob'] ?? '',
      'isActive': data['isActive'] ?? true,
    };
  } catch (e) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('Error fetching user details: $e')));
    return null;
  }
}

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Process queue when app starts
    UploadQueueService.processQueue();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    // Process queue when app resumes from background
    if (state == AppLifecycleState.resumed) {
      UploadQueueService.processQueue();
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: const LoginPage(),
      title: 'Plantation Summary',
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF2E7D32),
          brightness: Brightness.light,
        ),
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFF2E7D32),
          foregroundColor: Colors.white,
          elevation: 0,
          scrolledUnderElevation: 2,
          centerTitle: false,
          titleTextStyle: TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.w600,
            fontSize: 20,
            letterSpacing: 0.15,
          ),
          iconTheme: IconThemeData(color: Colors.white),
          actionsIconTheme: IconThemeData(color: Colors.white),
        ),
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
            backgroundColor: const Color(0xFF2E7D32),
            foregroundColor: Colors.white,
            minimumSize: const Size(0, 46),
            textStyle: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
            elevation: 0,
          ),
        ),
        outlinedButtonTheme: OutlinedButtonThemeData(
          style: OutlinedButton.styleFrom(
            foregroundColor: const Color(0xFF2E7D32),
            side: const BorderSide(color: Color(0xFF2E7D32), width: 1.5),
            minimumSize: const Size(0, 46),
            textStyle: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
        ),
        textButtonTheme: TextButtonThemeData(
          style: TextButton.styleFrom(
            foregroundColor: const Color(0xFF2E7D32),
            textStyle: const TextStyle(fontWeight: FontWeight.w600),
          ),
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: const Color(0xFFF1F8E9),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(color: Color(0xFFB0BEC5)),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(color: Color(0xFFB0BEC5)),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(color: Color(0xFF2E7D32), width: 2),
          ),
          labelStyle: const TextStyle(color: Color(0xFF558B2F)),
          contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        ),
        cardTheme: CardThemeData(
          elevation: 1,
          color: Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
        ),
        scaffoldBackgroundColor: const Color(0xFFF1F8E9),
        snackBarTheme: const SnackBarThemeData(
          behavior: SnackBarBehavior.floating,
          backgroundColor: Color(0xFF2E7D32),
          contentTextStyle: TextStyle(color: Colors.white),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(8)),
          ),
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
  late final Future<Map<String, dynamic>?> _userDetailsFuture;
  StreamSubscription<QuerySnapshot>? _accountWatcher;

  @override
  void initState() {
    super.initState();
    _userDetailsFuture = getCurrentUserDetails(context);
    _watchAccount();
  }

  // Force sign-out if the admin deletes this user's Firestore document
  void _watchAccount() {
    final mobile = loggedInMobile;
    if (mobile == null) return;
    _accountWatcher = FirebaseFirestore.instance
        .collection('users')
        .where('mobile', isEqualTo: MobileEncryptionService.encrypt(mobile) ?? mobile)
        .limit(1)
        .snapshots()
        .listen((snapshot) {
      if (snapshot.docs.isEmpty && mounted) {
        _forceSignOut();
      }
    });
  }

  void _forceSignOut() {
    _accountWatcher?.cancel();
    loggedInMobile = null;
    FirebaseAuth.instance.signOut();
    if (!mounted) return;
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const LoginPage()),
      (_) => false,
    );
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('तुमचे खाते हटवले गेले आहे. कृपया प्रशासकाशी संपर्क करा.'),
        duration: Duration(seconds: 5),
      ),
    );
  }

  @override
  void dispose() {
    _accountWatcher?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 8,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('वृक्षमोजणी'),
          bottom: TabBar(
            indicatorColor: Colors.white,
            labelColor: Colors.white,
            unselectedLabelColor: Colors.white60,
            isScrollable: true,
            tabs: const [
              Tab(icon: Icon(Icons.home_outlined), text: 'मुख्यपृष्ठ'),
              Tab(icon: Icon(Icons.park_outlined), text: 'व्यवस्थापन'),
              Tab(icon: Icon(Icons.list_alt_outlined), text: 'सर्व नोंदी'),
              Tab(icon: Icon(Icons.campaign_outlined), text: 'प्रसारण'),
              Tab(icon: Icon(Icons.bar_chart_outlined), text: 'अहवाल'),
              Tab(icon: Icon(Icons.people_outline), text: 'वापरकर्ते'),
              Tab(icon: Icon(Icons.fact_check_outlined), text: 'उपस्थिती'),
              Tab(icon: Icon(Icons.info_outline), text: 'संपर्क'),
            ],
            onTap: (index) async {
              const tabs = [
                'मुख्यपृष्ठ', 'वनस्पती व्यवस्थापन', 'सर्व वनस्पती नोंदी',
                'प्रसारण संदेश', 'अहवाल', 'वापरकर्ते', 'उपस्थिती', 'संपर्क',
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
          builder: (context, userSnap) {
            final role = userSnap.connectionState == ConnectionState.done &&
                    userSnap.hasData &&
                    userSnap.data != null
                ? userSnap.data!['role']?.toString().toLowerCase() ?? ''
                : '';
            final isSuperAdmin =
                role == 'super_admin' || role == 'superadmin';
            // admin gets everything except User Management
            final isElevated = isSuperAdmin || role == 'admin';

            return TabBarView(
              children: [
                // ── Home Tab ──────────────────────────────────────────
                _HomeTab(userSnap: userSnap),

                // ── Plant Management Tab ───────────────────────────────
                ZoneManagementPage(),

                // ── All Records Tab ────────────────────────────────────
                const PlantationListPage(),

                // ── Broadcast Tab ──────────────────────────────────────
                isElevated
                    ? const BroadcastPage()
                    : _LockedTab(label: 'प्रसारण संदेश', icon: Icons.campaign_outlined),

                // ── Reports Tab ────────────────────────────────────────
                isElevated
                    ? const ReportPage()
                    : _LockedTab(label: 'अहवाल', icon: Icons.bar_chart_outlined),

                // ── Users Tab — super_admin only ───────────────────────
                isSuperAdmin
                    ? const UserRoleManagementPage()
                    : _LockedTab(label: 'वापरकर्ते', icon: Icons.people_outline),

                // ── Attendance Tab ─────────────────────────────────────
                isElevated
                    ? AttendancePage(userFirestore: FirebaseFirestore.instance)
                    : _LockedTab(label: 'उपस्थिती', icon: Icons.fact_check_outlined),

                // ── Contact Tab ────────────────────────────────────────
                _ContactTab(),
              ],
            );
          },
        ),
      ),
    );
  }
}

String _roleLabel(String role) {
  const map = {
    'super_admin': 'सुपर प्रशासक',
    'superadmin': 'सुपर प्रशासक',
    'admin': 'प्रशासक',
    'zonal_admin': 'झोनल प्रशासक',
    'user': 'वापरकर्ता',
  };
  return map[role.toLowerCase()] ?? role;
}

// ── Home Tab ──────────────────────────────────────────────────────────────────

class _HomeTab extends StatelessWidget {
  final AsyncSnapshot<Map<String, dynamic>?> userSnap;
  const _HomeTab({required this.userSnap});

  @override
  Widget build(BuildContext context) {
    final userData = userSnap.connectionState == ConnectionState.done &&
            userSnap.hasData &&
            userSnap.data != null
        ? userSnap.data!
        : null;

    final userName = userData?['name']?.toString() ?? '';
    final userRole = userData?['role']?.toString() ?? '';
    final userZone = userData?['zone']?.toString() ?? '';
    final isSuperAdmin = userRole.toLowerCase() == 'super_admin' ||
        userRole.toLowerCase() == 'superadmin';

    final zoneNumber = userZone.replaceAll(RegExp(r'[^0-9]'), '');
    final svgPath = 'assets/zone_images/$zoneNumber.svg';

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // ── Shree heading ─────────────────────────────────────────
          const Text(
            '॥ श्री ॥',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.w600,
              color: Colors.orange,
              letterSpacing: 2,
            ),
          ),
          const SizedBox(height: 8),

          // ── User greeting card ────────────────────────────────────
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  CircleAvatar(
                    radius: 26,
                    backgroundColor: const Color(0xFF2E7D32),
                    child: Icon(
                      isSuperAdmin ? Icons.admin_panel_settings_outlined : Icons.person_outline,
                      color: Colors.white,
                      size: 26,
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          userName.isNotEmpty ? 'नमस्कार, $userName' : 'नमस्कार!',
                          style: const TextStyle(
                            fontWeight: FontWeight.w700,
                            fontSize: 16,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          _roleLabel(userRole),
                          style: TextStyle(color: Colors.grey[600], fontSize: 13),
                        ),
                      ],
                    ),
                  ),
                  OutlinedButton.icon(
                    onPressed: () async {
                      await FirebaseConfig.logEvent(
                        eventType: 'sign_out_clicked',
                        description: 'Sign out clicked',
                        userId: loggedInMobile,
                      );
                      loggedInMobile = null;
                      Navigator.pushReplacement(
                        context,
                        MaterialPageRoute(builder: (_) => const LoginPage()),
                      );
                    },
                    icon: const Icon(Icons.logout, size: 18),
                    label: const Text('बाहेर'),
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                      minimumSize: Size.zero,
                      textStyle: const TextStyle(fontSize: 13),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),

          // ── Stats section ─────────────────────────────────────────
          FutureBuilder(
            future: Future.wait([
              FirebaseFirestore.instance.collection('plantation_records').get(),
              FirebaseFirestore.instance.collection('zones').get(),
            ]),
            builder: (context, statsSnap) {
              if (statsSnap.connectionState != ConnectionState.done) {
                return const Card(
                  child: Padding(
                    padding: EdgeInsets.all(32),
                    child: Center(child: CircularProgressIndicator()),
                  ),
                );
              }
              if (!statsSnap.hasData) return const SizedBox();
              final plantDocs = (statsSnap.data as List)[0].docs;
              final zoneDocs = (statsSnap.data as List)[1].docs;
              final totalPlants = plantDocs.length;
              final totalZones = zoneDocs.length;
              final uniqueSpecies = plantDocs
                  .map((d) => (d.data() as Map)['plantName']?.toString().trim().toLowerCase())
                  .where((n) => n != null && n.isNotEmpty)
                  .toSet()
                  .length;

              return Row(
                children: [
                  _StatCard(icon: Icons.park_outlined, label: 'एकूण रोपे', value: '$totalPlants', color: const Color(0xFF2E7D32)),
                  _StatCard(icon: Icons.map_outlined, label: 'झोन', value: '$totalZones', color: const Color(0xFF1565C0)),
                  _StatCard(icon: Icons.category_outlined, label: 'प्रजाती', value: '$uniqueSpecies', color: const Color(0xFF6A1B9A)),
                ],
              );
            },
          ),
          const SizedBox(height: 12),

          // ── Zone map section ─────────────────────────────────────
          if (zoneNumber.isNotEmpty) ...[
            Card(
              child: Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.only(top: 12, bottom: 4),
                    child: Text(
                      'झोन $zoneNumber',
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                        color: Color(0xFF2E7D32),
                        letterSpacing: 0.5,
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.all(8),
                    child: SvgPicture.asset(
                      svgPath,
                      height: MediaQuery.of(context).size.height * 0.55,
                      width: double.infinity,
                      fit: BoxFit.contain,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _StatCard extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final Color color;

  const _StatCard({
    required this.icon,
    required this.label,
    required this.value,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Card(
        margin: const EdgeInsets.symmetric(horizontal: 4, vertical: 0),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 8),
          child: Column(
            children: [
              Icon(icon, color: color, size: 26),
              const SizedBox(height: 6),
              Text(
                value,
                style: TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w700,
                  color: color,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                label,
                style: TextStyle(fontSize: 11, color: Colors.grey[600]),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ── Locked Tab ────────────────────────────────────────────────────────────────

class _LockedTab extends StatelessWidget {
  final String label;
  final IconData icon;
  const _LockedTab({required this.label, required this.icon});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: Colors.grey[100],
              shape: BoxShape.circle,
            ),
            child: Icon(Icons.lock_outline, size: 40, color: Colors.grey[400]),
          ),
          const SizedBox(height: 16),
          Text(
            label,
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          Text(
            'फक्त सुपर प्रशासकाला प्रवेश आहे.',
            style: TextStyle(color: Colors.grey[600], fontSize: 14),
          ),
        ],
      ),
    );
  }
}

// ── Contact Tab ───────────────────────────────────────────────────────────────

class _ContactTab extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const SizedBox(height: 8),
        Card(
          child: InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: () async {
              await FirebaseConfig.logEvent(
                eventType: 'about_clicked',
                description: 'About clicked',
                userId: loggedInMobile,
              );
              showDialog(
                context: context,
                builder: (ctx) => AlertDialog(
                  title: const Text('आमच्याबद्दल'),
                  content: const Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('वृक्षमोजणी', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
                      SizedBox(height: 4),
                      Text('आवृत्ती: १.०.०', style: TextStyle(color: Color(0xFF757575))),
                      SizedBox(height: 12),
                      Text('हे अॅप वृक्षारोपण नोंदी व्यवस्थापित करण्यास मदत करते.'),
                    ],
                  ),
                  actions: [
                    TextButton(
                      onPressed: () {
                        Navigator.pop(ctx);
                        showLicensePage(
                          context: context,
                          applicationName: 'वृक्षमोजणी',
                          applicationVersion: '१.०.०',
                        );
                      },
                      child: const Text('परवाने पाहा'),
                    ),
                    TextButton(
                      onPressed: () => Navigator.pop(ctx),
                      child: const Text('बंद करा'),
                    ),
                  ],
                ),
              );
            },
            child: const Padding(
              padding: EdgeInsets.all(16),
              child: Row(
                children: [
                  Icon(Icons.info_outline, color: Color(0xFF2E7D32), size: 28),
                  SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('आमच्याबद्दल', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 15)),
                        SizedBox(height: 2),
                        Text('अॅप आवृत्ती व माहिती', style: TextStyle(color: Color(0xFF757575), fontSize: 13)),
                      ],
                    ),
                  ),
                  Icon(Icons.chevron_right, color: Color(0xFF2E7D32)),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(height: 10),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Row(
                  children: [
                    Icon(Icons.contact_support_outlined, color: Color(0xFF2E7D32), size: 28),
                    SizedBox(width: 12),
                    Text('संपर्क माहिती', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 15)),
                  ],
                ),
                const Divider(height: 20),
                _ContactRow(icon: Icons.email_outlined, label: 'ईमेल', value: 'support@plantation.com'),
                const SizedBox(height: 10),
                _ContactRow(icon: Icons.phone_outlined, label: 'फोन', value: '+91-9004223393'),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _ContactRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  const _ContactRow({required this.icon, required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, color: Colors.grey[600], size: 20),
        const SizedBox(width: 10),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: TextStyle(fontSize: 12, color: Colors.grey[500])),
            Text(value, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500)),
          ],
        ),
      ],
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
                    plantData['healthStatus'] != null &&
                            plantData['healthStatus'] != 'NA'
                        ? Colors.red[100]
                        : null,
                title: Row(
                  children: [
                    Expanded(child: Text(plantData['plantName'] ?? '')),
                    ElevatedButton(
                      onPressed: () {
                        showDialog(
                          context: context,
                          builder: (context) => AlertDialog(
                            title: Text(plantData['plantName'] ?? 'Plant Details'),
                            content: Column(
                              mainAxisSize: MainAxisSize.min,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                if (plantData['plantNumber'] != null)
                                  Text(
                                    'Plant Number: ${plantData['plantNumber']}',
                                  ),
                                if (plantData['healthStatus'] != null)
                                  Text(
                                    'Health Status: ${plantData['healthStatus']}',
                                  ),
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
