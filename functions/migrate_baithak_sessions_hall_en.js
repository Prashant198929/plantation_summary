/**
 * One-time backfill: copies HallName_en from 'BaithakHalls' onto every
 * matching 'BaithakSessions' doc as a new 'Hall_En' field.
 *
 * 'BaithakHalls' doc IDs are the hall's Marathi name (see
 * migrate_baithak_halls.js), and 'BaithakSessions.Hall_mr' reuses that exact
 * spelling (see migrate_baithak_sessions.js), so each session's hall is a
 * direct doc lookup by ID rather than a query.
 *
 * Usage (from functions/ directory):
 *   node migrate_baithak_sessions_hall_en.js            # dry run, prints what would be written
 *   node migrate_baithak_sessions_hall_en.js --commit   # writes to Firestore
 */

const { HAJERI_SERVICE_ACCOUNT } = require('./migration_lib');

const COMMIT = process.argv.includes('--commit');

async function main() {
  const admin = require('firebase-admin');
  const hajeriApp = admin.initializeApp(
    { credential: admin.credential.cert(require(HAJERI_SERVICE_ACCOUNT)), projectId: 'hajeri-465b7' },
    'hajeri',
  );
  const db = hajeriApp.firestore();

  const sessionsSnap = await db.collection('BaithakSessions').get();
  console.log(`${sessionsSnap.size} session(s) found in 'BaithakSessions'.`);

  const updates = [];
  const unmatched = [];
  for (const doc of sessionsSnap.docs) {
    const hallMr = (doc.get('Hall_mr') || '').toString();
    if (!hallMr) {
      unmatched.push(`${doc.id} (no Hall_mr)`);
      continue;
    }
    const hallDoc = await db.collection('BaithakHalls').doc(hallMr).get();
    const hallEn = (hallDoc.get('HallName_en') || '').toString();
    if (!hallDoc.exists || !hallEn) {
      unmatched.push(`${doc.id} (no BaithakHalls match for "${hallMr}")`);
      continue;
    }
    updates.push({ id: doc.id, ref: doc.ref, hallMr, hallEn });
  }

  console.log(`\n${updates.length} matched, ${unmatched.length} unmatched.`);
  updates.forEach(u => console.log(`  ${u.id} -> Hall_En: ${u.hallEn}`));
  if (unmatched.length) {
    console.log('\nUnmatched (left as-is):');
    unmatched.forEach(u => console.log(`  ${u}`));
  }

  if (!COMMIT) {
    console.log('\nDry run only — no writes made. Re-run with --commit to write to Firestore.');
    return;
  }

  let written = 0;
  for (const u of updates) {
    await u.ref.update({ Hall_En: u.hallEn });
    written++;
  }
  console.log(`\nDone. ${written} doc(s) updated with Hall_En.`);
}

main().catch(e => {
  console.error('Fatal:', e.message);
  process.exit(1);
});
