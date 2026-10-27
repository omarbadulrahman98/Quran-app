// قورئانی پیرۆز - Flutter project (data from assets/quran/*.json)
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart' show compute;
import 'package:flutter/services.dart' show rootBundle;
import 'package:shared_preferences/shared_preferences.dart';

// ============================================================
//  قورئانی پیرۆز - Quran + Kurdish tafseer
//  (UI part - identical in the DartPad and the Flutter project)
// ============================================================

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await settings.load();
  runApp(const QuranApp());
}

// ---------- colours / fonts ----------
const Color _green = Color(0xFF1E7A3E);
const Color _gold = Color(0xFFD9A21B);
const Color _creamBg = Color(0xFFFBF4E2);
const Color _darkBg = Color(0xFF111A14);
const List<String> _arFonts = [
  'Amiri',
  'Noto Naskh Arabic',
  'Scheherazade New',
  'Traditional Arabic',
  'Arial',
];

bool _isDark(BuildContext c) => Theme.of(c).brightness == Brightness.dark;
Color _cardColor(BuildContext c) =>
    _isDark(c) ? const Color(0xFF1B2620) : const Color(0xFFFFFBF0);
Color _lineColor(BuildContext c) =>
    _isDark(c) ? const Color(0xFF2C3A31) : const Color(0xFFEBDFC0);
Color _inkColor(BuildContext c) =>
    _isDark(c) ? const Color(0xFFEDE6D3) : const Color(0xFF2A2A22);
Color _mutedColor(BuildContext c) =>
    _isDark(c) ? const Color(0xFFA9B5AC) : const Color(0xFF6B6A5E);

// ---------- model ----------
enum Tr { puxt, asan, en, none }

const Map<Tr, String> _trLabels = {
  Tr.puxt: 'کوردی (پوخت)',
  Tr.asan: 'کوردی (ئاسان)',
  Tr.en: 'English',
  Tr.none: 'بێ وەرگێڕان',
};

class Ayah {
  final int n;
  final String ar;
  final String? puxt;
  final String? asan;
  final String? en;
  Ayah(this.n, this.ar, [this.puxt, this.asan, this.en]);

  String? tr(Tr t) {
    switch (t) {
      case Tr.puxt:
        return puxt;
      case Tr.asan:
        return asan;
      case Tr.en:
        return en;
      case Tr.none:
        return null;
    }
  }
}

class SurahInfo {
  final int n;
  final String ar;
  final String en;
  final bool makki;
  final int count;
  const SurahInfo(this.n, this.ar, this.en, this.makki, this.count);
}

// ---------- settings (dark mode, font size, translation) ----------
class Settings extends ChangeNotifier {
  bool dark = false;
  double arabicSize = 28;
  Tr tr = Tr.puxt;
  String rec = 'Alafasy_128kbps';
  List<List<String>> custom = [];

  Future<void> load() async {
    try {
      final p = await SharedPreferences.getInstance();
      dark = p.getBool('dark') ?? false;
      arabicSize = p.getDouble('size') ?? 28;
      final ti = p.getInt('tr') ?? 0;
      if (ti >= 0 && ti < Tr.values.length) tr = Tr.values[ti];
      rec = p.getString('rec') ?? rec;
      final c = p.getString('custom');
      if (c != null) {
        custom = (jsonDecode(c) as List<dynamic>)
            .map((e) => (e as List<dynamic>).map((x) => '$x').toList())
            .toList();
      }
    } catch (_) {}
  }

  Future<void> _save() async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setBool('dark', dark);
      await p.setDouble('size', arabicSize);
      await p.setInt('tr', tr.index);
      await p.setString('rec', rec);
      await p.setString('custom', jsonEncode(custom));
    } catch (_) {}
  }

  @override
  void notifyListeners() {
    super.notifyListeners();
    _save();
  }

  void setRec(String f) {
    rec = f;
    notifyListeners();
  }

  void addReciter(String f, String n) {
    custom = [...custom, [f, n]];
    rec = f;
    notifyListeners();
  }

  void removeReciter(String f) {
    custom = custom.where((r) => r[0] != f).toList();
    if (rec == f) rec = 'Alafasy_128kbps';
    notifyListeners();
  }

  void toggleDark() {
    dark = !dark;
    notifyListeners();
  }

  void bigger() {
    if (arabicSize < 56) {
      arabicSize += 2;
      notifyListeners();
    }
  }

  void smaller() {
    if (arabicSize > 16) {
      arabicSize -= 2;
      notifyListeners();
    }
  }

  void setTr(Tr t) {
    tr = t;
    notifyListeners();
  }
}

