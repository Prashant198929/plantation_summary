/**
 * One-time backfill: tallies each user's total historical attendance count
 * from hajeri-465b7's Attendance/{month}/records (field 'userId') and writes
 * it onto vrukshamojani-4ffd6's Shree_Sadasya/{docId}.attendanceCount.
 *
 * This replaces the app's per-load collectionGroup scan (previously run by
 * AttendanceSupport.fetchAttendanceCounts on every hall/zone switch, taking
 * up to ~20s) with a plain field read — the app now sorts by
 * Shree_Sadasya.attendanceCount directly (already present in the cached
 * user list) instead of re-scanning attendance history every time. Going
 * forward, the app increments/decrements this field at mark/unmark time
 * (see _markUserAttendance / _removeAlreadyMarkedAttendance in
 * attendance_page.dart), so this script only needs to run to completion
 * once to seed existing history.
 *
 * CHECKPOINTED ACROSS RUNS: the full record scan is ~111k reads, which by
 * itself exceeds Firestore Spark's ~50k-reads/day cap in a single run (hit
 * RESOURCE_EXHAUSTED on 2026-09-04 trying it in one shot). Rather than a
 * single collectionGroup('records') query, this processes one Attendance
 * month doc's 'records' subcollection at a time (a plain query per month —
 * listDocuments() to discover month IDs is metadata-only and doesn't count
 * against the read quota), stopping once this run's read budget is spent and
 * saving progress after every month. Mirrors batch_migrate_full.js's
 * checkpoint/resume convention (see migration_log.txt / _migration_checkpoint.json
 * for that unrelated migration's use of the same pattern).
 *
 * Usage (from functions/ directory):
 *   node backfill_attendance_counts.js                # resume (or start) tallying months; dry-runs the Shree_Sadasya diff once all months are read
 *   node backfill_attendance_counts.js --commit        # same, but writes the diff once all months are read
 *   node backfill_attendance_counts.js --budget=40000  # override this run's record-read budget (default 40000, safely under the ~50k/day cap)
 *   node backfill_attendance_counts.js --restart       # ignore checkpoint, re-tally every month from scratch
 */

const fs = require('fs');
const path = require('path');
const { MAIN_SERVICE_ACCOUNT, HAJERI_SERVICE_ACCOUNT } = require('./migration_lib');

const args = process.argv.slice(2);
const COMMIT = args.includes('--commit');
const RESTART = args.includes('--restart');
const BUDGET = parseInt((args.find(a => a.startsWith('--budget='))?.split('=')[1]) || '40000', 10);
const BATCH_SIZE = 500;

const CHECKPOINT_PATH = path.join(__dirname, '_backfill_attendance_counts_checkpoint.json');

function loadCheckpoint() {
  if (RESTART || !fs.existsSync(CHECKPOINT_PATH)) {
    return { processedMonths: [], counts: {}, recordsProcessed: 0, monthsDone: false };
  }
  return JSON.parse(fs.readFileSync(CHECKPOINT_PATH, 'utf8'));
}
function saveCheckpoint(state) {
  fs.writeFileSync(CHECKPOINT_PATH, JSON.stringify(state, null, 2));
}

