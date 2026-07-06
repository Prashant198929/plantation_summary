/**
 * Migrates users doc IDs to {invertedMs}_{authUid} format.
 * New format: e.g. 8249876543210_abc123def456uid
 *
 * Run from functions/ directory:
 *   $env:GOOGLE_APPLICATION_CREDENTIALS = "C:\GitLab\plantation_summary\android\app\vrukshamojani-4ffd6-eea304e118fb.json"
 *   node migrate_user_docids.js
 */

const admin = require('firebase-admin');
admin.initializeApp({
  credential: admin.credential.applicationDefault(),
  projectId: 'vrukshamojani-4ffd6',
});
const db = admin.firestore();

// New format: 13-digit invertedMs _ authUid
function isNewFormat(docId) {
  return /^\d{13}_/.test(docId);
}

async function main() {
  console.log('Fetching all users...');
  const snap = await db.collection('users').get();
  console.log(`Found ${snap.size} users.\n`);

  let fixed = 0, skipped = 0, errors = 0, noUid = 0;
  const usedIds = new Set();

  // Pre-collect already correct IDs
  for (const doc of snap.docs) {
    if (isNewFormat(doc.id)) usedIds.add(doc.id);
  }

  for (const doc of snap.docs) {
    if (isNewFormat(doc.id)) {
      skipped++;
      continue;
    }

    const data = doc.data();
    let authUid = data.uid;

    if (!authUid) {
      // Look up Firebase Auth UID by email
      if (data.email) {
        try {
          const userRecord = await admin.auth().getUserByEmail(data.email);
          authUid = userRecord.uid;
          console.log(`  FOUND uid for [${doc.id}] via email (${data.email}) → ${authUid}`);
        } catch (e) {
          console.log(`  SKIP [${doc.id}] — email not found in Auth (${data.email})`);
          noUid++;
          continue;
        }
      } else {
        console.log(`  SKIP [${doc.id}] — no uid or email field (name=${data.name}, mobile=${data.mobile})`);
        noUid++;
        continue;
      }
    }

    // Compute invertedMs from createdAt field
    let invertedMs;
    if (data.createdAt && data.createdAt.toMillis) {
      invertedMs = 9999999999999 - data.createdAt.toMillis();
    } else {
      // Fallback: use current time (ordering won't be perfect but ID is correct)
      invertedMs = 9999999999999 - Date.now();
    }

    let newId = `${invertedMs}_${authUid}`;

    // Handle collision
    let suffix = 0;
    while (usedIds.has(newId)) {
      suffix++;
      newId = `${invertedMs - suffix}_${authUid}`;
    }
    usedIds.add(newId);

    try {
      const batch = db.batch();
      batch.set(db.collection('users').doc(newId), data);
      batch.delete(db.collection('users').doc(doc.id));
      await batch.commit();
      console.log(`  FIXED [${doc.id}] → [${newId}]  (${data.name} ${data.surname || ''}, mobile=${data.mobile})`);
      fixed++;
    } catch (e) {
      console.error(`  ERROR [${doc.id}]: ${e.message}`);
      errors++;
    }
  }

  console.log('\n=== Done ===');
  console.log(`  Fixed  : ${fixed}`);
  console.log(`  Skipped: ${skipped} (already correct format)`);
  console.log(`  No uid : ${noUid} (review manually)`);
  console.log(`  Errors : ${errors}`);
  process.exit(0);
}

main().catch(e => { console.error('Fatal:', e.message); process.exit(1); });
