/**
 * Migrates old HistoricalData doc IDs (random Firestore auto-IDs) to
 * {invertedMs}_{zoneNum}_{plantNumber} format.
 *
 * Run from functions/ directory:
 *   $env:GOOGLE_APPLICATION_CREDENTIALS = "C:\GitLab\plantation_summary\android\app\vrukshamojani-4ffd6-eea304e118fb.json"
 *   node migrate_historical_docids.js
 */

const admin = require('firebase-admin');
admin.initializeApp({
  credential: admin.credential.applicationDefault(),
  projectId: 'vrukshamojani-4ffd6',
});
const db = admin.firestore();

// New format: starts with 13-digit inverted ms followed by _
function isNewFormat(docId) {
  return /^\d{13}_/.test(docId);
}

function zoneNumFromName(zoneName) {
  const match = (zoneName || '').match(/(\d+)/);
  return match ? match[1] : 'unknown';
}

function newDocId(data, fallbackMs) {
  // Compute inverted ms from stored timestamp
  let ms = fallbackMs;
  for (const field of ['editedAt', 'replacedAt', 'deletedAt', 'timestamp']) {
    const val = data[field];
    if (!val) continue;
    const parsed = typeof val === 'string' ? Date.parse(val) : null;
    if (parsed && !isNaN(parsed)) { ms = parsed; break; }
    if (val && val.toMillis) { ms = val.toMillis(); break; }
  }
  const invertedMs = 9999999999999 - ms;

  // Plant part: use originalId if available, else build from zoneName+plantNumber
  let plantPart;
  if (data.originalId && /^\d+_/.test(data.originalId)) {
    plantPart = data.originalId;
  } else {
    const zoneNum = zoneNumFromName(data.zoneName);
    const plantNum = (data.plantNumber || '').toString().trim();
    plantPart = plantNum ? `${zoneNum}_${plantNum}` : zoneNum;
  }

  return `${invertedMs}_${plantPart}`;
}

async function main() {
  console.log('Fetching all HistoricalData docs...');
  const snap = await db.collection('HistoricalData').get();
  console.log(`Found ${snap.size} docs.\n`);

  let fixed = 0, skipped = 0, errors = 0;
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
    let targetId = newDocId(data, Date.now());

    // Handle collision: append suffix
    let suffix = 0;
    while (usedIds.has(targetId)) {
      suffix++;
      targetId = `${targetId.split('_')[0]}_${suffix}_${targetId.split('_').slice(1).join('_')}`;
    }
    usedIds.add(targetId);

    try {
      const batch = db.batch();
      batch.set(db.collection('HistoricalData').doc(targetId), data);
      batch.delete(db.collection('HistoricalData').doc(doc.id));
      await batch.commit();
      console.log(`  FIXED [${doc.id}] → [${targetId}]`);
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
