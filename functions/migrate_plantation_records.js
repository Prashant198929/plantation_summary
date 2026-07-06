/**
 * Migration: rename plantation_records doc IDs to {zoneNum}_{plantNumber}
 *
 * Old format: e.g. "123_88_2026-06-30T10:30:00.000" or random Firestore IDs
 * New format: e.g. "88_123"
 *
 * Run from functions/ directory:
 *   $env:GOOGLE_APPLICATION_CREDENTIALS = "C:\Users\psawarwadkar\Downloads\vrukshamojani-4ffd6-eea304e118fb.json"
 *   node migrate_plantation_records.js
 *
 * Safe to re-run — skips docs already in correct format.
 */

const admin = require('firebase-admin');

admin.initializeApp({
  credential: admin.credential.applicationDefault(),
  projectId: 'vrukshamojani-4ffd6',
});

const db = admin.firestore();

function newDocId(zoneName, plantNumber) {
  const match = (zoneName || '').match(/(\d+)/);
  const zoneNum = match ? match[1] : (zoneName || 'unknown');
  return `${zoneNum}_${plantNumber}`;
}

async function main() {
  console.log('Fetching all plantation_records...');
  const snap = await db.collection('plantation_records').get();
  console.log(`Found ${snap.size} records.\n`);

  let skipped = 0, migrated = 0, errors = 0, collisions = 0;

  for (const doc of snap.docs) {
    const data = doc.data();
    const plantNumber = (data.plantNumber || '').toString().trim();
    const zoneName    = (data.zoneName || '').toString().trim();

    if (!plantNumber || !zoneName) {
      console.log(`  SKIP [${doc.id}] — missing plantNumber or zoneName`);
      skipped++;
      continue;
    }

    const targetId = newDocId(zoneName, plantNumber);

    if (doc.id === targetId) {
      skipped++;
      continue;
    }

    // Check for collision before writing
    const existing = await db.collection('plantation_records').doc(targetId).get();
    if (existing.exists) {
      console.log(`  COLLISION [${doc.id}] → [${targetId}] already exists — skipping`);
      collisions++;
      continue;
    }

    try {
      const batch = db.batch();
      batch.set(db.collection('plantation_records').doc(targetId), data);
      batch.delete(db.collection('plantation_records').doc(doc.id));
      await batch.commit();
      console.log(`  MIGRATED [${doc.id}] → [${targetId}]`);
      migrated++;
    } catch (e) {
      console.error(`  ERROR [${doc.id}]: ${e.message}`);
      errors++;
    }
  }

  console.log('\n=== Migration complete ===');
  console.log(`  Migrated : ${migrated}`);
  console.log(`  Skipped  : ${skipped} (already correct format)`);
  console.log(`  Collisions: ${collisions} (target ID already existed — review manually)`);
  console.log(`  Errors   : ${errors}`);

  if (collisions > 0) {
    console.log('\nCollisions mean two plants share the same zoneId + plantNumber.');
    console.log('Check plantation_records in Firebase console for duplicates.');
  }

  process.exit(0);
}

main().catch(err => {
  console.error('Fatal:', err.message);
  process.exit(1);
});
