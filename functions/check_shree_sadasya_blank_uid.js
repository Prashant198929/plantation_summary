/**
 * Read-only check: does vrukshamojani-4ffd6's 'Shree_Sadasya' collection
 * have docs with a blank-but-present 'uid' field (empty string, not
 * missing)? attendance_support.dart reads uid as `data['uid'] ?? doc.id`,
 * which only falls back to doc.id when 'uid' is null — an empty string
 * '' passes through as-is. If multiple docs share uid: '', the app's
 * in-memory user list would treat them as the SAME identity, so checking
 * one attendance checkbox would silently un-check another sharing that
 * blank uid — a likely explanation for reported "checked members
 * disappearing" behavior on the attendance page.
 *
 * Usage (from functions/ directory):
 *   node check_shree_sadasya_blank_uid.js
 */
const { MAIN_SERVICE_ACCOUNT } = require('./migration_lib');

async function main() {
  const admin = require('firebase-admin');
  const app = admin.initializeApp(
    { credential: admin.credential.cert(require(MAIN_SERVICE_ACCOUNT)), projectId: 'vrukshamojani-4ffd6' },
    'check-shree-sadasya-blank-uid',
  );
  const db = app.firestore();

  const snap = await db.collection('Shree_Sadasya').get();
  console.log(`Fetched ${snap.size} doc(s) from 'Shree_Sadasya'.`);

  const uidCounts = new Map();
  let missingField = 0;
  let blankString = 0;
  snap.docs.forEach(d => {
    const data = d.data();
    if (!('uid' in data)) {
      missingField++;
      return;
    }
    const uid = data.uid;
    if (uid === '' || uid === null) {
      blankString++;
    }
    const key = uid === undefined ? '<undefined>' : uid === null ? '<null>' : String(uid);
    if (!uidCounts.has(key)) uidCounts.set(key, []);
    uidCounts.get(key).push(d.id);
  });

  console.log(`\nDocs with no 'uid' field at all: ${missingField} (these correctly fall back to doc.id)`);
  console.log(`Docs with uid === '' or null: ${blankString}`);

  const dupes = [...uidCounts.entries()].filter(([, ids]) => ids.length > 1);
  console.log(`\n=== uid values shared by more than one doc (${dupes.length}) ===`);
  dupes.slice(0, 20).forEach(([uid, ids]) => {
    console.log(`  uid="${uid}" -> ${ids.length} docs: ${ids.slice(0, 10).join(', ')}${ids.length > 10 ? ', ...' : ''}`);
  });
  if (dupes.length > 20) console.log(`  ... and ${dupes.length - 20} more shared uid values`);
}

main().catch(e => {
  console.error('Fatal:', e.message);
  process.exit(1);
});
