/**
 * Removes the original 30 hall-only docs from 'BaithakHalls' (the ones with
 * only HallName_en/HallName_mr, no Day_mr/Zone fields) — now that the full
 * session-shaped docs (Hall_mr/Day_mr/Zone/Session_mr, keyed by Session_mr)
 * have been copied in alongside them (see copy_baithak_sessions_to_halls.js
 * and move_baithak_session_zones_to_halls.js), the bare hall-only docs are
 * redundant duplicates of the hall identified in each session doc.
 *
 * A doc is considered "bare" (to delete) if it has no Day_mr field and no
 * Zone field.
 *
 * Usage (from functions/ directory):
 *   node remove_bare_baithak_halls.js            # dry run
 *   node remove_bare_baithak_halls.js --commit   # deletes
 */

const { HAJERI_SERVICE_ACCOUNT } = require('./migration_lib');

const COMMIT = process.argv.includes('--commit');

async function main() {
  const admin = require('firebase-admin');
  const app = admin.initializeApp(
    { credential: admin.credential.cert(require(HAJERI_SERVICE_ACCOUNT)), projectId: 'hajeri-465b7' },
    'hajeri-remove-bare',
  );
  const db = app.firestore();

  const snap = await db.collection('BaithakHalls').get();
  const bare = snap.docs.filter(d => {
    const data = d.data();
    return !data.Day_mr && !data.Zone;
  });

  console.log(`BaithakHalls total: ${snap.size}`);
  console.log(`Bare (no Day_mr/Zone) docs to delete: ${bare.length}\n`);
  bare.forEach((d, i) => console.log(`  ${i + 1}. ${d.id}  ${JSON.stringify(d.data())}`));

  if (!COMMIT) {
    console.log('\nDry run only — no deletes made. Re-run with --commit to delete.');
    return;
  }

  let deleted = 0;
  for (const d of bare) {
    await db.collection('BaithakHalls').doc(d.id).delete();
    deleted++;
  }
  console.log(`\nDeleted ${deleted} doc(s).`);

  const finalSnap = await db.collection('BaithakHalls').get();
  console.log(`BaithakHalls now has ${finalSnap.size} docs (expected 79).`);
}

main().catch(e => {
  console.error('Fatal:', e.message);
  process.exit(1);
});
