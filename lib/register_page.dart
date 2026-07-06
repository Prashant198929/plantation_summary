import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'firebase_config.dart';
import 'mobile_encryption_service.dart';
import 'place_name_service.dart';
import 'transliteration_service.dart';
import 'user_id_service.dart';

class RegisterPage extends StatefulWidget {
  const RegisterPage({Key? key}) : super(key: key);

  @override
  State<RegisterPage> createState() => _RegisterPageState();
}

class _RegisterPageState extends State<RegisterPage> {
  static const String _customZoneValue = '__custom__';

  final TextEditingController _nameController = TextEditingController();
  final TextEditingController _nameMrController = TextEditingController();
  final TextEditingController _mobileController = TextEditingController();
  final TextEditingController _baithakNoController = TextEditingController();
  final TextEditingController _baithakPlaceController = TextEditingController();
  final TextEditingController _baithakMrController = TextEditingController();
  final TextEditingController _zoneMrController = TextEditingController();
  final TextEditingController _hallController = TextEditingController();
  final TextEditingController _hallMrController = TextEditingController();
  final TextEditingController _zoneController = TextEditingController();
  final TextEditingController _emailController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();
  final TextEditingController _dobController = TextEditingController();

  // Tracks whether the user has manually edited an auto-filled Marathi
  // field, so we stop overwriting it as they keep typing the English side.
  bool _nameMrTouched = false;
  bool _baithakMrTouched = false;
  bool _hallMrTouched = false;
  bool _zoneMrTouched = false;

  String? _selectedGender;
  String? _selectedBaithakDay;

  static const Map<String, String> _baithakDayMr = {
    'Monday': 'सोमवार',
    'Tuesday': 'मंगळवार',
    'Wednesday': 'बुधवार',
    'Thursday': 'गुरुवार',
    'Friday': 'शुक्रवार',
    'Saturday': 'शनिवार',
    'Sunday': 'रविवार',
  };

  final List<String> _zones = [];
  String? _selectedZoneChoice;

  Map<String, String> _errors = {};

  @override
  void initState() {
    super.initState();
    _fetchZones();
    PlaceNameService.fetchAll();
    Future.microtask(() async {
      await FirebaseConfig.logEvent(
        eventType: 'register_page_opened',
        description: 'Register page opened',
      );
    });
  }

  // Auto-fills a Marathi field from its English counterpart, unless the user
  // has already edited the Marathi field themselves.
  void _autoFillPhonetic(TextEditingController mrCtrl, bool touched, String english) {
    if (touched) return;
    setState(() => mrCtrl.text = TransliterationService.toDevanagari(english));
  }

  void _autoFillPlace(TextEditingController mrCtrl, bool touched, String english) {
    if (touched) return;
    setState(() => mrCtrl.text = PlaceNameService.suggest(english));
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
    if (trimmed.toLowerCase().startsWith('zone') || trimmed.startsWith('झोन')) {
      return trimmed;
    }
    return 'Zone $trimmed';
  }

  String _autoZoneMr(String zone) {
    if (zone.startsWith('झोन')) return zone;
    final digits = RegExp(r'(\d+)').firstMatch(zone)?.group(1) ?? '';
    return digits.isNotEmpty ? 'झोन $digits' : '';
  }

  void _autoFillZoneMr(String zone) {
    if (_zoneMrTouched) return;
    setState(() => _zoneMrController.text = _autoZoneMr(zone));
  }

  bool _validateName(String value) =>
      RegExp(r'^[A-Za-zऀ-ॿ ]+$').hasMatch(value.trim());
  bool _validateMobile(String value) =>
      RegExp(r'^[0-9]{10}$').hasMatch(value.replaceAll(RegExp(r'\D'), ''));
  bool _validateBaithakNo(String value) => value.trim().isNotEmpty;
  bool _validateBaithakPlace(String value) => value.trim().isNotEmpty;
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
    String nameMr = _nameMrController.text.trim();
    String mobile = _mobileController.text.replaceAll(RegExp(r'\D'), '');
    String baithakNo = _baithakNoController.text.trim();
    String baithakPlace = _baithakPlaceController.text.trim();
    String baithakMr = _baithakMrController.text.trim();
    String baithakDay = _selectedBaithakDay ?? '';
    String baithakDayMr = _baithakDayMr[baithakDay] ?? '';
    String zoneMr = _zoneMrController.text.trim();
    String hall = _hallController.text.trim();
    String hallMr = _hallMrController.text.trim();
    final chosenZone = _selectedZoneChoice == _customZoneValue
        ? _zoneController.text
        : _selectedZoneChoice ?? _zoneController.text;
    String zone = _normalizeZoneInput(chosenZone);
    _zoneController.text = zone;
    String email = _emailController.text.trim();
    String password = _passwordController.text.trim();
    String dob = _dobController.text.trim();
    String gender = _selectedGender ?? '';

