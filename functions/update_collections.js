/**
 * Updates WorkForm and Places collections in hajeri-465b7 Firebase project.
 * - Deletes all existing documents in each collection
 * - Inserts fresh data from SQL WorkMaster and LocationMaster tables
 *
 * Run from the functions/ directory:
 *   node update_collections.js
 */

const admin = require('firebase-admin');

admin.initializeApp({
  credential: admin.credential.applicationDefault(),
  projectId: 'hajeri-465b7',
});

const db = admin.firestore();

const WORK_TYPES = [
  { id: 1,  name: 'झाडांना पाणी देणे' },
  { id: 2,  name: 'आळ तयार करणे' },
  { id: 3,  name: 'ग्रीन नेट बांधणे' },
  { id: 4,  name: 'मोठे गवत कापणे' },
  { id: 5,  name: 'माती भुसभुशीत करणे' },
  { id: 6,  name: 'गांडूळ खत टाकणे' },
  { id: 7,  name: 'व्हर्मी कंपोस्ट खत टाकणे' },
  { id: 8,  name: 'झाडांची पाने धुणे' },
  { id: 9,  name: 'कंपोस्ट खत तयार करणे' },
  { id: 10, name: 'गांडूळ खत तयार करणे' },
  { id: 11, name: 'पाण्याच्या टाक्या भरणे' },
  { id: 12, name: 'ग्रास कटिंग किंवा इतर मशीन दुरुस्त करणे' },
  { id: 13, name: 'झाडांचे व इतर परिसर सर्वेक्षण करणे' },
  { id: 14, name: 'साहित्य नोंदणी करणे' },
  { id: 15, name: 'हजेरी नोंद करणे' },
  { id: 16, name: 'झुकलेल्या झाडांना आधार देणे' },
  { id: 17, name: 'पाण्याचा निचरा करणे' },
  { id: 18, name: 'कीटक नाशके फवारणे' },
  { id: 19, name: 'झाडा जवळचे गवत कापणे' },
  { id: 20, name: 'झाडांची माहिती अद्ययावत करणे' },
  { id: 21, name: 'नवीन झाडे लावणे' },
  { id: 22, name: 'मेलेली झाडे बदलणे' },
  { id: 23, name: 'झाडांची संख्या अद्ययावत करणे' },
  { id: 24, name: 'झाडांना नंबर देणे' },
  { id: 25, name: 'नवीन पाईप टाकणे' },
  { id: 26, name: 'पाईप दुरुस्त करणे' },
  { id: 27, name: 'गार्डन तयार करणे' },
  { id: 28, name: 'नवीन झाडे लावण्यासाठी खड्डे खोदणे' },
  { id: 29, name: 'रस्ता तयार करणे' },
  { id: 30, name: 'कचरा गोळा करणे' },
  { id: 31, name: 'टाकी बसवण्यासाठी बेस तयार करणे' },
  { id: 32, name: 'चर खोदणे' },
  { id: 33, name: 'चर साफ करणे' },
];

const PLACES = [
  { id: 1, name: 'उंबार्ली' },
  { id: 2, name: 'उंबार्ली - (खत संकलन प्रकल्प)' },
  { id: 3, name: 'सोनारपाडा हॉल' },
  { id: 4, name: 'खोणी बैठक हॉल' },
  { id: 5, name: 'जल पुनर्भरण' },
];

async function clearCollection(collectionName) {
  const snap = await db.collection(collectionName).get();
  if (snap.empty) {
    console.log(`  ${collectionName}: already empty`);
    return 0;
  }
  const batch = db.batch();
  snap.docs.forEach(doc => batch.delete(doc.ref));
  await batch.commit();
  console.log(`  ${collectionName}: deleted ${snap.size} document(s)`);
  return snap.size;
}

async function insertWorkForm() {
  const batch = db.batch();
  for (const w of WORK_TYPES) {
    const ref = db.collection('WorkForm').doc(w.name);
    batch.set(ref, { Topic: w.name, WorkMasterId: w.id });
  }
  await batch.commit();
  console.log(`  WorkForm: inserted ${WORK_TYPES.length} work types`);
}

async function insertPlaces() {
  const batch = db.batch();
  for (const p of PLACES) {
    const ref = db.collection('Places').doc(p.name);
    batch.set(ref, { PlaceName: p.name, LocationMasterId: p.id });
  }
  await batch.commit();
  console.log(`  Places: inserted ${PLACES.length} places`);
}

async function main() {
  console.log('=== Updating hajeri-465b7 collections ===\n');

  console.log('Clearing existing data...');
  await clearCollection('WorkForm');
  await clearCollection('Places');

  console.log('\nInserting new data...');
  await insertWorkForm();
  await insertPlaces();

  console.log('\nDone!');
  process.exit(0);
}

main().catch(err => {
  console.error('Error:', err.message);
  process.exit(1);
});
