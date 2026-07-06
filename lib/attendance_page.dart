import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:excel/excel.dart' hide Border;
import 'package:excel/excel.dart' as xl;
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'main.dart';
import 'attendance_support.dart';
import 'attendance_details.dart';
import 'firebase_config.dart';
import 'mobile_encryption_service.dart';
import 'place_name_service.dart';
import 'transliteration_service.dart';
import 'user_id_service.dart';

class AttendancePage extends StatefulWidget {
  final FirebaseFirestore userFirestore;
  const AttendancePage({Key? key, required this.userFirestore})
    : super(key: key);

  @override
  State<AttendancePage> createState() => _AttendancePageState();
}

class _AttendancePageState extends State<AttendancePage> {
  String _formatDateTime(DateTime dt) {
    return '${dt.year.toString().padLeft(4, '0')}${dt.month.toString().padLeft(2, '0')}${dt.day.toString().padLeft(2, '0')}${dt.hour.toString().padLeft(2, '0')}${dt.minute.toString().padLeft(2, '0')}${dt.second.toString().padLeft(2, '0')}';
  }

  DateTime _selectedDate = DateTime.now();
  List<String> _selectedTopics = [];
  String? _currentZone;
  List<String> _topics = [];
  List<Map<String, dynamic>> _places = [];
  String? _selectedPlace;
  List<Map<String, dynamic>> _zoneUsers = [];
  List<Map<String, dynamic>> _selectedUsers = [];
  List<Map<String, dynamic>> _filteredUsers = [];
  TextEditingController _searchController = TextEditingController();
  final TextEditingController _workHoursController = TextEditingController();
  bool _isLoading = false;
  String? _errorMessage;
  FirebaseFirestore? _secondaryFirestore;
  FirebaseApp? _secondaryApp;
  bool _canViewAttendance = false;
  bool _roleChecked = false;
  bool _isSuperAdmin = false;
  List<String> _zones = [];
  String? _selectedZone;

  @override
  void initState() {
    super.initState();
    _checkAttendanceRole();
    _callInitializeSecondaryApp();
    Future.microtask(() async {
      await _cleanupOldAttendanceLogs();
    });
    Future.microtask(() async {
      await FirebaseConfig.logEvent(
        eventType: 'attendance_page_opened',
        description: 'Attendance page opened',
        userId: loggedInMobile,
      );
    });
  }

  Future<void> _checkAttendanceRole() async {
    final encryptedMobile = loggedInMobile == null
        ? null
        : MobileEncryptionService.encrypt(loggedInMobile!) ?? loggedInMobile;
    final userQuery = await widget.userFirestore
        .collection('users')
        .where('mobile', isEqualTo: encryptedMobile)
        .limit(1)
        .get();
    bool canView = false;
    bool isSuperAdmin = false;
    if (userQuery.docs.isNotEmpty) {
      final data = userQuery.docs.first.data();
      final role = data['role']?.toString().toLowerCase();
      isSuperAdmin = role == 'super_admin' || role == 'superadmin' || role == 'admin';
      canView = isSuperAdmin || data['attendance_viewer'] == true;
    }
    if (!mounted) {
      return;
    }
    setState(() {
      _isSuperAdmin = isSuperAdmin;
      _canViewAttendance = canView;
      _roleChecked = true;
    });
    if (isSuperAdmin) {
      await _fetchZones();
      if (_secondaryFirestore != null) {
        await _fetchZoneUsers();
      }
    }
  }

  Future<void> _callInitializeSecondaryApp() async {
    final secondaryApp = await AttendanceSupport.initializeSecondaryApp(
      _secondaryFirestore,
    );
    if (secondaryApp != null) {
      final firestore = FirebaseFirestore.instanceFor(app: secondaryApp);
      if (!mounted) {
        return;
      }
      setState(() {
        _secondaryApp = secondaryApp;
        _secondaryFirestore = firestore;
      });
      final topics = await AttendanceSupport.fetchTopics(firestore);
      if (!mounted) {
        return;
      }
      setState(() {
        _topics = topics;
        _isLoading = false;
      });
      await _fetchPlaces();
      await _fetchCurrentUserZone();
      if (_isSuperAdmin) {
        await _fetchZones();
      } else {
        if (!mounted) {
          return;
        }
        setState(() {
          _selectedZone = _currentZone;
        });
      }
      await _fetchZoneUsers();
    } else {
      if (!mounted) {
        return;
      }
      setState(() {
        _errorMessage = 'Failed to initialize Firebase. Please try again.';
      });
    }
  }

  Future<void> _cleanupOldAttendanceLogs() async {
    final now = DateTime.now();
    final firstDayOfMonth = DateTime(now.year, now.month, 1);
    try {
      await FirebaseConfig.initialize();
      final logFirestore = FirebaseConfig.firestore;
      final snapshot = await logFirestore.collection('Register_Logs').get();
      for (final doc in snapshot.docs) {
        final docDate = DateTime.tryParse(doc.id);
        if (docDate != null && docDate.isBefore(firstDayOfMonth)) {
          await logFirestore.collection('Register_Logs').doc(doc.id).delete();
        }
      }
    } catch (e) {
      debugPrint('Attendance log cleanup failed: $e');
    }
  }

  @override
  void dispose() {
    _workHoursController.dispose();
    super.dispose();
  }

  Future<void> _fetchPlaces() async {
    final places = await AttendanceSupport.fetchPlaces(_secondaryFirestore);
    if (!mounted) {
      return;
    }
    setState(() {
      _places = places;
    });
  }

  Future<void> _fetchZones() async {
    final zonesSnapshot = await widget.userFirestore
        .collection('zones')
        .orderBy('name', descending: false)
        .get();
    final zonesFromCollection = zonesSnapshot.docs
        .map(
          (doc) =>
              (doc.data() as Map<String, dynamic>)['name']?.toString() ?? '',
        )
        .map((name) => name.trim())
        .where((name) => name.isNotEmpty)
        .toList();

    if (!mounted) {
      return;
    }
    setState(() {
      _zones = zonesFromCollection;
    });
  }

  Future<void> _fetchZoneUsers() async {
    final zoneToQuery = _isSuperAdmin ? _selectedZone : _currentZone;
    final users = await AttendanceSupport.fetchZoneUsers(
      widget.userFirestore,
      zoneToQuery,
    );
    if (!mounted) {
      return;
    }
    setState(() {
      _zoneUsers = users;
      _filteredUsers = users;
      _selectedUsers = [];
    });
  }

  Future<void> _fetchCurrentUserZone() async {
    final zone = await AttendanceSupport.fetchCurrentUserZone(context);
    if (!mounted) {
      return;
    }
    setState(() {
      _currentZone = zone;
    });
  }

