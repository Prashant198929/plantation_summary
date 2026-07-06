import 'package:cloud_firestore/cloud_firestore.dart';

class PlantType {
  final String id;
  final String nameMarathi;
  final String nameEnglish;
  final List<String> aliases;

  const PlantType({
    required this.id,
    required this.nameMarathi,
    required this.nameEnglish,
    this.aliases = const [],
  });

  factory PlantType.fromDoc(DocumentSnapshot doc) {
    final d = doc.data() as Map<String, dynamic>;
    return PlantType(
      id: doc.id,
      nameMarathi: d['nameMarathi'] ?? '',
      nameEnglish: d['nameEnglish'] ?? '',
      aliases: List<String>.from(d['aliases'] ?? []),
    );
  }

  Map<String, dynamic> toMap() => {
    'nameMarathi': nameMarathi,
    'nameEnglish': nameEnglish,
    'aliases': aliases,
  };

  // Partial match — used for search-as-you-type
  bool matches(String query) {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return true;
    return nameMarathi.toLowerCase().contains(q) ||
        nameEnglish.toLowerCase().contains(q) ||
        aliases.any((a) => a.toLowerCase().contains(q));
  }

  // Exact match — used for migration
  bool exactMatch(String input) {
    final q = input.trim().toLowerCase();
    return nameMarathi.toLowerCase() == q ||
        nameEnglish.toLowerCase() == q ||
        aliases.any((a) => a.toLowerCase() == q);
  }
}

class PlantTypeService {
  static const String _collection = 'plant_types';
  static List<PlantType>? _cache;

