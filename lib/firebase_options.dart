import 'package:firebase_core/firebase_core.dart' show FirebaseOptions;

class DefaultFirebaseOptions {
  static FirebaseOptions get currentPlatform {
    return const FirebaseOptions(
      apiKey: 'AIzaSyCfCKHjzCuuOTt8dZFJc-VDAPuFrkaaQVY',
    appId: '1:436597351597:android:c7ff2ff0649734e5325224',
    messagingSenderId: '436597351597',
    projectId: 'vrukshamojaniattendancelogs',
    databaseURL: 'https://vrukshamojaniattendancelogs.firebaseio.com',
    storageBucket: 'vrukshamojaniattendancelogs.firebasestorage.app',
  );
  }
}
