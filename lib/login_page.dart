import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:plantation_summary/main.dart';
import 'package:plantation_summary/register_page.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'dart:async';
import 'firebase_config.dart';
import 'mobile_encryption_service.dart';

class LoginPage extends StatefulWidget {
  const LoginPage({Key? key}) : super(key: key);

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final TextEditingController _mobileController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();
  bool _saveCredentials = false;
  bool _showPassword = false;

  @override
  void initState() {
    super.initState();
    _loadSavedCredentials();
    Future.microtask(() async {
      await FirebaseConfig.logEvent(
        eventType: 'login_page_opened',
        description: 'Login page opened',
        userId: _mobileController.text.trim().isEmpty
            ? null
            : _mobileController.text.trim(),
      );
    });
  }

  Future<void> _loadSavedCredentials() async {
    final prefs = await SharedPreferences.getInstance();
    final savedMobile = prefs.getString('saved_mobile');
    final savedPassword = prefs.getString('saved_password');
    if (savedMobile != null && savedPassword != null) {
      setState(() {
        _mobileController.text = savedMobile;
        _passwordController.text = savedPassword;
        _saveCredentials = true;
      });
    }
  }

  Future<String?> _promptForEmailAndUpdate(
    DocumentReference userRef,
    String mobile,
  ) async {
    final emailController = TextEditingController();
    final enteredEmail = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Email Required'),
        content: TextField(
          controller: emailController,
          decoration: const InputDecoration(labelText: 'Email'),
          keyboardType: TextInputType.emailAddress,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () {
              final email = emailController.text.trim();
              if (email.isEmpty) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('कृपया वैध ईमेल प्रविष्ट करा')),
                );
                return;
              }
              Navigator.pop(dialogContext, email);
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );

    if (enteredEmail == null || enteredEmail.isEmpty) {
      await FirebaseConfig.logEvent(
        eventType: 'login_failed',
        description: 'Login failed - email missing',
        userId: mobile,
      );
      return null;
    }

    await userRef.update({'email': enteredEmail});
    return enteredEmail;
  }

  Future<void> _promptPasswordReset() async {
    final emailController = TextEditingController();
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('चुकीचा पासवर्ड'),
        content: TextField(
          controller: emailController,
          decoration: const InputDecoration(labelText: 'नोंदणीकृत ईमेल'),
          keyboardType: TextInputType.emailAddress,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('रद्द करा'),
          ),
          ElevatedButton(
            onPressed: () async {
              final email = emailController.text.trim();
              if (email.isEmpty) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('कृपया तुमचा ईमेल प्रविष्ट करा'),
                  ),
                );
                return;
              }
              try {
                await FirebaseAuth.instance.sendPasswordResetEmail(
                  email: email,
                );
                Navigator.pop(dialogContext);
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text(
                      'पासवर्ड रीसेट ईमेल पाठवले. कृपया तुमचा इनबॉक्स तपासा.',
                    ),
                  ),
                );
              } catch (e) {
                Navigator.pop(dialogContext);
                ScaffoldMessenger.of(
                  context,
                ).showSnackBar(SnackBar(content: Text('रीसेट अयशस्वी: $e')));
              }
            },
            child: const Text('पासवर्ड रीसेट करा'),
          ),
        ],
      ),
    );
  }

  String _extractEmail(Map<String, dynamic> userData) {
    for (final entry in userData.entries) {
      final key = entry.key.toString().toLowerCase().replaceAll(
        RegExp(r'[^a-z0-9]'),
        '',
      );
      if (key == 'email' ||
          key == 'emailid' ||
          key == 'mail' ||
          key == 'mailid') {
        final value = entry.value?.toString().trim();
        if (value != null &&
            value.isNotEmpty &&
            value.toLowerCase() != 'null' &&
            value.toLowerCase() != 'undefined') {
          return value;
        }
      }
    }
    return '';
  }

  Future<void> _loginUser() async {
    String mobile = _mobileController.text.trim();
    String password = _passwordController.text.trim();

    if (mobile.isEmpty || password.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('कृपया मोबाईल नंबर आणि पासवर्ड दोन्ही प्रविष्ट करा'),
        ),
      );
      return;
    }

    // Find user by mobile to get email (mobile is stored encrypted)
    final encryptedMobile = MobileEncryptionService.encrypt(mobile) ?? mobile;
    QuerySnapshot query;
    try {
      query = await FirebaseFirestore.instance
          .collection('users')
          .where('mobile', isEqualTo: encryptedMobile)
          .get()
          .timeout(const Duration(seconds: 15));
    } on TimeoutException {
      await FirebaseConfig.logEvent(
        eventType: 'login_failed',
        description: 'Login failed - firestore timeout',
        userId: mobile,
      );
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'फायरस्टोअर टाइमआउट. तुमचे इंटरनेट तपासा आणि पुन्हा प्रयत्न करा.',
          ),
        ),
      );
      return;
    } on FirebaseException catch (e) {
      await FirebaseConfig.logEvent(
        eventType: 'login_failed',
        description: 'Login failed - firestore error',
        userId: mobile,
      );
      final message = e.code == 'unavailable'
          ? 'Firestore unavailable. Check your internet.'
          : 'Login failed. Please try again.';
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
      return;
    }

    if (query.docs.isEmpty) {
      await FirebaseConfig.logEvent(
        eventType: 'login_failed',
        description: 'Login failed',
        userId: mobile,
      );
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('अवैध मोबाईल नंबर किंवा पासवर्ड')));
      return;
    }

    if (query.docs.length > 1) {
      // This mobile number is shared by more than one account — almost
      // always a leftover placeholder value from the sevakdb migration
      // (e.g. '1234567890'), not a real duplicate registration. Picking
      // query.docs.first here would silently attach this login to an
      // arbitrary one of those accounts, so refuse instead of guessing.
      await FirebaseConfig.logEvent(
        eventType: 'login_failed',
        description: 'Login failed - mobile matches multiple accounts',
        userId: mobile,
        details: {'matchCount': query.docs.length},
      );
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'हा मोबाईल नंबर एकापेक्षा जास्त खात्यांशी जुळतो. कृपया योग्य मोबाईल नंबर नोंदवण्यासाठी प्रशासकाशी संपर्क साधा.',
          ),
        ),
      );
      return;
    }

    final userDoc = query.docs.first;
    final userData = userDoc.data() as Map<String, dynamic>;
    String email = _extractEmail(userData);
    if (email.isEmpty) {
      final updatedEmail = await _promptForEmailAndUpdate(
        userDoc.reference,
        mobile,
      );
      if (updatedEmail == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('लॉगिन सुरू ठेवण्यासाठी ईमेल आवश्यक आहे.')),
        );
        return;
      }
      email = updatedEmail;
    }
    UserCredential? credential;
    try {
      // Try sign-in first (single Firebase Auth call for existing users).
      // Only fall back to create if the account doesn't exist yet in Firebase Auth.
      try {
        credential = await FirebaseAuth.instance
            .signInWithEmailAndPassword(email: email, password: password)
            .timeout(const Duration(seconds: 15));
      } on FirebaseAuthException catch (signInError) {
        // Firebase now returns 'invalid-credential' (not 'user-not-found') when no
        // account exists for the email, to prevent account enumeration. Treat it the
        // same as 'user-not-found' and try to create the account; if one already
        // exists, createUser fails with 'email-already-in-use', confirming the
        // original failure was really a wrong password.
        if (signInError.code == 'user-not-found' ||
            signInError.code == 'invalid-credential') {
          try {
            credential = await FirebaseAuth.instance
                .createUserWithEmailAndPassword(
                  email: email,
                  password: password,
                )
                .timeout(const Duration(seconds: 15));
          } on FirebaseAuthException catch (createError) {
            if (createError.code == 'email-already-in-use') {
              // Account exists after all — the original sign-in failure was a
              // genuine wrong password, not a missing account.
              throw signInError;
            }
            throw createError;
          }
        } else {
          rethrow;
        }
      }
    } on TimeoutException {
      await FirebaseConfig.logEvent(
        eventType: 'login_failed',
        description: 'Login failed - timeout',
        userId: mobile,
      );
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('नेटवर्क टाइमआउट. कृपया पुन्हा प्रयत्न करा.'),
        ),
      );
      return;
    } on FirebaseAuthException catch (e) {
      await FirebaseConfig.logEvent(
        eventType: 'login_failed',
        description: 'Login failed: ${e.code}',
        userId: mobile,
      );
      final message =
          (e.code == 'wrong-password' || e.code == 'invalid-credential')
          ? 'अवैध मोबाईल नंबर किंवा पासवर्ड'
          : e.code == 'network-request-failed'
          ? 'नेटवर्क त्रुटी. कृपया तुमचे कनेक्शन तपासा.'
          : 'लॉगिन अयशस्वी. कृपया पुन्हा प्रयत्न करा.';
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
      return;
    } catch (e) {
      await FirebaseConfig.logEvent(
        eventType: 'login_failed',
        description: 'Login failed',
        userId: mobile,
      );
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('लॉगिन अयशस्वी. कृपया पुन्हा प्रयत्न करा.'),
        ),
      );
      return;
    }

    if (credential == null) {
      return;
    }

    // User found in Firebase Auth, store mobile for session
    loggedInMobile = mobile;
    await FirebaseConfig.logEvent(
      eventType: 'login_success',
      description: 'User logged in successfully',
      userId: mobile,
      isImportant: true,
    );
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('लॉगिन यशस्वी')));

    // Update FCM token in Firestore and subscribe to broadcast topic
    final currentToken = await FirebaseMessaging.instance.getToken();
    if (currentToken != null) {
      await query.docs.first.reference.update({'fcmToken': currentToken});
    }
    await FirebaseMessaging.instance.subscribeToTopic('all_users');

    if (_saveCredentials) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('saved_mobile', mobile);
      await prefs.setString('saved_password', password);
    } else {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('saved_mobile');
      await prefs.remove('saved_password');
    }
    _mobileController.clear();
    _passwordController.clear();
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(builder: (context) => PlantationForm()),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          Positioned.fill(child: CustomPaint(painter: _LeafWatermarkPainter())),
          SafeArea(
            child: Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(
                  horizontal: 28,
                  vertical: 24,
                ),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(
                      Icons.park_rounded,
                      size: 72,
                      color: Color(0xFF2E7D32),
                    ),
                    const SizedBox(height: 12),
                    const Text(
                      'वृक्षारोपण नोंदी',
                      style: TextStyle(
                        fontSize: 26,
                        fontWeight: FontWeight.bold,
                        color: Color(0xFF2E7D32),
                      ),
                    ),
                    const SizedBox(height: 36),
                    TextField(
                      controller: _mobileController,
                      decoration: const InputDecoration(
                        labelText: 'मोबाईल नंबर',
                        prefixIcon: Icon(Icons.phone_outlined),
                      ),
                      keyboardType: TextInputType.phone,
                    ),
                    const SizedBox(height: 16),
                    TextField(
                      controller: _passwordController,
                      decoration: InputDecoration(
                        labelText: 'पासवर्ड',
                        prefixIcon: const Icon(Icons.lock_outline),
                        suffixIcon: IconButton(
                          icon: Icon(
                            _showPassword
                                ? Icons.visibility_off
                                : Icons.visibility,
                          ),
                          onPressed: () =>
                              setState(() => _showPassword = !_showPassword),
                        ),
                      ),
                      obscureText: !_showPassword,
                    ),
                    CheckboxListTile(
                      title: const Text('क्रेडेन्शियल्स जतन करा'),
                      value: _saveCredentials,
                      onChanged: (val) =>
                          setState(() => _saveCredentials = val ?? false),
                      contentPadding: EdgeInsets.zero,
                      controlAffinity: ListTileControlAffinity.leading,
                      dense: true,
                    ),
                    const SizedBox(height: 20),
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton(
                        onPressed: () async {
                          await FirebaseConfig.logEvent(
                            eventType: 'login_button_clicked',
                            description: 'Login button clicked',
                            userId: _mobileController.text.trim().isEmpty
                                ? null
                                : _mobileController.text.trim(),
                          );
                          await _loginUser();
                        },
                        child: const Text('लॉगिन'),
                      ),
                    ),
                    const SizedBox(height: 12),
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton(
                        onPressed: () async {
                          await FirebaseConfig.logEvent(
                            eventType: 'register_nav_clicked',
                            description: 'Register navigation clicked',
                            userId: _mobileController.text.trim().isEmpty
                                ? null
                                : _mobileController.text.trim(),
                          );
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (context) => RegisterPage(),
                            ),
                          );
                        },
                        child: const Text('साइन अप / नोंदणी'),
                      ),
                    ),
                    const SizedBox(height: 4),
                    TextButton(
                      onPressed: () async {
                        await FirebaseConfig.logEvent(
                          eventType: 'forgot_password_clicked',
                          description: 'Forgot Password clicked',
                          userId: _mobileController.text.trim().isEmpty
                              ? null
                              : _mobileController.text.trim(),
                        );
                        _showResetPasswordDialog();
                      },
                      child: const Text('पासवर्ड विसरलात?'),
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

  void _showResetPasswordDialog() {
    final TextEditingController emailController = TextEditingController();
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('पासवर्ड रीसेट करा'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: emailController,
                decoration: const InputDecoration(labelText: 'नोंदणीकृत ईमेल'),
                keyboardType: TextInputType.emailAddress,
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('रद्द करा'),
            ),
            ElevatedButton(
              onPressed: () async {
                String email = emailController.text.trim();
                if (email.isEmpty) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('कृपया तुमचा नोंदणीकृत ईमेल प्रविष्ट करा'),
                    ),
                  );
                  return;
                }
                try {
                  await FirebaseAuth.instance.sendPasswordResetEmail(
                    email: email,
                  );
                  Navigator.of(context).pop();
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text(
                        'पासवर्ड रीसेट ईमेल पाठवले. कृपया तुमचा इनबॉक्स तपासा.',
                      ),
                    ),
                  );
                } catch (e) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('त्रुटी: ${e.toString()}')),
                  );
                }
              },
              child: const Text('रीसेट ईमेल पाठवा'),
            ),
          ],
        );
      },
    );
  }
}

