/**
 * Migrates historical attendance from sevakdb_attendance_full.xlsx (the
 * "Attendance" sheet — already joined with Name/Zone/Baithak/Hall/Location,
 * built in an earlier session) into two Firebase projects:
 *   - vrukshamojani-4ffd6 : users/{uid}                      (main app project)
 *   - hajeri-465b7        : Attendance/{monthKey}/records/{docId}
 *
 * uid = MemberMasterId (no prefix) — matches the convention already
 * documented in lib/user_id_service.dart: "The counter is seeded to
 * MAX(MemberMasterId) from the legacy sevakdb import, so IDs assigned here
 * never collide with historical member IDs once that data is imported."
 *
 * docId = `${invertedDate}_${uid}_${zoneDigits}` — zone is included because
 * 1,017 member-days in the source data have two sessions in different zones
 * on the same day; the app's normal `date_uid` scheme would collide on those.
 * The Attendance sheet has no numeric ZoneId, so digits are extracted from
 * ZoneName_en (e.g. "Zone 28" -> "28") as the disambiguating key instead.
 *
 * Mobile numbers in the source sheet are decrypted plain digits (the export
 * query calls dbo.DecryptMobile for readability), so they're re-encrypted
 * here with the same Triple-DES/ECB/MD5-key scheme as MobileEncryptionService
 * before being written to Firestore (verified round-trip against real records).
 *
 * Location_En/Location_Mr are taken directly from the sheet (populated for
 * ~4,626 of 110,798 rows) and left as '' when null — there is no derivation,
 * per explicit instruction, since guessing would misrepresent real data gaps.
 *
 * This is the manual/ad-hoc single-batch CLI, useful for small test batches.
 * For migrating the full dataset, use batch_migrate_full.js instead, which
 * shares this file's core logic (see migration_lib.js) but reads the source
 * Excel once, uses Firestore batched writes, and verifies+checkpoints after
 * every 100-row chunk so a full run can be resumed if interrupted.
 *
 * Usage (from functions/ directory):
 *   node migrate_sevakdb_attendance.js --limit=10                  # dry run
 *   node migrate_sevakdb_attendance.js --limit=10 --commit         # writes
 *   node migrate_sevakdb_attendance.js --limit=1000 --offset=10 --commit
 *
 * Requires:
 *   - Python + pandas/openpyxl on PATH (used to read the .xlsx)
 *   - MAIN_SERVICE_ACCOUNT below pointing at the vrukshamojani-4ffd6 key
 *   - HAJERI_SERVICE_ACCOUNT below pointing at the hajeri-465b7 key
 */

const { execFileSync } = require('child_process');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { MAIN_SERVICE_ACCOUNT, HAJERI_SERVICE_ACCOUNT, buildRecords } = require('./migration_lib');

const args = process.argv.slice(2);
const LIMIT = parseInt((args.find(a => a.startsWith('--limit='))?.split('=')[1]) || '10', 10);
const OFFSET = parseInt((args.find(a => a.startsWith('--offset='))?.split('=')[1]) || '0', 10);
const COMMIT = args.includes('--commit');

function fetchRows(limit, offset) {
  const outPath = path.join(os.tmpdir(), `sevakdb_excel_${Date.now()}.json`);
  execFileSync('python', [
    path.join(__dirname, 'extract_sevakdb_excel.py'),
    String(limit),
    String(offset),
    outPath,
  ], { stdio: 'inherit' });
  const rows = JSON.parse(fs.readFileSync(outPath, 'utf8'));
  fs.unlinkSync(outPath);
  return rows;
}

async function main() {
  console.log(`Fetching rows ${OFFSET + 1}..${OFFSET + LIMIT} from sevakdb_attendance_full.xlsx (Attendance sheet)...`);
  const rows = fetchRows(LIMIT, OFFSET);
  console.log(`Fetched ${rows.length} rows.`);

  const { users, attendanceRecords } = buildRecords(rows);

  console.log(`\n=== ${users.length} user doc(s) to upsert into vrukshamojani-4ffd6 'users' ===`);
  users.forEach(u => console.log(JSON.stringify(u, null, 2)));

  console.log(`\n=== ${attendanceRecords.length} attendance record(s) to write into hajeri-465b7 ===`);
  attendanceRecords.forEach(r =>
    console.log(`[${r.monthKey}/records/${r.docId}]\n${JSON.stringify(r.data, null, 2)}`),
  );

  const withLocation = attendanceRecords.filter(r => r.data.Location_En);
  console.log(`\n${withLocation.length} of ${attendanceRecords.length} record(s) in this batch have real Location_En data; the rest are ''.`);

  if (!COMMIT) {
    console.log('\nDry run only — no writes made. Re-run with --commit to write to Firestore.');
    return;
  }

  const admin = require('firebase-admin');
  const mainApp = admin.initializeApp(
    { credential: admin.credential.cert(require(MAIN_SERVICE_ACCOUNT)), projectId: 'vrukshamojani-4ffd6' },
    'main',
  );
  const hajeriApp = admin.initializeApp(
    { credential: admin.credential.cert(require(HAJERI_SERVICE_ACCOUNT)), projectId: 'hajeri-465b7' },
    'hajeri',
  );
  const mainDb = mainApp.firestore();
  const hajeriDb = hajeriApp.firestore();

  console.log('\nWriting users to vrukshamojani-4ffd6...');
  // Doc ID matches register_page.dart's live-registration scheme: invertedMs_uid
  // (invertedMs = 9999999999999 - millis), so migrated users sort/behave like real signups.
  // Since uid (MemberMasterId) is the real join key used everywhere else (attendance.userId,
  // etc.), we look up any existing doc by uid first so re-running this script is idempotent
  // instead of creating a fresh doc (and a fresh invertedMs) every time.
  const existingByUid = new Map();
  const uidChunks = [];
  for (let i = 0; i < users.length; i += 30) uidChunks.push(users.slice(i, i + 30).map(u => u.uid));
  for (const chunk of uidChunks) {
    const snap = await mainDb.collection('users').where('uid', 'in', chunk).get();
    snap.forEach(doc => existingByUid.set(doc.get('uid'), doc.id));
  }

  for (const u of users) {
    const docId = existingByUid.get(u.uid) || `${9999999999999 - Date.now()}_${u.uid}`;
    await mainDb.collection('users').doc(docId).set(u, { merge: true });
    console.log(`  upserted users/${docId} (uid=${u.uid})`);
  }

  console.log('\nWriting attendance records to hajeri-465b7...');
  for (const r of attendanceRecords) {
    const ref = hajeriDb.collection('Attendance').doc(r.monthKey).collection('records').doc(r.docId);
    const existing = await ref.get();
    if (existing.exists) {
      console.log(`  SKIP (already exists) ${r.monthKey}/records/${r.docId}`);
      continue;
    }
    await ref.set(r.data);
    console.log(`  wrote ${r.monthKey}/records/${r.docId}`);
  }

  console.log('\nDone.');
}

main().catch(e => {
  console.error('Fatal:', e.message);
  process.exit(1);
});