    Map<String, String> errors = {};

    if (!_validateName(name)) {
      errors['name'] = 'नावात फक्त अक्षरे असावीत';
    }
    if (!_validateMobile(mobile)) {
      errors['mobile'] = 'मोबाइल नंबर १० अंकी असावा';
    }
    if (!_validateBaithakNo(baithakNo)) {
      errors['baithakNo'] = 'बैठक क्रमांक आवश्यक आहे';
    }
    if (!_validateBaithakPlace(baithakPlace)) {
      errors['baithakPlace'] = 'बैठक ठिकाण आवश्यक आहे';
    }
    if (!_validateZone(zone)) {
      errors['zone'] = 'झोन अंकी असावा';
    }
    if (!_validateEmail(email)) {
      errors['email'] = 'वैध ईमेल पत्ता प्रविष्ट करा';
    }
    if (!_validatePassword(password)) {
      errors['password'] =
          'पासवर्ड किमान ८ अक्षरांचा असावा, अक्षर, संख्या आणि विशेष वर्ण समाविष्ट असावे';
    }

    setState(() {
      _errors = errors;
    });

    if (errors.isNotEmpty) return;

    // Check duplicate mobile BEFORE creating Firebase Auth account
    // (mobile is stored encrypted, so the lookup value must match)
    final encryptedMobile = MobileEncryptionService.encrypt(mobile) ?? mobile;
    final query = await FirebaseFirestore.instance
        .collection('users')
        .where('mobile', isEqualTo: encryptedMobile)
        .get();

    if (query.docs.isNotEmpty) {
      setState(() {
        _errors['mobile'] = 'मोबाइल नंबर आधीच नोंदणीकृत आहे';
      });
      await FirebaseFirestore.instance.collection('vrukshamojaniattendancelogs').add({
        'mobile': mobile,
        'timestamp': FieldValue.serverTimestamp(),
        'status': 'failed',
        'reason': 'मोबाइल नंबर आधीच नोंदणीकृत आहे',
      });
      return;
    }

    // Mobile is unique — now create Firebase Auth account
    String? authUid;
    try {
      final credential = await FirebaseAuth.instance.createUserWithEmailAndPassword(
        email: email,
        password: password,
      );
      authUid = credential.user?.uid;
    } catch (e) {
      setState(() {
        _errors['email'] = 'ईमेल नोंदणी अयशस्वी: ${e.toString()}';
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('ईमेल नोंदणी अयशस्वी: ${e.toString()}')),
      );
      return;
    }

