/**
 * Report: which BaithakSessions (hall+day meetings) had ZERO attendance
 * marked against them in the app between 2026-06-01 and today.
 *
 * Read-only — no writes. Two passes over hajeri-465b7:
 *   1. Attendance/{month}/records (June_2026..current month) -> distinct
 *      'baithak_mr'/'baithak' values actually recorded on attendance
 *      entries in the date range.
 *   2. BaithakSessions -> every registered hall+day session, matched
 *      against (1) by Hall_mr/Hall_En, normalized the same way
 *      attendance_support.dart's _normalizePlaceName does (strip commas,
 *      collapse whitespace) so punctuation-only differences don't cause a
 *      false "unused" result.
 *
 * Usage (from functions/ directory):
 *   node find_unused_baithak_sessions.js
 *   node find_unused_baithak_sessions.js --start=2026-06-01 --end=2026-09-07
 */

const { HAJERI_SERVICE_ACCOUNT } = require('./migration_lib');

const args = process.argv.slice(2);
function argVal(name, fallback) {
  const hit = args.find(a => a.startsWith(`--${name}=`));
  return hit ? hit.split('=')[1] : fallback;
}

const today = new Date();
const START = new Date(argVal('start', '2026-06-01') + 'T00:00:00');
const END = new Date(argVal('end', today.toISOString().slice(0, 10)) + 'T23:59:59');

const MONTH_NAMES = [
  'January', 'February', 'March', 'April', 'May', 'June',
  'July', 'August', 'September', 'October', 'November', 'December',
];
function monthYearKey(date) {
  return `${MONTH_NAMES[date.getMonth()]}_${date.getFullYear()}`;
}
function monthKeysBetween(start, end) {
  const keys = [];
  let cursor = new Date(start.getFullYear(), start.getMonth(), 1);
  const endMonth = new Date(end.getFullYear(), end.getMonth(), 1);
  while (cursor <= endMonth) {
    keys.push(monthYearKey(cursor));
    cursor = new Date(cursor.getFullYear(), cursor.getMonth() + 1, 1);
  }
  return keys;
}

// Mirrors AttendanceSupport._normalizePlaceName in lib/attendance_support.dart
function normalizePlace(v) {
  return (v || '')
    .toString()
    .replace(/,/g, ' ')
    .replace(/\s+/g, ' ')
    .trim()
    .toLowerCase();
}

async function main() {
  const admin = require('firebase-admin');
  const hajeriApp = admin.initializeApp(
    { credential: admin.credential.cert(require(HAJERI_SERVICE_ACCOUNT)), projectId: 'hajeri-465b7' },
    'hajeri-unused-sessions',
  );
  const db = hajeriApp.firestore();

  // --- Pass 1: distinct baithak names actually recorded, June 1 .. today ---
  const monthKeys = monthKeysBetween(START, END);
  console.log(`Scanning months: ${monthKeys.join(', ')}`);
  console.log(`Date range: ${START.toISOString().slice(0, 10)} .. ${END.toISOString().slice(0, 10)}\n`);

  const recordedNormalized = new Set();
  const recordedRaw = new Set();
  let totalRecords = 0;

  for (const monthKey of monthKeys) {
    let snap;
    try {
      snap = await db.collection('Attendance').doc(monthKey).collection('records').get();
    } catch (e) {
      console.log(`  [${monthKey}] error: ${e.message}`);
      continue;
    }
    let inRange = 0;
    snap.docs.forEach(doc => {
      const data = doc.data();
      const ts = data.date;
      const d = ts && typeof ts.toDate === 'function' ? ts.toDate() : (ts ? new Date(ts) : null);
      if (!d || d < START || d > END) return;
      inRange++;
      totalRecords++;
      [data.baithak_mr, data.baithak].forEach(v => {
        const raw = (v || '').toString().trim();
        if (!raw) return;
        recordedRaw.add(raw);
        recordedNormalized.add(normalizePlace(raw));
      });
    });
    console.log(`  [${monthKey}] ${snap.size} record(s) total, ${inRange} in date range`);
  }
  console.log(`\nTotal attendance records in range: ${totalRecords}`);
  console.log(`Distinct baithak names recorded on those entries: ${recordedRaw.size}\n`);

  // --- Pass 2: every registered BaithakSessions doc, matched against pass 1 ---
  const sessionsSnap = await db.collection('BaithakSessions').get();
  console.log(`Loaded ${sessionsSnap.size} BaithakSessions doc(s).\n`);

  const used = [];
  const unused = [];

  sessionsSnap.docs.forEach(doc => {
    const s = doc.data();
    const hallMr = (s.Hall_mr || '').toString().trim();
    const hallEn = (s.Hall_En || s.Hall_en || '').toString().trim();
    const dayMr = (s.Day_mr || '').toString().trim();
    const sessionLabel = (s.Session_mr || doc.id).toString().trim();
    const zone = (s.Zone_mr || s.Zone || '').toString().trim();

    const normHallMr = normalizePlace(hallMr);
    const normHallEn = normalizePlace(hallEn);

    // Exact normalized match, or substring either direction (covers cases
    // where the recorded value carries extra/less detail than the hall name).
    const isMatch = [...recordedNormalized].some(rec => {
      if (normHallMr && (rec === normHallMr || rec.includes(normHallMr) || normHallMr.includes(rec))) return true;
      if (normHallEn && (rec === normHallEn || rec.includes(normHallEn) || normHallEn.includes(rec))) return true;
      return false;
    });

    const row = { session: sessionLabel, hallMr, dayMr, zone, docId: doc.id };
    (isMatch ? used : unused).push(row);
  });

  console.log(`Sessions WITH at least one attendance mark in range: ${used.length}`);
  console.log(`Sessions with ZERO attendance marks in range: ${unused.length}\n`);

  console.log('=== BaithakSessions with NO attendance mark, 1 Jun 2026 - today ===\n');
  unused
    .sort((a, b) => {
      const na = parseInt((a.zone.match(/\d+/) || [])[0] || '9999', 10);
      const nb = parseInt((b.zone.match(/\d+/) || [])[0] || '9999', 10);
      return na - nb || a.session.localeCompare(b.session);
    })
    .forEach(u => {
      console.log(`  [${u.zone || 'no zone'}] ${u.session}`);
    });

  const fs = require('fs');
  const path = require('path');
  const outPath = path.join(__dirname, 'unused_baithak_sessions_report.json');
  fs.writeFileSync(outPath, JSON.stringify({
    start: START.toISOString(),
    end: END.toISOString(),
    totalRecords,
    distinctRecordedBaithakNames: [...recordedRaw].sort(),
    sessionsTotal: sessionsSnap.size,
    used,
    unused,
  }, null, 2));
  console.log(`\nWrote details to ${outPath}`);
}

main().catch(e => {
  console.error('Fatal:', e.message);
  process.exit(1);
});
