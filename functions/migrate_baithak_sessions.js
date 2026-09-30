/**
 * One-time load of real baithak sessions (hall + day pairs, as they actually
 * meet — not every hall meets every day, and some halls meet on more than
 * one day) into the hajeri-465b7 Firebase project as a new 'BaithakSessions'
 * collection.
 *
 * Source: the list of real sessions provided directly by the user (matches
 * the shape of `sevakdb.dbo.BaithakMaster`: BaithakName_mar + ', ' + Day_mr).
 * `Hall_mr` here reuses the exact spelling already migrated into
 * 'BaithakHalls' (see migrate_baithak_halls.js) so it matches users.hall_mr
 * for filtering; `Day_mr` matches the 'Day' collection / users.baithak_day_mr
 * (see migrate_days.js). `Day` (English) is derived from Day_mr the same way
 * lib/attendance_support.dart's fetchBaithakSessionOptions expects it to
 * already be on the doc. One new hall not in the existing 30 was added:
 * 'श्री सागर ठाकूर, जुनी डोंबिवली'.
 *
 * Usage (from functions/ directory):
 *   node migrate_baithak_sessions.js            # dry run, prints what would be written
 *   node migrate_baithak_sessions.js --commit   # writes to Firestore
 *
 * Doc ID = Session_mr (Hall_mr + ', ' + Day_mr), so a session can be looked
 * up directly by its full Marathi label. Idempotent: uses .set(..., {merge:
 * true}) on that ID, so re-running this for a newly-added hall won't clobber
 * Hall_En/Zone/Zone_mr/Day fields other scripts have since added to the
 * sessions already in Firestore.
 */

const { HAJERI_SERVICE_ACCOUNT } = require('./migration_lib');

const COMMIT = process.argv.includes('--commit');

// Mirrors lib/attendance_support.dart's _baithakDayMr (Marathi -> English).
const DAY_MR_TO_EN = {
  'सोमवार': 'Monday',
  'मंगळवार': 'Tuesday',
  'बुधवार': 'Wednesday',
  'गुरुवार': 'Thursday',
  'शुक्रवार': 'Friday',
  'शनिवार': 'Saturday',
  'रविवार': 'Sunday',
};

