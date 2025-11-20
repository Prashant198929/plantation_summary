import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'firebase_config.dart';

class UserRoleManagementPage extends StatefulWidget {
  const UserRoleManagementPage({Key? key}) : super(key: key);

  @override
  State<UserRoleManagementPage> createState() => _UserRoleManagementPageState();
}

class _UserRoleManagementPageState extends State<UserRoleManagementPage> {
final List<String> mainRoles = ['super_admin', 'admin', 'user'];
  void _updateUserRole(String userId, String newRole) async {
    await FirebaseFirestore.instance.collection('users').doc(userId).update({'role': newRole});
    await FirebaseConfig.logEvent(
      eventType: 'role_update',
      description: 'User role updated',
      userId: userId,
      details: {'newRole': newRole},
    );
  }

  void _deleteUser(String userId) async {
    await FirebaseFirestore.instance.collection('users').doc(userId).delete();
    await FirebaseConfig.logEvent(
      eventType: 'user_deleted',
      description: 'User deleted',
      userId: userId,
    );
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('User deleted')),
    );
  }

  String _searchQuery = '';

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('User Role Management')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(12.0),
            child: TextField(
              decoration: InputDecoration(
                labelText: 'Search by name or mobile',
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.search),
              ),
              onChanged: (val) {
                setState(() {
                  _searchQuery = val.trim().toLowerCase();
                });
              },
            ),
          ),
          Expanded(
            child: StreamBuilder<QuerySnapshot>(
              stream: FirebaseFirestore.instance.collection('users').snapshots(),
              builder: (context, snapshot) {
                if (snapshot.connectionState == ConnectionState.waiting) {
                  return Center(child: CircularProgressIndicator());
                }
                if (!snapshot.hasData || snapshot.data!.docs.isEmpty) {
                  return Center(child: Text('No users found.'));
                }
                final users = snapshot.data!.docs.where((user) {
                  final userData = user.data() as Map<String, dynamic>;
                  final name = (userData['name'] ?? '').toString().toLowerCase();
                  final mobile = (userData['mobile'] ?? '').toString().toLowerCase();
                  return name.contains(_searchQuery) || mobile.contains(_searchQuery);
                }).toList();
                return ListView.builder(
                  itemCount: users.length,
                  itemBuilder: (context, index) {
                    final user = users[index];
                    final userId = user.id;
                    final userData = user.data() as Map<String, dynamic>;
                    final currentRole = userData['role'] ?? 'user';
                    final attendanceViewer = userData['attendance_viewer'] == true;
                    final userName = userData['name'] ?? userData['mobile'] ?? 'Unknown';

                    return _UserRoleCard(
                      userName: userName,
                      userId: userId,
                      currentRole: currentRole,
                      attendanceViewer: attendanceViewer,
                      mainRoles: mainRoles,
                      onUpdateRole: _updateUserRole,
                      onUpdateAttendanceViewer: (userId, checked) async {
                        await FirebaseFirestore.instance.collection('users').doc(userId).update({'attendance_viewer': checked});
                      },
                      onDelete: _deleteUser,
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _UserRoleCard extends StatefulWidget {
  final String userName;
  final String userId;
  final String currentRole;
  final bool attendanceViewer;
  final List<String> mainRoles;
  final void Function(String userId, String newRole) onUpdateRole;
  final void Function(String userId, bool checked) onUpdateAttendanceViewer;
  final void Function(String userId) onDelete;

  const _UserRoleCard({
    required this.userName,
    required this.userId,
    required this.currentRole,
    required this.attendanceViewer,
    required this.mainRoles,
    required this.onUpdateRole,
    required this.onUpdateAttendanceViewer,
    required this.onDelete,
    Key? key,
  }) : super(key: key);

  @override
  State<_UserRoleCard> createState() => _UserRoleCardState();
}

class _UserRoleCardState extends State<_UserRoleCard> {
  late String selectedMainRole;
  late bool attendanceViewerChecked;

  @override
  void initState() {
    super.initState();
    selectedMainRole = widget.currentRole;
    attendanceViewerChecked = widget.attendanceViewer;
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
      child: Padding(
        padding: const EdgeInsets.all(8.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.userName, style: TextStyle(fontWeight: FontWeight.bold)),
            Wrap(
              spacing: 12,
              runSpacing: 8,
              children: [
                ...widget.mainRoles.map((role) => Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Radio<String>(
                      value: role,
                      groupValue: selectedMainRole,
                      onChanged: (val) {
                        setState(() {
                          selectedMainRole = val!;
                        });
                      },
                    ),
                    Text(role.replaceAll('_', ' ').toUpperCase()),
                  ],
                )),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Checkbox(
                      value: attendanceViewerChecked,
                      onChanged: (checked) {
                        setState(() {
                          attendanceViewerChecked = checked ?? false;
                        });
                      },
                    ),
                    Text('ATTENDANCE VIEWER'),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                ElevatedButton(
                  onPressed: () async {
                    bool changed = false;
if (selectedMainRole != widget.currentRole) {
  widget.onUpdateRole(widget.userId, selectedMainRole);
  changed = true;
}
if (attendanceViewerChecked != widget.attendanceViewer) {
  widget.onUpdateAttendanceViewer(widget.userId, attendanceViewerChecked);
  changed = true;
}
                    if (changed) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text('Role(s) updated')),
                      );
                    }
                  },
                  child: Text('Save'),
                ),
                const SizedBox(width: 8),
                IconButton(
                  icon: Icon(Icons.delete, color: Colors.red),
                  onPressed: () {
                    widget.onDelete(widget.userId);
                  },
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
