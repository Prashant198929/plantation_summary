/**
 * One-off diagnostic: how much Firestore storage headroom is left on the
 * Spark (free) plan for vrukshamojani-4ffd6 (users) and hajeri-465b7
 * (attendance), and how many more docs of the current average size would fit.
 * Not part of the migration pipeline — delete after use.
 */
const admin = require('firebase-admin');
const { MAIN_SERVICE_ACCOUNT, HAJERI_SERVICE_ACCOUNT } = require('./migration_lib');

const SPARK_STORAGE_BYTES = 1 * 1024 * 1024 * 1024; // 1 GiB free tier cap
const SPARK_DAILY_WRITES = 20000;
const SPARK_DAILY_READS = 50000;

async function collectionStats(db, collectionRef, label) {
  const countSnap = await collectionRef.count().get();
  const count = countSnap.data().count;
  const sample = await collectionRef.limit(50).get();
  let bytes = 0;
  sample.forEach(d => {
    // Rough proxy for Firestore's stored size (field names + values), not
    // exact (Firestore also charges ~32B/doc overhead + per-field index
    // entries by default), but good enough for an order-of-magnitude estimate.
    bytes += Buffer.byteLength(JSON.stringify(d.data()), 'utf8') + 32;
  });
  const avgBytes = sample.size ? bytes / sample.size : 0;
  return { label, count, avgBytes, sampledDocs: sample.size };
}

async function main() {
  const mainApp = admin.initializeApp(
    { credential: admin.credential.cert(require(MAIN_SERVICE_ACCOUNT)), projectId: 'vrukshamojani-4ffd6' },
    'main',
  );
  const hajeriApp = admin.initializeApp(
    { credential: admin.credential.cert(require(HAJERI_SERVICE_ACCOUNT)), projectId: 'hajeri-465b7' },
    'hajeri',
  );
  const mainDb = mainApp.firestore();
  const hajeriDb = hajeriApp.firestore();

  const usersStats = await collectionStats(mainDb, mainDb.collection('users'), 'vrukshamojani-4ffd6:users');
  const attStats = await collectionStats(hajeriDb, hajeriDb.collectionGroup('records'), 'hajeri-465b7:Attendance/*/records');

  for (const stats of [usersStats, attStats]) {
    const usedBytes = stats.count * stats.avgBytes;
    const remainingBytes = Math.max(0, SPARK_STORAGE_BYTES - usedBytes);
    const remainingDocsAtAvgSize = stats.avgBytes > 0 ? Math.floor(remainingBytes / stats.avgBytes) : null;
    console.log(`\n=== ${stats.label} ===`);
    console.log(`  doc count: ${stats.count}`);
    console.log(`  avg doc size (sampled ${stats.sampledDocs}): ${stats.avgBytes.toFixed(0)} bytes`);
    console.log(`  estimated storage used: ${(usedBytes / 1024 / 1024).toFixed(2)} MiB of 1024 MiB free tier`);
    console.log(`  estimated storage remaining: ${(remainingBytes / 1024 / 1024).toFixed(2)} MiB`);
    console.log(`  estimated additional docs that fit at this avg size: ~${remainingDocsAtAvgSize}`);
  }

  console.log(`\nDaily write quota (Spark): ${SPARK_DAILY_WRITES}/day per project (resets daily, not cumulative).`);
  console.log(`Daily read quota (Spark): ${SPARK_DAILY_READS}/day per project.`);

  await mainApp.delete();
  await hajeriApp.delete();
}

main().catch(e => { console.error('Fatal:', e.message); console.error(e.stack); process.exit(1); });
