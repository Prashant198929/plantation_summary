import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:plantation_summary/main.dart';
import 'package:plantation_summary/register_page.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'dart:async';
import 'firebase_config.dart';

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
                  const SnackBar(content: Text('Please enter a valid email')),
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
        title: const Text('Incorrect Password'),
        content: TextField(
          controller: emailController,
          decoration: const InputDecoration(labelText: 'Registered Email'),
          keyboardType: TextInputType.emailAddress,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () async {
              final email = emailController.text.trim();
              if (email.isEmpty) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Please enter your email')),
                );
                return;
              }
              try {
                await FirebaseAuth.instance.sendPasswordResetEmail(email: email);
                Navigator.pop(dialogContext);
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text(
                      'Password reset email sent. Please check your inbox.',
                    ),
                  ),
                );
              } catch (e) {
                Navigator.pop(dialogContext);
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('Reset failed: $e')),
                );
              }
            },
            child: const Text('Reset Password'),
          ),
        ],
      ),
    );
  }

  String _extractEmail(Map<String, dynamic> userData) {
    for (final entry in userData.entries) {
      final key = entry.key
          .toString()
          .toLowerCase()
          .replaceAll(RegExp(r'[^a-z0-9]'), '');
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
        SnackBar(content: Text('Please enter both mobile number and password')),
      );
      return;
    }

    // Find user by mobile to get email
    QuerySnapshot query;
    try {
      query = await FirebaseFirestore.instance
          .collection('users')
          .where('mobile', isEqualTo: mobile)
          .get()
          .timeout(const Duration(seconds: 15));
    } on TimeoutException {
      await FirebaseConfig.logEvent(
        eventType: 'login_failed',
        description: 'Login failed - firestore timeout',
        userId: mobile,
      );
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Firestore timeout. Check your internet and retry.')),
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
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
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
      ).showSnackBar(SnackBar(content: Text('Invalid mobile number or password')));
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
          SnackBar(content: Text('Email is required to continue login.')),
        );
        return;
      }
      email = updatedEmail;
    }
    UserCredential? credential;
    try {
      final signInMethods =
          await FirebaseAuth.instance.fetchSignInMethodsForEmail(email);
      if (signInMethods.isEmpty) {
        try {
          credential = await FirebaseAuth.instance
              .createUserWithEmailAndPassword(
                email: email,
                password: password,
              )
              .timeout(const Duration(seconds: 15));
        } on FirebaseAuthException catch (createError) {
          if (createError.code == 'email-already-in-use') {
            credential = await FirebaseAuth.instance
                .signInWithEmailAndPassword(
                  email: email,
                  password: password,
                )
                .timeout(const Duration(seconds: 15));
          } else {
            rethrow;
          }
        }
      } else {
        credential = await FirebaseAuth.instance
            .signInWithEmailAndPassword(
              email: email,
              password: password,
            )
            .timeout(const Duration(seconds: 15));
      }
    } on TimeoutException {
      await FirebaseConfig.logEvent(
        eventType: 'login_failed',
        description: 'Login failed - timeout',
        userId: mobile,
      );
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Network timeout. Please try again.')),
      );
      return;
    } on FirebaseAuthException catch (e) {
      if (e.code == 'email-already-in-use') {
        try {
          credential = await FirebaseAuth.instance
              .signInWithEmailAndPassword(
                email: email,
                password: password,
              )
              .timeout(const Duration(seconds: 15));
        } on FirebaseAuthException catch (signInError) {
          await FirebaseConfig.logEvent(
            eventType: 'login_failed',
            description: 'Login failed',
            userId: mobile,
          );
          if (signInError.code == 'wrong-password' ||
              signInError.code == 'invalid-credential') {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('Invalid mobile number or password')),
            );
            return;
          }
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Invalid mobile number or password')),
          );
          return;
        }
      } else if (e.code == 'wrong-password' ||
          e.code == 'invalid-credential') {
        await FirebaseConfig.logEvent(
          eventType: 'login_failed',
          description: 'Login failed',
          userId: mobile,
        );
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Invalid mobile number or password')),
        );
        return;
      } else {
        await FirebaseConfig.logEvent(
          eventType: 'login_failed',
          description: 'Login failed',
          userId: mobile,
        );
        final message = e.code == 'network-request-failed'
            ? 'Network error. Please check your connection.'
            : 'Invalid mobile number or password';
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(message)),
        );
        return;
      }
    } catch (e) {
      await FirebaseConfig.logEvent(
        eventType: 'login_failed',
        description: 'Login failed',
        userId: mobile,
      );
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Login failed. Please try again.')),
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
    );
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Login successful')),
    );

    // Update FCM token in Firestore after login
    final currentToken = await FirebaseMessaging.instance.getToken();
    if (currentToken != null) {
      await query.docs.first.reference.update({'fcmToken': currentToken});
    }

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
    // Update Firestore password after successful login
    await query.docs.first.reference.update({'password': password});
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(builder: (context) => PlantationForm()),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('Login')),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          children: [
            TextField(
              controller: _mobileController,
              decoration: InputDecoration(labelText: 'Mobile No.'),
              keyboardType: TextInputType.phone,
            ),
            SizedBox(height: 16),
            TextField(
              controller: _passwordController,
              decoration: InputDecoration(
                labelText: 'Password',
                suffixIcon: IconButton(
                  icon: Icon(
                    _showPassword ? Icons.visibility_off : Icons.visibility,
                  ),
                  onPressed: () {
                    setState(() {
                      _showPassword = !_showPassword;
                    });
                  },
                ),
              ),
              obscureText: !_showPassword,
            ),
            CheckboxListTile(
              title: Text('Save Credentials'),
              value: _saveCredentials,
              onChanged: (val) {
                setState(() {
                  _saveCredentials = val ?? false;
                });
              },
            ),
            SizedBox(height: 24),
            ElevatedButton(
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
              child: Text('Login'),
            ),
            SizedBox(height: 12),
            ElevatedButton(
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
              child: Text('Forgot Password?'),
            ),
            SizedBox(height: 12),
            ElevatedButton(
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
                  MaterialPageRoute(builder: (context) => RegisterPage()),
                );
              },
              child: Text('Sign Up / Register'),
            ),
          ],
        ),
      ),
    );
  }

  void _showResetPasswordDialog() {
    final TextEditingController emailController = TextEditingController();
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text('Reset Password'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: emailController,
                decoration: InputDecoration(labelText: 'Registered Email'),
                keyboardType: TextInputType.emailAddress,
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () async {
                String email = emailController.text.trim();
                if (email.isEmpty) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('Please enter your registered email')),
                  );
                  return;
                }
                try {
                  await FirebaseAuth.instance.sendPasswordResetEmail(email: email);
                  Navigator.of(context).pop();
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('Password reset email sent. Please check your inbox.')),
                  );
                } catch (e) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('Error: ${e.toString()}')),
                  );
                }
              },
              child: Text('Send Reset Email'),
            ),
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text('Cancel'),
            ),
          ],
        );
      },
    );
  }
}
