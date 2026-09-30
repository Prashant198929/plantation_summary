/**
 * Scans hajeri-465b7's Attendance/{August_2026,July_2026}/records for docs
 * whose docId is missing the trailing zoneKey (the old invertedDate_uid
 * scheme, from before the app started writing invertedDate_uid_zoneKey —
 * see lib/attendance_page.dart's docId construction and
 * functions/migration_lib.js's zoneKey()). For each one found, re-creates
 * the doc under the correct invertedDate_uid_zoneKey docId (derived from
 * the record's own date/userId/zone fields) and deletes the old-scheme doc.
 *
 * A doc is only touched if the expected new-scheme docId doesn't already
 * exist (if it does, the old-scheme doc is a leftover duplicate reported
 * but left alone — deleting data on a collision isn't this script's call).
 *
 * Usage (from functions/ directory):
 *   node fix_attendance_docids_missing_zone.js            # dry run (default)
 *   node fix_attendance_docids_missing_zone.js --commit   # writes to Firestore
 */
const { HAJERI_SERVICE_ACCOUNT } = require('./migration_lib');

const COMMIT = process.argv.includes('--commit');
const MONTH_KEYS = ['July_2026', 'August_2026'];

function invertedDateFrom(date) {
  const yyyy = date.getFullYear().toString().padStart(4, '0');
  const mm = (date.getMonth() + 1).toString().padStart(2, '0');
  const dd = date.getDate().toString().padStart(2, '0');
  return 99999999 - parseInt(`${yyyy}${mm}${dd}`, 10);
}

function zoneKey(zoneNameEn) {
  const digits = (zoneNameEn || '').match(/(\d+)/);
  return digits ? digits[1] : (zoneNameEn || '').trim().toLowerCase();
}

async function main() {
  const admin = require('firebase-admin');
  const app = admin.initializeApp(
    { credential: admin.credential.cert(require(HAJERI_SERVICE_ACCOUNT)), projectId: 'hajeri-465b7' },
    'fix-attendance-docids',
  );
  const db = app.firestore();

  const toFix = [];
  const skippedCollisions = [];
  const skippedNoZone = [];

  for (const monthKey of MONTH_KEYS) {
    const snap = await db.collection('Attendance').doc(monthKey).collection('records').get();
    console.log(`\n=== Attendance/${monthKey}/records (${snap.size} docs) ===`);

    for (const doc of snap.docs) {
      const data = doc.data();
      const uid = (data.userId ?? '').toString();
      const zone = (data.zone ?? data.zone_mr ?? '').toString();
      const dateVal = data.date && data.date.toDate ? data.date.toDate() : null;
      if (!uid || !dateVal) {
        console.log(`  [${doc.id}] SKIP — missing userId or date field`);
        continue;
      }
      if (!zone) {
        skippedNoZone.push(doc.id);
        console.log(`  [${doc.id}] SKIP — no zone/zone_mr field to derive a zoneKey from`);
        continue;
      }
      const zKey = zoneKey(zone);
      const expectedDocId = `${invertedDateFrom(dateVal)}_${uid}_${zKey}`;
      if (doc.id === expectedDocId) continue; // already correct scheme

      // Only rename docs whose id is missing the zoneKey suffix — i.e. the
      // old invertedDate_uid scheme (expectedDocId with the "_zKey" suffix
      // stripped). Anything else mismatching is unexpected and left alone.
      const oldSchemeId = expectedDocId.slice(0, expectedDocId.length - zKey.length - 1);
      if (doc.id !== oldSchemeId) {
        console.log(`  [${doc.id}] SKIP — docId doesn't match the expected old scheme (expected "${oldSchemeId}"), leaving alone`);
        continue;
      }

      toFix.push({ monthKey, oldId: doc.id, newId: expectedDocId, data });
    }
  }

  console.log(`\n=== Docs to migrate to invertedDate_uid_zoneKey scheme (${toFix.length}) ===`);
  for (const item of toFix) {
    console.log(`  Attendance/${item.monthKey}/records/${item.oldId} -> ${item.newId}  name=${item.data.name ?? ''} zone=${item.data.zone ?? ''}`);
  }

  if (!COMMIT) {
    console.log(`\nDry run only — no writes made. Re-run with --commit to apply ${toFix.length} rename(s).`);
    return;
  }

  let migrated = 0;
  for (const item of toFix) {
    const collRef = db.collection('Attendance').doc(item.monthKey).collection('records');
    const newRef = collRef.doc(item.newId);
    const existing = await newRef.get();
    if (existing.exists) {
      skippedCollisions.push(`${item.monthKey}/${item.oldId} -> ${item.newId} (target already exists)`);
      console.log(`  SKIP collision: ${item.monthKey}/${item.oldId} -> ${item.newId} already exists — leaving old doc in place`);
      continue;
    }
    await newRef.set(item.data);
    await collRef.doc(item.oldId).delete();
    migrated++;
    console.log(`  migrated: ${item.monthKey}/${item.oldId} -> ${item.newId}`);
  }

  console.log(`\nDone. ${migrated} doc(s) migrated, ${skippedCollisions.length} collision(s) skipped, ${skippedNoZone.length} doc(s) skipped for missing zone.`);
  if (skippedCollisions.length) {
    console.log('\nCollisions needing manual review:');
    skippedCollisions.forEach(c => console.log(`  ${c}`));
  }
}

main().catch(e => {
  console.error('Fatal:', e.message);
  process.exit(1);
});