// Purely decorative, very low-opacity leaf shapes behind the login form —
// a subtle nod to the app's plantation theme without hurting text contrast.
class _LeafWatermarkPainter extends CustomPainter {
  static const _leafColor = Color(0xFF2E7D32);

  void _drawLeaf(Canvas canvas, Offset center, double size, double rotation) {
    final fillPaint = Paint()
      ..color = _leafColor.withOpacity(0.05)
      ..style = PaintingStyle.fill;
    final veinPaint = Paint()
      ..color = _leafColor.withOpacity(0.08)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2;

    canvas.save();
    canvas.translate(center.dx, center.dy);
    canvas.rotate(rotation);

    final path = Path()
      ..moveTo(0, -size / 2)
      ..quadraticBezierTo(size / 2, -size / 4, 0, size / 2)
      ..quadraticBezierTo(-size / 2, -size / 4, 0, -size / 2)
      ..close();
    canvas.drawPath(path, fillPaint);
    canvas.drawLine(Offset(0, -size / 2), Offset(0, size / 2), veinPaint);

    canvas.restore();
  }

  @override
  void paint(Canvas canvas, Size size) {
    _drawLeaf(canvas, Offset(size.width * 0.85, size.height * 0.08), 150, -0.5);
    _drawLeaf(canvas, Offset(size.width * 0.12, size.height * 0.93), 170, 2.6);
    _drawLeaf(canvas, Offset(size.width * 0.18, size.height * 0.15), 80, 0.9);
  }

  @override
  bool shouldRepaint(covariant _LeafWatermarkPainter oldDelegate) => false;
}
