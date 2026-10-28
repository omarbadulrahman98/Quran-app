// قورئانی پیرۆز - Flutter project (data from assets/quran/*.json)
import 'dart:convert';

import 'package:flutter/material.dart';
import 'dart:async';

import 'package:just_audio/just_audio.dart';
import 'package:just_audio_background/just_audio_background.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';
import 'package:flutter/foundation.dart' show compute;
import 'package:flutter/services.dart' show rootBundle;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:speech_to_text/speech_recognition_error.dart'
    show SpeechRecognitionError;
import 'package:speech_to_text/speech_recognition_result.dart'
    show SpeechRecognitionResult;
import 'package:speech_to_text/speech_to_text.dart' as stt;
import 'package:recite_quran/recite_quran.dart' as rq;

// ============================================================
//  قورئانی پیرۆز - Quran + Kurdish tafseer
//  (UI part - identical in the DartPad and the Flutter project)
// ============================================================

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    await JustAudioBackground.init(
      androidNotificationChannelId: 'com.quran.kurdish.audio',
      androidNotificationChannelName: 'Quran audio',
      androidNotificationOngoing: true,
    );
  } catch (_) {}
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
  List<String> marks = [];
  int lastSurah = 0;
  int lastAyah = 0;
  int coachLevel = 1; // 0 lenient, 1 normal, 2 strict, 3 letter-by-letter
  final ValueNotifier<int> lastTick = ValueNotifier<int>(0);

  Future<void> load() async {
    try {
      final p = await SharedPreferences.getInstance();
      dark = p.getBool('dark') ?? false;
      arabicSize = p.getDouble('size') ?? 28;
      final ti = p.getInt('tr') ?? 0;
      if (ti >= 0 && ti < Tr.values.length) tr = Tr.values[ti];
      rec = p.getString('rec') ?? rec;
      marks = p.getStringList('marks') ?? [];
      lastSurah = p.getInt('lastS') ?? 0;
      lastAyah = p.getInt('lastA') ?? 0;
      coachLevel = (p.getInt('coachLvl') ?? 1).clamp(0, 5).toInt();
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
      await p.setStringList('marks', marks);
      await p.setInt('coachLvl', coachLevel);
    } catch (_) {}
  }

  @override
  void notifyListeners() {
    super.notifyListeners();
    _save();
  }

  bool isMarked(int s, int a) => marks.contains('$s:$a');

  void toggleMark(int s, int a) {
    final k = '$s:$a';
    marks = marks.contains(k)
        ? marks.where((m) => m != k).toList()
        : [...marks, k];
    notifyListeners();
  }

  void setLast(int s, int a) {
    if (s == lastSurah && a == lastAyah) return;
    lastSurah = s;
    lastAyah = a;
    lastTick.value++;
    _saveLast();
  }

  Future<void> _saveLast() async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setInt('lastS', lastSurah);
      await p.setInt('lastA', lastAyah);
    } catch (_) {}
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

  void setCoachLevel(int l) {
    coachLevel = l.clamp(0, 5).toInt();
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
        scaffoldMessengerKey: appMessenger,
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
                tooltip: 'گەڕان لە ئایەتەکان',
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(builder: (_) => const SearchPage()),
                ),
                icon: const Icon(Icons.manage_search),
              ),
              IconButton(
                tooltip: 'نیشانەکان',
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(builder: (_) => const BookmarksPage()),
                ),
                icon: const Icon(Icons.bookmarks),
              ),
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
                  const _ContinueCard(),
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
  final int initialAyah;
  const SurahPage({super.key, required this.number, this.initialAyah = 0});

  @override
  State<SurahPage> createState() => _SurahPageState();
}

class _SurahPageState extends State<SurahPage> {
  late final Future<List<Ayah>> _future;
  final ItemScrollController _sc = ItemScrollController();
  final ItemPositionsListener _pl = ItemPositionsListener.create();
  Timer? _t;
  List<Ayah>? _ayahs;
  int _followed = 0;
  int _coachFollowed = 0;

  @override
  void initState() {
    super.initState();
    _future = loadSurah(widget.number);
    _pl.itemPositions.addListener(_onPos);
    audio.addListener(_follow);
    coach.addListener(_coachFollow);
  }

  @override
  void dispose() {
    _t?.cancel();
    _pl.itemPositions.removeListener(_onPos);
    audio.removeListener(_follow);
    coach.removeListener(_coachFollow);
    coach.detach(widget.number); // leaving the page switches the mic off
    super.dispose();
  }

  // keep the ayah being recited in view
  void _coachFollow() {
    if (!coach.on || coach.surah != widget.number || !_sc.isAttached) return;
    final a = coach.cursorAyah;
    if (a < 1 || a == _coachFollowed) return;
    _coachFollowed = a;
    _sc.scrollTo(
      index: a + 1,
      alignment: 0.05,
      duration: const Duration(milliseconds: 400),
    );
  }

  void _turnCoachOn() {
    final ay = _ayahs;
    if (ay == null) {
      appMessenger.currentState?.showSnackBar(
        const SnackBar(content: Text('چاوەڕێ بکە تا سوورەتەکە بار دەبێت')),
      );
      return;
    }
    _coachFollowed = 0;
    final hint = (settings.lastSurah == widget.number && settings.lastAyah > 0)
        ? settings.lastAyah
        : (widget.initialAyah > 0 ? widget.initialAyah : 1);
    coach.start(widget.number, ay, hintAyah: hint);
  }

  void _onPos() {
    _t?.cancel();
    _t = Timer(const Duration(milliseconds: 700), () {
      final ay = _ayahs;
      if (ay == null || ay.isEmpty) return;
      int? first;
      for (final p in _pl.itemPositions.value) {
        if (p.index >= 2 && p.index - 2 < ay.length && p.itemTrailingEdge > 0.05) {
          if (first == null || p.index < first) first = p.index;
        }
      }
      if (first != null) settings.setLast(widget.number, ay[first - 2].n);
    });
  }