  // Full plant list from database
  static final List<Map<String, dynamic>> _seedData = [
    {'id': 'amba',            'nameMarathi': 'आंबा',            'nameEnglish': 'Mango',              'aliases': ['Mango', 'mango', 'Amba', 'amba', 'आंबा ']},
    {'id': 'phanas',          'nameMarathi': 'फणस',             'nameEnglish': 'Jackfruit',          'aliases': ['Jackfruit', 'jackfruit', 'Phanas', 'phanas', 'फणस ', 'फणस(झाड नाही आहे, मेले आहे)', 'फणस (झाड नाही आहे, मेले आहे)', 'फणस (नवीन झाड वड)', 'फणस (नवीन झाड करंज)']},
    {'id': 'vad',             'nameMarathi': 'वड',              'nameEnglish': 'Banyan',             'aliases': ['Banyan', 'banyan', 'Vad', 'vad', 'वड ']},
    {'id': 'karanj',          'nameMarathi': 'करंज',            'nameEnglish': 'Pongamia',           'aliases': ['Pongamia', 'pongamia', 'Karanj', 'karanj', 'करंज ']},
    {'id': 'jambhul',         'nameMarathi': 'जांभूळ',          'nameEnglish': 'Jamun',              'aliases': ['Jamun', 'jamun', 'Jambhul', 'jambhul', 'जांभूळ ']},
    {'id': 'kaju',            'nameMarathi': 'काजू',            'nameEnglish': 'Cashew',             'aliases': ['Cashew', 'cashew', 'Kaju', 'kaju', 'काजू ', 'काजू', 'काजु']},
    {'id': 'behada',          'nameMarathi': 'बेहडा',           'nameEnglish': 'Behada',             'aliases': ['Behada', 'behada', 'Beleric', 'बेहडा ']},
    {'id': 'jangali_badam',   'nameMarathi': 'जंगली बदाम',      'nameEnglish': 'Wild Almond',        'aliases': ['Wild Almond', 'wild almond', 'Jangali Badam', 'jangali badam', 'जंगली बदाम ']},
    {'id': 'pimpal',          'nameMarathi': 'पिंपळ',           'nameEnglish': 'Peepal',             'aliases': ['Peepal', 'peepal', 'Pimpal', 'pimpal', 'पिंपळ ']},
    {'id': 'chinch',          'nameMarathi': 'चिंच',            'nameEnglish': 'Tamarind',           'aliases': ['Tamarind', 'tamarind', 'Chinch', 'chinch', 'चिंच ']},
    {'id': 'vilayati_chinch', 'nameMarathi': 'विलायती चिंच',   'nameEnglish': 'Manila Tamarind',    'aliases': ['Manila Tamarind', 'manila tamarind', 'Vilayati Chinch', ' विलायती चिंच', ' चिंच']},
    {'id': 'bamboo',          'nameMarathi': 'बांबू',           'nameEnglish': 'Bamboo',             'aliases': ['Bamboo', 'bamboo', 'Bambu', 'बांबू ']},
    {'id': 'bhokhar',         'nameMarathi': 'भोकर',            'nameEnglish': 'Bhokhar',            'aliases': ['Bhokhar', 'bhokhar', 'Cordia', 'cordia', 'भोकर ']},
    {'id': 'miks_zhade',      'nameMarathi': 'मिक्स झाडे',      'nameEnglish': 'Mixed Trees',        'aliases': ['Mixed Trees', 'mixed trees', 'Mix', 'mix', 'मिक्स झाडे ']},
    {'id': 'savar',           'nameMarathi': 'सावर',            'nameEnglish': 'Silk Cotton',        'aliases': ['Silk Cotton', 'silk cotton', 'Bombax', 'bombax', 'Savar', 'savar', 'सावर ']},
    {'id': 'hirvee_savar',    'nameMarathi': 'हिरवीसावर',       'nameEnglish': 'Green Silk Cotton',  'aliases': ['Green Silk Cotton', 'Hirvee Savar', 'हिरवीसावर ']},
    {'id': 'kadulimb',        'nameMarathi': 'कडुलिंब',         'nameEnglish': 'Neem',               'aliases': ['Neem', 'neem', 'Kadulimb', 'kadulimb', 'कडुळिंब', 'कडुलिंब ']},
    {'id': 'arjun',           'nameMarathi': 'अर्जुन',          'nameEnglish': 'Arjun Tree',         'aliases': ['Arjun', 'arjun', 'Terminalia arjuna', 'अर्जुन ']},
    {'id': 'sag',             'nameMarathi': 'साग',             'nameEnglish': 'Teak',               'aliases': ['Teak', 'teak', 'Sagwan', 'sagwan', 'Sag', 'सागवान', 'साग ']},
    {'id': 'gulmohar',        'nameMarathi': 'गुलमोहर',         'nameEnglish': 'Gulmohar',           'aliases': ['Gulmohar', 'gulmohar', 'Flame Tree', 'गुलमोहर ']},
    {'id': 'rain_tree',       'nameMarathi': 'रेन ट्री',        'nameEnglish': 'Rain Tree',          'aliases': ['Rain Tree', 'rain tree', 'Raintree', 'रेन ट्री ']},
    {'id': 'peru',            'nameMarathi': 'पेरू',            'nameEnglish': 'Guava',              'aliases': ['Guava', 'guava', 'Peru', 'peru', 'पेरू ']},
    {'id': 'chiku',           'nameMarathi': 'चिकू',            'nameEnglish': 'Sapodilla',          'aliases': ['Sapodilla', 'sapodilla', 'Chiku', 'chiku', 'चिकू ', 'चिक्कू']},
    {'id': 'sitafal',         'nameMarathi': 'सीताफळ',          'nameEnglish': 'Custard Apple',      'aliases': ['Custard Apple', 'custard apple', 'Sitafal', 'sitafal', 'सीताफळ ']},
    {'id': 'ramfal',          'nameMarathi': 'रामफळ',           'nameEnglish': 'Sugar Apple',        'aliases': ['Sugar Apple', 'sugar apple', 'Ramfal', 'ramfal']},
    {'id': 'bel',             'nameMarathi': 'बेल',             'nameEnglish': 'Bael',               'aliases': ['Bael', 'bael', 'Bel', 'bel', 'बेल ']},
    {'id': 'badam',           'nameMarathi': 'बदाम',            'nameEnglish': 'Indian Almond',      'aliases': ['Indian Almond', 'indian almond', 'Badam', 'badam', 'बदाम ']},
    {'id': 'tamhan',          'nameMarathi': 'ताम्हण',          'nameEnglish': 'Flame of Forest',    'aliases': ['Flame of Forest', 'flame of forest', 'Butea', 'butea', 'Tamhan', 'tamhan', 'ताम्हण ']},
    {'id': 'kokam',           'nameMarathi': 'कोकम',            'nameEnglish': 'Kokum',              'aliases': ['Kokum', 'kokum', 'Kokam', 'kokam', 'Garcinia', 'कोकम ']},
    {'id': 'umbar',           'nameMarathi': 'उंबर',            'nameEnglish': 'Cluster Fig',        'aliases': ['Cluster Fig', 'cluster fig', 'Umbar', 'umbar', 'उंबर ']},
    {'id': 'kadamba',         'nameMarathi': 'कदंब',            'nameEnglish': 'Kadamba',            'aliases': ['Kadamba', 'kadamba', 'कदंब ', 'कदंबा']},
    {'id': 'bakul',           'nameMarathi': 'बकुळ',            'nameEnglish': 'Bakul',              'aliases': ['Bakul', 'bakul', 'Mimusops', 'बकुळा', 'बकुळ ', 'बकुळा ']},
    {'id': 'kanchen',         'nameMarathi': 'कांचन',           'nameEnglish': 'Orchid Tree',        'aliases': ['Orchid Tree', 'orchid tree', 'Bauhinia', 'bauhinia', 'Kanchen', 'kanchen', 'कांचन ']},
    {'id': 'indrajav',        'nameMarathi': 'इंद्रजव',         'nameEnglish': 'Kutaj',              'aliases': ['Kutaj', 'kutaj', 'Holarrhena', 'Indrajav', 'indrajav', 'इंद्रजव ']},
    {'id': 'kusum',           'nameMarathi': 'कुसुम',           'nameEnglish': 'Kusum',              'aliases': ['Kusum', 'kusum', 'Schleichera', 'कुसुम ', ' कुसुम']},
    {'id': 'sonmohar',        'nameMarathi': 'सोनमोहर',         'nameEnglish': 'Golden Shower',      'aliases': ['Golden Shower', 'golden shower', 'Cassia fistula', 'Sonmohar', 'सोनमोहर ']},
    {'id': 'kassia',          'nameMarathi': 'कॅशिया',          'nameEnglish': 'Cassia',             'aliases': ['Cassia', 'cassia', 'Kassia', 'kassia', 'कॅशिया ']},
    {'id': 'rita',            'nameMarathi': 'रिटा',            'nameEnglish': 'Soapnut',            'aliases': ['Soapnut', 'soapnut', 'Sapindus', 'Rita', 'rita', 'रिटा', 'रीटा', 'रिटा ', 'रिठा']},
    {'id': 'putranjivika',    'nameMarathi': 'पुत्रजीविका',     'nameEnglish': 'Putranjiva',         'aliases': ['Putranjiva', 'putranjiva', 'Drypetes', 'Putranjivika', 'पुत्रजीविका ']},
    {'id': 'vasantarani',     'nameMarathi': 'वसंतराणी',        'nameEnglish': 'Vasantarani',        'aliases': ['Vasantarani', 'vasantarani', 'बसंतराणी', 'वसंतराणी ', 'बसंतराणी ']},
    {'id': 'undi',            'nameMarathi': 'उंडी',            'nameEnglish': 'Alexandrian Laurel', 'aliases': ['Alexandrian Laurel', 'Calophyllum', 'Undi', 'undi', 'उंडी ']},
    {'id': 'kinhal',          'nameMarathi': 'किंजळ',           'nameEnglish': 'Kinhal',             'aliases': ['Kinhal', 'kinhal', 'Pterocarpus', 'Kinjal', 'किंजळ ', 'किंजल']},
    {'id': 'kailasapati',     'nameMarathi': 'कैलासपती',        'nameEnglish': 'Kailasapati',        'aliases': ['Kailasapati', 'kailasapati', 'कैलासपती ', 'कैलासपती']},
    {'id': 'sita_ashoka',     'nameMarathi': 'सिता अशोका',      'nameEnglish': 'Saraca',             'aliases': ['Saraca', 'saraca', 'Ashoka', 'ashoka', 'Sita Ashoka', 'सिता अशोका', 'सीता अशोका', 'सिता अशोका ', 'सीता अशोक', 'सिता अशोक']},
    {'id': 'nimbara',         'nameMarathi': 'निंबारा',         'nameEnglish': 'Nimbara',            'aliases': ['Nimbara', 'nimbara', 'निंबर', 'निंबारा ', 'निंबर ', 'निंबरा']},
    {'id': 'kamrakh',         'nameMarathi': 'कमरख',            'nameEnglish': 'Star Fruit',         'aliases': ['Star Fruit', 'star fruit', 'Carambola', 'Kamrakh', 'kamrakh', 'कमरख ']},
    {'id': 'vhavhala',        'nameMarathi': 'व्हावळा',         'nameEnglish': 'Vhavhala',           'aliases': ['Vhavhala', 'vhavhala', 'वाव्हळा', 'व्हावळा ', 'वाव्हळा ', 'वाव्हला']},
    {'id': 'ral',             'nameMarathi': 'राळ',             'nameEnglish': 'Ral',                'aliases': ['Ral', 'ral', 'Shorea', 'राळ ']},
    {'id': 'poonam',          'nameMarathi': 'पूनम',            'nameEnglish': 'Poonam',             'aliases': ['Poonam', 'poonam', 'पूनम ']},
    {'id': 'aashi',           'nameMarathi': 'आशी',             'nameEnglish': 'Aashi',              'aliases': ['Aashi', 'aashi', 'आशी ']},
    {'id': 'tanam',           'nameMarathi': 'तनम',             'nameEnglish': 'Tanam',              'aliases': ['Tanam', 'tanam', 'तनम ']},
    {'id': 'kasheeda',        'nameMarathi': 'काशीद',           'nameEnglish': 'Kasheeda',           'aliases': ['Kasheeda', 'kasheeda', 'काशीद ', 'काशीद']},
    {'id': 'kamarkar',        'nameMarathi': 'कामरकर',          'nameEnglish': 'Kamarkar',           'aliases': ['Kamarkar', 'kamarkar', 'कामरकर ']},
    {'id': 'karavati',        'nameMarathi': 'करवती',           'nameEnglish': 'Karavati',           'aliases': ['Karavati', 'karavati', 'करवती ']},
    {'id': 'payar',           'nameMarathi': 'पायर',            'nameEnglish': 'Payar',              'aliases': ['Payar', 'payar', 'पायर ']},
    {'id': 'akrod',           'nameMarathi': 'अक्रोड',          'nameEnglish': 'Walnut',             'aliases': ['Walnut', 'walnut', 'Akrod', 'akrod', 'अक्रोड ']},
    {'id': 'nariyal',         'nameMarathi': 'नारळ',            'nameEnglish': 'Coconut',            'aliases': ['Coconut', 'coconut', 'Nariyal', 'nariyal']},
    {'id': 'limbu',           'nameMarathi': 'लिंबू',           'nameEnglish': 'Lemon',              'aliases': ['Lemon', 'lemon', 'Limbu', 'limbu', 'Nimbu', 'nimbu', 'लिंबू ']},
    {'id': 'tulsi',           'nameMarathi': 'तुळस',            'nameEnglish': 'Tulsi',              'aliases': ['Tulsi', 'tulsi', 'Holy Basil', 'holy basil', 'तुळस ']},
    {'id': 'karela',          'nameMarathi': 'कारले',           'nameEnglish': 'Bitter Gourd',       'aliases': ['Bitter Gourd', 'bitter gourd', 'Karela', 'karela', 'कारले ']},
  ];

