import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:plantation_summary/main.dart';
import 'firebase_config.dart';
import 'mobile_encryption_service.dart';

class BroadcastPage extends StatefulWidget {
  const BroadcastPage({Key? key}) : super(key: key);

  @override
  State<BroadcastPage> createState() => _BroadcastPageState();
}

class _BroadcastPageState extends State<BroadcastPage> {
  final TextEditingController _messageController = TextEditingController();
  final TextEditingController _searchController = TextEditingController();
  List<String> _selectedPhones = [];
  List<Map<String, dynamic>> _allUsers = [];
  String _searchQuery = '';

  String _broadcastDocId() {
    final invertedMs = 9999999999999 - DateTime.now().millisecondsSinceEpoch;
    return invertedMs.toString();
  }

  Future<List<Map<String, dynamic>>> _getLocalNotifications() async {
    final prefs = await SharedPreferences.getInstance();
    final List<String> notifications =
        prefs.getStringList('received_notifications') ?? [];
    debugPrint('Fetched notifications from SharedPreferences: $notifications');
    // Import loggedInMobile from main.dart
    String? myMobile = loggedInMobile;
    final filtered = notifications
        .map((e) => Map<String, dynamic>.from(jsonDecode(e)))
        .where(
          (n) =>
              n['data']?['phone']?.replaceAll(RegExp(r'\D'), '') ==
              myMobile?.replaceAll(RegExp(r'\D'), ''),
        )
        .toList();
    debugPrint('Filtered notifications for $myMobile: $filtered');
    return filtered;
  }

  @override
  void initState() {
    super.initState();
    _fetchAllUsers();
    Future.microtask(() async {
      await FirebaseConfig.logEvent(
        eventType: 'broadcast_page_opened',
        description: 'Broadcast page opened',
        userId: loggedInMobile,
      );
    });
  }

  Future<void> _fetchAllUsers() async {
    final query = await FirebaseFirestore.instance.collection('users').get();
    if (!mounted) {
      return;
    }
    setState(() {
      _allUsers = query.docs.map((doc) {
        final data = Map<String, dynamic>.from(doc.data());
        final storedMobile = data['mobile']?.toString();
        if (storedMobile != null && storedMobile.isNotEmpty) {
          data['mobile'] =
              MobileEncryptionService.decrypt(storedMobile) ?? storedMobile;
        }
        return data;
      }).toList();
    });
  }

