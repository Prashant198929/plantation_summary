import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:plantation_summary/main.dart';

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
  }

  Future<void> _fetchAllUsers() async {
    final query = await FirebaseFirestore.instance.collection('users').get();
    setState(() {
      _allUsers = query.docs.map((doc) => doc.data()).toList();
    });
  }

  Future<void> _getRegistrationToken() async {
    try {
      String? token = await FirebaseMessaging.instance.getToken();
      print('FCM Registration Token: $token');
      debugPrint('FCM Registration Token: $token');
      setState(() {
        _registrationToken = token;
      });
    } catch (e) {
      print('Error retrieving FCM token: $e');
      debugPrint('Error retrieving FCM token: $e');
      setState(() {
        _registrationToken = 'Error retrieving token: $e';
      });
    }
  }

  Future<String> _fetchAccessToken() async {
    // Replace with your backend server IP and port, or use a public endpoint if available
    final url = Uri.parse('http://161.118.179.102:8082/api/generate-token');
    debugPrint('Fetching access token from: $url');
    try {
      final response = await http.get(url).timeout(const Duration(seconds: 5));
      debugPrint(
        'Access token response: ${response.statusCode} ${response.body}',
      );
      if (response.statusCode == 200) {
        return response.body;
      } else {
        throw Exception(
          'Failed to fetch access token: ${response.statusCode} ${response.body}',
        );
      }
    } on Exception catch (e) {
      debugPrint('Access token fetch error: $e');
      throw Exception(
        'Could not fetch access token. Please check backend URL and connectivity. Error: $e',
      );
    }
  }

  Future<void> _sendBroadcast() async {
    String message = _messageController.text.trim();

    if (message.isEmpty || _selectedPhones.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Please enter message and select at least one device'),
        ),
      );
      return;
    }

    for (final phone in _selectedPhones) {
      final user = _allUsers.firstWhere(
        (u) => u['mobile'] == phone,
        orElse: () => {},
      );
      String? targetToken = user['fcmToken'];
      if (targetToken != null && targetToken.isNotEmpty) {
        await FirebaseFirestore.instance.collection('broadcasts').add({
          'message': message,
          'phone': phone,
          'sentAt': FieldValue.serverTimestamp(),
          'registrationToken': targetToken,
        });

        try {
          final accessToken = await _fetchAccessToken();
          debugPrint('Using access token: $accessToken');
          const String projectId = 'vrukshamojani-4ffd6';
          final url = Uri.parse(
            'https://fcm.googleapis.com/v1/projects/$projectId/messages:send',
          );
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

          print('FCM JSON request: $body');
          debugPrint('FCM JSON request: $body');
          final response = await http.post(url, headers: headers, body: body);
          print('FCM JSON response: $response');
          debugPrint('FCM JSON response: $response');
        } catch (e) {
          debugPrint('Error sending push notification: $e');
        }
      }
    }

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Broadcast sent to selected devices')),
    );

    _messageController.clear();
    setState(() {
      _selectedPhones = [];
    });
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: Text('Broadcast Message'),
          actions: [
            PopupMenuButton<String>(
              icon: Icon(Icons.more_vert),
              onSelected: (value) async {
                if (value == 'Received') {
                  showDialog(
                    context: context,
                    builder: (context) => AlertDialog(
                      title: Text('Received Notifications'),
                      content: FutureBuilder<List<Map<String, dynamic>>>(
                        future: _getLocalNotifications(),
                        builder: (context, snapshot) {
                          if (snapshot.connectionState == ConnectionState.waiting) {
                            return Center(child: CircularProgressIndicator());
                          }
                          final notifications = snapshot.data ?? [];
                          if (notifications.isEmpty) {
                            return Text('No notifications received yet.');
                          }
                          return Container(
                            width: double.maxFinite,
                            child: ListView.builder(
                              shrinkWrap: true,
                              itemCount: notifications.length,
                              itemBuilder: (context, index) {
                                final data = notifications[index];
                                return ListTile(
                                  title: Text(data['title'] ?? ''),
                                  subtitle: Text(data['body'] ?? ''),
                                  trailing: Text(
                                    data['receivedAt'] ?? '',
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
                          onPressed: () => Navigator.pop(context),
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
                        stream: FirebaseFirestore.instance
                            .collection('broadcasts')
                            .orderBy('sentAt', descending: true)
                            .snapshots(),
                        builder: (context, snapshot) {
                          if (snapshot.connectionState == ConnectionState.waiting) {
                            return Center(child: CircularProgressIndicator());
                          }
                          if (!snapshot.hasData || snapshot.data!.docs.isEmpty) {
                            return Text('No sent notifications.');
                          }
                          final sent = snapshot.data!.docs;
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
                          onPressed: () => Navigator.pop(context),
                          child: Text('Close'),
                        ),
                      ],
                    ),
                  );
                }
              },
              itemBuilder: (context) => [
                PopupMenuItem(
                  value: 'Sent',
                  child: Text('Sent'),
                ),
                PopupMenuItem(
                  value: 'Received',
                  child: Text('Received'),
                ),
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
                            .map((u) => DropdownMenuItem<String>(
                                  value: u['mobile'],
                                  child: Text('${u['name'] ?? ''} (${u['mobile']})'),
                                ))
                            .toList(),
                        onChanged: (val) {
                          if (val != null && !_selectedPhones.contains(val)) {
                            setState(() {
                              _selectedPhones.add(val);
                            });
                          }
                        },
                        decoration: InputDecoration(labelText: 'Mobile Number(s)'),
                      ),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: _selectedPhones
                            .map((phone) {
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
                                  onPressed: () {
                                    setState(() {
                                      _selectedPhones.remove(phone);
                                    });
                                  },
                                ),
                              );
                            })
                            .toList(),
                      ),
                      SizedBox(height: 24),
                      ElevatedButton(
                        onPressed: () {
                          _sendBroadcast();
                        },
                        child: Text('Broadcast'),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            Expanded(
              child: TabBarView(
                children: [
                  // Received Notifications Tab
                  FutureBuilder<List<Map<String, dynamic>>>(
                    future: _getLocalNotifications(),
                    builder: (context, snapshot) {
                      if (snapshot.connectionState == ConnectionState.waiting) {
                        return Center(child: CircularProgressIndicator());
                      }
                      final notifications = snapshot.data ?? [];
                      if (notifications.isEmpty) {
                        return Center(child: Text('No notifications received yet.'));
                      }
                      return ListView.builder(
                        itemCount: notifications.length,
                        itemBuilder: (context, index) {
                          final data = notifications[index];
                          return ListTile(
                            title: Text(data['title'] ?? ''),
                            subtitle: Text(data['body'] ?? ''),
                            trailing: Text(
                              data['receivedAt'] ?? '',
                              style: TextStyle(fontSize: 10),
                            ),
                          );
                        },
                      );
                    },
                  ),
                  // Sent Notifications Tab
                  StreamBuilder<QuerySnapshot>(
                    stream: FirebaseFirestore.instance
                        .collection('broadcasts')
                        .orderBy('sentAt', descending: true)
                        .snapshots(),
                    builder: (context, snapshot) {
                      if (snapshot.connectionState == ConnectionState.waiting) {
                        return Center(child: CircularProgressIndicator());
                      }
                      if (!snapshot.hasData || snapshot.data!.docs.isEmpty) {
                        return Center(child: Text('No sent notifications.'));
                      }
                      final sent = snapshot.data!.docs;
                      return ListView.builder(
                        itemCount: sent.length,
                        itemBuilder: (context, index) {
                          final doc = sent[index];
                          final data = doc.data() as Map<String, dynamic>;
                          return ListTile(
                            title: Text(data['message'] ?? ''),
                            subtitle: Text('To: ${data['phone'] ?? ''}'),
                            trailing: Text(
                              data['sentAt'] != null
                                  ? (data['sentAt'] as Timestamp).toDate().toString()
                                  : '',
                              style: TextStyle(fontSize: 10),
                            ),
                          );
                        },
                      );
                    },
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
