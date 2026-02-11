import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:excel/excel.dart' hide Border;
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'main.dart';
import 'attendance_support.dart';
import 'attendance_details.dart';
import 'firebase_config.dart';

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
  List<String> _places = [];
  String? _selectedPlace;
  List<Map<String, dynamic>> _zoneUsers = [];
  List<Map<String, dynamic>> _selectedUsers = [];
  List<Map<String, dynamic>> _filteredUsers = [];
  TextEditingController _searchController = TextEditingController();
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
    final userQuery = await widget.userFirestore
        .collection('users')
        .where('mobile', isEqualTo: loggedInMobile)
        .limit(1)
        .get();
    bool canView = false;
    bool isSuperAdmin = false;
    if (userQuery.docs.isNotEmpty) {
      final data = userQuery.docs.first.data();
      final role = data['role']?.toString().toLowerCase();
      isSuperAdmin = role == 'super_admin' || role == 'superadmin';
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
      if (_zones.isNotEmpty && _selectedZone == null) {
        setState(() {
          _selectedZone = _zones.first;
        });
      }
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
        if (_topics.isNotEmpty && _selectedTopics.isEmpty) {
          _selectedTopics = [_topics[0]];
        }
        _isLoading = false;
      });
      await _fetchPlaces();
      await _fetchCurrentUserZone();
      if (_isSuperAdmin) {
        await _fetchZones();
        if (_zones.isNotEmpty && _selectedZone == null) {
        if (!mounted) {
          return;
        }
        setState(() {
          _selectedZone = _zones.first;
        });
        }
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
    super.dispose();
  }

  Future<void> _fetchPlaces() async {
    final places = await AttendanceSupport.fetchPlaces(_secondaryFirestore);
    if (!mounted) {
      return;
    }
    setState(() {
      _places = places;
      if (_places.isNotEmpty && _selectedPlace == null) {
        _selectedPlace = _places[0];
      }
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

    final usersSnapshot =
        await widget.userFirestore.collection('users').get();
    final zonesFromUsers = usersSnapshot.docs
        .map(
          (doc) =>
              (doc.data() as Map<String, dynamic>)['zone']?.toString() ?? '',
        )
        .map((name) => name.trim())
        .where((name) => name.isNotEmpty)
        .toList();

    final merged = <String>{...zonesFromCollection, ...zonesFromUsers}.toList()
      ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));

    if (!mounted) {
      return;
    }
    setState(() {
      _zones = merged;
    });
  }

  Future<void> _fetchZoneUsers() async {
    final zoneToQuery = _isSuperAdmin ? _selectedZone : _currentZone;
    print('Calling fetchZoneUsers with zone: "${zoneToQuery}"');
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
        appBar: AppBar(title: Text('Attendance Management')),
        body: Center(child: CircularProgressIndicator()),
      );
    }
