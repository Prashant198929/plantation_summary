/**
 * Fixes plantation_records that still have wrong doc IDs (leftover from bad first migration).
 * For each record: if doc ID != {zoneNum}_{plantNumber}, rename it.
 * If the target already exists AND has different data, prints both for manual review.
 *
 * Run from functions/ directory:
 *   $env:GOOGLE_APPLICATION_CREDENTIALS = "..."
 *   node fix_collision_records.js
 */

const admin = require('firebase-admin');
admin.initializeApp({
  credential: admin.credential.applicationDefault(),
  projectId: 'vrukshamojani-4ffd6',
});
const db = admin.firestore();

function correctDocId(zoneName, plantNumber) {
  const match = (zoneName || '').match(/(\d+)/);
  const zoneNum = match ? match[1] : (zoneName || 'unknown');
  return `${zoneNum}_${plantNumber}`;
}

async function main() {
  console.log('Scanning for wrongly-named plantation_records...\n');
  const snap = await db.collection('plantation_records').get();

  let fixed = 0, alreadyCorrect = 0, trueConflict = 0, skipped = 0;

  for (const doc of snap.docs) {
    const data = doc.data();
    const plantNumber = (data.plantNumber || '').toString().trim();
    const zoneName    = (data.zoneName || '').toString().trim();

    if (!plantNumber || !zoneName) {
      console.log(`  SKIP [${doc.id}] — missing plantNumber or zoneName`);
      skipped++;
      continue;
    }

    const targetId = correctDocId(zoneName, plantNumber);
    if (doc.id === targetId) {
      alreadyCorrect++;
      continue;
    }

    // Check if target already exists
    const targetDoc = await db.collection('plantation_records').doc(targetId).get();

    if (targetDoc.exists) {
      const targetData = targetDoc.data();
      // True conflict: target exists with DIFFERENT plant data
      console.log(`  CONFLICT [${doc.id}] → [${targetId}] already exists`);
      console.log(`    Current : zone=${data.zoneName}, plant=${data.plantNumber}, name=${data.plantName}, coords=${data.latitude},${data.longitude}`);
      console.log(`    Target  : zone=${targetData.zoneName}, plant=${targetData.plantNumber}, name=${targetData.plantName}, coords=${targetData.latitude},${targetData.longitude}`);
      trueConflict++;
      continue;
    }

    // Target is empty — safe to rename
    try {
      const batch = db.batch();
      batch.set(db.collection('plantation_records').doc(targetId), data);
      batch.delete(db.collection('plantation_records').doc(doc.id));
      await batch.commit();
      console.log(`  FIXED [${doc.id}] → [${targetId}]  (${zoneName}, plant ${plantNumber})`);
      fixed++;
    } catch (e) {
      console.error(`  ERROR [${doc.id}]: ${e.message}`);
    }
  }

  console.log('\n=== Done ===');
  console.log(`  Fixed          : ${fixed}`);
  console.log(`  Already correct: ${alreadyCorrect}`);
  console.log(`  True conflicts : ${trueConflict} (need manual review)`);
  console.log(`  Skipped        : ${skipped}`);
  process.exit(0);
}

main().catch(e => { console.error('Fatal:', e.message); process.exit(1); });
