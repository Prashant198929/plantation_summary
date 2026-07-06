/**
 * Automated full-dataset migration: processes sevakdb_attendance_full.xlsx
 * in chunks of 100 rows, writing to Firestore with batched writes, verifying
 * one doc per chunk actually landed correctly, and checkpointing progress so
 * the run can be resumed if interrupted. Each chunk is raced against a 30s
 * timeout and retried up to 3x (safe — writes are idempotent) to survive
 * transient hangs (e.g. a stale gRPC connection after many consecutive
 * calls); halts immediately if retries are exhausted or verification fails,
 * rather than plowing ahead or hanging silently.
 *
 * Usage (from functions/ directory):
 *   node batch_migrate_full.js                 # resumes from checkpoint if present, else starts at 0
 *   node batch_migrate_full.js --restart        # ignores checkpoint, starts from row 0
 *   node batch_migrate_full.js --chunk=100      # override chunk size (default 100)
 *   node batch_migrate_full.js --max-chunks=5   # stop after N chunks (for testing)
 */
const { execFileSync } = require('child_process');
const fs = require('fs');
const os = require('os');
const path = require('path');
const admin = require('firebase-admin');
const { MAIN_SERVICE_ACCOUNT, HAJERI_SERVICE_ACCOUNT, buildRecords } = require('./migration_lib');

const args = process.argv.slice(2);
const CHUNK = parseInt((args.find(a => a.startsWith('--chunk='))?.split('=')[1]) || '100', 10);
const MAX_CHUNKS = parseInt((args.find(a => a.startsWith('--max-chunks='))?.split('=')[1]) || '0', 10);
const RESTART = args.includes('--restart');

const CHECKPOINT_PATH = path.join(__dirname, '_migration_checkpoint.json');
const LOG_PATH = path.join(__dirname, 'migration_log.txt');

// Every run (manual or via the daily scheduled task) appends here, so there's
// one persistent record of the whole migration regardless of how it was invoked.
function log(msg) {
  console.log(msg);
  fs.appendFileSync(LOG_PATH, `[${new Date().toISOString()}] ${msg}\n`);
}
function logErr(msg) {
  console.error(msg);
  fs.appendFileSync(LOG_PATH, `[${new Date().toISOString()}] ERROR: ${msg}\n`);
}

function loadCheckpoint() {
  if (RESTART || !fs.existsSync(CHECKPOINT_PATH)) return { nextOffset: 0, usersWritten: 0, attendanceWritten: 0, attendanceSkipped: 0 };
  return JSON.parse(fs.readFileSync(CHECKPOINT_PATH, 'utf8'));
}
function saveCheckpoint(state) {
  fs.writeFileSync(CHECKPOINT_PATH, JSON.stringify(state, null, 2));
}

function fetchAllRows() {
  const outPath = path.join(os.tmpdir(), `sevakdb_excel_full_${Date.now()}.json`);
  log('Dumping full sevakdb_attendance_full.xlsx (this is a one-time read, may take a minute)...');
  execFileSync('python', [
    path.join(__dirname, 'extract_sevakdb_excel.py'),
    '200000', // limit — bigger than the known 110,798 rows, pandas caps at what's available
    '0',
    outPath,
  ], { stdio: 'inherit' });
  const rows = JSON.parse(fs.readFileSync(outPath, 'utf8'));
  fs.unlinkSync(outPath);
  return rows;
}

async function loadExistingUserMap(mainDb) {
  log('Loading existing users/{uid} map for idempotency (one-time read)...');
  const map = new Map(); // uid (string) -> docId
  const snap = await mainDb.collection('users').select('uid').get();
  snap.forEach(doc => {
    const uid = doc.get('uid');
    if (uid !== undefined && uid !== null) map.set(String(uid), doc.id);
  });
  log(`  ${map.size} existing user doc(s) indexed by uid.`);
  return map;
}

