/**
 * Inspects hajeri-465b7 collections and prints doc ID samples.
 */
const admin = require('firebase-admin');
admin.initializeApp({
  credential: admin.credential.applicationDefault(),
  projectId: 'hajeri-465b7',
});
const db = admin.firestore();

async function main() {
  // WorkForm
  const wf = await db.collection('WorkForm').get();
  console.log(`\n=== WorkForm (${wf.size} docs) ===`);
  wf.docs.slice(0, 5).forEach(d => console.log(`  [${d.id}]`));

  // Places
  const pl = await db.collection('Places').get();
  console.log(`\n=== Places (${pl.size} docs) ===`);
  pl.docs.forEach(d => console.log(`  [${d.id}]`));

  // Users
  const us = await db.collection('users').get();
  console.log(`\n=== users (${us.size} docs) ===`);
  us.docs.slice(0, 5).forEach(d => console.log(`  [${d.id}]  name=${d.data().name}, zone=${d.data().zone}`));

  // Attendance parent docs
  const at = await db.collection('Attendance').get();
  console.log(`\n=== Attendance parent docs (${at.size} docs) ===`);
  for (const month of at.docs) {
    const records = await db.collection('Attendance').doc(month.id).collection('records').get();
    console.log(`  [${month.id}] → ${records.size} records`);
    records.docs.slice(0, 3).forEach(r => console.log(`    [${r.id}]`));
  }

  process.exit(0);
}
main().catch(e => { console.error('Fatal:', e.message); process.exit(1); });
