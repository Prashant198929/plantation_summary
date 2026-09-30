/**
 * Grants attendance page access to every login user in sevakdb.dbo.Users by
 * setting attendance_viewer=true on their matching Firestore doc in
 * vrukshamojani-4ffd6's 'users' collection.
 *
 * sevakdb.dbo.Users is the small (41-row) table of app login accounts (zone
 * coordinators etc.) — distinct from MemberMaster/the 110k-row attendance
 * migration. Matched here by case-insensitive/trimmed Name against
 * Firestore's 'name' field. (Mobile was tried first but many migrated docs
 * share the same mobile number, matching far more docs than intended; a
 * plain exact-string name match was tried next but missed real matches over
 * case/spacing differences — e.g. sevakdb's ALL CAPS vs Firestore's mixed
 * case. The 'users' collection is only ~2,700 docs, small enough to fetch
 * in full and compare normalized names in JS.)
 *
 * Usage (from functions/ directory):
 *   node set_attendance_viewer_sevakdb_users.js            # dry run
 *   node set_attendance_viewer_sevakdb_users.js --commit   # writes to Firestore
 */

const { execFileSync } = require('child_process');
const { MAIN_SERVICE_ACCOUNT } = require('./migration_lib');

const COMMIT = process.argv.includes('--commit');

// First confirmed batch: the 25 sevakdb UserIds with a single, unambiguous
// Firestore match (no duplicate docs, no zone conflict, no multi-candidate
// ambiguity). The other 11 (duplicates/zone mismatches/ambiguous picks) and
// 3 no-match users are handled separately once reviewed.
const CLEAN_USER_IDS = new Set([
  5, 6, 7, 9, 11, 13, 15, 20, 24, 29, 31, 38, 40, 41, // exact tier, clean
  14, 16, 21, 26, 28, 32, 37, 42,                     // fuzzy tier, clean
  27, 30, 36,                                          // zone+first-name tier, clean (single candidate)
]);

function sqlcmdJson(query) {
  const out = execFileSync('docker', [
    'exec', 'sqlserver',
    '/opt/mssql-tools18/bin/sqlcmd',
    '-S', 'localhost', '-U', 'sa', '-P', 'YourPass@123', '-C',
    '-d', 'sevakdb', '-y', '0', '-w', '65535',
    '-Q', query,
  ], { encoding: 'utf8' });
  // sqlcmd chunks long FOR JSON PATH output across multiple lines (no field
  // in this table legitimately contains a newline), so strip line breaks
  // before parsing to undo that chunking.
  return JSON.parse(out.replace(/[\r\n]/g, ''));
}

function fetchSevakdbUsers() {
  return sqlcmdJson('SET NOCOUNT ON; SELECT UserId, Name, EmailId, Contact, ZoneId, IsUserActive FROM Users ORDER BY UserId FOR JSON PATH;');
}

function fetchZoneMap() {
  const rows = sqlcmdJson('SET NOCOUNT ON; SELECT ZoneMasterId, ZoneName_en FROM ZoneMaster FOR JSON PATH;');
  const map = new Map();
  rows.forEach(r => map.set(String(r.ZoneMasterId), r.ZoneName_en));
  return map;
}

// sevakdb Names sometimes carry an honorific prefix (Shri/Shree/Smt/Sau/Kum)
// that Firestore's app-entered 'name' field usually omits, which breaks
// both the exact and first+last token matches.
const HONORIFICS = new Set(['shri', 'shree', 'shri.', 'shree.', 'smt', 'smt.', 'sau', 'sau.', 'kum', 'kum.', 'mr', 'mr.', 'mrs', 'mrs.']);
function stripHonorific(tokens) {
  return tokens[0] && HONORIFICS.has(tokens[0]) ? tokens.slice(1) : tokens;
}

