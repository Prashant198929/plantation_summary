/**
 * Read-only check: for every user who would see a role-scoped (non-admin)
 * baithak hall dropdown on the attendance page, does their 'users'.baithak_mr
 * actually match a real BaithakSessions.Hall_mr entry?
 *
 * Mirrors the app's own matching logic exactly:
 *  - attendance_page.dart _visibleBaithakSessions: only applies this filter
 *    when role is NOT super_admin/superadmin/admin (those see every hall).
 *  - attendance_support.dart filterSessionsByHall / _normalizePlaceName:
 *    strips commas, collapses whitespace, trims, before comparing.
 *
 * A user whose baithak_mr doesn't match any hall would see an EMPTY hall
 * dropdown and be unable to mark/find their own attendance list at all.
 *
 * Usage (from functions/ directory):
 *   node check_hall_matching.js
 */
const { MAIN_SERVICE_ACCOUNT, HAJERI_SERVICE_ACCOUNT } = require('./migration_lib');

function normalizePlaceName(value) {
  return (value || '').toString().replace(/,/g, ' ').replace(/\s+/g, ' ').trim();
}

function isSuperAdmin(role) {
  const r = (role || '').toString().toLowerCase();
  return r === 'super_admin' || r === 'superadmin' || r === 'admin';
}

async function main() {
  const admin = require('firebase-admin');

  const mainApp = admin.initializeApp(
    { credential: admin.credential.cert(require(MAIN_SERVICE_ACCOUNT)), projectId: 'vrukshamojani-4ffd6' },
    'check-hall-matching-main',
  );
  const hajeriApp = admin.initializeApp(
    { credential: admin.credential.cert(require(HAJERI_SERVICE_ACCOUNT)), projectId: 'hajeri-465b7' },
    'check-hall-matching-hajeri',
  );

  const mainDb = mainApp.firestore();
  const hajeriDb = hajeriApp.firestore();

  const [usersSnap, sessionsSnap] = await Promise.all([
    mainDb.collection('users').get(),
    hajeriDb.collection('BaithakSessions').get(),
  ]);

  console.log(`Fetched ${usersSnap.size} doc(s) from 'users'.`);
  console.log(`Fetched ${sessionsSnap.size} doc(s) from 'BaithakSessions'.`);

  const hallSet = new Set();
  sessionsSnap.docs.forEach(d => {
    const hallMr = normalizePlaceName(d.data().Hall_mr);
    if (hallMr) hallSet.add(hallMr);
  });
  console.log(`Distinct normalized Hall_mr values: ${hallSet.size}`);

  const relevantUsers = usersSnap.docs.filter(d => {
    const data = d.data();
    if (isSuperAdmin(data.role)) return false; // admins see every hall, matching doesn't apply
    return data.attendance_viewer === true;
  });
  console.log(`\nNon-admin users with attendance_viewer=true: ${relevantUsers.length}`);

  const blankBaithak = [];
  const noMatch = [];
  let matched = 0;

  relevantUsers.forEach(d => {
    const data = d.data();
    const raw = (data.baithak_mr || '').toString().trim();
    if (!raw) {
      blankBaithak.push({ id: d.id, name: data.name || data.name_mr || '' });
      return;
    }
    const normalized = normalizePlaceName(raw);
    if (hallSet.has(normalized)) {
      matched++;
    } else {
      noMatch.push({ id: d.id, name: data.name || data.name_mr || '', baithak_mr: raw });
    }
  });

  console.log(`\nMatched OK: ${matched}`);
  console.log(`Blank baithak_mr (empty hall dropdown guaranteed): ${blankBaithak.length}`);
  blankBaithak.slice(0, 30).forEach(u => console.log(`  ${u.id}  name="${u.name}"`));
  if (blankBaithak.length > 30) console.log(`  ... and ${blankBaithak.length - 30} more`);

  console.log(`\nNon-blank baithak_mr with NO matching hall (empty hall dropdown): ${noMatch.length}`);
  noMatch.slice(0, 50).forEach(u => console.log(`  ${u.id}  name="${u.name}"  baithak_mr="${u.baithak_mr}"`));
  if (noMatch.length > 50) console.log(`  ... and ${noMatch.length - 50} more`);
}

main().catch(e => {
  console.error('Fatal:', e.message);
  process.exit(1);
});
