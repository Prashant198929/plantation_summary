import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:excel/excel.dart' hide Border;
import 'package:excel/excel.dart' as xl;
import 'dart:io';
import 'dart:typed_data';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'main.dart';
import 'attendance_support.dart';
import 'attendance_details.dart';
import 'excel_download_helper.dart';
import 'firebase_config.dart';
import 'mobile_encryption_service.dart';
import 'place_name_service.dart';
import 'transliteration_service.dart';
import 'user_id_service.dart';
import 'vehicle_entry.dart';

class AttendancePage extends StatefulWidget {
  final FirebaseFirestore userFirestore;
  const AttendancePage({Key? key, required this.userFirestore})
    : super(key: key);

  @override
  State<AttendancePage> createState() => _AttendancePageState();
}

class _AttendancePageState extends State<AttendancePage> {
  // झोन only matters (and is only enabled) when marking attendance at this
  // specific place — other Umbarli-adjacent places (e.g. the fertilizer
  // project) don't count, only the exact PlaceName match.
  static const String _umbarliPlaceName = 'उंबार्ली';

  DateTime _selectedDate = DateTime.now();
  List<String> _selectedTopics = [];
  String? _currentZone;
  String? _currentBaithakMr;
  String? _currentUserUid;
  String? _currentUserName;
  String? _currentUserNameMr;
  List<String> _topics = [];
  List<Map<String, dynamic>> _places = [];
  String? _selectedPlace;
  List<Map<String, dynamic>> _zoneUsers = [];
  List<Map<String, dynamic>> _selectedUsers = [];
  // uid -> real Firestore docId of that user's attendance record for
  // _selectedDate AND the currently selected zone (a user can have a
  // separate record per zone per day — see the docId scheme in the submit
  // handler below). Drives the light-green highlight and pre-checked state
  // on the mark-attendance list so backdated lookups show who's covered for
  // this zone and who's still missing. Storing the real docId (rather than
  // recomputing it) means unmark-delete always targets the actual document.
  Map<String, String> _alreadyMarkedDocIds = {};
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
  List<Map<String, dynamic>> _baithakSessions = [];
  String? _selectedBaithakSessionLabel;
  String? _selectedBaithakHallMr;
  String? _selectedBaithakDayMr;
  List<Map<String, dynamic>> _hallUsers = [];
  final TextEditingController _globalSearchController = TextEditingController();
  List<Map<String, dynamic>> _globalSearchResults = [];
  bool _isGlobalSearching = false;
  // Bumped on every _searchAllUsers call so a slower, stale request can't
  // overwrite results from a newer one that finished first.
  int _searchRequestId = 0;
  // Tracks whichever of "search box" / "baithak hall" the admin touched most
  // recently, so the list below always reflects the latest action.
  bool _useGlobalSearchList = false;
  // "Show N entries" pagination for the matched-users list below — purely a
  // client-side page over usersToShow (already fully fetched, not a
  // Firestore query limit). 1-indexed; reset to 1 whenever the underlying
  // list or page size changes so it never lands on a now-out-of-range page.
  static const List<int> _userListPageSizes = [10, 50, 100];
  int _userListPageSize = 50;
  int _userListCurrentPage = 1;

  // The user list to mark attendance for comes only from picking a baithak
  // session or from the mobile/name search — zone is just a tag applied to
  // the attendance record for the day, not a way to fetch a user list.
  List<Map<String, dynamic>> get _displayUsers => _hallUsers;

  // True only when _selectedUsers holds a genuinely pending (not yet saved)
  // pick. _syncAlreadyMarkedForDate / _searchAllUsers auto-add already-marked
  // users to _selectedUsers purely so their checkbox shows checked — those
  // don't count as "pending" since there's nothing the admin actually chose
  // to submit for them. Treating them as pending falsely blocked switching
  // between the hall list and cross-zone search as soon as anyone was
  // already marked that day.
  bool get _hasPendingSelections => _selectedUsers.any(
    (u) => !_alreadyMarkedDocIds.containsKey((u['uid'] ?? '').toString()),
  );

  // A non-admin only ever marks attendance for their own baithak hall, so
  // the hall dropdown is scoped to sessions at their registered baithak_mr
  // instead of listing every hall in the system.
  List<Map<String, dynamic>> get _visibleBaithakSessions => _isSuperAdmin
      ? _baithakSessions
      : AttendanceSupport.filterSessionsByHall(
          _baithakSessions,
          _currentBaithakMr,
        );

  bool _isUserSelected(Map<String, dynamic> user) {
    final uid = user['uid']?.toString();
    return _selectedUsers.any((u) => u['uid']?.toString() == uid);
  }

  void _toggleUserSelection(Map<String, dynamic> user, bool checked) {
    final uid = user['uid']?.toString();
    setState(() {
      if (checked) {
        if (!_selectedUsers.any((u) => u['uid']?.toString() == uid)) {
          _selectedUsers.add(user);
        }
      } else {
        _selectedUsers.removeWhere((u) => u['uid']?.toString() == uid);
      }
    });
  }

