import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_messaging/firebase_messaging.dart';

class RegisterPage extends StatefulWidget {
  const RegisterPage({Key? key}) : super(key: key);

  @override
  State<RegisterPage> createState() => _RegisterPageState();
}

class _RegisterPageState extends State<RegisterPage> {
  final TextEditingController _nameController = TextEditingController();
  final TextEditingController _surnameController = TextEditingController();
  final TextEditingController _mobileController = TextEditingController();
  final TextEditingController _baithakNoController = TextEditingController();
  final TextEditingController _baithakPlaceController = TextEditingController();
  final TextEditingController _zoneController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();

  Map<String, String> _errors = {};

  bool _validateName(String value) =>
      RegExp(r'^[A-Za-z]+$').hasMatch(value.trim());
  bool _validateSurname(String value) =>
      RegExp(r'^[A-Za-z]+$').hasMatch(value.trim());
  bool _validateMobile(String value) =>
      RegExp(r'^[0-9]{10}$').hasMatch(value.replaceAll(RegExp(r'\D'), ''));
  bool _validateBaithakNo(String value) =>
      RegExp(r'^[0-9]+$').hasMatch(value.trim());
  bool _validateBaithakPlace(String value) =>
      RegExp(r'^[A-Za-z ]+$').hasMatch(value.trim());
  bool _validateZone(String value) {
    final numeric = RegExp(r'(\d+)$').firstMatch(value.trim());
    return numeric != null;
  }
  bool _validatePassword(String value) =>
      RegExp(r'^(?=.*[A-Za-z])(?=.*\d)(?=.*[@$!%*#?&])[A-Za-z\d@$!%*#?&]{8,}$')
          .hasMatch(value);