const SKIPPED_XLSX_SCRIPT = path.join(__dirname, 'append_skipped_rows.py');

function flushSkippedDetails(details) {
  if (!details.length) return;
  const tmpPath = path.join(os.tmpdir(), `sevakdb_skipped_${Date.now()}.json`);
  fs.writeFileSync(tmpPath, JSON.stringify(details));
  try {
    const out = execFileSync('python', [SKIPPED_XLSX_SCRIPT, tmpPath], { encoding: 'utf8' });
    log(`  ${out.trim()}`);
  } finally {
    fs.unlinkSync(tmpPath);
  }
}

async function processChunk(chunk, mainDb, hajeriDb, userDocIdByUid, offset) {
  const { users, attendanceRecords } = buildRecords(chunk);

  // --- users: batched upsert, assigning new invertedMs_uid doc IDs for new members ---
  const usersBatch = mainDb.batch();
  let newUsers = 0;
  for (const u of users) {
    let docId = userDocIdByUid.get(u.uid);
    if (!docId) {
      docId = `${9999999999999 - Date.now()}_${u.uid}`;
      userDocIdByUid.set(u.uid, docId);
      newUsers++;
    }
    usersBatch.set(mainDb.collection('users').doc(docId), u, { merge: true });
  }
  if (users.length) await usersBatch.commit();

  // --- attendance: check existence first (one round trip), then batch-write only new docs ---
  const attRefs = attendanceRecords.map(r =>
    hajeriDb.collection('Attendance').doc(r.monthKey).collection('records').doc(r.docId));
  const existingDocs = attRefs.length ? await hajeriDb.getAll(...attRefs) : [];
  const attBatch = hajeriDb.batch();
  let written = 0, skipped = 0;
  const newlyWrittenRefs = [];
  const skippedDetails = [];
  attendanceRecords.forEach((r, i) => {
    if (existingDocs[i]?.exists) {
      skipped++;
      skippedDetails.push({
        RowNumber: offset + r.chunkIndex + 1,
        MemberMasterId: r.data.userId,
        Name_en: r.data.name,
        Name_mr: r.data.name_mr,
        AttendanceDate: r.data.date.toISOString().slice(0, 10),
        Zone: r.data.zone,
        Baithak: r.data.baithak,
        MonthKey: r.monthKey,
        DocId: r.docId,
        FirestorePath: `Attendance/${r.monthKey}/records/${r.docId}`,
        Reason: 'Row already existed in Firestore when this run reached it (written by an earlier daily migration run); detected via existence check and skipped',
      });
    } else {
      attBatch.set(attRefs[i], r.data);
      newlyWrittenRefs.push(attRefs[i]);
      written++;
    }
  });
  if (attendanceRecords.length) await attBatch.commit();

  return { newUsers, totalUsers: users.length, written, skipped, skippedDetails, verifyRef: newlyWrittenRefs[0] || attRefs[0] };
}

async function verifyChunk(verifyRef) {
  if (!verifyRef) return true; // empty chunk, nothing to verify
  const snap = await verifyRef.get();
  return snap.exists;
}

// Guards against transient hangs (e.g. a stale gRPC connection after many consecutive
// Firestore calls) — races the real work against a timeout and retries a few times before
// giving up, rather than sitting stuck indefinitely. Safe to retry: user upserts use
// merge:true and attendance writes skip docs that already exist, so redoing a chunk is idempotent.
function withTimeout(promise, ms, label) {
  let timer;
  const timeout = new Promise((_, reject) => {
    timer = setTimeout(() => reject(new Error(`Timed out after ${ms}ms: ${label}`)), ms);
  });
  return Promise.race([promise, timeout]).finally(() => clearTimeout(timer));
}

const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));