async function main() {
  const rows = fetchSevakdbUsers();
  console.log(`Fetched ${rows.length} row(s) from sevakdb.dbo.Users.`);
  const zoneMap = fetchZoneMap();

  const active = rows.filter(r => r.IsUserActive === true);
  const inactiveOrNull = rows.filter(r => r.IsUserActive !== true);
  if (inactiveOrNull.length) {
    console.log(`\n${inactiveOrNull.length} row(s) have IsUserActive NOT true (skipped):`);
    inactiveOrNull.forEach(r => console.log(`  UserId=${r.UserId} ${r.Name} (${r.EmailId}) IsUserActive=${r.IsUserActive}`));
  }

  const admin = require('firebase-admin');
  const mainApp = admin.initializeApp(
    { credential: admin.credential.cert(require(MAIN_SERVICE_ACCOUNT)), projectId: 'vrukshamojani-4ffd6' },
    'main',
  );
  const db = mainApp.firestore();

  const tokenize = s => stripHonorific((s || '').trim().toLowerCase().replace(/\s+/g, ' ').split(' ').filter(Boolean));
  const normalize = s => tokenize(s).join(' ');
  const zoneNamesFor = r => new Set(String(r.ZoneId || '').split(',').map(z => zoneMap.get(z.trim())).filter(Boolean));

  const allDocs = await db.collection('users').select('name', 'mobile', 'zone', 'attendance_viewer').get();
  const byNormalizedName = new Map();
  const byFirstLast = new Map();
  const byZone = new Map();
  allDocs.forEach(doc => {
    const tokens = tokenize(doc.get('name'));
    if (tokens.length) {
      const key = tokens.join(' ');
      if (!byNormalizedName.has(key)) byNormalizedName.set(key, []);
      byNormalizedName.get(key).push(doc);
    }
    if (tokens.length >= 2) {
      const flKey = `${tokens[0]}|${tokens[tokens.length - 1]}`;
      if (!byFirstLast.has(flKey)) byFirstLast.set(flKey, []);
      byFirstLast.get(flKey).push(doc);
    }
    const zone = doc.get('zone');
    if (zone) {
      if (!byZone.has(zone)) byZone.set(zone, []);
      byZone.get(zone).push(doc);
    }
  });
  console.log(`\nFetched ${allDocs.size} Firestore user doc(s) for in-memory name/zone matching.`);

  const withZoneInfo = (m, r) => ({ ...m, zoneMatch: zoneNamesFor(r).has(m.docZone) });

  const toResult = (r, doc) => ({
    sevakdbUser: r,
    docId: doc.id,
    docName: doc.get('name'),
    docMobile: doc.get('mobile'),
    docZone: doc.get('zone'),
    alreadyTrue: doc.get('attendance_viewer') === true,
  });

  const matched = [];
  const fuzzyMatched = [];
  const zoneMatched = [];
  const unmatched = [];
  for (const r of active) {
    const tokens = tokenize(r.Name);
    const key = tokens.join(' ');
    const docs = key ? byNormalizedName.get(key) : undefined;
    if (docs && docs.length) {
      docs.forEach(doc => matched.push(withZoneInfo(toResult(r, doc), r)));
      continue;
    }
    const flKey = tokens.length >= 2 ? `${tokens[0]}|${tokens[tokens.length - 1]}` : null;
    const fuzzyDocs = flKey ? byFirstLast.get(flKey) : undefined;
    if (fuzzyDocs && fuzzyDocs.length) {
      fuzzyDocs.forEach(doc => fuzzyMatched.push(withZoneInfo(toResult(r, doc), r)));
      continue;
    }
    // Last resort: same zone + first name token matches — flagged lower
    // confidence since zone+first-name alone doesn't guarantee one person.
    const zoneNames = zoneNamesFor(r);
    if (tokens.length && zoneNames.size) {
      const candidates = [...zoneNames].flatMap(z => byZone.get(z) || []);
      const firstTok = tokens[0];
      const zoneHits = candidates.filter(doc => tokenize(doc.get('name'))[0] === firstTok);
      if (zoneHits.length) {
        zoneHits.forEach(doc => zoneMatched.push(withZoneInfo(toResult(r, doc), r)));
        continue;
      }
    }
    unmatched.push(r);
  }

  console.log(`\n=== ${matched.length} exact-name matching Firestore user doc(s) found ===`);
  matched.forEach(m => console.log(`  users/${m.docId}  name="${m.docName}" zone=${m.docZone}${m.zoneMatch ? '' : ' [ZONE MISMATCH]'}  <-  UserId=${m.sevakdbUser.UserId} ${m.sevakdbUser.Name} (${m.sevakdbUser.EmailId})${m.alreadyTrue ? '  [already true]' : ''}`));

  if (fuzzyMatched.length) {
    console.log(`\n=== ${fuzzyMatched.length} FUZZY match(es) (first+last name only, middle name/honorific dropped — review before trusting) ===`);
    fuzzyMatched.forEach(m => console.log(`  users/${m.docId}  name="${m.docName}" zone=${m.docZone}${m.zoneMatch ? ' [zone confirms]' : ' [ZONE MISMATCH]'}  <-  UserId=${m.sevakdbUser.UserId} ${m.sevakdbUser.Name} (${m.sevakdbUser.EmailId})${m.alreadyTrue ? '  [already true]' : ''}`));
  }

  if (zoneMatched.length) {
    console.log(`\n=== ${zoneMatched.length} ZONE+FIRST-NAME match(es) (lowest confidence — last name didn't match at all, review carefully) ===`);
    zoneMatched.forEach(m => console.log(`  users/${m.docId}  name="${m.docName}" zone=${m.docZone}  <-  UserId=${m.sevakdbUser.UserId} ${m.sevakdbUser.Name} (${m.sevakdbUser.EmailId})${m.alreadyTrue ? '  [already true]' : ''}`));
  }

  if (unmatched.length) {
    console.log(`\n=== ${unmatched.length} sevakdb user(s) with NO matching Firestore doc at all (skipped) ===`);
    unmatched.forEach(r => console.log(`  UserId=${r.UserId} ${r.Name} (${r.EmailId}) ZoneId=${r.ZoneId}`));
  }

  const cleanCandidates = [...matched, ...fuzzyMatched, ...zoneMatched].filter(m => CLEAN_USER_IDS.has(m.sevakdbUser.UserId));
  const toWrite = cleanCandidates.filter(m => !m.alreadyTrue);
  console.log(`\n=== This run targets ${CLEAN_USER_IDS.size} confirmed-clean sevakdb UserId(s): ${cleanCandidates.length} Firestore doc(s) matched, ${toWrite.length} need attendance_viewer set to true (${cleanCandidates.length - toWrite.length} already true) ===`);
  toWrite.forEach(m => console.log(`  users/${m.docId}  <-  UserId=${m.sevakdbUser.UserId} ${m.sevakdbUser.Name}`));

  if (!COMMIT) {
    console.log('\nDry run only — no writes made. Re-run with --commit to write to Firestore.');
    return;
  }

  let written = 0;
  for (const m of toWrite) {
    await db.collection('users').doc(m.docId).update({ attendance_viewer: true });
    console.log(`  updated users/${m.docId}`);
    written++;
  }
  console.log(`\nDone. ${written} doc(s) updated.`);
}

main().catch(e => {
  console.error('Fatal:', e.message);
  process.exit(1);
});
