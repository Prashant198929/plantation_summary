/**
 * One-time load of vehicle type options into the vrukshamojani-4ffd6
 * Firebase project (the MAIN app project, not hajeri-465b7) as a new
 * 'Vehicle' collection, for the Add User page's "Add Vehicle" section.
 *
 * Usage (from functions/ directory):
 *   node migrate_vehicle_types.js            # dry run, prints what would be written
 *   node migrate_vehicle_types.js --commit   # writes to Firestore
 *
 * Doc ID = name. `order` preserves the given display order (not
 * alphabetical — "Dumper" is deliberately last).
 */

const { MAIN_SERVICE_ACCOUNT } = require('./migration_lib');

const COMMIT = process.argv.includes('--commit');

const VEHICLE_TYPES = [
  '2 wheeler',
  '3 wheeler',
  '4 wheeler (5 seater)',
  '4 wheeler (7 seater)',
  'Mini tempo',
  'Dumper',
].map((name, order) => ({ name, order }));

async function main() {
  console.log(`${VEHICLE_TYPES.length} vehicle type(s) to write into vrukshamojani-4ffd6 'Vehicle'.`);
  VEHICLE_TYPES.forEach((v, i) => console.log(`  ${i + 1}. ${v.name}`));

  if (!COMMIT) {
    console.log('\nDry run only — no writes made. Re-run with --commit to write to Firestore.');
    return;
  }

  const admin = require('firebase-admin');
  const mainApp = admin.initializeApp(
    { credential: admin.credential.cert(require(MAIN_SERVICE_ACCOUNT)), projectId: 'vrukshamojani-4ffd6' },
    'vrukshamojani',
  );
  const db = mainApp.firestore();
  const collection = db.collection('Vehicle');

  let written = 0;
  for (const vehicle of VEHICLE_TYPES) {
    await collection.doc(vehicle.name).set(vehicle);
    console.log(`  wrote: ${vehicle.name}`);
    written++;
  }

  console.log(`\nDone. ${written} written (doc ID = name).`);
}

main().catch(e => {
  console.error('Fatal:', e.message);
  process.exit(1);
});
