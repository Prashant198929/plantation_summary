/**
 * Fixes the Hall_mr spelling on the single Zone 31 BaithakSessions doc so it
 * matches what 59 of 69 Shree_Sadasya users in that zone already have
 * stored in their baithak_mr field ("आजदेपाडा"), instead of the current,
 * differently-spelled "आजदेपदा" — which was causing the हॉल dropdown to
 * come up empty for those users on the attendance page.
 *
 * Only the BaithakSessions doc is touched. No Shree_Sadasya/user docs are
 * modified (per explicit instruction — do not update users).
 *
 * Doc id ("श्री. हरिश्चंद्र पाटील आजदेपदा, मंगळवार") and its Session_mr
 * field are left as-is: matching (filterSessionsByHall) and the displayed
 * label (sessionLabel) are both built from Hall_mr/Day_mr, not from
 * Session_mr or the doc id, so fixing Hall_mr alone is sufficient to fix
 * both matching and display.
 *
 * Usage (from functions/ directory):
 *   node fix_zone31_hall_name.js
 */
const { HAJERI_SERVICE_ACCOUNT } = require('./migration_lib');

const DOC_ID = 'श्री. हरिश्चंद्र पाटील आजदेपदा, मंगळवार';
const OLD_HALL_MR = 'श्री. हरिश्चंद्र पाटील आजदेपदा';
const NEW_HALL_MR = 'श्री. हरिश्चंद्र पाटील आजदेपाडा';

async function main() {
  const admin = require('firebase-admin');
  const app = admin.initializeApp(
    { credential: admin.credential.cert(require(HAJERI_SERVICE_ACCOUNT)), projectId: 'hajeri-465b7' },
    'fix-zone31-hall-name',
  );
  const db = app.firestore();

  const docRef = db.collection('BaithakSessions').doc(DOC_ID);
  const doc = await docRef.get();
  if (!doc.exists) {
    console.error(`Doc not found: ${DOC_ID}`);
    process.exit(1);
  }
  const data = doc.data();
  console.log('Before:', JSON.stringify(data));

  if (data.Hall_mr !== OLD_HALL_MR) {
    console.error(`Refusing to update: Hall_mr is currently "${data.Hall_mr}", expected "${OLD_HALL_MR}". Doc may have already changed.`);
    process.exit(1);
  }

  await docRef.update({ Hall_mr: NEW_HALL_MR });

  const after = await docRef.get();
  console.log('After: ', JSON.stringify(after.data()));
}

main().catch(e => {
  console.error('Fatal:', e.message);
  process.exit(1);
});
