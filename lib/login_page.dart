import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:plantation_summary/main.dart';
import 'package:plantation_summary/register_page.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';

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

    final query = await FirebaseFirestore.instance
        .collection('users')
        .where('mobile', isEqualTo: mobile)
        .where('password', isEqualTo: password)
        .get();

    if (query.docs.isNotEmpty) {
      // User found in Firestore, store mobile for session
      loggedInMobile = mobile;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Login successful')));
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
    } else {
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
}