  void _follow() {
    if (audio.surah == widget.number &&
        audio.all &&
        audio.ayah != _followed &&
        _sc.isAttached) {
      _followed = audio.ayah;
      _sc.scrollTo(
        index: audio.ayah + 1,
        alignment: 0.05,
        duration: const Duration(milliseconds: 400),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final info = kSurahs[widget.number - 1];
    return ListenableBuilder(
      listenable: settings,
      builder: (context, _) {
        return Scaffold(
          bottomNavigationBar: const Column(
            mainAxisSize: MainAxisSize.min,
            children: [_CoachPanel(), PlayerBar()],
          ),
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
              // recitation coach switch, right next to the Settings icon
              _CoachToggle(onTurnOn: _turnCoachOn),
              IconButton(
                tooltip: 'ڕێکخستنەکان',
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(builder: (_) => const SettingsPage()),
                ),
                icon: const Icon(Icons.settings),
              ),
              TextButton(
                style: _abBtn,
                onPressed: settings.bigger,
                child: const Text('A+', style: _abStyle),
              ),
              TextButton(
                style: _abBtn,
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
              _ayahs = ayahs;
              final showBismillah = info.n != 1 && info.n != 9;
              final start = widget.initialAyah > 0
                  ? (widget.initialAyah + 1).clamp(0, ayahs.length + 2).toInt()
                  : 0;
              return SelectionArea(
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 820),
                    child: ScrollablePositionedList.builder(
                      itemScrollController: _sc,
                      itemPositionsListener: _pl,
                      initialScrollIndex: start,
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

final ButtonStyle _abBtn = TextButton.styleFrom(
  minimumSize: const Size(36, 40),
  padding: const EdgeInsets.symmetric(horizontal: 6),
);

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
                    tooltip: 'نیشانەکردن',
                    onPressed: () => settings.toggleMark(surah, a.n),
                    icon: Icon(
                      settings.isMarked(surah, a.n)
                          ? Icons.bookmark
                          : Icons.bookmark_border,
                      color: _gold,
                      size: 28,
                    ),
                  ),
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
          _AyahArabic(a, surah),
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

Future<Map<String, dynamic>> loadAll() async {
  final cached = _all;
  if (cached != null) return cached;
  final txt = await rootBundle.loadString('quran.json');
  final m = await compute(_parseAll, txt);
  _all = m;
  return m;
}

Ayah _ayahFrom(Map<String, dynamic> m) => Ayah(
      m['n'] as int,
      m['ar'] as String,
      m['puxt'] as String?,
      m['asan'] as String?,
      m['en'] as String?,
    );

Future<List<Ayah>> loadSurah(int n) async {
  final hit = _cache[n];
  if (hit != null) return hit;
  final all = await loadAll();
  final list = (all['$n'] as List<dynamic>)
      .map((e) => _ayahFrom(e as Map<String, dynamic>))
      .toList();
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
  bool correcting = false; // playing a coach correction (always Alafasy)
  int _base = 1;

  AudioCtl() {
    _p.playerStateStream.listen((s) {
      if (s.processingState == ProcessingState.completed) {
        stop();
        return;
      }
      playing = s.playing;
      notifyListeners();
    });
    _p.currentIndexStream.listen((i) {
      if (i != null && surah != 0) {
        ayah = _base + i;
        notifyListeners();
      }
    });
    _p.playbackEventStream.listen((_) {}, onError: (Object e, StackTrace st) {
      error = true;
      notifyListeners();
    });
  }

  String _url(int s, int a) =>
      'https://everyayah.com/data/${settings.rec}/${s.toString().padLeft(3, '0')}${a.toString().padLeft(3, '0')}.mp3';

  Future<void> play(int s, int a, {bool all = false}) async {
    surah = s;
    ayah = a;
    this.all = all;
    _base = a;
    error = false;
    correcting = false;
    notifyListeners();
    try {
      final last = all ? kSurahs[s - 1].count : a;
      final items = <AudioSource>[
        for (var i = a; i <= last; i++)
          AudioSource.uri(
            Uri.parse(_url(s, i)),
            tag: MediaItem(
              id: '$s:$i',
              title: '${kSurahs[s - 1].ar} • $i',
              artist: reciterName(),
            ),
          ),
      ];
      await _p.setAudioSource(ConcatenatingAudioSource(children: items));
      _p.play().catchError((Object _) {
        error = true;
        notifyListeners();
      });
    } catch (_) {
      error = true;
      notifyListeners();
    }
  }

  /// One ayah in Mishary Alafasy's voice, used by the recitation coach.
  Future<void> playCorrection(int s, int a, {double from = 0}) async {
    surah = s;
    ayah = a;
    all = false;
    _base = a;
    error = false;
    correcting = true;
    notifyListeners();
    try {
      final url =
          'https://everyayah.com/data/$kCoachReciter/${s.toString().padLeft(3, '0')}${a.toString().padLeft(3, '0')}.mp3';
      final dur = await _p.setAudioSource(ConcatenatingAudioSource(children: [
        AudioSource.uri(
          Uri.parse(url),
          tag: MediaItem(
            id: '$s:$a',
            title: '${kSurahs[s - 1].ar} • $a',
            artist: 'مشاری العفاسی',
          ),
        ),
      ]));
      // start a little before the wrong word (estimated from letter count)
      if (from > 0 && dur != null) {
        final ms = (dur.inMilliseconds * from).round() - 500;
        if (ms > 0) await _p.seek(Duration(milliseconds: ms));
      }
      _p.play().catchError((Object _) {
        error = true;
        notifyListeners();
      });
    } catch (_) {
      error = true;
      notifyListeners();
    }
  }

  /// One isolated word (quran.com word-by-word audio): a tiny file that
  /// starts playing almost at once. Falls back to the ayah if it cannot load.
  Future<void> playWord(int s, int a, int pos, {double fallbackFrom = 0}) async {
    surah = s;
    ayah = a;
    all = false;
    _base = a;
    error = false;
    correcting = true;
    notifyListeners();
    try {
      String n3(int v) => v.toString().padLeft(3, '0');
      final url = 'https://audio.qurancdn.com/wbw/${n3(s)}_${n3(a)}_${n3(pos)}.mp3';
      await _p.setAudioSource(ConcatenatingAudioSource(children: [
        AudioSource.uri(
          Uri.parse(url),
          tag: MediaItem(
            id: 'w$s:$a:$pos',
            title: '${kSurahs[s - 1].ar} • $a',
            artist: 'وشە',
          ),
        ),
      ]));
      _p.play().catchError((Object _) {
        error = true;
        notifyListeners();
      });
    } catch (_) {
      await playCorrection(s, a, from: fallbackFrom);
    }
  }

  String reciterLabel() => correcting ? 'مشاری العفاسی • ڕاستکردنەوە' : reciterName();

  Future<void> toggle() async {
    if (_p.playing) {
      await _p.pause();
    } else {
      _p.play().catchError((Object _) {});
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
    surah = 0;
    ayah = 0;
    all = false;
    playing = false;
    error = false;
    correcting = false;
    notifyListeners();
    try {
      await _p.stop();
    } catch (_) {}
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
                                : audio.reciterLabel(),
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
                  _head('ڕاستکردنەوەی خوێندنەوە بە دەنگ'),
                  Text(
                    'لە لاپەڕەی سوورەت، دوگمەی مایکرۆفۆن (لای ئایکۆنی ڕێکخستن) هەڵبکە. ئەپەکە گوێ لە خوێندنەوەکەت دەگرێت و ئەگەر هەڵەت بکرد، ئایەتەکە بە دەنگی مشاری العفاسی دەلێتەوە. ناسینەوەی دەنگی عەرەبی گووگڵ بەکاردێت و ئینتەرنێتی دەوێت. لە دۆخی «پیت بە پیت» پیتە هەڵەکان بە سوور لەناو وشەکە دەردەکەون و تەنها لە دوو وشە پێش هەڵەکە دووبارە دەکرێتەوە. هەستیاری:',
                    style: TextStyle(
                        fontSize: 13, height: 1.7, color: _mutedColor(context)),
                  ),
                  const SizedBox(height: 6),
                  for (var i = 0; i < kCoachLevels.length; i++)
                    _opt(context, kCoachLevels[i], settings.coachLevel == i,
                        () => settings.setCoachLevel(i)),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}


// ============================================================
//  Continue reading / bookmarks / search
// ============================================================
class _ContinueCard extends StatelessWidget {
  const _ContinueCard();

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<int>(
      valueListenable: settings.lastTick,
      builder: (context, _, __) {
        final s = settings.lastSurah;
        if (s < 1 || s > 114) return const SizedBox.shrink();
        final info = kSurahs[s - 1];
        return Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
          child: Material(
            color: _green,
            borderRadius: BorderRadius.circular(14),
            child: InkWell(
              borderRadius: BorderRadius.circular(14),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) =>
                      SurahPage(number: s, initialAyah: settings.lastAyah),
                ),
              ),
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                child: Row(
                  children: [
                    const Icon(Icons.menu_book, color: Color(0xFFF0C14B)),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'بەردەوامبوون لە خوێندنەوە',
                            style: TextStyle(
                                color: Color(0xCCFFFFFF), fontSize: 12.5),
                          ),
                          Text(
                            '${info.ar} • ئایەتی ${settings.lastAyah}',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 19,
                              fontWeight: FontWeight.bold,
                              fontFamilyFallback: _arFonts,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const Icon(Icons.arrow_back, color: Colors.white),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class BookmarksPage extends StatelessWidget {
  const BookmarksPage({super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: settings,
      builder: (context, _) {
        final items = settings.marks.reversed.toList();
        return Scaffold(
          bottomNavigationBar: const PlayerBar(),
          appBar: AppBar(
            title: const Text('نیشانەکان',
                style: TextStyle(fontWeight: FontWeight.bold)),
          ),
          body: items.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      'هێشتا هیچ ئایەتێکت نیشان نەکردووە. لە ناو سوورەت، دوگمەی نیشانە لەسەر ئایەتێک دابگرە.',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                          fontSize: 15, height: 1.8, color: _mutedColor(context)),
                    ),
                  ),
                )
              : Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 820),
                    child: ListView.builder(
                      padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
                      itemCount: items.length,
                      itemBuilder: (context, i) => _BookmarkTile(items[i]),
                    ),
                  ),
                ),
        );
      },
    );
  }
}

class _BookmarkTile extends StatelessWidget {
  final String k;
  const _BookmarkTile(this.k);

  @override
  Widget build(BuildContext context) {
    final parts = k.split(':');
    final s = (int.tryParse(parts[0]) ?? 1).clamp(1, 114).toInt();
    final a = int.tryParse(parts.length > 1 ? parts[1] : '1') ?? 1;
    final info = kSurahs[s - 1];
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Material(
        color: _cardColor(context),
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: BorderSide(color: _lineColor(context)),
        ),
        child: InkWell(
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => SurahPage(number: s, initialAyah: a),
            ),
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 10, 6, 10),
            child: Row(
              children: [
                Expanded(
                  child: FutureBuilder<List<Ayah>>(
                    future: loadSurah(s),
                    builder: (context, snap) {
                      Ayah? ay;
                      final list = snap.data;
                      if (list != null) {
                        for (final x in list) {
                          if (x.n == a) ay = x;
                        }
                      }
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '${info.ar} • ئایەتی $a',
                            style: const TextStyle(
                              fontSize: 18,
                              color: _gold,
                              fontWeight: FontWeight.bold,
                              fontFamilyFallback: _arFonts,
                            ),
                          ),
                          if (ay != null) ...[
                            const SizedBox(height: 6),
                            Text(
                              ay.ar,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              textDirection: TextDirection.rtl,
                              style: TextStyle(
                                fontSize: 20,
                                height: 1.8,
                                color: _inkColor(context),
                                fontFamilyFallback: _arFonts,
                              ),
                            ),
                            if ((ay.puxt ?? '').isNotEmpty)
                              Text(
                                ay.puxt!,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 14,
                                  height: 1.6,
                                  color: _mutedColor(context),
                                ),
                              ),
                          ],
                        ],
                      );
                    },
                  ),
                ),
                IconButton(
                  tooltip: 'سڕینەوە',
                  onPressed: () => settings.toggleMark(s, a),
                  icon: const Icon(Icons.delete_outline),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ---------- search ----------
final RegExp _diac = RegExp('[\u064B-\u065F\u0670\u06D6-\u06ED\u0640]');
final RegExp _alefs = RegExp('[\u0622\u0623\u0625\u0671]');

String _norm(String s) {
  var t = s.replaceAll(_diac, '').replaceAll(_alefs, '\u0627');
  t = t
      .replaceAll('\u0649', '\u06CC')
      .replaceAll('\u064A', '\u06CC')
      .replaceAll('\u0643', '\u06A9')
      .replaceAll('\u0629', '\u0647')
      .replaceAll('\u06D5', '\u0647');
  return t.toLowerCase();
}

List<String> _buildIndex(Map<String, dynamic> all) {
  final out = <String>[];
  for (var n = 1; n <= 114; n++) {
    final l = all['$n'] as List<dynamic>;
    for (final e in l) {
      final m = e as Map<String, dynamic>;
      out.add(_norm(
          '${m['ar'] ?? ''} ${m['puxt'] ?? ''} ${m['asan'] ?? ''} ${m['en'] ?? ''}'));
    }
  }
  return out;
}

class SearchPage extends StatefulWidget {
  const SearchPage({super.key});

  @override
  State<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends State<SearchPage> {
  final TextEditingController _c = TextEditingController();
  List<String> _index = [];
  final List<List<int>> _pos = [];
  List<List<int>> _res = [];
  bool _loading = true;
  String _q = '';
  Timer? _t;

  @override
  void initState() {
    super.initState();
    _init();
  }

  @override
  void dispose() {
    _t?.cancel();
    _c.dispose();
    super.dispose();
  }

  Future<void> _init() async {
    final all = await loadAll();
    final idx = await compute(_buildIndex, all);
    for (var n = 1; n <= 114; n++) {
      final c = (all['$n'] as List<dynamic>).length;
      for (var i = 0; i < c; i++) {
        _pos.add([n, i]);
      }
    }
    if (!mounted) return;
    setState(() {
      _index = idx;
      _loading = false;
    });
    if (_c.text.trim().length >= 2) _run(_c.text);
  }

  void _onChanged(String v) {
    _t?.cancel();
    _t = Timer(const Duration(milliseconds: 300), () => _run(v));
  }

  void _run(String v) {
    final q = _norm(v.trim());
    final out = <List<int>>[];
    if (q.length >= 2) {
      for (var i = 0; i < _index.length && out.length < 80; i++) {
        if (_index[i].contains(q)) out.add(_pos[i]);
      }
    }
    setState(() {
      _q = q;
      _res = out;
    });
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: settings,
      builder: (context, _) {
        final tr = settings.tr == Tr.none ? Tr.puxt : settings.tr;
        return Scaffold(
          bottomNavigationBar: const PlayerBar(),
          appBar: AppBar(
            title: const Text('گەڕان لە ئایەتەکان',
                style: TextStyle(fontWeight: FontWeight.bold)),
          ),
          body: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 820),
              child: Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
                    child: TextField(
                      controller: _c,
                      autofocus: true,
                      onChanged: _onChanged,
                      decoration: InputDecoration(
                        hintText: 'وشەیەک بنووسە (کوردی، عەرەبی، English)...',
                        prefixIcon: const Icon(Icons.search),
                        filled: true,
                        fillColor: _cardColor(context),
                        contentPadding: const EdgeInsets.symmetric(vertical: 12),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(14),
                          borderSide: BorderSide(color: _lineColor(context)),
                        ),
                      ),
                    ),
                  ),
                  if (_loading)
                    const Padding(
                      padding: EdgeInsets.all(28),
                      child: CircularProgressIndicator(),
                    )
                  else if (_q.length >= 2 && _res.isEmpty)
                    Padding(
                      padding: const EdgeInsets.all(28),
                      child: Text('هیچ ئایەتێک نەدۆزرایەوە',
                          style: TextStyle(color: _mutedColor(context))),
                    )
                  else
                    Expanded(
                      child: ListView.builder(
                        padding: const EdgeInsets.fromLTRB(12, 4, 12, 24),
                        itemCount: _res.length,
                        itemBuilder: (context, i) {
                          final s = _res[i][0];
                          final ay = _ayahFrom(
                              (_all![ '$s' ] as List<dynamic>)[_res[i][1]]
                                  as Map<String, dynamic>);
                          final info = kSurahs[s - 1];
                          final t = ay.tr(tr) ?? '';
                          return Padding(
                            padding: const EdgeInsets.symmetric(vertical: 4),
                            child: Material(
                              color: _cardColor(context),
                              clipBehavior: Clip.antiAlias,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(14),
                                side: BorderSide(color: _lineColor(context)),
                              ),
                              child: InkWell(
                                onTap: () => Navigator.of(context).push(
                                  MaterialPageRoute<void>(
                                    builder: (_) => SurahPage(
                                        number: s, initialAyah: ay.n),
                                  ),
                                ),
                                child: Padding(
                                  padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        '${info.ar} • ئایەتی ${ay.n}',
                                        style: const TextStyle(
                                          fontSize: 17,
                                          color: _gold,
                                          fontWeight: FontWeight.bold,
                                          fontFamilyFallback: _arFonts,
                                        ),
                                      ),
                                      const SizedBox(height: 6),
                                      Text(
                                        ay.ar,
                                        maxLines: 2,
                                        overflow: TextOverflow.ellipsis,
                                        textDirection: TextDirection.rtl,
                                        style: TextStyle(
                                          fontSize: 20,
                                          height: 1.8,
                                          color: _inkColor(context),
                                          fontFamilyFallback: _arFonts,
                                        ),
                                      ),
                                      if (t.isNotEmpty)
                                        Text(
                                          t,
                                          maxLines: 3,
                                          overflow: TextOverflow.ellipsis,
                                          textDirection: tr == Tr.en
                                              ? TextDirection.ltr
                                              : TextDirection.rtl,
                                          style: TextStyle(
                                            fontSize: 14,
                                            height: 1.6,
                                            color: _mutedColor(context),
                                          ),
                                        ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          );
                        },
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


// ============================================================
//  Recitation coach (1/2) - pure logic: normalise, match, align
// ============================================================
const Map<int, int> _arFold = {
  0x0622: 0x0627, 0x0623: 0x0627, 0x0625: 0x0627, 0x0671: 0x0627, // آ أ إ ٱ -> ا
  0x0672: 0x0627, 0x0673: 0x0627,
  0x0649: 0x064A, 0x06CC: 0x064A, 0x0626: 0x064A, // ى ی ئ -> ي
  0x0624: 0x0648, // ؤ -> و
  0x0629: 0x0647, 0x06D5: 0x0647, // ة ە -> ه
  0x06A9: 0x0643, // ک -> ك
};
final RegExp _arStrip = RegExp(
    '[ؐ-ًؚ-ٰٟۖ-ۭـ࣓-ࣿ​-‏]');
final RegExp _arMatres = RegExp('[اوي]');

/// Letters only: no harakat / Quranic marks, alef-forms, ya-forms, hamza folded.
String _arNorm(String s) {
  final sb = StringBuffer();
  for (final r in s.replaceAll(_arStrip, '').runes) {
    if (r == 0x0621) continue; // standalone hamza
    final f = _arFold[r] ?? r;
    if (f >= 0x0621 && f <= 0x064A) sb.writeCharCode(f);
  }
  return sb.toString();
}

int _lev(String a, String b) {
  if (a == b) return 0;
  if (a.isEmpty) return b.length;
  if (b.isEmpty) return a.length;
  var prev = List<int>.generate(b.length + 1, (i) => i);
  var cur = List<int>.filled(b.length + 1, 0);
  for (var i = 1; i <= a.length; i++) {
    cur[0] = i;
    for (var j = 1; j <= b.length; j++) {
      final c = a.codeUnitAt(i - 1) == b.codeUnitAt(j - 1) ? 0 : 1;
      var v = cur[j - 1] + 1;
      if (prev[j] + 1 < v) v = prev[j] + 1;
      if (prev[j - 1] + c < v) v = prev[j - 1] + c;
      cur[j] = v;
    }
    final t = prev;
    prev = cur;
    cur = t;
  }
  return prev[b.length];
}

double _sim(String a, String b) {
  final m = a.length > b.length ? a.length : b.length;
  if (m == 0) return 0;
  return 1 - _lev(a, b) / m;
}

/// Tolerant word comparison (speech recognisers spell Arabic differently
/// from the Uthmani script, e.g. العالمين / العلمين).
bool _sameWord(String h, String e, double thr) {
  if (h.isEmpty || e.isEmpty) return false;
  if (h == e) return true;
  final sh = h.replaceAll(_arMatres, '');
  final se = e.replaceAll(_arMatres, '');
  if (sh.length >= 2 && sh == se) return true;
  final m = h.length > e.length ? h.length : e.length;
  if (m <= 2) return false;
  if ((h.length - e.length).abs() > m * (1 - thr)) return false;
  return 1 - _lev(h, e) / m >= thr;
}

class AlignEvent {
  final int g; // global word index of the mistake
  final bool skipped; // true: word(s) left out, false: wrong word
  final String heard;
  final String expected; // normalised expected word
  const AlignEvent(this.g, this.skipped, this.heard, [this.expected = '']);
}

/// Which letters of the expected word were read wrongly (letter-by-letter).
class LetterDiff {
  final Set<int> bad; // indexes into the normalised expected word
  final List<String> notes; // Kurdish explanation, one line per letter
  const LetterDiff(this.bad, this.notes);
}

bool _isMatres(String ch) => ch == 'ا' || ch == 'و' || ch == 'ي';

/// Compares the heard word with the expected one letter by letter.
/// Long-vowel letters (ا و ي) are ignored because recognisers spell them
/// inconsistently.
LetterDiff _letterDiff(String heard, String expected) {
  final n = expected.length;
  final m = heard.length;
  final d = List<List<int>>.generate(n + 1, (_) => List<int>.filled(m + 1, 0));
  for (var i = 0; i <= n; i++) {
    d[i][0] = i;
  }
  for (var j = 0; j <= m; j++) {
    d[0][j] = j;
  }
  for (var i = 1; i <= n; i++) {
    for (var j = 1; j <= m; j++) {
      final c = expected[i - 1] == heard[j - 1] ? 0 : 1;
      var v = d[i - 1][j - 1] + c;
      if (d[i - 1][j] + 1 < v) v = d[i - 1][j] + 1;
      if (d[i][j - 1] + 1 < v) v = d[i][j - 1] + 1;
      d[i][j] = v;
    }
  }
  final bad = <int>{};
  final notes = <String>[];
  var i = n;
  var j = m;
  while (i > 0 || j > 0) {
    if (i > 0 &&
        j > 0 &&
        d[i][j] == d[i - 1][j - 1] + (expected[i - 1] == heard[j - 1] ? 0 : 1)) {
      if (expected[i - 1] != heard[j - 1] &&
          !_isMatres(expected[i - 1]) &&
          !_isMatres(heard[j - 1])) {
        bad.add(i - 1);
        notes.add('پیتی «${expected[i - 1]}» وەک «${heard[j - 1]}» بیستراوە');
      }
      i--;
      j--;
    } else if (i > 0 && d[i][j] == d[i - 1][j] + 1) {
      if (!_isMatres(expected[i - 1])) {
        bad.add(i - 1);
        notes.add('پیتی «${expected[i - 1]}» نەبیستراوە');
      }
      i--;
    } else {
      if (j > 0 && !_isMatres(heard[j - 1])) {
        notes.add('پیتی زیادەی «${heard[j - 1]}»');
      }
      j--;
    }
  }
  return LetterDiff(bad, notes.reversed.toList());
}

class _Cluster {
  String text;
  final int idx; // index into the normalised word, -1 = no letter
  _Cluster(this.text, this.idx);
}

/// Splits a vowelled Arabic word into letter + its marks, with the index the
/// letter has in _arNorm(word).
List<_Cluster> _clusters(String token) {
  final out = <_Cluster>[];
  var idx = 0;
  for (final r in token.runes) {
    final ch = String.fromCharCode(r);
    var contributes = false;
    if (!_arStrip.hasMatch(ch) && r != 0x0621) {
      final f = _arFold[r] ?? r;
      contributes = f >= 0x0621 && f <= 0x064A;
    }
    if (contributes || out.isEmpty) {
      out.add(_Cluster(ch, contributes ? idx : -1));
      if (contributes) idx++;
    } else {
      out.last.text += ch;
    }
  }
  return out;
}

/// Follows the reader through the flat list of expected words.
/// st[i]: 0 not read yet, 1 read correctly, 2 mistake.
class RecitationAligner {
  final List<String> words;
  final List<int> st;
  int cursor;
  bool locked = false;
  int level = 1; // 0 lenient, 1 normal, 2 strict
  int rev = 0; // bumps on every visible change
  int _hint;
  int _miss = 0;
  final List<String> _pending = [];
  final List<String> _recent = [];
  final List<String> _dropped = [];

  RecitationAligner(this.words, {int hint = 0})
      : st = List<int>.filled(words.length, 0),
        cursor = hint,
        _hint = hint;

  bool get finished => cursor >= words.length;
  double get _thr =>
      level == 0 ? 0.6 : (level == 1 ? 0.7 : (level == 2 ? 0.8 : 0.88));
  bool get _instant => level >= 3; // flag a wrong word without waiting
  bool _same(String h, String e) => _sameWord(h, e, _thr);

  /// Feed newly stable (already normalised) words. Returns the first mistake.
  AlignEvent? feed(List<String> heard, {required bool isFinal}) {
    _pending.addAll(heard);
    for (var guard = 0; guard < 8; guard++) {
      if (!locked) _locate();
      if (!locked) return null;
      final ev = _process(isFinal);
      if (ev != null) return ev;
      if (locked) return null;
    }
    return null;
  }

  /// Correct word heard in a still-changing partial result: accept at once.
  bool acceptTentative(String h) {
    if (!locked || _pending.isNotEmpty || cursor >= words.length) return false;
    if (!_same(h, words[cursor])) return false;
    _ok(cursor);
    cursor++;
    rev++;
    _miss = 0;
    return true;
  }

  /// After a correction: user repeats the ayah [start, end).
  void rewindTo(int start, int end) {
    for (var k = start; k < end && k < st.length; k++) {
      if (st[k] != 2) st[k] = 0;
    }
    cursor = start;
    locked = true;
    _pending.clear();
    _recent.clear();
    _dropped.clear();
    _miss = 0;
    rev++;
  }

  void _ok(int i) {
    if (i >= 0 && i < st.length && st[i] != 1) {
      st[i] = 1;
      rev++;
    }
  }

  // --- find where in the surah the reader is (3 consecutive words) ---
  void _locate() {
    while (_pending.isNotEmpty && !locked) {
      _recent.add(_pending.removeAt(0));
      if (_recent.length > 3) _recent.removeAt(0);
      if (_recent.length < 3) continue;
      var best = -1;
      var bestScore = 1 << 30;
      for (var p = 0; p + 2 < words.length; p++) {
        if (_same(_recent[0], words[p]) &&
            _same(_recent[1], words[p + 1]) &&
            _same(_recent[2], words[p + 2])) {
          final score = p >= _hint ? p - _hint : (_hint - p) * 3;
          if (score < bestScore) {
            bestScore = score;
            best = p;
          }
        }
      }
      if (best >= 0) {
        _ok(best);
        _ok(best + 1);
        _ok(best + 2);
        cursor = best + 3;
        locked = true;
        _miss = 0;
        _recent.clear();
        _dropped.clear();
        rev++;
      }
    }
  }

  AlignEvent? _process(bool isFinal) {
    while (_pending.isNotEmpty && cursor < words.length) {
      final h = _pending[0];
      final e = words[cursor];
      final n = words.length;

      // 1. correct word
      if (_same(h, e)) {
        _ok(cursor);
        cursor++;
        rev++;
        _pending.removeAt(0);
        _miss = 0;
        continue;
      }
      // 2. recogniser split one word in two (يا + أيها)
      if (_pending.length > 1 && _same(h + _pending[1], e)) {
        _ok(cursor);
        cursor++;
        rev++;
        _pending.removeRange(0, 2);
        _miss = 0;
        continue;
      }
      // 3. recogniser glued two words together
      if (cursor + 1 < n && _same(h, e + words[cursor + 1])) {
        _ok(cursor);
        _ok(cursor + 1);
        cursor += 2;
        rev++;
        _pending.removeAt(0);
        _miss = 0;
        continue;
      }

      // Need one more heard word to tell the cases below apart.
      if (_pending.length < 2 && !isFinal && !_instant) break;
      final next = _pending.length > 1 ? _pending[1] : null;
      // instant mode: h may only be the first half of a split word - wait
      if (_instant &&
          !isFinal &&
          next == null &&
          h.length >= 2 &&
          e.length > h.length &&
          (e.startsWith(h) || e.endsWith(h))) {
        break;
      }

      // 4. words skipped: h matches an expected word 1..3 ahead (+ confirmed)
      var skip = 0;
      for (var j = 1; j <= 3 && cursor + j < n; j++) {
        if (!_same(h, words[cursor + j])) continue;
        final confirmed = next == null ||
            cursor + j + 1 >= n ||
            _same(next, words[cursor + j + 1]);
        if (confirmed) {
          skip = j;
          break;
        }
      }
      if (skip > 0) {
        final flag = level == 2 || (level == 1 && skip >= 2);
        final at = cursor;
        for (var k = 0; k < skip; k++) {
          st[at + k] = flag ? 2 : 1;
        }
        _ok(at + skip);
        cursor = at + skip + 1;
        rev++;
        _pending.removeAt(0);
        _miss = 0;
        if (flag) return AlignEvent(at, true, '', words[at]);
        continue;
      }

      // 5. wrong word: the next heard word is the expected word after it
      if (next != null && cursor + 1 < n && _same(next, words[cursor + 1])) {
        final at = cursor;
        st[at] = 2;
        cursor++;
        rev++;
        _pending.removeAt(0);
        _miss = 0;
        return AlignEvent(at, false, h, words[at]);
      }
      // 5b. last word of an utterance, clearly a mispronunciation of e
      if (next == null &&
          (isFinal || _instant) &&
          level >= 1 &&
          _sim(h, e) >= 0.4) {
        final at = cursor;
        st[at] = 2;
        cursor++;
        rev++;
        _pending.removeAt(0);
        _miss = 0;
        return AlignEvent(at, false, h, words[at]);
      }

      // 6. noise, or the reader jumped somewhere else
      _dropped.add(_pending.removeAt(0));
      if (_dropped.length > 3) _dropped.removeAt(0);
      if (++_miss >= 4) {
        locked = false;
        _hint = cursor;
        _recent
          ..clear()
          ..addAll(_dropped);
        _dropped.clear();
        _miss = 0;
        rev++;
        return null;
      }
    }
    return null;
  }
}


// ============================================================
//  Recitation coach (2/2) - microphone, correction audio, state
//  Listens while the toggle is ON, compares what you recite with the
//  ayah text, and plays the correct ayah (Alafasy) when you make a mistake.
// ============================================================
const String kCoachReciter = 'Alafasy_128kbps'; // مشاری العفاسی
const List<String> kCoachLevels = [
  'لەسەرخۆ - تەنها هەڵەی ئاشکرا',
  'ئاسایی (پێشنیارکراو)',
  'توند - هەموو وردەکارییەک',
  'پیت بە پیت - یەکسەر ڕاستدەکاتەوە (زۆر توند)',
  'تەجوید - خێرا (مۆدێلی دەنگی ئۆفلاین)',
  'تەجوید - وردبین (چاوەڕێی کۆتایی وشە دەکات)',
];

final GlobalKey<ScaffoldMessengerState> appMessenger =
    GlobalKey<ScaffoldMessengerState>();

enum CoachState { off, starting, listening, paused, correcting }

class CoachMarks {
  final List<String> tokens;
  final List<int> marks; // 0 unread, 1 correct, 2 mistake, 3 current word
  final Map<int, Set<int>> letters; // token index -> wrong letter indexes
  const CoachMarks(this.tokens, this.marks, [this.letters = const {}]);
}

class RecitationCoach extends ChangeNotifier with WidgetsBindingObserver {
  final stt.SpeechToText _stt = stt.SpeechToText();
  final ValueNotifier<String> heardText = ValueNotifier<String>('');
  bool _ready = false;
  String? _locale;

  bool on = false;
  CoachState state = CoachState.off;
  String message = '';
  int surah = 0;

  List<Ayah> _ayahs = const [];
  List<List<String>> _tokens = const [];
  List<List<bool>> _isWord = const [];
  List<int> _starts = const [0];
  List<int> _wayah = const [];
  RecitationAligner? _al;

  int _consumed = 0;
  List<String> _lastHeard = const [];
  bool _flushed = true;
  String _lastFinal = '';
  DateTime _lastFinalAt = DateTime(2000);
  int _fails = 0;
  bool _correcting = false;
  bool _corrArmed = false;
  bool _wasLocked = false;
  Timer? _restart;
  Timer? _safety;
  Timer? _idle;
  // neural (offline acoustic model) mode
  bool _neural = false;
  rq.ReciteQuran? _nTracker;
  rq.AudioProcessor? _nMic;
  StreamSubscription<rq.WordMatchedEvent>? _nSub;
  final Map<int, rq.ContinuousQuranWord> _byGlobal = {};
  List<rq.ContinuousQuranWord> _nWords = const [];
  final Map<int, int> _wordFails = {}; // global word -> mistakes in a row
  int _wBase = 1; // is wordInAyah 0- or 1-based in the package
  DateTime _unmuteAt = DateTime(2000);
  final Map<int, Set<int>> _badLetters = {};

  // ---------- public ----------
  /// Ayah number the reader is currently at (0 when idle).
  int get cursorAyah {
    final al = _al;
    if (al == null || _wayah.isEmpty) return 0;
    final g = al.cursor >= _wayah.length ? _wayah.length - 1 : al.cursor;
    return _ayahs[_wayah[g]].n;
  }

  Future<void> start(int surahNo, List<Ayah> ayahs, {int hintAyah = 1}) async {
    if (on) return;
    on = true;
    surah = surahNo;
    _fails = 0;
    _build(ayahs, hintAyah);
    _set(CoachState.starting, 'مایکرۆفۆن ئامادە دەکرێت...');
    WidgetsBinding.instance.addObserver(this);
    audio.addListener(_onAudio);
    if (audio.surah != 0) await audio.stop(); // the mic must not hear the speaker
    _neural = settings.coachLevel >= 4;
    final ok = _neural ? await _initNeural() : await _init();
    if (!on) return;
    if (!ok) {
      await stop(msg: message);
      return;
    }
    if (_neural) {
      _set(CoachState.listening, 'گوێم لێتە - دەستپێبکە بخوێنە');
      return;
    }
    await _listen();
  }

  Future<void> stop({String msg = ''}) async {
    if (!on && state == CoachState.off) return;
    final wasCorrecting = _correcting;
    on = false;
    _correcting = false;
    _corrArmed = false;
    _restart?.cancel();
    _safety?.cancel();
    _idle?.cancel();
    _badLetters.clear();
    audio.removeListener(_onAudio);
    WidgetsBinding.instance.removeObserver(this);
    state = CoachState.off;
    message = '';
    heardText.value = '';
    _al = null;
    notifyListeners();
    try {
      await _stt.cancel();
    } catch (_) {}
    await _teardownNeural();
    if (wasCorrecting && audio.surah != 0) await audio.stop();
    if (msg.isNotEmpty) {
      appMessenger.currentState
          ?.showSnackBar(SnackBar(content: Text(msg)));
    }
  }

  /// Called when the reading page is closed.
  void detach(int surahNo) {
    if (on && surah == surahNo) scheduleMicrotask(() => stop());
  }

  /// Per-word colours for one ayah (null = draw it normally).
  CoachMarks? marksFor(int surahNo, int ayahN) {
    final al = _al;
    if (!on || al == null || surah != surahNo || state == CoachState.starting) {
      return null;
    }
    final ai = _ayahIndexOf(ayahN);
    if (ai < 0) return null;
    final s = _starts[ai];
    final e = _starts[ai + 1];
    final cur = al.cursor;
    var touched = cur >= s && cur < e;
    if (!touched) {
      for (var k = s; k < e; k++) {
        if (al.st[k] != 0) {
          touched = true;
          break;
        }
      }
    }
    if (!touched) return null;
    final toks = _tokens[ai];
    final out = List<int>.filled(toks.length, 0);
    final letters = <int, Set<int>>{};
    var wi = 0;
    for (var t = 0; t < toks.length; t++) {
      if (!_isWord[ai][t]) continue;
      final g = s + wi;
      wi++;
      out[t] = al.st[g] == 2
          ? 2
          : (al.st[g] == 4 ? 4 : (g == cur ? 3 : al.st[g]));
      if (al.st[g] == 2) {
        final bl = _badLetters[g];
        if (bl != null && bl.isNotEmpty) letters[t] = bl;
      }
    }
    return CoachMarks(toks, out, letters);
  }

  // ---------- setup ----------
  void _set(CoachState s, String m) {
    state = s;
    message = m;
    notifyListeners();
  }

  void _build(List<Ayah> ayahs, int hintAyah) {
    _ayahs = ayahs;
    final tokens = <List<String>>[];
    final isWord = <List<bool>>[];
    final starts = <int>[];
    final wayah = <int>[];
    final words = <String>[];
    for (var i = 0; i < ayahs.length; i++) {
      final toks = ayahs[i].ar.split(RegExp(r'\s+')).where((t) => t.isNotEmpty).toList();
      final flags = <bool>[];
      starts.add(words.length);
      for (final t in toks) {
        final w = _arNorm(t);
        flags.add(w.isNotEmpty);
        if (w.isNotEmpty) {
          words.add(w);
          wayah.add(i);
        }
      }
      tokens.add(toks);
      isWord.add(flags);
    }
    starts.add(words.length);
    _tokens = tokens;
    _isWord = isWord;
    _starts = starts;
    _wayah = wayah;
    var hint = 0;
    for (var i = 0; i < ayahs.length; i++) {
      if (ayahs[i].n == hintAyah) hint = starts[i];
    }
    final al = RecitationAligner(words, hint: hint);
    al.level = settings.coachLevel;
    _al = al;
    _wasLocked = false;
    _consumed = 0;
    _lastHeard = const [];
    _flushed = true;
    _corrArmed = false;
    _correcting = false;
    _badLetters.clear();
  }

  String _cursorWord() {
    final al = _al;
    if (al == null || al.cursor >= _wayah.length) return '';
    return _wordText(_wayah[al.cursor], al.cursor);
  }

  int _ayahIndexOf(int n) {
    if (n - 1 >= 0 && n - 1 < _ayahs.length && _ayahs[n - 1].n == n) return n - 1;
    for (var i = 0; i < _ayahs.length; i++) {
      if (_ayahs[i].n == n) return i;
    }
    return -1;
  }

  String _wordText(int ai, int g) {
    final target = g - _starts[ai];
    var wi = 0;
    for (var t = 0; t < _tokens[ai].length; t++) {
      if (!_isWord[ai][t]) continue;
      if (wi == target) return _tokens[ai][t];
      wi++;
    }
    return '';
  }

  Future<bool> _init() async {
    if (_ready && _locale != null) return true;
    try {
      _ready = await _stt.initialize(onStatus: _onStatus, onError: _onError);
    } catch (_) {
      _ready = false;
    }
    if (!_ready) {
      message = 'ڕێگەپێدانی مایکرۆفۆن نەدرا، یان ناسینەوەی دەنگ لەسەر ئەم مۆبایلە بەردەست نییە.';
      return false;
    }
    String? pick;
    try {
      final locs = await _stt.locales();
      for (final l in locs) {
        final id = l.localeId.replaceAll('_', '-').toLowerCase();
        if (id == 'ar-sa') {
          pick = l.localeId;
          break;
        }
      }
      if (pick == null) {
        for (final l in locs) {
          if (l.localeId.toLowerCase().startsWith('ar')) {
            pick = l.localeId;
            break;
          }
        }
      }
    } catch (_) {}
    // If the phone does not list Arabic, still try ar-SA: Google can often
    // recognise it online even when it is not in the locale list.
    pick ??= 'ar-SA';
    _locale = pick;
    return true;
  }

  // ---------- listening loop ----------
  String _listeningText() {
    final al = _al;
    if (al != null && al.locked) {
      return 'گوێم لێتە - ئایەتی $cursorAyah';
    }
    return 'دەگەڕێم بۆ شوێنی خوێندنەوەکەت... دەستپێبکە بخوێنە';
  }

  Future<void> _listen() async {
    if (!on || _correcting || _stt.isListening) return;
    if (audio.playing) {
      _set(CoachState.paused, 'گوێگرتن ڕاگیراوە تا دەنگەکە دەوەستێت');
      return;
    }
    _consumed = 0;
    _lastHeard = const [];
    _flushed = true;
    try {
      await _stt.listen(
        onResult: _onResult,
        localeId: _locale,
        listenFor: const Duration(minutes: 2),
        pauseFor: const Duration(seconds: 8),
        partialResults: true,
        cancelOnError: false,
      );
      if (on && !_correcting) _set(CoachState.listening, _listeningText());
    } catch (_) {
      _fails++;
      if (_fails >= 6) {
        await stop(msg: 'نەتوانرا گوێ لە دەنگ بگیرێت. مایکرۆفۆن و ئینتەرنێت بپشکنە.');
        return;
      }
      _scheduleRestart(const Duration(milliseconds: 800));
    }
  }

  void _scheduleRestart(Duration d) {
    _restart?.cancel();
    _restart = Timer(d, () {
      if (on && !_correcting && state != CoachState.starting) _listen();
    });
  }

  void _onStatus(String s) {
    if (!on || _correcting) return;
    if (s == 'done' || s == 'notListening' || s == 'doneNoResult') {
      _flushPending();
      if (on && !_correcting) _scheduleRestart(const Duration(milliseconds: 350));
    }
  }

  void _onError(SpeechRecognitionError e) {
    if (!on || _correcting) return;
    final m = e.errorMsg;
    if (m.contains('permission')) {
      stop(msg: 'ڕێگەپێدانی مایکرۆفۆن نەدراوە. لە ڕێکخستنەکانی مۆبایل بیدە بە ئەپەکە.');
      return;
    }
    if (m.contains('language')) {
      stop(msg: 'زمانی عەرەبی بۆ ناسینەوەی دەنگ بەردەست نییە.');
      return;
    }
    if (m != 'error_no_match' && m != 'error_speech_timeout') _fails++;
    if (_fails >= 6) {
      stop(msg: 'ناسینەوەی دەنگ کار ناکات. ئینتەرنێت بپشکنە و دووبارە هەوڵبدەرەوە.');
      return;
    }
    _flushPending();
    if (on && !_correcting) {
      _scheduleRestart(Duration(milliseconds: m == 'error_busy' ? 900 : 400));
    }
  }

  void _onResult(SpeechRecognitionResult r) {
    if (!on || _correcting || _al == null) return;
    _fails = 0;
    final text = r.recognizedWords.trim();
    if (r.finalResult) {
      final now = DateTime.now();
      if (text == _lastFinal && now.difference(_lastFinalAt) < const Duration(seconds: 2)) {
        return;
      }
      _lastFinal = text;
      _lastFinalAt = now;
    }
    heardText.value = text;
    final words = text.isEmpty ? <String>[] : text.split(RegExp(r'\s+'));
    _lastHeard = words;
    _flushed = r.finalResult;
    _idle?.cancel();
    // The last word of a partial result may still change: wait for the next one.
    _consume(words, r.finalResult ? words.length : words.length - 1, r.finalResult);
    if (r.finalResult || words.isEmpty || !on || _correcting) return;
    // A correct last word is accepted at once (the word lights up while reading).
    final al = _al;
    if (al != null && _consumed == words.length - 1) {
      final w = _arNorm(words.last);
      if (w.isNotEmpty && al.acceptTentative(w)) {
        _consumed = words.length;
        if (al.finished) {
          stop(msg: 'ماشاءاللە! سوورەتەکەت تەواو کرد.');
          return;
        }
        notifyListeners();
      }
    }
    // The reader paused: the last word is settled, check it without waiting
    // for another word or the end of the session.
    final lvl = settings.coachLevel;
    if (lvl >= 1) {
      final ms = lvl == 1 ? 1300 : (lvl == 2 ? 900 : 500);
      _idle = Timer(Duration(milliseconds: ms), () {
        if (!on || _correcting || _al == null || _lastHeard.isEmpty) return;
        _consume(_lastHeard, _lastHeard.length, false, idle: true);
      });
    }
  }

  /// Session ended without a final result: treat the last partial as final.
  void _flushPending() {
    _idle?.cancel();
    if (!_flushed && _lastHeard.isNotEmpty) {
      final w = _lastHeard;
      _lastHeard = const [];
      _flushed = true;
      _consume(w, w.length, true);
    }
    _consumed = 0;
  }

  void _consume(List<String> words, int stable, bool isFinal,
      {bool idle = false}) {
    final al = _al;
    if (al == null) return;
    al.level = settings.coachLevel;
    final fresh = <String>[];
    for (var i = _consumed; i < stable && i < words.length; i++) {
      final w = _arNorm(words[i]);
      if (w.isNotEmpty) fresh.add(w);
    }
    if (stable > _consumed) _consumed = stable;
    if (fresh.isEmpty && !isFinal) return;
    final before = al.rev;
    final ev = al.feed(fresh, isFinal: isFinal || idle);
    if (isFinal) _consumed = 0;
    _after(ev, before);
  }

  void _after(AlignEvent? ev, int revBefore) {
    final al = _al;
    if (al == null) return;
    if (al.finished) {
      stop(msg: 'ماشاءاللە! سوورەتەکەت تەواو کرد.');
      return;
    }
    if (ev != null) {
      _correct(ev);
      return;
    }
    if (al.locked != _wasLocked) {
      _wasLocked = al.locked;
      if (state == CoachState.listening) {
        message = _listeningText();
        notifyListeners();
        return;
      }
    }
    if (al.rev != revBefore) notifyListeners();
  }

  // ---------- neural engine (recite_quran: Zipformer CTC + tajweed) ----------
  Future<bool> _initNeural() async {
    try {
      final repo = rq.QuranRepository(rq.QuranMetadataService());
      await repo.loadSurahAsync(surah);
      final tracker = rq.ReciteQuran(
        repository: repo,
        config: rq.TrackerConfig(
          recitationSpeed: rq.RecitationSpeed.normal,
          // level 4: commit words at once; level 5: wait for the full vowel
          // length (more exact madd/ghunna, a little slower)
          enableEarlyMatching: settings.coachLevel == 4,
          enableAutoReanchor: true,
        ),
        isTajweed: true,
      );
      await tracker.initialize();
      tracker.setTargetSurah(surah);
      final words = repo.getSurahWords(surah);
      _byGlobal.clear();
      _nWords = words;
      _wordFails.clear();
      for (final w in words) {
        _byGlobal[w.globalIndex] = w;
      }
      _wBase = words.isEmpty ? 1 : words.first.wordInAyah;
      _nTracker = tracker;
      _nSub = tracker.onWordMatched.listen(_onNeuralWord);
      final mic = rq.AudioProcessor();
      _nMic = mic;
      await mic.start(onChunk: (chunk, isFinal) {
        if (!on || !_neural || _correcting || audio.playing) return;
        if (DateTime.now().isBefore(_unmuteAt)) return;
        tracker.feedAudioChunk(chunk, isFinal: isFinal);
      });
      return true;
    } catch (e) {
      await _teardownNeural();
      message = 'مۆدێلی دەنگ بار نەبوو (فایلی مۆدێلەکە لەناو ئەپەکەدا نییە، یان مایکرۆفۆن ڕێگەپێدراو نییە): $e';
      return false;
    }
  }

  Future<void> _teardownNeural() async {
    final sub = _nSub;
    final mic = _nMic;
    final tr = _nTracker;
    _nSub = null;
    _nMic = null;
    _nTracker = null;
    _neural = false;
    try {
      await sub?.cancel();
    } catch (_) {}
    // method names below are called dynamically so a different package
    // version cannot break the build
    if (mic != null) {
      try {
        await (mic as dynamic).stop();
      } catch (_) {}
      try {
        await (mic as dynamic).dispose();
      } catch (_) {}
    }
    if (tr != null) {
      try {
        await (tr as dynamic).dispose();
      } catch (_) {}
    }
  }

  String _tajweedText(List<dynamic>? errs) {
    if (errs == null || errs.isEmpty) return '';
    final out = <String>[];
    for (final e in errs) {
      if (e is Map) {
        for (final k in const ['message_ar', 'message', 'explanation', 'rule', 'type', 'name']) {
          final v = e[k];
          if (v != null && '$v'.trim().isNotEmpty) {
            out.add('$v');
            break;
          }
        }
      }
    }
    return out.isEmpty ? 'هەڵەی تەجوید' : out.take(2).join(' • ');
  }

  void _onNeuralWord(rq.WordMatchedEvent ev) {
    final al = _al;
    if (!on || !_neural || al == null) return;
    // wordId is the package's global word index; fall back to the list position
    // results that were still in the pipe when the correction ended
    if (!_correcting &&
        DateTime.now().isBefore(_unmuteAt.add(const Duration(milliseconds: 600)))) {
      return;
    }
    final w = _byGlobal[ev.wordId] ??
        (ev.wordId >= 0 && ev.wordId < _nWords.length ? _nWords[ev.wordId] : null);
    if (w == null) return;
    final ai = _ayahIndexOf(w.ayah);
    if (ai < 0) return;
    final count = _starts[ai + 1] - _starts[ai];
    if (count <= 0) return;
    var k = w.wordInAyah - _wBase;
    if (k < 0) k = 0;
    if (k >= count) k = count - 1;
    final g = _starts[ai] + k;
    final errs = (ev as dynamic).tajweedErrors as List<dynamic>?;
    final slip = errs != null && errs.isNotEmpty;
    al.locked = true;
    if (ev.isRed || slip) {
      al.st[g] = ev.isRed ? 2 : 4;
      al.cursor = g;
      al.rev++;
      if (_correcting) {
        notifyListeners();
      } else {
        _correctNeural(ai, g, ev.isRed, slip ? _tajweedText(errs) : '',
            w.wordInAyah - _wBase + 1);
      }
      return;
    }
    if ((ev as dynamic).isNeutral == true) return;
    if (_correcting) return; // stale result that arrived after the mistake
    al.st[g] = 1;
    _wordFails.remove(g);
    al.cursor = g + 1;
    al.rev++;
    if (al.cursor >= al.words.length) {
      stop(msg: 'ماشاءاللە! سوورەتەکەت تەواو کرد.');
      return;
    }
    notifyListeners();
  }

  /// Teacher-style correction: the wrong word is said on its own at once
  /// (tiny word audio, no waiting). If the same word is wrong again, the
  /// whole phrase is replayed from two words before it.
  Future<void> _correctNeural(
      int ai, int g, bool wrongWord, String detail, int pos) async {
    final al = _al;
    if (al == null) return;
    final ayah = _ayahs[ai];
    final bad = _wordText(ai, g);
    _correcting = true;
    _corrArmed = false;
    final fails = (_wordFails[g] ?? 0) + 1;
    _wordFails[g] = fails;
    final single = fails <= 1;
    final resume = single ? g : (g - 2 < _starts[ai] ? _starts[ai] : g - 2);
    var before = 0;
    var total = 0;
    for (var k = _starts[ai]; k < _starts[ai + 1]; k++) {
      final n = al.words[k].length + 1;
      total += n;
      if (k < resume) before += n;
    }
    final from = total > 0 ? before / total : 0.0;
    al.cursor = resume;
    heardText.value = '';
    _set(
      CoachState.correcting,
      wrongWord
          ? 'هەڵە لە وشەی «$bad» - گوێبگرە و دووبارە بکەرەوە'
          : 'هەڵەی تەجوید لە وشەی «$bad»${detail.isEmpty ? '' : ' ($detail)'} - گوێبگرە و دووبارە بکەرەوە',
    );
    _safety?.cancel();
    _safety = Timer(Duration(seconds: single ? 12 : 40), _endCorrection);
    final f = single
        ? audio.playWord(surah, ayah.n, pos, fallbackFrom: from)
        : audio.playCorrection(surah, ayah.n, from: from);
    _corrArmed = true;
    await f;
  }

  // ---------- correction ----------
  Future<void> _correct(AlignEvent ev) async {
    final al = _al;
    if (al == null) return;
    final ai = _wayah[ev.g];
    final ayah = _ayahs[ai];
    final bad = _wordText(ai, ev.g);
    _correcting = true;
    _corrArmed = false;
    _restart?.cancel();
    _idle?.cancel();
    // which letters were wrong (shown in red inside the word)
    var detail = '';
    if (!ev.skipped && ev.heard.isNotEmpty && ev.expected.isNotEmpty) {
      final ld = _letterDiff(ev.heard, ev.expected);
      if (ld.bad.isNotEmpty) _badLetters[ev.g] = ld.bad;
      if (ld.notes.isNotEmpty) detail = ' (${ld.notes.take(2).join(' • ')})';
    }
    // normal levels: repeat the whole ayah. letter-by-letter level: repeat
    // only from two words before the mistake, and play the audio from there.
    final letterMode = settings.coachLevel >= 3;
    var resume = _starts[ai];
    var from = 0.0;
    if (letterMode) {
      resume = ev.g - 2 < _starts[ai] ? _starts[ai] : ev.g - 2;
      var before = 0;
      var total = 0;
      for (var k = _starts[ai]; k < _starts[ai + 1]; k++) {
        final w = al.words[k].length + 1;
        total += w;
        if (k < resume) before += w;
      }
      if (total > 0) from = before / total;
    }
    al.rewindTo(resume, _starts[ai + 1]);
    _wasLocked = true;
    heardText.value = '';
    _set(
      CoachState.correcting,
      ev.skipped
          ? 'وشەیەک بەجێماوە لە ئایەتی ${ayah.n}. گوێبگرە و دووبارە بکەرەوە'
          : 'هەڵە لە وشەی «$bad»$detail - ئایەتی ${ayah.n}. گوێبگرە و دووبارە بکەرەوە',
    );
    try {
      await _stt.cancel();
    } catch (_) {}
    if (!on || !_correcting) return;
    _safety?.cancel();
    _safety = Timer(const Duration(seconds: 40), _endCorrection);
    final f = audio.playCorrection(surah, ayah.n, from: from);
    _corrArmed = true; // playCorrection has already registered the new ayah
    await f;
  }

  Future<void> _endCorrection() async {
    if (!_correcting) return;
    _correcting = false;
    _corrArmed = false;
    _safety?.cancel();
    if (audio.surah != 0) await audio.stop();
    if (!on) return;
    if (_neural) {
      _unmuteAt = DateTime.now().add(const Duration(milliseconds: 300));
      final w = _cursorWord();
      _set(CoachState.listening,
          w.isNotEmpty ? 'ئامادەبە، لە وشەی «$w» دەست پێبکەوە...' : 'گوێم لێتە');
      return;
    }
    final cw = settings.coachLevel >= 3 ? _cursorWord() : '';
    _set(
        CoachState.paused,
        cw.isNotEmpty
            ? 'ئامادەبە، لە وشەی «$cw» دەست پێبکەوە...'
            : 'ئامادەبە، ئایەتی $cursorAyah دووبارە بکەرەوە...');
    _scheduleRestart(const Duration(milliseconds: 700));
  }

  void _onAudio() {
    if (!on) return;
    if (_correcting) {
      if (_corrArmed && (audio.surah == 0 || audio.error)) _endCorrection();
      return;
    }
    if (_neural) return;
    if (audio.playing) {
      if (state == CoachState.listening) {
        _restart?.cancel();
        _set(CoachState.paused, 'گوێگرتن ڕاگیراوە تا دەنگەکە دەوەستێت');
        _stt.cancel();
      }
    } else if (state == CoachState.paused) {
      _scheduleRestart(const Duration(milliseconds: 500));
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState s) {
    if (on && s == AppLifecycleState.paused && state != CoachState.starting) {
      stop(msg: 'گوێگرتن وەستا چونکە ئەپەکە چووە پاشبنەما.');
    }
  }
}

final RecitationCoach coach = RecitationCoach();

// ---------- UI: toggle (next to the Settings icon) ----------
class _CoachToggle extends StatelessWidget {
  final VoidCallback onTurnOn;
  const _CoachToggle({required this.onTurnOn});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: coach,
      builder: (context, _) {
        return Tooltip(
          message: 'ڕاستکردنەوەی خوێندنەوە بە دەنگ',
          child: SizedBox(
            width: 50,
            child: FittedBox(
              child: Switch(
                value: coach.on,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                onChanged: (v) {
                  if (v) {
                    onTurnOn();
                  } else {
                    coach.stop();
                  }
                },
                thumbIcon: WidgetStateProperty.resolveWith<Icon?>(
                  (states) => states.contains(WidgetState.selected)
                      ? const Icon(Icons.mic, size: 16, color: Colors.white)
                      : const Icon(Icons.mic_off, size: 16, color: Color(0xFF6B6A5E)),
                ),
                thumbColor: WidgetStateProperty.resolveWith<Color?>(
                  (states) => states.contains(WidgetState.selected)
                      ? _green
                      : Colors.white,
                ),
                trackColor: WidgetStateProperty.resolveWith<Color?>(
                  (states) => states.contains(WidgetState.selected)
                      ? _gold
                      : const Color(0x66FFFFFF),
                ),
                trackOutlineColor:
                    const WidgetStatePropertyAll<Color>(Colors.transparent),
              ),
            ),
          ),
        );
      },
    );
  }
}

// ---------- UI: status panel above the player bar ----------
class _CoachPanel extends StatelessWidget {
  const _CoachPanel();

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([coach, audio]),
      builder: (context, _) {
        if (!coach.on) return const SizedBox.shrink();
        final st = coach.state;
        final bad = st == CoachState.correcting;
        final accent = bad ? const Color(0xFFE53935) : _green;
        return Material(
          color: _cardColor(context),
          child: SafeArea(
            top: false,
            bottom: audio.surah == 0,
            child: Container(
              decoration: BoxDecoration(
                border: Border(top: BorderSide(color: accent, width: 2)),
              ),
              padding: const EdgeInsets.fromLTRB(14, 8, 14, 8),
              child: Row(
                children: [
                  _MicDot(
                    active: st == CoachState.listening,
                    color: accent,
                    icon: bad
                        ? Icons.volume_up
                        : (st == CoachState.paused ? Icons.mic_off : Icons.mic),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          coach.message,
                          style: TextStyle(
                            fontSize: 14.5,
                            fontWeight: FontWeight.bold,
                            color: bad ? accent : _inkColor(context),
                          ),
                        ),
                        ValueListenableBuilder<String>(
                          valueListenable: coach.heardText,
                          builder: (context, v, _) => v.isEmpty
                              ? const SizedBox.shrink()
                              : Text(
                                  v,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  textDirection: TextDirection.rtl,
                                  style: TextStyle(
                                    fontSize: 13,
                                    color: _mutedColor(context),
                                    fontFamilyFallback: _arFonts,
                                  ),
                                ),
                        ),
                      ],
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

class _MicDot extends StatefulWidget {
  final bool active;
  final Color color;
  final IconData icon;
  const _MicDot({required this.active, required this.color, required this.icon});

  @override
  State<_MicDot> createState() => _MicDotState();
}

class _MicDotState extends State<_MicDot> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  );

  @override
  void initState() {
    super.initState();
    _sync();
  }

  @override
  void didUpdateWidget(_MicDot old) {
    super.didUpdateWidget(old);
    _sync();
  }

  void _sync() {
    if (widget.active) {
      if (!_c.isAnimating) _c.repeat(reverse: true);
    } else {
      _c.stop();
      _c.value = 0;
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      builder: (context, _) {
        final t = _c.value;
        return Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: widget.color,
            boxShadow: widget.active
                ? [
                    BoxShadow(
                      color: const Color(0x661E7A3E),
                      blurRadius: 4 + 8 * t,
                      spreadRadius: 1 + 4 * t,
                    ),
                  ]
                : const [],
          ),
          child: Icon(widget.icon, color: Colors.white, size: 22),
        );
      },
    );
  }
}

// ---------- UI: Arabic text of one ayah (coloured while the coach is on) ----------
class _AyahArabic extends StatelessWidget {
  final Ayah a;
  final int surah;
  const _AyahArabic(this.a, this.surah);

  @override
  Widget build(BuildContext context) {
    final base = TextStyle(
      fontSize: settings.arabicSize,
      height: 2.0,
      color: _inkColor(context),
      fontFamilyFallback: _arFonts,
    );
    return ListenableBuilder(
      listenable: coach,
      builder: (context, _) {
        final m = coach.marksFor(surah, a.n);
        if (m == null) {
          return Text(
            a.ar,
            textDirection: TextDirection.rtl,
            textAlign: TextAlign.start,
            style: base,
          );
        }
        final dark = _isDark(context);
        final okColor = dark ? const Color(0xFF6FD08C) : _green;
        final badColor = dark ? const Color(0xFFFF7B7B) : const Color(0xFFD32F2F);
        final spans = <TextSpan>[];
        for (var i = 0; i < m.tokens.length; i++) {
          final txt = i < m.tokens.length - 1 ? '${m.tokens[i]} ' : m.tokens[i];
          final wrong = m.letters[i];
          if (m.marks[i] == 2 && wrong != null && wrong.isNotEmpty) {
            final cl = _clusters(m.tokens[i]);
            spans.add(TextSpan(children: [
              for (final c in cl)
                TextSpan(
                  text: c.text,
                  style: wrong.contains(c.idx)
                      ? TextStyle(
                          color: badColor,
                          fontWeight: FontWeight.bold,
                          backgroundColor: const Color(0x66E53935),
                        )
                      : TextStyle(color: _inkColor(context)),
                ),
              if (i < m.tokens.length - 1) const TextSpan(text: ' '),
            ]));
            continue;
          }
          TextStyle? s;
          switch (m.marks[i]) {
            case 1:
              s = TextStyle(color: okColor);
              break;
            case 2:
              s = TextStyle(
                color: badColor,
                backgroundColor: const Color(0x33E53935),
              );
              break;
            case 3:
              s = const TextStyle(
                color: _gold,
                backgroundColor: Color(0x33D9A21B),
              );
              break;
            case 4: // tajweed slip (word right, rule wrong)
              s = const TextStyle(
                color: Color(0xFFEF8F00),
                backgroundColor: Color(0x44EF8F00),
              );
              break;
          }
          spans.add(TextSpan(text: txt, style: s));
        }
        return Text.rich(
          TextSpan(style: base, children: spans),
          textDirection: TextDirection.rtl,
          textAlign: TextAlign.start,
        );
      },
    );
  }
}
