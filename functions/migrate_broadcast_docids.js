/**
 * Migrates old broadcast doc IDs (which contained phone numbers) to
 * inverted-timestamp format (e.g. 9999999998576) so phone numbers are
 * no longer visible in Firebase console doc IDs.
 *
 * Run from functions/ directory:
 *   $env:GOOGLE_APPLICATION_CREDENTIALS = "C:\GitLab\plantation_summary\android\app\vrukshamojani-4ffd6-eea304e118fb.json"
 *   node migrate_broadcast_docids.js
 */

const admin = require('firebase-admin');
admin.initializeApp({
  credential: admin.credential.applicationDefault(),
  projectId: 'vrukshamojani-4ffd6',
});
const db = admin.firestore();

// New format: pure 13-digit inverted timestamp
function isNewFormat(docId) {
  return /^\d{13}$/.test(docId);
}

async function main() {
  console.log('Fetching all broadcasts...');
  const snap = await db.collection('broadcasts').get();
  console.log(`Found ${snap.size} broadcasts.\n`);

  let fixed = 0, skipped = 0, errors = 0;
  const usedIds = new Set();

  // Pre-collect already correct IDs so we don't collide with them
  for (const doc of snap.docs) {
    if (isNewFormat(doc.id)) usedIds.add(doc.id);
  }

  for (const doc of snap.docs) {
    if (isNewFormat(doc.id)) {
      skipped++;
      continue;
    }

    const data = doc.data();

    // Compute new doc ID from sentAt timestamp; fallback to createdAt or now
    let sentMs;
    if (data.sentAt && data.sentAt.toMillis) {
      sentMs = data.sentAt.toMillis();
    } else if (data.createdAt && data.createdAt.toMillis) {
      sentMs = data.createdAt.toMillis();
    } else {
      sentMs = Date.now();
    }

    let newId = (9999999999999 - sentMs).toString();

    // Handle collision: append suffix until unique
    let suffix = 0;
    while (usedIds.has(newId)) {
      suffix++;
      newId = `${9999999999999 - sentMs}_${suffix}`;
    }
    usedIds.add(newId);

    try {
      const batch = db.batch();
      batch.set(db.collection('broadcasts').doc(newId), data);
      batch.delete(db.collection('broadcasts').doc(doc.id));
      await batch.commit();
      console.log(`  FIXED [${doc.id}] → [${newId}]`);
      fixed++;
    } catch (e) {
      console.error(`  ERROR [${doc.id}]: ${e.message}`);
      errors++;
    }
  }

  console.log('\n=== Done ===');
  console.log(`  Fixed  : ${fixed}`);
  console.log(`  Skipped: ${skipped} (already correct format)`);
  console.log(`  Errors : ${errors}`);
  process.exit(0);
}

main().catch(e => { console.error('Fatal:', e.message); process.exit(1); });