  Future<void> _sendBroadcast() async {
    final String message = _messageController.text.trim();

    if (message.isEmpty || _selectedPhones.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('कृपया संदेश प्रविष्ट करा आणि किमान एक डिव्हाइस निवडा'),
        ),
      );
      return;
    }

    int queued = 0;
    int missingToken = 0;

    for (final phone in _selectedPhones) {
      final user = _allUsers.firstWhere(
        (u) => u['mobile'] == phone,
        orElse: () => <String, dynamic>{},
      );
      final String? token = user['fcmToken'] is String
          ? user['fcmToken'] as String
          : null;

      final docId = _broadcastDocId();
      await FirebaseFirestore.instance.collection('broadcasts').doc(docId).set({
        'title': 'प्रसारण संदेश',
        'message': message,
        'phone': phone,
        'toPhone': phone,
        'fromPhone': loggedInMobile,
        'senderMobile': loggedInMobile,
        'registrationToken': token,
        'status': token != null ? 'pending' : 'missing_token',
        'sentAt': FieldValue.serverTimestamp(),
      });

      if (token != null) {
        queued++;
      } else {
        missingToken++;
      }
    }

    await FirebaseConfig.logEvent(
      eventType: 'broadcast_send_attempt',
      description: 'Broadcast queued via Cloud Function',
      userId: loggedInMobile,
      isImportant: true,
      details: {
        'message': message,
        'targetPhones': _selectedPhones,
        'queued': queued,
        'missingToken': missingToken,
      },
    );

    if (queued > 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '$queued संदेश पाठवण्यासाठी रांगेत टाकले.'
            '${missingToken > 0 ? ' ($missingToken टोकन नाही)' : ''}',
          ),
        ),
      );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('निवडलेल्या डिव्हाइसवर FCM टोकन नाही.')),
      );
    }

    _messageController.clear();
    _searchController.clear();
    if (mounted)
      setState(() {
        _selectedPhones = [];
        _searchQuery = '';
      });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('प्रसारित संदेश'),
        actions: [
          PopupMenuButton<String>(
            icon: Icon(Icons.more_vert),
            onSelected: (value) async {
              await FirebaseConfig.logEvent(
                eventType: 'broadcast_menu_selected',
                description: 'Broadcast menu selected',
                userId: loggedInMobile,
                details: {'menu': value},
              );
              if (value == 'Received') {
                showDialog(
                  context: context,
                  builder: (context) => AlertDialog(
                    title: Text('प्राप्त सूचना'),
                    content: StreamBuilder<QuerySnapshot>(
                      stream: loggedInMobile == null
                          ? const Stream.empty()
                          : FirebaseFirestore.instance
                                .collection('broadcasts')
                                .where('toPhone', isEqualTo: loggedInMobile)
                                .snapshots(),
                      builder: (context, snapshot) {
                        if (snapshot.connectionState ==
                            ConnectionState.waiting) {
                          return Center(child: CircularProgressIndicator());
                        }
                        if (!snapshot.hasData || snapshot.data!.docs.isEmpty) {
                          return Text('प्राप्त सूचना नाहीत.');
                        }
                        final received = snapshot.data!.docs.toList()
                          ..sort((a, b) {
                            final aTime =
                                (a.data() as Map<String, dynamic>)['sentAt'];
                            final bTime =
                                (b.data() as Map<String, dynamic>)['sentAt'];
                            final aDate = aTime is Timestamp
                                ? aTime.toDate()
                                : DateTime.fromMillisecondsSinceEpoch(0);
                            final bDate = bTime is Timestamp
                                ? bTime.toDate()
                                : DateTime.fromMillisecondsSinceEpoch(0);
                            return bDate.compareTo(aDate);
                          });
                        return Container(
                          width: double.maxFinite,
                          child: ListView.builder(
                            shrinkWrap: true,
                            itemCount: received.length,
                            itemBuilder: (context, index) {
                              final doc = received[index];
                              final data = doc.data() as Map<String, dynamic>;
                              return ListTile(
                                title: Text(data['message'] ?? ''),
                                subtitle: Text(
                                  'पासून: ${data['fromPhone'] ?? ''}',
                                ),
                                trailing: Text(
                                  data['sentAt'] != null
                                      ? (data['sentAt'] as Timestamp)
                                            .toDate()
                                            .toString()
                                      : '',
                                  style: TextStyle(fontSize: 10),
                                ),
                              );
                            },
                          ),
                        );
                      },
                    ),
                    actions: [
                      TextButton(
                        onPressed: () async {
                          await FirebaseConfig.logEvent(
                            eventType: 'broadcast_received_closed',
                            description: 'Broadcast received dialog closed',
                            userId: loggedInMobile,
                          );
                          Navigator.pop(context);
                        },
                        child: Text('बंद करा'),
                      ),
                    ],
                  ),
                );
              } else if (value == 'Sent') {
                showDialog(
                  context: context,
                  builder: (context) => AlertDialog(
                    title: Text('पाठवलेल्या सूचना'),
                    content: StreamBuilder<QuerySnapshot>(
                      stream: loggedInMobile == null
                          ? const Stream.empty()
                          : FirebaseFirestore.instance
                                .collection('broadcasts')
                                .where('fromPhone', isEqualTo: loggedInMobile)
                                .snapshots(),
                      builder: (context, snapshot) {
                        if (snapshot.connectionState ==
                            ConnectionState.waiting) {
                          return Center(child: CircularProgressIndicator());
                        }
                        if (!snapshot.hasData || snapshot.data!.docs.isEmpty) {
                          return Text('पाठवलेल्या सूचना नाहीत.');
                        }
                        final sent = snapshot.data!.docs.toList()
                          ..sort((a, b) {
                            final aTime =
                                (a.data() as Map<String, dynamic>)['sentAt'];
                            final bTime =
                                (b.data() as Map<String, dynamic>)['sentAt'];
                            final aDate = aTime is Timestamp
                                ? aTime.toDate()
                                : DateTime.fromMillisecondsSinceEpoch(0);
                            final bDate = bTime is Timestamp
                                ? bTime.toDate()
                                : DateTime.fromMillisecondsSinceEpoch(0);
                            return bDate.compareTo(aDate);
                          });
                        return Container(
                          width: double.maxFinite,
                          child: ListView.builder(
                            shrinkWrap: true,
                            itemCount: sent.length,
                            itemBuilder: (context, index) {
                              final doc = sent[index];
                              final data = doc.data() as Map<String, dynamic>;
                              return ListTile(
                                title: Text(data['message'] ?? ''),
                                subtitle: Text('कडे: ${data['phone'] ?? ''}'),
                                trailing: Text(
                                  data['sentAt'] != null
                                      ? (data['sentAt'] as Timestamp)
                                            .toDate()
                                            .toString()
                                      : '',
                                  style: TextStyle(fontSize: 10),
                                ),
                              );
                            },
                          ),
                        );
                      },
                    ),
                    actions: [
                      TextButton(
                        onPressed: () async {
                          await FirebaseConfig.logEvent(
                            eventType: 'broadcast_sent_closed',
                            description: 'Broadcast sent dialog closed',
                            userId: loggedInMobile,
                          );
                          Navigator.pop(context);
                        },
                        child: Text('बंद करा'),
                      ),
                    ],
                  ),
                );
              }
            },
            itemBuilder: (context) => [
              PopupMenuItem(value: 'Sent', child: Text('पाठवलेले')),
              PopupMenuItem(value: 'Received', child: Text('प्राप्त')),
            ],
          ),
        ],
      ),
      body: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Card(
            elevation: 2,
            child: Padding(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                children: [
                  TextField(
                    controller: _messageController,
                    decoration: InputDecoration(labelText: 'संदेश'),
                    maxLines: 4,
                  ),
                  SizedBox(height: 16),
                  // Search box
                  Builder(
                    builder: (context) {
                      final filtered = _allUsers.where((u) {
                        if (_searchQuery.isEmpty) return true;
                        final q = _searchQuery.toLowerCase();
                        final name = (u['name'] ?? '').toString().toLowerCase();
                        final mobile = (u['mobile'] ?? '').toString();
                        return name.contains(q) ||
                            mobile.contains(q);
                      }).toList();

                      final allFilteredSelected =
                          filtered.isNotEmpty &&
                          filtered.every(
                            (u) => _selectedPhones.contains(
                              u['mobile']?.toString(),
                            ),
                          );

                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: TextField(
                                  controller: _searchController,
                                  decoration: InputDecoration(
                                    labelText: 'वापरकर्ता शोधा (नाव / मोबाइल)',
                                    prefixIcon: Icon(Icons.search),
                                    suffixIcon: _searchQuery.isNotEmpty
                                        ? IconButton(
                                            icon: Icon(Icons.clear),
                                            onPressed: () => setState(() {
                                              _searchController.clear();
                                              _searchQuery = '';
                                            }),
                                          )
                                        : null,
                                    border: OutlineInputBorder(),
                                    isDense: true,
                                  ),
                                  onChanged: (v) =>
                                      setState(() => _searchQuery = v.trim()),
                                ),
                              ),
                              SizedBox(width: 8),
                              TextButton(
                                onPressed: filtered.isEmpty
                                    ? null
                                    : () {
                                        setState(() {
                                          if (allFilteredSelected) {
                                            for (final u in filtered) {
                                              _selectedPhones.remove(
                                                u['mobile']?.toString(),
                                              );
                                            }
                                          } else {
                                            for (final u in filtered) {
                                              final m =
                                                  u['mobile']?.toString() ?? '';
                                              if (m.isNotEmpty &&
                                                  !_selectedPhones.contains(
                                                    m,
                                                  )) {
                                                _selectedPhones.add(m);
                                              }
                                            }
                                          }
                                        });
                                      },
                                child: Text(
                                  allFilteredSelected
                                      ? 'सर्व काढा'
                                      : 'सर्व निवडा',
                                ),
                              ),
                            ],
                          ),
                          SizedBox(height: 8),
                          Container(
                            height: 200,
                            decoration: BoxDecoration(
                              border: Border.all(color: Colors.grey.shade300),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: filtered.isEmpty
                                ? Center(
                                    child: Text(
                                      'कोणताही वापरकर्ता सापडला नाही',
                                      style: TextStyle(color: Colors.grey),
                                    ),
                                  )
                                : ListView.builder(
                                    itemCount: filtered.length,
                                    itemBuilder: (context, index) {
                                      final u = filtered[index];
                                      final mobile =
                                          u['mobile']?.toString() ?? '';
                                      final name =
                                          (u['name'] ?? '').toString().trim();
                                      final isSelected = _selectedPhones
                                          .contains(mobile);
                                      return CheckboxListTile(
                                        dense: true,
                                        value: isSelected,
                                        title: Text(
                                          name.isEmpty ? mobile : name,
                                        ),
                                        subtitle: Text(mobile),
                                        onChanged: (checked) async {
                                          setState(() {
                                            if (checked == true) {
                                              if (!_selectedPhones.contains(
                                                mobile,
                                              ))
                                                _selectedPhones.add(mobile);
                                            } else {
                                              _selectedPhones.remove(mobile);
                                            }
                                          });
                                          await FirebaseConfig.logEvent(
                                            eventType: checked == true
                                                ? 'broadcast_phone_added'
                                                : 'broadcast_phone_removed',
                                            description:
                                                'Broadcast phone ${checked == true ? 'added' : 'removed'}',
                                            userId: loggedInMobile,
                                            details: {'phone': mobile},
                                          );
                                        },
                                      );
                                    },
                                  ),
                          ),
                          if (_selectedPhones.isNotEmpty) ...[
                            SizedBox(height: 8),
                            Text(
                              'निवडलेले (${_selectedPhones.length}):',
                              style: TextStyle(fontWeight: FontWeight.w600),
                            ),
                            SizedBox(height: 4),
                            Wrap(
                              spacing: 6,
                              runSpacing: 4,
                              children: _selectedPhones.map((phone) {
                                final user = _allUsers.firstWhere(
                                  (u) => u['mobile'] == phone,
                                  orElse: () => {},
                                );
                                final name =
                                    (user['name'] ?? '').toString().trim();
                                return Chip(
                                  label: Text(
                                    name.isEmpty ? phone : name,
                                    style: TextStyle(fontSize: 12),
                                  ),
                                  deleteIcon: Icon(Icons.close, size: 14),
                                  onDeleted: () => setState(
                                    () => _selectedPhones.remove(phone),
                                  ),
                                  materialTapTargetSize:
                                      MaterialTapTargetSize.shrinkWrap,
                                );
                              }).toList(),
                            ),
                          ],
                        ],
                      );
                    },
                  ),
                  SizedBox(height: 24),
                  ElevatedButton(
                    onPressed: () async {
                      await FirebaseConfig.logEvent(
                        eventType: 'broadcast_send_clicked',
                        description: 'Broadcast send clicked',
                        userId: loggedInMobile,
                        details: {'selectedPhones': _selectedPhones},
                      );
                      _sendBroadcast();
                    },
                    child: Text('प्रसारित करा'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