final Settings settings = Settings();

// ---------- app ----------
class QuranApp extends StatelessWidget {
  const QuranApp({super.key});

  ThemeData _theme(Brightness b) {
    final dark = b == Brightness.dark;
    return ThemeData(
      useMaterial3: true,
      brightness: b,
      colorScheme: ColorScheme.fromSeed(seedColor: _green, brightness: b),
      scaffoldBackgroundColor: dark ? _darkBg : _creamBg,
      appBarTheme: const AppBarTheme(
        backgroundColor: _green,
        foregroundColor: Colors.white,
        centerTitle: true,
        elevation: 0,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: settings,
      builder: (context, _) => MaterialApp(
        debugShowCheckedModeBanner: false,
        title: 'قورئانی پیرۆز',
        themeMode: settings.dark ? ThemeMode.dark : ThemeMode.light,
        theme: _theme(Brightness.light),
        darkTheme: _theme(Brightness.dark),
        builder: (context, child) => Directionality(
          textDirection: TextDirection.rtl,
          child: child ?? const SizedBox.shrink(),
        ),
        home: const SurahListPage(),
      ),
    );
  }
}

// ---------- small widgets ----------
class _Badge extends StatelessWidget {
  final int n;
  final double size;
  const _Badge(this.n, {this.size = 32});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size + 4,
      height: size + 4,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Transform.rotate(
            angle: 0.7853981634,
            child: Container(
              width: size * 0.72,
              height: size * 0.72,
              decoration: BoxDecoration(
                border: Border.all(color: _gold, width: 1.4),
                borderRadius: BorderRadius.circular(4),
              ),
            ),
          ),
          Text(
            '$n',
            style: TextStyle(
              fontSize: size * 0.36,
              color: _gold,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

// ---------- surah list ----------
class SurahListPage extends StatefulWidget {
  const SurahListPage({super.key});

  @override
  State<SurahListPage> createState() => _SurahListPageState();
}

class _SurahListPageState extends State<SurahListPage> {
  String _q = '';

  bool _match(SurahInfo s) {
    if (_q.isEmpty) return true;
    return '${s.n}' == _q ||
        s.en.toLowerCase().contains(_q) ||
        s.ar.contains(_q);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: settings,
      builder: (context, _) {
        final items = kSurahs.where(_match).toList();
        return Scaffold(
          bottomNavigationBar: const PlayerBar(),
          appBar: AppBar(
            title: const Text(
              'قورئانی پیرۆز',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
            actions: [
              IconButton(
                tooltip: 'ڕێکخستنەکان',
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(builder: (_) => const SettingsPage()),
                ),
                icon: const Icon(Icons.settings),
              ),
              IconButton(
                tooltip: 'تاریک / ڕووناک',
                onPressed: settings.toggleDark,
                icon: Icon(settings.dark ? Icons.light_mode : Icons.dark_mode),
              ),
            ],
          ),
          body: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 820),
              child: Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
                    child: TextField(
                      onChanged: (v) => setState(() => _q = v.trim().toLowerCase()),
                      decoration: InputDecoration(
                        hintText: 'گەڕان بە ناو یان ژمارە...',
                        prefixIcon: const Icon(Icons.search),
                        filled: true,
                        fillColor: _cardColor(context),
                        contentPadding: const EdgeInsets.symmetric(vertical: 12),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(14),
                          borderSide: BorderSide(color: _lineColor(context)),
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(14),
                          borderSide: BorderSide(color: _lineColor(context)),
                        ),
                      ),
                    ),
                  ),
                  Expanded(
                    child: ListView.builder(
                      padding: const EdgeInsets.fromLTRB(12, 6, 12, 24),
                      itemCount: items.length,
                      itemBuilder: (context, i) => _SurahTile(items[i]),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _SurahTile extends StatelessWidget {
  final SurahInfo s;
  const _SurahTile(this.s);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Material(
        color: _cardColor(context),
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute<void>(builder: (_) => SurahPage(number: s.n)),
          ),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: _lineColor(context)),
            ),
            child: Row(
              children: [
                _Badge(s.n),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        s.en,
                        textDirection: TextDirection.ltr,
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                          color: _inkColor(context),
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '${s.count} ئایەت • ${s.makki ? 'مەککی' : 'مەدەنی'}',
                        style: TextStyle(fontSize: 12.5, color: _mutedColor(context)),
                      ),
                    ],
                  ),
                ),
                Text(
                  s.ar,
                  style: const TextStyle(
                    fontSize: 24,
                    color: _gold,
                    fontWeight: FontWeight.bold,
                    fontFamilyFallback: _arFonts,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ---------- one surah ----------
class SurahPage extends StatefulWidget {
  final int number;
  const SurahPage({super.key, required this.number});

  @override
  State<SurahPage> createState() => _SurahPageState();
}

class _SurahPageState extends State<SurahPage> {
  late final Future<List<Ayah>> _future;

  @override
  void initState() {
    super.initState();
    _future = loadSurah(widget.number);
  }

  @override
  Widget build(BuildContext context) {
    final info = kSurahs[widget.number - 1];
    return ListenableBuilder(
      listenable: settings,
      builder: (context, _) {
        return Scaffold(
          bottomNavigationBar: const PlayerBar(),
          appBar: AppBar(
            leading: const BackButton(),
            title: Text(
              info.ar,
              style: const TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.bold,
                fontFamilyFallback: _arFonts,
              ),
            ),
            actions: [
              TextButton(
                onPressed: settings.bigger,
                child: const Text('A+', style: _abStyle),
              ),
              TextButton(
                onPressed: settings.smaller,
                child: const Text('A-', style: _abStyle),
              ),
              PopupMenuButton<Tr>(
                tooltip: 'وەرگێڕان',
                icon: const Icon(Icons.translate),
                onSelected: settings.setTr,
                itemBuilder: (context) => [
                  for (final t in kTrOptions)
                    CheckedPopupMenuItem<Tr>(
                      value: t,
                      checked: settings.tr == t,
                      child: Text(_trLabels[t] ?? ''),
                    ),
                ],
              ),
              IconButton(
                tooltip: 'تاریک / ڕووناک',
                onPressed: settings.toggleDark,
                icon: Icon(settings.dark ? Icons.light_mode : Icons.dark_mode),
              ),
            ],
          ),
          body: FutureBuilder<List<Ayah>>(
            future: _future,
            builder: (context, snap) {
              if (snap.hasError) {
                return Center(child: Text('هەڵە: ${snap.error}'));
              }
              final ayahs = snap.data;
              if (ayahs == null) {
                return const Center(child: CircularProgressIndicator());
              }
              final showBismillah = info.n != 1 && info.n != 9;
              return SelectionArea(
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 820),
                    child: ListView.builder(
                      padding: const EdgeInsets.only(bottom: 24),
                      itemCount: ayahs.length + 3,
                      itemBuilder: (context, i) {
                        if (i == 0) return _SurahHeader(info);
                        if (i == 1) {
                          return showBismillah
                              ? _Bismillah()
                              : const SizedBox(height: 12);
                        }
                        if (i == ayahs.length + 2) return _NavRow(info.n);
                        return _AyahCard(ayahs[i - 2], info.n);
                      },
                    ),
                  ),
                ),
              );
            },
          ),
        );
      },
    );
  }
}

const TextStyle _abStyle = TextStyle(
  color: Colors.white,
  fontWeight: FontWeight.bold,
  fontSize: 16,
);

class _SurahHeader extends StatelessWidget {
  final SurahInfo s;
  const _SurahHeader(this.s);

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 14, 12, 4),
      padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 16),
      decoration: BoxDecoration(
        color: _green,
        borderRadius: BorderRadius.circular(18),
      ),
      child: Column(
        children: [
          Text(
            s.ar,
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontSize: 32,
              color: _gold,
              fontWeight: FontWeight.bold,
              fontFamilyFallback: _arFonts,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            s.en,
            textDirection: TextDirection.ltr,
            style: const TextStyle(
              fontSize: 15,
              color: Colors.white,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'سوورەی ${s.n} • ${s.makki ? 'مەککی' : 'مەدەنی'} • ${s.count} ئایەت',
            style: const TextStyle(fontSize: 12.5, color: Color(0xCCFFFFFF)),
          ),
          const SizedBox(height: 12),
          _PlayAllButton(s.n),
        ],
      ),
    );
  }
}

