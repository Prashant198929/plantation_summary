import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'firebase_config.dart';
import 'mobile_encryption_service.dart';
import 'transliteration_service.dart';

String _decryptMobile(String? stored) {
  if (stored == null || stored.isEmpty) return '';
  return MobileEncryptionService.decrypt(stored) ?? stored;
}

// Mirrors the key-matching logic login_page.dart uses when locating an
// account's email, since migrated records store it under varying key names.
String _extractEmail(Map<String, dynamic> userData) {
  for (final entry in userData.entries) {
    final key = entry.key.toString().toLowerCase().replaceAll(
      RegExp(r'[^a-z0-9]'),
      '',
    );
    if (key == 'email' ||
        key == 'emailid' ||
        key == 'mail' ||
        key == 'mailid') {
      final value = entry.value?.toString().trim();
      if (value != null &&
          value.isNotEmpty &&
          value.toLowerCase() != 'null' &&
          value.toLowerCase() != 'undefined') {
        return value;
      }
    }
  }
  return '';
}

String _getRoleDisplayName(String role) {
  const roleMap = {
    'super_admin': 'सुपर प्रशासक',
    'admin': 'प्रशासक',
    'zonal_admin': 'झोनल प्रशासक',
    'user': 'वापरकर्ता',
  };
  return roleMap[role] ?? role;
}

class UserRoleManagementPage extends StatefulWidget {
  const UserRoleManagementPage({Key? key}) : super(key: key);

  @override
  State<UserRoleManagementPage> createState() => _UserRoleManagementPageState();
}

class _UserRoleManagementPageState extends State<UserRoleManagementPage> {
  final List<String> mainRoles = [
    'super_admin',
    'admin',
    'zonal_admin',
    'user',
  ];

  @override
  void initState() {
    super.initState();
    Future.microtask(() async {
      await FirebaseConfig.logEvent(
        eventType: 'user_role_page_opened',
        description: 'User role management page opened',
      );
    });
  }

  void _updateUserRole(String userId, String newRole, String? zone) async {
    final Map<String, dynamic> updates = {'role': newRole};
    if (zone != null) updates['zone'] = zone;
    await FirebaseFirestore.instance
        .collection('users')
        .doc(userId)
        .update(updates);
    await FirebaseConfig.logEvent(
      eventType: 'role_update',
      description: 'User role updated',
      userId: userId,
      isImportant: true,
      details: {'newRole': newRole, if (zone != null) 'zone': zone},
    );
  }

