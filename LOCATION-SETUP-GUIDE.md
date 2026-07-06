# Google Location Setup Guide

This guide shows how to complete the GPS location feature implementation.

## ✅ Already Completed:
1. ✓ Added `geolocator: ^13.0.2` package to `pubspec.yaml`
2. ✓ Imported `package:geolocator/geolocator.dart` in zone_management_page.dart
3. ✓ Created `_getCurrentLocation()` helper function (line 70)

## 📱 Step 1: Add Android Permissions

**File:** `android/app/src/main/AndroidManifest.xml`

Add these permissions **before** the `<application>` tag:

```xml
<manifest xmlns:android="http://schemas.android.com/apk/res/android">
    <!-- ADD THESE TWO LINES -->
    <uses-permission android:name="android.permission.ACCESS_FINE_LOCATION" />
    <uses-permission android:name="android.permission.ACCESS_COARSE_LOCATION" />
    
    <application
        ...
    </application>
</manifest>
```

## 🍎 Step 2: Add iOS Permissions

**File:** `ios/Runner/Info.plist`

Add these inside the `<dict>` tag:

```xml
<key>NSLocationWhenInUseUsageDescription</key>
<string>या अॅपला रोपांचे स्थान रेकॉर्ड करण्यासाठी स्थान प्रवेशाची आवश्यकता आहे</string>
<key>NSLocationAlwaysUsageDescription</key>
<string>या अॅपला रोपांचे स्थान रेकॉर्ड करण्यासाठी स्थान प्रवेशाची आवश्यकता आहे</string>
```

## 🔧 Step 3: Run Flutter Pub Get

```bash
cd c:/GitLab/plantation_summary
flutter pub get
```

## 📍 Step 4: Add "Get Location" Button

You need to add this button in **3 places**:

### Location 1: Add Plant Dialog (_showAddPlantDialog - around line 1800)

After the latitude TextField, add:

```dart
const SizedBox(height: 12),
ElevatedButton.icon(
  onPressed: () async {
    Position? position = await _getCurrentLocation(context);
    if (position != null) {
      setState(() {
        longitudeController.text = position.longitude.toString();
        latitudeController.text = position.latitude.toString();
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('स्थान यशस्वीरित्या मिळवले!')),
      );
    }
  },
  icon: Icon(Icons.my_location),
  label: Text('सध्याचे स्थान मिळवा'),
  style: ElevatedButton.styleFrom(
    backgroundColor: Colors.blue,
    foregroundColor: Colors.white,
  ),
),
```

### Location 2: Edit Plant Dialog (_showEditPlantDialog - around line 1400)

After the latitude TextField (inside the edit dialog), add the same button.

### Location 3: ZoneDetailPage build method (around line 850)

After the latitude TextField in the main form, add the same button but with slight modification:

```dart
const SizedBox(height: 8),
ElevatedButton.icon(
  onPressed: () async {
    Position? position = await _getCurrentLocation(context);
    if (position != null) {
      setState(() {
        _longitudeController.text = position.longitude.toString();
        _latitudeController.text = position.latitude.toString();
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('स्थान यशस्वीरित्या मिळवले!')),
      );
    }
  },
  icon: Icon(Icons.my_location),
  label: Text('सध्याचे स्थान मिळवा'),
  style: ElevatedButton.styleFrom(
    backgroundColor: Colors.blue,
    foregroundColor: Colors.white,
  ),
),
```

## 🎯 How It Will Work:

1. User clicks **"सध्याचे स्थान मिळवा"** (Get Current Location)
2. App requests location permission (first time only)
3. GPS fetches current latitude & longitude
4. Fields auto-fill with coordinates
5. User saves the plant with accurate GPS data

## ⚠️ Important Notes:

- **First time:** App will ask for location permission
- **Location services off:** User sees message "कृपया स्थान सेवा सक्षम करा"
- **Permission denied:** User sees message "स्थान परवानगी नाकारली"
- **GPS error:** Shows error message in Marathi

## ✨ Benefits:

✅ **No manual typing** of lat/long coordinates  
✅ **100% accurate** GPS coordinates  
✅ **Permission handling** built-in  
✅ **Error messages** in Marathi  
✅ **Works everywhere:** Add, Edit, and main forms  

## 🧪 Testing:

1. Run app on real device (GPS doesn't work well in emulator)
2. Go to Plant Management → Add Plant
3. Click "सध्याचे स्थान मिळवा"
4. Allow location permission when prompted
5. Check latitude/longitude fields auto-fill

## 📝 Next Steps:

After adding the buttons in all 3 locations, rebuild the app:

```bash
flutter clean
flutter pub get
flutter run