class _Bismillah extends StatelessWidget {
  const _Bismillah();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 18, horizontal: 12),
      child: Text(
        'بِسْمِ ٱللَّهِ ٱلرَّحْمَٰنِ ٱلرَّحِيمِ',
        textAlign: TextAlign.center,
        style: TextStyle(
          fontSize: settings.arabicSize,
          color: _gold,
          fontFamilyFallback: _arFonts,
        ),
      ),
    );
  }
}

class _AyahCard extends StatelessWidget {
  final Ayah a;
  final int surah;
  const _AyahCard(this.a, this.surah);

  @override
  Widget build(BuildContext context) {
    final t = settings.tr;
    final text = a.tr(t);
    final isEn = t == Tr.en;
    final double trSize = (settings.arabicSize * 0.56).clamp(13.0, 24.0).toDouble();
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 14),
      decoration: BoxDecoration(
        color: _cardColor(context),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: _lineColor(context)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ListenableBuilder(
            listenable: audio,
            builder: (context, _) {
              final active = audio.surah == surah && audio.ayah == a.n;
              return Row(
                children: [
                  _Badge(a.n, size: 30),
                  const Spacer(),
                  IconButton(
                    tooltip: 'گوێگرتن',
                    onPressed: () =>
                        active ? audio.toggle() : audio.play(surah, a.n),
                    icon: Icon(
                      active && audio.playing
                          ? Icons.pause_circle
                          : Icons.play_circle,
                      color: _gold,
                      size: 36,
                    ),
                  ),
                ],
              );
            },
          ),
          const SizedBox(height: 6),
          Text(
            a.ar,
            textDirection: TextDirection.rtl,
            textAlign: TextAlign.start,
            style: TextStyle(
              fontSize: settings.arabicSize,
              height: 2.0,
              color: _inkColor(context),
              fontFamilyFallback: _arFonts,
            ),
          ),
          if (t != Tr.none) ...[
            const SizedBox(height: 8),
            Divider(height: 1, color: _lineColor(context)),
            const SizedBox(height: 10),
            Text(
              (text == null || text.isEmpty) ? '(ئەم وەرگێڕانە بۆ ئەم ئایەتە بەردەست نییە)' : text,
              textDirection: isEn ? TextDirection.ltr : TextDirection.rtl,
              textAlign: TextAlign.start,
              style: TextStyle(
                fontSize: trSize,
                height: 1.7,
                color: _mutedColor(context),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _NavRow extends StatelessWidget {
  final int n;
  const _NavRow(this.n);

  void _go(BuildContext context, int to) {
    Navigator.of(context).pushReplacement(
      MaterialPageRoute<void>(builder: (_) => SurahPage(number: to)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 14, 12, 0),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          if (n > 1)
            OutlinedButton.icon(
              onPressed: () => _go(context, n - 1),
              icon: const Icon(Icons.arrow_back),
              label: Text('سوورەتی پێشوو (${n - 1})'),
            )
          else
            const SizedBox.shrink(),
          if (n < 114)
            OutlinedButton.icon(
              onPressed: () => _go(context, n + 1),
              icon: const Icon(Icons.arrow_forward),
              label: Text('سوورەتی دواتر (${n + 1})'),
            )
          else
            const SizedBox.shrink(),
        ],
      ),
    );
  }
}

// ---------- data: assets/quran/<n>.json ----------
const List<Tr> kTrOptions = [Tr.puxt, Tr.asan, Tr.en, Tr.none];

final Map<int, List<Ayah>> _cache = {};
Map<String, dynamic>? _all;

Map<String, dynamic> _parseAll(String t) =>
    jsonDecode(t) as Map<String, dynamic>;

Future<List<Ayah>> loadSurah(int n) async {
  final hit = _cache[n];
  if (hit != null) return hit;
  _all ??= await compute(_parseAll, await rootBundle.loadString('quran.json'));
  final list = (_all!['$n'] as List<dynamic>).map((e) {
    final m = e as Map<String, dynamic>;
    return Ayah(
      m['n'] as int,
      m['ar'] as String,
      m['puxt'] as String?,
      m['asan'] as String?,
      m['en'] as String?,
    );
  }).toList();
  _cache[n] = list;
  return list;
}

const List<SurahInfo> kSurahs = [
  SurahInfo(1, "الفاتحة", "Al-Fatihah", true, 7),
  SurahInfo(2, "البقرة", "Al-Baqarah", false, 286),
  SurahInfo(3, "آل عمران", "Ali 'Imran", false, 200),
  SurahInfo(4, "النساء", "An-Nisa", false, 176),
  SurahInfo(5, "المائدة", "Al-Ma'idah", false, 120),
  SurahInfo(6, "الأنعام", "Al-An'am", true, 165),
  SurahInfo(7, "الأعراف", "Al-A'raf", true, 206),
  SurahInfo(8, "الأنفال", "Al-Anfal", false, 75),
  SurahInfo(9, "التوبة", "At-Tawbah", false, 129),
  SurahInfo(10, "يونس", "Yunus", true, 109),
  SurahInfo(11, "هود", "Hud", true, 123),
  SurahInfo(12, "يوسف", "Yusuf", true, 111),
  SurahInfo(13, "الرعد", "Ar-Ra'd", false, 43),
  SurahInfo(14, "إبراهيم", "Ibrahim", true, 52),
  SurahInfo(15, "الحجر", "Al-Hijr", true, 99),
  SurahInfo(16, "النحل", "An-Nahl", true, 128),
  SurahInfo(17, "الإسراء", "Al-Isra", true, 111),
  SurahInfo(18, "الكهف", "Al-Kahf", true, 110),
  SurahInfo(19, "مريم", "Maryam", true, 98),
  SurahInfo(20, "طه", "Ta-Ha", true, 135),
  SurahInfo(21, "الأنبياء", "Al-Anbiya", true, 112),
  SurahInfo(22, "الحج", "Al-Hajj", false, 78),
  SurahInfo(23, "المؤمنون", "Al-Mu'minun", true, 118),
  SurahInfo(24, "النور", "An-Nur", false, 64),
  SurahInfo(25, "الفرقان", "Al-Furqan", true, 77),
  SurahInfo(26, "الشعراء", "Ash-Shu'ara", true, 227),
  SurahInfo(27, "النمل", "An-Naml", true, 93),
  SurahInfo(28, "القصص", "Al-Qasas", true, 88),
  SurahInfo(29, "العنكبوت", "Al-'Ankabut", true, 69),
  SurahInfo(30, "الروم", "Ar-Rum", true, 60),
  SurahInfo(31, "لقمان", "Luqman", true, 34),
  SurahInfo(32, "السجدة", "As-Sajdah", true, 30),
  SurahInfo(33, "الأحزاب", "Al-Ahzab", false, 73),
  SurahInfo(34, "سبأ", "Saba", true, 54),
  SurahInfo(35, "فاطر", "Fatir", true, 45),
  SurahInfo(36, "يس", "Ya-Sin", true, 83),
  SurahInfo(37, "الصافات", "As-Saffat", true, 182),
  SurahInfo(38, "ص", "Sad", true, 88),
  SurahInfo(39, "الزمر", "Az-Zumar", true, 75),
  SurahInfo(40, "غافر", "Ghafir", true, 85),
  SurahInfo(41, "فصلت", "Fussilat", true, 54),
  SurahInfo(42, "الشورى", "Ash-Shuraa", true, 53),
  SurahInfo(43, "الزخرف", "Az-Zukhruf", true, 89),
  SurahInfo(44, "الدخان", "Ad-Dukhan", true, 59),
  SurahInfo(45, "الجاثية", "Al-Jathiyah", true, 37),
  SurahInfo(46, "الأحقاف", "Al-Ahqaf", true, 35),
  SurahInfo(47, "محمد", "Muhammad", false, 38),
  SurahInfo(48, "الفتح", "Al-Fath", false, 29),
  SurahInfo(49, "الحجرات", "Al-Hujurat", false, 18),
  SurahInfo(50, "ق", "Qaf", true, 45),
  SurahInfo(51, "الذاريات", "Adh-Dhariyat", true, 60),
  SurahInfo(52, "الطور", "At-Tur", true, 49),
  SurahInfo(53, "النجم", "An-Najm", true, 62),
  SurahInfo(54, "القمر", "Al-Qamar", true, 55),
  SurahInfo(55, "الرحمن", "Ar-Rahman", false, 78),
  SurahInfo(56, "الواقعة", "Al-Waqi'ah", true, 96),
  SurahInfo(57, "الحديد", "Al-Hadid", false, 29),
  SurahInfo(58, "المجادلة", "Al-Mujadila", false, 22),
  SurahInfo(59, "الحشر", "Al-Hashr", false, 24),
  SurahInfo(60, "الممتحنة", "Al-Mumtahanah", false, 13),
  SurahInfo(61, "الصف", "As-Saff", false, 14),
  SurahInfo(62, "الجمعة", "Al-Jumu'ah", false, 11),
  SurahInfo(63, "المنافقون", "Al-Munafiqun", false, 11),
  SurahInfo(64, "التغابن", "At-Taghabun", false, 18),
  SurahInfo(65, "الطلاق", "At-Talaq", false, 12),
  SurahInfo(66, "التحريم", "At-Tahrim", false, 12),
  SurahInfo(67, "الملك", "Al-Mulk", true, 30),
  SurahInfo(68, "القلم", "Al-Qalam", true, 52),
  SurahInfo(69, "الحاقة", "Al-Haqqah", true, 52),
  SurahInfo(70, "المعارج", "Al-Ma'arij", true, 44),
  SurahInfo(71, "نوح", "Nuh", true, 28),
  SurahInfo(72, "الجن", "Al-Jinn", true, 28),
  SurahInfo(73, "المزمل", "Al-Muzzammil", true, 20),
  SurahInfo(74, "المدثر", "Al-Muddaththir", true, 56),
  SurahInfo(75, "القيامة", "Al-Qiyamah", true, 40),
  SurahInfo(76, "الإنسان", "Al-Insan", false, 31),
  SurahInfo(77, "المرسلات", "Al-Mursalat", true, 50),
  SurahInfo(78, "النبأ", "An-Naba", true, 40),
  SurahInfo(79, "النازعات", "An-Nazi'at", true, 46),
  SurahInfo(80, "عبس", "'Abasa", true, 42),
  SurahInfo(81, "التكوير", "At-Takwir", true, 29),
  SurahInfo(82, "الإنفطار", "Al-Infitar", true, 19),
  SurahInfo(83, "المطففين", "Al-Mutaffifin", true, 36),
  SurahInfo(84, "الإنشقاق", "Al-Inshiqaq", true, 25),
  SurahInfo(85, "البروج", "Al-Buruj", true, 22),
  SurahInfo(86, "الطارق", "At-Tariq", true, 17),
  SurahInfo(87, "الأعلى", "Al-A'la", true, 19),
  SurahInfo(88, "الغاشية", "Al-Ghashiyah", true, 26),
  SurahInfo(89, "الفجر", "Al-Fajr", true, 30),
  SurahInfo(90, "البلد", "Al-Balad", true, 20),
  SurahInfo(91, "الشمس", "Ash-Shams", true, 15),
  SurahInfo(92, "الليل", "Al-Layl", true, 21),
  SurahInfo(93, "الضحى", "Ad-Duha", true, 11),
  SurahInfo(94, "الشرح", "Ash-Sharh", true, 8),
  SurahInfo(95, "التين", "At-Tin", true, 8),
  SurahInfo(96, "العلق", "Al-'Alaq", true, 19),
  SurahInfo(97, "القدر", "Al-Qadr", true, 5),
  SurahInfo(98, "البينة", "Al-Bayyinah", false, 8),
  SurahInfo(99, "الزلزلة", "Az-Zalzalah", false, 8),
  SurahInfo(100, "العاديات", "Al-'Adiyat", true, 11),
  SurahInfo(101, "القارعة", "Al-Qari'ah", true, 11),
  SurahInfo(102, "التكاثر", "At-Takathur", true, 8),
  SurahInfo(103, "العصر", "Al-'Asr", true, 3),
  SurahInfo(104, "الهمزة", "Al-Humazah", true, 9),
  SurahInfo(105, "الفيل", "Al-Fil", true, 5),
  SurahInfo(106, "قريش", "Quraysh", true, 4),
  SurahInfo(107, "الماعون", "Al-Ma'un", true, 7),
  SurahInfo(108, "الكوثر", "Al-Kawthar", true, 3),
  SurahInfo(109, "الكافرون", "Al-Kafirun", true, 6),
  SurahInfo(110, "النصر", "An-Nasr", false, 3),
  SurahInfo(111, "المسد", "Al-Masad", true, 5),
  SurahInfo(112, "الإخلاص", "Al-Ikhlas", true, 4),
  SurahInfo(113, "الفلق", "Al-Falaq", true, 5),
  SurahInfo(114, "الناس", "An-Nas", true, 6),
];


// ============================================================
//  Reciters + audio (audio streamed from everyayah.com)
// ============================================================
const List<List<String>> kReciters = [
  ['Alafasy_128kbps', 'مشاری العفاسی'],
  ['Abdul_Basit_Murattal_192kbps', 'عبدالباسط عبدالصمد'],
  ['Abdurrahmaan_As-Sudais_192kbps', 'عبدالرحمن السدیس'],
  ['MaherAlMuaiqly128kbps', 'ماهر المعیقلی'],
  ['Saood_ash-Shuraym_128kbps', 'سعود الشریم'],
  ['Minshawy_Murattal_128kbps', 'محمد صدیق المنشاوی'],
  ['Husary_128kbps', 'محمود خلیل الحصری'],
  ['Abu_Bakr_Ash-Shaatree_128kbps', 'أبو بكر الشاطري'],
  ['Ahmed_ibn_Ali_al_Ajamy_128kbps_ketaballah.net', 'أحمد العجمي'],
];

List<List<String>> allReciters() => [...kReciters, ...settings.custom];

String reciterName() {
  for (final r in allReciters()) {
    if (r[0] == settings.rec) return r[1];
  }
  return settings.rec;
}

class AudioCtl extends ChangeNotifier {
  final AudioPlayer _p = AudioPlayer();
  int surah = 0;
  int ayah = 0;
  bool all = false;
  bool playing = false;
  bool error = false;

  AudioCtl() {
    _p.onPlayerComplete.listen((_) {
      if (all && surah != 0 && ayah < kSurahs[surah - 1].count) {
        play(surah, ayah + 1, all: true);
      } else {
        stop();
      }
    });
    _p.onPlayerStateChanged.listen((s) {
      playing = s == PlayerState.playing;
      notifyListeners();
    });
  }

  String _url(int s, int a) =>
      'https://everyayah.com/data/${settings.rec}/${s.toString().padLeft(3, '0')}${a.toString().padLeft(3, '0')}.mp3';

  Future<void> play(int s, int a, {bool all = false}) async {
    surah = s;
    ayah = a;
    this.all = all;
    error = false;
    notifyListeners();
    try {
      await _p.play(UrlSource(_url(s, a)));
    } catch (_) {
      error = true;
      notifyListeners();
    }
  }

  Future<void> toggle() async {
    if (playing) {
      await _p.pause();
    } else {
      await _p.resume();
    }
  }

  void next() {
    if (surah != 0 && ayah < kSurahs[surah - 1].count) {
      play(surah, ayah + 1, all: all);
    }
  }

  void prev() {
    if (surah != 0 && ayah > 1) play(surah, ayah - 1, all: all);
  }

  Future<void> stop() async {
    try {
      await _p.stop();
    } catch (_) {}
    surah = 0;
    ayah = 0;
    all = false;
    playing = false;
    error = false;
    notifyListeners();
  }
}

final AudioCtl audio = AudioCtl();

class PlayerBar extends StatelessWidget {
  final bool openSettings;
  const PlayerBar({super.key, this.openSettings = true});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([audio, settings]),
      builder: (context, _) {
        if (audio.surah == 0) return const SizedBox.shrink();
        final info = kSurahs[audio.surah - 1];
        return Material(
          color: _green,
          child: SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              child: Row(
                children: [
                  Expanded(
                    child: InkWell(
                      onTap: openSettings
                          ? () => Navigator.of(context).push(
                                MaterialPageRoute<void>(
                                    builder: (_) => const SettingsPage()),
                              )
                          : null,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            '${info.ar} • ئایەتی ${audio.ayah}',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                              fontFamilyFallback: _arFonts,
                            ),
                          ),
                          Text(
                            audio.error
                                ? 'دەنگەکە نەکرایەوە. ئینتەرنێت بپشکنە'
                                : reciterName(),
                            style: const TextStyle(
                                color: Color(0xCCFFFFFF), fontSize: 12.5),
                          ),
                        ],
                      ),
                    ),
                  ),
                  Directionality(
                    textDirection: TextDirection.ltr,
                    child: Row(
                      children: [
                        IconButton(
                          color: Colors.white,
                          onPressed: audio.prev,
                          icon: const Icon(Icons.skip_previous),
                        ),
                        IconButton(
                          color: Colors.white,
                          onPressed: audio.toggle,
                          icon: Icon(
                              audio.playing ? Icons.pause : Icons.play_arrow),
                        ),
                        IconButton(
                          color: Colors.white,
                          onPressed: audio.next,
                          icon: const Icon(Icons.skip_next),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    color: Colors.white,
                    onPressed: audio.stop,
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _PlayAllButton extends StatelessWidget {
  final int n;
  const _PlayAllButton(this.n);

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: audio,
      builder: (context, _) {
        final on = audio.surah == n && audio.all;
        return FilledButton.icon(
          style: FilledButton.styleFrom(
            backgroundColor: const Color(0xFFF0C14B),
            foregroundColor: const Color(0xFF1B2A1F),
          ),
          onPressed: () => on ? audio.toggle() : audio.play(n, 1, all: true),
          icon: Icon(on && audio.playing ? Icons.pause : Icons.play_arrow),
          label: Text(on && audio.playing ? 'ڕاگرتن' : 'گوێگرتن'),
        );
      },
    );
  }
}

// ---------- settings page ----------
class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  final TextEditingController _name = TextEditingController();
  final TextEditingController _folder = TextEditingController();
  String _msg = '';

  @override
  void dispose() {
    _name.dispose();
    _folder.dispose();
    super.dispose();
  }

  void _select(String f) {
    settings.setRec(f);
    if (audio.surah != 0) audio.play(audio.surah, audio.ayah, all: audio.all);
  }

  void _add() {
    final n = _name.text.trim();
    final f = _folder.text.trim();
    if (n.isEmpty || !RegExp(r'^[\w.\-]+$').hasMatch(f)) {
      setState(() => _msg = 'ناو و ناوی فۆڵدەر بە پیتی لاتینی بنووسە.');
      return;
    }
    if (allReciters().any((r) => r[0] == f)) {
      setState(() => _msg = 'ئەم فۆڵدەرە پێشتر زیاد کراوە.');
      return;
    }
    settings.addReciter(f, n);
    _name.clear();
    _folder.clear();
    setState(() => _msg = '');
    if (audio.surah != 0) audio.play(audio.surah, audio.ayah, all: audio.all);
  }

  Widget _head(String t) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 22, 4, 6),
        child: Text(
          t,
          style: const TextStyle(
              fontSize: 17, fontWeight: FontWeight.bold, color: _gold),
        ),
      );

  Widget _opt(BuildContext c, String label, bool on, VoidCallback tap,
      {Widget? trailing, bool arabic = false}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Material(
        color: _cardColor(c),
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: BorderSide(color: on ? _gold : _lineColor(c)),
        ),
        child: ListTile(
          onTap: tap,
          leading: Icon(
              on ? Icons.radio_button_checked : Icons.radio_button_off,
              color: _gold),
          title: Text(
            label,
            style: TextStyle(
              fontSize: arabic ? 19 : 16,
              color: _inkColor(c),
              fontFamilyFallback: _arFonts,
            ),
          ),
          trailing: trailing,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: settings,
      builder: (context, _) {
        return Scaffold(
          bottomNavigationBar: const PlayerBar(openSettings: false),
          appBar: AppBar(
            title: const Text('ڕێکخستنەکان',
                style: TextStyle(fontWeight: FontWeight.bold)),
          ),
          body: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 820),
              child: ListView(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 32),
                children: [
                  _head('قورئان خوێن'),
                  for (final r in allReciters())
                    _opt(
                      context,
                      r[1],
                      settings.rec == r[0],
                      () => _select(r[0]),
                      arabic: true,
                      trailing: settings.custom.any((x) => x[0] == r[0])
                          ? IconButton(
                              onPressed: () => settings.removeReciter(r[0]),
                              icon: const Icon(Icons.close),
                            )
                          : null,
                    ),
                  _head('زیادکردنی قورئان خوێن'),
                  Text(
                    'ناوی قورئان خوێنەکە و ناوی فۆڵدەری دەنگەکانی لە everyayah.com بنووسە (بۆ نموونە Alafasy_128kbps).',
                    style: TextStyle(
                        fontSize: 13, height: 1.7, color: _mutedColor(context)),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: _name,
                    decoration: const InputDecoration(
                        labelText: 'ناو', border: OutlineInputBorder()),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: _folder,
                    textDirection: TextDirection.ltr,
                    autocorrect: false,
                    decoration: const InputDecoration(
                        labelText: 'Folder', border: OutlineInputBorder()),
                  ),
                  if (_msg.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(_msg,
                          style: const TextStyle(color: Colors.redAccent)),
                    ),
                  const SizedBox(height: 10),
                  FilledButton(
                    onPressed: _add,
                    style: FilledButton.styleFrom(backgroundColor: _green),
                    child: const Text('زیادکردن'),
                  ),
                  _head('پیشاندان'),
                  for (final t in kTrOptions)
                    _opt(context, _trLabels[t] ?? '', settings.tr == t,
                        () => settings.setTr(t)),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: Text('قەبارەی نووسین',
                            style: TextStyle(
                                fontSize: 16, color: _inkColor(context))),
                      ),
                      IconButton(
                          onPressed: settings.smaller,
                          icon: const Icon(Icons.remove_circle_outline)),
                      Text('${settings.arabicSize.round()}',
                          style: TextStyle(
                              fontSize: 16, color: _inkColor(context))),
                      IconButton(
                          onPressed: settings.bigger,
                          icon: const Icon(Icons.add_circle_outline)),
                    ],
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('دۆخی تاریک'),
                    value: settings.dark,
                    onChanged: (_) => settings.toggleDark(),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
