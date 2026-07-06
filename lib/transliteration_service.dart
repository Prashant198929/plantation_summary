// Best-effort English -> Marathi (Devanagari) phonetic transliteration.
//
// This is a rule-based letter mapper, not a trained model. It gets common
// names/places roughly right but cannot resolve real ambiguities in casual
// English spelling — e.g. dental vs retroflex consonants (Sonarpada's "d"
// could be द or ड) or short vs long vowels swallowed by nasal codas
// (Prashant is pronounced with a long, nasal "aa" that plain "a" can't
// encode). Callers should always leave the Marathi field editable.
class TransliterationService {
  // Longest-match-first; keys must stay lowercase.
  static const Map<String, String> _consonants = {
    'ksh': 'क्ष',
    'dny': 'ज्ञ',
    'chh': 'छ',
    'kh': 'ख',
    'gh': 'घ',
    'ch': 'च',
    'jh': 'झ',
    'ny': 'ञ',
    'ng': 'ङ',
    'th': 'थ',
    'dh': 'ध',
    'ph': 'फ',
    'bh': 'भ',
    'sh': 'श',
    'gy': 'ज्ञ',
    'jn': 'ज्ञ',
    'k': 'क',
    'g': 'ग',
    'c': 'च',
    'j': 'ज',
    't': 'त',
    'd': 'द',
    'n': 'न',
    'p': 'प',
    'b': 'ब',
    'm': 'म',
    'y': 'य',
    'r': 'र',
    'l': 'ल',
    'v': 'व',
    'w': 'व',
    's': 'स',
    'h': 'ह',
    'f': 'फ',
    'x': 'क्ष',
  };

  static const Map<String, String> _standaloneVowels = {
    'aa': 'आ',
    'ee': 'ई',
    'ii': 'ई',
    'oo': 'ऊ',
    'uu': 'ऊ',
    'ai': 'ऐ',
    'au': 'औ',
    'ow': 'औ',
    'a': 'अ',
    'i': 'इ',
    'u': 'उ',
    'e': 'ए',
    'o': 'ओ',
  };

  // Matra applied after a consonant. 'a' is the implicit schwa — no glyph.
  static const Map<String, String> _matras = {
    'aa': 'ा',
    'ee': 'ी',
    'ii': 'ी',
    'oo': 'ू',
    'uu': 'ू',
    'ai': 'ै',
    'au': 'ौ',
    'ow': 'ौ',
    'a': '',
    'i': 'ि',
    'u': 'ु',
    'e': 'े',
    'o': 'ो',
  };

  static const String _halant = '्';
  static const String _anusvara = 'ं';

  static String? _matchLongest(Map<String, String> table, String s, int at, List<int> lengths) {
    for (final len in lengths) {
      if (at + len <= s.length) {
        final sub = s.substring(at, at + len);
        if (table.containsKey(sub)) return sub;
      }
    }
    return null;
  }

  static bool _consonantStartsAt(String s, int at) =>
      _matchLongest(_consonants, s, at, const [3, 2, 1]) != null;

  static String toDevanagari(String input) {
    if (input.trim().isEmpty) return '';
    return input.split(' ').map((w) => w.isEmpty ? w : _transliterateWord(w)).join(' ');
  }

  static String _transliterateWord(String word) {
    final w = word.toLowerCase();
    final buf = StringBuffer();
    int i = 0;

    while (i < w.length) {
      final consKey = _matchLongest(_consonants, w, i, const [3, 2, 1]);
      if (consKey != null) {
        final nextIndex = i + consKey.length;

        // Coda-nasal heuristic: "n"/"m" directly before another consonant
        // (no vowel between) almost always represents anusvara in Marathi
        // spelling (e.g. "sant" -> संत), not a literal न्/म् + consonant.
        if ((consKey == 'n' || consKey == 'm') &&
            nextIndex < w.length &&
            _consonantStartsAt(w, nextIndex)) {
          buf.write(_anusvara);
          i = nextIndex;
          continue;
        }

        buf.write(_consonants[consKey]);
        i = nextIndex;

        final vowelKey = _matchLongest(_matras, w, i, const [2, 1]);
        if (vowelKey != null) {
          buf.write(_matras[vowelKey]);
          i += vowelKey.length;
        } else if (i < w.length && _consonantStartsAt(w, i)) {
          // Consonant cluster with no vowel between — join with halant.
          buf.write(_halant);
        }
        // Else: end of word or unrecognized char — inherent "a" stays implicit.
        continue;
      }

      final vowelKey = _matchLongest(_standaloneVowels, w, i, const [2, 1]);
      if (vowelKey != null) {
        buf.write(_standaloneVowels[vowelKey]);
        i += vowelKey.length;
        continue;
      }

      // Unrecognized character (digit, punctuation, etc.) — pass through.
      buf.write(w[i]);
      i++;
    }

    return buf.toString();
  }
}
