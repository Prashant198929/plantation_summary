/**
 * Fixes attendance records where userId / doc ID still reference old user doc IDs.
 * Looks up the real Firebase Auth UID via the mobile field.
 *
 * Run from functions/ directory:
 *   $env:GOOGLE_APPLICATION_CREDENTIALS = "C:\Users\psawarwadkar\Downloads\hajeri-465b7-firebase-adminsdk-fbsvc-df192818af.json"
 *   node fix_attendance_userids.js
 */

const hajeriAdmin = require('firebase-admin');
const mainAdmin = require('firebase-admin/app');

// Init hajeri app
const hajeriApp = hajeriAdmin.initializeApp({
  credential: hajeriAdmin.credential.cert(
    require('C:/Users/psawarwadkar/Downloads/hajeri-465b7-firebase-adminsdk-fbsvc-df192818af.json')
  ),
  projectId: 'hajeri-465b7',
}, 'hajeri');

// Init main app using vrukshamojani service account
const { initializeApp, cert } = require('firebase-admin/app');
const { getFirestore } = require('firebase-admin/firestore');

const mainApp = initializeApp({
  credential: cert(
    require('C:/GitLab/plantation_summary/android/app/vrukshamojani-4ffd6-eea304e118fb.json')
  ),
  projectId: 'vrukshamojani-4ffd6',
}, 'main');

const hajeriDb = hajeriAdmin.firestore(hajeriApp);
const mainDb   = getFirestore(mainApp);

const MONTHS = [
  'January','February','March','April','May','June',
  'July','August','September','October','November','December'
];

// Firebase Auth UIDs are 28-char alphanumeric
function isAuthUid(uid) {
  return /^[A-Za-z0-9]{20,}$/.test(uid) && !/^\d+$/.test(uid);
}

function invertedDateFromTimestamp(ts) {
  const d = ts.toDate();
  const yyyy = d.getFullYear().toString().padStart(4, '0');
  const mm   = (d.getMonth() + 1).toString().padStart(2, '0');
  const dd   = d.getDate().toString().padStart(2, '0');
  return 99999999 - parseInt(`${yyyy}${mm}${dd}`, 10);
}

async function buildMobileToUidMap() {
  const snap = await mainDb.collection('users').get();
  const map = {};
  for (const doc of snap.docs) {
    const d = doc.data();
    if (d.mobile && d.uid) {
      map[d.mobile.toString().trim()] = d.uid;
    }
  }
  return map;
}

async function main() {
  console.log('Building mobile → uid map from main users collection...');
  const mobileToUid = await buildMobileToUidMap();
  console.log(`  ${Object.keys(mobileToUid).length} users mapped.\n`);

  let totalFixed = 0, totalSkipped = 0, totalErrors = 0;

  const monthKeys = [];
  for (let year = 2023; year <= 2027; year++) {
    for (const month of MONTHS) monthKeys.push(`${month}_${year}`);
  }

  for (const monthKey of monthKeys) {
    const recordsRef = hajeriDb.collection('Attendance').doc(monthKey).collection('records');
    const snap = await recordsRef.get();
    if (snap.empty) continue;

    console.log(`\n[${monthKey}] — ${snap.size} records`);

    for (const doc of snap.docs) {
      const data = doc.data();
      const currentUserId = (data.userId || '').toString().trim();

      // Already using a valid Firebase Auth UID
      if (isAuthUid(currentUserId)) {
        // Check doc ID also correct: {8digits}_{authUid}
        const expectedId = `${invertedDateFromTimestamp(data.date)}_${currentUserId}`;
        if (doc.id === expectedId) {
          totalSkipped++;
          continue;
        }
      }

      // Look up real Auth UID via mobile
      const mobile = (data.mobile || '').toString().trim();
      const authUid = mobileToUid[mobile];

      if (!authUid) {
        console.log(`  SKIP [${doc.id}] — mobile ${mobile} not found in users`);
        totalSkipped++;
        continue;
      }

      const invertedDate = invertedDateFromTimestamp(data.date);
      const newId = `${invertedDate}_${authUid}`;
      const updatedData = { ...data, userId: authUid };

      if (doc.id === newId && currentUserId === authUid) {
        totalSkipped++;
        continue;
      }

      try {
        const batch = hajeriDb.batch();
        batch.set(recordsRef.doc(newId), updatedData);
        batch.delete(recordsRef.doc(doc.id));
        await batch.commit();
        console.log(`  FIXED [${doc.id}] → [${newId}]  (mobile=${mobile})`);
        totalFixed++;
      } catch (e) {
        console.error(`  ERROR [${doc.id}]: ${e.message}`);
        totalErrors++;
      }
    }
  }

  console.log('\n=== Done ===');
  console.log(`  Fixed  : ${totalFixed}`);
  console.log(`  Skipped: ${totalSkipped}`);
  console.log(`  Errors : ${totalErrors}`);
  process.exit(0);
}

main().catch(e => { console.error('Fatal:', e.message); process.exit(1); });
