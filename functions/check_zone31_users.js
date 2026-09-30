/**
 * Read-only, scoped check (where-filtered, not a full collection scan) of
 * every Shree_Sadasya user in Zone 31, to see how many share the
 * "आजदेपाडा" baithak_mr spelling that doesn't match BaithakSessions' Hall_mr
 * ("आजदेपदा").
 *
 * Usage (from functions/ directory):
 *   node check_zone31_users.js
 */
const { MAIN_SERVICE_ACCOUNT } = require('./migration_lib');

async function main() {
  const admin = require('firebase-admin');
  const app = admin.initializeApp(
    { credential: admin.credential.cert(require(MAIN_SERVICE_ACCOUNT)), projectId: 'vrukshamojani-4ffd6' },
    'check-zone31-users',
  );
  const db = app.firestore();

  const snap = await db.collection('Shree_Sadasya').where('zone_mr', '==', 'झोन 31').get();
  console.log(`Zone 31 users found: ${snap.size}`);

  const byBaithakMr = new Map();
  snap.docs.forEach(d => {
    const data = d.data();
    const key = (data.baithak_mr || '<blank>').toString();
    if (!byBaithakMr.has(key)) byBaithakMr.set(key, []);
    byBaithakMr.get(key).push({ id: d.id, name: data.name || data.name_mr || '' });
  });

  console.log(`\nDistinct baithak_mr values in Zone 31: ${byBaithakMr.size}`);
  [...byBaithakMr.entries()].forEach(([baithakMr, users]) => {
    console.log(`\n"${baithakMr}" -> ${users.length} user(s)`);
    users.slice(0, 10).forEach(u => console.log(`   ${u.id}  ${u.name}`));
    if (users.length > 10) console.log(`   ... and ${users.length - 10} more`);
  });
}

main().catch(e => {
  console.error('Fatal:', e.message);
  process.exit(1);
});