if (!_canViewAttendance) {
  return Scaffold(
    appBar: AppBar(title: Text('Attendance Management')),
    body: Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.lock_outline, color: Colors.red, size: 64),
          SizedBox(height: 24),
          Text(
            'You are not authorized to view the Attendance page.',
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
            'Please contact your administrator for access.',
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
        title: Text('Attendance Management'),
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
                if (_topics.isNotEmpty && _selectedTopics.isEmpty) {
                  _selectedTopics = [_topics[0]];
                }
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
            if (_topics.isNotEmpty && _selectedTopics.isEmpty) {
              _selectedTopics = [_topics[0]];
            }
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
                          'Date: ${_selectedDate.toLocal().toString().split(' ')[0]}',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        if (!_isSuperAdmin)
                          Text(
                            'Zone: ${_currentZone ?? "Loading..."}',
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
                                        Text(
                                          'Topics',
                                          style: TextStyle(
                                            fontWeight: FontWeight.bold,
                                          ),
                                        ),
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
                                                      title: Text('Select Topics'),
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
                                                          child: Text('OK'),
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
                                                          child: Text('Cancel'),
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
                                          child: Container(
                                            padding: EdgeInsets.symmetric(
                                              horizontal: 12,
                                              vertical: 16,
                                            ),
                                            decoration: BoxDecoration(
                                              color: Color(0xFFE8F5E9),
                                              border: Border.all(
                                                color: Colors.grey,
                                              ),
                                              borderRadius:
                                                  BorderRadius.circular(4),
                                            ),
                                            child: Row(
                                              children: [
                                                Expanded(
                                                  child: Text(
                                                    _selectedTopics.isEmpty
                                                        ? 'Select Topics'
                                                        : _selectedTopics.join(
                                                            ', ',
                                                          ),
                                                    style: TextStyle(
                                                      fontSize: 16,
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
                                        labelText: 'Place',
                                        border: OutlineInputBorder(),
                                      ),
                                      value: _selectedPlace,
                                      items: _places.map((place) {
                                        return DropdownMenuItem(
                                          value: place,
                                          child: Text(place),
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
                                    if (_isSuperAdmin)
                                      Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            'Zone',
                                            style: TextStyle(
                                              fontWeight: FontWeight.bold,
                                            ),
                                          ),
                                          SizedBox(height: 8),
                                          DropdownButtonFormField<String>(
                                            value: _selectedZone,
                                            menuMaxHeight: 300,
                                            isExpanded: true,
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
                                            decoration: InputDecoration(
                                              border: OutlineInputBorder(),
                                            ),
                                          ),
                                        ],
                                      ),
                                    if (_isSuperAdmin) SizedBox(height: 16),
                                    Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          'Select Users from Zone:',
                                          style: TextStyle(
                                            fontWeight: FontWeight.bold,
                                          ),
                                        ),
                                        SizedBox(height: 4),
                                        Row(
                                          children: [
                                            IconButton(
                                              icon: Icon(Icons.refresh),
                                              tooltip: 'Refresh user list',
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
                                                child: Text('Select All'),
                                              ),
                                          ],
                                        ),
                                      ],
                                    ),
                                    SizedBox(height: 8),
                                    _zoneUsers.isEmpty
                                        ? Text('No users found for this zone.')
                                        : Column(
                                            children: [
                                              TextField(
                                                controller: _searchController,
                                                decoration: InputDecoration(
                                                  labelText: 'Search User Name',
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
                        'place': _selectedPlace,
                      },
                    );
                    if (_selectedTopics.isEmpty) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text('Please select at least one topic'),
                        ),
                      );
                      return;
                    }
                    if (_selectedPlace == null) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text('Please select a place')),
                      );
                      return;
                    }
                    if (_selectedUsers.isEmpty) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text('Please select at least one user'),
                        ),
                      );
                      return;
                    }

                    try {
                      int addedCount = 0;
                      int duplicateCount = 0;
                      String duplicateNames = '';
                      final monthKey =
                          AttendanceSupport.monthYearKey(_selectedDate);
                      for (final user in _selectedUsers) {
                        final dateKey =
                            '${_selectedDate.year.toString().padLeft(4, '0')}${_selectedDate.month.toString().padLeft(2, '0')}${_selectedDate.day.toString().padLeft(2, '0')}';
                        final rawDocId = '${dateKey}_${user['uid']}';
                        final docId = rawDocId.replaceAll(
                          RegExp(r'[^\w\d]'),
                          '_',
                        );
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
                        await docRef.set({
                          'date': Timestamp.fromDate(_selectedDate),
                          'time': DateTime.now().toLocal().toString().split(
                            ' ',
                          )[1],
                          'status': 'Present',
                          'Topic': _selectedTopics.join(', '),
                          'Place': _selectedPlace,
                          'zone': user['zone'],
                          'name': user['name'],
                          'userId': user['uid'],
                          'mobile': user['mobile'],
                        });
                        print(
                          'Attendance record added for ${user['name']}: $docId',
                        );
                        addedCount++;
                      }
                      String msg = '';
                      if (addedCount > 0) {
                        msg += 'Attendance marked for $addedCount user(s). ';
                        await FirebaseConfig.logEvent(
                          eventType: 'attendance_marked',
                          description: 'Attendance marked',
                          details: {
                            'count': addedCount,
                            'users': _selectedUsers.map((u) => u['name']).toList(),
                            'date': _selectedDate.toIso8601String(),
                            'place': _selectedPlace,
                            'topics': _selectedTopics,
                          },
                        );
                      }
                      if (duplicateCount > 0) {
                        msg +=
                            'Duplicate entries for: ${duplicateNames.substring(0, duplicateNames.length - 2)}. ';
                        await FirebaseConfig.logEvent(
                          eventType: 'attendance_duplicate',
                          description: 'Duplicate attendance entries',
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
                            msg.isEmpty ? 'No attendance marked.' : msg,
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
                          'place': _selectedPlace,
                          'topics': _selectedTopics,
                        },
                      );
                      print('Error marking attendance: $e');
                      print('Stack trace: ${StackTrace.current}');
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text('Failed to mark attendance: $e'),
                        ),
                      );
                    }
                  },
                  child: Text(
                    'Mark Attendance',
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
                        ? _places[0]
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
                              title: Text('Attendance View'),
                              content: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  DropdownButtonFormField<int>(
                                    decoration: InputDecoration(
                                      labelText: 'Year',
                                      border: OutlineInputBorder(),
                                    ),
                                    value: selectedYear,
                                    items: yearsList
                                        .map(
                                          (y) => DropdownMenuItem(
                                            value: y,
                                            child: Text('Year $y'),
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
'Start Date: ${startDate.year.toString().padLeft(4, '0')}-${startDate.month.toString().padLeft(2, '0')}-${startDate.day.toString().padLeft(2, '0')}',
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
'End Date: ${endDate.year.toString().padLeft(4, '0')}-${endDate.month.toString().padLeft(2, '0')}-${endDate.day.toString().padLeft(2, '0')}',
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
                                            labelText: 'Place',
                                            border: OutlineInputBorder(),
                                          ),
                                          value: selectedPlace,
                                          items: _places.map((place) {
                                            return DropdownMenuItem(
                                              value: place,
                                              child: Text(place),
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
                                            labelText: 'Zone',
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
                                    child: Text('Show Attendance'),
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
                                              'Please wait, Firebase is still initializing.',
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
                                    label: Text('Download List'),
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
                                      final normalizedSelectedPlace =
                                          (selectedPlace ?? '')
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
                                      final records = allRecords.map((data) {
                                        // Add formatted date string if not present
                                        if (!data.containsKey('dateString')) {
                                          final ts = data['date'];
                                          if (ts is Timestamp) {
                                            data['dateString'] = ts.toDate().toIso8601String();
                                          } else if (ts is DateTime) {
                                            data['dateString'] = ts.toIso8601String();
                                          } else {
                                            data['dateString'] = ts?.toString() ?? '';
                                          }
                                        }
                                        return data;
                                      }).where((data) {
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
                                              (data['Place'] ?? '')
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
                                          SnackBar(content: Text('No attendance records found for selected filters.')),
                                        );
                                        return;
                                      }
                                      final excel = Excel.createExcel();
                                      final sheet = excel['Attendance'];
                                      // Ensure 'dateString' is included in header
                                      final headerKeys = records.first.keys.toList();
                                      if (!headerKeys.contains('dateString')) {
                                        headerKeys.add('dateString');
                                      }
                                      sheet.appendRow(headerKeys.map((k) => TextCellValue(k.toString())).toList());
                                      for (final record in records) {
                                        final row = headerKeys.map((k) => TextCellValue(record[k]?.toString() ?? '')).toList();
                                        sheet.appendRow(row);
                                      }
                                      Directory? downloadsDir;
                                      try {
                                        downloadsDir = Directory('/storage/emulated/0/Download');
                                        if (!await downloadsDir.exists()) {
                                          downloadsDir = await getExternalStorageDirectory();
                                        }
                                      } catch (_) {
                                        downloadsDir = await getExternalStorageDirectory();
                                      }
                                      final path = downloadsDir?.path ?? (await getApplicationDocumentsDirectory()).path;
                                      final filterParts = <String>[
                                        'attendance',
                                        selectedYear.toString(),
                                      ];
                                      if (useStartDate) {
                                        filterParts.add(
                                          'from${_formatDateTime(startDate)}',
                                        );
                                      }
                                      if (useEndDate) {
                                        filterParts.add(
                                          'to${_formatDateTime(endDate)}',
                                        );
                                      }
                                      if (usePlace &&
                                          normalizedSelectedPlace.isNotEmpty) {
                                        filterParts.add(
                                          'place${normalizedSelectedPlace.replaceAll(RegExp(r'\s+'), '')}',
                                        );
                                      }
                                      if (useZone &&
                                          normalizedSelectedZone.isNotEmpty) {
                                        filterParts.add(
                                          'zone$normalizedSelectedZone',
                                        );
                                      }
                                      filterParts.add(
                                        _formatDateTime(DateTime.now()),
                                      );
                                      final fileNameRaw = filterParts.join('_');
                                      final fileName = fileNameRaw
                                              .replaceAll(
                                                RegExp(r'[^\w\d]'),
                                                '',
                                              ) +
                                          '.xlsx';
                                      final file = File('$path/$fileName');
                                      await file.writeAsBytes(excel.encode()!);
                                      await FirebaseConfig.logEvent(
                                        eventType: 'attendance_list_downloaded',
                                        description: 'Attendance List downloaded as Excel',
                                        details: {
                                          'timestamp': DateTime.now().toIso8601String(),
                                          'type': 'attendance',
                                          'filters': {
                                            'year': selectedYear,
                                            'place': selectedPlace,
                                            'zone': selectedZone,
                                            'startDate': useStartDate ? startDate.toIso8601String() : null,
                                            'endDate': useEndDate ? endDate.toIso8601String() : null,
                                          },
                                        },
                                      );
                                      ScaffoldMessenger.of(context).showSnackBar(
                                        SnackBar(content: Text('Excel file saved: $path/$fileName')),
                                      );
                                    },
                                  ),
                                ],
                              ),
                              actions: [
                                TextButton(
                                  child: Text('Close'),
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
                    'Attendance View',
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
