import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'firebase_config.dart';

class RegisterPage extends StatefulWidget {
  const RegisterPage({Key? key}) : super(key: key);

  @override
  State<RegisterPage> createState() => _RegisterPageState();
}

class _RegisterPageState extends State<RegisterPage> {
  static const String _customZoneValue = '__custom__';

  final TextEditingController _nameController = TextEditingController();
  final TextEditingController _surnameController = TextEditingController();
  final TextEditingController _mobileController = TextEditingController();
  final TextEditingController _baithakNoController = TextEditingController();
  final TextEditingController _baithakPlaceController = TextEditingController();
  final TextEditingController _zoneController = TextEditingController();
  final TextEditingController _emailController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();

  final List<String> _zones = [];
  String? _selectedZoneChoice;

  Map<String, String> _errors = {};

  @override
  void initState() {
    super.initState();
    _fetchZones();
    Future.microtask(() async {
      await FirebaseConfig.logEvent(
        eventType: 'register_page_opened',
        description: 'Register page opened',
      );
    });
  }

  Future<void> _fetchZones() async {
    final snapshot = await FirebaseFirestore.instance
        .collection('zones')
        .orderBy('name', descending: false)
        .get();
    final zones = snapshot.docs
        .map((doc) => doc['name']?.toString() ?? '')
        .where((name) => name.isNotEmpty)
        .toList();
    setState(() {
      _zones
        ..clear()
        ..addAll(zones);
      if (_zones.isNotEmpty && _selectedZoneChoice == null) {
        _selectedZoneChoice = _zones.first;
        _zoneController.text = _selectedZoneChoice!;
      }
    });
  }

