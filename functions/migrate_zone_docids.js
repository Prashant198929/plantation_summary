/**
 * Migrates zone doc IDs from numeric (e.g. "21") to full zone name (e.g. "Zone 21").
 * Also updates the zoneId field in all plantation_records that reference the old zone doc ID.
 *
 * Run from functions/ directory:
 *   $env:GOOGLE_APPLICATION_CREDENTIALS = "C:\GitLab\plantation_summary\android\app\vrukshamojani-4ffd6-eea304e118fb.json"
 *   node migrate_zone_docids.js
 */

const admin = require('firebase-admin');
admin.initializeApp({
  credential: admin.credential.applicationDefault(),
  projectId: 'vrukshamojani-4ffd6',
});
const db = admin.firestore();

async function main() {
  console.log('Fetching all zones...');
  const zonesSnap = await db.collection('zones').get();
  console.log(`Found ${zonesSnap.size} zones.\n`);

  let zoneFixed = 0, zoneSkipped = 0, plantationUpdated = 0;

  for (const zoneDoc of zonesSnap.docs) {
    const zoneName = (zoneDoc.data().name || '').toString().trim();
    const oldId = zoneDoc.id;

    if (!zoneName) {
      console.log(`  SKIP [${oldId}] — no name field`);
      zoneSkipped++;
      continue;
    }

    if (oldId === zoneName) {
      console.log(`  OK   [${oldId}] — already correct`);
      zoneSkipped++;
      continue;
    }

    // Check if target doc already exists
    const targetRef = db.collection('zones').doc(zoneName);
    const targetSnap = await targetRef.get();
    if (targetSnap.exists) {
      console.log(`  SKIP [${oldId}] → [${zoneName}] — target already exists`);
      zoneSkipped++;
      continue;
    }

    // Rename zone doc: create new, delete old
    const batch = db.batch();
    batch.set(targetRef, zoneDoc.data());
    batch.delete(db.collection('zones').doc(oldId));
    await batch.commit();
    console.log(`  ZONE RENAMED [${oldId}] → [${zoneName}]`);
    zoneFixed++;

    // Update all plantation_records that have zoneId == oldId
    const plantsSnap = await db.collection('plantation_records')
      .where('zoneId', '==', oldId)
      .get();

    if (plantsSnap.size > 0) {
      const BATCH_SIZE = 400;
      let i = 0;
      while (i < plantsSnap.docs.length) {
        const chunk = plantsSnap.docs.slice(i, i + BATCH_SIZE);
        const updateBatch = db.batch();
        for (const plant of chunk) {
          updateBatch.update(plant.ref, { zoneId: zoneName });
        }
        await updateBatch.commit();
        i += BATCH_SIZE;
      }
      console.log(`    Updated zoneId in ${plantsSnap.size} plantation_records`);
      plantationUpdated += plantsSnap.size;
    }
  }

  console.log('\n=== Done ===');
  console.log(`  Zones renamed        : ${zoneFixed}`);
  console.log(`  Zones skipped        : ${zoneSkipped}`);
  console.log(`  plantation_records updated: ${plantationUpdated}`);
  process.exit(0);
}

main().catch(e => { console.error('Fatal:', e.message); process.exit(1); });