  void _deleteUser(String userId) async {
    await FirebaseFirestore.instance.collection('users').doc(userId).delete();
    await FirebaseConfig.logEvent(
      eventType: 'user_deleted',
      description: 'User deleted',
      userId: userId,
      isImportant: true,
    );
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('वापरकर्ता हटवला')));
  }

  String _searchQuery = '';

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('वापरकर्ता भूमिका व्यवस्थापन')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(12.0),
            child: TextField(
              decoration: InputDecoration(
                labelText: 'नाव किंवा मोबाइलद्वारे शोधा',
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
              stream: FirebaseFirestore.instance
                  .collection('users')
                  .snapshots(),
              builder: (context, snapshot) {
                if (snapshot.connectionState == ConnectionState.waiting) {
                  return Center(child: CircularProgressIndicator());
                }
                if (!snapshot.hasData || snapshot.data!.docs.isEmpty) {
                  return Center(child: Text('कोणतेही वापरकर्ते सापडले नाहीत.'));
                }
                final totalCount = snapshot.data!.docs.length;
                // Mobile is stored encrypted, but encryption is deterministic
                // (same plaintext -> same ciphertext), so counting the raw
                // encrypted value directly still correctly finds accounts
                // that share the same real mobile number/placeholder value.
                // '--', '-' and '_' are legacy "no mobile on file" markers
                // from the sevakdb migration, not a real shared number —
                // treat them the same as an empty mobile, never as a
                // duplicate issue.
                const noMobilePlaceholders = {'--', '-', '_'};
                bool isNoMobile(String raw) {
                  if (raw.isEmpty) return true;
                  return noMobilePlaceholders.contains(
                    _decryptMobile(raw).trim(),
                  );
                }

                final mobileCounts = <String, int>{};
                final emailCounts = <String, int>{};
                for (final doc in snapshot.data!.docs) {
                  final data = doc.data() as Map<String, dynamic>;
                  final raw = data['mobile']?.toString() ?? '';
                  if (!isNoMobile(raw)) {
                    mobileCounts[raw] = (mobileCounts[raw] ?? 0) + 1;
                  }
                  final email = _extractEmail(data).toLowerCase();
                  if (email.isNotEmpty) {
                    emailCounts[email] = (emailCounts[email] ?? 0) + 1;
                  }
                }

                // One or more human-readable issue descriptions for this
                // account's mobile/email fields, empty if everything is fine.
                List<String> issuesFor(Map<String, dynamic> data) {
                  final issues = <String>[];
                  final raw = data['mobile']?.toString() ?? '';
                  if (isNoMobile(raw)) {
                    issues.add('मोबाईल क्रमांक नोंदणीकृत नाही');
                  } else if ((mobileCounts[raw] ?? 0) > 1) {
                    issues.add(
                      'मोबाईल क्रमांक इतर ${mobileCounts[raw]! - 1} खात्यांशी जुळतो',
                    );
                  }
                  // Missing email is NOT flagged as an issue — nearly every
                  // sevakdb-migrated account has no email yet by design; it
                  // gets filled in automatically the first time that person
                  // logs in (same self-healing story as fcmToken). Only a
                  // genuine email collision is worth an admin's attention.
                  final email = _extractEmail(data).toLowerCase();
                  if (email.isNotEmpty && (emailCounts[email] ?? 0) > 1) {
                    issues.add(
                      'ईमेल इतर ${emailCounts[email]! - 1} खात्यांशी जुळतो',
                    );
                  }
                  return issues;
                }

                final issueCount = snapshot.data!.docs
                    .where(
                      (doc) => issuesFor(
                        doc.data() as Map<String, dynamic>,
                      ).isNotEmpty,
                    )
                    .length;
                final users = snapshot.data!.docs.where((user) {
                  final userData = user.data() as Map<String, dynamic>;
                  final name = (userData['name'] ?? '')
                      .toString()
                      .toLowerCase();
                  final mobile = _decryptMobile(
                    userData['mobile']?.toString(),
                  ).toLowerCase();
                  return name.contains(_searchQuery) ||
                      mobile.contains(_searchQuery);
                }).toList();
                return Column(
                  children: [
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 8,
                      ),
                      color: const Color(0xFFE8F5E9),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Icon(
                                Icons.people,
                                size: 18,
                                color: Colors.green[800],
                              ),
                              const SizedBox(width: 8),
                              Text(
                                _searchQuery.isEmpty
                                    ? 'एकूण वापरकर्ते: $totalCount'
                                    : '${users.length} / $totalCount वापरकर्ते जुळले',
                                style: TextStyle(
                                  fontWeight: FontWeight.bold,
                                  color: Colors.green[900],
                                ),
                              ),
                            ],
                          ),
                          if (issueCount > 0) ...[
                            const SizedBox(height: 4),
                            Text(
                              '* लाल रंग = समस्या (मोबाईल क्रमांक/ईमेल संबंधित समस्या असलेली $issueCount खाती, तपशीलासाठी (i) बटण दाबा)',
                              style: TextStyle(
                                fontSize: 12,
                                color: Colors.red[700],
                                fontStyle: FontStyle.italic,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                    Expanded(
                      child: ListView.builder(
                        itemCount: users.length,
                        itemBuilder: (context, index) {
                          final user = users[index];
                          final userId = user.id;
                          final userData = user.data() as Map<String, dynamic>;
                          final currentRole = userData['role'] ?? 'user';
                          final currentZone = userData['zone'] as String?;
                          final attendanceViewer =
                              userData['attendance_viewer'] == true;
                          final rawMobile =
                              userData['mobile']?.toString() ?? '';
                          final decryptedMobile = _decryptMobile(rawMobile);
                          final userName =
                              userData['name'] ??
                              (decryptedMobile.isEmpty
                                  ? 'Unknown'
                                  : decryptedMobile);
                          final issues = issuesFor(userData);
                          // Placeholder values ('--', '-', '_') shouldn't be
                          // shown as if they were a real number in the edit
                          // field — present those as blank instead.
                          final mobileForEdit = isNoMobile(rawMobile)
                              ? ''
                              : decryptedMobile;
                          final emailForEdit = _extractEmail(userData);

                          return _UserRoleCard(
                            userName: userName,
                            userId: userId,
                            currentRole: currentRole,
                            currentZone: currentZone,
                            attendanceViewer: attendanceViewer,
                            issues: issues,
                            currentMobile: mobileForEdit,
                            currentEmail: emailForEdit,
                            userData: userData,
                            mainRoles: mainRoles,
                            onUpdateRole: _updateUserRole,
                            onUpdateAttendanceViewer: (userId, checked) async {
                              await FirebaseFirestore.instance
                                  .collection('users')
                                  .doc(userId)
                                  .update({'attendance_viewer': checked});
                            },
                            onDelete: _deleteUser,
                          );
                        },
                      ),
                    ),
                  ],
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
  final String? currentZone;
  final bool attendanceViewer;
  final List<String> issues;
  final String currentMobile;
  final String currentEmail;
  final Map<String, dynamic> userData;
  final List<String> mainRoles;
  final void Function(String userId, String newRole, String? zone) onUpdateRole;
  final void Function(String userId, bool checked) onUpdateAttendanceViewer;
  final void Function(String userId) onDelete;

  const _UserRoleCard({
    required this.userName,
    required this.userId,
    required this.currentRole,
    this.currentZone,
    required this.attendanceViewer,
    required this.issues,
    required this.currentMobile,
    required this.currentEmail,
    required this.userData,
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

  bool get _showZoneInfo =>
      selectedMainRole == 'zonal_admin' || selectedMainRole == 'user';

  @override
  void initState() {
    super.initState();
    selectedMainRole = widget.currentRole;
    attendanceViewerChecked = widget.attendanceViewer;
  }

  @override
  Widget build(BuildContext context) {
    final hasIssue = widget.issues.isNotEmpty;
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
      color: hasIssue ? const Color(0xFFFFEBEE) : null,
      child: Padding(
        padding: const EdgeInsets.all(8.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                if (hasIssue) ...[
                  Icon(Icons.error_outline, size: 16, color: Colors.red[700]),
                  const SizedBox(width: 6),
                ],
                Expanded(
                  child: Text(
                    widget.userName,
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                ),
                IconButton(
                  icon: Icon(
                    hasIssue ? Icons.info_outline : Icons.edit_outlined,
                    size: 20,
                    color: hasIssue ? Colors.red[700] : Colors.grey[700],
                  ),
                  tooltip: 'तपशील पहा / संपादित करा',
                  onPressed: () async {
                    await FirebaseConfig.logEvent(
                      eventType: 'user_details_dialog_opened',
                      description: 'User details dialog opened',
                      userId: widget.userId,
                      details: {'issues': widget.issues},
                    );
                    showDialog(
                      context: context,
                      builder: (context) => _UserDetailsEditDialog(
                        userId: widget.userId,
                        userName: widget.userName,
                        currentMobile: widget.currentMobile,
                        currentEmail: widget.currentEmail,
                        userData: widget.userData,
                        issues: widget.issues,
                      ),
                    );
                  },
                ),
              ],
            ),
            Wrap(
              spacing: 12,
              runSpacing: 8,
              children: [
                ...widget.mainRoles.map(
                  (role) => Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Radio<String>(
                        value: role,
                        groupValue: selectedMainRole,
                        onChanged: (val) {
                          setState(() {
                            selectedMainRole = val!;
                          });
                          Future.microtask(() async {
                            await FirebaseConfig.logEvent(
                              eventType: 'role_radio_selected',
                              description: 'Role radio selected',
                              userId: widget.userId,
                              details: {'selectedRole': selectedMainRole},
                            );
                          });
                        },
                      ),
                      Text(_getRoleDisplayName(role)),
                    ],
                  ),
                ),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Checkbox(
                      value: attendanceViewerChecked,
                      onChanged: (checked) {
                        setState(() {
                          attendanceViewerChecked = checked ?? false;
                        });
                        Future.microtask(() async {
                          await FirebaseConfig.logEvent(
                            eventType: 'attendance_viewer_toggled',
                            description: 'Attendance viewer toggled',
                            userId: widget.userId,
                            details: {
                              'attendanceViewer': attendanceViewerChecked,
                            },
                          );
                        });
                      },
                    ),
                    Text('उपस्थिती दर्शक'),
                  ],
                ),
              ],
            ),
            if (_showZoneInfo) ...[
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 10,
                ),
                decoration: BoxDecoration(
                  border: Border.all(color: Colors.grey.shade400),
                  borderRadius: BorderRadius.circular(4),
                  color: Colors.grey.shade100,
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.location_on_outlined,
                      size: 16,
                      color: Colors.grey[600],
                    ),
                    const SizedBox(width: 8),
                    Text(
                      'नोंदणी झोन: ${widget.currentZone ?? 'माहित नाही'}',
                      style: TextStyle(color: Colors.grey[700], fontSize: 14),
                    ),
                  ],
                ),
              ),
            ],
            const SizedBox(height: 8),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                ElevatedButton(
                  onPressed: () async {
                    await FirebaseConfig.logEvent(
                      eventType: 'role_save_clicked',
                      description: 'Role save clicked',
                      userId: widget.userId,
                      details: {
                        'selectedRole': selectedMainRole,
                        'attendanceViewer': attendanceViewerChecked,
                        if (widget.currentZone != null)
                          'zone': widget.currentZone,
                      },
                    );
                    bool changed = false;
                    if (selectedMainRole != widget.currentRole) {
                      widget.onUpdateRole(
                        widget.userId,
                        selectedMainRole,
                        null,
                      );
                      changed = true;
                    }
                    if (attendanceViewerChecked != widget.attendanceViewer) {
                      widget.onUpdateAttendanceViewer(
                        widget.userId,
                        attendanceViewerChecked,
                      );
                      changed = true;
                    }
                    if (changed) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text('भूमिका अपडेट केली')),
                      );
                    }
                  },
                  child: Text('जतन करा'),
                ),
                const SizedBox(width: 8),
                IconButton(
                  icon: Icon(Icons.delete, color: Colors.red),
                  onPressed: () async {
                    await FirebaseConfig.logEvent(
                      eventType: 'user_delete_clicked',
                      description: 'User delete clicked',
                      userId: widget.userId,
                    );
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

// Full profile editor for a user doc — this is the only place in the app
// where a super admin can update these fields directly (there's no other
// admin screen for it). Mobile is a plain lookup field, so it's always safe
// to edit once uniqueness is checked. Email doubles as the Firebase Auth
// login credential once an account has completed its first login — editing
// it here without also updating Auth would desync login, so it's locked
// (read-only) whenever the account already has an email on file.
class _UserDetailsEditDialog extends StatefulWidget {
  final String userId;
  final String userName;
  final String currentMobile;
  final String currentEmail;
  final Map<String, dynamic> userData;
  final List<String> issues;

  const _UserDetailsEditDialog({
    required this.userId,
    required this.userName,
    required this.currentMobile,
    required this.currentEmail,
    required this.userData,
    required this.issues,
  });

  @override
  State<_UserDetailsEditDialog> createState() => _UserDetailsEditDialogState();
}

// key -> label for every plain-text profile field editable here, beyond
// mobile/email (which need their own special-cased handling above).
const _profileFields = [
  ['name', 'पूर्ण नाव (इंग्रजी)'],
  ['name_mr', 'पूर्ण नाव (मराठी)'],
  ['zone', 'झोन'],
  ['zone_mr', 'झोन (मराठी)'],
  ['baithakPlace', 'बैठक ठिकाण'],
  ['baithak_mr', 'बैठक ठिकाण (मराठी)'],
  ['baithak_day', 'बैठक वार'],
  ['baithak_day_mr', 'बैठक वार (मराठी)'],
  ['baithakNo', 'बैठक क्रमांक'],
  ['hall', 'हॉल'],
  ['hall_mr', 'हॉल (मराठी)'],
  ['gender', 'लिंग (M/F)'],
  ['dob', 'जन्मतारीख (YYYY-MM-DD)'],
  ['hajeri_kramank', 'हजेरी क्रमांक'],
];

class _UserDetailsEditDialogState extends State<_UserDetailsEditDialog> {
  late final TextEditingController _mobileController;
  late final TextEditingController _emailController;
  late final Map<String, TextEditingController> _fieldControllers;
  late bool _isActive;
  bool _saving = false;
  String? _error;

  // Marathi name only stops auto-filling from the English name once the
  // admin has manually edited it — mirrors register_page.dart's behavior.
  bool _nameMrTouched = false;

  bool get _emailAlreadyLinked => widget.currentEmail.isNotEmpty;

  @override
  void initState() {
    super.initState();
    _mobileController = TextEditingController(text: widget.currentMobile);
    _emailController = TextEditingController(text: widget.currentEmail);
    _fieldControllers = {
      for (final f in _profileFields)
        f[0]: TextEditingController(
          text: widget.userData[f[0]]?.toString() ?? '',
        ),
    };
    _isActive = widget.userData['isActive'] == true;

    final name = _fieldControllers['name']?.text.trim() ?? '';
    final nameMr = _fieldControllers['name_mr'];
    if (nameMr != null && nameMr.text.trim().isEmpty && name.isNotEmpty) {
      nameMr.text = TransliterationService.toDevanagari(name);
    } else {
      // Already has a Marathi value — treat as touched so typo fixes to the
      // English name don't silently clobber a previously curated value.
      _nameMrTouched = (nameMr?.text.trim() ?? '').isNotEmpty;
    }
  }

  void _autoFillNameMr(String english) {
    if (_nameMrTouched) return;
    setState(() {
      _fieldControllers['name_mr']!.text =
          TransliterationService.toDevanagari(english);
    });
  }

  @override
  void dispose() {
    _mobileController.dispose();
    _emailController.dispose();
    for (final c in _fieldControllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    final newMobile = _mobileController.text.trim();
    final newEmail = _emailController.text.trim();
    final updates = <String, dynamic>{};

    if (newMobile.isEmpty || newEmail.isEmpty) {
      setState(() {
        _error = 'मोबाईल क्रमांक आणि ईमेल आवश्यक आहेत — आधी ते भरा, मगच इतर तपशील जतन होतील';
      });
      return;
    }

    setState(() {
      _saving = true;
      _error = null;
    });

    try {
      if (newMobile != widget.currentMobile) {
        final encrypted = MobileEncryptionService.encrypt(newMobile);
        if (encrypted == null) {
          setState(() {
            _error = 'मोबाईल क्रमांक कूटबद्ध करण्यात अयशस्वी';
            _saving = false;
          });
          return;
        }
        final clash = await FirebaseFirestore.instance
            .collection('users')
            .where('mobile', isEqualTo: encrypted)
            .get();
        if (clash.docs.any((d) => d.id != widget.userId)) {
          setState(() {
            _error = 'हा मोबाईल क्रमांक आधीच दुसऱ्या खात्यात वापरला आहे';
            _saving = false;
          });
          return;
        }
        updates['mobile'] = encrypted;
      }

      if (!_emailAlreadyLinked &&
          newEmail.isNotEmpty &&
          newEmail != widget.currentEmail) {
        final clash = await FirebaseFirestore.instance
            .collection('users')
            .where('email', isEqualTo: newEmail)
            .get();
        if (clash.docs.any((d) => d.id != widget.userId)) {
          setState(() {
            _error = 'हा ईमेल आधीच दुसऱ्या खात्यात वापरला आहे';
            _saving = false;
          });
          return;
        }
        updates['email'] = newEmail;
      }

      for (final f in _profileFields) {
        final key = f[0];
        final original = widget.userData[key]?.toString() ?? '';
        final edited = _fieldControllers[key]!.text.trim();
        if (edited != original) {
          updates[key] = edited;
        }
      }

      if (_isActive != (widget.userData['isActive'] == true)) {
        updates['isActive'] = _isActive;
      }

      if (updates.isEmpty) {
        if (mounted) Navigator.of(context).pop();
        return;
      }

      await FirebaseFirestore.instance
          .collection('users')
          .doc(widget.userId)
          .update(updates);
      await FirebaseConfig.logEvent(
        eventType: 'user_details_updated',
        description: 'User details updated from details dialog',
        userId: widget.userId,
        isImportant: true,
        details: {'updatedFields': updates.keys.toList()},
      );

      if (mounted) {
        Navigator.of(context).pop();
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('तपशील अद्ययावत केले')));
      }
    } catch (e) {
      setState(() {
        _error = 'जतन करताना त्रुटी: $e';
        _saving = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.userName),
      content: SizedBox(
        width: double.maxFinite,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (widget.issues.isNotEmpty) ...[
                ...widget.issues.map(
                  (issue) => Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(
                          Icons.error_outline,
                          size: 16,
                          color: Colors.red[700],
                        ),
                        const SizedBox(width: 8),
                        Expanded(child: Text(issue)),
                      ],
                    ),
                  ),
                ),
                const Divider(height: 24),
              ],
              TextField(
                controller: _mobileController,
                enabled: !_saving,
                decoration: const InputDecoration(
                  labelText: 'मोबाईल क्रमांक *',
                  border: OutlineInputBorder(),
                ),
                keyboardType: TextInputType.phone,
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _emailController,
                enabled: !_emailAlreadyLinked && !_saving,
                decoration: InputDecoration(
                  labelText: 'ईमेल *',
                  border: const OutlineInputBorder(),
                  helperText: _emailAlreadyLinked
                      ? 'हे खाते आधीच लॉगिन झाले आहे — ईमेल येथून बदलता येणार नाही (बदलल्यास लॉगिन तुटेल)'
                      : null,
                  helperMaxLines: 2,
                ),
                keyboardType: TextInputType.emailAddress,
              ),
              for (final f in _profileFields) ...[
                const SizedBox(height: 12),
                TextField(
                  controller: _fieldControllers[f[0]],
                  enabled: !_saving,
                  decoration: InputDecoration(
                    labelText: f[1],
                    border: const OutlineInputBorder(),
                  ),
                  onChanged: f[0] == 'name'
                      ? _autoFillNameMr
                      : f[0] == 'name_mr'
                          ? (_) => _nameMrTouched = true
                          : null,
                ),
              ],
              const SizedBox(height: 4),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: Text('सक्रिय (Active)'),
                subtitle: Text(
                  'सध्या हे केवळ माहितीसाठी आहे — भविष्यातील वापरासाठी राखीव',
                  style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                ),
                value: _isActive,
                onChanged: null, // disabled for now — reserved for future use
              ),
              if (_error != null) ...[
                const SizedBox(height: 8),
                Text(_error!, style: TextStyle(color: Colors.red[700])),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(),
          child: Text('रद्द करा'),
        ),
        ElevatedButton(
          onPressed: _saving ? null : _save,
          child: _saving
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text('जतन करा'),
        ),
      ],
    );
  }
}