    try {
      final zoneSnapshot = await FirebaseFirestore.instance
          .collection('zones')
          .where('name', isEqualTo: zone)
          .limit(1)
          .get();
      if (zoneSnapshot.docs.isEmpty) {
        await FirebaseFirestore.instance
            .collection('zones')
            .doc(zone)
            .set({'name': zone});
        setState(() {
          _zones.add(zone);
        });
      }

      final invertedMs = 9999999999999 - DateTime.now().millisecondsSinceEpoch;
      String? fcmToken = await FirebaseMessaging.instance.getToken();
      // 'uid' is a clean sequential display ID (for reports/attendance);
      // 'authUid' is the real Firebase Auth ID, kept separately so account
      // cleanup (deleteAuthOnUserDelete) can still find the login account.
      final sequentialUid = await UserIdService.nextId();
      final userDocId = '${invertedMs}_$sequentialUid';
      await FirebaseFirestore.instance.collection('users').doc(userDocId).set({
        'name': name,
        'name_mr': nameMr,
        'mobile': encryptedMobile,
        'baithakNo': baithakNo,
        'baithakPlace': baithakPlace,
        'baithak_mr': baithakMr,
        'baithak_day': baithakDay,
        'baithak_day_mr': baithakDayMr,
        'zone': zone,
        'zone_mr': zoneMr,
        'hall': hall,
        'hall_mr': hallMr,
        'gender': gender,
        'isActive': true,
        'dob': dob,
        'email': email,
        'fcmToken': fcmToken,
        'role': 'user',
        'attendance_viewer': false,
        'createdAt': FieldValue.serverTimestamp(),
        'uid': sequentialUid,
        if (authUid != null) 'authUid': authUid,
      });

      // Grow the place dictionary so future auto-fill for this Baithak
      // Place / Hall is an exact lookup instead of a phonetic guess.
      await PlaceNameService.learn(baithakPlace, baithakMr);
      await PlaceNameService.learn(hall, hallMr);

      await FirebaseFirestore.instance.collection('vrukshamojaniattendancelogs').add({
        'mobile': mobile,
        'timestamp': FieldValue.serverTimestamp(),
        'status': 'success',
      });

      await FirebaseConfig.logEvent(
        eventType: 'register_success',
        description: 'User registered successfully',
        userId: mobile,
        isImportant: true,
        details: {
          'name': name,
          'baithakNo': baithakNo,
          'baithakPlace': baithakPlace,
          'zone': zone,
          'email': email,
        },
      );
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('यशस्वीरित्या नोंदणी केली')));
      _nameController.clear();
      _nameMrController.clear();
      _mobileController.clear();
      _baithakNoController.clear();
      _baithakPlaceController.clear();
      _baithakMrController.clear();
      _zoneMrController.clear();
      _hallController.clear();
      _hallMrController.clear();
      _zoneController.clear();
      _emailController.clear();
      _passwordController.clear();
      _dobController.clear();
      setState(() {
        _selectedGender = null;
        _selectedBaithakDay = null;
        _nameMrTouched = false;
        _baithakMrTouched = false;
        _hallMrTouched = false;
      });
      Navigator.pop(context);
    } catch (e) {
      await FirebaseConfig.logEvent(
        eventType: 'register_failed',
        description: 'User registration failed',
        userId: mobile,
        details: {
          'error': e.toString(),
          'name': name,
          'baithakNo': baithakNo,
          'baithakPlace': baithakPlace,
          'zone': zone,
          'email': email,
        },
      );
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('त्रुटी: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('नोंदणी')),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: SingleChildScrollView(
          child: Column(
            children: [
              TextField(
                controller: _nameController,
                decoration: InputDecoration(labelText: 'पूर्ण नाव (Full Name)'),
                onChanged: (val) {
                  setState(() {
                    if (!_validateName(val)) {
                      _errors['name'] = 'नावात फक्त अक्षरे असावीत';
                    } else {
                      _errors.remove('name');
                    }
                  });
                  _autoFillPhonetic(_nameMrController, _nameMrTouched, val);
                },
              ),
              if (_errors['name'] != null)
                Padding(
                  padding: const EdgeInsets.only(top: 2.0),
                  child: Text(_errors['name']!, style: TextStyle(color: Colors.red)),
                ),
              SizedBox(height: 12),
              TextField(
                controller: _nameMrController,
                decoration: InputDecoration(labelText: 'पूर्ण नाव मराठी (Full Name in Marathi)'),
                onChanged: (_) => _nameMrTouched = true,
              ),
              SizedBox(height: 12),
              TextField(
                controller: _mobileController,
                decoration: InputDecoration(labelText: 'मोबाइल नंबर'),
                keyboardType: TextInputType.phone,
                onChanged: (val) {
                  setState(() {
                    if (!_validateMobile(val)) {
                      _errors['mobile'] = 'मोबाइल नंबर १० अंकी असावा';
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
                decoration: InputDecoration(labelText: 'बैठक क्रमांक'),
                onChanged: (val) {
                  setState(() {
                    if (val.trim().isEmpty) {
                      _errors['baithakNo'] = 'बैठक क्रमांक आवश्यक आहे';
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
                decoration: InputDecoration(labelText: 'बैठक ठिकाण (Baithak Place)'),
                onChanged: (val) {
                  setState(() {
                    if (val.trim().isEmpty) {
                      _errors['baithakPlace'] = 'बैठक ठिकाण आवश्यक आहे';
                    } else {
                      _errors.remove('baithakPlace');
                    }
                  });
                  _autoFillPlace(_baithakMrController, _baithakMrTouched, val);
                },
              ),
              if (_errors['baithakPlace'] != null)
                Padding(
                  padding: const EdgeInsets.only(top: 2.0),
                  child: Text(_errors['baithakPlace']!, style: TextStyle(color: Colors.red)),
                ),
              SizedBox(height: 12),
              TextField(
                controller: _baithakMrController,
                decoration: InputDecoration(labelText: 'बैठक ठिकाण मराठी (Baithak Place in Marathi)'),
                onChanged: (_) => _baithakMrTouched = true,
              ),
              SizedBox(height: 12),
              DropdownButtonFormField<String>(
                value: _selectedBaithakDay,
                decoration: InputDecoration(labelText: 'बैठकीचा वार (Baithak Day)'),
                items: _baithakDayMr.entries.map((e) =>
                  DropdownMenuItem(value: e.key, child: Text('${e.key} - ${e.value}')),
                ).toList(),
                onChanged: (val) => setState(() => _selectedBaithakDay = val),
              ),
              SizedBox(height: 12),
              DropdownButtonFormField<String>(
                value: _selectedGender,
                decoration: InputDecoration(labelText: 'लिंग (Gender)'),
                items: const [
                  DropdownMenuItem(value: 'Male', child: Text('Male - पुरुष')),
                  DropdownMenuItem(value: 'Female', child: Text('Female - स्त्री')),
                  DropdownMenuItem(value: 'Other', child: Text('Other - इतर')),
                ],
                onChanged: (val) => setState(() => _selectedGender = val),
              ),
              SizedBox(height: 12),
              TextField(
                controller: _dobController,
                readOnly: true,
                decoration: InputDecoration(
                  labelText: 'जन्मतारीख (DOB)',
                  suffixIcon: Icon(Icons.calendar_today),
                ),
                onTap: () async {
                  final picked = await showDatePicker(
                    context: context,
                    initialDate: DateTime(2000),
                    firstDate: DateTime(1940),
                    lastDate: DateTime.now(),
                  );
                  if (picked != null) {
                    setState(() {
                      _dobController.text =
                          '${picked.year}-${picked.month.toString().padLeft(2, '0')}-${picked.day.toString().padLeft(2, '0')}';
                    });
                  }
                },
              ),
              SizedBox(height: 12),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  DropdownButtonFormField<String>(
                    value: _selectedZoneChoice,
                    decoration: InputDecoration(labelText: 'झोन'),
                    items: [
                      ..._zones.map(
                        (zone) => DropdownMenuItem(
                          value: zone,
                          child: Text(zone),
                        ),
                      ),
                      DropdownMenuItem(
                        value: _customZoneValue,
                        child: Text('इतर'),
                      ),
                    ],
                    onChanged: (val) {
                      setState(() {
                        _selectedZoneChoice = val;
                        if (val != null && val != _customZoneValue) {
                          _zoneController.text = val;
                          if (!_validateZone(val)) {
                            _errors['zone'] = 'झोन अंकी असावा';
                          } else {
                            _errors.remove('zone');
                          }
                          _autoFillZoneMr(val);
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
                          labelText: 'कस्टम झोन',
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
                              _errors['zone'] = 'झोन अंकी असावा';
                            } else {
                              _errors.remove('zone');
                            }
                          });
                          _autoFillZoneMr(normalized);
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
                controller: _zoneMrController,
                decoration: InputDecoration(labelText: 'झोन मराठी (Zone in Marathi)'),
                onChanged: (_) => _zoneMrTouched = true,
              ),
              SizedBox(height: 12),
              TextField(
                controller: _hallController,
                decoration: InputDecoration(labelText: 'हॉल (Hall)'),
                onChanged: (val) => _autoFillPlace(_hallMrController, _hallMrTouched, val),
              ),
              SizedBox(height: 12),
              TextField(
                controller: _hallMrController,
                decoration: InputDecoration(labelText: 'हॉल मराठी (Hall in Marathi)'),
                onChanged: (_) => _hallMrTouched = true,
              ),
              SizedBox(height: 12),
              TextField(
                controller: _emailController,
                decoration: InputDecoration(labelText: 'ईमेल'),
                keyboardType: TextInputType.emailAddress,
                onChanged: (val) {
                  setState(() {
                    if (!_validateEmail(val)) {
                      _errors['email'] = 'वैध ईमेल पत्ता प्रविष्ट करा';
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
                decoration: InputDecoration(labelText: 'पासवर्ड'),
                obscureText: true,
                onChanged: (val) {
                  setState(() {
                    if (!_validatePassword(val)) {
                      _errors['password'] =
                          'पासवर्ड किमान ८ अक्षरांचा असावा, अक्षर, संख्या आणि विशेष वर्ण समाविष्ट असावे';
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
                child: Text('नोंदणी करा'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
