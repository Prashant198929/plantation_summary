/**
 * Follow-up to fix_zone31_hall_name.js: the Zone 31 BaithakSessions doc's
 * Hall_mr was already changed (externally, not by us) to
 * "श्री. हरिश्चंद्र पाटील, आजदेपाडा", which now matches 59 of 69 Zone 31
 * users' baithak_mr — except one outlier, Prashant Prakash Parshram
 * (Shree_Sadasya/8213566361754_22843), whose baithak_mr still holds the old
 * spelling ("श्री. हरिश्चंद्र पाटील आजदेपदा") and would now show an empty
 * हॉल list.
 *
 * This updates ONLY that one user's baithak_mr to match the current
 * BaithakSessions Hall_mr exactly.
 *
 * Usage (from functions/ directory):
 *   node fix_zone31_outlier_user.js
 */
const { MAIN_SERVICE_ACCOUNT } = require('./migration_lib');

const DOC_ID = '8213566361754_22843';
const OLD_BAITHAK_MR = 'श्री. हरिश्चंद्र पाटील आजदेपदा';
const NEW_BAITHAK_MR = 'श्री. हरिश्चंद्र पाटील, आजदेपाडा';

async function main() {
  const admin = require('firebase-admin');
  const app = admin.initializeApp(
    { credential: admin.credential.cert(require(MAIN_SERVICE_ACCOUNT)), projectId: 'vrukshamojani-4ffd6' },
    'fix-zone31-outlier-user',
  );
  const db = app.firestore();

  const docRef = db.collection('Shree_Sadasya').doc(DOC_ID);
  const doc = await docRef.get();
  if (!doc.exists) {
    console.error(`Doc not found: ${DOC_ID}`);
    process.exit(1);
  }
  const data = doc.data();
  console.log('Before baithak_mr:', data.baithak_mr, ' name:', data.name || data.name_mr);

  if (data.baithak_mr !== OLD_BAITHAK_MR) {
    console.error(`Refusing to update: baithak_mr is currently "${data.baithak_mr}", expected "${OLD_BAITHAK_MR}". Doc may have already changed.`);
    process.exit(1);
  }

  await docRef.update({ baithak_mr: NEW_BAITHAK_MR });

  const after = await docRef.get();
  console.log('After baithak_mr: ', after.data().baithak_mr);
}

main().catch(e => {
  console.error('Fatal:', e.message);
  process.exit(1);
});
