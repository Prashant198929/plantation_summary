/**
 * Read-only check against hajeri-465b7: lists every doc in 'users', and
 * reports how many docs sit under Attendance/July_2026/records (the month
 * doc a user wants deleted) before any deletion is attempted.
 *
 * Usage (from functions/ directory):
 *   node list_hajeri_users_and_july_records.js
 */
const { HAJERI_SERVICE_ACCOUNT } = require('./migration_lib');

async function main() {
  const admin = require('firebase-admin');
  const app = admin.initializeApp(
    { credential: admin.credential.cert(require(HAJERI_SERVICE_ACCOUNT)), projectId: 'hajeri-465b7' },
    'hajeri',
  );
  const db = app.firestore();

  const usersSnap = await db.collection('users').get();
  console.log(`=== users (${usersSnap.size} docs) ===`);
  usersSnap.docs.forEach(d => {
    const data = d.data();
    console.log(`  [${d.id}] name=${data.name ?? ''} zone=${data.zone ?? ''} mobile=${data.mobile ?? ''}`);
  });

  const monthId = 'July_2026';
  const recordsSnap = await db.collection('Attendance').doc(monthId).collection('records').get();
  console.log(`\n=== Attendance/${monthId}/records (${recordsSnap.size} docs) ===`);
  recordsSnap.docs.slice(0, 10).forEach(r => console.log(`  [${r.id}]`));
  if (recordsSnap.size > 10) console.log(`  ... and ${recordsSnap.size - 10} more`);
}

main().catch(e => {
  console.error('Fatal:', e.message);
  process.exit(1);
});
