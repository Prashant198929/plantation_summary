/**
 * Migrates Attendance/{month}/records doc IDs to {invertedDate}_{uid} format.
 * Structure: Attendance/{monthKey}/records/{docId}
 * New format: {99999999 - YYYYMMDD}_{uid}  e.g. 99740101_abc123
 *
 * Run from functions/ directory:
 *   $env:GOOGLE_APPLICATION_CREDENTIALS = "C:\Users\psawarwadkar\Downloads\hajeri-465b7-firebase-adminsdk-fbsvc-df192818af.json"
 *   node migrate_attendance_docids.js
 */

const admin = require('firebase-admin');
admin.initializeApp({
  credential: admin.credential.applicationDefault(),
  projectId: 'hajeri-465b7',
});
const db = admin.firestore();

const MONTHS = [
  'January','February','March','April','May','June',
  'July','August','September','October','November','December'
];

// New format: inverted date (99999999 - YYYYMMDD) starts around 797xxxxx
// Old format: YYYYMMDD starts with 2025, 2026, etc.
function isNewFormat(docId) {
  const prefix = parseInt(docId.split('_')[0], 10);
  // Inverted dates for 2020-2035 are in range 79700000-79800000
  return prefix >= 79000000 && prefix <= 99000000;
}

function invertedDateFromTimestamp(ts) {
  const d = ts.toDate();
  const yyyy = d.getFullYear().toString().padStart(4, '0');
  const mm   = (d.getMonth() + 1).toString().padStart(2, '0');
  const dd   = d.getDate().toString().padStart(2, '0');
  const dateKey = parseInt(`${yyyy}${mm}${dd}`, 10);
  return 99999999 - dateKey;
}

async function main() {
  let totalFixed = 0, totalSkipped = 0, totalErrors = 0;

  // Build all month keys from 2023 to 2027
  const monthKeys = [];
  for (let year = 2023; year <= 2027; year++) {
    for (const month of MONTHS) {
      monthKeys.push(`${month}_${year}`);
    }
  }

  for (const monthKey of monthKeys) {
    const recordsRef = db.collection('Attendance').doc(monthKey).collection('records');
    const snap = await recordsRef.get();
    if (snap.empty) continue;

    console.log(`\n[${monthKey}] — ${snap.size} records`);
    const usedIds = new Set();

    // Pre-collect already correct IDs
    for (const doc of snap.docs) {
      if (isNewFormat(doc.id)) usedIds.add(doc.id);
    }

    for (const doc of snap.docs) {
      if (isNewFormat(doc.id)) {
        totalSkipped++;
        continue;
      }

      const data = doc.data();
      const uid = data.uid || data.userId || doc.id;

      // Compute inverted date from stored date field
      let invertedDate;
      if (data.date && data.date.toDate) {
        invertedDate = invertedDateFromTimestamp(data.date);
      } else {
        console.log(`  SKIP [${doc.id}] — no date field`);
        totalSkipped++;
        continue;
      }

      let newId = `${invertedDate}_${uid}`;

      // Handle collision
      let suffix = 0;
      while (usedIds.has(newId)) {
        suffix++;
        newId = `${invertedDate}_${suffix}_${uid}`;
      }
      usedIds.add(newId);

      try {
        const batch = db.batch();
        batch.set(recordsRef.doc(newId), data);
        batch.delete(recordsRef.doc(doc.id));
        await batch.commit();
        console.log(`  FIXED [${doc.id}] → [${newId}]`);
        totalFixed++;
      } catch (e) {
        console.error(`  ERROR [${doc.id}]: ${e.message}`);
        totalErrors++;
      }
    }
  }

  console.log('\n=== Done ===');
  console.log(`  Fixed  : ${totalFixed}`);
  console.log(`  Skipped: ${totalSkipped} (already correct format)`);
  console.log(`  Errors : ${totalErrors}`);
  process.exit(0);
}

main().catch(e => { console.error('Fatal:', e.message); process.exit(1); });
