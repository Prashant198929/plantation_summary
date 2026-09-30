/**
 * One-time load of the 7 weekdays into the hajeri-465b7 Firebase project as
 * a new 'Day' collection, for use as a lookup alongside 'BaithakHalls'.
 *
 * Source: sevakdb.dbo.BaithakMaster only has 6 distinct Day_en/Day_mr values
 * (no Saturday baithak currently scheduled), but Saturday is included here
 * too since this is a general day-of-week lookup, not a mirror of that table.
 *
 * Usage (from functions/ directory):
 *   node migrate_days.js            # dry run, prints what would be written
 *   node migrate_days.js --commit   # writes to Firestore
 */

const { HAJERI_SERVICE_ACCOUNT } = require('./migration_lib');

const COMMIT = process.argv.includes('--commit');

const DAYS = [
  { Day_en: 'Sunday', Day_mr: 'रविवार' },
  { Day_en: 'Monday', Day_mr: 'सोमवार' },
  { Day_en: 'Tuesday', Day_mr: 'मंगळवार' },
  { Day_en: 'Wednesday', Day_mr: 'बुधवार' },
  { Day_en: 'Thursday', Day_mr: 'गुरुवार' },
  { Day_en: 'Friday', Day_mr: 'शुक्रवार' },
  { Day_en: 'Saturday', Day_mr: 'शनिवार' },
];

async function main() {
  console.log(`${DAYS.length} day(s) to write into hajeri-465b7 'Day'.`);
  DAYS.forEach((d, i) => console.log(`  ${i + 1}. ${d.Day_en} | ${d.Day_mr}`));

  if (!COMMIT) {
    console.log('\nDry run only — no writes made. Re-run with --commit to write to Firestore.');
    return;
  }

  const admin = require('firebase-admin');
  const hajeriApp = admin.initializeApp(
    { credential: admin.credential.cert(require(HAJERI_SERVICE_ACCOUNT)), projectId: 'hajeri-465b7' },
    'hajeri',
  );
  const db = hajeriApp.firestore();
  const collection = db.collection('Day');

  let written = 0;
  for (const day of DAYS) {
    await collection.doc(day.Day_mr).set(day);
    console.log(`  wrote: ${day.Day_mr}`);
    written++;
  }

  console.log(`\nDone. ${written} written (doc ID = Day_mr).`);
}

main().catch(e => {
  console.error('Fatal:', e.message);
  process.exit(1);
});
