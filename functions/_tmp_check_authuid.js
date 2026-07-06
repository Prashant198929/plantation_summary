const admin = require('firebase-admin');
const serviceAccount = require('C:/GitLab/plantation_summary/android/app/vrukshamojani-4ffd6-eea304e118fb.json');
admin.initializeApp({ credential: admin.credential.cert(serviceAccount), projectId: 'vrukshamojani-4ffd6' });
const db = admin.firestore();

async function main() {
  const snap = await db.collection('users').orderBy('uid').get();
  for (const doc of snap.docs) {
    const d = doc.data();
    let authStatus;
    if (d.authUid) {
      authStatus = `authUid="${d.authUid}"`;
    } else if (d.email) {
      try {
        const rec = await admin.auth().getUserByEmail(d.email);
        authStatus = `NO authUid, but email lookup works -> ${rec.uid}`;
      } catch (e) {
        authStatus = `NO authUid, email lookup FAILED (${e.code})`;
      }
    } else {
      authStatus = 'NO authUid AND no email — cannot delete Auth account';
    }
    console.log(`uid=${d.uid}  name="${d.name}"  ${authStatus}`);
  }
  process.exit(0);
}
main().catch((e) => { console.error('Fatal:', e.message); process.exit(1); });
