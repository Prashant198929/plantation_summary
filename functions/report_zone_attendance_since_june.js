/**
 * Report: which zones have marked attendance in the app between 2026-06-01
 * and today, using hajeri-465b7's Attendance/{month}/records.
 *
 * Read-only — no writes. Queries one month doc's 'records' subcollection at
 * a time (June_2026 .. current month), matching the docId/date scheme used
 * by attendance_page.dart (AttendanceSupport.monthYearKey / zone / zone_mr
 * fields on each record).
 *
 * Usage (from functions/ directory):
 *   node report_zone_attendance_since_june.js
 *   node report_zone_attendance_since_june.js --start=2026-06-01 --end=2026-09-07
 */

const { HAJERI_SERVICE_ACCOUNT, zoneKey } = require('./migration_lib');

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

async function main() {
  const admin = require('firebase-admin');
  const hajeriApp = admin.initializeApp(
    { credential: admin.credential.cert(require(HAJERI_SERVICE_ACCOUNT)), projectId: 'hajeri-465b7' },
    'hajeri-zone-report',
  );
  const db = hajeriApp.firestore();

  // BaithakHalls lookup: zoneKey -> Set of hall/session names, so the
  // registered-hall-for-this-zone can be compared against what was actually
  // recorded on attendance entries (baithak_mr).
  const hallsSnap = await db.collection('BaithakHalls').get();
  const hallsByZoneKey = new Map();
  hallsSnap.docs.forEach(doc => {
    const h = doc.data();
    const zoneRaw = (h.Zone || h.Zone_mr || '').toString().trim();
    if (!zoneRaw) return;
    const key = zoneKey(zoneRaw);
    const name = (h.Session_mr || h.Hall_mr || doc.id).toString().trim();
    if (!hallsByZoneKey.has(key)) hallsByZoneKey.set(key, new Set());
    hallsByZoneKey.get(key).add(name);
  });
  console.log(`Loaded ${hallsSnap.size} BaithakHalls doc(s), covering ${hallsByZoneKey.size} distinct zone(s).\n`);

  const monthKeys = monthKeysBetween(START, END);
  console.log(`Scanning months: ${monthKeys.join(', ')}`);
  console.log(`Date range: ${START.toISOString().slice(0, 10)} .. ${END.toISOString().slice(0, 10)}\n`);

  // zoneLabel -> { count, uids: Set, dates: Set }
  const zones = new Map();
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

      const zoneEn = (data.zone || '').toString().trim();
      const zoneMr = (data.zone_mr || '').toString().trim();
      const label = zoneMr || zoneEn || '(no zone)';
      const uid = (data.uid || data.userId || '').toString();
      const dateKey = d.toISOString().slice(0, 10);
      const baithak = (data.baithak_mr || data.baithak || '').toString().trim();

      if (!zones.has(label)) zones.set(label, { zoneEn, zoneMr, count: 0, uids: new Set(), dates: new Set(), baithaks: new Set() });
      const z = zones.get(label);
      z.count++;
      if (uid) z.uids.add(uid);
      z.dates.add(dateKey);
      if (baithak) z.baithaks.add(baithak);
    });
    console.log(`  [${monthKey}] ${snap.size} record(s) total, ${inRange} in date range`);
  }

  console.log(`\nTotal records in range: ${totalRecords}`);
  console.log(`Distinct zones that marked attendance: ${zones.size}\n`);

  const rows = [...zones.entries()].map(([label, z]) => ({
    zone: label,
    zoneEn: z.zoneEn,
    recordedBaithakMr: [...z.baithaks].join(' | ') || '(blank)',
    records: z.count,
    distinctMembers: z.uids.size,
    distinctDays: z.dates.size,
    firstDate: [...z.dates].sort()[0],
    lastDate: [...z.dates].sort().slice(-1)[0],
  }));

  rows.sort((a, b) => {
    const na = parseInt((a.zoneEn.match(/\d+/) || [])[0] || '9999', 10);
    const nb = parseInt((b.zoneEn.match(/\d+/) || [])[0] || '9999', 10);
    return na - nb;
  });

  console.log('Raw (as-stored zone/zone_mr labels, un-normalized):');
  console.table(rows);

  // Normalized rollup: merge labels that mean the same zone (e.g. "Zone 7" /
  // "झोन 7" / "Zone7" -> key "7"), matching AttendanceSupport.zoneKey() /
  // migration_lib.zoneKey() digit-extraction used when records are written.
  const normalized = new Map();
  zones.forEach((z, label) => {
    const key = zoneKey(z.zoneEn || label);
    if (!normalized.has(key)) {
      normalized.set(key, { key, labels: new Set(), count: 0, uids: new Set(), dates: new Set(), baithaks: new Set() });
    }
    const n = normalized.get(key);
    n.labels.add(label);
    n.count += z.count;
    z.uids.forEach(u => n.uids.add(u));
    z.dates.forEach(d => n.dates.add(d));
    z.baithaks.forEach(b => n.baithaks.add(b));
  });

  const normRows = [...normalized.values()].map(n => {
    const registeredHalls = hallsByZoneKey.get(n.key);
    return {
      zone: [...n.labels].join(' / '),
      recordedBaithakMr: [...n.baithaks].join(' | ') || '(blank)',
      registeredBaithakHalls: registeredHalls ? [...registeredHalls].join(' | ') : '(no BaithakHalls entry)',
      records: n.count,
      distinctMembers: n.uids.size,
      distinctDays: n.dates.size,
      firstDate: [...n.dates].sort()[0],
      lastDate: [...n.dates].sort().slice(-1)[0],
    };
  });
  normRows.sort((a, b) => {
    const na = parseInt((a.zone.match(/\d+/) || [])[0] || '9999', 10);
    const nb = parseInt((b.zone.match(/\d+/) || [])[0] || '9999', 10);
    return na - nb;
  });

  console.log(`\nNormalized (merged by zone number) — ${normRows.length} distinct zones:`);
  console.table(normRows);

  const fs = require('fs');
  const path = require('path');
  const outPath = path.join(__dirname, 'zone_attendance_report.json');
  fs.writeFileSync(outPath, JSON.stringify({ start: START.toISOString(), end: END.toISOString(), totalRecords, rows, normalized: normRows }, null, 2));
  console.log(`\nWrote details to ${outPath}`);
}

main().catch(e => {
  console.error('Fatal:', e.message);
  process.exit(1);
});
