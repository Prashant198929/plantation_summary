/**
 * Copies every doc in vrukshamojani-4ffd6's 'users' collection into a new
 * 'Shree_Sadasya' collection, preserving the same document IDs.
 *
 * Usage (from functions/ directory):
 *   node copy_users_to_shree_sadasya.js            # dry run
 *   node copy_users_to_shree_sadasya.js --commit   # writes to Firestore
 */

const { MAIN_SERVICE_ACCOUNT } = require('./migration_lib');

const COMMIT = process.argv.includes('--commit');
const BATCH_SIZE = 500;

async function main() {
  const admin = require('firebase-admin');
  const app = admin.initializeApp(
    { credential: admin.credential.cert(require(MAIN_SERVICE_ACCOUNT)), projectId: 'vrukshamojani-4ffd6' },
    'copy-users-to-shree-sadasya',
  );
  const db = app.firestore();

  const usersSnap = await db.collection('users').get();
  console.log(`Fetched ${usersSnap.size} doc(s) from 'users'.`);

  const existingSnap = await db.collection('Shree_Sadasya').select().get();
  const existingIds = new Set(existingSnap.docs.map(d => d.id));
  if (existingIds.size) {
    console.log(`'Shree_Sadasya' already has ${existingIds.size} doc(s) — those will be overwritten.`);
  }

  console.log('\nSample of first 5 doc(s) to be copied:');
  usersSnap.docs.slice(0, 5).forEach(doc => {
    console.log(`  users/${doc.id} -> Shree_Sadasya/${doc.id}  name="${doc.get('name')}" zone=${doc.get('zone')}`);
  });

  if (!COMMIT) {
    console.log(`\nDry run only — no writes made. Would copy ${usersSnap.size} doc(s) to 'Shree_Sadasya'.`);
    console.log('Re-run with --commit to write to Firestore.');
    return;
  }

  const docs = usersSnap.docs;
  let written = 0;
  for (let i = 0; i < docs.length; i += BATCH_SIZE) {
    const batch = db.batch();
    const chunk = docs.slice(i, i + BATCH_SIZE);
    chunk.forEach(doc => {
      batch.set(db.collection('Shree_Sadasya').doc(doc.id), doc.data());
    });
    await batch.commit();
    written += chunk.length;
    console.log(`  committed batch: ${written}/${docs.length}`);
  }

  console.log(`\nDone. ${written} doc(s) copied to 'Shree_Sadasya'.`);
}

main().catch(e => {
  console.error('Fatal:', e.message);
  process.exit(1);
});
