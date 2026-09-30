/**
 * Copies the remaining 48 'BaithakSessions' docs (the original hall+day
 * list, see migrate_baithak_sessions.js) into 'BaithakHalls' with all their
 * fields (Hall_mr, Hall_En, Day_mr, Day, Session_mr, Zone, Zone_mr), keyed by
 * the same Session_mr doc ID already used in BaithakSessions. This doesn't
 * touch BaithakSessions (copy, not move) and doesn't collide with
 * BaithakHalls' existing docs: the original 30 are keyed by plain
 * HallName_mr, and the 31 zone-variant docs already moved over in
 * move_baithak_session_zones_to_halls.js use a different Session_mr (with a
 * "(झोन N)" suffix) than these 48 (no suffix).
 *
 * Usage (from functions/ directory):
 *   node copy_baithak_sessions_to_halls.js            # dry run
 *   node copy_baithak_sessions_to_halls.js --commit   # writes
 */

const { HAJERI_SERVICE_ACCOUNT } = require('./migration_lib');

const COMMIT = process.argv.includes('--commit');

async function main() {
  const admin = require('firebase-admin');
  const app = admin.initializeApp(
    { credential: admin.credential.cert(require(HAJERI_SERVICE_ACCOUNT)), projectId: 'hajeri-465b7' },
    'hajeri-copy',
  );
  const db = app.firestore();

  const snap = await db.collection('BaithakSessions').get();
  console.log(`BaithakSessions total: ${snap.size} (expected 48)`);
  snap.docs.forEach((d, i) => console.log(`  ${i + 1}. ${d.id}`));

  if (!COMMIT) {
    console.log('\nDry run only — no writes made. Re-run with --commit to write to BaithakHalls.');
    return;
  }

  let written = 0;
  for (const d of snap.docs) {
    await db.collection('BaithakHalls').doc(d.id).set(d.data());
    written++;
  }
  console.log(`\nWrote ${written} doc(s) into BaithakHalls.`);

  const finalSnap = await db.collection('BaithakHalls').get();
  console.log(`BaithakHalls now has ${finalSnap.size} docs total (expected 30 + 31 + 48 = 109).`);
}

main().catch(e => {
  console.error('Fatal:', e.message);
  process.exit(1);
});
