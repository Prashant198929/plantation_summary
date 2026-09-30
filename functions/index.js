const functions = require('firebase-functions');
const admin = require('firebase-admin');
admin.initializeApp();

// When an admin deletes a user document, also delete the Firebase Auth account
// so the user cannot log in again via any app or token.
exports.deleteAuthOnUserDelete = functions
  .region('us-central1')
  .firestore.document('users/{userId}')
  .onDelete(async (snap) => {
    const data = snap.data();

    // 'authUid' holds the real Firebase Auth ID. 'uid' is now always a
    // sequential display ID (for reports/attendance) — never a real Auth
    // ID — so it must NOT be used as a fallback here; fall back straight
    // to email lookup for any record without authUid.
    let uid = data.authUid || null;

    if (!uid && data.email) {
      try {
        const userRecord = await admin.auth().getUserByEmail(data.email);
        uid = userRecord.uid;
      } catch (e) {
        if (e.code === 'auth/user-not-found') {
          console.log('deleteAuthOnUserDelete: no Auth account for email', data.email, '(doc', snap.id + ') — nothing to clean up');
        } else {
          console.error('getUserByEmail failed for doc', snap.id, ':', e.message);
        }
        return null;
      }
    }

    if (!uid) {
      console.warn('deleteAuthOnUserDelete: no authUid or email on doc', snap.id, '— cannot clean up any Auth account');
      return null;
    }

    try {
      await admin.auth().deleteUser(uid);
      console.log('Deleted Auth account:', uid, 'for Firestore doc:', snap.id);
    } catch (e) {
      if (e.code === 'auth/user-not-found') {
        console.log('deleteAuthOnUserDelete: Auth account', uid, 'for doc', snap.id, 'already gone (stale authUid?) — nothing to clean up');
      } else {
        console.error('deleteUser failed for doc', snap.id, 'uid', uid, ':', e.message);
      }
    }
    return null;
  });

// Lets a super admin set a new login password for another user directly
// (bypassing the "forgot password" email flow), from the User Management
// edit dialog. 'users' docs are keyed by a sequential display id, not the
// Firebase Auth uid, so both the caller's own role and the target account
// are resolved via their stored 'authUid' field, falling back to email —
// the same fallback deleteAuthOnUserDelete above uses.
exports.adminSetUserPassword = functions
  .region('us-central1')
  .https.onCall(async (data, context) => {
    if (!context.auth) {
      throw new functions.https.HttpsError('unauthenticated', 'Sign in required.');
    }

    let callerSnap = await admin.firestore()
      .collection('users')
      .where('authUid', '==', context.auth.uid)
      .limit(1)
      .get();
    if (callerSnap.empty && context.auth.token.email) {
      callerSnap = await admin.firestore()
        .collection('users')
        .where('email', '==', context.auth.token.email)
        .limit(1)
        .get();
    }
    const callerRole = (callerSnap.docs[0]?.get('role') || '').toString().toLowerCase();
    if (callerRole !== 'super_admin' && callerRole !== 'superadmin') {
      throw new functions.https.HttpsError(
        'permission-denied',
        "Only a super admin can set another user's password.",
      );
    }

    const targetAuthUid = (data.authUid || '').toString().trim();
    const targetEmail = (data.email || '').toString().trim();
    const newPassword = (data.newPassword || '').toString();
    if (newPassword.length < 8) {
      throw new functions.https.HttpsError('invalid-argument', 'Password must be at least 8 characters.');
    }
    if (!targetAuthUid && !targetEmail) {
      throw new functions.https.HttpsError('invalid-argument', 'authUid or email is required to identify the account.');
    }

    let resolvedUid = targetAuthUid;
    if (!resolvedUid) {
      try {
        const userRecord = await admin.auth().getUserByEmail(targetEmail);
        resolvedUid = userRecord.uid;
      } catch (e) {
        throw new functions.https.HttpsError('not-found', 'No login account found for this user.');
      }
    }

    try {
      await admin.auth().updateUser(resolvedUid, { password: newPassword });
    } catch (e) {
      if (e.code === 'auth/user-not-found') {
        throw new functions.https.HttpsError('not-found', 'No login account found for this user.');
      }
      throw new functions.https.HttpsError('internal', e.message);
    }

    return { success: true };
  });

