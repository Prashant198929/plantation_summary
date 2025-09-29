import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

class UserRoleManagementPage extends StatefulWidget {
  const UserRoleManagementPage({Key? key}) : super(key: key);

  @override
  State<UserRoleManagementPage> createState() => _UserRoleManagementPageState();
}

class _UserRoleManagementPageState extends State<UserRoleManagementPage> {
  final List<String> roles = ['super_admin', 'admin', 'user'];

  void _updateUserRole(String userId, String newRole) async {
    await FirebaseFirestore.instance.collection('users').doc(userId).update({'role': newRole});
  }

  void _deleteUser(String userId) async {
    await FirebaseFirestore.instance.collection('users').doc(userId).delete();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('User deleted')),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('User Role Management')),
      body: StreamBuilder<QuerySnapshot>(
        stream: FirebaseFirestore.instance.collection('users').snapshots(),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return Center(child: CircularProgressIndicator());
          }
          if (!snapshot.hasData || snapshot.data!.docs.isEmpty) {
            return Center(child: Text('No users found.'));
          }
          final users = snapshot.data!.docs;
          return ListView.builder(
            itemCount: users.length,
            itemBuilder: (context, index) {
              final user = users[index];
              final userId = user.id;
              final userData = user.data() as Map<String, dynamic>;
              final currentRole = userData['role'] ?? 'user';
              final userName = userData['name'] ?? userData['mobile'] ?? 'Unknown';

              return _UserRoleCard(
                userName: userName,
                userId: userId,
                currentRole: currentRole,
                roles: roles,
                onUpdateRole: _updateUserRole,
                onDelete: _deleteUser,
              );
            },
          );
        },
      ),
    );
  }
}

class _UserRoleCard extends StatefulWidget {
  final String userName;
  final String userId;
  final String currentRole;
  final List<String> roles;
  final void Function(String userId, String newRole) onUpdateRole;
  final void Function(String userId) onDelete;

  const _UserRoleCard({
    required this.userName,
    required this.userId,
    required this.currentRole,
    required this.roles,
    required this.onUpdateRole,
    required this.onDelete,
    Key? key,
  }) : super(key: key);

  @override
  State<_UserRoleCard> createState() => _UserRoleCardState();
}

class _UserRoleCardState extends State<_UserRoleCard> {
  late String selectedRole;

  @override
  void initState() {
    super.initState();
    selectedRole = widget.currentRole;
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
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: widget.roles.map((role) {
                  return Row(
                    children: [
                      Radio<String>(
                        value: role,
                        groupValue: selectedRole,
                        onChanged: (val) {
                          setState(() {
                            selectedRole = val!;
                          });
                        },
                      ),
                      Text(role.replaceAll('_', ' ').toUpperCase()),
                    ],
                  );
                }).toList(),
              ),
            ),
            const SizedBox(height: 8),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                ElevatedButton(
                  onPressed: () {
                    if (selectedRole != widget.currentRole) {
                      widget.onUpdateRole(widget.userId, selectedRole);
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text('Role updated to $selectedRole')),
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