  Future<void> _selectDate(BuildContext context) async {
    final picked = await AttendanceSupport.selectDate(context, _selectedDate);
    if (picked != null && picked != _selectedDate) {
      if (!mounted) {
        return;
      }
      setState(() {
        _selectedDate = picked;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_roleChecked) {
      return Scaffold(
        appBar: AppBar(title: Text('उपस्थिती व्यवस्थापन')),
        body: Center(child: CircularProgressIndicator()),
      );
    }
if (!_canViewAttendance) {
  return Scaffold(
    appBar: AppBar(title: Text('उपस्थिती व्यवस्थापन')),
    body: Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.lock_outline, color: Colors.red, size: 64),
          SizedBox(height: 24),
          Text(
            'तुम्हाला उपस्थिती पृष्ठ पाहण्याची अधिकृतता नाही.',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: Colors.red,
              fontWeight: FontWeight.bold,
              fontSize: 22,
              letterSpacing: 1.2,
              shadows: [
                Shadow(
                  color: Colors.black26,
                  offset: Offset(1, 2),
                  blurRadius: 4,
                ),
              ],
            ),
          ),
          SizedBox(height: 16),
          Text(
            'कृपया प्रवेशासाठी तुमच्या प्रशासकाशी संपर्क साधा.',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: Colors.grey[700],
              fontSize: 16,
            ),
          ),
        ],
      ),
    ),
  );
}
    // ... original build code below ...
    return Scaffold(
      appBar: AppBar(
        title: Text('उपस्थिती व्यवस्थापन'),
        actions: [
          IconButton(
            icon: Icon(Icons.refresh),
            onPressed: () async {
              await FirebaseConfig.logEvent(
                eventType: 'attendance_refresh_clicked',
                description: 'Attendance refresh clicked',
                userId: loggedInMobile,
              );
              final topics = await AttendanceSupport.fetchTopics(
                _secondaryFirestore,
              );
              setState(() {
                _topics = topics;
                _isLoading = false;
              });
            },
          ),
          IconButton(
            icon: Icon(Icons.calendar_today),
            onPressed: () async {
              await FirebaseConfig.logEvent(
                eventType: 'attendance_date_picker_clicked',
                description: 'Attendance date picker clicked',
                userId: loggedInMobile,
              );
              _selectDate(context);
            },
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () async {
          await FirebaseConfig.logEvent(
            eventType: 'attendance_pull_refresh',
            description: 'Attendance pull to refresh',
            userId: loggedInMobile,
          );
          final topics = await AttendanceSupport.fetchTopics(
            _secondaryFirestore,
          );
          setState(() {
            _topics = topics;
            _isLoading = false;
          });
        },
        child: SingleChildScrollView(
          physics: AlwaysScrollableScrollPhysics(),
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.all(16.0),
                child: Column(
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          'तारीख: ${_selectedDate.toLocal().toString().split(' ')[0]}',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        if (!_isSuperAdmin)
                          Text(
                            'झोन: ${_currentZone ?? "लोड करत आहे..."}',
                            style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                      ],
                    ),
                    SizedBox(height: 16),
                    if (_errorMessage != null)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 16.0),
                        child: Text(
                          _errorMessage!,
                          style: TextStyle(
                            color: Colors.red,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Expanded(
                          child: _isLoading
                              ? Center(child: CircularProgressIndicator())
                              : Column(
                                  children: [
                                    Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        GestureDetector(
                                          onTap: () async {
                                            await FirebaseConfig.logEvent(
                                              eventType: 'attendance_topics_clicked',
                                              description: 'Attendance topics clicked',
                                              userId: loggedInMobile,
                                            );
                                            final selected = await showDialog<List<String>>(
                                              context: context,
                                              builder: (context) {
                                                List<String> tempSelected = List.from(_selectedTopics);
                                                return StatefulBuilder(
                                                  builder: (context, setStateDialog) {
                                                    return AlertDialog(
                                                      title: Text('विषय निवडा'),
                                                      content: Container(
                                                        width: double.maxFinite,
                                                        child: ListView(
                                                          shrinkWrap: true,
                                                          children: _topics.map((topic) {
                                                            final isSelected = tempSelected.contains(topic);
                                                            return CheckboxListTile(
                                                              title: Text(topic),
                                                              value: isSelected,
                                                              onChanged: (checked) {
                                                                setStateDialog(() {
                                                                  if (checked == true) {
                                                                    if (!tempSelected.contains(topic)) {
                                                                      tempSelected.add(topic);
                                                                    }
                                                                  } else {
                                                                    tempSelected.remove(topic);
                                                                  }
                                                                });
                                                                Future.microtask(() async {
                                                                  await FirebaseConfig.logEvent(
                                                                    eventType: 'attendance_topic_toggled',
                                                                    description: 'Attendance topic toggled',
                                                                    userId: loggedInMobile,
                                                                    details: {
                                                                      'topic': topic,
                                                                      'selected': checked == true,
                                                                    },
                                                                  );
                                                                });
                                                              },
                                                            );
                                                          }).toList(),
                                                        ),
                                                      ),
                                                      actions: [
                                                        TextButton(
                                                          child: Text('ठीक आहे'),
                                                          onPressed: () async {
                                                            await FirebaseConfig.logEvent(
                                                              eventType: 'attendance_topics_ok',
                                                              description: 'Attendance topics OK',
                                                              userId: loggedInMobile,
                                                              details: {'topics': tempSelected},
                                                            );
                                                            Navigator.of(context).pop(tempSelected);
                                                          },
                                                        ),
                                                        TextButton(
                                                          child: Text('रद्द करा'),
                                                          onPressed: () async {
                                                            await FirebaseConfig.logEvent(
                                                              eventType: 'attendance_topics_cancel',
                                                              description: 'Attendance topics cancel',
                                                              userId: loggedInMobile,
                                                            );
                                                            Navigator.of(context).pop(_selectedTopics);
                                                          },
                                                        ),
                                                      ],
                                                    );
                                                  },
                                                );
                                              },
                                            );
                                            if (selected != null) {
                                              setState(() {
                                                _selectedTopics = selected;
                                              });
                                            }
                                          },
                                          child: InputDecorator(
                                            decoration: const InputDecoration(
                                              labelText: 'विषय',
                                              border: OutlineInputBorder(),
                                            ),
                                            child: Row(
                                              children: [
                                                Expanded(
                                                  child: Text(
                                                    _selectedTopics.isEmpty
                                                        ? 'विषय निवडा'
                                                        : _selectedTopics.join(
                                                            ', ',
                                                          ),
                                                    style: TextStyle(
                                                      fontSize: 16,
                                                      color: _selectedTopics.isEmpty
                                                          ? Theme.of(context).hintColor
                                                          : null,
                                                    ),
                                                  ),
                                                ),
                                                Icon(Icons.arrow_drop_down),
                                              ],
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                    SizedBox(height: 16),
                                    DropdownButtonFormField<String>(
                                      decoration: InputDecoration(
                                        labelText: 'ठिकाण',
                                        border: OutlineInputBorder(),
                                      ),
                                      value: _selectedPlace,
                                      hint: Text('ठिकाण निवडा'),
                                      items: _places.map((place) {
                                        return DropdownMenuItem(
                                          value: place['placeName'] as String,
                                          child: Text(place['placeName'] as String),
                                        );
                                      }).toList(),
                                      onChanged: (value) {
                                        setState(() {
                                          _selectedPlace = value;
                                        });
                                        Future.microtask(() async {
                                          await FirebaseConfig.logEvent(
                                            eventType: 'attendance_place_changed',
                                            description: 'Attendance place changed',
                                            userId: loggedInMobile,
                                            details: {'place': value},
                                          );
                                        });
                                      },
                                    ),
                                    SizedBox(height: 16),
                                    TextField(
                                      controller: _workHoursController,
                                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                                      decoration: const InputDecoration(
                                        labelText: 'कामाचे तास (Work Hours)',
                                        hintText: 'तास निवडा',
                                        floatingLabelBehavior: FloatingLabelBehavior.always,
                                        border: OutlineInputBorder(),
                                      ),
                                      onChanged: (value) {
                                        Future.microtask(() async {
                                          await FirebaseConfig.logEvent(
                                            eventType: 'attendance_work_hours_changed',
                                            description: 'Attendance work hours changed',
                                            userId: loggedInMobile,
                                            details: {'workHours': value},
                                          );
                                        });
                                      },
                                    ),
                                    SizedBox(height: 16),
                                    if (_isSuperAdmin)
                                      DropdownButtonFormField<String>(
                                        value: _selectedZone,
                                        menuMaxHeight: 300,
                                        isExpanded: true,
                                        hint: Text('झोन निवडा'),
                                        items: _zones
                                            .map(
                                              (zone) => DropdownMenuItem(
                                                value: zone,
                                                child: Text(zone),
                                              ),
                                            )
                                            .toList(),
                                        onChanged: (value) async {
                                          setState(() {
                                            _selectedZone = value;
                                            _selectedUsers = [];
                                            _searchController.clear();
                                          });
                                          await FirebaseConfig.logEvent(
                                            eventType:
                                                'attendance_zone_changed',
                                            description:
                                                'Attendance zone changed',
                                            userId: loggedInMobile,
                                            details: {'zone': value},
                                          );
                                          await _fetchZoneUsers();
                                        },
                                        decoration: const InputDecoration(
                                          labelText: 'झोन',
                                          border: OutlineInputBorder(),
                                        ),
                                      ),
                                    if (_isSuperAdmin) SizedBox(height: 16),
                                    Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          'झोनमधून वापरकर्ते निवडा:',
                                          style: TextStyle(
                                            fontWeight: FontWeight.bold,
                                          ),
                                        ),
                                        SizedBox(height: 4),
                                        Row(
                                          children: [
                                            IconButton(
                                              icon: Icon(Icons.refresh),
                                              tooltip: 'वापरकर्ता यादी रीफ्रेश करा',
                                              onPressed: () async {
                                                await FirebaseConfig.logEvent(
                                                  eventType: 'attendance_user_refresh_clicked',
                                                  description:
                                                      'Attendance user refresh clicked',
                                                  userId: loggedInMobile,
                                                  details: {
                                                    'zone': _isSuperAdmin
                                                        ? _selectedZone
                                                        : _currentZone,
                                                  },
                                                );
                                                print(
                                                  'Manual refresh clicked. Current zone: $_currentZone',
                                                );
                                                _fetchZoneUsers();
                                              },
                                            ),
                                            if (_isSuperAdmin)
                                              TextButton(
                                                onPressed: () async {
                                                  setState(() {
                                                    _selectedUsers = List.from(
                                                      _zoneUsers,
                                                    );
                                                  });
                                                  await FirebaseConfig.logEvent(
                                                    eventType:
                                                        'attendance_select_all_users',
                                                    description:
                                                        'Attendance select all users',
                                                    userId: loggedInMobile,
                                                    details: {
                                                      'zone': _selectedZone,
                                                      'count':
                                                          _selectedUsers.length,
                                                    },
                                                  );
                                                },
                                                child: Text('सर्व निवडा'),
                                              ),
                                            if (_isSuperAdmin)
                                              IconButton(
                                                icon: Icon(Icons.person_add, color: Color(0xFF2E7D32)),
                                                tooltip: 'नवीन वापरकर्ता जोडा',
                                                onPressed: () async {
                                                  final added = await showModalBottomSheet<bool>(
                                                    context: context,
                                                    isScrollControlled: true,
                                                    shape: RoundedRectangleBorder(
                                                      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
                                                    ),
                                                    builder: (_) => _AddUserBottomSheet(
                                                      zones: _zones,
                                                      prefilledZone: _isSuperAdmin ? _selectedZone : _currentZone,
                                                      userFirestore: widget.userFirestore,
                                                    ),
                                                  );
                                                  if (added == true) await _fetchZoneUsers();
                                                },
                                              ),
                                          ],
                                        ),
                                      ],
                                    ),
                                    SizedBox(height: 8),
                                    _zoneUsers.isEmpty
                                        ? Text('या झोनसाठी कोणतेही वापरकर्ते आढळले नाहीत.')
                                        : Column(
                                            children: [
                                              TextField(
                                                controller: _searchController,
                                                decoration: InputDecoration(
                                                  labelText: 'वापरकर्त्याचे नाव शोधा',
                                                  border: OutlineInputBorder(),
                                                  prefixIcon: Icon(
                                                    Icons.search,
                                                  ),
                                                ),
                                                onChanged: (value) {
                                                  setState(() {
                                                    _filteredUsers = _zoneUsers
                                                        .where(
                                                          (user) => user['name']
                                                              .toString()
                                                              .toLowerCase()
                                                              .contains(
                                                                value
                                                                    .toLowerCase(),
                                                              ),
                                                        )
                                                        .toList();
                                                  });
                                                },
                                              ),
                                              SizedBox(height: 8),
                                              Container(
                                                height: 200,
                                                child: ListView.builder(
                                                  shrinkWrap: true,
                                                  physics:
                                                      AlwaysScrollableScrollPhysics(),
                                                  itemCount:
                                                      _filteredUsers.length,
                                                  itemBuilder: (context, idx) {
                                                    final user =
                                                        _filteredUsers[idx];
                                                    final isSelected =
                                                        _selectedUsers.contains(
                                                          user,
                                                        );
                                                    return CheckboxListTile(
                                                      title: Text(
                                                        '${user['name']} (${user['mobile']})',
                                                        style: TextStyle(
                                                          fontSize: 12,
                                                        ),
                                                      ),
                                                      value: isSelected,
                                                      onChanged: (checked) {
                                                        setState(() {
                                                          if (checked == true) {
                                                            _selectedUsers.add(
                                                              user,
                                                            );
                                                          } else {
                                                            _selectedUsers
                                                                .remove(user);
                                                          }
                                                        });
                                                        Future.microtask(() async {
                                                          await FirebaseConfig.logEvent(
                                                            eventType: 'attendance_user_toggled',
                                                            description: 'Attendance user toggled',
                                                            userId: loggedInMobile,
                                                            details: {
                                                              'userName': user['name'],
                                                              'mobile': user['mobile'],
                                                              'selected': checked == true,
                                                            },
                                                          );
                                                        });
                                                      },
                                                      visualDensity:
                                                          VisualDensity.compact,
                                                      materialTapTargetSize:
                                                          MaterialTapTargetSize
                                                              .shrinkWrap,
                                                      controlAffinity:
                                                          ListTileControlAffinity
                                                              .leading,
                                                    );
                                                  },
                                                ),
                                              ),
                                            ],
                                          ),
                                  ],
                                ),
                        ),
                        SizedBox(width: 16),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
      floatingActionButton: null,
      bottomNavigationBar: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Row(
          children: [
            Expanded(
              child: SizedBox(
                height: 48,
                child: ElevatedButton(
                  onPressed: () async {
                    await FirebaseConfig.logEvent(
                      eventType: 'attendance_mark_clicked',
                      description: 'Attendance mark clicked',
                      userId: loggedInMobile,
                      details: {
                        'selectedUsers': _selectedUsers.length,
                        'topics': _selectedTopics,
                        'place': _places.firstWhere((p) => p['placeName'] == _selectedPlace, orElse: () => <String, dynamic>{'locationEn': _selectedPlace ?? ''})['locationEn'],
                      },
                    );
                    if (_selectedTopics.isEmpty) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text('कृपया किमान एक विषय निवडा'),
                        ),
                      );
                      return;
                    }
                    if (_selectedPlace == null) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text('कृपया ठिकाण निवडा')),
                      );
                      return;
                    }
                    if (_selectedUsers.isEmpty) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text('कृपया किमान एक वापरकर्ता निवडा'),
                        ),
                      );
                      return;
                    }

                    final selectedPlaceData = _places.firstWhere(
                      (p) => p['placeName'] == _selectedPlace,
                      orElse: () => <String, dynamic>{'locationEn': _selectedPlace ?? '', 'locationMr': _selectedPlace ?? ''},
                    );
                    try {
                      int addedCount = 0;
                      int duplicateCount = 0;
                      String duplicateNames = '';
                      final monthKey =
                          AttendanceSupport.monthYearKey(_selectedDate);
                      for (final user in _selectedUsers) {
                        final dateKey =
                            '${_selectedDate.year.toString().padLeft(4, '0')}${_selectedDate.month.toString().padLeft(2, '0')}${_selectedDate.day.toString().padLeft(2, '0')}';
                        final invertedDate = 99999999 - int.parse(dateKey);
                        final docId = '${invertedDate}_${user['uid']}';
                        final docRef = _secondaryFirestore!
                            .collection('Attendance')
                            .doc(monthKey)
                            .collection('records')
                            .doc(docId);
                        final existing = await docRef.get();
                        if (existing.exists) {
                          duplicateCount++;
                          duplicateNames += '${user['name']}, ';
                          print(
                            'Duplicate attendance for ${user['name']} on ${_selectedDate.toLocal().toString().split(' ')[0]}',
                          );
                          continue;
                        }
                        final userName = (user['name'] ?? '').toString();
                        final userNameMr = (user['name_mr'] ?? '').toString();
                        final userZone = (user['zone'] ?? '').toString();
                        final userZoneMr = (user['zone_mr'] ?? '').toString();
                        await docRef.set({
                          'date': Timestamp.fromDate(_selectedDate),
                          'time': DateTime.now().toLocal().toString().split(
                            ' ',
                          )[1],
                          'status': 'Present',
                          'Topic': _selectedTopics.join(', '),
                          'work_hours': _workHoursController.text.trim(),
                          'Location_En': selectedPlaceData['locationEn'] ?? '',
                          'Location_Mr': selectedPlaceData['locationMr'] ?? '',
                          'zone': user['zone'],
                          // zone is usually already Marathi (e.g. "झोन 1"), but
                          // custom/imported zones can be English ("Zone 1") with
                          // no zone_mr filled in — derive Marathi from the number.
                          'zone_mr': userZoneMr.isNotEmpty
                              ? userZoneMr
                              : AttendanceSupport.toMarathiZoneLabel(userZone),
                          'name': user['name'],
                          // name_mr is optional at registration — fall back to a
                          // best-effort transliteration rather than leaving it blank.
                          'name_mr': userNameMr.isNotEmpty
                              ? userNameMr
                              : TransliterationService.toDevanagari(userName),
                          'userId': user['uid'],
                          'mobile': MobileEncryptionService.encrypt(
                                (user['mobile'] ?? '').toString(),
                              ) ??
                              user['mobile'],
                          'baithak': user['baithak'] ?? '',
                          'hajeri_kramank': user['hajeri_kramank'] ?? '',
                        });
                        print(
                          'Attendance record added for ${user['name']}: $docId',
                        );
                        addedCount++;
                      }
                      String msg = '';
                      if (addedCount > 0) {
                        msg += '$addedCount वापरकर्त्यांची उपस्थिती नोंदवली. ';
                        await FirebaseConfig.logEvent(
                          eventType: 'attendance_marked',
                          description: 'Attendance marked',
                          isImportant: true,
                          details: {
                            'count': addedCount,
                            'users': _selectedUsers.map((u) => u['name']).toList(),
                            'date': _selectedDate.toIso8601String(),
                            'place': selectedPlaceData['locationEn'],
                            'topics': _selectedTopics,
                          },
                        );
                      }
                      if (duplicateCount > 0) {
                        msg +=
                            'आधीच नोंदवलेले: ${duplicateNames.substring(0, duplicateNames.length - 2)}. ';
                        await FirebaseConfig.logEvent(
                          eventType: 'attendance_duplicate',
                          description: 'Duplicate attendance entries',
                          isImportant: true,
                          details: {
                            'count': duplicateCount,
                            'names': duplicateNames,
                            'date': _selectedDate.toIso8601String(),
                          },
                        );
                      }
                      if (msg.isNotEmpty) {
                        setState(() {
                          _errorMessage = msg;
                        });
                      }
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text(
                            msg.isEmpty ? 'कोणतीही उपस्थिती नोंदवली नाही.' : msg,
                          ),
                        ),
                      );
                      setState(() {
                        _selectedUsers = [];
                      });
                    } catch (e) {
                      await FirebaseConfig.logEvent(
                        eventType: 'attendance_error',
                        description: 'Error marking attendance',
                        details: {
                          'error': e.toString(),
                          'date': _selectedDate.toIso8601String(),
                          'place': selectedPlaceData['locationEn'],
                          'topics': _selectedTopics,
                        },
                      );
                      print('Error marking attendance: $e');
                      print('Stack trace: ${StackTrace.current}');
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text('उपस्थिती नोंदवताना त्रुटी: $e'),
                        ),
                      );
                    }
                  },
                  child: Text(
                    'उपस्थिती नोंदवा',
                    style: TextStyle(fontSize: 14),
                  ),
                ),
              ),
            ),
            SizedBox(width: 16),
            Expanded(
              child: SizedBox(
                height: 48,
                child: ElevatedButton(
                  onPressed: () async {
                    await FirebaseConfig.logEvent(
                      eventType: 'attendance_view_clicked',
                      description: 'Attendance view clicked',
                      userId: loggedInMobile,
                    );
                    DateTime startDate = DateTime.now();
                    DateTime endDate = DateTime.now();
                    String? selectedPlace = _places.isNotEmpty
                        ? _places[0]['placeName'] as String
                        : null;
                    String? selectedZone =
                        _isSuperAdmin ? _selectedZone : _currentZone;

                    int currentYear = DateTime.now().year;
                    List<int> yearsList = List.generate(
                      currentYear - 2020 + 1,
                      (i) => 2020 + i,
                    );
                    int selectedYear = currentYear;

                    bool useStartDate = true;
                    bool useEndDate = true;

                    bool usePlace = false;
                    bool useZone = false;
                    await showDialog(
                      context: context,
                      builder: (context) {
                        return StatefulBuilder(
                          builder: (context, setState) {
                            return AlertDialog(
                              title: Text('उपस्थिती पहा'),
                              content: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  DropdownButtonFormField<int>(
                                    decoration: InputDecoration(
                                      labelText: 'वर्ष',
                                      border: OutlineInputBorder(),
                                    ),
                                    value: selectedYear,
                                    items: yearsList
                                        .map(
                                          (y) => DropdownMenuItem(
                                            value: y,
                                            child: Text('वर्ष $y'),
                                          ),
                                        )
                                        .toList(),
                                    onChanged: (val) {
                                      if (val != null) {
                                        setState(() {
                                          selectedYear = val;
                                        });
                                      }
                                    },
                                  ),
                                  Row(
                                    children: [
                                      Checkbox(
                                        value: useStartDate ?? true,
                                        onChanged: (checked) {
                                          setState(() {
                                            useStartDate = checked ?? true;
                                          });
                                        },
                                      ),
                                      Expanded(
                                        child: ListTile(
                                          title: Text(
'प्रारंभ तारीख: ${startDate.year.toString().padLeft(4, '0')}-${startDate.month.toString().padLeft(2, '0')}-${startDate.day.toString().padLeft(2, '0')}',
),
                                          trailing: Icon(Icons.calendar_today),
                                          onTap: () async {
                                            final earliest = DateTime(2000);
                                            final latest =
                                                DateTime(
                                                  selectedYear,
                                                  12,
                                                  31,
                                                ).isAfter(DateTime.now())
                                                ? DateTime.now()
                                                : DateTime(
                                                    selectedYear,
                                                    12,
                                                    31,
                                                  );
                                            DateTime validInitialDate =
                                                startDate;
                                            if (validInitialDate.isBefore(
                                              earliest,
                                            )) {
                                              validInitialDate = earliest;
                                            }
                                            if (validInitialDate.isAfter(
                                              latest,
                                            )) {
                                              validInitialDate = latest;
                                            }
                                            final picked =
                                                await AttendanceSupport.selectDate(
                                                  context,
                                                  validInitialDate,
                                                );
                                            if (picked != null) {
                                              setState(() {
                                                startDate = picked;
                                              });
                                            }
                                          },
                                        ),
                                      ),
                                    ],
                                  ),
                                  Row(
                                    children: [
                                      Checkbox(
                                        value: useEndDate ?? true,
                                        onChanged: (checked) {
                                          setState(() {
                                            useEndDate = checked ?? true;
                                          });
                                        },
                                      ),
                                      Expanded(
                                        child: ListTile(
                                          title: Text(
'समाप्ती तारीख: ${endDate.year.toString().padLeft(4, '0')}-${endDate.month.toString().padLeft(2, '0')}-${endDate.day.toString().padLeft(2, '0')}',
),
                                          trailing: Icon(Icons.calendar_today),
                                          onTap: () async {
                                            final earliest = DateTime(2000);
                                            final latest =
                                                DateTime(
                                                  selectedYear,
                                                  12,
                                                  31,
                                                ).isAfter(DateTime.now())
                                                ? DateTime.now()
                                                : DateTime(
                                                    selectedYear,
                                                    12,
                                                    31,
                                                  );
                                            DateTime validInitialDate = endDate;
                                            if (validInitialDate.isBefore(
                                              earliest,
                                            )) {
                                              validInitialDate = earliest;
                                            }
                                            if (validInitialDate.isAfter(
                                              latest,
                                            )) {
                                              validInitialDate = latest;
                                            }
                                            final picked =
                                                await AttendanceSupport.selectDate(
                                                  context,
                                                  validInitialDate,
                                                );
                                            if (picked != null) {
                                              setState(() {
                                                endDate = picked;
                                              });
                                            }
                                          },
                                        ),
                                      ),
                                    ],
                                  ),
                                  Row(
                                    children: [
                                      Checkbox(
                                        value: usePlace ?? false,
                                        onChanged: (checked) {
                                          setState(() {
                                            usePlace = checked ?? false;
                                          });
                                        },
                                      ),
                                      Expanded(
                                        child: DropdownButtonFormField<String>(
                                          decoration: InputDecoration(
                                            labelText: 'ठिकाण',
                                            border: OutlineInputBorder(),
                                          ),
                                          value: selectedPlace,
                                          isExpanded: true,
                                          items: _places.map((place) {
                                            return DropdownMenuItem(
                                              value: place['placeName'] as String,
                                              child: Text(place['placeName'] as String),
                                            );
                                          }).toList(),
                                          onChanged: (value) {
                                            setState(() {
                                              selectedPlace = value;
                                            });
                                          },
                                        ),
                                      ),
                                    ],
                                  ),
                                  SizedBox(height: 8),
                                  Row(
                                    children: [
                                      Checkbox(
                                        value: useZone ?? false,
                                        onChanged: (checked) {
                                          setState(() {
                                            useZone = checked ?? false;
                                          });
                                        },
                                      ),
                                      Expanded(
                                        child: DropdownButtonFormField<String>(
                                          decoration: InputDecoration(
                                            labelText: 'झोन',
                                            border: OutlineInputBorder(),
                                          ),
                                          value: selectedZone,
                                          menuMaxHeight: 300,
                                          isExpanded: true,
                                          items: (_isSuperAdmin
                                                  ? _zones
                                                  : _zoneUsers
                                                      .map(
                                                        (u) =>
                                                            u['zone']
                                                                ?.toString() ??
                                                            '',
                                                      )
                                                      .toSet()
                                                      .toList())
                                              .where((z) => z.isNotEmpty)
                                              .map(
                                                (zone) =>
                                                    DropdownMenuItem<String>(
                                                      value: zone,
                                                      child: Text(zone),
                                                    ),
                                              )
                                              .toList(),
                                          onChanged: (value) {
                                            setState(() {
                                              selectedZone = value;
                                            });
                                          },
                                        ),
                                      ),
                                    ],
                                  ),
                                  SizedBox(height: 16),
                                  ElevatedButton(
                                    child: Text('उपस्थिती दर्शवा'),
                                    onPressed: () async {
                                      await FirebaseConfig.logEvent(
                                        eventType: 'attendance_show_clicked',
                                        description: 'Attendance show clicked',
                                        userId: loggedInMobile,
                                      );
                                      if (_secondaryFirestore == null) {
                                        ScaffoldMessenger.of(
                                          context,
                                        ).showSnackBar(
                                          SnackBar(
                                            content: Text(
                                              'कृपया थांबा, Firebase सुरू होत आहे.',
                                            ),
                                          ),
                                        );
                                        return;
                                      }
                                      final logPlace =
                                          usePlace ? selectedPlace : null;
                                      final logZone =
                                          useZone ? selectedZone : null;
                                      print(
                                        '[AttendancePage] Show Attendance: year=$selectedYear, place="$logPlace", zone="$logZone", startDate=${useStartDate ? startDate : null}, endDate=${useEndDate ? endDate : null}',
                                      );
                                      Navigator.push(
                                        context,
                                        MaterialPageRoute(
                                          builder: (context) =>
                                              AttendanceDetails(
                                                year: selectedYear,
                                                place: usePlace
                                                    ? selectedPlace
                                                    : null,
                                                zone: useZone ? selectedZone : null,
                                                firestore: _secondaryFirestore!,
                                                startDate: useStartDate
                                                    ? startDate
                                                    : null,
                                                endDate: useEndDate
                                                    ? endDate
                                                    : null,
                                              ),
                                        ),
                                      );
                                    },
                                  ),
                                  SizedBox(height: 8),
                                  ElevatedButton.icon(
                                    icon: Icon(Icons.download),
                                    label: Text('यादी डाउनलोड करा'),
                                    onPressed: () async {
                                      await FirebaseConfig.logEvent(
                                        eventType: 'attendance_download_clicked',
                                        description: 'Attendance download clicked',
                                        userId: loggedInMobile,
                                      );
                                      if (_secondaryFirestore == null) {
                                        ScaffoldMessenger.of(context).showSnackBar(
                                          SnackBar(
                                            content: Text('Please wait, Firebase is still initializing.'),
                                          ),
                                        );
                                        return;
                                      }
                                      final dialogPlaceData = _places.firstWhere(
                                        (p) => p['placeName'] == selectedPlace,
                                        orElse: () => <String, dynamic>{'placeName': selectedPlace ?? '', 'locationEn': selectedPlace ?? '', 'locationMr': selectedPlace ?? ''},
                                      );
                                      final normalizedSelectedPlace =
                                          (dialogPlaceData['locationMr'] ?? selectedPlace ?? '')
                                              .trim()
                                              .toLowerCase()
                                              .replaceAll(RegExp(r'\s+'), ' ');
                                      final normalizedSelectedZoneRaw =
                                          (selectedZone ?? '')
                                              .trim()
                                              .toLowerCase();
                                      final normalizedSelectedZoneDigits =
                                          RegExp(r'(\d+)')
                                                  .firstMatch(
                                                    normalizedSelectedZoneRaw,
                                                  )
                                                  ?.group(1) ??
                                              '';
                                      final normalizedSelectedZone =
                                          normalizedSelectedZoneDigits
                                                  .isNotEmpty
                                              ? int.tryParse(
                                                    normalizedSelectedZoneDigits,
                                                  )?.toString() ??
                                                  normalizedSelectedZoneDigits
                                              : normalizedSelectedZoneRaw;
                                      final downloadStart = useStartDate
                                          ? startDate
                                          : DateTime(selectedYear, 1, 1);
                                      final downloadEnd = useEndDate
                                          ? endDate
                                          : DateTime(
                                              selectedYear,
                                              12,
                                              31,
                                              23,
                                              59,
                                              59,
                                            );
                                      final monthKeys =
                                          AttendanceSupport.monthYearKeysBetween(
                                        downloadStart,
                                        downloadEnd,
                                      );
                                      final allRecords =
                                          <Map<String, dynamic>>[];
                                      for (final key in monthKeys) {
                                        final snapshot = await _secondaryFirestore!
                                            .collection('Attendance')
                                            .doc(key)
                                            .collection('records')
                                            .where(
                                              'date',
                                              isGreaterThanOrEqualTo:
                                                  Timestamp.fromDate(
                                                    downloadStart,
                                                  ),
                                            )
                                            .where(
                                              'date',
                                              isLessThanOrEqualTo:
                                                  Timestamp.fromDate(
                                                    downloadEnd,
                                                  ),
                                            )
                                            .get();
                                        for (final doc in snapshot.docs) {
                                          allRecords.add(doc.data());
                                        }
                                      }
                                      final records = allRecords.where((data) {
                                        // Filter by year, start date, end date, place, and zone
                                        final date = data['date'];
                                        DateTime? dt;
                                        if (date is Timestamp) {
                                          dt = date.toDate();
                                        } else if (date is DateTime) {
                                          dt = date;
                                        }
                                        if (dt == null) return false;
                                        if (useStartDate && dt.isBefore(startDate)) return false;
                                        if (useEndDate && dt.isAfter(endDate)) return false;
                                        if (usePlace &&
                                            normalizedSelectedPlace.isNotEmpty) {
                                          final recordPlace =
                                              (data['Location_Mr'] ?? data['Place'] ?? '')
                                                  .toString()
                                                  .trim()
                                                  .toLowerCase()
                                                  .replaceAll(
                                                    RegExp(r'\s+'),
                                                    ' ',
                                                  );
                                          if (recordPlace !=
                                              normalizedSelectedPlace) {
                                            return false;
                                          }
                                        }
                                        if (useZone &&
                                            normalizedSelectedZone.isNotEmpty) {
                                          final recordZoneRaw =
                                              (data['zone'] ?? '')
                                                  .toString()
                                                  .trim()
                                                  .toLowerCase();
                                          final recordZoneDigits =
                                              RegExp(r'(\d+)')
                                                      .firstMatch(
                                                        recordZoneRaw,
                                                      )
                                                      ?.group(1) ??
                                                  '';
                                          final recordZone =
                                              recordZoneDigits.isNotEmpty
                                                  ? int.tryParse(
                                                        recordZoneDigits,
                                                      )?.toString() ??
                                                      recordZoneDigits
                                                  : recordZoneRaw;
                                          if (recordZone !=
                                              normalizedSelectedZone) {
                                            return false;
                                          }
                                        }
                                        // Only filter by year if not using date range
                                        if (!(useStartDate || useEndDate) && dt.year != selectedYear) return false;
                                        return true;
                                      }).toList();
                                      if (records.isEmpty) {
                                        ScaffoldMessenger.of(context).showSnackBar(
                                          SnackBar(content: Text('निवडलेल्या फिल्टरसाठी कोणतीही उपस्थिती नोंद आढळली नाही.')),
                                        );
                                        return;
                                      }
                                      String excelMarathiDay(DateTime dt) {
                                        const days = ['सोमवार', 'मंगळवार', 'बुधवार', 'गुरुवार', 'शुक्रवार', 'शनिवार', 'रविवार'];
                                        return days[dt.weekday - 1];
                                      }
                                      String excelEnglishDay(DateTime dt) {
                                        const days = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];
                                        return days[dt.weekday - 1];
                                      }
                                      String excelEnglishMonth(DateTime dt) {
                                        const months = ['January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October', 'November', 'December'];
                                        return months[dt.month - 1];
                                      }
                                      DateTime? firstDt;
                                      final firstDateVal = records.isNotEmpty ? records.first['date'] : null;
                                      if (firstDateVal is Timestamp) firstDt = firstDateVal.toDate();
                                      else if (firstDateVal is DateTime) firstDt = firstDateVal;
                                      firstDt ??= DateTime.now();
                                      final headerPlace = (selectedPlace?.isNotEmpty == true)
                                          ? (dialogPlaceData['locationMr'] ?? selectedPlace!)
                                          : (records.isNotEmpty ? (records.first['Location_Mr']?.toString() ?? records.first['Place']?.toString() ?? '') : '');
                                      // Lookup baithak/hajeri_kramank from main users collection for old records
                                      final needsLookupIds = records
                                          .where((r) => (r['baithak'] ?? '').toString().trim().isEmpty || (r['hajeri_kramank'] ?? '').toString().trim().isEmpty)
                                          .map((r) => r['userId']?.toString().trim() ?? '')
                                          .where((id) => id.isNotEmpty)
                                          .toSet()
                                          .toList();
                                      final userLookup = <String, Map<String, dynamic>>{};
                                      if (needsLookupIds.isNotEmpty) {
                                        for (int i = 0; i < needsLookupIds.length; i += 30) {
                                          final chunk = needsLookupIds.sublist(i, (i + 30).clamp(0, needsLookupIds.length));
                                          final snap = await widget.userFirestore.collection('users').where('uid', whereIn: chunk).get();
                                          for (final doc in snap.docs) {
                                            final d = doc.data();
                                            userLookup[d['uid']?.toString() ?? doc.id] = d;
                                          }
                                        }
                                      }
                                      String getBaithak(Map<String, dynamic> r) {
                                        final v = r['baithak']?.toString().trim() ?? '';
                                        if (v.isNotEmpty) return v;
                                        final uid = r['userId']?.toString().trim() ?? '';
                                        return userLookup[uid]?['baithakPlace']?.toString() ?? '';
                                      }
                                      String getHajeriKramank(Map<String, dynamic> r) {
                                        final v = r['hajeri_kramank']?.toString().trim() ?? '';
                                        if (v.isNotEmpty) return v;
                                        final uid = r['userId']?.toString().trim() ?? '';
                                        return userLookup[uid]?['baithakNo']?.toString() ?? '';
                                      }
                                      final excel = Excel.createExcel();
                                      final sheet = excel['Attendance'];
                                      const _cols = ['A', 'B', 'C', 'D', 'E', 'F', 'G'];

                                      // Row 1: || श्री || — centered across all 7 columns
                                      sheet.merge(CellIndex.indexByString('A1'), CellIndex.indexByString('G1'));
                                      final c1 = sheet.cell(CellIndex.indexByString('A1'));
                                      c1.value = TextCellValue('|| श्री ||');
                                      c1.cellStyle = CellStyle(horizontalAlign: HorizontalAlign.Center);

                                      // Row 2: || श्री राम समर्थ || — centered
                                      sheet.merge(CellIndex.indexByString('A2'), CellIndex.indexByString('G2'));
                                      final c2 = sheet.cell(CellIndex.indexByString('A2'));
                                      c2.value = TextCellValue('|| श्री राम समर्थ ||');
                                      c2.cellStyle = CellStyle(horizontalAlign: HorizontalAlign.Center);

                                      // Row 3: empty (spacer)

                                      // Row 4: Place (left, A4:D4) + Date (right, E4:G4)
                                      sheet.merge(CellIndex.indexByString('A4'), CellIndex.indexByString('D4'));
                                      final placeCell = sheet.cell(CellIndex.indexByString('A4'));
                                      placeCell.value = TextCellValue('श्री सेवेचे ठिकाण: $headerPlace');

                                      sheet.merge(CellIndex.indexByString('E4'), CellIndex.indexByString('G4'));
                                      final dateCell = sheet.cell(CellIndex.indexByString('E4'));
                                      final String excelDateHeader;
                                      if (!useStartDate && !useEndDate) {
                                        excelDateHeader = 'दि. $selectedYear';
                                      } else if (useStartDate && useEndDate &&
                                          startDate.year == endDate.year &&
                                          startDate.month == endDate.month &&
                                          startDate.day == endDate.day) {
                                        excelDateHeader = 'दि. ${excelEnglishDay(startDate)}, ${excelEnglishMonth(startDate)} ${startDate.day}, ${startDate.year}';
                                      } else {
                                        final rangeStart = useStartDate ? startDate : DateTime(selectedYear, 1, 1);
                                        final rangeEnd = useEndDate ? endDate : DateTime(selectedYear, 12, 31);
                                        excelDateHeader = 'दि. ${excelEnglishMonth(rangeStart)} ${rangeStart.day}, ${rangeStart.year} - ${excelEnglishMonth(rangeEnd)} ${rangeEnd.day}, ${rangeEnd.year}';
                                      }
                                      dateCell.value = TextCellValue(excelDateHeader);
                                      dateCell.cellStyle = CellStyle(horizontalAlign: HorizontalAlign.Right);

                                      // Row 5: empty (spacer)

                                      // Row 6: Column headers with black borders
                                      final _hdrs = ['क्रमांक', 'नाव', 'मराठी नाव', 'बैठक', 'वार', 'हजेरी क्रमांक', 'काम'];
                                      for (int i = 0; i < _hdrs.length; i++) {
                                        final hc = sheet.cell(CellIndex.indexByString('${_cols[i]}6'));
                                        hc.value = TextCellValue(_hdrs[i]);
                                        hc.cellStyle = CellStyle(
                                          bold: true,
                                          leftBorder: xl.Border(borderStyle: xl.BorderStyle.Thin),
                                          rightBorder: xl.Border(borderStyle: xl.BorderStyle.Thin),
                                          topBorder: xl.Border(borderStyle: xl.BorderStyle.Thin),
                                          bottomBorder: xl.Border(borderStyle: xl.BorderStyle.Thin),
                                        );
                                      }

                                      // Data rows from row 7 with black borders
                                      int serial = 1;
                                      int dataRow = 7;
                                      for (final record in records) {
                                        DateTime? recDt;
                                        final dv = record['date'];
                                        if (dv is Timestamp) recDt = dv.toDate();
                                        else if (dv is DateTime) recDt = dv;
                                        final rowVals = [
                                          '$serial',
                                          record['name']?.toString() ?? '',
                                          record['name_mr']?.toString() ?? '',
                                          getBaithak(record),
                                          recDt != null ? excelMarathiDay(recDt) : '',
                                          getHajeriKramank(record),
                                          record['Topic']?.toString() ?? '',
                                        ];
                                        for (int i = 0; i < rowVals.length; i++) {
                                          final dc = sheet.cell(CellIndex.indexByString('${_cols[i]}$dataRow'));
                                          dc.value = TextCellValue(rowVals[i]);
                                          dc.cellStyle = CellStyle(
                                            leftBorder: xl.Border(borderStyle: xl.BorderStyle.Thin),
                                            rightBorder: xl.Border(borderStyle: xl.BorderStyle.Thin),
                                            topBorder: xl.Border(borderStyle: xl.BorderStyle.Thin),
                                            bottomBorder: xl.Border(borderStyle: xl.BorderStyle.Thin),
                                          );
                                        }
                                        serial++;
                                        dataRow++;
                                      }
                                      final filterParts = <String>[
                                        'attendance',
                                        selectedYear.toString(),
                                      ];
                                      if (useStartDate) filterParts.add('from${_formatDateTime(startDate)}');
                                      if (useEndDate) filterParts.add('to${_formatDateTime(endDate)}');
                                      if (usePlace && normalizedSelectedPlace.isNotEmpty) filterParts.add('place${normalizedSelectedPlace.replaceAll(RegExp(r'\s+'), '')}');
                                      if (useZone && normalizedSelectedZone.isNotEmpty) filterParts.add('zone$normalizedSelectedZone');
                                      filterParts.add(_formatDateTime(DateTime.now()));
                                      final fileName = filterParts.join('_').replaceAll(RegExp(r'[^\w\d]'), '') + '.xlsx';

                                      final tempDir = await getTemporaryDirectory();
                                      final tempFile = File('${tempDir.path}/$fileName');
                                      await tempFile.writeAsBytes(excel.encode()!);

                                      await FirebaseConfig.logEvent(
                                        eventType: 'attendance_list_downloaded',
                                        description: 'Attendance List downloaded as Excel',
                                        details: {
                                          'timestamp': DateTime.now().toIso8601String(),
                                          'type': 'attendance',
                                          'filters': {
                                            'year': selectedYear,
                                            'place': dialogPlaceData['locationEn'],
                                            'zone': selectedZone,
                                            'startDate': useStartDate ? startDate.toIso8601String() : null,
                                            'endDate': useEndDate ? endDate.toIso8601String() : null,
                                          },
                                        },
                                      );
                                      await Share.shareXFiles(
                                        [XFile(tempFile.path, mimeType: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet')],
                                        subject: fileName,
                                      );
                                    },
                                  ),
                                ],
                              ),
                              actions: [
                                TextButton(
                                  child: Text('बंद करा'),
                                  onPressed: () async {
                                    await FirebaseConfig.logEvent(
                                      eventType: 'attendance_view_closed',
                                      description: 'Attendance view closed',
                                      userId: loggedInMobile,
                                    );
                                    Navigator.of(context).pop();
                                  },
                                ),
                              ],
                            );
                          },
                        );
                      },
                    );
                  },
                  child: Text(
                    'उपस्थिती पहा',
                    style: TextStyle(fontSize: 14),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _AddUserBottomSheet extends StatefulWidget {
  final List<String> zones;
  final String? prefilledZone;
  final FirebaseFirestore userFirestore;

  const _AddUserBottomSheet({
    required this.zones,
    required this.userFirestore,
    this.prefilledZone,
  });

  @override
  State<_AddUserBottomSheet> createState() => _AddUserBottomSheetState();
}

class _AddUserBottomSheetState extends State<_AddUserBottomSheet> {
  static const String _customZoneValue = '__custom__';

  final _nameCtrl        = TextEditingController();
  final _nameMrCtrl      = TextEditingController();
  final _mobileCtrl      = TextEditingController();
  final _baithakNoCtrl   = TextEditingController();
  final _baithakPlaceCtrl= TextEditingController();
  final _baithakMrCtrl   = TextEditingController();
  final _zoneCtrl        = TextEditingController();
  final _zoneMrCtrl      = TextEditingController();
  final _hallCtrl        = TextEditingController();
  final _hallMrCtrl      = TextEditingController();
  final _emailCtrl       = TextEditingController();
  final _passwordCtrl    = TextEditingController();
  final _dobCtrl         = TextEditingController();

  String? _selectedZoneChoice;
  String? _selectedGender;
  String? _selectedBaithakDay;
  Map<String, String> _errors = {};
  bool _isSubmitting = false;

  // Tracks whether the user has manually edited an auto-filled Marathi
  // field, so we stop overwriting it as they keep typing the English side.
  bool _nameMrTouched = false;
  bool _baithakMrTouched = false;
  bool _hallMrTouched = false;
  bool _zoneMrTouched = false;

  static const Map<String, String> _baithakDayMr = {
    'Monday': 'सोमवार',
    'Tuesday': 'मंगळवार',
    'Wednesday': 'बुधवार',
    'Thursday': 'गुरुवार',
    'Friday': 'शुक्रवार',
    'Saturday': 'शनिवार',
    'Sunday': 'रविवार',
  };

  @override
  void initState() {
    super.initState();
    _selectedZoneChoice = widget.prefilledZone;
    _zoneCtrl.text = widget.prefilledZone ?? '';
    PlaceNameService.fetchAll();
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

  void _autoFillZoneMr(String zone) {
    if (_zoneMrTouched) return;
    setState(() => _zoneMrCtrl.text = AttendanceSupport.toMarathiZoneLabel(zone));
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _nameMrCtrl.dispose();
    _mobileCtrl.dispose();
    _baithakNoCtrl.dispose();
    _baithakPlaceCtrl.dispose();
    _baithakMrCtrl.dispose();
    _zoneCtrl.dispose();
    _zoneMrCtrl.dispose();
    _hallCtrl.dispose();
    _hallMrCtrl.dispose();
    _emailCtrl.dispose();
    _passwordCtrl.dispose();
    _dobCtrl.dispose();
    super.dispose();
  }

  bool _validateName(String v)        => RegExp(r'^[A-Za-zऀ-ॿ ]+$').hasMatch(v.trim());
  bool _validateMobile(String v)      => RegExp(r'^[0-9]{10}$').hasMatch(v.replaceAll(RegExp(r'\D'), ''));
  bool _validateBaithakNo(String v)   => v.trim().isNotEmpty;
  bool _validateBaithakPlace(String v)=> v.trim().isNotEmpty;
  bool _validateZone(String v)        => RegExp(r'(\d+)$').firstMatch(v.trim()) != null;
  bool _validateEmail(String v)       => RegExp(r'^[\w-\.]+@([\w-]+\.)+[\w-]{2,4}$').hasMatch(v.trim());
  bool _validatePassword(String v)    => RegExp(r'^(?=.*[A-Za-z])(?=.*\d)(?=.*[@$!%*#?&])[A-Za-z\d@$!%*#?&]{8,}$').hasMatch(v);

  String _normalizeZone(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) return trimmed;
    if (trimmed.toLowerCase().startsWith('zone') || trimmed.startsWith('झोन')) {
      return trimmed;
    }
    return 'Zone $trimmed';
  }

  Future<void> _submit() async {
    final name        = _nameCtrl.text.trim();
    final nameMr      = _nameMrCtrl.text.trim();
    final mobile      = _mobileCtrl.text.replaceAll(RegExp(r'\D'), '');
    final baithakNo   = _baithakNoCtrl.text.trim();
    final baithakPlace= _baithakPlaceCtrl.text.trim();
    final baithakMr   = _baithakMrCtrl.text.trim();
    final baithakDay  = _selectedBaithakDay ?? '';
    final baithakDayMr= _baithakDayMr[baithakDay] ?? '';
    final chosenZone  = _selectedZoneChoice == _customZoneValue
        ? _zoneCtrl.text
        : _selectedZoneChoice ?? _zoneCtrl.text;
    final zone        = _normalizeZone(chosenZone);
    final zoneMr      = _zoneMrCtrl.text.trim();
    final hall        = _hallCtrl.text.trim();
    final hallMr      = _hallMrCtrl.text.trim();
    final gender      = _selectedGender ?? '';
    final dob         = _dobCtrl.text.trim();
    final email       = _emailCtrl.text.trim();
    final password    = _passwordCtrl.text.trim();

    final errors = <String, String>{};
    if (!_validateName(name))         errors['name']        = 'नावात फक्त अक्षरे असावीत';
    if (!_validateMobile(mobile))     errors['mobile']      = 'मोबाइल नंबर १० अंकी असावा';
    if (!_validateBaithakNo(baithakNo))     errors['baithakNo']   = 'बैठक क्रमांक आवश्यक आहे';
    if (!_validateBaithakPlace(baithakPlace)) errors['baithakPlace']= 'बैठक ठिकाण आवश्यक आहे';
    if (!_validateZone(zone))         errors['zone']        = 'झोन अंकी असावा';
    if (!_validateEmail(email))       errors['email']       = 'वैध ईमेल पत्ता प्रविष्ट करा';
    if (!_validatePassword(password)) errors['password']    = 'पासवर्ड किमान ८ अक्षरांचा, अक्षर, संख्या आणि विशेष वर्ण असावे';

    setState(() => _errors = errors);
    if (errors.isNotEmpty) return;

    setState(() => _isSubmitting = true);

    // Check duplicate mobile (mobile is stored encrypted, so match on that)
    final encryptedMobile = MobileEncryptionService.encrypt(mobile) ?? mobile;
    final dup = await widget.userFirestore
        .collection('users')
        .where('mobile', isEqualTo: encryptedMobile)
        .get();
    if (dup.docs.isNotEmpty) {
      setState(() {
        _errors['mobile'] = 'मोबाइल नंबर आधीच नोंदणीकृत आहे';
        _isSubmitting = false;
      });
      return;
    }

    // Create Firebase Auth account
    String? authUid;
    try {
      final cred = await FirebaseAuth.instance.createUserWithEmailAndPassword(
        email: email,
        password: password,
      );
      authUid = cred.user?.uid;
    } catch (e) {
      setState(() {
        _errors['email'] = 'ईमेल नोंदणी अयशस्वी: $e';
        _isSubmitting = false;
      });
      return;
    }

    // Write user to Firestore
    try {
      final invertedMs = 9999999999999 - DateTime.now().millisecondsSinceEpoch;
      String? fcmToken = await FirebaseMessaging.instance.getToken();
      // 'uid' is a clean sequential display ID (for reports/attendance);
      // 'authUid' is the real Firebase Auth ID, kept separately so account
      // cleanup (deleteAuthOnUserDelete) can still find the login account.
      final sequentialUid = await UserIdService.nextId();
      final userDocId = '${invertedMs}_$sequentialUid';
      await widget.userFirestore.collection('users').doc(userDocId).set({
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

      await FirebaseConfig.logEvent(
        eventType: 'register_success_from_attendance',
        description: 'User registered from attendance page',
        details: {'name': name, 'mobile': mobile, 'zone': zone},
        isImportant: true,
      );

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('$name यांची यशस्वीरित्या नोंदणी केली')),
        );
        Navigator.pop(context, true);
      }
    } catch (e) {
      setState(() {
        _errors['general'] = 'त्रुटी: $e';
        _isSubmitting = false;
      });
    }
  }

  Widget _buildField(
    String label,
    TextEditingController ctrl,
    String? error, {
    TextInputType? keyboardType,
    bool obscure = false,
    void Function(String)? onChanged,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          controller: ctrl,
          decoration: InputDecoration(
            labelText: label,
            border: const OutlineInputBorder(),
            errorText: error,
          ),
          keyboardType: keyboardType,
          obscureText: obscure,
          onChanged: onChanged,
        ),
        const SizedBox(height: 12),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        left: 16,
        right: 16,
        top: 16,
        bottom: MediaQuery.of(context).viewInsets.bottom + 24,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text(
                  'नवीन वापरकर्ता जोडा',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                ),
                IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: () => Navigator.pop(context),
                ),
              ],
            ),
            const Divider(),
            const SizedBox(height: 8),
            _buildField('पूर्ण नाव (Full Name)', _nameCtrl, _errors['name'], onChanged: (v) {
              setState(() => _validateName(v) ? _errors.remove('name') : _errors['name'] = 'नावात फक्त अक्षरे असावीत');
              _autoFillPhonetic(_nameMrCtrl, _nameMrTouched, v);
            }),
            _buildField('पूर्ण नाव मराठी', _nameMrCtrl, null, onChanged: (_) => _nameMrTouched = true),
            _buildField('मोबाइल नंबर', _mobileCtrl, _errors['mobile'],
              keyboardType: TextInputType.phone,
              onChanged: (v) {
                setState(() => _validateMobile(v) ? _errors.remove('mobile') : _errors['mobile'] = 'मोबाइल नंबर १० अंकी असावा');
              },
            ),
            _buildField('बैठक क्रमांक', _baithakNoCtrl, _errors['baithakNo'], onChanged: (v) {
              setState(() => _validateBaithakNo(v) ? _errors.remove('baithakNo') : _errors['baithakNo'] = 'बैठक क्रमांक आवश्यक आहे');
            }),
            _buildField('बैठक ठिकाण', _baithakPlaceCtrl, _errors['baithakPlace'], onChanged: (v) {
              setState(() => _validateBaithakPlace(v) ? _errors.remove('baithakPlace') : _errors['baithakPlace'] = 'बैठक ठिकाण आवश्यक आहे');
              _autoFillPlace(_baithakMrCtrl, _baithakMrTouched, v);
            }),
            _buildField('बैठक ठिकाण मराठी', _baithakMrCtrl, null, onChanged: (_) => _baithakMrTouched = true),
            DropdownButtonFormField<String>(
              value: _selectedBaithakDay,
              decoration: const InputDecoration(
                labelText: 'बैठकीचा वार',
                border: OutlineInputBorder(),
              ),
              items: _baithakDayMr.entries
                  .map((e) => DropdownMenuItem(value: e.key, child: Text('${e.key} - ${e.value}')))
                  .toList(),
              onChanged: (val) => setState(() => _selectedBaithakDay = val),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              value: _selectedGender,
              decoration: const InputDecoration(
                labelText: 'लिंग',
                border: OutlineInputBorder(),
              ),
              items: const [
                DropdownMenuItem(value: 'Male', child: Text('Male - पुरुष')),
                DropdownMenuItem(value: 'Female', child: Text('Female - स्त्री')),
                DropdownMenuItem(value: 'Other', child: Text('Other - इतर')),
              ],
              onChanged: (val) => setState(() => _selectedGender = val),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _dobCtrl,
              readOnly: true,
              decoration: const InputDecoration(
                labelText: 'जन्मतारीख',
                border: OutlineInputBorder(),
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
                    _dobCtrl.text =
                        '${picked.year}-${picked.month.toString().padLeft(2, '0')}-${picked.day.toString().padLeft(2, '0')}';
                  });
                }
              },
            ),
            const SizedBox(height: 12),
            // Zone dropdown
            DropdownButtonFormField<String>(
              value: _selectedZoneChoice,
              decoration: InputDecoration(
                labelText: 'झोन',
                border: const OutlineInputBorder(),
                errorText: _errors['zone'],
              ),
              items: [
                ...widget.zones.map((z) => DropdownMenuItem(value: z, child: Text(z))),
                const DropdownMenuItem(value: _customZoneValue, child: Text('इतर')),
              ],
              onChanged: (val) {
                setState(() {
                  _selectedZoneChoice = val;
                  if (val != null && val != _customZoneValue) {
                    _zoneCtrl.text = val;
                    _validateZone(val) ? _errors.remove('zone') : _errors['zone'] = 'झोन अंकी असावा';
                    _autoFillZoneMr(val);
                  }
                });
              },
            ),
            if (_selectedZoneChoice == _customZoneValue) ...[
              const SizedBox(height: 8),
              TextField(
                controller: _zoneCtrl,
                decoration: const InputDecoration(
                  labelText: 'कस्टम झोन',
                  border: OutlineInputBorder(),
                ),
                onChanged: (v) {
                  final normalized = _normalizeZone(v);
                  setState(() {
                    _zoneCtrl.text = normalized;
                    _zoneCtrl.selection = TextSelection.fromPosition(TextPosition(offset: normalized.length));
                    _validateZone(normalized) ? _errors.remove('zone') : _errors['zone'] = 'झोन अंकी असावा';
                  });
                  _autoFillZoneMr(normalized);
                },
              ),
            ],
            const SizedBox(height: 12),
            _buildField('झोन मराठी', _zoneMrCtrl, null, onChanged: (_) => _zoneMrTouched = true),
            _buildField('हॉल', _hallCtrl, null, onChanged: (v) => _autoFillPlace(_hallMrCtrl, _hallMrTouched, v)),
            _buildField('हॉल मराठी', _hallMrCtrl, null, onChanged: (_) => _hallMrTouched = true),
            _buildField('ईमेल', _emailCtrl, _errors['email'],
              keyboardType: TextInputType.emailAddress,
              onChanged: (v) {
                setState(() => _validateEmail(v) ? _errors.remove('email') : _errors['email'] = 'वैध ईमेल पत्ता प्रविष्ट करा');
              },
            ),
            _buildField('पासवर्ड', _passwordCtrl, _errors['password'],
              obscure: true,
              onChanged: (v) {
                setState(() => _validatePassword(v) ? _errors.remove('password') : _errors['password'] = 'पासवर्ड किमान ८ अक्षरांचा, अक्षर, संख्या आणि विशेष वर्ण असावे');
              },
            ),
            if (_errors['general'] != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(_errors['general']!, style: const TextStyle(color: Colors.red)),
              ),
            SizedBox(
              width: double.infinity,
              height: 48,
              child: ElevatedButton(
                onPressed: _isSubmitting ? null : _submit,
                child: _isSubmitting
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                      )
                    : const Text('नोंदणी करा'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