const SESSIONS = [
  { Hall_mr: 'श्री. दामू ठाकरे दावडी', Day_mr: 'गुरुवार' },
  { Hall_mr: 'श्री. भास्कर गायकर गोळवली', Day_mr: 'गुरुवार' },
  { Hall_mr: 'श्री. शंकर शेलार खंबाळपाडा', Day_mr: 'गुरुवार' },
  { Hall_mr: 'श्री. भरत म्हसकर म्हास्करवाडा', Day_mr: 'मंगळवार' },
  { Hall_mr: 'श्री. भूषण म्हात्रे पाथर्ली', Day_mr: 'सोमवार' },
  { Hall_mr: 'श्री. भूषण म्हात्रे पाथर्ली', Day_mr: 'मंगळवार' },
  { Hall_mr: 'श्री. हरिश्चंद्र पाटील आजदेपदा', Day_mr: 'मंगळवार' },
  { Hall_mr: 'श्री. श्याम पाटील मल्हार बंगला', Day_mr: 'सोमवार' },
  { Hall_mr: 'श्री. श्याम पाटील मल्हार बंगला', Day_mr: 'बुधवार' },
  { Hall_mr: 'श्री. श्याम पाटील मल्हार बंगला', Day_mr: 'शुक्रवार' },
  { Hall_mr: 'श्री. सिद्धार्थ म्हात्रे सोनारपाडा', Day_mr: 'बुधवार' },
  { Hall_mr: 'श्री. सिद्धार्थ म्हात्रे सोनारपाडा', Day_mr: 'गुरुवार' },
  { Hall_mr: 'श्री. प्रकाश पाटील नांदिवली', Day_mr: 'मंगळवार' },
  { Hall_mr: 'श्री. प्रकाश पाटील नांदिवली', Day_mr: 'गुरुवार' },
  { Hall_mr: 'श्री. प्रकाश पाटील नांदिवली', Day_mr: 'रविवार' },
  { Hall_mr: 'श्री. तानाजी पाटील भोपर', Day_mr: 'गुरुवार' },
  { Hall_mr: 'श्री. प्रवीण रा. म्हात्रे कोपर', Day_mr: 'सोमवार' },
  { Hall_mr: 'श्री. प्रवीण रा. म्हात्रे कोपर', Day_mr: 'गुरुवार' },
  { Hall_mr: 'श्री. ओमकार भोईर मोठागाव', Day_mr: 'सोमवार' },
  { Hall_mr: 'श्री. रमेश पाटील देवीचा पाडा', Day_mr: 'मंगळवार' },
  { Hall_mr: 'श्री. रमेश पाटील देवीचा पाडा', Day_mr: 'गुरुवार' },
  { Hall_mr: 'श्री. संदेश मोरे गावदेवी मंदिर (प.)', Day_mr: 'बुधवार' },
  { Hall_mr: 'श्री. जीवन म्हात्रे नवापाडा', Day_mr: 'मंगळवार' },
  { Hall_mr: 'श्री. जीवन म्हात्रे नवापाडा', Day_mr: 'बुधवार' },
  { Hall_mr: 'श्री. जीवन म्हात्रे नवापाडा', Day_mr: 'गुरुवार' },
  { Hall_mr: 'श्री. प्रवीण म्हात्रे दातिवली', Day_mr: 'शुक्रवार' },
  { Hall_mr: 'श्री. अरुण मढवी आगासन', Day_mr: 'बुधवार' },
  { Hall_mr: 'श्री. उमेश पाटील साबे, दिवा (पू)', Day_mr: 'सोमवार' },
  { Hall_mr: 'श्री. उमेश पाटील साबे, दिवा (पू)', Day_mr: 'बुधवार' },
  { Hall_mr: 'श्री. उमेश पाटील साबे, दिवा (पू)', Day_mr: 'गुरुवार' },
  { Hall_mr: 'श्री. शैलेश पाटील दिवा', Day_mr: 'रविवार' },
  { Hall_mr: 'श्री. इंद्रपाल पाटील दिवा (प)', Day_mr: 'मंगळवार' },
  { Hall_mr: 'श्री. चंदर म्हात्रे डायघर', Day_mr: 'सोमवार' },
  { Hall_mr: 'श्री. चंदर म्हात्रे डायघर', Day_mr: 'मंगळवार' },
  { Hall_mr: 'श्री. मोहन साळवी मुंब्रा', Day_mr: 'बुधवार' },
  { Hall_mr: 'श्री. मोहन साळवी मुंब्रा', Day_mr: 'शुक्रवार' },
  { Hall_mr: 'श्री. जयंता पाटील दहिसर', Day_mr: 'मंगळवार' },
  { Hall_mr: 'श्री. अनंता पाटील कोळेगाव', Day_mr: 'मंगळवार' },
  { Hall_mr: 'श्री. अनंता पाटील कोळेगाव', Day_mr: 'बुधवार' },
  { Hall_mr: 'श्री. अनंता पाटील कोळेगाव', Day_mr: 'गुरुवार' },
  { Hall_mr: 'श्री. अनंता पाटील कोळेगाव', Day_mr: 'शुक्रवार' },
  { Hall_mr: 'श्री. लहु फराड खोणी', Day_mr: 'बुधवार' },
  { Hall_mr: 'श्री. हरी पाटील वडवली', Day_mr: 'गुरुवार' },
  { Hall_mr: 'श्री. कृष्णा पाटील वाकळण', Day_mr: 'गुरुवार' },
  { Hall_mr: 'श्री. राजेंद्र साळवी, मुलुंड ईस्ट', Day_mr: 'मंगळवार' },
  { Hall_mr: 'श्री सागर ठाकूर, जुनी डोंबिवली', Day_mr: 'मंगळवार' },
  { Hall_mr: 'अहिल्याबाई विद्यामंदिर, काळाचौकी चिंचपोकळी', Day_mr: 'बुधवार' },
  { Hall_mr: 'भंडार्ली', Day_mr: 'मंगळवार' },
].map(s => ({
  ...s,
  Session_mr: `${s.Hall_mr}, ${s.Day_mr}`,
  Day: DAY_MR_TO_EN[s.Day_mr] || '',
}));

async function main() {
  console.log(`${SESSIONS.length} session(s) to write into hajeri-465b7 'BaithakSessions'.`);
  SESSIONS.forEach((s, i) => console.log(`  ${i + 1}. ${s.Session_mr}`));

  if (!COMMIT) {
    console.log('\nDry run only — no writes made. Re-run with --commit to write to Firestore.');
    return;
  }

  const admin = require('firebase-admin');
  const hajeriApp = admin.initializeApp(
    { credential: admin.credential.cert(require(HAJERI_SERVICE_ACCOUNT)), projectId: 'hajeri-465b7' },
    'hajeri',
  );
  const db = hajeriApp.firestore();
  const collection = db.collection('BaithakSessions');

  let written = 0;
  for (const session of SESSIONS) {
    await collection.doc(session.Session_mr).set(session, { merge: true });
    console.log(`  wrote: ${session.Session_mr}`);
    written++;
  }

  console.log(`\nDone. ${written} written (doc ID = Session_mr).`);
}

main().catch(e => {
  console.error('Fatal:', e.message);
  process.exit(1);
});
