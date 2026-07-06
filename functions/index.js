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
        // Auth account may already be gone — not an error
        if (e.code !== 'auth/user-not-found') {
          console.error('getUserByEmail failed:', e.message);
        }
        return null;
      }
    }

    if (!uid) {
      console.warn('deleteAuthOnUserDelete: no uid or email on doc', snap.id);
      return null;
    }

    try {
      await admin.auth().deleteUser(uid);
      console.log('Deleted Auth account:', uid, 'for Firestore doc:', snap.id);
    } catch (e) {
      if (e.code !== 'auth/user-not-found') {
        console.error('deleteUser failed:', e.message);
      }
    }
    return null;
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
