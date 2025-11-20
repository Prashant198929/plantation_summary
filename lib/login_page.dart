import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:plantation_summary/main.dart';
import 'package:plantation_summary/register_page.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
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

  @override
  void initState() {
    super.initState();
    _loadSavedCredentials();
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
    final query = await FirebaseFirestore.instance
        .collection('users')
        .where('mobile', isEqualTo: mobile)
        .get();

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

    String email = query.docs.first['email'] ?? '';
    try {
      await FirebaseAuth.instance.signInWithEmailAndPassword(
        email: email,
        password: password,
      );
      // User found in Firebase Auth, store mobile for session
      loggedInMobile = mobile;
      await FirebaseConfig.logEvent(
        eventType: 'login_success',
        description: 'User logged in successfully',
        userId: mobile,
      );
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Login successful')));

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
    } catch (e) {
      await FirebaseConfig.logEvent(
        eventType: 'login_failed',
        description: 'Login failed',
        userId: mobile,
      );
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Invalid mobile number or password')));
    }
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
              decoration: InputDecoration(labelText: 'Password'),
              obscureText: true,
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
            ElevatedButton(onPressed: _loginUser, child: Text('Login')),
            SizedBox(height: 12),
            ElevatedButton(
              onPressed: _showResetPasswordDialog,
              child: Text('Forgot Password?'),
            ),
            SizedBox(height: 12),
            ElevatedButton(
              onPressed: () {
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
