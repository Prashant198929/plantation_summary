/**
 * Shared logic for sevakdb -> Firebase attendance migration, used by both
 * migrate_sevakdb_attendance.js (manual single-batch CLI) and
 * batch_migrate_full.js (automated full-dataset runner).
 */
const crypto = require('crypto');

const MAIN_SERVICE_ACCOUNT = 'C:/GitLab/plantation_summary/android/app/vrukshamojani-4ffd6-eea304e118fb.json';
const HAJERI_SERVICE_ACCOUNT = 'C:/Users/psawarwadkar/Downloads/hajeri-465b7-firebase-adminsdk-fbsvc-df192818af.json';

// Triple-DES/ECB/PKCS7 with an MD5-derived key, matching lib/mobile_encryption_service.dart
// (verified against real records: decrypting 'cHs2tfDSi8DO2N8cyvWBNw==' yields '9870496105').
const MOBILE_KEY = crypto.createHash('md5').update(Buffer.from('iMmoRtALs', 'utf8')).digest();
function encryptMobile(plainText) {
  if (!plainText) return '';
  const cipher = crypto.createCipheriv('des-ede-ecb', MOBILE_KEY, Buffer.alloc(0));
  cipher.setAutoPadding(true);
  return Buffer.concat([cipher.update(Buffer.from(plainText, 'utf8')), cipher.final()]).toString('base64');
}

const MONTH_NAMES = [
  'January', 'February', 'March', 'April', 'May', 'June',
  'July', 'August', 'September', 'October', 'November', 'December',
];

function monthYearKey(date) {
  return `${MONTH_NAMES[date.getMonth()]}_${date.getFullYear()}`;
}

function invertedDateFrom(date) {
  const yyyy = date.getFullYear().toString().padStart(4, '0');
  const mm = (date.getMonth() + 1).toString().padStart(2, '0');
  const dd = date.getDate().toString().padStart(2, '0');
  return 99999999 - parseInt(`${yyyy}${mm}${dd}`, 10);
}

function zoneKey(zoneNameEn) {
  const digits = (zoneNameEn || '').match(/(\d+)/);
  return digits ? digits[1] : (zoneNameEn || 'unknown').replace(/\s+/g, '');
}

function formatDob(v) {
  if (!v) return '';
  const d = new Date(v);
  if (isNaN(d) || d.getFullYear() <= 1901) return '';
  const mm = (d.getMonth() + 1).toString().padStart(2, '0');
  const dd = d.getDate().toString().padStart(2, '0');
  return `${d.getFullYear()}-${mm}-${dd}`;
}

const str = v => (v === null || v === undefined ? '' : String(v).trim());

function buildRecords(rows) {
  const usersById = new Map();
  const attendanceRecords = [];

  rows.forEach((row, chunkIndex) => {
    const uid = str(row.MemberMasterId);
    if (!uid) return; // no member reference — skip, can't attribute this row

    if (!usersById.has(uid)) {
      usersById.set(uid, {
        uid,
        name: str(row.Name_en),
        name_mr: str(row.Name_mr),
        mobile: encryptMobile(str(row.Mobile)), // source column is decrypted plain digits; re-encrypt for storage
        zone: str(row.ZoneName_en),
        zone_mr: str(row.ZoneName_mr),
        baithakPlace: str(row.BaithakName_en),
        baithak_mr: str(row.BaithakName_mr),
        baithak_day: str(row.BaithakDay_en),
        baithak_day_mr: str(row.BaithakDay_mr),
        hall: str(row.HallName_en),
        hall_mr: str(row.HallName_mr),
        gender: str(row.Gender),
        dob: formatDob(row.DateOfBirth),
        hajeri_kramank: str(row.Hajeri),
        isActive: row.IsActive === 1 || row.IsActive === '1' || row.IsActive === true,
        role: 'user',
        attendance_viewer: false,
        source: 'sevakdb_migration',
      });
    }

    const attDate = new Date(row.AttendanceDateTime);
    const invertedDate = invertedDateFrom(attDate);
    const monthKey = monthYearKey(attDate);
    const docId = `${invertedDate}_${uid}_${zoneKey(row.ZoneName_en)}`;

    attendanceRecords.push({
      monthKey,
      docId,
      chunkIndex, // position within the input `rows` chunk — lets callers map back to a source row number
      data: {
        date: attDate,
        time: '00:00:00',
        status: 'Present',
        Topic: str(row.WorkNames),
        work_hours: row.WorkHours === null || row.WorkHours === undefined ? '' : String(row.WorkHours),
        Location_En: str(row.Location_En),
        Location_Mr: str(row.Location_Mr),
        zone: str(row.ZoneName_en),
        zone_mr: str(row.ZoneName_mr),
        name: str(row.Name_en),
        name_mr: str(row.Name_mr),
        userId: uid,
        mobile: encryptMobile(str(row.Mobile)),
        baithak: str(row.BaithakName_en),
        hajeri_kramank: str(row.Hajeri),
        source: 'sevakdb_migration',
      },
    });
  });

  return { users: [...usersById.values()], attendanceRecords };
}

module.exports = {
  MAIN_SERVICE_ACCOUNT,
  HAJERI_SERVICE_ACCOUNT,
  encryptMobile,
  monthYearKey,
  invertedDateFrom,
  zoneKey,
  formatDob,
  str,
  buildRecords,
};