async function main() {
  const admin = require('firebase-admin');

  const hajeriApp = admin.initializeApp(
    { credential: admin.credential.cert(require(HAJERI_SERVICE_ACCOUNT)), projectId: 'hajeri-465b7' },
    'hajeri-backfill',
  );
  const mainApp = admin.initializeApp(
    { credential: admin.credential.cert(require(MAIN_SERVICE_ACCOUNT)), projectId: 'vrukshamojani-4ffd6' },
    'main-backfill',
  );
  const hajeriDb = hajeriApp.firestore();
  const mainDb = mainApp.firestore();

  const state = loadCheckpoint();

  if (!state.monthsDone) {
    const monthRefs = await hajeriDb.collection('Attendance').listDocuments();
    const allMonths = monthRefs.map(r => r.id);
    const remaining = allMonths.filter(m => !state.processedMonths.includes(m));

    if (state.processedMonths.length === 0) {
      console.log(`Found ${allMonths.length} Attendance month doc(s) total.`);
    } else {
      console.log(
        `Resuming: ${state.processedMonths.length}/${allMonths.length} month(s) already processed ` +
        `(${state.recordsProcessed} record(s) tallied so far, ${Object.keys(state.counts).length} distinct user(s)).`,
      );
    }

    let budgetLeft = BUDGET;
    for (const monthKey of remaining) {
      if (budgetLeft <= 0) break;
      const snap = await hajeriDb
        .collection('Attendance')
        .doc(monthKey)
        .collection('records')
        .select('userId')
        .get();
      snap.docs.forEach(doc => {
        const userId = (doc.get('userId') || '').toString();
        if (!userId) return;
        state.counts[userId] = (state.counts[userId] || 0) + 1;
      });
      state.processedMonths.push(monthKey);
      state.recordsProcessed += snap.size;
      budgetLeft -= snap.size;
      console.log(
        `  [${monthKey}] ${snap.size} record(s) — running total ${state.recordsProcessed}, ` +
        `${Object.keys(state.counts).length} distinct user(s) so far.`,
      );
      saveCheckpoint(state);
    }

    const stillRemaining = allMonths.filter(m => !state.processedMonths.includes(m));
    if (stillRemaining.length > 0) {
      console.log(`\nRead budget spent for this run. ${stillRemaining.length} month(s) still pending: ${stillRemaining.join(', ')}`);
      console.log('Re-run this same command (no flags needed) once quota resets to continue — it resumes automatically.');
      return;
    }
    state.monthsDone = true;
    saveCheckpoint(state);
    console.log(`\nAll ${allMonths.length} month(s) processed. Total ${state.recordsProcessed} record(s), ${Object.keys(state.counts).length} distinct user(s).`);
  }

  // --- Shree_Sadasya diff + write (small — well within a single run's quota) ---
  console.log("\nDiffing against 'Shree_Sadasya'...");
  const usersSnap = await mainDb.collection('Shree_Sadasya').select('uid', 'attendanceCount').get();
  console.log(`Fetched ${usersSnap.size} doc(s) from 'Shree_Sadasya'.`);

  const updates = [];
  usersSnap.docs.forEach(doc => {
    const uid = (doc.get('uid') || doc.id || '').toString();
    const newCount = state.counts[uid] || 0;
    const existing = doc.get('attendanceCount');
    if (existing === newCount) return; // already correct, nothing to write
    updates.push({ docId: doc.id, uid, from: existing ?? '(none)', to: newCount });
  });

  console.log(`\n${updates.length} of ${usersSnap.size} Shree_Sadasya doc(s) need an attendanceCount update.`);
  console.log('\nSample of first 10:');
  updates.slice(0, 10).forEach(u => {
    console.log(`  Shree_Sadasya/${u.docId} (uid=${u.uid}) attendanceCount: ${u.from} -> ${u.to}`);
  });

  if (!COMMIT) {
    console.log('\nDry run only — no writes made. Re-run with --commit to write to Firestore.');
    return;
  }

  let written = 0;
  for (let i = 0; i < updates.length; i += BATCH_SIZE) {
    const batch = mainDb.batch();
    const chunk = updates.slice(i, i + BATCH_SIZE);
    chunk.forEach(u => {
      batch.set(
        mainDb.collection('Shree_Sadasya').doc(u.docId),
        { attendanceCount: u.to },
        { merge: true },
      );
    });
    await batch.commit();
    written += chunk.length;
    console.log(`  committed ${written}/${updates.length}`);
  }
  console.log(`\nDone. Updated attendanceCount on ${written} Shree_Sadasya doc(s).`);
}

main().catch(e => {
  console.error('Fatal:', e.message);
  process.exit(1);
});