  String _normalizeZoneInput(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) return trimmed;
    if (trimmed.toLowerCase().startsWith('zone')) {
      return trimmed;
    }
    return 'Zone $trimmed';
  }

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
  bool _validateEmail(String value) =>
      RegExp(r'^[\w-\.]+@([\w-]+\.)+[\w-]{2,4}$').hasMatch(value.trim());
  bool _validatePassword(String value) =>
      RegExp(r'^(?=.*[A-Za-z])(?=.*\d)(?=.*[@$!%*#?&])[A-Za-z\d@$!%*#?&]{8,}$')
          .hasMatch(value);

  void _registerUser() async {
    String name = _nameController.text.trim();
    String surname = _surnameController.text.trim();
    String mobile = _mobileController.text.replaceAll(RegExp(r'\D'), '');
    String baithakNo = _baithakNoController.text.trim();
    String baithakPlace = _baithakPlaceController.text.trim();
    final chosenZone = _selectedZoneChoice == _customZoneValue
        ? _zoneController.text
        : _selectedZoneChoice ?? _zoneController.text;
    String zone = _normalizeZoneInput(chosenZone);
    _zoneController.text = zone;
    String email = _emailController.text.trim();
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
    if (!_validateEmail(email)) {
      errors['email'] = 'Enter a valid email address';
    }
    if (!_validatePassword(password)) {
      errors['password'] =
          'Password must be at least 8 characters, include a letter, number, and special character';
    }

    setState(() {
      _errors = errors;
    });

    if (errors.isNotEmpty) return;

    // Register user with Firebase Auth
    try {
      await FirebaseAuth.instance.createUserWithEmailAndPassword(
        email: email,
        password: password,
      );
    } catch (e) {
      setState(() {
        _errors['email'] = 'Email registration failed: ${e.toString()}';
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Email registration failed: ${e.toString()}')),
      );
      return;
    }

    final query = await FirebaseFirestore.instance
        .collection('users')
        .where('mobile', isEqualTo: mobile)
        .get();

    if (query.docs.isNotEmpty) {
      setState(() {
        _errors['mobile'] = 'Mobile number already registered';
      });
      await FirebaseFirestore.instance.collection('vrukshamojaniattendancelogs').add({
        'mobile': mobile,
        'timestamp': FieldValue.serverTimestamp(),
        'status': 'failed',
        'reason': 'Mobile number already registered',
      });
      return;
    }

    try {
      final zoneSnapshot = await FirebaseFirestore.instance
          .collection('zones')
          .where('name', isEqualTo: zone)
          .limit(1)
          .get();
      if (zoneSnapshot.docs.isEmpty) {
        final zoneDocId = zone.replaceAll(RegExp(r'[^\w\d]'), '_');
        await FirebaseFirestore.instance
            .collection('zones')
            .doc(zoneDocId)
            .set({'name': zone});
        setState(() {
          _zones.add(zone);
        });
      }

      final now = DateTime.now();
      final dateKey =
          '${now.year.toString().padLeft(4, '0')}${now.month.toString().padLeft(2, '0')}${now.day.toString().padLeft(2, '0')}';
      final rawUserId = '${dateKey}_${name}_${mobile}_$zone';
      final userDocId = rawUserId.replaceAll(RegExp(r'[^\w\d]'), '_');
      String? fcmToken = await FirebaseMessaging.instance.getToken();
      await FirebaseFirestore.instance.collection('users').doc(userDocId).set({
        'name': name,
        'surname': surname,
        'mobile': mobile,
        'baithakNo': baithakNo,
        'baithakPlace': baithakPlace,
        'zone': zone,
        'email': email,
        'password': password,
        'fcmToken': fcmToken,
        'role': 'user',
        'createdAt': FieldValue.serverTimestamp(),
      });

      await FirebaseFirestore.instance.collection('vrukshamojaniattendancelogs').add({
        'mobile': mobile,
        'timestamp': FieldValue.serverTimestamp(),
        'status': 'success',
      });

      await FirebaseConfig.logEvent(
        eventType: 'register_success',
        description: 'User registered successfully',
        userId: mobile,
        details: {
          'name': name,
          'surname': surname,
          'baithakNo': baithakNo,
          'baithakPlace': baithakPlace,
          'zone': zone,
          'email': email,
        },
      );
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Registered successfully')));
      _nameController.clear();
      _surnameController.clear();
      _mobileController.clear();
      _baithakNoController.clear();
      _baithakPlaceController.clear();
      _zoneController.clear();
      _emailController.clear();
      _passwordController.clear();
      Navigator.pop(context);
    } catch (e) {
      await FirebaseConfig.logEvent(
        eventType: 'register_failed',
        description: 'User registration failed',
        userId: mobile,
        details: {
          'error': e.toString(),
          'name': name,
          'surname': surname,
          'baithakNo': baithakNo,
          'baithakPlace': baithakPlace,
          'zone': zone,
          'email': email,
        },
      );
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
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  DropdownButtonFormField<String>(
                    value: _selectedZoneChoice,
                    decoration: InputDecoration(labelText: 'Zone'),
                    items: [
                      ..._zones.map(
                        (zone) => DropdownMenuItem(
                          value: zone,
                          child: Text(zone),
                        ),
                      ),
                      DropdownMenuItem(
                        value: _customZoneValue,
                        child: Text('Other'),
                      ),
                    ],
                    onChanged: (val) {
                      setState(() {
                        _selectedZoneChoice = val;
                        if (val != null && val != _customZoneValue) {
                          _zoneController.text = val;
                          if (!_validateZone(val)) {
                            _errors['zone'] = 'Zone should be numeric';
                          } else {
                            _errors.remove('zone');
                          }
                        }
                      });
                    },
                  ),
                  if (_selectedZoneChoice == _customZoneValue)
                    Padding(
                      padding: const EdgeInsets.only(top: 8.0),
                      child: TextField(
                        controller: _zoneController,
                        decoration: InputDecoration(
                          labelText: 'Custom Zone',
                        ),
                        onChanged: (val) {
                          final normalized = _normalizeZoneInput(val);
                          setState(() {
                            _zoneController.text = normalized;
                            _zoneController.selection =
                                TextSelection.fromPosition(
                              TextPosition(
                                offset: _zoneController.text.length,
                              ),
                            );
                            if (!_validateZone(normalized)) {
                              _errors['zone'] = 'Zone should be numeric';
                            } else {
                              _errors.remove('zone');
                            }
                          });
                        },
                      ),
                    ),
                ],
              ),
              if (_errors['zone'] != null)
                Padding(
                  padding: const EdgeInsets.only(top: 2.0),
                  child: Text(_errors['zone']!, style: TextStyle(color: Colors.red)),
                ),
              SizedBox(height: 12),
              TextField(
                controller: _emailController,
                decoration: InputDecoration(labelText: 'Email'),
                keyboardType: TextInputType.emailAddress,
                onChanged: (val) {
                  setState(() {
                    if (!_validateEmail(val)) {
                      _errors['email'] = 'Enter a valid email address';
                    } else {
                      _errors.remove('email');
                    }
                  });
                },
              ),
              if (_errors['email'] != null)
                Padding(
                  padding: const EdgeInsets.only(top: 2.0),
                  child: Text(_errors['email']!, style: TextStyle(color: Colors.red)),
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
              ElevatedButton(
                onPressed: () async {
                  await FirebaseConfig.logEvent(
                    eventType: 'register_button_clicked',
                    description: 'Register button clicked',
                    userId: _mobileController.text.trim().isEmpty
                        ? null
                        : _mobileController.text.trim(),
                  );
                  _registerUser();
                },
                child: Text('Register'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