// Firestore document IDs here are date-derived and monotonically related
// (invertedDate_uid_zone, walked in ascending date order), which is the
// exact pattern Firestore's own docs warn creates write "hotspots" on a
// single storage range for a brand-new collection until it auto-scales/
// splits — matching the reproducible stall observed right around the
// 20,000-write mark. Backing off and retrying (rather than failing fast)
// gives the backend time to rebalance; each attempt still safely no-ops
// on already-written docs, so retries never duplicate data.
async function processChunkWithRetry(chunk, mainDb, hajeriDb, userDocIdByUid, chunkNum, offset) {
  const DELAYS_MS = [10000, 20000, 40000, 60000, 90000];
  const TIMEOUT_MS = 45000;
  for (let attempt = 1; attempt <= DELAYS_MS.length + 1; attempt++) {
    try {
      return await withTimeout(
        processChunk(chunk, mainDb, hajeriDb, userDocIdByUid, offset),
        TIMEOUT_MS,
        `chunk ${chunkNum} attempt ${attempt}`,
      );
    } catch (e) {
      logErr(`  chunk ${chunkNum} attempt ${attempt}/${DELAYS_MS.length + 1} failed: ${e.message}`);
      if (attempt > DELAYS_MS.length) throw e;
      const delay = DELAYS_MS[attempt - 1];
      logErr(`  backing off ${delay / 1000}s before retrying (likely a write hotspot on new sequential doc IDs, should self-resolve)...`);
      await sleep(delay);
    }
  }
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

  log('=== Migration run started ===');
  const rows = fetchAllRows();
  log(`Loaded ${rows.length} total rows from source.`);

  const userDocIdByUid = await loadExistingUserMap(mainDb);

  let state = loadCheckpoint();
  if (state.nextOffset > 0) {
    log(`Resuming from checkpoint: offset ${state.nextOffset} (${state.usersWritten} users, ${state.attendanceWritten} attendance written so far, ${state.attendanceSkipped} skipped).`);
  }

  const totalChunks = Math.ceil(rows.length / CHUNK);
  let chunkNum = Math.floor(state.nextOffset / CHUNK);

  for (let offset = state.nextOffset; offset < rows.length; offset += CHUNK) {
    chunkNum++;
    if (MAX_CHUNKS && chunkNum - Math.floor(state.nextOffset / CHUNK) > MAX_CHUNKS) {
      log(`Reached --max-chunks=${MAX_CHUNKS} limit, stopping (this is a manual test cap, not an error).`);
      break;
    }

    const chunk = rows.slice(offset, offset + CHUNK);
    const { newUsers, totalUsers, written, skipped, skippedDetails, verifyRef } = await processChunkWithRetry(chunk, mainDb, hajeriDb, userDocIdByUid, chunkNum, offset);
    const verified = await verifyChunk(verifyRef);

    state.usersWritten += newUsers;
    state.attendanceWritten += written;
    state.attendanceSkipped += skipped;
    flushSkippedDetails(skippedDetails);

    log(
      `[${chunkNum}/${totalChunks}] rows ${offset + 1}-${offset + chunk.length}: ` +
      `${totalUsers} users (${newUsers} new), ${written} attendance written, ${skipped} skipped-existing — ` +
      `${verified ? 'verified OK' : 'VERIFICATION FAILED'}`
    );

    if (!verified) {
      logErr(`HALTING at offset ${offset} — verification failed for a doc in this chunk. No further chunks processed.`);
      logErr('Checkpoint saved at the last successfully verified chunk; re-run to retry from there once investigated.');
      process.exit(1);
    }

    state.nextOffset = offset + CHUNK;
    saveCheckpoint(state);
  }

  log(`Done this run. Totals so far: ${state.usersWritten} new users, ${state.attendanceWritten} attendance written, ${state.attendanceSkipped} attendance skipped (already existed).`);
  if (state.nextOffset >= rows.length) {
    log('Full dataset migrated.');
  }
  log('=== Migration run ended ===\n');
}

main().catch(e => {
  logErr(`Fatal: ${e.message}`);
  console.error(e.stack);
  log('=== Migration run ended (fatal error) ===\n');
  process.exit(1);
});
