import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'attendance_support.dart';
import 'firebase_config.dart';
import 'mobile_encryption_service.dart';
import 'transliteration_service.dart';
import 'user_id_service.dart';

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
    'administrator': 'administrator',
    'super_admin': 'super_admin',
    'admin': 'admin',
    'zonal_admin': 'zonal_admin',
    'user': 'user',
    'Shree Sadasya': 'shree_sadsya',
  };
  return roleMap[role] ?? role;
}

class UserRoleManagementPage extends StatefulWidget {
  // The signed-in viewer's own role — Administrator is a strictly higher
  // tier than Super Admin and can assign any role; a Super Admin viewer is
  // restricted to the "day-to-day" tiers only (see mainRoles below).
  final String viewerRole;

  const UserRoleManagementPage({Key? key, required this.viewerRole})
    : super(key: key);

  @override
  State<UserRoleManagementPage> createState() => _UserRoleManagementPageState();
}

class _UserRoleManagementPageState extends State<UserRoleManagementPage> {
  // Administrator (assigned manually — never itself selectable here) sees
  // every role, including Super Admin/User/Shree Sadasya. Anyone else who
  // can reach this page is a Super Admin, who's limited to Admin/Zonal Admin
  // so they can't create or demote a Super Admin, User, or Shree Sadasya
  // account — उपस्थिती प्रशासक (attendance_viewer) stays a separate
  // checkbox below, visible either way.
  List<String> get mainRoles =>
      widget.viewerRole.toLowerCase() == 'administrator'
      ? const ['super_admin', 'admin', 'zonal_admin', 'user', 'Shree Sadasya']
      : const ['admin', 'zonal_admin'];

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
      appBar: AppBar(
        title: Text('वापरकर्ता भूमिका व्यवस्थापन'),
        actions: [
          IconButton(
            icon: const Icon(Icons.person_add),
            tooltip: 'नवीन मेंबर जोडा',
            // The user list below is a live snapshots() StreamBuilder, so a
            // newly added 'users' doc shows up on its own — no manual
            // refresh needed after the dialog closes.
            onPressed: () => showDialog<bool>(
              context: context,
              builder: (_) => const _AddUserRoleDialog(),
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(8.0),
            child: TextField(
              decoration: InputDecoration(
                labelText: 'नाव, मोबाइल किंवा झोनद्वारे शोधा',
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
                  final zone = (userData['zone'] ?? '')
                      .toString()
                      .toLowerCase();
                  final zoneMr = (userData['zone_mr'] ?? '')
                      .toString()
                      .toLowerCase();
                  // Space-stripped compare too, so "Zone34"/"zone34" still
                  // matches a stored "Zone 34" even though the plain
                  // .contains() above would miss it over the space.
                  final searchQueryCompact = _searchQuery.replaceAll(
                    RegExp(r'\s+'),
                    '',
                  );
                  final zoneCompact = zone.replaceAll(RegExp(r'\s+'), '');
                  final zoneMrCompact = zoneMr.replaceAll(RegExp(r'\s+'), '');
                  return name.contains(_searchQuery) ||
                      mobile.contains(_searchQuery) ||
                      zone.contains(_searchQuery) ||
                      zoneMr.contains(_searchQuery) ||
                      zoneCompact.contains(searchQueryCompact) ||
                      zoneMrCompact.contains(searchQueryCompact);
                }).toList();
                return Column(
                  children: [
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 6,
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
      margin: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
      color: hasIssue ? const Color(0xFFFFEBEE) : null,
      child: Padding(
        padding: const EdgeInsets.all(6.0),
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
                  visualDensity: VisualDensity.compact,
                  constraints: const BoxConstraints(),
                  padding: const EdgeInsets.all(8),
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
              spacing: 8,
              runSpacing: 0,
              children: [
                ...widget.mainRoles.map(
                  (role) => Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Radio<String>(
                        value: role,
                        groupValue: selectedMainRole,
                        visualDensity: VisualDensity.compact,
                        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
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
                      visualDensity: VisualDensity.compact,
                      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
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
                    Text('attendance_admin'),
                  ],
                ),
              ],
            ),
            if (_showZoneInfo) ...[
              const SizedBox(height: 4),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 6,
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
            const SizedBox(height: 4),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
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
                  visualDensity: VisualDensity.compact,
                  constraints: const BoxConstraints(),
                  padding: const EdgeInsets.all(8),
                  onPressed: () async {
                    await FirebaseConfig.logEvent(
                      eventType: 'user_delete_clicked',
                      description: 'User delete clicked',
                      userId: widget.userId,
                    );
                    final confirmed = await showDialog<bool>(
                      context: context,
                      builder: (context) => AlertDialog(
                        title: Text('वापरकर्ता हटवायचा?'),
                        content: Text(
                          'तुम्हाला खात्री आहे की तुम्ही "${widget.userName}" या वापरकर्त्याला हटवू इच्छिता? ही क्रिया पूर्ववत करता येणार नाही.',
                        ),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.of(context).pop(false),
                            child: Text('रद्द करा'),
                          ),
                          TextButton(
                            onPressed: () => Navigator.of(context).pop(true),
                            child: Text(
                              'हो, हटवा',
                              style: TextStyle(color: Colors.red),
                            ),
                          ),
                        ],
                      ),
                    );
                    if (confirmed == true) {
                      widget.onDelete(widget.userId);
                    }
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
// login credential once an account has completed its first login, so
// editing it here also calls adminSetUserEmail to update Auth first —
// keeping the Firestore field and the Auth login credential in sync.
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
  // baithakPlace is rendered as one merged बैठक ठिकाण dropdown (picking a
  // BaithakSessions entry fills all four of these); baithak_mr/baithak_day/
  // baithak_day_mr stay in this list purely so the generic save-diff loop
  // below still persists them — see the build() render loop, which skips
  // rendering a separate row for the 3 non-anchor keys.
  ['baithakPlace', 'बैठक ठिकाण'],
  ['baithak_mr', 'बैठक ठिकाण (मराठी)'],
  ['baithak_day', 'बैठक वार'],
  ['baithak_day_mr', 'बैठक वार (मराठी)'],
  ['dob', 'जन्मतारीख (YYYY-MM-DD)'],
  ['hajeri_kramank', 'हजेरी क्रमांक'],
];

// The baithak + zone keys folded into the merged बैठक ठिकाण dropdown — zone
// and zone_mr are derived from whichever baithak session is picked rather
// than edited directly. Still saved via _profileFields, but never given
// their own render row.
const _hiddenBaithakFieldKeys = {
  'baithak_mr',
  'baithak_day',
  'baithak_day_mr',
  'zone',
  'zone_mr',
};

// हजेरी क्रमांक is split into a पटावर/पटाबाहेर type plus the number itself,
// then combined at save time into e.g. "पटावर 104" — mirrors the same split
// in attendance_page.dart's _AddUserBottomSheet / _ShreeSadasyaEditDialog.
const _hajeriTypes = ['पटावर', 'पटाबाहेर'];

// English day name -> Marathi, mirrors register_page.dart's dropdown map.
// baithak_day is picked from this dropdown; baithak_day_mr is always
// derived from that pick, never typed in directly.
const _baithakDayMr = {
  'Monday': 'सोमवार',
  'Tuesday': 'मंगळवार',
  'Wednesday': 'बुधवार',
  'Thursday': 'गुरुवार',
  'Friday': 'शुक्रवार',
  'Saturday': 'शनिवार',
  'Sunday': 'रविवार',
};

class _UserDetailsEditDialogState extends State<_UserDetailsEditDialog> {
  late final TextEditingController _mobileController;
  late final TextEditingController _emailController;
  late final Map<String, TextEditingController> _fieldControllers;
  late bool _isActive;
  bool _saving = false;
  String? _error;

  // Each Marathi field only stops auto-filling from its English counterpart
  // once the admin has manually edited it — mirrors register_page.dart's
  // behavior for name_mr and zone_mr. baithak_mr/baithak_day/baithak_day_mr
  // are no longer manually editable at all — all three are always derived
  // from the single merged बैठक ठिकाण dropdown selection below.
  bool _nameMrTouched = false;
  String? _selectedBaithakSessionMr;
  List<Map<String, String>> _baithakSessionOptions = [];
  FirebaseFirestore? _secondaryFirestore;
  final _newPasswordCtrl = TextEditingController();
  bool _settingPassword = false;
  String? _passwordFieldError;

  // हजेरी क्रमांक's number portion is edited separately from its combined
  // "<type> <number>" value, which stays in _fieldControllers['hajeri_kramank']
  // as the source of truth the generic save-diff loop reads.
  late final TextEditingController _hajeriNoCtrl;
  String? _selectedHajeriType;

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
    _fetchBaithakSessionOptions();

    _hajeriNoCtrl = TextEditingController();
    final storedHajeri = _fieldControllers['hajeri_kramank']?.text.trim() ?? '';
    for (final t in _hajeriTypes) {
      if (storedHajeri.startsWith('$t ')) {
        _selectedHajeriType = t;
        _hajeriNoCtrl.text = storedHajeri.substring(t.length + 1).trim();
        break;
      }
    }
    if (_selectedHajeriType == null && storedHajeri.isNotEmpty) {
      // Legacy free-text value that doesn't match the पटावर/पटाबाहेर
      // pattern — keep it as the number portion instead of losing it; it'll
      // just show with no type selected until the admin picks one.
      _hajeriNoCtrl.text = storedHajeri;
    }
    // Defaults to पटावर (the common case) rather than leaving the dropdown
    // blank.
    _selectedHajeriType ??= _hajeriTypes.first;

    // Marathi fields only lock against auto-fill once the admin manually
    // edits that Marathi box during THIS edit session (see the _mr
    // onChanged handlers below) — an existing saved value does not count
    // as "touched" on its own, so correcting the English field always
    // regenerates the Marathi one to match.
    final name = _fieldControllers['name']?.text.trim() ?? '';
    final nameMr = _fieldControllers['name_mr'];
    if (nameMr != null && nameMr.text.trim().isEmpty && name.isNotEmpty) {
      nameMr.text = TransliterationService.toDevanagari(name);
    }

    // The merged बैठक ठिकाण dropdown is keyed by "<Hall_mr>, <Day_mr>" (the
    // same Session_mr format BaithakSessions docs use), reconstructed from
    // whatever's already stored so an existing record shows a sensible
    // selection even before _baithakSessionOptions finishes loading — if it
    // doesn't match any fetched session it just falls back to its own
    // synthetic dropdown item (same pattern as the old hall/day/zone
    // fallbacks below).
    final storedHallMr = _fieldControllers['baithak_mr']?.text.trim() ?? '';
    var storedDayMr = _fieldControllers['baithak_day_mr']?.text.trim() ?? '';
    if (storedDayMr.isEmpty) {
      final storedDayEn = _fieldControllers['baithak_day']?.text.trim() ?? '';
      storedDayMr = _baithakDayMr.entries
          .firstWhere(
            (e) => e.key.toLowerCase() == storedDayEn.toLowerCase(),
            orElse: () => const MapEntry('', ''),
          )
          .value;
    }
    if (storedHallMr.isNotEmpty && storedDayMr.isNotEmpty) {
      _selectedBaithakSessionMr = '$storedHallMr, $storedDayMr';
    }
  }

  Future<void> _fetchBaithakSessionOptions() async {
    final secondaryApp = await AttendanceSupport.initializeSecondaryApp(
      _secondaryFirestore,
    );
    final firestore = secondaryApp != null
        ? FirebaseFirestore.instanceFor(app: secondaryApp)
        : _secondaryFirestore;
    if (firestore == null) return;
    final options = await AttendanceSupport.fetchBaithakSessionOptions(
      firestore,
    );
    if (!mounted) return;
    setState(() {
      _secondaryFirestore = firestore;
      _baithakSessionOptions = options;
    });
  }

  void _onBaithakSessionChanged(String? sessionMr) {
    setState(() {
      _selectedBaithakSessionMr = sessionMr;
      final session = _baithakSessionOptions.firstWhere(
        (o) => o['sessionMr'] == sessionMr,
        orElse: () => const {},
      );
      _fieldControllers['baithakPlace']!.text = session['hallEn'] ?? '';
      _fieldControllers['baithak_mr']!.text = session['hallMr'] ?? '';
      _fieldControllers['baithak_day']!.text = session['dayEn'] ?? '';
      _fieldControllers['baithak_day_mr']!.text = session['dayMr'] ?? '';
      _fieldControllers['zone']!.text = session['zone'] ?? '';
      _fieldControllers['zone_mr']!.text = session['zoneMr'] ?? '';
    });
  }

  void _autoFillNameMr(String english) {
    if (_nameMrTouched) return;
    setState(() {
      _fieldControllers['name_mr']!.text = TransliterationService.toDevanagari(
        english,
      );
    });
  }

  void _updateHajeriCombined() {
    final type = _selectedHajeriType ?? '';
    final number = _hajeriNoCtrl.text.trim();
    _fieldControllers['hajeri_kramank']!.text =
        type.isNotEmpty && number.isNotEmpty ? '$type $number' : '';
  }

  @override
  void dispose() {
    _mobileController.dispose();
    _emailController.dispose();
    _newPasswordCtrl.dispose();
    _hajeriNoCtrl.dispose();
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
        _error =
            'मोबाईल क्रमांक आणि ईमेल आवश्यक आहेत — आधी ते भरा, मगच इतर तपशील जतन होतील';
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

      if (newEmail != widget.currentEmail) {
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
        // An already-linked email is also the Firebase Auth login
        // credential, so Auth has to be updated first (adminSetUserEmail
        // re-checks the caller's super_admin role server-side) — only once
        // that succeeds is it safe to write the Firestore field, so the two
        // never drift apart.
        if (_emailAlreadyLinked) {
          try {
            await FirebaseFunctions.instanceFor(
              region: 'us-central1',
            ).httpsCallable('adminSetUserEmail').call({
              'authUid': widget.userData['authUid']?.toString() ?? '',
              'currentEmail': widget.currentEmail,
              'newEmail': newEmail,
            });
          } on FirebaseFunctionsException catch (e) {
            setState(() {
              _error = e.message ?? 'ईमेल बदलण्यात अयशस्वी';
              _saving = false;
            });
            return;
          }
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

  bool _validateNewPassword(String v) => RegExp(
    r'^(?=.*[A-Za-z])(?=.*\d)(?=.*[@$!%*#?&])[A-Za-z\d@$!%*#?&]{8,}$',
  ).hasMatch(v);

  // Only a super admin ever reaches this dialog (the tab itself is gated in
  // main.dart), but the client role can't be trusted as the real gate — the
  // adminSetUserPassword Cloud Function re-checks the caller's role from
  // their own 'users' doc before touching Firebase Auth. 'users' docs aren't
  // keyed by Auth uid, so the target account is identified by its stored
  // authUid, falling back to email (mirrors deleteAuthOnUserDelete's lookup).
  Future<void> _setPassword() async {
    final newPassword = _newPasswordCtrl.text.trim();
    if (!_validateNewPassword(newPassword)) {
      setState(() {
        _passwordFieldError =
            'पासवर्ड किमान ८ अक्षरांचा, अक्षर, संख्या आणि विशेष वर्ण असावे';
      });
      return;
    }

    setState(() {
      _settingPassword = true;
      _passwordFieldError = null;
    });

    try {
      final authUid = widget.userData['authUid']?.toString() ?? '';
      await FirebaseFunctions.instanceFor(
        region: 'us-central1',
      ).httpsCallable('adminSetUserPassword').call({
        'authUid': authUid,
        'email': widget.currentEmail,
        'newPassword': newPassword,
      });
      _newPasswordCtrl.clear();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('पासवर्ड यशस्वीरित्या बदलला')),
        );
      }
    } on FirebaseFunctionsException catch (e) {
      setState(() {
        _passwordFieldError = e.message ?? 'पासवर्ड बदलण्यात अयशस्वी';
      });
    } catch (e) {
      setState(() {
        _passwordFieldError = 'पासवर्ड बदलण्यात अयशस्वी: $e';
      });
    } finally {
      if (mounted) setState(() => _settingPassword = false);
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
                const Divider(height: 16),
              ],
              TextField(
                controller: _mobileController,
                enabled: !_saving,
                decoration: const InputDecoration(
                  labelText: 'मोबाईल क्रमांक *',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
                keyboardType: TextInputType.phone,
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _emailController,
                enabled: !_saving,
                decoration: InputDecoration(
                  labelText: 'ईमेल *',
                  border: const OutlineInputBorder(),
                  helperText: _emailAlreadyLinked
                      ? 'हे खाते आधीच लॉगिन झाले आहे — ईमेल बदलल्यास लॉगिन ईमेलही आपोआप अद्ययावत होईल'
                      : null,
                  helperMaxLines: 2,
                ),
                keyboardType: TextInputType.emailAddress,
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _newPasswordCtrl,
                obscureText: true,
                enabled: !_settingPassword,
                decoration: InputDecoration(
                  labelText: 'नवीन पासवर्ड सेट करा',
                  border: const OutlineInputBorder(),
                  errorText: _passwordFieldError,
                  helperText: 'हे थेट वापरकर्त्याचा लॉगिन पासवर्ड बदलते',
                  helperMaxLines: 2,
                ),
                onChanged: (_) => setState(() => _passwordFieldError = null),
              ),
              const SizedBox(height: 4),
              Align(
                alignment: Alignment.centerLeft,
                child: OutlinedButton(
                  onPressed: _settingPassword ? null : _setPassword,
                  child: _settingPassword
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('पासवर्ड सेट करा'),
                ),
              ),
              for (final f in _profileFields) ...[
                if (!_hiddenBaithakFieldKeys.contains(f[0]))
                  const SizedBox(height: 8),
                if (f[0] == 'dob')
                  TextField(
                    controller: _fieldControllers['dob'],
                    enabled: !_saving,
                    readOnly: true,
                    decoration: const InputDecoration(
                      labelText: 'जन्मतारीख (YYYY-MM-DD)',
                      border: OutlineInputBorder(),
                      suffixIcon: Icon(Icons.calendar_today),
                    ),
                    onTap: _saving
                        ? null
                        : () async {
                            final current = DateTime.tryParse(
                              _fieldControllers['dob']!.text.trim(),
                            );
                            final picked = await AttendanceSupport.selectDate(
                              context,
                              current ?? DateTime(2000),
                              minimumDate: DateTime(1940),
                              maximumDate: DateTime.now(),
                            );
                            if (picked != null) {
                              setState(() {
                                _fieldControllers['dob']!.text =
                                    '${picked.year}-${picked.month.toString().padLeft(2, '0')}-${picked.day.toString().padLeft(2, '0')}';
                              });
                            }
                          },
                  )
                else if (f[0] == 'baithakPlace')
                  DropdownButtonFormField<String>(
                    value: _selectedBaithakSessionMr,
                    isExpanded: true,
                    menuMaxHeight: 300,
                    // DropdownButtonFormField's own isDense (separate from
                    // the isDense inside decoration below) defaults to true,
                    // which clamps the closed/selected-value display to a
                    // fixed single-line height, cutting off a wrapped 2nd
                    // line.
                    isDense: false,
                    // Null instead of the default fixed 48px row height, so
                    // long hall names wrap onto multiple lines (both in the
                    // closed field and the open menu) instead of being
                    // ellipsized — same treatment as the attendance page's
                    // baithak hall dropdown.
                    itemHeight: null,
                    decoration: InputDecoration(
                      labelText: f[1],
                      border: const OutlineInputBorder(),
                    ),
                    items: [
                      ..._baithakSessionOptions.map(
                        (o) => DropdownMenuItem(
                          value: o['sessionMr'],
                          child: Padding(
                            padding: const EdgeInsets.symmetric(vertical: 6),
                            child: Text(
                              o['label'] ?? '',
                              style: const TextStyle(fontSize: 12),
                              softWrap: true,
                            ),
                          ),
                        ),
                      ),
                      // Keeps a legacy value that doesn't match any known
                      // session (from back when hall/day were free text)
                      // selectable instead of silently discarding it.
                      if (_selectedBaithakSessionMr != null &&
                          !_baithakSessionOptions.any(
                            (o) => o['sessionMr'] == _selectedBaithakSessionMr,
                          ))
                        DropdownMenuItem(
                          value: _selectedBaithakSessionMr,
                          child: Padding(
                            padding: const EdgeInsets.symmetric(vertical: 6),
                            child: Text(
                              _selectedBaithakSessionMr!,
                              softWrap: true,
                            ),
                          ),
                        ),
                    ],
                    selectedItemBuilder: (context) => [
                      ..._baithakSessionOptions.map(
                        (o) => Align(
                          alignment: Alignment.centerLeft,
                          child: Padding(
                            padding: const EdgeInsets.symmetric(vertical: 6),
                            child: Text(
                              o['label'] ?? '',
                              style: const TextStyle(fontSize: 12),
                              softWrap: true,
                            ),
                          ),
                        ),
                      ),
                      if (_selectedBaithakSessionMr != null &&
                          !_baithakSessionOptions.any(
                            (o) => o['sessionMr'] == _selectedBaithakSessionMr,
                          ))
                        Align(
                          alignment: Alignment.centerLeft,
                          child: Padding(
                            padding: const EdgeInsets.symmetric(vertical: 6),
                            child: Text(
                              _selectedBaithakSessionMr!,
                              softWrap: true,
                            ),
                          ),
                        ),
                    ],
                    onChanged: _saving ? null : _onBaithakSessionChanged,
                  )
                else if (_hiddenBaithakFieldKeys.contains(f[0]))
                  const SizedBox.shrink()
                else if (f[0] == 'hajeri_kramank')
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: DropdownButtonFormField<String>(
                          value: _selectedHajeriType,
                          isExpanded: true,
                          decoration: const InputDecoration(
                            labelText: 'हजेरी क्रमांक प्रकार',
                            border: OutlineInputBorder(),
                          ),
                          items: _hajeriTypes
                              .map(
                                (t) =>
                                    DropdownMenuItem(value: t, child: Text(t)),
                              )
                              .toList(),
                          onChanged: _saving
                              ? null
                              : (val) => setState(() {
                                  _selectedHajeriType = val;
                                  _updateHajeriCombined();
                                }),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: TextField(
                          controller: _hajeriNoCtrl,
                          enabled: !_saving,
                          keyboardType: TextInputType.number,
                          decoration: const InputDecoration(
                            labelText: 'क्रमांक',
                            border: OutlineInputBorder(),
                          ),
                          onChanged: (_) => setState(_updateHajeriCombined),
                        ),
                      ),
                    ],
                  )
                else
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
              const SizedBox(height: 8),
              SwitchListTile(
                dense: true,
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
                const SizedBox(height: 4),
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

// Adds a brand-new 'users' doc (a login-capable account) directly from the
// User Management page — mirrors _UserDetailsEditDialog's field set exactly
// (no gender, no vehicles) but also needs email+password here to create the
// Firebase Auth account, since 'users' (unlike Shree_Sadasya) log in. Role
// always defaults to 'user' — an admin can promote via the edit dialog's
// role radios afterward.
class _AddUserRoleDialog extends StatefulWidget {
  const _AddUserRoleDialog();

  @override
  State<_AddUserRoleDialog> createState() => _AddUserRoleDialogState();
}

class _AddUserRoleDialogState extends State<_AddUserRoleDialog> {
  static const List<String> _hajeriTypes = ['पटावर', 'पटाबाहेर'];

  final _nameCtrl = TextEditingController();
  final _nameMrCtrl = TextEditingController();
  final _mobileCtrl = TextEditingController();
  final _emailCtrl = TextEditingController();
  final _passwordCtrl = TextEditingController();
  final _dobCtrl = TextEditingController();
  final _hajeriCtrl = TextEditingController();
  // Defaults to पटावर (the common case) so adding a new user doesn't need
  // an extra tap for this field.
  String? _selectedHajeriType = _hajeriTypes.first;

  bool _nameMrTouched = false;
  Map<String, String> _errors = {};
  bool _saving = false;

  String? _selectedSessionMr;
  String? _selectedHallEn;
  String? _selectedHallMr;
  String? _selectedDayEn;
  String? _selectedDayMr;
  String? _selectedZone;
  String? _selectedZoneMr;
  List<Map<String, String>> _baithakSessionOptions = [];
  FirebaseFirestore? _secondaryFirestore;

  @override
  void initState() {
    super.initState();
    _fetchBaithakSessionOptions();
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _nameMrCtrl.dispose();
    _mobileCtrl.dispose();
    _emailCtrl.dispose();
    _passwordCtrl.dispose();
    _dobCtrl.dispose();
    _hajeriCtrl.dispose();
    super.dispose();
  }

  Future<void> _fetchBaithakSessionOptions() async {
    final secondaryApp = await AttendanceSupport.initializeSecondaryApp(
      _secondaryFirestore,
    );
    final firestore = secondaryApp != null
        ? FirebaseFirestore.instanceFor(app: secondaryApp)
        : _secondaryFirestore;
    if (firestore == null) return;
    final options = await AttendanceSupport.fetchBaithakSessionOptions(
      firestore,
    );
    if (!mounted) return;
    setState(() {
      _secondaryFirestore = firestore;
      _baithakSessionOptions = options;
    });
  }

  void _onBaithakSessionChanged(String? sessionMr) {
    setState(() {
      _selectedSessionMr = sessionMr;
      final session = _baithakSessionOptions.firstWhere(
        (o) => o['sessionMr'] == sessionMr,
        orElse: () => const {},
      );
      _selectedHallEn = session['hallEn'] ?? '';
      _selectedHallMr = session['hallMr'] ?? '';
      _selectedDayEn = session['dayEn'] ?? '';
      _selectedDayMr = session['dayMr'] ?? '';
      _selectedZone = session['zone'] ?? '';
      _selectedZoneMr = session['zoneMr'] ?? '';
      _errors.remove('baithakPlace');
    });
  }

  void _autoFillNameMr(String english) {
    if (_nameMrTouched) return;
    setState(
      () => _nameMrCtrl.text = TransliterationService.toDevanagari(english),
    );
  }

  bool _validateName(String v) => RegExp(r'^[A-Za-zऀ-ॿ ]+$').hasMatch(v.trim());
  bool _validateMobile(String v) =>
      RegExp(r'^[0-9]{10}$').hasMatch(v.replaceAll(RegExp(r'\D'), ''));
  bool _validateEmail(String v) =>
      RegExp(r'^[\w-\.]+@([\w-]+\.)+[\w-]{2,4}$').hasMatch(v.trim());
  bool _validatePassword(String v) => RegExp(
    r'^(?=.*[A-Za-z])(?=.*\d)(?=.*[@$!%*#?&])[A-Za-z\d@$!%*#?&]{8,}$',
  ).hasMatch(v);

  Future<void> _save() async {
    final name = _nameCtrl.text.trim();
    final nameMr = _nameMrCtrl.text.trim();
    final mobile = _mobileCtrl.text.replaceAll(RegExp(r'\D'), '');
    final baithakPlace = _selectedHallEn ?? '';
    final baithakMr = _selectedHallMr ?? '';
    final baithakDay = _selectedDayEn ?? '';
    final baithakDayMr = _selectedDayMr ?? '';
    final zone = _selectedZone ?? '';
    final zoneMr = _selectedZoneMr ?? '';
    final dob = _dobCtrl.text.trim();
    final hajeriType = _selectedHajeriType ?? '';
    final hajeriNo = _hajeriCtrl.text.trim();
    final hajeri = hajeriType.isNotEmpty && hajeriNo.isNotEmpty
        ? '$hajeriType $hajeriNo'
        : '';
    final email = _emailCtrl.text.trim();
    final password = _passwordCtrl.text.trim();

    final errors = <String, String>{};
    if (!_validateName(name)) errors['name'] = 'नावात फक्त अक्षरे असावीत';
    if (!_validateMobile(mobile))
      errors['mobile'] = 'मोबाइल नंबर १० अंकी असावा';
    if (baithakPlace.isEmpty) errors['baithakPlace'] = 'बैठक ठिकाण आवश्यक आहे';
    if (!_validateEmail(email)) errors['email'] = 'वैध ईमेल पत्ता प्रविष्ट करा';
    if (!_validatePassword(password)) {
      errors['password'] =
          'पासवर्ड किमान ८ अक्षरांचा, अक्षर, संख्या आणि विशेष वर्ण असावे';
    }

    setState(() => _errors = errors);
    if (errors.isNotEmpty) return;

    setState(() => _saving = true);

    try {
      final encryptedMobile = MobileEncryptionService.encrypt(mobile) ?? mobile;
      final dup = await FirebaseFirestore.instance
          .collection('users')
          .where('mobile', isEqualTo: encryptedMobile)
          .get();
      if (dup.docs.isNotEmpty) {
        setState(() {
          _errors['mobile'] = 'मोबाइल नंबर आधीच नोंदणीकृत आहे';
          _saving = false;
        });
        return;
      }

      final dupEmail = await FirebaseFirestore.instance
          .collection('users')
          .where('email', isEqualTo: email)
          .get();
      if (dupEmail.docs.isNotEmpty) {
        setState(() {
          _errors['email'] = 'हा ईमेल आधीच नोंदणीकृत आहे';
          _saving = false;
        });
        return;
      }

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
          _saving = false;
        });
        return;
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
        'hajeri_kramank': hajeri,
        'baithakPlace': baithakPlace,
        'baithak_mr': baithakMr,
        'baithak_day': baithakDay,
        'baithak_day_mr': baithakDayMr,
        'zone': zone,
        'zone_mr': zoneMr,
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

      await FirebaseConfig.logEvent(
        eventType: 'user_added_from_user_management',
        description: 'User added from user management page',
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
        _saving = false;
      });
    }
  }

  Widget _field(
    TextEditingController ctrl,
    String label, {
    String? error,
    TextInputType? keyboardType,
    bool obscure = false,
    void Function(String)? onChanged,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: TextField(
        controller: ctrl,
        enabled: !_saving,
        obscureText: obscure,
        keyboardType: keyboardType,
        decoration: InputDecoration(
          labelText: label,
          border: const OutlineInputBorder(),
          errorText: error,
          isDense: true,
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 12,
            vertical: 10,
          ),
        ),
        onChanged: onChanged,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('नवीन मेंबर जोडा'),
      content: SizedBox(
        width: double.maxFinite,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _field(
                _nameCtrl,
                'पूर्ण नाव (इंग्रजी)',
                error: _errors['name'],
                onChanged: (v) {
                  setState(
                    () => _validateName(v)
                        ? _errors.remove('name')
                        : _errors['name'] = 'नावात फक्त अक्षरे असावीत',
                  );
                  _autoFillNameMr(v);
                },
              ),
              _field(
                _nameMrCtrl,
                'पूर्ण नाव (मराठी)',
                onChanged: (_) => _nameMrTouched = true,
              ),
              _field(
                _mobileCtrl,
                'मोबाइल क्रमांक',
                error: _errors['mobile'],
                keyboardType: TextInputType.phone,
                onChanged: (v) {
                  setState(
                    () => _validateMobile(v)
                        ? _errors.remove('mobile')
                        : _errors['mobile'] = 'मोबाइल नंबर १० अंकी असावा',
                  );
                },
              ),
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: DropdownButtonFormField<String>(
                  value: _selectedSessionMr,
                  isExpanded: true,
                  menuMaxHeight: 300,
                  // DropdownButtonFormField's own isDense (separate from
                  // the isDense inside decoration below) defaults to true,
                  // which clamps the closed/selected-value display to a
                  // fixed single-line height, cutting off a wrapped 2nd
                  // line.
                  isDense: false,
                  // Null instead of the default fixed 48px row height, so
                  // long hall names wrap onto multiple lines (both in the
                  // closed field and the open menu) instead of being
                  // ellipsized — same treatment as the attendance page's
                  // baithak hall dropdown.
                  itemHeight: null,
                  decoration: InputDecoration(
                    labelText: 'बैठक ठिकाण',
                    border: const OutlineInputBorder(),
                    errorText: _errors['baithakPlace'],
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 10,
                    ),
                  ),
                  items: _baithakSessionOptions
                      .map(
                        (o) => DropdownMenuItem(
                          value: o['sessionMr'],
                          child: Padding(
                            padding: const EdgeInsets.symmetric(vertical: 6),
                            child: Text(
                              o['label'] ?? '',
                              style: const TextStyle(fontSize: 12),
                              softWrap: true,
                            ),
                          ),
                        ),
                      )
                      .toList(),
                  selectedItemBuilder: (context) => _baithakSessionOptions
                      .map(
                        (o) => Align(
                          alignment: Alignment.centerLeft,
                          child: Padding(
                            padding: const EdgeInsets.symmetric(vertical: 6),
                            child: Text(
                              o['label'] ?? '',
                              style: const TextStyle(fontSize: 12),
                              softWrap: true,
                            ),
                          ),
                        ),
                      )
                      .toList(),
                  onChanged: _saving ? null : _onBaithakSessionChanged,
                ),
              ),
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: TextField(
                  controller: _dobCtrl,
                  readOnly: true,
                  enabled: !_saving,
                  decoration: const InputDecoration(
                    labelText: 'जन्मतारीख (YYYY-MM-DD)',
                    border: OutlineInputBorder(),
                    suffixIcon: Icon(Icons.calendar_today),
                    isDense: true,
                    contentPadding: EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 10,
                    ),
                  ),
                  onTap: _saving
                      ? null
                      : () async {
                          final picked = await AttendanceSupport.selectDate(
                            context,
                            DateTime(2000),
                            minimumDate: DateTime(1940),
                            maximumDate: DateTime.now(),
                          );
                          if (picked != null) {
                            setState(() {
                              _dobCtrl.text =
                                  '${picked.year}-${picked.month.toString().padLeft(2, '0')}-${picked.day.toString().padLeft(2, '0')}';
                            });
                          }
                        },
                ),
              ),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: DropdownButtonFormField<String>(
                      value: _selectedHajeriType,
                      isExpanded: true,
                      decoration: const InputDecoration(
                        labelText: 'हजेरी क्रमांक प्रकार',
                        border: OutlineInputBorder(),
                        isDense: true,
                        contentPadding: EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 10,
                        ),
                      ),
                      items: _hajeriTypes
                          .map(
                            (t) => DropdownMenuItem(value: t, child: Text(t)),
                          )
                          .toList(),
                      onChanged: _saving
                          ? null
                          : (val) => setState(() => _selectedHajeriType = val),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: _field(
                      _hajeriCtrl,
                      'क्रमांक',
                      keyboardType: TextInputType.number,
                    ),
                  ),
                ],
              ),
              _field(
                _emailCtrl,
                'ईमेल',
                error: _errors['email'],
                keyboardType: TextInputType.emailAddress,
                onChanged: (v) {
                  setState(
                    () => _validateEmail(v)
                        ? _errors.remove('email')
                        : _errors['email'] = 'वैध ईमेल पत्ता प्रविष्ट करा',
                  );
                },
              ),
              _field(
                _passwordCtrl,
                'पासवर्ड',
                error: _errors['password'],
                obscure: true,
                onChanged: (v) {
                  setState(() {
                    _validatePassword(v)
                        ? _errors.remove('password')
                        : _errors['password'] =
                              'पासवर्ड किमान ८ अक्षरांचा, अक्षर, संख्या आणि विशेष वर्ण असावे';
                  });
                },
              ),
              if (_errors['general'] != null)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    _errors['general']!,
                    style: const TextStyle(color: Colors.red),
                  ),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.pop(context, false),
          child: const Text('रद्द करा'),
        ),
        ElevatedButton(
          onPressed: _saving ? null : _save,
          child: _saving
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('जतन करा'),
        ),
      ],
    );
  }
}