  static Future<List<PlantType>> fetchAll() async {
    if (_cache != null) return _cache!;
    final snapshot = await FirebaseFirestore.instance
        .collection(_collection)
        .orderBy('nameMarathi')
        .get();
    if (snapshot.docs.isEmpty) {
      await _seed();
      return fetchAll();
    }
    _cache = snapshot.docs.map((d) => PlantType.fromDoc(d)).toList();
    return _cache!;
  }

  static void clearCache() => _cache = null;

  // Resolve a raw plantName string to a PlantType (exact match only)
  static PlantType? resolveFromCache(String name) {
    if (_cache == null) return null;
    final q = name.trim().toLowerCase();
    try {
      return _cache!.firstWhere((p) => p.exactMatch(q));
    } catch (_) {
      return null;
    }
  }

  static Future<void> _seed() async {
    final batch = FirebaseFirestore.instance.batch();
    for (final p in _seedData) {
      final ref = FirebaseFirestore.instance
          .collection(_collection)
          .doc(p['id'] as String);
      batch.set(ref, {
        'nameMarathi': p['nameMarathi'],
        'nameEnglish': p['nameEnglish'],
        'aliases': p['aliases'],
      });
    }
    await batch.commit();
  }

  // One-time migration: adds plantTypeId + normalizes plantName to Marathi
  // Returns {'matched': N, 'unmatched': N}
  static Future<Map<String, int>> migrateExistingRecords() async {
    final all = await fetchAll();
    int matched = 0;
    int unmatched = 0;

    for (final collName in ['plantation_records', 'HistoricalData']) {
      DocumentSnapshot? lastDoc;
      bool hasMore = true;

      while (hasMore) {
        Query query = FirebaseFirestore.instance
            .collection(collName)
            .limit(400);
        if (lastDoc != null) query = query.startAfterDocument(lastDoc);

        final snapshot = await query.get();
        if (snapshot.docs.isEmpty) break;

        final writeBatch = FirebaseFirestore.instance.batch();
        int count = 0;

        for (final doc in snapshot.docs) {
          final data = doc.data() as Map<String, dynamic>;
          final existing = data['plantTypeId']?.toString() ?? '';
          if (existing.isNotEmpty && existing != '__review__') continue;

          final plantName = data['plantName']?.toString().trim() ?? '';
          if (plantName.isEmpty) continue;

          PlantType? match;
          try {
            match = all.firstWhere((p) => p.exactMatch(plantName));
          } catch (_) {
            match = null;
          }

          if (match != null) {
            writeBatch.update(doc.reference, {
              'plantTypeId': match.id,
              'plantName': match.nameMarathi,
            });
            matched++;
          } else {
            writeBatch.update(doc.reference, {'plantTypeId': '__review__'});
            unmatched++;
          }
          count++;
        }

        if (count > 0) await writeBatch.commit();
        lastDoc = snapshot.docs.last;
        hasMore = snapshot.docs.length == 400;
      }
    }

    return {'matched': matched, 'unmatched': unmatched};
  }
}
