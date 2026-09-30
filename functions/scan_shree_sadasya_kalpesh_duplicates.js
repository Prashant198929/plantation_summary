/**
 * Read-only scan of vrukshamojani-4ffd6's 'Shree_Sadasya' collection for
 * duplicate profiles matching "Kalpesh" (English or Marathi), plus a direct
 * lookup of the two suspect docIds (79739197_392 and 79739197_392_392_32)
 * seen in Attendance — those two IDs collapse to the same base uid "392"
 * once the trailing zoneKey ("_32") from the newer docId scheme is
 * stripped, so this checks whether 'Shree_Sadasya' itself also has more
 * than one doc for that uid/name (a separate concern from the Attendance
 * docId-scheme duplicate already diagnosed in attendance_page.dart).
 *
 * Usage (from functions/ directory):
 *   node scan_shree_sadasya_kalpesh_duplicates.js
 */
const { MAIN_SERVICE_ACCOUNT } = require('./migration_lib');

const NAME_QUERY = 'kalpesh';
const SUSPECT_UIDS = ['392'];

function norm(s) {
  return (s ?? '').toString().trim().toLowerCase();
}

async function main() {
  const admin = require('firebase-admin');
  const app = admin.initializeApp(
    { credential: admin.credential.cert(require(MAIN_SERVICE_ACCOUNT)), projectId: 'vrukshamojani-4ffd6' },
    'scan-shree-sadasya-kalpesh',
  );
  const db = app.firestore();

  const snap = await db.collection('Shree_Sadasya').get();
  console.log(`Fetched ${snap.size} doc(s) from 'Shree_Sadasya'.\n`);

  const matches = snap.docs.filter(d => {
    const data = d.data();
    return norm(data.name).includes(NAME_QUERY) || norm(data.name_mr).includes(NAME_QUERY);
  });

  console.log(`=== Docs with name matching "${NAME_QUERY}" (${matches.length}) ===`);
  matches.forEach(d => {
    const data = d.data();
    console.log(
      `  [${d.id}] name=${data.name ?? ''} name_mr=${data.name_mr ?? ''} ` +
      `zone=${data.zone ?? ''} zone_mr=${data.zone_mr ?? ''} mobile=${data.mobile ?? ''}`,
    );
  });

  // Group by normalized name to surface likely duplicate profiles.
  const byName = new Map();
  matches.forEach(d => {
    const data = d.data();
    const key = norm(data.name) || norm(data.name_mr);
    if (!byName.has(key)) byName.set(key, []);
    byName.get(key).push(d.id);
  });
  const dupNames = [...byName.entries()].filter(([, ids]) => ids.length > 1);
  console.log(`\n=== Names with more than one doc (${dupNames.length}) ===`);
  dupNames.forEach(([name, ids]) => console.log(`  "${name}": ${ids.join(', ')}`));

  console.log(`\n=== Direct lookup for suspect uid(s): ${SUSPECT_UIDS.join(', ')} ===`);
  for (const uid of SUSPECT_UIDS) {
    const doc = await db.collection('Shree_Sadasya').doc(uid).get();
    if (doc.exists) {
      const data = doc.data();
      console.log(`  [${uid}] EXISTS name=${data.name ?? ''} name_mr=${data.name_mr ?? ''} zone=${data.zone ?? ''}`);
    } else {
      console.log(`  [${uid}] does not exist as a doc ID in Shree_Sadasya`);
    }
  }
}

main().catch(e => {
  console.error('Fatal:', e.message);
  process.exit(1);
});
