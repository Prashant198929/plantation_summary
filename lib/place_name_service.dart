import 'package:cloud_firestore/cloud_firestore.dart';
import 'transliteration_service.dart';

// Dictionary-backed English -> Marathi lookup for Baithak Place / Hall names.
// Unlike personal names, these are a small, repeating, finite set for a given
// organization, so exact matches can be stored and reused instead of guessed
// every time. Falls back to phonetic transliteration for names not yet seen,
// and learns new/corrected entries as users submit forms.
class PlaceNameService {
  static const String _collection = 'place_translations';
  static Map<String, String>? _cache;

  static String normalize(String value) => value.trim().toLowerCase();

  static Future<Map<String, String>> fetchAll() async {
    if (_cache != null) return _cache!;
    final snapshot = await FirebaseFirestore.instance.collection(_collection).get();
    _cache = {
      for (final doc in snapshot.docs)
        (doc.data()['english'] ?? doc.id).toString(): (doc.data()['marathi'] ?? '').toString(),
    };
    return _cache!;
  }

  static void clearCache() => _cache = null;

  // Returns the known Marathi spelling for an exact match, or a best-effort
  // phonetic guess if this place hasn't been seen before.
  static String suggest(String english) {
    final key = normalize(english);
    if (key.isEmpty) return '';
    final known = _cache?[key];
    if (known != null && known.isNotEmpty) return known;
    return TransliterationService.toDevanagari(english.trim());
  }

  static bool hasExactMatch(String english) {
    final key = normalize(english);
    final known = _cache?[key];
    return known != null && known.isNotEmpty;
  }

  // Stores/updates an English -> Marathi pair so future lookups are exact.
  static Future<void> learn(String english, String marathi) async {
    final key = normalize(english);
    final marathiTrimmed = marathi.trim();
    if (key.isEmpty || marathiTrimmed.isEmpty) return;
    if (_cache?[key] == marathiTrimmed) return; // already known, skip write

    _cache ??= {};
    _cache![key] = marathiTrimmed;

    await FirebaseFirestore.instance.collection(_collection).doc(_docIdFor(key)).set({
      'english': english.trim(),
      'marathi': marathiTrimmed,
      'updatedAt': FieldValue.serverTimestamp(),
    });
  }

  // Firestore doc IDs can't contain '/'; sanitize just in case.
  static String _docIdFor(String normalizedKey) =>
      normalizedKey.replaceAll('/', '_').replaceAll(' ', '_');
}
