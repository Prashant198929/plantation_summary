import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:plantation_summary/main.dart';
import 'firebase_config.dart';

class BroadcastPage extends StatefulWidget {
  const BroadcastPage({Key? key}) : super(key: key);

  @override
  State<BroadcastPage> createState() => _BroadcastPageState();
}

class _BroadcastPageState extends State<BroadcastPage> {
  final TextEditingController _messageController = TextEditingController();
  List<String> _selectedPhones = [];
  List<Map<String, dynamic>> _allUsers = [];
  String? _registrationToken;

  String _broadcastDocId(String phone) {
    final now = DateTime.now();
    final dateKey =
        '${now.year.toString().padLeft(4, '0')}${now.month.toString().padLeft(2, '0')}${now.day.toString().padLeft(2, '0')}';
    final rawId = '${dateKey}_$phone';
    return rawId.replaceAll(RegExp(r'[^\w\d]'), '_');
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
    _getRegistrationToken();
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
      _allUsers = query.docs.map((doc) => doc.data()).toList();
    });
  }

  Future<void> _getRegistrationToken() async {
    try {
      String? token = await FirebaseMessaging.instance.getToken();
      print('FCM Registration Token: $token');
      debugPrint('FCM Registration Token: $token');
      if (!mounted) {
        return;
      }
      setState(() {
        _registrationToken = token;
      });
    } catch (e) {
      print('Error retrieving FCM token: $e');
      debugPrint('Error retrieving FCM token: $e');
      if (!mounted) {
        return;
      }
      setState(() {
        _registrationToken = 'Error retrieving token: $e';
      });
    }
  }

  Future<String> _fetchAccessToken() async {
    // Replace with your backend server IP and port, or use a public endpoint if available
    final url = Uri.parse('http://161.118.179.102:8082/api/generate-token');
    debugPrint('Fetching access token from: $url');
    await FirebaseConfig.logEvent(
      eventType: 'broadcast_access_token_fetch_started',
      description: 'Broadcast access token fetch started',
      userId: loggedInMobile,
      details: {'url': url.toString()},
    );
    try {
      final response = await http.get(url).timeout(const Duration(seconds: 5));
      debugPrint(
        'Access token response: ${response.statusCode} ${response.body}',
      );
      if (response.statusCode == 200) {
        await FirebaseConfig.logEvent(
          eventType: 'broadcast_access_token_fetch_succeeded',
          description: 'Broadcast access token fetch succeeded',
          userId: loggedInMobile,
          details: {'statusCode': response.statusCode},
        );
        return response.body;
      } else {
        await FirebaseConfig.logEvent(
          eventType: 'broadcast_access_token_fetch_failed',
          description: 'Broadcast access token fetch failed',
          userId: loggedInMobile,
          details: {'statusCode': response.statusCode},
        );
        throw Exception(
          'Failed to fetch access token: ${response.statusCode} ${response.body}',
        );
      }
    } on Exception catch (e) {
      debugPrint('Access token fetch error: $e');
      await FirebaseConfig.logEvent(
        eventType: 'broadcast_access_token_fetch_error',
        description: 'Broadcast access token fetch error',
        userId: loggedInMobile,
        details: {'error': e.toString()},
      );
      throw Exception(
        'Could not fetch access token. Please check backend URL and connectivity. Error: $e',
      );
    }
  }

  Future<void> _sendBroadcast() async {
    final String message = _messageController.text.trim();

    if (message.isEmpty || _selectedPhones.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please enter message and select at least one device'),
        ),
      );
      return;
    }

    int successCount = 0;
    int failureCount = 0;
    final List<String> failedPhones = [];

    for (final phone in _selectedPhones) {
      final user = _allUsers.firstWhere(
        (u) => u['mobile'] == phone,
        orElse: () => <String, dynamic>{},
      );
      final String? targetToken = (user['fcmToken'] is String) ? user['fcmToken'] as String : null;
      if (targetToken == null || targetToken.isEmpty) {
        failureCount++;
        failedPhones.add(phone);
        // Also log missing token for diagnostics
        try {
          final docId = _broadcastDocId(phone);
          await FirebaseFirestore.instance
              .collection('broadcasts')
              .doc(docId)
              .set({
                'message': message,
                'phone': phone,
                'sentAt': FieldValue.serverTimestamp(),
                'registrationToken': null,
                'status': 'missing_token',
                'senderMobile': loggedInMobile,
                'fromPhone': loggedInMobile,
                'toPhone': phone,
              });
        } catch (_) {}
        continue;
      }

      try {
        final accessToken = await _fetchAccessToken();
        debugPrint('Using access token: $accessToken');
        const String projectId = 'vrukshamojani-4ffd6';
        final url = Uri.parse('https://fcm.googleapis.com/v1/projects/$projectId/messages:send');
        final headers = {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $accessToken',
        };
        final body = jsonEncode({
          'message': {
            'token': targetToken,
            'notification': {'title': 'Broadcast Message', 'body': message},
            'data': {'phone': phone},
          },
        });

        debugPrint('FCM JSON request: $body');
        final response = await http.post(url, headers: headers, body: body).timeout(const Duration(seconds: 10));
        debugPrint('FCM JSON response: ${response.statusCode} ${response.body}');

        // Log attempt result in Firestore
        final docId = _broadcastDocId(phone);
        await FirebaseFirestore.instance
            .collection('broadcasts')
            .doc(docId)
            .set({
              'message': message,
              'phone': phone,
              'sentAt': FieldValue.serverTimestamp(),
              'registrationToken': targetToken,
              'statusCode': response.statusCode,
              'responseBody': response.body,
              'senderMobile': loggedInMobile,
              'fromPhone': loggedInMobile,
              'toPhone': phone,
            });

        if (response.statusCode >= 200 && response.statusCode < 300) {
          successCount++;
        } else {
          failureCount++;
          failedPhones.add(phone);
        }
      } on Exception catch (e) {
        debugPrint('Error sending push notification: $e');
        failureCount++;
        failedPhones.add(phone);
        // Log the failure in Firestore for diagnostics
        try {
          final docId = _broadcastDocId(phone);
          await FirebaseFirestore.instance
              .collection('broadcasts')
              .doc(docId)
              .set({
                'message': message,
                'phone': phone,
                'sentAt': FieldValue.serverTimestamp(),
                'registrationToken': targetToken,
                'status': 'error',
                'error': e.toString(),
                'senderMobile': loggedInMobile,
                'fromPhone': loggedInMobile,
                'toPhone': phone,
              });
        } catch (_) {}
      }
    }

    await FirebaseConfig.logEvent(
      eventType: 'broadcast_send_attempt',
      description: 'Attempted to send broadcast to selected devices',
      details: {
        'message': message,
        'attemptedPhones': _selectedPhones,
        'successCount': successCount,
        'failureCount': failureCount,
        'failedPhones': failedPhones,
      },
    );

    // Show accurate outcome
    if (successCount > 0 && failureCount == 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Broadcast sent to $successCount device(s).')),
      );
    } else if (successCount > 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Broadcast sent to $successCount device(s). $failureCount failed.')),
      );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Failed to send broadcast to selected devices.')),
      );
    }

    _messageController.clear();
    if (!mounted) {
      return;
    }
    setState(() {
      _selectedPhones = [];
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Broadcast Message'),
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
                    title: Text('Received Notifications'),
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
                          return Text('No received notifications.');
                        }
                        final received = snapshot.data!.docs.toList()
                          ..sort((a, b) {
                            final aTime = (a.data() as Map<String, dynamic>)['sentAt'];
                            final bTime = (b.data() as Map<String, dynamic>)['sentAt'];
                            final aDate = aTime is Timestamp ? aTime.toDate() : DateTime.fromMillisecondsSinceEpoch(0);
                            final bDate = bTime is Timestamp ? bTime.toDate() : DateTime.fromMillisecondsSinceEpoch(0);
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
                                subtitle: Text('From: ${data['fromPhone'] ?? ''}'),
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
                        child: Text('Close'),
                      ),
                    ],
                  ),
                );
              } else if (value == 'Sent') {
                showDialog(
                  context: context,
                  builder: (context) => AlertDialog(
                    title: Text('Sent Notifications'),
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
                          return Text('No sent notifications.');
                        }
                        final sent = snapshot.data!.docs.toList()
                          ..sort((a, b) {
                            final aTime = (a.data() as Map<String, dynamic>)['sentAt'];
                            final bTime = (b.data() as Map<String, dynamic>)['sentAt'];
                            final aDate = aTime is Timestamp ? aTime.toDate() : DateTime.fromMillisecondsSinceEpoch(0);
                            final bDate = bTime is Timestamp ? bTime.toDate() : DateTime.fromMillisecondsSinceEpoch(0);
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
                                subtitle: Text('To: ${data['phone'] ?? ''}'),
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
                        child: Text('Close'),
                      ),
                    ],
                  ),
                );
              }
            },
            itemBuilder: (context) => [
              PopupMenuItem(value: 'Sent', child: Text('Sent')),
              PopupMenuItem(value: 'Received', child: Text('Received')),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: Card(
              elevation: 2,
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: Column(
                  children: [
                    TextField(
                      controller: _messageController,
                      decoration: InputDecoration(labelText: 'Message'),
                      maxLines: 4,
                    ),
                    SizedBox(height: 16),
                    DropdownButtonFormField<String>(
                      items: _allUsers
                          .map(
                            (u) => DropdownMenuItem<String>(
                              value: u['mobile'],
                              child: Text(
                                '${u['name'] ?? ''} (${u['mobile']})',
                              ),
                            ),
                          )
                          .toList(),
                      onChanged: (val) {
                        if (val != null && !_selectedPhones.contains(val)) {
                          setState(() {
                            _selectedPhones.add(val);
                          });
                          Future.microtask(() async {
                            await FirebaseConfig.logEvent(
                              eventType: 'broadcast_phone_added',
                              description: 'Broadcast phone added',
                              userId: loggedInMobile,
                              details: {'phone': val},
                            );
                          });
                        }
                      },
                      decoration: InputDecoration(
                        labelText: 'Mobile Number(s)',
                      ),
                    ),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: _selectedPhones.map((phone) {
                        final user = _allUsers.firstWhere(
                          (u) => u['mobile'] == phone,
                          orElse: () => {},
                        );
                        final name = user['name'] ?? phone;
                        return ListTile(
                          title: Text(name),
                          subtitle: Text(phone),
                          trailing: IconButton(
                            icon: Icon(Icons.close),
                            onPressed: () async {
                              await FirebaseConfig.logEvent(
                                eventType: 'broadcast_phone_removed',
                                description: 'Broadcast phone removed',
                                userId: loggedInMobile,
                                details: {'phone': phone},
                              );
                              setState(() {
                                _selectedPhones.remove(phone);
                              });
                            },
                          ),
                        );
                      }).toList(),
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
                      child: Text('Broadcast'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