  // A tappable field that looks like a dropdown but opens a checklist so the
  // View Attendance filters (place/zone) can select more than one option at
  // once — a plain DropdownButtonFormField only ever holds a single value.
  Widget _multiSelectField({
    required BuildContext context,
    required String label,
    required List<String> options,
    required Set<String> selected,
    required void Function(void Function()) setState,
  }) {
    return InkWell(
      onTap: () => showDialog(
        context: context,
        builder: (dialogContext) {
          return StatefulBuilder(
            builder: (dialogContext, setDialogState) {
              return AlertDialog(
                title: Text(label),
                content: SizedBox(
                  width: double.maxFinite,
                  child: options.isEmpty
                      ? Text('कोणतेही पर्याय उपलब्ध नाहीत.')
                      : ListView(
                          shrinkWrap: true,
                          children: options.map((option) {
                            final checked = selected.contains(option);
                            return CheckboxListTile(
                              value: checked,
                              title: Text(option),
                              onChanged: (v) {
                                setDialogState(() {
                                  setState(() {
                                    if (v == true) {
                                      selected.add(option);
                                    } else {
                                      selected.remove(option);
                                    }
                                  });
                                });
                              },
                            );
                          }).toList(),
                        ),
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(dialogContext),
                    child: Text('ठीक आहे'),
                  ),
                ],
              );
            },
          );
        },
      ),
      child: InputDecorator(
        decoration: InputDecoration(
          labelText: label,
          border: OutlineInputBorder(),
          isDense: true,
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 10,
            vertical: 6,
          ),
        ),
        child: Text(
          selected.isEmpty
              ? 'कृपया निवडा'
              : '${selected.length}/${options.length} निवडले',
        ),
      ),
    );
  }

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
    String? baithakMr;
    String? currentUserUid;
    String? currentUserName;
    String? currentUserNameMr;
    if (userQuery.docs.isNotEmpty) {
      final doc = userQuery.docs.first;
      final data = doc.data();
      final role = data['role']?.toString().toLowerCase();
      isSuperAdmin =
          role == 'super_admin' || role == 'superadmin' || role == 'admin';
      canView = isSuperAdmin || data['attendance_viewer'] == true;
      baithakMr = data['baithak_mr']?.toString();
      currentUserUid = doc.id;
      currentUserName = data['name']?.toString();
      currentUserNameMr = data['name_mr']?.toString();
    }
    if (!mounted) {
      return;
    }
    setState(() {
      _isSuperAdmin = isSuperAdmin;
      _canViewAttendance = canView;
      _roleChecked = true;
      _currentBaithakMr = baithakMr;
      _currentUserUid = currentUserUid;
      _currentUserName = currentUserName;
      _currentUserNameMr = currentUserNameMr;
    });
    if (canView) {
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
      await _fetchBaithakSessions();
      await _fetchCurrentUserZone();
      if (_canViewAttendance) {
        await _fetchZones();
      }
      if (!mounted) {
        return;
      }
      // Sensible defaults on first load: place defaults to उंबार्ली (where
      // झोन applies at all), झोन defaults to the logged-in user's own zone,
      // and बैठक हॉल defaults to whichever session matches their own hall —
      // if their hall meets on 2-3 different days, this just picks one of
      // those matches as the default while the dropdown still lists the rest.
      final matchingHallSessions = AttendanceSupport.filterSessionsByHall(
        _baithakSessions,
        _currentBaithakMr,
      );
      final defaultSession = matchingHallSessions.isEmpty
          ? null
          : matchingHallSessions.first;
      // 'zones' collection entries are stored Marathi-only ("झोन 7"), but a
      // user's own 'zone' field is usually English ("Zone 7") — normalize
      // before assigning, and only if the result is actually one of the
      // dropdown's options, else DropdownButtonFormField throws on a value
      // with zero matching items.
      final normalizedCurrentZone = AttendanceSupport.toMarathiZoneLabel(
        _currentZone ?? '',
      );
      setState(() {
        if (_places.any((p) => p['placeName'] == _umbarliPlaceName)) {
          _selectedPlace = _umbarliPlaceName;
        }
        if (_zones.contains(normalizedCurrentZone)) {
          _selectedZone = normalizedCurrentZone;
        }
        if (defaultSession != null) {
          _selectedBaithakSessionLabel =
              defaultSession['Session_mr'] as String?;
          _selectedBaithakHallMr = defaultSession['Hall_mr'] as String?;
          _selectedBaithakDayMr = defaultSession['Day_mr'] as String?;
        }
      });
      await _fetchZoneUsers();
      if (defaultSession != null) {
        await _fetchHallDayUsers();
      }
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
    _globalSearchController.dispose();
    super.dispose();
  }

  Future<void> _refreshDisplayUsers() async {
    if (_selectedBaithakSessionLabel != null &&
        _selectedBaithakSessionLabel!.isNotEmpty) {
      await _fetchHallDayUsers();
    } else {
      await _fetchZoneUsers();
    }
  }

  Future<void> _fetchHallDayUsers() async {
    // Captured before refetching so a pull-to-refresh (this also runs via
    // _refreshDisplayUsers, wired to the member list's RefreshIndicator —
    // easy to trigger by accident while scrolling) doesn't silently drop
    // whatever the admin already checked. This refetch only ever touches
    // the hall list, never _globalSearchResults, so a pending pick from the
    // cross-zone search box must also be checked against that (still
    // unchanged) list, not just the freshly fetched hall list — otherwise a
    // refresh while browsing search results would drop those picks since
    // their uids can't possibly be in the new hall list. A genuine hall/
    // session switch still clears selection for anyone in neither list.
    final pendingUsers = List<Map<String, dynamic>>.from(_selectedUsers);
    final searchUids = _globalSearchResults
        .map((u) => (u['uid'] ?? '').toString())
        .toSet();
    if (_selectedBaithakSessionLabel == null ||
        _selectedBaithakSessionLabel!.isEmpty) {
      if (!mounted) return;
      setState(() {
        _hallUsers = [];
        _filteredUsers = [];
        _selectedUsers = pendingUsers
            .where((u) => searchUids.contains((u['uid'] ?? '').toString()))
            .toList();
        _userListCurrentPage = 1;
      });
      return;
    }
    final users = await AttendanceSupport.fetchUsersByHallAndDay(
      widget.userFirestore,
      _selectedBaithakHallMr,
      _selectedBaithakDayMr,
    );
    final counts = await AttendanceSupport.fetchAttendanceCounts(
      _secondaryFirestore,
      users.map((u) => (u['uid'] ?? '').toString()).toList(),
    );
    final sortedUsers = AttendanceSupport.sortByAttendanceCount(users, counts);
    if (!mounted) return;
    final hallUids = sortedUsers.map((u) => (u['uid'] ?? '').toString()).toSet();
    setState(() {
      _hallUsers = sortedUsers;
      _filteredUsers = sortedUsers;
      _selectedUsers = pendingUsers.where((u) {
        final uid = (u['uid'] ?? '').toString();
        return hallUids.contains(uid) || searchUids.contains(uid);
      }).toList();
      _userListCurrentPage = 1;
    });
    await _syncAlreadyMarkedForDate();
  }

  // Looks up who's already marked present on _selectedDate FOR THE
  // CURRENTLY SELECTED ZONE specifically (not "marked anywhere that day") —
  // matches the invertedDate_uid_zoneKey docId scheme in the submit handler,
  // which lets the same person have a separate record per zone per day.
  // Applies to both the hall list AND the mobile/name search results, so a
  // person only shows already-marked/green where they're actually covered
  // for the zone currently selected — a different zone genuinely means "not
  // marked here yet." Pre-checks matches so a backdated lookup shows what's
  // covered without re-querying per user — a single day-range query (then
  // filtering by zone client-side, since zone is stored in English or
  // Marathi inconsistently) is simpler than one get() per user.
  Future<void> _syncAlreadyMarkedForDate() async {
    if (_secondaryFirestore == null ||
        (_hallUsers.isEmpty && _globalSearchResults.isEmpty)) {
      if (mounted && _alreadyMarkedDocIds.isNotEmpty) {
        setState(() => _alreadyMarkedDocIds = {});
      }
      return;
    }
    final monthKey = AttendanceSupport.monthYearKey(_selectedDate);
    final startOfDay = DateTime(
      _selectedDate.year,
      _selectedDate.month,
      _selectedDate.day,
    );
    final endOfDay = startOfDay.add(const Duration(days: 1));
    final selectedZoneKey = AttendanceSupport.zoneKey(
      AttendanceSupport.toEnglishZoneLabel(_selectedZone ?? ''),
    );
    try {
      final snap = await _secondaryFirestore!
          .collection('Attendance')
          .doc(monthKey)
          .collection('records')
          .where('date', isGreaterThanOrEqualTo: Timestamp.fromDate(startOfDay))
          .where('date', isLessThan: Timestamp.fromDate(endOfDay))
          .get();
      final markedDocIds = <String, String>{};
      for (final d in snap.docs) {
        final data = d.data();
        final uid = (data['userId'] ?? '').toString();
        if (uid.isEmpty) continue;
        final recordZoneKey = AttendanceSupport.zoneKey(
          AttendanceSupport.toEnglishZoneLabel(
            (data['zone'] ?? data['zone_mr'] ?? '').toString(),
          ),
        );
        if (recordZoneKey == selectedZoneKey) {
          markedDocIds[uid] = d.id;
        }
      }
      if (!mounted) return;
      setState(() {
        _alreadyMarkedDocIds = markedDocIds;
        // Covers _globalSearchResults too, not just _hallUsers — otherwise a
        // cross-zone search result whose already-marked status only becomes
        // known AFTER it was searched (this query finishing later than
        // _searchAllUsers's own one-time pre-check) would show green from
        // this fresh markedDocIds but never get retroactively checked.
        for (final user in [..._hallUsers, ..._globalSearchResults]) {
          final uid = user['uid']?.toString();
          if (uid != null &&
              markedDocIds.containsKey(uid) &&
              !_selectedUsers.any((u) => u['uid']?.toString() == uid)) {
            _selectedUsers.add(user);
          }
        }
      });
    } catch (e) {
      debugPrint('Failed to load already-marked attendance: $e');
    }
  }

  // Unchecking an already-marked user deletes their saved record for
  // _selectedDate + the currently selected zone outright (confirmed by the
  // caller before this runs). Uses the real docId captured in
  // _syncAlreadyMarkedForDate rather than recomputing it, so this targets
  // the exact same document regardless of which docId scheme wrote it
  // (live invertedDate_uid_zoneKey vs any older/migrated variant).
  Future<void> _removeAlreadyMarkedAttendance(Map<String, dynamic> user) async {
    final uid = user['uid']?.toString();
    final docId = uid == null ? null : _alreadyMarkedDocIds[uid];
    if (uid == null || docId == null || _secondaryFirestore == null) return;
    final monthKey = AttendanceSupport.monthYearKey(_selectedDate);
    try {
      await _secondaryFirestore!
          .collection('Attendance')
          .doc(monthKey)
          .collection('records')
          .doc(docId)
          .delete();
      if (!mounted) return;
      setState(() {
        _alreadyMarkedDocIds.remove(uid);
        _selectedUsers.removeWhere((u) => u['uid']?.toString() == uid);
      });
      await FirebaseConfig.logEvent(
        eventType: 'attendance_unmarked',
        description: 'Attendance removed for a previously marked user',
        isImportant: true,
        userId: loggedInMobile,
        details: {
          'userName': user['name'],
          'date': _selectedDate.toIso8601String(),
        },
      );
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('उपस्थिती काढली.')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('उपस्थिती काढताना त्रुटी: $e')));
      }
    }
  }

  // Whichever result set applies right now — a global mobile/name search
  // takes over the list once there's enough to search on, otherwise it falls
  // back to the baithak hall list (see _displayUsers).
  Widget _buildUserListSection() {
    final isGlobalSearchActive = _useGlobalSearchList;
    final hasEnoughSearchText = _globalSearchController.text.trim().length >= 3;
    final usersToShow = isGlobalSearchActive
        ? _globalSearchResults
        : _filteredUsers;
    final showEmptyMessage = !isGlobalSearchActive && _displayUsers.isEmpty;

    if (showEmptyMessage) {
      return Text('कृपया बैठक हॉल निवडा किंवा सदस्य शोधा.');
    }

    return Column(
      children: [
        if (!isGlobalSearchActive)
          TextField(
            controller: _searchController,
            style: TextStyle(fontSize: 13),
            decoration: InputDecoration(
              labelText: 'वापरकर्त्याचे नाव शोधा',
              labelStyle: TextStyle(fontSize: 13),
              border: OutlineInputBorder(),
              prefixIcon: Icon(Icons.search, size: 18),
              // A prefixIcon otherwise reserves a fixed 48x48 min tap-target
              // box regardless of the icon's own size or contentPadding,
              // which was keeping this field visibly taller than the other
              // fields on this page (none of which have a prefixIcon).
              prefixIconConstraints: BoxConstraints(
                minWidth: 32,
                minHeight: 32,
              ),
              isDense: true,
              contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 2),
            ),
            onChanged: (value) {
              setState(() {
                _filteredUsers = _displayUsers
                    .where(
                      (user) => user['name'].toString().toLowerCase().contains(
                        value.toLowerCase(),
                      ),
                    )
                    .toList();
                _userListCurrentPage = 1;
              });
            },
          ),
        if (!isGlobalSearchActive) SizedBox(height: 4),
        if (isGlobalSearchActive && !hasEnoughSearchText)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 4),
            child: Text('किमान ३ अक्षरे किंवा अंक टाका.'),
          ),
        if (isGlobalSearchActive && hasEnoughSearchText && _isGlobalSearching)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 4),
            child: LinearProgressIndicator(),
          ),
        if (isGlobalSearchActive &&
            hasEnoughSearchText &&
            !_isGlobalSearching &&
            usersToShow.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 4),
            child: Text('कोणतेही जुळणारे सदस्य आढळले नाहीत.'),
          ),
        if (usersToShow.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'Show',
                      style: TextStyle(fontSize: 12, color: Colors.grey[700]),
                    ),
                    const SizedBox(width: 6),
                    DropdownButton<int>(
                      value: _userListPageSize,
                      isDense: true,
                      style: TextStyle(fontSize: 12, color: Colors.grey[800]),
                      items: _userListPageSizes
                          .map(
                            (n) =>
                                DropdownMenuItem(value: n, child: Text('$n')),
                          )
                          .toList(),
                      onChanged: (val) {
                        if (val != null) {
                          setState(() {
                            _userListPageSize = val;
                            _userListCurrentPage = 1;
                          });
                        }
                      },
                    ),
                    const SizedBox(width: 6),
                    Text(
                      'entries',
                      style: TextStyle(fontSize: 12, color: Colors.grey[700]),
                    ),
                  ],
                ),
                Text(
                  'निवडलेले सदस्य: ${usersToShow.where(_isUserSelected).length}/${usersToShow.length}',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: Colors.grey[700],
                  ),
                ),
              ],
            ),
          ),
        if (usersToShow.isNotEmpty)
          Expanded(
            child: Builder(
              builder: (context) {
                // int.clamp()/num.clamp() return num, not int, which would
                // break sublist()'s int-only signature below — so page/index
                // bounds are kept in range with plain int ternaries instead.
                final totalCount = usersToShow.length;
                final totalPages = totalCount == 0
                    ? 1
                    : (totalCount / _userListPageSize).ceil();
                final currentPage = _userListCurrentPage < 1
                    ? 1
                    : (_userListCurrentPage > totalPages
                          ? totalPages
                          : _userListCurrentPage);
                final startIdx = (currentPage - 1) * _userListPageSize;
                final endIdxRaw = startIdx + _userListPageSize;
                final endIdx = endIdxRaw > totalCount ? totalCount : endIdxRaw;
                final visibleUsers = usersToShow.sublist(startIdx, endIdx);
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Container(
                        // Fills whatever vertical space is left below the
                        // fixed fields above (the body Column no longer
                        // scrolls as a whole — see the Expanded this section
                        // sits in) instead of a fixed height, so only this
                        // box scrolls while everything above it stays put.
                        // A border/background marks this as its own scrollable
                        // panel — without it, rows sliding past the box's
                        // edge while scrolling look like they're bleeding into
                        // the fields above/below instead of just clipping
                        // inside the box.
                        decoration: BoxDecoration(
                          border: Border.all(color: Colors.grey.shade300),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        clipBehavior: Clip.hardEdge,
                        child: ListView.builder(
                          shrinkWrap: true,
                          physics: const AlwaysScrollableScrollPhysics(),
                          itemCount: visibleUsers.length,
                          itemBuilder: (context, idx) {
                            final user = visibleUsers[idx];
                            final isSelected = _isUserSelected(user);
                            final uid = user['uid']?.toString();
                            // Zone-specific for both the hall list AND the mobile/name
                            // search results — a person only shows already-marked/green
                            // where they're actually covered for the currently selected
                            // zone; a different zone means "not marked here yet."
                            final isAlreadyMarked =
                                uid != null &&
                                _alreadyMarkedDocIds.containsKey(uid);
                            final nameMr =
                                (user['name_mr'] ?? '').toString().isNotEmpty
                                ? user['name_mr'].toString()
                                : TransliterationService.toDevanagari(
                                    (user['name'] ?? '').toString(),
                                  );
                            final nameEn = (user['name'] ?? '').toString();
                            final displayName = nameEn.isNotEmpty
                                ? '$nameMr ($nameEn)'
                                : nameMr;
                            return Container(
                              // CheckboxListTile's own tileColor property paints via a
                              // Material surface that bleeds far past this row's bounds
                              // inside a bounded/shrinkWrap ListView (reproduced in
                              // isolation — the green covered content well below the
                              // scroll box, disappearing once tileColor was removed).
                              // Coloring the wrapping Container instead avoids that
                              // Flutter rendering bug entirely.
                              color: isAlreadyMarked
                                  ? const Color(0xFFDCEDC8)
                                  : null,
                              child: CheckboxListTile(
                                title: Text(
                                  displayName,
                                  style: TextStyle(fontSize: 12),
                                ),
                                subtitle: isGlobalSearchActive
                                    ? Text(
                                        'झोन: ${(user['zone_mr'] ?? '').toString().isNotEmpty ? user['zone_mr'] : user['zone']}   बैठक ठिकाण: ${user['baithak_mr'] ?? ''}'
                                        '${isAlreadyMarked ? '\nया तारखेला आधीच उपस्थिती नोंदवली आहे' : ''}',
                                        style: TextStyle(fontSize: 10),
                                      )
                                    : (isAlreadyMarked
                                          ? Text(
                                              'या तारखेला आधीच उपस्थिती नोंदवली आहे',
                                              style: TextStyle(
                                                fontSize: 10,
                                                color: Colors.green[800],
                                              ),
                                            )
                                          : null),
                                value: isSelected,
                                onChanged: (checked) async {
                                  if (isAlreadyMarked && checked == false) {
                                    final confirm = await showDialog<bool>(
                                      context: context,
                                      builder: (dialogContext) => AlertDialog(
                                        title: Text('उपस्थिती काढायची?'),
                                        content: Text(
                                          '$displayName ची या तारखेची नोंदवलेली उपस्थिती काढायची का?',
                                        ),
                                        actions: [
                                          TextButton(
                                            onPressed: () => Navigator.pop(
                                              dialogContext,
                                              false,
                                            ),
                                            child: Text('नाही'),
                                          ),
                                          TextButton(
                                            onPressed: () => Navigator.pop(
                                              dialogContext,
                                              true,
                                            ),
                                            child: Text('होय, काढा'),
                                          ),
                                        ],
                                      ),
                                    );
                                    if (confirm != true) return;
                                    await _removeAlreadyMarkedAttendance(user);
                                    return;
                                  }
                                  _toggleUserSelection(user, checked == true);
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
                                dense: true,
                                visualDensity: const VisualDensity(
                                  horizontal: -4,
                                  vertical: -4,
                                ),
                                contentPadding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                  vertical: 0,
                                ),
                                materialTapTargetSize:
                                    MaterialTapTargetSize.shrinkWrap,
                                controlAffinity:
                                    ListTileControlAffinity.trailing,
                                secondary: IconButton(
                                  icon: const Icon(Icons.edit, size: 20),
                                  tooltip: 'सदस्य माहिती संपादित करा',
                                  // IconButton otherwise reserves a fixed
                                  // 48x48 min tap-target box regardless of
                                  // the icon's own size, which was pushing
                                  // this row's edit button/checkbox further
                                  // from the corner than needed and eating
                                  // into the name's width.
                                  padding: EdgeInsets.zero,
                                  constraints: const BoxConstraints(
                                    minWidth: 32,
                                    minHeight: 32,
                                  ),
                                  onPressed: () async {
                                    final docId = user['docId']?.toString();
                                    if (docId == null || docId.isEmpty) return;
                                    final saved = await showDialog<bool>(
                                      context: context,
                                      builder: (_) => _ShreeSadasyaEditDialog(
                                        firestore: widget.userFirestore,
                                        secondaryFirestore: _secondaryFirestore,
                                        docId: docId,
                                        user: user,
                                      ),
                                    );
                                    if (saved == true) {
                                      if (isGlobalSearchActive) {
                                        await _searchAllUsers(
                                          _globalSearchController.text,
                                        );
                                      } else {
                                        await _refreshDisplayUsers();
                                      }
                                    }
                                  },
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Row(
                        children: [
                          Flexible(
                            child: Text(
                              'Showing ${totalCount == 0 ? 0 : startIdx + 1} to $endIdx of $totalCount entries',
                              style: TextStyle(
                                fontSize: 11,
                                color: Colors.grey[600],
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          // A SingleChildScrollView with no bounded width just
                          // reports its full unscrolled content width, which
                          // overflowed the Row on narrow screens with several
                          // page buttons — Expanded gives it an actual bound
                          // to scroll within, and Align keeps it flush right
                          // when the buttons don't need the whole width.
                          if (totalPages > 1)
                            Expanded(
                              child: Align(
                                alignment: Alignment.centerRight,
                                child: SingleChildScrollView(
                                  scrollDirection: Axis.horizontal,
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      TextButton(
                                        onPressed: currentPage > 1
                                            ? () => setState(
                                                () => _userListCurrentPage =
                                                    currentPage - 1,
                                              )
                                            : null,
                                        style: TextButton.styleFrom(
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 6,
                                          ),
                                          minimumSize: Size(0, 0),
                                        ),
                                        child: const Text(
                                          'Previous',
                                          style: TextStyle(fontSize: 12),
                                        ),
                                      ),
                                      ...List.generate(
                                        totalPages,
                                        (i) => i + 1,
                                      ).map(
                                        (page) => Padding(
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 2,
                                          ),
                                          child: InkWell(
                                            onTap: () => setState(
                                              () => _userListCurrentPage = page,
                                            ),
                                            borderRadius: BorderRadius.circular(
                                              4,
                                            ),
                                            child: Container(
                                              padding:
                                                  const EdgeInsets.symmetric(
                                                    horizontal: 8,
                                                    vertical: 4,
                                                  ),
                                              decoration: BoxDecoration(
                                                color: page == currentPage
                                                    ? Theme.of(
                                                        context,
                                                      ).primaryColor
                                                    : null,
                                                borderRadius:
                                                    BorderRadius.circular(4),
                                              ),
                                              child: Text(
                                                '$page',
                                                style: TextStyle(
                                                  fontSize: 12,
                                                  color: page == currentPage
                                                      ? Colors.white
                                                      : Colors.black87,
                                                  fontWeight:
                                                      page == currentPage
                                                      ? FontWeight.bold
                                                      : FontWeight.normal,
                                                ),
                                              ),
                                            ),
                                          ),
                                        ),
                                      ),
                                      TextButton(
                                        onPressed: currentPage < totalPages
                                            ? () => setState(
                                                () => _userListCurrentPage =
                                                    currentPage + 1,
                                              )
                                            : null,
                                        style: TextButton.styleFrom(
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 6,
                                          ),
                                          minimumSize: Size(0, 0),
                                        ),
                                        child: const Text(
                                          'Next',
                                          style: TextStyle(fontSize: 12),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
      ],
    );
  }

  Future<void> _searchAllUsers(String query) async {
    if (!mounted) return;
    final requestId = ++_searchRequestId;
    setState(() => _useGlobalSearchList = query.trim().isNotEmpty);
    if (query.trim().length < 3) {
      if (!mounted || requestId != _searchRequestId) return;
      setState(() {
        _globalSearchResults = [];
        _userListCurrentPage = 1;
      });
      return;
    }
    if (!mounted) return;
    setState(() => _isGlobalSearching = true);
    final results = await AttendanceSupport.searchUsers(
      widget.userFirestore,
      query,
    );
    final counts = await AttendanceSupport.fetchAttendanceCounts(
      _secondaryFirestore,
      results.map((u) => (u['uid'] ?? '').toString()).toList(),
    );
    final sortedResults = AttendanceSupport.sortByAttendanceCount(
      results,
      counts,
    );
    if (!mounted || requestId != _searchRequestId) return;
    setState(() {
      _globalSearchResults = sortedResults;
      _isGlobalSearching = false;
      _userListCurrentPage = 1;
      // Mirrors _syncAlreadyMarkedForDate's pre-check for _hallUsers — a
      // search result already marked for the currently selected zone
      // should show checked, matching its green highlight, not just
      // colored-but-unchecked.
      for (final user in sortedResults) {
        final uid = user['uid']?.toString();
        if (uid != null &&
            _alreadyMarkedDocIds.containsKey(uid) &&
            !_selectedUsers.any((u) => u['uid']?.toString() == uid)) {
          _selectedUsers.add(user);
        }
      }
    });
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

  Future<void> _fetchBaithakSessions() async {
    final sessions = await AttendanceSupport.fetchBaithakSessions(
      _secondaryFirestore,
    );
    if (!mounted) {
      return;
    }
    setState(() {
      _baithakSessions = sessions;
    });
  }

  Future<void> _fetchZones() async {
    final zonesSnapshot = await widget.userFirestore
        .collection('zones')
        .orderBy('name', descending: false)
        .get();
    final zonesFromCollection =
        zonesSnapshot.docs
            .map(
              (doc) =>
                  (doc.data() as Map<String, dynamic>)['name']?.toString() ??
                  '',
            )
            .map((name) => name.trim())
            .where((name) => name.isNotEmpty)
            .toSet()
            .toList()
          ..sort(AttendanceSupport.compareZoneNames);

    if (!mounted) {
      return;
    }
    setState(() {
      _zones = zonesFromCollection;
    });
  }

  // _zoneUsers is no longer shown as the mark-attendance list (that only
  // comes from a baithak session or the mobile/name search) — it's kept
  // solely as the zone-name source for the non-admin "View Attendance"
  // export dialog below.
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
        _selectedUsers = [];
      });
      await _syncAlreadyMarkedForDate();
    }
  }

  // Exports everyone marked present on _selectedDate for the currently
  // selected hall + zone, read straight from Firestore — so it includes
  // marks from an earlier, separate visit (e.g. marked 2 hours ago) just as
  // well as ones made in this session, since both are the same query.
  Future<void> _downloadTodayMarkedExcel({bool download = false}) async {
    await FirebaseConfig.logEvent(
      eventType: download
          ? 'attendance_marked_list_download_clicked'
          : 'attendance_marked_list_share_clicked',
      description: download
          ? 'Download marked-by-me list clicked'
          : 'Share marked-by-me list clicked',
      userId: loggedInMobile,
    );
    if (_secondaryFirestore == null) return;
    final monthKey = AttendanceSupport.monthYearKey(_selectedDate);
    final startOfDay = DateTime(
      _selectedDate.year,
      _selectedDate.month,
      _selectedDate.day,
    );
    final endOfDay = startOfDay.add(const Duration(days: 1));
    final selectedZoneKey = AttendanceSupport.zoneKey(
      AttendanceSupport.toEnglishZoneLabel(_selectedZone ?? ''),
    );
    // Match hall membership via _hallUsers' uids (already resolved by
    // fetchUsersByHallAndDay) rather than comparing the record's stored
    // baithak_mr text — older/migrated records often have baithak_mr blank
    // (only the English 'baithak' is guaranteed), which made this filter
    // silently exclude everyone even though they show green/already-marked.
    final hallUserUids = _hallUsers
        .map((u) => (u['uid'] ?? '').toString())
        .where((uid) => uid.isNotEmpty)
        .toSet();
    List<Map<String, dynamic>> records;
    try {
      final snap = await _secondaryFirestore!
          .collection('Attendance')
          .doc(monthKey)
          .collection('records')
          .where('date', isGreaterThanOrEqualTo: Timestamp.fromDate(startOfDay))
          .where('date', isLessThan: Timestamp.fromDate(endOfDay))
          .get();
      records = snap.docs.map((d) => d.data()).where((data) {
        final recordZoneKey = AttendanceSupport.zoneKey(
          AttendanceSupport.toEnglishZoneLabel(
            (data['zone'] ?? data['zone_mr'] ?? '').toString(),
          ),
        );
        if (recordZoneKey != selectedZoneKey) return false;
        if (hallUserUids.isNotEmpty &&
            !hallUserUids.contains((data['userId'] ?? '').toString())) {
          return false;
        }
        return true;
      }).toList();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('यादी आणताना त्रुटी: $e')));
      }
      return;
    }
    if (records.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('अजून कोणतीही उपस्थिती नोंदवलेली नाही.')),
      );
      return;
    }

    final dateLabel =
        '${_selectedDate.year}${_selectedDate.month.toString().padLeft(2, '0')}${_selectedDate.day.toString().padLeft(2, '0')}';
    // Same sheet layout as the attendee-list page's "यादी शेअर करा" export
    // (attendee_details.dart _shareAttendeeDetails), so both exports look
    // identical: || श्री || header block, place/date/topic summary lines,
    // then a bordered क्रमांक/नाव/बैठक/वार/हजेरी क्रमांक/झोन table.
    final sheetName = 'Marked_$dateLabel';
    final excel = Excel.createExcel();
    final defaultSheetName = excel.getDefaultSheet() ?? excel.sheets.keys.first;
    excel.rename(defaultSheetName, sheetName);
    final sheet = excel[sheetName];

    String excelEnglishDay(DateTime dt) {
      const days = [
        'Monday',
        'Tuesday',
        'Wednesday',
        'Thursday',
        'Friday',
        'Saturday',
        'Sunday',
      ];
      return days[dt.weekday - 1];
    }

    String excelEnglishMonth(DateTime dt) {
      const months = [
        'January',
        'February',
        'March',
        'April',
        'May',
        'June',
        'July',
        'August',
        'September',
        'October',
        'November',
        'December',
      ];
      return months[dt.month - 1];
    }

    final headerPlace =
        (records.first['Location_Mr'] ?? records.first['Location_En'] ?? '')
            .toString();

    // Falls back to the user's CURRENT Shree_Sadasya profile for any record
    // whose own baithak/hajeri/name/day fields are blank — the record only
    // ever carries a snapshot of the user's profile from when they were
    // marked, so a record marked before a user's baithak day was filled in
    // (or corrected via Edit) stays blank forever unless we re-check the
    // live profile here too. Same pattern already used for the attendee's
    // own history export and the in-app history table.
    final needsLookupIds = records
        .where(
          (r) =>
              (r['baithak'] ?? '').toString().trim().isEmpty ||
              (r['hajeri_kramank'] ?? '').toString().trim().isEmpty ||
              (r['baithak_mr'] ?? '').toString().trim().isEmpty ||
              (r['name_mr'] ?? '').toString().trim().isEmpty ||
              (r['baithak_day_mr'] ?? '').toString().trim().isEmpty,
        )
        .map((r) => r['userId']?.toString().trim() ?? '')
        .where((id) => id.isNotEmpty)
        .toSet()
        .toList();
    final userLookup = <String, Map<String, dynamic>>{};
    if (needsLookupIds.isNotEmpty) {
      for (int i = 0; i < needsLookupIds.length; i += 30) {
        final chunk = needsLookupIds.sublist(
          i,
          (i + 30).clamp(0, needsLookupIds.length),
        );
        final snap = await widget.userFirestore
            .collection('Shree_Sadasya')
            .where('uid', whereIn: chunk)
            .get();
        for (final doc in snap.docs) {
          final d = doc.data();
          userLookup[d['uid']?.toString() ?? doc.id] = d;
        }
      }
    }

    String getVaar(Map<String, dynamic> r) {
      final mr = (r['baithak_day_mr'] ?? '').toString().trim();
      if (mr.isNotEmpty) return mr;
      final uid = r['userId']?.toString().trim() ?? '';
      final lookupMr =
          userLookup[uid]?['baithak_day_mr']?.toString().trim() ?? '';
      if (lookupMr.isNotEmpty) return lookupMr;
      final en = (r['baithak_day'] ?? '').toString().trim();
      final lookupEn = userLookup[uid]?['baithak_day']?.toString().trim() ?? '';
      final fallbackEn = en.isNotEmpty ? en : lookupEn;
      return AttendanceSupport.toMarathiDayLabel(fallbackEn);
    }

    final topicSet = <String>{};
    for (final record in records) {
      final t = (record['Topic'] ?? '').toString().trim();
      if (t.isNotEmpty) {
        topicSet.addAll(
          t.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty),
        );
      }
    }
    const cols = ['A', 'B', 'C', 'D', 'E', 'F'];

    // Row 1: || श्री || — centered across all columns
    sheet.merge(CellIndex.indexByString('A1'), CellIndex.indexByString('F1'));
    final c1 = sheet.cell(CellIndex.indexByString('A1'));
    c1.value = TextCellValue('|| श्री ||');
    c1.cellStyle = CellStyle(horizontalAlign: HorizontalAlign.Center);

    // Row 2: || श्री राम समर्थ || — centered
    sheet.merge(CellIndex.indexByString('A2'), CellIndex.indexByString('F2'));
    final c2 = sheet.cell(CellIndex.indexByString('A2'));
    c2.value = TextCellValue('|| श्री राम समर्थ ||');
    c2.cellStyle = CellStyle(horizontalAlign: HorizontalAlign.Center);

    // Row 3: empty (spacer)

    // Row 4: Place — centered across all columns
    sheet.merge(CellIndex.indexByString('A4'), CellIndex.indexByString('F4'));
    final placeCell = sheet.cell(CellIndex.indexByString('A4'));
    placeCell.value = TextCellValue('श्री सेवेचे ठिकाण: $headerPlace');
    placeCell.cellStyle = CellStyle(horizontalAlign: HorizontalAlign.Center);

    // Row 5: Date — right-aligned across all columns
    sheet.merge(CellIndex.indexByString('A5'), CellIndex.indexByString('F5'));
    final dateCell = sheet.cell(CellIndex.indexByString('A5'));
    dateCell.value = TextCellValue(
      'दि. ${excelEnglishDay(_selectedDate)}, ${excelEnglishMonth(_selectedDate)} ${_selectedDate.day}, ${_selectedDate.year}',
    );
    dateCell.cellStyle = CellStyle(horizontalAlign: HorizontalAlign.Right);

    // Row 6: empty (spacer)

    // Row 7: कामाचे स्वरूप — unique topics across the marked records
    sheet.merge(CellIndex.indexByString('A7'), CellIndex.indexByString('F7'));
    final topicCell = sheet.cell(CellIndex.indexByString('A7'));
    topicCell.value = TextCellValue('कामाचे स्वरूप: ${topicSet.join(', ')}');

    // Row 8: empty (spacer)

    // Row 9: Column headers with black borders
    const hdrs = ['क्रमांक', 'नाव', 'बैठक', 'वार', 'हजेरी क्रमांक', 'झोन'];
    for (int i = 0; i < hdrs.length; i++) {
      final hc = sheet.cell(CellIndex.indexByString('${cols[i]}9'));
      hc.value = TextCellValue(hdrs[i]);
      hc.cellStyle = CellStyle(
        bold: true,
        leftBorder: xl.Border(borderStyle: xl.BorderStyle.Thin),
        rightBorder: xl.Border(borderStyle: xl.BorderStyle.Thin),
        topBorder: xl.Border(borderStyle: xl.BorderStyle.Thin),
        bottomBorder: xl.Border(borderStyle: xl.BorderStyle.Thin),
      );
    }

    // Data rows from row 10 with black borders
    int serial = 1;
    int dataRow = 10;
    String getName(Map<String, dynamic> r) {
      final mr = (r['name_mr'] ?? '').toString().trim();
      if (mr.isNotEmpty) return mr;
      final uid = r['userId']?.toString().trim() ?? '';
      final lookupMr = userLookup[uid]?['name_mr']?.toString().trim() ?? '';
      if (lookupMr.isNotEmpty) return lookupMr;
      final en = (r['name'] ?? '').toString().trim();
      if (en.isNotEmpty) return en;
      return userLookup[uid]?['name']?.toString().trim() ?? '';
    }

    String getBaithak(Map<String, dynamic> r) {
      final mr = (r['baithak_mr'] ?? '').toString().trim();
      if (mr.isNotEmpty) return mr;
      final uid = r['userId']?.toString().trim() ?? '';
      final lookupMr = userLookup[uid]?['baithak_mr']?.toString().trim() ?? '';
      if (lookupMr.isNotEmpty) return lookupMr;
      final en = (r['baithak'] ?? '').toString().trim();
      if (en.isNotEmpty) return en;
      return userLookup[uid]?['baithak']?.toString().trim() ?? '';
    }

    String getHajeriKramank(Map<String, dynamic> r) {
      final v = (r['hajeri_kramank'] ?? '').toString().trim();
      if (v.isNotEmpty) return v;
      final uid = r['userId']?.toString().trim() ?? '';
      return userLookup[uid]?['hajeri_kramank']?.toString().trim() ?? '';
    }

    for (final record in records) {
      final name = getName(record);
      final baithak = getBaithak(record);
      final vaar = getVaar(record);
      final hajeriKramank = getHajeriKramank(record);
      final zone = (record['zone_mr'] ?? record['zone'] ?? '').toString();
      final rowVals = ['$serial', name, baithak, vaar, hajeriKramank, zone];
      for (int i = 0; i < rowVals.length; i++) {
        final dc = sheet.cell(CellIndex.indexByString('${cols[i]}$dataRow'));
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

    final fileName = 'marked_attendance_$dateLabel.xlsx';
    final bytes = excel.encode()!;

    await FirebaseConfig.logEvent(
      eventType: download
          ? 'attendance_marked_list_downloaded'
          : 'attendance_marked_list_shared',
      description: download
          ? 'Marked-by-me attendance list downloaded'
          : 'Marked-by-me attendance list shared',
      userId: loggedInMobile,
      details: {'date': dateLabel, 'count': records.length},
    );

    if (!mounted) return;

    if (download) {
      await downloadExcelFile(
        context: context,
        bytes: Uint8List.fromList(bytes),
        fileName: fileName,
      );
      return;
    }

    final tempDir = await getTemporaryDirectory();
    final tempFile = File('${tempDir.path}/$fileName');
    await tempFile.writeAsBytes(bytes);
    await Share.shareXFiles([
      XFile(
        tempFile.path,
        mimeType:
            'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
      ),
    ], subject: fileName);
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
                style: TextStyle(color: Colors.grey[700], fontSize: 16),
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
      body: Padding(
        padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
        child: Column(
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'तारीख: ${_selectedDate.toLocal().toString().split(' ')[0]}',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                ),
                Row(
                  children: [
                    if (!_isSuperAdmin)
                      Text(
                        'झोन: ${_currentZone != null ? (RegExp(r'(\d+)').firstMatch(_currentZone!)?.group(1) ?? _currentZone!) : "लोड करत आहे..."}',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    if (_canViewAttendance)
                      IconButton(
                        icon: Icon(Icons.person_add, color: Color(0xFF2E7D32)),
                        tooltip: 'नवीन श्री सदस्य जोडा',
                        onPressed: () async {
                          final added = await showModalBottomSheet<bool>(
                            context: context,
                            isScrollControlled: true,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.vertical(
                                top: Radius.circular(16),
                              ),
                            ),
                            builder: (_) => _AddUserBottomSheet(
                              userFirestore: widget.userFirestore,
                              secondaryFirestore: _secondaryFirestore,
                            ),
                          );
                          if (added == true) await _refreshDisplayUsers();
                        },
                      ),
                  ],
                ),
              ],
            ),
            Align(
              alignment: Alignment.centerLeft,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextButton.icon(
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 4,
                      ),
                      minimumSize: Size.zero,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      visualDensity: VisualDensity.compact,
                    ),
                    icon: Icon(Icons.share, size: 18, color: Color(0xFF2E7D32)),
                    label: Text(
                      'यादी शेअर करा',
                      style: TextStyle(fontSize: 13, color: Color(0xFF2E7D32)),
                    ),
                    onPressed: () => _downloadTodayMarkedExcel(download: false),
                  ),
                  const SizedBox(width: 4),
                  TextButton.icon(
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 4,
                      ),
                      minimumSize: Size.zero,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      visualDensity: VisualDensity.compact,
                    ),
                    icon: Icon(
                      Icons.download,
                      size: 18,
                      color: Color(0xFF2E7D32),
                    ),
                    label: Text(
                      'यादी डाउनलोड करा',
                      style: TextStyle(fontSize: 13, color: Color(0xFF2E7D32)),
                    ),
                    onPressed: () => _downloadTodayMarkedExcel(download: true),
                  ),
                ],
              ),
            ),
            SizedBox(height: 16),
            if (_errorMessage != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 8.0),
                child: Text(
                  _errorMessage!,
                  style: TextStyle(
                    color: Colors.red,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            Expanded(
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(
                    child: _isLoading
                        ? Center(child: CircularProgressIndicator())
                        : Column(
                            children: [
                              Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  GestureDetector(
                                    onTap: () async {
                                      await FirebaseConfig.logEvent(
                                        eventType: 'attendance_topics_clicked',
                                        description:
                                            'Attendance topics clicked',
                                        userId: loggedInMobile,
                                      );
                                      final selected = await showDialog<List<String>>(
                                        context: context,
                                        builder: (context) {
                                          List<String> tempSelected = List.from(
                                            _selectedTopics,
                                          );
                                          return StatefulBuilder(
                                            builder: (context, setStateDialog) {
                                              return AlertDialog(
                                                title: Text(
                                                  'कामाचे स्वरूप निवडा',
                                                ),
                                                content: Container(
                                                  width: double.maxFinite,
                                                  child: ListView(
                                                    shrinkWrap: true,
                                                    children: _topics.map((
                                                      topic,
                                                    ) {
                                                      final isSelected =
                                                          tempSelected.contains(
                                                            topic,
                                                          );
                                                      return CheckboxListTile(
                                                        title: Text(topic),
                                                        value: isSelected,
                                                        onChanged: (checked) {
                                                          setStateDialog(() {
                                                            if (checked ==
                                                                true) {
                                                              if (!tempSelected
                                                                  .contains(
                                                                    topic,
                                                                  )) {
                                                                tempSelected
                                                                    .add(topic);
                                                              }
                                                            } else {
                                                              tempSelected
                                                                  .remove(
                                                                    topic,
                                                                  );
                                                            }
                                                          });
                                                          Future.microtask(() async {
                                                            await FirebaseConfig.logEvent(
                                                              eventType:
                                                                  'attendance_topic_toggled',
                                                              description:
                                                                  'Attendance topic toggled',
                                                              userId:
                                                                  loggedInMobile,
                                                              details: {
                                                                'topic': topic,
                                                                'selected':
                                                                    checked ==
                                                                    true,
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
                                                        eventType:
                                                            'attendance_topics_ok',
                                                        description:
                                                            'Attendance topics OK',
                                                        userId: loggedInMobile,
                                                        details: {
                                                          'topics':
                                                              tempSelected,
                                                        },
                                                      );
                                                      Navigator.of(
                                                        context,
                                                      ).pop(tempSelected);
                                                    },
                                                  ),
                                                  TextButton(
                                                    child: Text('रद्द करा'),
                                                    onPressed: () async {
                                                      await FirebaseConfig.logEvent(
                                                        eventType:
                                                            'attendance_topics_cancel',
                                                        description:
                                                            'Attendance topics cancel',
                                                        userId: loggedInMobile,
                                                      );
                                                      Navigator.of(
                                                        context,
                                                      ).pop(_selectedTopics);
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
                                        labelText: 'कामाचे स्वरूप',
                                        border: OutlineInputBorder(),
                                        isDense: true,
                                        contentPadding: EdgeInsets.symmetric(
                                          horizontal: 10,
                                          vertical: 2,
                                        ),
                                      ),
                                      child: Row(
                                        children: [
                                          Expanded(
                                            child: Text(
                                              _selectedTopics.isEmpty
                                                  ? 'कामाचे स्वरूप निवडा'
                                                  : _selectedTopics.join(', '),
                                              style: TextStyle(
                                                fontSize: 14,
                                                color: _selectedTopics.isEmpty
                                                    ? Theme.of(
                                                        context,
                                                      ).hintColor
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
                              SizedBox(height: 8),
                              DropdownButtonFormField<String>(
                                decoration: InputDecoration(
                                  labelText: 'ठिकाण',
                                  border: OutlineInputBorder(),
                                  isDense: true,
                                  contentPadding: EdgeInsets.symmetric(
                                    horizontal: 10,
                                    vertical: 2,
                                  ),
                                ),
                                value: _selectedPlace,
                                hint: Text(
                                  'ठिकाण निवडा',
                                  style: TextStyle(fontSize: 13),
                                ),
                                items: _places.map((place) {
                                  return DropdownMenuItem(
                                    value: place['placeName'] as String,
                                    child: Text(
                                      place['placeName'] as String,
                                      style: TextStyle(fontSize: 13),
                                    ),
                                  );
                                }).toList(),
                                onChanged: (value) {
                                  final zoneChanged =
                                      value != _umbarliPlaceName &&
                                      _selectedZone != null;
                                  setState(() {
                                    _selectedPlace = value;
                                    // झोन only applies when marking attendance
                                    // at उंबार्ली — clear any stale selection
                                    // for other places, where it's disabled.
                                    if (value != _umbarliPlaceName) {
                                      _selectedZone = null;
                                    }
                                  });
                                  // Already-marked is zone-scoped, so
                                  // clearing the zone needs a fresh
                                  // lookup too.
                                  if (zoneChanged) {
                                    _syncAlreadyMarkedForDate();
                                  }
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
                              SizedBox(height: 8),
                              Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Expanded(
                                    child: TextField(
                                      controller: _workHoursController,
                                      keyboardType:
                                          const TextInputType.numberWithOptions(
                                            decimal: true,
                                          ),
                                      decoration: const InputDecoration(
                                        labelText: 'कामाचे तास (Work Hours)',
                                        border: OutlineInputBorder(),
                                        isDense: true,
                                        contentPadding: EdgeInsets.symmetric(
                                          horizontal: 10,
                                          vertical: 2,
                                        ),
                                      ),
                                      onChanged: (value) {
                                        Future.microtask(() async {
                                          await FirebaseConfig.logEvent(
                                            eventType:
                                                'attendance_work_hours_changed',
                                            description:
                                                'Attendance work hours changed',
                                            userId: loggedInMobile,
                                            details: {'workHours': value},
                                          );
                                        });
                                      },
                                    ),
                                  ),
                                  if (_canViewAttendance) ...[
                                    SizedBox(width: 12),
                                    Expanded(
                                      child: DropdownButtonFormField<String>(
                                        value: _selectedZone,
                                        menuMaxHeight: 300,
                                        isExpanded: true,
                                        hint: Text(
                                          'झोन निवडा',
                                          style: TextStyle(fontSize: 13),
                                        ),
                                        items: _zones
                                            .map(
                                              (zone) => DropdownMenuItem(
                                                value: zone,
                                                child: Text(
                                                  zone,
                                                  style: TextStyle(
                                                    fontSize: 13,
                                                  ),
                                                ),
                                              ),
                                            )
                                            .toList(),
                                        onChanged:
                                            _selectedPlace == _umbarliPlaceName
                                            ? (value) async {
                                                setState(() {
                                                  _selectedZone = value;
                                                  _selectedUsers = [];
                                                  _searchController.clear();
                                                });
                                                // Already-marked is
                                                // zone-scoped, so
                                                // switching zones needs
                                                // a fresh lookup.
                                                await _syncAlreadyMarkedForDate();
                                                await FirebaseConfig.logEvent(
                                                  eventType:
                                                      'attendance_zone_changed',
                                                  description:
                                                      'Attendance zone changed',
                                                  userId: loggedInMobile,
                                                  details: {'zone': value},
                                                );
                                              }
                                            : null,
                                        decoration: const InputDecoration(
                                          labelText: 'झोन',
                                          border: OutlineInputBorder(),
                                          isDense: true,
                                          contentPadding: EdgeInsets.symmetric(
                                            horizontal: 10,
                                            vertical: 2,
                                          ),
                                        ),
                                      ),
                                    ),
                                  ],
                                ],
                              ),
                              SizedBox(height: 8),
                              // Selections made from the baithak-hall list must be marked
                              // (which clears _selectedUsers) before switching to the
                              // cross-zone search — mixing sources mid-selection would let
                              // an admin lose track of who they'd already picked.
                              GestureDetector(
                                onTap:
                                    (_hasPendingSelections &&
                                        !_useGlobalSearchList)
                                    ? () {
                                        ScaffoldMessenger.of(
                                          context,
                                        ).showSnackBar(
                                          const SnackBar(
                                            content: Text(
                                              'कृपया आधी निवडलेल्या सदस्यांची उपस्थिती नोंदवा, त्यानंतर शोधा.',
                                            ),
                                          ),
                                        );
                                      }
                                    : null,
                                child: AbsorbPointer(
                                  absorbing:
                                      _hasPendingSelections &&
                                      !_useGlobalSearchList,
                                  child: TextField(
                                    controller: _globalSearchController,
                                    style: const TextStyle(fontSize: 13),
                                    decoration: const InputDecoration(
                                      labelText:
                                          'दुसऱ्या झोन मधील श्री सदस्य शोधा',
                                      labelStyle: TextStyle(fontSize: 12),
                                      border: OutlineInputBorder(),
                                      prefixIcon: Icon(
                                        Icons.person_search,
                                        size: 18,
                                      ),
                                      // Same fixed 48x48 prefixIcon
                                      // tap-target issue as the user-name
                                      // search field above.
                                      prefixIconConstraints: BoxConstraints(
                                        minWidth: 32,
                                        minHeight: 32,
                                      ),
                                      isDense: true,
                                      contentPadding: EdgeInsets.symmetric(
                                        horizontal: 10,
                                        vertical: 2,
                                      ),
                                    ),
                                    onChanged: _searchAllUsers,
                                  ),
                                ),
                              ),
                              SizedBox(height: 8),
                              // Same rule in reverse — selections made from a cross-zone
                              // search must be marked before switching the baithak hall.
                              GestureDetector(
                                onTap:
                                    (_hasPendingSelections &&
                                        _useGlobalSearchList)
                                    ? () {
                                        ScaffoldMessenger.of(
                                          context,
                                        ).showSnackBar(
                                          const SnackBar(
                                            content: Text(
                                              'कृपया आधी निवडलेल्या सदस्यांची उपस्थिती नोंदवा, त्यानंतर बैठक हॉल बदला.',
                                            ),
                                          ),
                                        );
                                      }
                                    : null,
                                child: AbsorbPointer(
                                  absorbing:
                                      _hasPendingSelections &&
                                      _useGlobalSearchList,
                                  child: DropdownButtonFormField<String>(
                                    value: _selectedBaithakSessionLabel,
                                    menuMaxHeight: 300,
                                    isExpanded: true,
                                    // DropdownButtonFormField's own isDense
                                    // (separate from the isDense inside
                                    // decoration below) defaults to true,
                                    // which clamps the CLOSED/selected-value
                                    // display to a fixed single-line height
                                    // no matter what — cutting off a wrapped
                                    // 2nd line regardless of padding. false
                                    // lets the closed field grow to fit the
                                    // actual selected text.
                                    isDense: false,
                                    // Null instead of the default fixed
                                    // 48px row height, so long hall names
                                    // wrap onto multiple lines (both in the
                                    // closed field and the open menu)
                                    // instead of being clipped/ellipsized.
                                    itemHeight: null,
                                    hint: Text('बैठक हॉल निवडा'),
                                    items: [
                                      ..._visibleBaithakSessions.map(
                                        (session) => DropdownMenuItem(
                                          value:
                                              session['Session_mr'] as String,
                                          child: Padding(
                                            padding: const EdgeInsets.symmetric(
                                              vertical: 6,
                                            ),
                                            child: Text(
                                              AttendanceSupport.sessionLabel(
                                                session,
                                              ),
                                              style: const TextStyle(
                                                fontSize: 12,
                                              ),
                                              softWrap: true,
                                            ),
                                          ),
                                        ),
                                      ),
                                    ],
                                    onChanged: (value) async {
                                      final session = _visibleBaithakSessions
                                          .firstWhere(
                                            (s) => s['Session_mr'] == value,
                                            orElse: () => {},
                                          );
                                      setState(() {
                                        _selectedBaithakSessionLabel = value;
                                        _selectedBaithakHallMr =
                                            session['Hall_mr'] as String?;
                                        _selectedBaithakDayMr =
                                            session['Day_mr'] as String?;
                                        _useGlobalSearchList = false;
                                      });
                                      await _fetchHallDayUsers();
                                      await FirebaseConfig.logEvent(
                                        eventType:
                                            'attendance_baithak_hall_changed',
                                        description:
                                            'Attendance baithak hall changed',
                                        userId: loggedInMobile,
                                        details: {'baithakSession': value},
                                      );
                                    },
                                    decoration: const InputDecoration(
                                      labelText: 'बैठक हॉल',
                                      border: OutlineInputBorder(),
                                      isDense: true,
                                      contentPadding: EdgeInsets.symmetric(
                                        horizontal: 10,
                                        vertical: 6,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                              SizedBox(height: 8),
                              Expanded(
                                child: RefreshIndicator(
                                  onRefresh: () async {
                                    await FirebaseConfig.logEvent(
                                      eventType: 'attendance_pull_refresh',
                                      description: 'Attendance pull to refresh',
                                      userId: loggedInMobile,
                                    );
                                    final topics =
                                        await AttendanceSupport.fetchTopics(
                                          _secondaryFirestore,
                                        );
                                    setState(() {
                                      _topics = topics;
                                      _isLoading = false;
                                    });
                                    await _refreshDisplayUsers();
                                  },
                                  child: _buildUserListSection(),
                                ),
                              ),
                            ],
                          ),
                  ),
                  SizedBox(width: 16),
                ],
              ),
            ),
          ],
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
                        'place': _places.firstWhere(
                          (p) => p['placeName'] == _selectedPlace,
                          orElse: () => <String, dynamic>{
                            'locationEn': _selectedPlace ?? '',
                          },
                        )['locationEn'],
                      },
                    );
                    if (_selectedTopics.isEmpty) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text('कृपया किमान एक कामाचे स्वरूप निवडा'),
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
                    if (_selectedPlace == _umbarliPlaceName &&
                        (_selectedZone == null || _selectedZone!.isEmpty)) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text('कृपया झोन निवडा')),
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
                      orElse: () => <String, dynamic>{
                        'locationEn': _selectedPlace ?? '',
                        'locationMr': _selectedPlace ?? '',
                      },
                    );
                    try {
                      int addedCount = 0;
                      int duplicateCount = 0;
                      String duplicateNames = '';
                      final monthKey = AttendanceSupport.monthYearKey(
                        _selectedDate,
                      );
                      for (final user in _selectedUsers) {
                        final dateKey =
                            '${_selectedDate.year.toString().padLeft(4, '0')}${_selectedDate.month.toString().padLeft(2, '0')}${_selectedDate.day.toString().padLeft(2, '0')}';
                        final invertedDate = 99999999 - int.parse(dateKey);
                        // Zone recorded on the attendance doc is the zone the
                        // work actually happened in today (from the dropdown
                        // above, or the admin's own zone for non-admins), not
                        // the marked user's registered home zone — a user
                        // can work in a zone other than their own. Format
                        // isn't guaranteed here (dropdown is Marathi, a
                        // non-admin's own zone field is usually English), so
                        // normalize both ways rather than assume one.
                        final selectedZone = _selectedZone ?? '';
                        // docId includes the zone key so the same person can
                        // have one record per zone per day, and so it lands
                        // in the same invertedDate_uid_zoneKey scheme already
                        // used by historical sevakdb-migrated attendance
                        // (functions/migration_lib.js) — a plain
                        // invertedDate_uid docId would silently miss those
                        // existing records in the duplicate check below.
                        final zoneKey = AttendanceSupport.zoneKey(
                          AttendanceSupport.toEnglishZoneLabel(selectedZone),
                        );
                        final docId = '${invertedDate}_${user['uid']}_$zoneKey';
                        final docRef = _secondaryFirestore!
                            .collection('Attendance')
                            .doc(monthKey)
                            .collection('records')
                            .doc(docId);
                        final existing = await docRef.get();
                        if (existing.exists) {
                          duplicateCount++;
                          final duplicateDisplayName =
                              (user['name_mr'] ?? '').toString().isNotEmpty
                              ? user['name_mr']
                              : TransliterationService.toDevanagari(
                                  (user['name'] ?? '').toString(),
                                );
                          duplicateNames += '$duplicateDisplayName, ';
                          print(
                            'Duplicate attendance for ${user['name']} on ${_selectedDate.toLocal().toString().split(' ')[0]}',
                          );
                          continue;
                        }
                        final userName = (user['name'] ?? '').toString();
                        final userNameMr = (user['name_mr'] ?? '').toString();
                        final recordData = {
                          'date': Timestamp.fromDate(_selectedDate),
                          'time': DateTime.now().toLocal().toString().split(
                            ' ',
                          )[1],
                          'status': 'Present',
                          'Topic': _selectedTopics.join(', '),
                          'work_hours': _workHoursController.text.trim(),
                          'Location_En': selectedPlaceData['locationEn'] ?? '',
                          'Location_Mr': selectedPlaceData['locationMr'] ?? '',
                          'zone': AttendanceSupport.toEnglishZoneLabel(
                            selectedZone,
                          ),
                          'zone_mr': AttendanceSupport.toMarathiZoneLabel(
                            selectedZone,
                          ),
                          'name': user['name'],
                          // name_mr is optional at registration — fall back to a
                          // best-effort transliteration rather than leaving it blank.
                          'name_mr': userNameMr.isNotEmpty
                              ? userNameMr
                              : TransliterationService.toDevanagari(userName),
                          'userId': user['uid'],
                          'mobile':
                              MobileEncryptionService.encrypt(
                                (user['mobile'] ?? '').toString(),
                              ) ??
                              user['mobile'],
                          'baithak': user['baithak'] ?? '',
                          'baithak_mr': user['baithak_mr'] ?? '',
                          // Persisted (not just kept in-session) so the वार
                          // column in "यादी डाउनलोड करा" can be rebuilt from
                          // Firestore directly — needed for a download to
                          // include marks from an earlier, separate visit,
                          // not just this session's picks.
                          'baithak_day': user['baithak_day'] ?? '',
                          'baithak_day_mr': user['baithak_day_mr'] ?? '',
                          'hajeri_kramank': user['hajeri_kramank'] ?? '',
                          'markedBy_uid': _currentUserUid ?? '',
                          'markedBy_name': _currentUserName ?? '',
                          'markedBy_name_mr': _currentUserNameMr ?? '',
                        };
                        await docRef.set(recordData);
                        print(
                          'Attendance record added for ${user['name']}: $docId',
                        );
                        addedCount++;
                      }
                      String msg = '';
                      // Kept separate from msg below — _errorMessage is
                      // rendered as a permanent block above the member list
                      // (not a transient SnackBar), so it only ever holds the
                      // short count; the full already-marked name list would
                      // grow that block and push the list out of view.
                      String summaryMsg = '';
                      if (addedCount > 0) {
                        summaryMsg = '$addedCount वापरकर्त्यांची उपस्थिती नोंदवली.';
                        msg += '$summaryMsg ';
                        await FirebaseConfig.logEvent(
                          eventType: 'attendance_marked',
                          description: 'Attendance marked',
                          isImportant: true,
                          details: {
                            'count': addedCount,
                            'users': _selectedUsers
                                .map((u) => u['name'])
                                .toList(),
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
                      setState(() {
                        _errorMessage = summaryMsg.isEmpty ? null : summaryMsg;
                      });
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text(
                            msg.isEmpty
                                ? 'कोणतीही उपस्थिती नोंदवली नाही.'
                                : msg,
                          ),
                        ),
                      );
                      setState(() {
                        _selectedUsers = [];
                      });
                      // Without this, the just-marked rows stay stale
                      // (missing green / unchecked) until the admin manually
                      // refreshes or reopens the screen — this re-syncs
                      // _alreadyMarkedDocIds immediately so they show
                      // correctly right away.
                      await _syncAlreadyMarkedForDate();
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
                    // Empty means "no filter" — matches the old usePlace/useZone
                    // unchecked-by-default behavior, but now expressed as
                    // nothing selected in the multi-select list.
                    Set<String> selectedPlaces = {};
                    Set<String> selectedZones = {};

                    int currentYear = DateTime.now().year;
                    List<int> yearsList = List.generate(
                      currentYear - 2020 + 1,
                      (i) => 2020 + i,
                    );
                    int selectedYear = currentYear;

                    bool useStartDate = true;
                    bool useEndDate = true;
                    await showDialog(
                      context: context,
                      builder: (context) {
                        return StatefulBuilder(
                          builder: (context, setState) {
                            return AlertDialog(
                              title: Row(
                                mainAxisAlignment:
                                    MainAxisAlignment.spaceBetween,
                                children: [
                                  Text('उपस्थिती पहा'),
                                  IconButton(
                                    icon: Icon(Icons.close),
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
                              ),
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
                                  ListTile(
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
                                          : DateTime(selectedYear, 12, 31);
                                      DateTime validInitialDate = startDate;
                                      if (validInitialDate.isBefore(earliest)) {
                                        validInitialDate = earliest;
                                      }
                                      if (validInitialDate.isAfter(latest)) {
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
                                  ListTile(
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
                                          : DateTime(selectedYear, 12, 31);
                                      DateTime validInitialDate = endDate;
                                      if (validInitialDate.isBefore(earliest)) {
                                        validInitialDate = earliest;
                                      }
                                      if (validInitialDate.isAfter(latest)) {
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
                                  _multiSelectField(
                                    context: context,
                                    label: 'ठिकाण',
                                    options: _places
                                        .map((p) => p['placeName'] as String)
                                        .toList(),
                                    selected: selectedPlaces,
                                    setState: setState,
                                  ),
                                  SizedBox(height: 8),
                                  _multiSelectField(
                                    context: context,
                                    label: 'झोन',
                                    options:
                                        (_canViewAttendance
                                                ? _zones
                                                : _zoneUsers
                                                      .map(
                                                        (u) =>
                                                            AttendanceSupport.toMarathiZoneLabel(
                                                              (u['zone'] ?? '')
                                                                  .toString(),
                                                            ),
                                                      )
                                                      .toSet()
                                                      .toList())
                                            .where((z) => z.isNotEmpty)
                                            .toList(),
                                    selected: selectedZones,
                                    setState: setState,
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
                                      final logPlaces = selectedPlaces.isEmpty
                                          ? null
                                          : selectedPlaces.toList();
                                      final logZones = selectedZones.isEmpty
                                          ? null
                                          : selectedZones.toList();
                                      print(
                                        '[AttendancePage] Show Attendance: year=$selectedYear, places="$logPlaces", zones="$logZones", startDate=${useStartDate ? startDate : null}, endDate=${useEndDate ? endDate : null}',
                                      );
                                      Navigator.push(
                                        context,
                                        MaterialPageRoute(
                                          builder: (context) =>
                                              AttendanceDetails(
                                                year: selectedYear,
                                                places: logPlaces,
                                                zones: logZones,
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
                                    icon: Icon(Icons.ios_share),
                                    label: Text('यादी शेअर/डाउनलोड करा'),
                                    onPressed: () async {
                                      await FirebaseConfig.logEvent(
                                        eventType: 'attendance_share_clicked',
                                        description: 'Attendance share clicked',
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
                                      final exportAsDownload =
                                          await askShareOrDownload(context);
                                      if (exportAsDownload == null ||
                                          !context.mounted)
                                        return;
                                      // One dialogPlaceData lookup per selected place, so a Marathi
                                      // header/export label is available even for multi-place filters.
                                      final selectedPlaceDataList =
                                          selectedPlaces
                                              .map(
                                                (p) => _places.firstWhere(
                                                  (pl) => pl['placeName'] == p,
                                                  orElse: () =>
                                                      <String, dynamic>{
                                                        'placeName': p,
                                                        'locationEn': p,
                                                        'locationMr': p,
                                                      },
                                                ),
                                              )
                                              .toList();
                                      final normalizedSelectedPlaces =
                                          selectedPlaceDataList
                                              .map(
                                                (d) => (d['locationMr'] ?? '')
                                                    .toString()
                                                    .trim()
                                                    .toLowerCase()
                                                    .replaceAll(
                                                      RegExp(r'\s+'),
                                                      ' ',
                                                    ),
                                              )
                                              .where((p) => p.isNotEmpty)
                                              .toSet();
                                      String normalizeZoneValue(String raw) {
                                        final trimmed = raw
                                            .trim()
                                            .toLowerCase();
                                        final digits =
                                            RegExp(
                                              r'(\d+)',
                                            ).firstMatch(trimmed)?.group(1) ??
                                            '';
                                        return digits.isNotEmpty
                                            ? (int.tryParse(
                                                    digits,
                                                  )?.toString() ??
                                                  digits)
                                            : trimmed;
                                      }

                                      final normalizedSelectedZones =
                                          selectedZones
                                              .map(normalizeZoneValue)
                                              .where((z) => z.isNotEmpty)
                                              .toSet();
                                      final downloadStart = useStartDate
                                          ? DateTime(
                                              startDate.year,
                                              startDate.month,
                                              startDate.day,
                                            )
                                          : DateTime(selectedYear, 1, 1);
                                      final downloadEnd = useEndDate
                                          ? DateTime(
                                              endDate.year,
                                              endDate.month,
                                              endDate.day,
                                              23,
                                              59,
                                              59,
                                              999,
                                            )
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
                                        final snapshot =
                                            await _secondaryFirestore!
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
                                        if (useStartDate &&
                                            dt.isBefore(downloadStart))
                                          return false;
                                        if (useEndDate &&
                                            dt.isAfter(downloadEnd))
                                          return false;
                                        if (normalizedSelectedPlaces
                                            .isNotEmpty) {
                                          final recordPlace =
                                              (data['Location_Mr'] ??
                                                      data['Place'] ??
                                                      '')
                                                  .toString()
                                                  .trim()
                                                  .toLowerCase()
                                                  .replaceAll(
                                                    RegExp(r'\s+'),
                                                    ' ',
                                                  );
                                          if (!normalizedSelectedPlaces
                                              .contains(recordPlace)) {
                                            return false;
                                          }
                                        }
                                        if (normalizedSelectedZones
                                            .isNotEmpty) {
                                          final recordZone = normalizeZoneValue(
                                            (data['zone'] ?? '').toString(),
                                          );
                                          if (!normalizedSelectedZones.contains(
                                            recordZone,
                                          )) {
                                            return false;
                                          }
                                        }
                                        // Only filter by year if not using date range
                                        if (!(useStartDate || useEndDate) &&
                                            dt.year != selectedYear)
                                          return false;
                                        return true;
                                      }).toList();
                                      if (records.isEmpty) {
                                        ScaffoldMessenger.of(
                                          context,
                                        ).showSnackBar(
                                          SnackBar(
                                            content: Text(
                                              'निवडलेल्या फिल्टरसाठी कोणतीही उपस्थिती नोंद आढळली नाही.',
                                            ),
                                          ),
                                        );
                                        return;
                                      }
                                      String excelEnglishDay(DateTime dt) {
                                        const days = [
                                          'Monday',
                                          'Tuesday',
                                          'Wednesday',
                                          'Thursday',
                                          'Friday',
                                          'Saturday',
                                          'Sunday',
                                        ];
                                        return days[dt.weekday - 1];
                                      }

                                      String excelEnglishMonth(DateTime dt) {
                                        const months = [
                                          'January',
                                          'February',
                                          'March',
                                          'April',
                                          'May',
                                          'June',
                                          'July',
                                          'August',
                                          'September',
                                          'October',
                                          'November',
                                          'December',
                                        ];
                                        return months[dt.month - 1];
                                      }

                                      DateTime? firstDt;
                                      final firstDateVal = records.isNotEmpty
                                          ? records.first['date']
                                          : null;
                                      if (firstDateVal is Timestamp)
                                        firstDt = firstDateVal.toDate();
                                      else if (firstDateVal is DateTime)
                                        firstDt = firstDateVal;
                                      firstDt ??= DateTime.now();
                                      final headerPlace =
                                          selectedPlaceDataList.isNotEmpty
                                          ? selectedPlaceDataList
                                                .map(
                                                  (d) =>
                                                      (d['locationMr'] ??
                                                              d['placeName'] ??
                                                              '')
                                                          .toString(),
                                                )
                                                .join(', ')
                                          : (records.isNotEmpty
                                                ? (records.first['Location_Mr']
                                                          ?.toString() ??
                                                      records.first['Place']
                                                          ?.toString() ??
                                                      '')
                                                : '');
                                      // Lookup baithak/hajeri_kramank from main users collection for old records.
                                      // Attendance docs only ever store the English 'baithak' value, never
                                      // 'baithak_mr', so the Marathi name always has to come from the users
                                      // collection (or a phonetic fallback) rather than the record itself.
                                      await PlaceNameService.fetchAll();
                                      final needsLookupIds = records
                                          .where(
                                            (r) =>
                                                (r['baithak'] ?? '')
                                                    .toString()
                                                    .trim()
                                                    .isEmpty ||
                                                (r['hajeri_kramank'] ?? '')
                                                    .toString()
                                                    .trim()
                                                    .isEmpty ||
                                                (r['baithak_mr'] ?? '')
                                                    .toString()
                                                    .trim()
                                                    .isEmpty ||
                                                (r['name_mr'] ?? '')
                                                    .toString()
                                                    .trim()
                                                    .isEmpty ||
                                                (r['baithak_day_mr'] ?? '')
                                                    .toString()
                                                    .trim()
                                                    .isEmpty,
                                          )
                                          .map(
                                            (r) =>
                                                r['userId']
                                                    ?.toString()
                                                    .trim() ??
                                                '',
                                          )
                                          .where((id) => id.isNotEmpty)
                                          .toSet()
                                          .toList();
                                      final userLookup =
                                          <String, Map<String, dynamic>>{};
                                      if (needsLookupIds.isNotEmpty) {
                                        for (
                                          int i = 0;
                                          i < needsLookupIds.length;
                                          i += 30
                                        ) {
                                          final chunk = needsLookupIds.sublist(
                                            i,
                                            (i + 30).clamp(
                                              0,
                                              needsLookupIds.length,
                                            ),
                                          );
                                          final snap = await widget
                                              .userFirestore
                                              .collection('Shree_Sadasya')
                                              .where('uid', whereIn: chunk)
                                              .get();
                                          for (final doc in snap.docs) {
                                            final d = doc.data();
                                            userLookup[d['uid']?.toString() ??
                                                    doc.id] =
                                                d;
                                          }
                                        }
                                      }
                                      String getName(Map<String, dynamic> r) {
                                        final mr =
                                            r['name_mr']?.toString().trim() ??
                                            '';
                                        if (mr.isNotEmpty) return mr;
                                        final uid =
                                            r['userId']?.toString().trim() ??
                                            '';
                                        final lookupMr =
                                            userLookup[uid]?['name_mr']
                                                ?.toString()
                                                .trim() ??
                                            '';
                                        if (lookupMr.isNotEmpty)
                                          return lookupMr;
                                        final en =
                                            r['name']?.toString().trim() ?? '';
                                        final lookupEn =
                                            userLookup[uid]?['name']
                                                ?.toString()
                                                .trim() ??
                                            '';
                                        final fallbackEn = en.isNotEmpty
                                            ? en
                                            : lookupEn;
                                        return fallbackEn.isNotEmpty
                                            ? TransliterationService.toDevanagari(
                                                fallbackEn,
                                              )
                                            : '';
                                      }

                                      String getBaithak(
                                        Map<String, dynamic> r,
                                      ) {
                                        final mr =
                                            r['baithak_mr']
                                                ?.toString()
                                                .trim() ??
                                            '';
                                        if (mr.isNotEmpty) return mr;
                                        final uid =
                                            r['userId']?.toString().trim() ??
                                            '';
                                        final lookupMr =
                                            userLookup[uid]?['baithak_mr']
                                                ?.toString()
                                                .trim() ??
                                            '';
                                        if (lookupMr.isNotEmpty)
                                          return lookupMr;
                                        final v =
                                            r['baithak']?.toString().trim() ??
                                            '';
                                        final english = v.isNotEmpty
                                            ? v
                                            : (userLookup[uid]?['baithakPlace']
                                                      ?.toString() ??
                                                  '');
                                        return PlaceNameService.suggest(
                                          english,
                                        );
                                      }

                                      String getHajeriKramank(
                                        Map<String, dynamic> r,
                                      ) {
                                        final v =
                                            r['hajeri_kramank']
                                                ?.toString()
                                                .trim() ??
                                            '';
                                        if (v.isNotEmpty) return v;
                                        final uid =
                                            r['userId']?.toString().trim() ??
                                            '';
                                        return userLookup[uid]?['hajeri_kramank']
                                                ?.toString() ??
                                            userLookup[uid]?['baithakNo']
                                                ?.toString() ??
                                            '';
                                      }

                                      // The वार column shows the person's fixed weekly baithak
                                      // day (from registration), not the weekday the attendance
                                      // date happens to fall on — those are unrelated, since
                                      // plantation work can happen any day.
                                      String getVaar(Map<String, dynamic> r) {
                                        final mr =
                                            r['baithak_day_mr']
                                                ?.toString()
                                                .trim() ??
                                            '';
                                        if (mr.isNotEmpty) return mr;
                                        final uid =
                                            r['userId']?.toString().trim() ??
                                            '';
                                        final lookupMr =
                                            userLookup[uid]?['baithak_day_mr']
                                                ?.toString()
                                                .trim() ??
                                            '';
                                        if (lookupMr.isNotEmpty)
                                          return lookupMr;
                                        final en =
                                            r['baithak_day']
                                                ?.toString()
                                                .trim() ??
                                            '';
                                        final lookupEn =
                                            userLookup[uid]?['baithak_day']
                                                ?.toString()
                                                .trim() ??
                                            '';
                                        final fallbackEn = en.isNotEmpty
                                            ? en
                                            : lookupEn;
                                        return AttendanceSupport.toMarathiDayLabel(
                                          fallbackEn,
                                        );
                                      }

                                      final rangeStart = useStartDate
                                          ? startDate
                                          : DateTime(selectedYear, 1, 1);
                                      final rangeEnd = useEndDate
                                          ? endDate
                                          : DateTime(selectedYear, 12, 31);
                                      final isSingleDay =
                                          useStartDate &&
                                          useEndDate &&
                                          startDate.year == endDate.year &&
                                          startDate.month == endDate.month &&
                                          startDate.day == endDate.day;
                                      final String excelDateHeader;
                                      if (!useStartDate && !useEndDate) {
                                        excelDateHeader = 'दि. $selectedYear';
                                      } else if (isSingleDay) {
                                        excelDateHeader =
                                            'दि. ${excelEnglishDay(startDate)}, ${excelEnglishMonth(startDate)} ${startDate.day}, ${startDate.year}';
                                      } else {
                                        excelDateHeader =
                                            'दि. ${excelEnglishMonth(rangeStart)} ${rangeStart.day}, ${rangeStart.year} - ${excelEnglishMonth(rangeEnd)} ${rangeEnd.day}, ${rangeEnd.year}';
                                      }
                                      // Compact yyyyMMdd date label shared by the sheet tab name and
                                      // the exported file name, so both read as e.g.
                                      // "..._20260701_to_20260722" instead of a full timestamp dump.
                                      String fmtSheetDate(DateTime d) =>
                                          '${d.year}${d.month.toString().padLeft(2, '0')}${d.day.toString().padLeft(2, '0')}';
                                      final String dateLabel;
                                      if (!useStartDate && !useEndDate) {
                                        dateLabel = '$selectedYear';
                                      } else if (isSingleDay) {
                                        dateLabel = fmtSheetDate(startDate);
                                      } else {
                                        dateLabel =
                                            '${fmtSheetDate(rangeStart)}_to_${fmtSheetDate(rangeEnd)}';
                                      }
                                      // Excel tab names can't contain \/?*[]: and cap at 31 chars —
                                      // dateLabel is already digits/underscores only, so this always fits.
                                      final sheetName = 'Attendance_$dateLabel';
                                      final excel = Excel.createExcel();
                                      // createExcel() always seeds a blank default sheet ('Sheet1') —
                                      // rename it in place instead of creating a second sheet, so the
                                      // exported file has exactly one tab and it opens to the data.
                                      final defaultSheetName =
                                          excel.getDefaultSheet() ??
                                          excel.sheets.keys.first;
                                      excel.rename(defaultSheetName, sheetName);
                                      final sheet = excel[sheetName];
                                      const _cols = [
                                        'A',
                                        'B',
                                        'C',
                                        'D',
                                        'E',
                                        'F',
                                      ];

                                      // Row 1: || श्री || — centered across all 6 columns
                                      sheet.merge(
                                        CellIndex.indexByString('A1'),
                                        CellIndex.indexByString('F1'),
                                      );
                                      final c1 = sheet.cell(
                                        CellIndex.indexByString('A1'),
                                      );
                                      c1.value = TextCellValue('|| श्री ||');
                                      c1.cellStyle = CellStyle(
                                        horizontalAlign: HorizontalAlign.Center,
                                      );

                                      // Row 2: || श्री राम समर्थ || — centered
                                      sheet.merge(
                                        CellIndex.indexByString('A2'),
                                        CellIndex.indexByString('F2'),
                                      );
                                      final c2 = sheet.cell(
                                        CellIndex.indexByString('A2'),
                                      );
                                      c2.value = TextCellValue(
                                        '|| श्री राम समर्थ ||',
                                      );
                                      c2.cellStyle = CellStyle(
                                        horizontalAlign: HorizontalAlign.Center,
                                      );

                                      // Row 3: empty (spacer)

                                      // Row 4: Place — centered across all columns
                                      sheet.merge(
                                        CellIndex.indexByString('A4'),
                                        CellIndex.indexByString('F4'),
                                      );
                                      final placeCell = sheet.cell(
                                        CellIndex.indexByString('A4'),
                                      );
                                      placeCell.value = TextCellValue(
                                        'श्री सेवेचे ठिकाण: $headerPlace',
                                      );
                                      placeCell.cellStyle = CellStyle(
                                        horizontalAlign: HorizontalAlign.Center,
                                      );

                                      // Row 5: Date — right-aligned across all columns
                                      sheet.merge(
                                        CellIndex.indexByString('A5'),
                                        CellIndex.indexByString('F5'),
                                      );
                                      final dateCell = sheet.cell(
                                        CellIndex.indexByString('A5'),
                                      );
                                      dateCell.value = TextCellValue(
                                        excelDateHeader,
                                      );
                                      dateCell.cellStyle = CellStyle(
                                        horizontalAlign: HorizontalAlign.Right,
                                      );

                                      // Row 6: empty (spacer)

                                      // Row 7: कामाचे स्वरूप — unique topics across the filtered records
                                      final topicSet = <String>{};
                                      for (final record in records) {
                                        final t =
                                            record['Topic']
                                                ?.toString()
                                                .trim() ??
                                            '';
                                        if (t.isNotEmpty)
                                          topicSet.addAll(
                                            t
                                                .split(',')
                                                .map((e) => e.trim())
                                                .where((e) => e.isNotEmpty),
                                          );
                                      }
                                      sheet.merge(
                                        CellIndex.indexByString('A7'),
                                        CellIndex.indexByString('F7'),
                                      );
                                      final topicCell = sheet.cell(
                                        CellIndex.indexByString('A7'),
                                      );
                                      topicCell.value = TextCellValue(
                                        'कामाचे स्वरूप: ${topicSet.join(', ')}',
                                      );

                                      // Row 8: empty (spacer)

                                      // Row 9: Column headers with black borders
                                      final _hdrs = [
                                        'क्रमांक',
                                        'नाव',
                                        'बैठक',
                                        'वार',
                                        'हजेरी क्रमांक',
                                        'झोन',
                                      ];
                                      for (int i = 0; i < _hdrs.length; i++) {
                                        final hc = sheet.cell(
                                          CellIndex.indexByString(
                                            '${_cols[i]}9',
                                          ),
                                        );
                                        hc.value = TextCellValue(_hdrs[i]);
                                        hc.cellStyle = CellStyle(
                                          bold: true,
                                          leftBorder: xl.Border(
                                            borderStyle: xl.BorderStyle.Thin,
                                          ),
                                          rightBorder: xl.Border(
                                            borderStyle: xl.BorderStyle.Thin,
                                          ),
                                          topBorder: xl.Border(
                                            borderStyle: xl.BorderStyle.Thin,
                                          ),
                                          bottomBorder: xl.Border(
                                            borderStyle: xl.BorderStyle.Thin,
                                          ),
                                        );
                                      }

                                      // Data rows from row 10 with black borders
                                      int serial = 1;
                                      int dataRow = 10;
                                      for (final record in records) {
                                        final recordZoneMr =
                                            record['zone_mr']
                                                ?.toString()
                                                .trim() ??
                                            '';
                                        final rowVals = [
                                          '$serial',
                                          getName(record),
                                          getBaithak(record),
                                          getVaar(record),
                                          getHajeriKramank(record),
                                          recordZoneMr.isNotEmpty
                                              ? recordZoneMr
                                              : AttendanceSupport.toMarathiZoneLabel(
                                                  record['zone']?.toString() ??
                                                      '',
                                                ),
                                        ];
                                        for (
                                          int i = 0;
                                          i < rowVals.length;
                                          i++
                                        ) {
                                          final dc = sheet.cell(
                                            CellIndex.indexByString(
                                              '${_cols[i]}$dataRow',
                                            ),
                                          );
                                          dc.value = TextCellValue(rowVals[i]);
                                          dc.cellStyle = CellStyle(
                                            leftBorder: xl.Border(
                                              borderStyle: xl.BorderStyle.Thin,
                                            ),
                                            rightBorder: xl.Border(
                                              borderStyle: xl.BorderStyle.Thin,
                                            ),
                                            topBorder: xl.Border(
                                              borderStyle: xl.BorderStyle.Thin,
                                            ),
                                            bottomBorder: xl.Border(
                                              borderStyle: xl.BorderStyle.Thin,
                                            ),
                                          );
                                        }
                                        serial++;
                                        dataRow++;
                                      }
                                      final filterParts = <String>[
                                        'attendance',
                                        dateLabel,
                                      ];
                                      if (normalizedSelectedPlaces.isNotEmpty) {
                                        filterParts.add(
                                          'place${normalizedSelectedPlaces.map((p) => p.replaceAll(RegExp(r'\s+'), '')).join('_')}',
                                        );
                                      }
                                      if (normalizedSelectedZones.isNotEmpty) {
                                        filterParts.add(
                                          'zone${normalizedSelectedZones.join('_')}',
                                        );
                                      }
                                      final fileName =
                                          filterParts
                                              .join('_')
                                              .replaceAll(
                                                RegExp(r'[^\w\d]'),
                                                '',
                                              ) +
                                          '.xlsx';
                                      final bytes = excel.encode()!;

                                      await FirebaseConfig.logEvent(
                                        eventType: exportAsDownload
                                            ? 'attendance_list_downloaded'
                                            : 'attendance_list_shared',
                                        description: exportAsDownload
                                            ? 'Attendance List downloaded as Excel'
                                            : 'Attendance List shared as Excel',
                                        details: {
                                          'timestamp': DateTime.now()
                                              .toIso8601String(),
                                          'type': 'attendance',
                                          'filters': {
                                            'year': selectedYear,
                                            'places': selectedPlaceDataList
                                                .map((d) => d['locationEn'])
                                                .toList(),
                                            'zones': selectedZones.toList(),
                                            'startDate': useStartDate
                                                ? startDate.toIso8601String()
                                                : null,
                                            'endDate': useEndDate
                                                ? endDate.toIso8601String()
                                                : null,
                                          },
                                        },
                                      );

                                      if (!context.mounted) return;

                                      if (exportAsDownload) {
                                        await downloadExcelFile(
                                          context: context,
                                          bytes: Uint8List.fromList(bytes),
                                          fileName: fileName,
                                        );
                                        return;
                                      }

                                      final tempDir =
                                          await getTemporaryDirectory();
                                      final tempFile = File(
                                        '${tempDir.path}/$fileName',
                                      );
                                      await tempFile.writeAsBytes(bytes);
                                      await Share.shareXFiles([
                                        XFile(
                                          tempFile.path,
                                          mimeType:
                                              'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
                                        ),
                                      ], subject: fileName);
                                    },
                                  ),
                                ],
                              ),
                            );
                          },
                        );
                      },
                    );
                  },
                  child: Text('उपस्थिती पहा', style: TextStyle(fontSize: 14)),
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
  final FirebaseFirestore userFirestore;
  final FirebaseFirestore? secondaryFirestore;

  const _AddUserBottomSheet({
    required this.userFirestore,
    this.secondaryFirestore,
  });

  @override
  State<_AddUserBottomSheet> createState() => _AddUserBottomSheetState();
}

class _AddUserBottomSheetState extends State<_AddUserBottomSheet> {
  static const List<String> _baithakNoTypes = ['पटावर', 'पटाबाहेर'];

  final _nameCtrl = TextEditingController();
  final _nameMrCtrl = TextEditingController();
  final _mobileCtrl = TextEditingController();
  final _baithakNoCtrl = TextEditingController();
  final _emailCtrl = TextEditingController();
  final _dobCtrl = TextEditingController();

  // बैठक क्रमांक is split into a Patavar/Patabaher type plus the number
  // itself, then combined at submit time into e.g. "Patavar 104".
  // Defaults to पटावर (the common case) so registering a new Shree Sadasya
  // doesn't need an extra tap for this field.
  String? _selectedBaithakNoType = _baithakNoTypes.first;
  // The merged बैठक ठिकाण dropdown selects one BaithakSessions doc (keyed by
  // its Session_mr, which is already unique per hall+day), and that single
  // pick fills all four of baithakPlace/baithak_mr/baithak_day/baithak_day_mr.
  String? _selectedSessionMr;
  String? _selectedHallEn;
  String? _selectedHallMr;
  String? _selectedDayEn;
  String? _selectedDayMr;
  String? _selectedZone;
  String? _selectedZoneMr;
  List<Map<String, String>> _baithakSessionOptions = [];
  List<String> _vehicleTypeOptions = [];
  final List<VehicleEntry> _vehicles = [];
  Map<String, String> _errors = {};
  bool _isSubmitting = false;

  // Tracks whether the user has manually edited an auto-filled Marathi
  // field, so we stop overwriting it as they keep typing the English side.
  bool _nameMrTouched = false;

  @override
  void initState() {
    super.initState();
    _fetchBaithakSessionOptions();
    _fetchVehicleTypes();
  }

  Future<void> _fetchBaithakSessionOptions() async {
    final options = await AttendanceSupport.fetchBaithakSessionOptions(
      widget.secondaryFirestore,
    );
    if (!mounted) return;
    setState(() => _baithakSessionOptions = options);
  }

  Future<void> _fetchVehicleTypes() async {
    final types = await AttendanceSupport.fetchVehicleTypes(
      widget.userFirestore,
    );
    if (!mounted) return;
    setState(() => _vehicleTypeOptions = types);
  }

  void _addVehicleRow() => setState(() => _vehicles.add(VehicleEntry()));

  void _removeVehicleRow(int index) {
    setState(() {
      _vehicles[index].dispose();
      _vehicles.removeAt(index);
    });
  }

  // Auto-fills a Marathi field from its English counterpart, unless the user
  // has already edited the Marathi field themselves.
  void _autoFillPhonetic(
    TextEditingController mrCtrl,
    bool touched,
    String english,
  ) {
    if (touched) return;
    setState(() => mrCtrl.text = TransliterationService.toDevanagari(english));
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _nameMrCtrl.dispose();
    _mobileCtrl.dispose();
    _baithakNoCtrl.dispose();
    _emailCtrl.dispose();
    _dobCtrl.dispose();
    for (final vehicle in _vehicles) {
      vehicle.dispose();
    }
    super.dispose();
  }

  bool _validateName(String v) => RegExp(r'^[A-Za-zऀ-ॿ ]+$').hasMatch(v.trim());
  bool _validateMobile(String v) =>
      RegExp(r'^[0-9]{10}$').hasMatch(v.replaceAll(RegExp(r'\D'), ''));
  bool _validateBaithakNo(String type, String number) =>
      type.trim().isNotEmpty && RegExp(r'^[0-9]+$').hasMatch(number.trim());
  bool _validateBaithakPlace(String v) => v.trim().isNotEmpty;
  bool _validateEmail(String v) =>
      RegExp(r'^[\w-\.]+@([\w-]+\.)+[\w-]{2,4}$').hasMatch(v.trim());

  Future<void> _submit() async {
    final name = _nameCtrl.text.trim();
    final nameMr = _nameMrCtrl.text.trim();
    final mobile = _mobileCtrl.text.replaceAll(RegExp(r'\D'), '');
    final baithakNoType = _selectedBaithakNoType ?? '';
    final baithakNoValue = _baithakNoCtrl.text.trim();
    final baithakNo = baithakNoType.isNotEmpty && baithakNoValue.isNotEmpty
        ? '$baithakNoType $baithakNoValue'
        : '';
    final baithakPlace = _selectedHallEn ?? '';
    final baithakMr = _selectedHallMr ?? '';
    final baithakDay = _selectedDayEn ?? '';
    final baithakDayMr = _selectedDayMr ?? '';
    final zone = _selectedZone ?? '';
    final zoneMr = _selectedZoneMr ?? '';
    final dob = _dobCtrl.text.trim();
    final email = _emailCtrl.text.trim();

    final errors = <String, String>{};
    if (!_validateName(name)) errors['name'] = 'नावात फक्त अक्षरे असावीत';
    if (!_validateMobile(mobile))
      errors['mobile'] = 'मोबाइल नंबर १० अंकी असावा';
    if (!_validateBaithakNo(baithakNoType, baithakNoValue))
      errors['baithakNo'] = 'बैठक क्रमांक प्रकार व क्रमांक दोन्ही आवश्यक आहेत';
    if (!_validateBaithakPlace(baithakPlace))
      errors['baithakPlace'] = 'बैठक ठिकाण आवश्यक आहे';
    if (!_validateEmail(email)) errors['email'] = 'वैध ईमेल पत्ता प्रविष्ट करा';

    setState(() => _errors = errors);
    if (errors.isNotEmpty) return;

    setState(() => _isSubmitting = true);

    // Check duplicate mobile (mobile is stored encrypted, so match on that)
    final encryptedMobile = MobileEncryptionService.encrypt(mobile) ?? mobile;
    final dup = await widget.userFirestore
        .collection('Shree_Sadasya')
        .where('mobile', isEqualTo: encryptedMobile)
        .get();
    if (dup.docs.isNotEmpty) {
      setState(() {
        _errors['mobile'] = 'मोबाइल नंबर आधीच नोंदणीकृत आहे';
        _isSubmitting = false;
      });
      return;
    }

    // Check duplicate email — Shree Sadasya don't log in, so this is just
    // a data-integrity check, not an auth-account uniqueness constraint.
    final dupEmail = await widget.userFirestore
        .collection('Shree_Sadasya')
        .where('email', isEqualTo: email)
        .get();
    if (dupEmail.docs.isNotEmpty) {
      setState(() {
        _errors['email'] = 'हा ईमेल आधीच नोंदणीकृत आहे';
        _isSubmitting = false;
      });
      return;
    }

    // Write user to Firestore — Shree Sadasya are attendance-only records,
    // so no Firebase Auth account is created for them.
    try {
      final invertedMs = 9999999999999 - DateTime.now().millisecondsSinceEpoch;
      String? fcmToken = await FirebaseMessaging.instance.getToken();
      // 'uid' is a clean sequential display ID for reports/attendance.
      final sequentialUid = await UserIdService.nextId();
      final userDocId = '${invertedMs}_$sequentialUid';
      final vehicles = VehicleEntry.toStored(_vehicles);
      await widget.userFirestore
          .collection('Shree_Sadasya')
          .doc(userDocId)
          .set({
            'name': name,
            'name_mr': nameMr,
            'mobile': encryptedMobile,
            'hajeri_kramank': baithakNo,
            'baithakPlace': baithakPlace,
            'baithak_mr': baithakMr,
            'baithak_day': baithakDay,
            'baithak_day_mr': baithakDayMr,
            'zone': zone,
            'zone_mr': zoneMr,
            'vehicles': vehicles,
            'isActive': true,
            'dob': dob,
            'email': email,
            'fcmToken': fcmToken,
            'role': 'Shree Sadasya',
            'attendance_viewer': false,
            'createdAt': FieldValue.serverTimestamp(),
            'uid': sequentialUid,
          });

      // Grow the place dictionary so future auto-fill for this Baithak
      // Place is an exact lookup instead of a phonetic guess.
      await PlaceNameService.learn(baithakPlace, baithakMr);

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
    bool readOnly = false,
    void Function(String)? onChanged,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          controller: ctrl,
          readOnly: readOnly,
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
          style: const TextStyle(fontSize: 14),
          keyboardType: keyboardType,
          obscureText: obscure,
          onChanged: onChanged,
        ),
        const SizedBox(height: 8),
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
                  'नवीन श्री सदस्य जोडा',
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
            _buildField(
              'पूर्ण नाव (Full Name)',
              _nameCtrl,
              _errors['name'],
              onChanged: (v) {
                setState(
                  () => _validateName(v)
                      ? _errors.remove('name')
                      : _errors['name'] = 'नावात फक्त अक्षरे असावीत',
                );
                _autoFillPhonetic(_nameMrCtrl, _nameMrTouched, v);
              },
            ),
            _buildField(
              'पूर्ण नाव मराठी',
              _nameMrCtrl,
              null,
              onChanged: (_) => _nameMrTouched = true,
            ),
            _buildField(
              'मोबाइल नंबर',
              _mobileCtrl,
              _errors['mobile'],
              keyboardType: TextInputType.phone,
              onChanged: (v) {
                setState(
                  () => _validateMobile(v)
                      ? _errors.remove('mobile')
                      : _errors['mobile'] = 'मोबाइल नंबर १० अंकी असावा',
                );
              },
            ),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: DropdownButtonFormField<String>(
                    value: _selectedBaithakNoType,
                    isExpanded: true,
                    decoration: InputDecoration(
                      labelText: 'बैठक क्रमांक प्रकार',
                      border: const OutlineInputBorder(),
                      errorText: _errors['baithakNo'],
                      isDense: true,
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 10,
                      ),
                    ),
                    items: _baithakNoTypes
                        .map((t) => DropdownMenuItem(value: t, child: Text(t)))
                        .toList(),
                    onChanged: (val) {
                      setState(() {
                        _selectedBaithakNoType = val;
                        _errors.remove('baithakNo');
                      });
                    },
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _buildField(
                    'क्रमांक',
                    _baithakNoCtrl,
                    null,
                    keyboardType: TextInputType.number,
                    onChanged: (v) =>
                        setState(() => _errors.remove('baithakNo')),
                  ),
                ),
              ],
            ),
            DropdownButtonFormField<String>(
              value: _selectedSessionMr,
              isExpanded: true,
              menuMaxHeight: 300,
              // DropdownButtonFormField's own isDense (separate from the
              // isDense inside decoration below) defaults to true, which
              // clamps the closed/selected-value display to a fixed
              // single-line height, cutting off a wrapped 2nd line.
              isDense: false,
              // Null instead of the default fixed 48px row height, so long
              // hall names wrap onto multiple lines (both in the closed
              // field and the open menu) instead of being ellipsized —
              // same treatment as the baithak hall dropdown on the
              // attendance page.
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
              onChanged: (val) {
                setState(() {
                  _selectedSessionMr = val;
                  final session = _baithakSessionOptions.firstWhere(
                    (o) => o['sessionMr'] == val,
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
              },
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _dobCtrl,
              readOnly: true,
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
              onTap: () async {
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
            const SizedBox(height: 8),
            _buildField(
              'ईमेल',
              _emailCtrl,
              _errors['email'],
              keyboardType: TextInputType.emailAddress,
              onChanged: (v) {
                setState(
                  () => _validateEmail(v)
                      ? _errors.remove('email')
                      : _errors['email'] = 'वैध ईमेल पत्ता प्रविष्ट करा',
                );
              },
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text(
                  'वाहन माहिती (Vehicle)',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                ),
                TextButton.icon(
                  onPressed: _addVehicleRow,
                  icon: const Icon(Icons.add, size: 18),
                  label: const Text('Add Vehicle'),
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    minimumSize: Size(0, 0),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                ),
              ],
            ),
            ..._vehicles.asMap().entries.map((entry) {
              final index = entry.key;
              final vehicle = entry.value;
              return Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: DropdownButtonFormField<String>(
                        value: vehicle.type,
                        isExpanded: true,
                        decoration: const InputDecoration(
                          labelText: 'Vehicle Type',
                          border: OutlineInputBorder(),
                          isDense: true,
                          contentPadding: EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 10,
                          ),
                        ),
                        items: [
                          ..._vehicleTypeOptions.map(
                            (t) => DropdownMenuItem(
                              value: t,
                              child: Text(t, overflow: TextOverflow.ellipsis),
                            ),
                          ),
                          // Guards against a value not yet present in
                          // _vehicleTypeOptions (still loading) — see the
                          // matching fallback in _ShreeSadasyaEditDialog.
                          if ((vehicle.type ?? '').isNotEmpty &&
                              !_vehicleTypeOptions.contains(vehicle.type))
                            DropdownMenuItem(
                              value: vehicle.type,
                              child: Text(
                                vehicle.type!,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                        ],
                        onChanged: (val) => setState(() => vehicle.type = val),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: TextField(
                        controller: vehicle.noCtrl,
                        decoration: const InputDecoration(
                          labelText: 'Vehicle No.',
                          border: OutlineInputBorder(),
                          isDense: true,
                          contentPadding: EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 10,
                          ),
                        ),
                      ),
                    ),
                    IconButton(
                      icon: const Icon(
                        Icons.remove_circle_outline,
                        color: Colors.red,
                      ),
                      tooltip: 'Remove Vehicle',
                      onPressed: () => _removeVehicleRow(index),
                    ),
                  ],
                ),
              );
            }),
            if (_errors['general'] != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(
                  _errors['general']!,
                  style: const TextStyle(color: Colors.red),
                ),
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
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
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

// Lightweight profile editor for a single Shree_Sadasya doc, opened from the
// attendance page's user list (edit icon in place of the old leading
// checkbox). Mobile is stored encrypted, so it's decrypted for display (by
// the caller, via AttendanceSupport._fetchMappedUsers) and re-encrypted here
// before saving.
class _ShreeSadasyaEditDialog extends StatefulWidget {
  final FirebaseFirestore firestore;
  final FirebaseFirestore? secondaryFirestore;
  final String docId;
  final Map<String, dynamic> user;

  const _ShreeSadasyaEditDialog({
    required this.firestore,
    this.secondaryFirestore,
    required this.docId,
    required this.user,
  });

  @override
  State<_ShreeSadasyaEditDialog> createState() =>
      _ShreeSadasyaEditDialogState();
}

class _ShreeSadasyaEditDialogState extends State<_ShreeSadasyaEditDialog> {
  // हजेरी क्रमांक is split into a पटावर/पटाबाहेर type plus the number
  // itself, then combined at save time into e.g. "पटावर 104" — mirrors the
  // same split in _AddUserBottomSheet / _UserDetailsEditDialog.
  static const List<String> _hajeriTypes = ['पटावर', 'पटाबाहेर'];

  late final TextEditingController _nameCtrl;
  late final TextEditingController _nameMrCtrl;
  late final TextEditingController _mobileCtrl;
  late final TextEditingController _emailCtrl;
  late final TextEditingController _dobCtrl;
  late final TextEditingController _hajeriCtrl;
  String? _selectedHajeriType;
  bool _saving = false;
  String? _error;

  // The merged बैठक ठिकाण dropdown selects one BaithakSessions doc, which
  // fills all four of baithakPlace/baithak_mr/baithak_day/baithak_day_mr plus
  // zone/zone_mr — mirrors the same merge in _AddUserBottomSheet /
  // _UserDetailsEditDialog, so zone is no longer edited separately.
  String? _selectedSessionMr;
  String? _selectedHallEn;
  String? _selectedHallMr;
  String? _selectedDayEn;
  String? _selectedDayMr;
  String? _selectedZone;
  String? _selectedZoneMr;
  List<Map<String, String>> _baithakSessionOptions = [];
  List<String> _vehicleTypeOptions = [];
  late final List<VehicleEntry> _vehicles;

  @override
  void initState() {
    super.initState();
    final u = widget.user;
    _nameCtrl = TextEditingController(text: (u['name'] ?? '').toString());
    _nameMrCtrl = TextEditingController(text: (u['name_mr'] ?? '').toString());
    _mobileCtrl = TextEditingController(text: (u['mobile'] ?? '').toString());
    _emailCtrl = TextEditingController(text: (u['email'] ?? '').toString());
    _dobCtrl = TextEditingController(text: (u['dob'] ?? '').toString());
    _hajeriCtrl = TextEditingController();
    final storedHajeri = (u['hajeri_kramank'] ?? '').toString().trim();
    for (final t in _hajeriTypes) {
      if (storedHajeri.startsWith('$t ')) {
        _selectedHajeriType = t;
        _hajeriCtrl.text = storedHajeri.substring(t.length + 1).trim();
        break;
      }
    }
    if (_selectedHajeriType == null && storedHajeri.isNotEmpty) {
      // Legacy free-text value that doesn't match the पटावर/पटाबाहेर
      // pattern — keep it as the number portion instead of losing it.
      _hajeriCtrl.text = storedHajeri;
    }
    // Defaults to पटावर (the common case) rather than leaving the dropdown
    // blank — also avoids silently wiping a legacy hajeri_kramank value on
    // save, since an unset type otherwise saves as an empty string.
    _selectedHajeriType ??= _hajeriTypes.first;
    _vehicles = VehicleEntry.fromStored(u['vehicles']);

    _selectedHallEn = (u['baithak'] ?? '').toString();
    _selectedHallMr = (u['baithak_mr'] ?? '').toString();
    _selectedDayEn = (u['baithak_day'] ?? '').toString();
    _selectedDayMr = (u['baithak_day_mr'] ?? '').toString();
    _selectedZone = (u['zone'] ?? '').toString();
    _selectedZoneMr = (u['zone_mr'] ?? '').toString();
    if (_selectedHallMr!.isNotEmpty && _selectedDayMr!.isNotEmpty) {
      _selectedSessionMr = '$_selectedHallMr, $_selectedDayMr';
    }
    _fetchBaithakSessionOptions();
    _fetchVehicleTypes();
  }

  Future<void> _fetchBaithakSessionOptions() async {
    final options = await AttendanceSupport.fetchBaithakSessionOptions(
      widget.secondaryFirestore,
    );
    if (!mounted) return;
    setState(() => _baithakSessionOptions = options);
  }

  Future<void> _fetchVehicleTypes() async {
    final types = await AttendanceSupport.fetchVehicleTypes(widget.firestore);
    if (!mounted) return;
    setState(() => _vehicleTypeOptions = types);
  }

  void _addVehicleRow() => setState(() => _vehicles.add(VehicleEntry()));

  void _removeVehicleRow(int index) {
    setState(() {
      _vehicles[index].dispose();
      _vehicles.removeAt(index);
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
    });
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _nameMrCtrl.dispose();
    _mobileCtrl.dispose();
    _emailCtrl.dispose();
    _dobCtrl.dispose();
    _hajeriCtrl.dispose();
    for (final vehicle in _vehicles) {
      vehicle.dispose();
    }
    super.dispose();
  }

  Widget _field(TextEditingController ctrl, String label) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: TextField(
        controller: ctrl,
        decoration: InputDecoration(
          labelText: label,
          border: const OutlineInputBorder(),
          isDense: true,
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 12,
            vertical: 10,
          ),
        ),
      ),
    );
  }

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final mobileDigits = _mobileCtrl.text.trim();
      final encryptedMobile = mobileDigits.isEmpty
          ? ''
          : (MobileEncryptionService.encrypt(mobileDigits) ?? mobileDigits);
      await widget.firestore
          .collection('Shree_Sadasya')
          .doc(widget.docId)
          .update({
            'name': _nameCtrl.text.trim(),
            'name_mr': _nameMrCtrl.text.trim(),
            'mobile': encryptedMobile,
            'zone': _selectedZone ?? '',
            'zone_mr': _selectedZoneMr ?? '',
            'baithakPlace': _selectedHallEn ?? '',
            'baithak_mr': _selectedHallMr ?? '',
            'baithak_day': _selectedDayEn ?? '',
            'baithak_day_mr': _selectedDayMr ?? '',
            'email': _emailCtrl.text.trim(),
            'dob': _dobCtrl.text.trim(),
            'hajeri_kramank':
                (_selectedHajeriType ?? '').isNotEmpty &&
                    _hajeriCtrl.text.trim().isNotEmpty
                ? '${_selectedHajeriType!} ${_hajeriCtrl.text.trim()}'
                : '',
            'vehicles': VehicleEntry.toStored(_vehicles),
          });
      if (!mounted) return;
      Navigator.pop(context, true);
    } catch (e) {
      setState(() {
        _error = 'जतन करण्यात अयशस्वी: $e';
        _saving = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('सदस्य माहिती संपादित करा'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _field(_nameCtrl, 'नाव (इंग्रजी)'),
            _field(_nameMrCtrl, 'नाव (मराठी)'),
            _field(_mobileCtrl, 'मोबाइल'),
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: DropdownButtonFormField<String>(
                value: _selectedSessionMr,
                isExpanded: true,
                menuMaxHeight: 300,
                // DropdownButtonFormField's own isDense (separate from the
                // isDense inside decoration below) defaults to true, which
                // clamps the closed/selected-value display to a fixed
                // single-line height, cutting off a wrapped 2nd line.
                isDense: false,
                // Null instead of the default fixed 48px row height, so long
                // hall names wrap onto multiple lines (both in the closed
                // field and the open menu) instead of being ellipsized —
                // same treatment as the baithak hall dropdown on the
                // attendance page.
                itemHeight: null,
                decoration: const InputDecoration(
                  labelText: 'बैठक ठिकाण',
                  border: OutlineInputBorder(),
                  isDense: true,
                  contentPadding: EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 10,
                  ),
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
                  // session selectable instead of silently discarding it.
                  if (_selectedSessionMr != null &&
                      !_baithakSessionOptions.any(
                        (o) => o['sessionMr'] == _selectedSessionMr,
                      ))
                    DropdownMenuItem(
                      value: _selectedSessionMr,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 6),
                        child: Text(_selectedSessionMr!, softWrap: true),
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
                  if (_selectedSessionMr != null &&
                      !_baithakSessionOptions.any(
                        (o) => o['sessionMr'] == _selectedSessionMr,
                      ))
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 6),
                        child: Text(_selectedSessionMr!, softWrap: true),
                      ),
                    ),
                ],
                onChanged: _saving ? null : _onBaithakSessionChanged,
              ),
            ),
            _field(_emailCtrl, 'ईमेल'),
            _field(_dobCtrl, 'जन्मतारीख (YYYY-MM-DD)'),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.only(bottom: 10),
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
                ),
                const SizedBox(width: 8),
                Expanded(child: _field(_hajeriCtrl, 'क्रमांक')),
              ],
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text(
                  'वाहन माहिती (Vehicle)',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                ),
                TextButton.icon(
                  onPressed: _saving ? null : _addVehicleRow,
                  icon: const Icon(Icons.add, size: 18),
                  label: const Text('Add Vehicle'),
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    minimumSize: Size(0, 0),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                ),
              ],
            ),
            ..._vehicles.asMap().entries.map((entry) {
              final index = entry.key;
              final vehicle = entry.value;
              return Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: DropdownButtonFormField<String>(
                        value: vehicle.type,
                        isExpanded: true,
                        decoration: const InputDecoration(
                          labelText: 'Vehicle Type',
                          border: OutlineInputBorder(),
                          isDense: true,
                          contentPadding: EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 10,
                          ),
                        ),
                        items: [
                          ..._vehicleTypeOptions.map(
                            (t) => DropdownMenuItem(
                              value: t,
                              child: Text(t, overflow: TextOverflow.ellipsis),
                            ),
                          ),
                          // A saved vehicle's type is set in initState before
                          // _vehicleTypeOptions finishes loading (it's an
                          // async fetch) — without this fallback item,
                          // DropdownButtonFormField asserts on a value that
                          // doesn't (yet) match any item, and the whole
                          // section fails to render on the very first frame.
                          if ((vehicle.type ?? '').isNotEmpty &&
                              !_vehicleTypeOptions.contains(vehicle.type))
                            DropdownMenuItem(
                              value: vehicle.type,
                              child: Text(
                                vehicle.type!,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                        ],
                        onChanged: _saving
                            ? null
                            : (val) => setState(() => vehicle.type = val),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: TextField(
                        controller: vehicle.noCtrl,
                        enabled: !_saving,
                        decoration: const InputDecoration(
                          labelText: 'Vehicle No.',
                          border: OutlineInputBorder(),
                          isDense: true,
                          contentPadding: EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 10,
                          ),
                        ),
                      ),
                    ),
                    IconButton(
                      icon: const Icon(
                        Icons.remove_circle_outline,
                        color: Colors.red,
                      ),
                      tooltip: 'Remove Vehicle',
                      onPressed: _saving
                          ? null
                          : () => _removeVehicleRow(index),
                    ),
                  ],
                ),
              );
            }),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(_error!, style: const TextStyle(color: Colors.red)),
              ),
          ],
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
