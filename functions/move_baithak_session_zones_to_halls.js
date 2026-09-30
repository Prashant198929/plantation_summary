/**
 * One-time cleanup: the 31 zone-suffixed docs in 'BaithakSessions' (hall+day
 * sessions that also carry a Zone/Zone_mr for a specific additional zone,
 * doc ID like "<Hall_mr>, <Day_mr> (झोन N)") get copied as-is into
 * 'BaithakHalls' (doc ID = Session_mr, same string used in BaithakSessions —
 * doesn't collide with BaithakHalls' existing 30 docs, which are keyed by
 * plain HallName_mr with no day/zone suffix). After the copy, the 31 are
 * deleted from BaithakSessions, leaving exactly the original 48 hall+day
 * records (see migrate_baithak_sessions.js) in that collection.
 *
 * Usage (from functions/ directory):
 *   node move_baithak_session_zones_to_halls.js            # dry run
 *   node move_baithak_session_zones_to_halls.js --commit   # writes + deletes
 */

const { HAJERI_SERVICE_ACCOUNT } = require('./migration_lib');

const COMMIT = process.argv.includes('--commit');
const ZONE_SUFFIX_RE = /\(झोन\s*\d+\)\s*$/;

async function main() {
  const admin = require('firebase-admin');
  const app = admin.initializeApp(
    { credential: admin.credential.cert(require(HAJERI_SERVICE_ACCOUNT)), projectId: 'hajeri-465b7' },
    'hajeri-move',
  );
  const db = app.firestore();

  const snap = await db.collection('BaithakSessions').get();
  const extras = snap.docs.filter(d => ZONE_SUFFIX_RE.test(d.id));

  console.log(`BaithakSessions total: ${snap.size}`);
  console.log(`Zone-suffixed extras to move: ${extras.length}\n`);
  extras.forEach((d, i) => console.log(`  ${i + 1}. ${d.id}`));

  if (!COMMIT) {
    console.log('\nDry run only — no writes/deletes made. Re-run with --commit to apply.');
    return;
  }

  let written = 0;
  for (const d of extras) {
    await db.collection('BaithakHalls').doc(d.id).set(d.data());
    written++;
  }
  console.log(`\nWrote ${written} doc(s) into BaithakHalls.`);

  let deleted = 0;
  for (const d of extras) {
    await db.collection('BaithakSessions').doc(d.id).delete();
    deleted++;
  }
  console.log(`Deleted ${deleted} doc(s) from BaithakSessions.`);

  const finalSnap = await db.collection('BaithakSessions').get();
  console.log(`\nBaithakSessions now has ${finalSnap.size} docs (expected 48).`);
}

main().catch(e => {
  console.error('Fatal:', e.message);
  process.exit(1);
});