  void _registerUser() async {
    String name = _nameController.text.trim();
    String surname = _surnameController.text.trim();
    String mobile = _mobileController.text.replaceAll(RegExp(r'\D'), '');
    String baithakNo = _baithakNoController.text.trim();
    String baithakPlace = _baithakPlaceController.text.trim();
    String zone = _zoneController.text.trim();
    String password = _passwordController.text.trim();

    Map<String, String> errors = {};

    if (!_validateName(name)) {
      errors['name'] = 'Name should contain alphabets only';
    }
    if (!_validateSurname(surname)) {
      errors['surname'] = 'Surname should contain alphabets only';
    }
    if (!_validateMobile(mobile)) {
      errors['mobile'] = 'Mobile should be 10 digits';
    }
    if (!_validateBaithakNo(baithakNo)) {
      errors['baithakNo'] = 'Baithak No. should be numeric';
    }
    if (!_validateBaithakPlace(baithakPlace)) {
      errors['baithakPlace'] = 'Baithak Place should be alphabetic';
    }
    if (!_validateZone(zone)) {
      errors['zone'] = 'Zone should be numeric';
    }
    if (!_validatePassword(password)) {
      errors['password'] =
          'Password must be at least 8 characters, include a letter, number, and special character';
    }

    setState(() {
      _errors = errors;
    });

    if (errors.isNotEmpty) return;

    final query = await FirebaseFirestore.instance
        .collection('users')
        .where('mobile', isEqualTo: mobile)
        .get();

    if (query.docs.isNotEmpty) {
      setState(() {
        _errors['mobile'] = 'Mobile number already registered';
      });
      return;
    }

    try {
      String? fcmToken = await FirebaseMessaging.instance.getToken();
      await FirebaseFirestore.instance.collection('users').add({
        'name': name,
        'surname': surname,
        'mobile': mobile,
        'baithakNo': baithakNo,
        'baithakPlace': baithakPlace,
        'zone': zone,
        'password': password,
        'fcmToken': fcmToken,
        'role': 'user',
        'createdAt': FieldValue.serverTimestamp(),
      });

      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Registered successfully')));
      _nameController.clear();
      _surnameController.clear();
      _mobileController.clear();
      _baithakNoController.clear();
      _baithakPlaceController.clear();
      _passwordController.clear();
      Navigator.pop(context);
    } catch (e) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Error: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('Register')),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: SingleChildScrollView(
          child: Column(
            children: [
              TextField(
                controller: _nameController,
                decoration: InputDecoration(labelText: 'Name'),
                onChanged: (val) {
                  setState(() {
                    if (!_validateName(val)) {
                      _errors['name'] = 'Name should contain alphabets only';
                    } else {
                      _errors.remove('name');
                    }
                  });
                },
              ),
              if (_errors['name'] != null)
                Padding(
                  padding: const EdgeInsets.only(top: 2.0),
                  child: Text(_errors['name']!, style: TextStyle(color: Colors.red)),
                ),
              SizedBox(height: 12),
              TextField(
                controller: _surnameController,
                decoration: InputDecoration(labelText: 'Surname'),
                onChanged: (val) {
                  setState(() {
                    if (!_validateSurname(val)) {
                      _errors['surname'] = 'Surname should contain alphabets only';
                    } else {
                      _errors.remove('surname');
                    }
                  });
                },
              ),
              if (_errors['surname'] != null)
                Padding(
                  padding: const EdgeInsets.only(top: 2.0),
                  child: Text(_errors['surname']!, style: TextStyle(color: Colors.red)),
                ),
              SizedBox(height: 12),
              TextField(
                controller: _mobileController,
                decoration: InputDecoration(labelText: 'Mobile No.'),
                keyboardType: TextInputType.phone,
                onChanged: (val) {
                  setState(() {
                    if (!_validateMobile(val)) {
                      _errors['mobile'] = 'Mobile should be 10 digits';
                    } else {
                      _errors.remove('mobile');
                    }
                  });
                },
              ),
              if (_errors['mobile'] != null)
                Padding(
                  padding: const EdgeInsets.only(top: 2.0),
                  child: Text(_errors['mobile']!, style: TextStyle(color: Colors.red)),
                ),
              SizedBox(height: 12),
              TextField(
                controller: _baithakNoController,
                decoration: InputDecoration(labelText: 'Baithak No.'),
                onChanged: (val) {
                  setState(() {
                    if (!_validateBaithakNo(val)) {
                      _errors['baithakNo'] = 'Baithak No. is required';
                    } else {
                      _errors.remove('baithakNo');
                    }
                  });
                },
              ),
              if (_errors['baithakNo'] != null)
                Padding(
                  padding: const EdgeInsets.only(top: 2.0),
                  child: Text(_errors['baithakNo']!, style: TextStyle(color: Colors.red)),
                ),
              SizedBox(height: 12),
              TextField(
                controller: _baithakPlaceController,
                decoration: InputDecoration(labelText: 'Baithak Place'),
                onChanged: (val) {
                  setState(() {
                    if (!_validateBaithakPlace(val)) {
                      _errors['baithakPlace'] = 'Baithak Place is required';
                    } else {
                      _errors.remove('baithakPlace');
                    }
                  });
                },
              ),
              if (_errors['baithakPlace'] != null)
                Padding(
                  padding: const EdgeInsets.only(top: 2.0),
                  child: Text(_errors['baithakPlace']!, style: TextStyle(color: Colors.red)),
                ),
              SizedBox(height: 12),
              TextField(
                controller: _zoneController,
                decoration: InputDecoration(labelText: 'Zone'),
                onChanged: (val) {
                  setState(() {
                    if (!_validateZone(val)) {
                      _errors['zone'] = 'Zone should be numeric';
                    } else {
                      _errors.remove('zone');
                    }
                  });
                  if (val.isNotEmpty && !val.toLowerCase().startsWith('zone')) {
                    _zoneController.text = 'Zone $val';
                    _zoneController.selection = TextSelection.fromPosition(
                      TextPosition(offset: _zoneController.text.length),
                    );
                  }
                },
              ),
              if (_errors['zone'] != null)
                Padding(
                  padding: const EdgeInsets.only(top: 2.0),
                  child: Text(_errors['zone']!, style: TextStyle(color: Colors.red)),
                ),
              SizedBox(height: 12),
              TextField(
                controller: _passwordController,
                decoration: InputDecoration(labelText: 'Password'),
                obscureText: true,
                onChanged: (val) {
                  setState(() {
                    if (!_validatePassword(val)) {
                      _errors['password'] =
                          'Password must be at least 8 characters, include a letter, number, and special character';
                    } else {
                      _errors.remove('password');
                    }
                  });
                },
              ),
              if (_errors['password'] != null)
                Padding(
                  padding: const EdgeInsets.only(top: 2.0),
                  child: Text(_errors['password']!, style: TextStyle(color: Colors.red)),
                ),
              SizedBox(height: 24),
              ElevatedButton(onPressed: _registerUser, child: Text('Register')),
            ],
          ),
        ),
      ),
    );
  }
}
