/**
 * Read-only, targeted check (minimal reads to avoid the daily quota) for why
 * Zone 31's hall list is showing empty on the attendance page.
 *
 * Looks up one specific user doc (users/8216851210503_178) in the main
 * project to see its baithak_mr/zone fields, then looks at BaithakSessions
 * in the hajeri project filtered to Zone 31 to see what's actually there and
 * whether Hall_mr would match via the app's normalizePlaceName logic.
 *
 * Usage (from functions/ directory):
 *   node check_zone31_hall.js
 */
const { MAIN_SERVICE_ACCOUNT, HAJERI_SERVICE_ACCOUNT } = require('./migration_lib');

function normalizePlaceName(value) {
  return (value || '').toString().replace(/,/g, ' ').replace(/\s+/g, ' ').trim();
}

async function main() {
  const admin = require('firebase-admin');

  const mainApp = admin.initializeApp(
    { credential: admin.credential.cert(require(MAIN_SERVICE_ACCOUNT)), projectId: 'vrukshamojani-4ffd6' },
    'check-zone31-main',
  );
  const hajeriApp = admin.initializeApp(
    { credential: admin.credential.cert(require(HAJERI_SERVICE_ACCOUNT)), projectId: 'hajeri-465b7' },
    'check-zone31-hajeri',
  );

  const mainDb = mainApp.firestore();
  const hajeriDb = hajeriApp.firestore();

  const userDoc = await mainDb.collection('users').doc('8216851210503_178').get();
  if (!userDoc.exists) {
    console.log(`users/8216851210503_178 does not exist in 'users'. Trying 'Shree_Sadasya'...`);
    const altDoc = await mainDb.collection('Shree_Sadasya').doc('8216851210503_178').get();
    if (altDoc.exists) {
      console.log('Found in Shree_Sadasya:', JSON.stringify(altDoc.data(), null, 2));
    } else {
      console.log('Not found in Shree_Sadasya either.');
    }
  } else {
    const data = userDoc.data();
    console.log('users/8216851210503_178:', JSON.stringify(data, null, 2));
  }

  console.log('\n--- BaithakSessions where Zone or Zone_mr mentions 31 ---');
  const sessionsSnap = await hajeriDb.collection('BaithakSessions').get();
  const zone31Sessions = sessionsSnap.docs.filter(d => {
    const data = d.data();
    const z = (data.Zone || '').toString();
    const zMr = (data.Zone_mr || '').toString();
    return /\b31\b/.test(z) || /\b31\b/.test(zMr);
  });
  console.log(`Total BaithakSessions docs: ${sessionsSnap.size}`);
  console.log(`Zone 31 sessions found: ${zone31Sessions.length}`);
  zone31Sessions.forEach(d => {
    console.log(`  docId="${d.id}"`, JSON.stringify(d.data()));
  });
}

main().catch(e => {
  console.error('Fatal:', e.message);
  process.exit(1);
});
