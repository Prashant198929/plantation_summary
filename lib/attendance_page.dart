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

  @override
  void initState() {
    super.initState();
    _checkAttendanceRole();
    _callInitializeSecondaryApp();
  }

  Future<void> _checkAttendanceRole() async {
    // Replace with your user id logic if needed
    final userQuery = await widget.userFirestore
        .collection('users')
        .where('mobile', isEqualTo: loggedInMobile)
        .limit(1)
        .get();
    if (userQuery.docs.isNotEmpty) {
      final data = userQuery.docs.first.data();
if (data['attendance_viewer'] == true) {
  setState(() {
    _canViewAttendance = true;
  });
}
    }
    setState(() {
      _roleChecked = true;
    });
  }

  Future<void> _callInitializeSecondaryApp() async {
    final secondaryApp = await AttendanceSupport.initializeSecondaryApp(
      _secondaryFirestore,
    );
    if (secondaryApp != null) {
      final firestore = FirebaseFirestore.instanceFor(app: secondaryApp);
      setState(() {
        _secondaryApp = secondaryApp;
        _secondaryFirestore = firestore;
      });
      final topics = await AttendanceSupport.fetchTopics(firestore);
      setState(() {
        _topics = topics;
        if (_topics.isNotEmpty && _selectedTopics.isEmpty) {
          _selectedTopics = [_topics[0]];
        }
        _isLoading = false;
      });
      await _fetchPlaces();
      await _fetchCurrentUserZone();
      await _fetchZoneUsers();
    } else {
      setState(() {
        _errorMessage = 'Failed to initialize Firebase. Please try again.';
      });
    }
  }

  @override
  void dispose() {
    super.dispose();
  }

  Future<void> _fetchPlaces() async {
    final places = await AttendanceSupport.fetchPlaces(_secondaryFirestore);
    setState(() {
      _places = places;
      if (_places.isNotEmpty && _selectedPlace == null) {
        _selectedPlace = _places[0];
      }
    });
  }

  Future<void> _fetchZoneUsers() async {
    print('Calling fetchZoneUsers with _currentZone: "${_currentZone}"');
    final users = await AttendanceSupport.fetchZoneUsers(
      widget.userFirestore,
      _currentZone,
    );
    setState(() {
      _zoneUsers = users;
      _filteredUsers = users;
      _selectedUsers = [];
    });
  }

  Future<void> _fetchCurrentUserZone() async {
    final zone = await AttendanceSupport.fetchCurrentUserZone(context);
    setState(() {
      _currentZone = zone;
    });
  }

  Future<void> _selectDate(BuildContext context) async {
    final picked = await AttendanceSupport.selectDate(context, _selectedDate);
    if (picked != null && picked != _selectedDate) {
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
            onPressed: () => _selectDate(context),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () async {
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
                                                              },
                                                            );
                                                          }).toList(),
                                                        ),
                                                      ),
                                                      actions: [
                                                        TextButton(
                                                          child: Text('OK'),
                                                          onPressed: () => Navigator.of(context).pop(tempSelected),
                                                        ),
                                                        TextButton(
                                                          child: Text('Cancel'),
                                                          onPressed: () => Navigator.of(context).pop(_selectedTopics),
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
                                      },
                                    ),
                                    SizedBox(height: 16),
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
                                              onPressed: () {
                                                print(
                                                  'Manual refresh clicked. Current zone: $_currentZone',
                                                );
                                                _fetchZoneUsers();
                                              },
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
                      for (final user in _selectedUsers) {
                        final existing = await _secondaryFirestore!
                            .collection('Attendance')
                            .where(
                              'date',
                              isGreaterThanOrEqualTo: Timestamp.fromDate(
                                DateTime(
                                  _selectedDate.year,
                                  _selectedDate.month,
                                  _selectedDate.day,
                                ),
                              ),
                            )
                            .where(
                              'date',
                              isLessThan: Timestamp.fromDate(
                                DateTime(
                                  _selectedDate.year,
                                  _selectedDate.month,
                                  _selectedDate.day + 1,
                                ),
                              ),
                            )
                            .where('name', isEqualTo: user['name'])
                            .get();
                        if (existing.docs.isNotEmpty) {
                          duplicateCount++;
                          duplicateNames += '${user['name']}, ';
                          print(
                            'Duplicate attendance for ${user['name']} on ${_selectedDate.toLocal().toString().split(' ')[0]}',
                          );
                          continue;
                        }
                        final docRef = await _secondaryFirestore!
                            .collection('Attendance')
                            .add({
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
                          'Attendance record added for ${user['name']}: ${docRef.id}',
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
                    DateTime startDate = DateTime.now();
                    DateTime endDate = DateTime.now();
                    String? selectedPlace = _places.isNotEmpty
                        ? _places[0]
                        : null;
                    String? selectedZone = _currentZone;

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
                                          items: (_places.isNotEmpty
                                                  ? _zoneUsers.map((u) => u['zone']?.toString() ?? '').toSet().toList()
                                                  : [])
                                              .where((z) => z.isNotEmpty)
                                              .map((zone) => DropdownMenuItem<String>(
                                                    value: zone,
                                                    child: Text(zone),
                                                  ))
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
                                    onPressed: () {
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
                                      print(
                                        '[AttendancePage] Show Attendance: year=$selectedYear, place="$selectedPlace", zone="$selectedZone", startDate=${useStartDate ? startDate : null}, endDate=${useEndDate ? endDate : null}',
                                      );
                                      Navigator.push(
                                        context,
                                        MaterialPageRoute(
                                          builder: (context) =>
                                              AttendanceDetails(
                                                year: selectedYear,
                                                place: selectedPlace,
                                                zone: selectedZone,
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
                                      if (_secondaryFirestore == null) {
                                        ScaffoldMessenger.of(context).showSnackBar(
                                          SnackBar(
                                            content: Text('Please wait, Firebase is still initializing.'),
                                          ),
                                        );
                                        return;
                                      }
                                      final query = _secondaryFirestore!
                                          .collection('Attendance')
                                          .where('date', isGreaterThanOrEqualTo: Timestamp.fromDate(useStartDate ? startDate : DateTime(selectedYear, 1, 1)))
                                          .where('date', isLessThanOrEqualTo: Timestamp.fromDate(useEndDate ? endDate : DateTime(selectedYear, 12, 31, 23, 59, 59)));
                                      if (usePlace ?? false && selectedPlace != null) {
                                        query.where('Place', isEqualTo: selectedPlace);
                                      }
                                      if ((useZone == true) && (selectedZone?.isNotEmpty ?? false)) {
                                        query.where('zone', isEqualTo: selectedZone);
                                      }
                                      final snapshot = await query.get();
                                      final records = snapshot.docs.map((doc) {
                                        final data = doc.data();
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
                                        if (selectedPlace?.isNotEmpty ?? false) {
                                          if ((data['Place'] ?? '').toString() != selectedPlace) return false;
                                        }
                                        if (selectedZone?.isNotEmpty ?? false) {
                                          if ((data['zone'] ?? '').toString() != selectedZone) return false;
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
                                      final fileNameRaw = 'attendance_${selectedYear}_${useStartDate ? _formatDateTime(startDate) : ''}_${useEndDate ? _formatDateTime(endDate) : ''}_${selectedPlace ?? ''}_${selectedZone ?? ''}_${_formatDateTime(DateTime.now())}';
                                      final fileName = fileNameRaw.replaceAll(RegExp(r'[^\w\d]'), '') + '.xlsx';
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
                                  onPressed: () => Navigator.of(context).pop(),
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