// Lets a super admin change another user's login email directly, from the
// User Management edit dialog. Email doubles as the Firebase Auth login
// credential once an account has logged in at least once, so the Firestore
// 'users' doc and the Auth account must be updated together — this updates
// Auth first (source of truth for login) and the caller only writes the
// Firestore field afterwards, so a failure here never desyncs the two.
// Same caller/target resolution as adminSetUserPassword above.
exports.adminSetUserEmail = functions
  .region('us-central1')
  .https.onCall(async (data, context) => {
    if (!context.auth) {
      throw new functions.https.HttpsError('unauthenticated', 'Sign in required.');
    }

    let callerSnap = await admin.firestore()
      .collection('users')
      .where('authUid', '==', context.auth.uid)
      .limit(1)
      .get();
    if (callerSnap.empty && context.auth.token.email) {
      callerSnap = await admin.firestore()
        .collection('users')
        .where('email', '==', context.auth.token.email)
        .limit(1)
        .get();
    }
    const callerRole = (callerSnap.docs[0]?.get('role') || '').toString().toLowerCase();
    if (callerRole !== 'super_admin' && callerRole !== 'superadmin') {
      throw new functions.https.HttpsError(
        'permission-denied',
        "Only a super admin can change another user's email.",
      );
    }

    const targetAuthUid = (data.authUid || '').toString().trim();
    const currentEmail = (data.currentEmail || '').toString().trim();
    const newEmail = (data.newEmail || '').toString().trim();
    if (!newEmail) {
      throw new functions.https.HttpsError('invalid-argument', 'newEmail is required.');
    }
    if (!targetAuthUid && !currentEmail) {
      throw new functions.https.HttpsError('invalid-argument', 'authUid or currentEmail is required to identify the account.');
    }

    let resolvedUid = targetAuthUid;
    if (!resolvedUid) {
      try {
        const userRecord = await admin.auth().getUserByEmail(currentEmail);
        resolvedUid = userRecord.uid;
      } catch (e) {
        throw new functions.https.HttpsError('not-found', 'No login account found for this user.');
      }
    }

    try {
      await admin.auth().updateUser(resolvedUid, { email: newEmail });
    } catch (e) {
      if (e.code === 'auth/user-not-found') {
        throw new functions.https.HttpsError('not-found', 'No login account found for this user.');
      }
      if (e.code === 'auth/email-already-exists') {
        throw new functions.https.HttpsError('already-exists', 'This email is already used by another login account.');
      }
      throw new functions.https.HttpsError('internal', e.message);
    }

    return { success: true };
  });

exports.sendBroadcastNotification = functions
  .region('us-central1')
  .firestore.document('broadcasts/{broadcastId}')
  .onCreate(async (snap, context) => {
    const data = snap.data();

    if (data.status === 'missing_token' || data.status === 'sent') {
      return null;
    }

    const token = data.registrationToken;
    if (!token) {
      await snap.ref.update({ status: 'missing_token' });
      return null;
    }

    const message = {
      token: token,
      notification: {
        title: data.title || 'प्रसारण संदेश',
        body: data.message || '',
      },
      data: {
        phone: data.toPhone || '',
        fromPhone: data.fromPhone || '',
      },
      android: {
        priority: 'high',
        notification: {
          sound: 'default',
          channelId: 'broadcast_channel',
        },
      },
    };

    try {
      const response = await admin.messaging().send(message);
      await snap.ref.update({
        status: 'sent',
        fcmMessageId: response,
        deliveredAt: admin.firestore.FieldValue.serverTimestamp(),
      });
      return null;
    } catch (error) {
      await snap.ref.update({
        status: 'error',
        error: error.message,
      });
      return null;
    }
  });
