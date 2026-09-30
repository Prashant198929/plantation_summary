/**
 * Deletes docs from vrukshamojani-4ffd6's 'users' collection whose
 * attendance_viewer field is exactly false. Docs with attendance_viewer
 * missing/non-boolean are left untouched and reported separately for review
 * (all 2,690 users were already copied into 'Shree_Sadasya' before this
 * runs, so nothing is lost — this just prunes 'users' down to the
 * attendance-viewer allowlist).
 *
 * Usage (from functions/ directory):
 *   node delete_non_attendance_viewer_users.js            # dry run
 *   node delete_non_attendance_viewer_users.js --commit   # deletes from Firestore
 */

const { MAIN_SERVICE_ACCOUNT } = require('./migration_lib');

const COMMIT = process.argv.includes('--commit');
const BATCH_SIZE = 500;

async function main() {
  const admin = require('firebase-admin');
  const app = admin.initializeApp(
    { credential: admin.credential.cert(require(MAIN_SERVICE_ACCOUNT)), projectId: 'vrukshamojani-4ffd6' },
    'delete-non-attendance-viewer-users',
  );
  const db = app.firestore();

  const allSnap = await db.collection('users').select('name', 'zone', 'attendance_viewer').get();
  console.log(`Fetched ${allSnap.size} doc(s) from 'users'.`);

  const toDelete = [];
  const kept = [];
  const ambiguous = [];
  allSnap.forEach(doc => {
    const av = doc.get('attendance_viewer');
    if (av === false) toDelete.push(doc);
    else if (av === true) kept.push(doc);
    else ambiguous.push(doc);
  });

  console.log(`\nattendance_viewer == true (kept): ${kept.length}`);
  console.log(`attendance_viewer == false (would delete): ${toDelete.length}`);
  console.log(`attendance_viewer missing/non-boolean (left untouched, review manually): ${ambiguous.length}`);
  if (ambiguous.length) {
    ambiguous.forEach(doc => console.log(`  users/${doc.id}  name="${doc.get('name')}" zone=${doc.get('zone')} attendance_viewer=${JSON.stringify(doc.get('attendance_viewer'))}`));
  }

  console.log('\nSample of first 5 doc(s) to be deleted:');
  toDelete.slice(0, 5).forEach(doc => {
    console.log(`  users/${doc.id}  name="${doc.get('name')}" zone=${doc.get('zone')}`);
  });

  if (!COMMIT) {
    console.log(`\nDry run only — no deletes made. Would delete ${toDelete.length} doc(s) from 'users'.`);
    console.log('Re-run with --commit to delete from Firestore.');
    return;
  }

  let deleted = 0;
  for (let i = 0; i < toDelete.length; i += BATCH_SIZE) {
    const batch = db.batch();
    const chunk = toDelete.slice(i, i + BATCH_SIZE);
    chunk.forEach(doc => batch.delete(db.collection('users').doc(doc.id)));
    await batch.commit();
    deleted += chunk.length;
    console.log(`  committed batch: ${deleted}/${toDelete.length}`);
  }

  console.log(`\nDone. ${deleted} doc(s) deleted from 'users'.`);
}

main().catch(e => {
  console.error('Fatal:', e.message);
  process.exit(1);
});
