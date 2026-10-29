// قورئانی پیرۆز - Flutter project (data from assets/quran/*.json)
import 'dart:convert';

import 'package:flutter/material.dart';
import 'dart:async';
import 'dart:io' show File, Directory, HttpClient;

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
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:audio_session/audio_session.dart' as asn;

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
  audio.trimCache(); // old downloaded audio never piles up
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
  int coachLevel = 2; // 1 easy, 2 balanced (recommended), 3 strict
  int coachSpeed = 1; // offline engine: 0 hadr (fast), 1 tadweer, 2 tahqeeq (slow)
  // where the live recitation stopped last (surah, ayah number, word inside the ayah)
  int coachSurah = 0, coachAyah = 0, coachWord = 0;
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
      // 3 tiers now. Older installs stored 0..6: map them onto the new tiers.
      final lv3 = p.getInt('coachLvl3');
      if (lv3 != null) {
        coachLevel = lv3.clamp(1, 3).toInt();
      } else {
        const migrate = {0: 1, 1: 2, 2: 3, 3: 3, 4: 2, 5: 3, 6: 2};
        coachLevel = migrate[p.getInt('coachLvl') ?? 1] ?? 2;
      }
      coachSpeed = (p.getInt('coachSpd') ?? 1).clamp(0, 2).toInt();
      coachSurah = p.getInt('cSur') ?? 0;
      coachAyah = p.getInt('cAy') ?? 0;
      coachWord = p.getInt('cWd') ?? 0;
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
      await p.setInt('coachLvl3', coachLevel);
      await p.setInt('coachSpd', coachSpeed);
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

  /// Remembers where the recitation is, so a new session continues there.
  Future<void> saveCoachPos(int s, int a, int w) async {
    if (s == coachSurah && a == coachAyah && w == coachWord) return;
    coachSurah = s;
    coachAyah = a;
    coachWord = w;
    try {
      final p = await SharedPreferences.getInstance();
      await p.setInt('cSur', s);
      await p.setInt('cAy', a);
      await p.setInt('cWd', w);
    } catch (_) {}
  }

  void setCoachLevel(int l) {
    coachLevel = l.clamp(1, 3).toInt();
    notifyListeners();
  }

  void setCoachSpeed(int v) {
    coachSpeed = v.clamp(0, 2).toInt();
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

/// Downloaded teacher audio (prefetch) may use at most this much storage.
const int kAudioCacheMaxBytes = 50 * 1024 * 1024;

/// Files not used for this long are removed even when the cache is small.
const Duration kAudioCacheMaxAge = Duration(days: 7);

class _CachedFile {
  final File file;
  final int size;
  final DateTime time; // last use (refreshed whenever the file is played)
  const _CachedFile(this.file, this.size, this.time);
}

class AudioCtl extends ChangeNotifier {
  final AudioPlayer _p = AudioPlayer();
  int surah = 0;
  int ayah = 0;
  bool all = false;
  bool playing = false;
  bool error = false;
  bool correcting = false; // playing a coach correction (always Alafasy)
  bool _wordList = false; // playing words of one ayah: index != ayah offset
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
      if (i != null && surah != 0 && !_wordList) {
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
    _wordList = false;
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
  int corrMs = 0; // estimated length of the slice being replayed (0 = whole rest of the ayah)

  Future<void> playCorrection(int s, int a,
      {double from = 0, double to = 0}) async {
    corrMs = 0;
    _wordList = false;
    surah = s;
    ayah = a;
    all = false;
    _base = a;
    error = false;
    correcting = true;
    notifyListeners();
    try {
      var cached = _ayahCache['${s}_$a'];
      if (cached != null && !File(cached).existsSync()) {
        _ayahCache.remove('${s}_$a'); // the system cleaned it up: use the network
        cached = null;
      }
      if (cached != null) _touch(cached);
      final dur = await _p.setAudioSource(ConcatenatingAudioSource(children: [
        AudioSource.uri(
          cached != null ? Uri.file(cached) : Uri.parse(_coachUrl(s, a)),
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
      // only the slice around the wrong word (estimated), not the whole ayah
      if (to > from && dur != null) {
        corrMs = ((to - from) * dur.inMilliseconds).round() + 1000;
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

  final Map<String, String> _wordCache = {}; // 's_a_pos' -> local mp3
  final Set<String> _wordLoading = {};
  final HttpClient _http = HttpClient()
    ..connectionTimeout = const Duration(seconds: 6)
    ..maxConnectionsPerHost = 6;

  // Coach voice (one ayah per file), downloaded ahead of time so a correction
  // starts at once from a local file instead of waiting for the network.
  final Map<String, String> _ayahCache = {}; // 's_a' -> local mp3 (oldest first)
  final Set<String> _ayahLoading = {};

  String _coachUrl(int s, int a) =>
      'https://everyayah.com/data/$kCoachReciter/${s.toString().padLeft(3, '0')}${a.toString().padLeft(3, '0')}.mp3';

  /// Keeps the downloaded audio under [kAudioCacheMaxBytes]: the least recently
  /// used files go first, and anything older than [kAudioCacheMaxAge] goes
  /// anyway. Also removes files that earlier sessions or older app versions
  /// left in the temp folder. Files in [keepPaths] are never removed.
  Future<void> trimCache({Set<String> keepPaths = const {}}) async {
    try {
      final files = <_CachedFile>[];
      await for (final e in Directory.systemTemp.list()) {
        if (e is! File) continue;
        final name = e.uri.pathSegments.last;
        final ours = (name.startsWith('ay_') || name.startsWith('w_')) &&
            name.endsWith('.mp3');
        if (!ours) continue;
        final st = await e.stat();
        files.add(_CachedFile(e, st.size, st.modified));
      }
      files.sort((x, y) => x.time.compareTo(y.time)); // oldest first
      var total = 0;
      for (final f in files) {
        total += f.size;
      }
      final now = DateTime.now();
      for (final f in files) {
        final tooOld = now.difference(f.time) > kAudioCacheMaxAge;
        if (!tooOld && total <= kAudioCacheMaxBytes) break; // the rest is newer
        if (keepPaths.contains(f.file.path)) continue;
        try {
          await f.file.delete();
          total -= f.size;
        } catch (_) {}
        _ayahCache.removeWhere((_, p) => p == f.file.path);
        _wordCache.removeWhere((_, p) => p == f.file.path);
      }
    } catch (_) {}
  }

  /// Marks a cached file as just used, so it is the last one to be removed.
  Future<void> _touch(String path) async {
    try {
      await File(path).setLastModified(DateTime.now());
    } catch (_) {}
  }

  Future<void> prefetchAyah(int s, int a) async {
    final key = '${s}_$a';
    if (_ayahCache.containsKey(key) || _ayahLoading.contains(key)) return;
    _ayahLoading.add(key);
    try {
      final req = await _http.getUrl(Uri.parse(_coachUrl(s, a)));
      final res = await req.close();
      if (res.statusCode == 200) {
        final f = File('${Directory.systemTemp.path}/ay_$key.mp3');
        await res.pipe(f.openWrite());
        _ayahCache[key] = f.path;
        await trimCache(keepPaths: {f.path});
      } else {
        await res.drain<void>();
      }
    } catch (_) {
    } finally {
      _ayahLoading.remove(key);
    }
  }

  String _wordUrl(int s, int a, int pos) {
    String n3(int v) => v.toString().padLeft(3, '0');
    return 'https://audio.qurancdn.com/wbw/${n3(s)}_${n3(a)}_${n3(pos)}.mp3';
  }

  /// Downloads a word's audio to a temp file ahead of time, so a correction
  /// can start playing at once (no network wait).
  Future<void> prefetchWord(int s, int a, int pos) async {
    final key = '${s}_${a}_$pos';
    if (_wordCache.containsKey(key) || _wordLoading.contains(key)) return;
    _wordLoading.add(key);
    try {
      final req = await _http.getUrl(Uri.parse(_wordUrl(s, a, pos)));
      final res = await req.close();
      if (res.statusCode == 200) {
        final f = File('${Directory.systemTemp.path}/w_$key.mp3');
        await res.pipe(f.openWrite());
        _wordCache[key] = f.path;
      } else {
        await res.drain<void>();
      }
    } catch (_) {
    } finally {
      _wordLoading.remove(key);
    }
  }

  /// One isolated word (quran.com word-by-word audio): a tiny file that
  /// starts playing almost at once. Falls back to the ayah if it cannot load.
  Future<void> playWord(int s, int a, int pos,
      {int prevPos = 0, double fallbackFrom = 0}) async {
    _wordList = true;
    surah = s;
    ayah = a;
    all = false;
    _base = a;
    error = false;
    correcting = true;
    notifyListeners();
    try {
      // the word before the mistake is said first, then the wrong word
      // ("ملك الناس"), so the reader hears it in its place
      AudioSource wordSrc(int w) {
        final cached = _wordCache['${s}_${a}_$w'];
        final uri =
            cached != null ? Uri.file(cached) : Uri.parse(_wordUrl(s, a, w));
        return AudioSource.uri(
          uri,
          tag: MediaItem(
            id: 'w$s:$a:$w',
            title: '${kSurahs[s - 1].ar} • $a',
            artist: 'وشە',
          ),
        );
      }

      await _p.setAudioSource(ConcatenatingAudioSource(children: [
        if (prevPos > 0) wordSrc(prevPos),
        wordSrc(pos),
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
      {Widget? trailing, bool arabic = false, String? sub}) {
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
          subtitle: sub == null
              ? null
              : Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(sub,
                      style: TextStyle(
                          fontSize: 12.5, height: 1.6, color: _mutedColor(c))),
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
                    'لە لاپەڕەی سوورەت، دوگمەی مایکرۆفۆن (لای ئایکۆنی ڕێکخستن) هەڵبکە. ئەپەکە بە مۆدێلی ناو مۆبایل گوێ لە خوێندنەوەکەت دەگرێت (بێ ئینتەرنێت)، بەڵام دەنگی مامۆستا ئینتەرنێتی دەوێت. ئەگەر هەڵەت بکرد، وشەکە بە سوور دەردەکەوێت، سێ وشەکە (پێش، هەڵە، دوای) نیشان دەدرێن و مامۆستا بە دەنگی مشاری العفاسی دەیانڵێتەوە، پاشان تۆ دووبارەیان دەکەیتەوە. ئاستی وردی:',
                    style: TextStyle(
                        fontSize: 13, height: 1.7, color: _mutedColor(context)),
                  ),
                  const SizedBox(height: 6),
                  for (var i = 0; i < kCoachLevels.length; i++)
                    _opt(context, kCoachLevels[i], settings.coachLevel == i + 1,
                        () => settings.setCoachLevel(i + 1),
                        sub: kCoachLevelHints[i]),
                  const SizedBox(height: 10),
                  _head('خێرایی خوێندنەوە'),
                  Text(
                    'دیاری دەکات مەدەکان چەند درێژ بن. ئەگەر بە خێرایی دەخوێنیت (حدر) مەدی کورت وەک هەڵە نابینرێت، و ئەگەر بە خاوی (تحقیق) مەدی درێژ وەک هەڵە نابینرێت. دوای گۆڕین، مامۆستا دووبارە دەست پێبکەرەوە.',
                    style: TextStyle(
                        fontSize: 13, height: 1.7, color: _mutedColor(context)),
                  ),
                  const SizedBox(height: 6),
                  _opt(context, 'خێرا - حدر (مەد 2 دەنگ)', settings.coachSpeed == 0,
                      () => settings.setCoachSpeed(0)),
                  _opt(context, 'ناوەند - تدویر (مەد 4 دەنگ)', settings.coachSpeed == 1,
                      () => settings.setCoachSpeed(1)),
                  _opt(context, 'خاو - تحقیق (مەد 5 تا 6 دەنگ)', settings.coachSpeed == 2,
                      () => settings.setCoachSpeed(2)),
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

/// Skeleton for comparing CONNECTED recitation with the expected text: letters
/// only (no harakat), long-vowel letters (ا و ي) removed because a recogniser
/// spells them unreliably, and a doubled letter written once (shadda, merged
/// lam of al-). It has no spaces, so it does not matter where the recogniser
/// put (or forgot) a word boundary.
String _connSkel(String s) {
  final sb = StringBuffer();
  var last = -1;
  for (final r in _arNorm(s).replaceAll(_arMatres, '').runes) {
    if (r == last) continue;
    sb.writeCharCode(r);
    last = r;
  }
  return sb.toString();
}

/// [expected] (a skeleton) is inside [heard] (a skeleton). Exact on purpose;
/// the only slack is the first letter of a longer phrase, which recognisers
/// often lose when the reader joins it to the sound before (the ب of بِسْمِ).
bool _connContains(String heard, String expected, int level) {
  if (expected.length < 4) return false; // too short to prove anything
  if (heard.contains(expected)) return true;
  if (level >= 3) return false; // strict: exact only
  if (expected.length >= 6 && heard.contains(expected.substring(1))) return true;
  // easy: one wrong or missing letter in a long chain is forgiven
  return level == 1 && expected.length >= 8 && _bestSubstringDist(heard, expected) <= 1;
}

/// Fewest edits that turn [pat] into some part of [text].
int _bestSubstringDist(String text, String pat) {
  if (pat.isEmpty) return 0;
  var prev = List<int>.generate(pat.length + 1, (i) => i);
  var best = prev[pat.length];
  for (var j = 1; j <= text.length; j++) {
    final cur = List<int>.filled(pat.length + 1, 0);
    for (var i = 1; i <= pat.length; i++) {
      final c = pat.codeUnitAt(i - 1) == text.codeUnitAt(j - 1) ? 0 : 1;
      var v = prev[i - 1] + c;
      if (prev[i] + 1 < v) v = prev[i] + 1;
      if (cur[i - 1] + 1 < v) v = cur[i - 1] + 1;
      cur[i] = v;
    }
    if (cur[pat.length] < best) best = cur[pat.length];
    prev = cur;
  }
  return best;
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

// ============================================================
//  Phonetic layer - Shamsi/Qamari assimilation + Wasl chaining
//  Pure Dart (no packages). kPhoneticLayer = false switches it off
//  everywhere, and the coach then behaves exactly as it did before.
//
//  1. Shamsi / Qamari: the lam of "al-" is not pronounced before a sun
//     letter and the sun letter is doubled instead:
//        ٱلرَّحْمَٰنِ  ->  "ar-rahman"  (not "al-rahman")
//     Before a moon letter the lam stays:  ٱلْحَمْدُ -> "al-hamd".
//     The vowelled text decides (bare lam + shadda on the next letter);
//     words like ٱلَّذِينَ / ٱلَّيْلِ, whose lam carries its own shadda,
//     are therefore never mistaken for a sun-letter article.
//  2. Wasl: the alef of wasl (ٱ) is silent when the word is joined to the
//     word before it, so the words are compared as one space-free chain:
//        بِسْمِ ٱللَّهِ  ->  "bismillah"
//  Words that come from a speech recogniser have no vowel marks, so the
//  same rules are applied there letter by letter (_forms).
// ============================================================
const bool kPhoneticLayer = true;

/// Pronunciation of one Quran word, derived from its vowelled (Uthmani) text.
class PhoneticWord {
  /// The original token, e.g. ٱلرَّحْمَٰنِ
  final String surface;

  /// Letters only, identical to _arNorm(surface).
  final String ortho;

  /// How the word sounds when it is said alone: the lam of al- before a sun
  /// letter is gone, letters with shadda are doubled, letters that are never
  /// pronounced (the alef after waw al-jama'a, the alef of wasl after a
  /// prefix such as و ب ف) are left out.  ٱلرَّحْمَٰنِ -> "اررحمن"
  final String sounded;

  /// Like [sounded], but only the doublings that normal Arabic spelling also
  /// shows (al- + sun letter, merged lam of الليل). This is the form that
  /// can be compared with recogniser text.
  final String spell;

  /// Starts with al- (possibly after a prefix letter).
  final bool hasArticle;

  /// The lam of al- is merged into the following sun letter.
  final bool assimilated;

  /// Starts with the alef of wasl: that alef is silent when the word is
  /// joined to the previous word.
  final bool waslStart;

  /// Ends with a long-vowel letter (ا و ي) that is shortened when the next
  /// word starts with the alef of wasl (فِى ٱلْأَرْضِ is said "fil ard").
  final bool endsWithMadd;

  /// Indexes into [ortho] of the letters that are never pronounced (the
  /// assimilated lam of al-, the wasl alef after a prefix).
  final Set<int> silent;

  PhoneticWord({
    required this.surface,
    required this.ortho,
    required this.sounded,
    required this.spell,
    required this.hasArticle,
    required this.assimilated,
    required this.waslStart,
    required this.endsWithMadd,
    required this.silent,
  });
}

class _Gl {
  final int base;
  final Set<int> marks = <int>{};
  _Gl(this.base);
}

class _Form {
  final String text;
  final bool article; // al- hypothesis of a word without prefix letter
  const _Form(this.text, this.article);
}

class QuranPhonetics {
  QuranPhonetics._();

  static const int _waslaAlef = 0x0671;
  static const int _lam = 0x0644;
  static const int _shadda = 0x0651;
  static const int _silentMark = 0x06DF; // small high zero: letter not read
  static const String _alefS = '\u0627';
  static const String _sun = 'تثدذرزسشصضطظلن';
  static const String _prefixChars = 'وفبكلت';
  static const Set<int> _prefixCodes = {
    0x0648, 0x0641, 0x0628, 0x0643, 0x0644, 0x062A, // و ف ب ك ل ت
  };
  // words whose first lam is part of the word itself (al-ladhi, at-ti):
  // the lam is doubled, it is NOT an assimilated article
  static const Set<String> _relative = {
    'الذي',
    'الذين',
    'التي',
    'الذان',
    'التان',
  };
  static const Set<int> _vowelMarks = {
    0x064B, 0x064C, 0x064D, 0x064E, 0x064F, 0x0650, 0x0651, 0x0652, 0x06DF,
  };
  static const Set<int> _tanween = {0x064B, 0x064C, 0x064D};

  static bool _isMark(int r) =>
      (r >= 0x0610 && r <= 0x061A) ||
      (r >= 0x064B && r <= 0x065F) ||
      r == 0x0670 ||
      (r >= 0x06D6 && r <= 0x06ED) ||
      r == 0x0640 ||
      (r >= 0x08D3 && r <= 0x08FF) ||
      (r >= 0x200B && r <= 0x200F);

  /// Folded letter code, or 0 when the character does not count
  /// (same rules as _arNorm).
  static int _letter(int r) {
    if (r == 0x0621) return 0;
    final f = _arFold[r] ?? r;
    return (f >= 0x0621 && f <= 0x064A) ? f : 0;
  }

  static bool _hasAny(Set<int> a, Set<int> b) {
    for (final x in b) {
      if (a.contains(x)) return true;
    }
    return false;
  }

  // ---------- 1. analysis of a vowelled word ----------

  /// Analyses one vowelled token (as it is written in quran.json).
  static PhoneticWord analyze(String token) {
    final gl = <_Gl>[];
    for (final r in token.runes) {
      if (_isMark(r)) {
        if (gl.isNotEmpty) gl.last.marks.add(r);
      } else {
        gl.add(_Gl(r));
      }
    }
    final n = gl.length;

    // al- at the start (after at most two prefix letters). In the Uthmani
    // script its alef is always the alef of wasl.
    var ai = -1;
    for (var i = 0; i < n && i <= 2; i++) {
      if (gl[i].base == _waslaAlef) {
        if (i + 1 < n && gl[i + 1].base == _lam) ai = i;
        break;
      }
      if (!_prefixCodes.contains(gl[i].base)) break;
    }

    final ortho = StringBuffer();
    final sounded = StringBuffer();
    final spell = StringBuffer();
    final silent = <int>{};
    var assimilated = false;
    var oi = 0;
    for (var k = 0; k < n; k++) {
      final g = gl[k];
      final f = _letter(g.base);
      if (f == 0) continue;
      final c = String.fromCharCode(f);
      ortho.write(c);
      final idx = oi;
      oi++;
      // bare lam of al- followed by a letter with shadda: sun letter, the
      // lam is not pronounced
      if (ai >= 0 &&
          k == ai + 1 &&
          g.marks.isEmpty &&
          k + 1 < n &&
          gl[k + 1].marks.contains(_shadda) &&
          _letter(gl[k + 1].base) != 0) {
        silent.add(idx);
        assimilated = true;
        continue;
      }
      // alef of wasl right after a prefix letter (وَٱلشَّمْسِ): never sounded
      if (ai > 0 && k == ai) {
        silent.add(idx);
        continue;
      }
      final dbl = g.marks.contains(_shadda);
      // the letter that carries the doubling of an al- merge: the sun letter
      // after the silent lam, or the lam of ٱلَّذِي / ٱلَّيْلِ
      final merged = ai >= 0 &&
          dbl &&
          ((k == ai + 1 && f == _lam) || (k == ai + 2 && assimilated));
      if (!g.marks.contains(_silentMark)) sounded.write(dbl ? c + c : c);
      spell.write(dbl && merged ? c + c : c);
    }

    var madd = false;
    var last = -1;
    for (var k = n - 1; k >= 0; k--) {
      if (_letter(gl[k].base) != 0) {
        last = k;
        break;
      }
    }
    if (last > 0) {
      final lf = _letter(gl[last].base);
      final m = gl[last].marks;
      final pm = gl[last - 1].marks;
      if ((lf == 0x0627 || lf == 0x0648 || lf == 0x064A) &&
          !_hasAny(m, _vowelMarks)) {
        final need = lf == 0x0627 ? 0x064E : (lf == 0x0648 ? 0x064F : 0x0650);
        madd = pm.contains(need) || (lf == 0x0627 && !_hasAny(pm, _tanween));
      }
    }

    return PhoneticWord(
      surface: token,
      ortho: ortho.toString(),
      sounded: sounded.toString(),
      spell: spell.toString(),
      hasArticle: ai >= 0,
      assimilated: assimilated,
      waslStart: n > 0 && gl[0].base == _waslaAlef,
      endsWithMadd: madd,
      silent: silent,
    );
  }

  // ---------- 2. chains (wasl: no spaces between words) ----------

  /// The words written as one string without spaces. The alef of wasl is
  /// dropped for every word that is joined to the one before it; with
  /// [sounded] (full pronunciation) a long vowel in front of it is shortened
  /// as well. [startOfUtterance] false means the first word is also joined
  /// to something the reader said before.
  static String chain(
    List<PhoneticWord> ws, {
    bool sounded = true,
    bool startOfUtterance = true,
    bool elideMadd = true,
  }) {
    final parts = <String>[];
    for (var i = 0; i < ws.length; i++) {
      var t = sounded ? ws[i].sounded : ws[i].spell;
      final joined = i > 0 || !startOfUtterance;
      if (joined && ws[i].waslStart && t.startsWith(_alefS)) {
        t = t.substring(1);
        if (sounded &&
            elideMadd &&
            i > 0 &&
            parts.isNotEmpty &&
            ws[i - 1].endsWithMadd &&
            parts.last.isNotEmpty) {
          parts[parts.length - 1] =
              parts.last.substring(0, parts.last.length - 1);
        }
      }
      parts.add(t);
    }
    return parts.join();
  }

  // ---------- 3. recogniser text (no vowel marks) ----------

  static final Map<String, List<_Form>> _formsCache = <String, List<_Form>>{};

  /// Possible pronunciations of a plain skeleton: [0] is the skeleton itself,
  /// [1] (when it looks like al- + noun) has the lam merged into a sun letter.
  static List<_Form> _forms(String sk) {
    final hit = _formsCache[sk];
    if (hit != null) return hit;
    if (_formsCache.length > 30000) _formsCache.clear();
    final out = <_Form>[_Form(sk, false)];
    var at = -1;
    for (var p = 0; p <= 2 && p + 1 < sk.length; p++) {
      if (p > 0 && !_prefixChars.contains(sk[p - 1])) break;
      if (sk[p] == _alefS && sk[p + 1] == '\u0644') {
        at = p;
        break;
      }
    }
    if (at >= 0) {
      final base = sk.substring(at);
      if (base.length >= 4) {
        final head = sk.substring(0, at) + (at == 0 ? _alefS : '');
        String text;
        if (_relative.contains(base)) {
          text = head + '\u0644\u0644' + base.substring(2);
        } else if (_sun.contains(base[2])) {
          text = head + base[2] + base[2] + base.substring(3);
        } else {
          text = head + base.substring(1);
        }
        out.add(_Form(text, at == 0));
      }
    }
    _formsCache[sk] = out;
    return out;
  }

  /// Extra word test used next to _sameWord: [h] (heard) and [e] (expected)
  /// are plain skeletons; [alts] are the expected word's own pronunciations
  /// taken from its vowelled text. True when they agree once al- is merged
  /// into the sun letter. The plain-with-plain case is left to _sameWord.
  static bool sameSpelling(String h, String e, double thr,
      [Iterable<String>? alts]) {
    final fh = _forms(h);
    final ce = <String>[];
    for (final f in _forms(e)) {
      ce.add(f.text);
    }
    if (alts != null) {
      for (final a in alts) {
        ce.add(a);
        final fa = _forms(a);
        for (var i = 1; i < fa.length; i++) {
          ce.add(fa[i].text);
        }
      }
    }
    for (var i = 0; i < fh.length; i++) {
      for (var j = 0; j < ce.length; j++) {
        if (i == 0 && j == 0) continue;
        if (fh[i].text == ce[j] || _sameWord(fh[i].text, ce[j], thr)) {
          return true;
        }
      }
    }
    return false;
  }

  /// Every way the heard words can be written as one space-free chain.
  static List<String> heardChains(List<String> tokens) {
    var combos = <String>[''];
    for (var j = 0; j < tokens.length; j++) {
      final fs = <String>[];
      for (final f in _forms(tokens[j])) {
        var t = f.text;
        if (j > 0 && f.article && t.startsWith(_alefS)) t = t.substring(1);
        if (!fs.contains(t)) fs.add(t);
        if (j > 0 && t.length > 1 && t.startsWith(_alefS)) {
          final d = t.substring(1);
          if (!fs.contains(d)) fs.add(d);
        }
      }
      final next = <String>[];
      for (final c in combos) {
        for (final t in fs) {
          next.add(c + t);
        }
      }
      combos = next;
    }
    return combos;
  }

  /// The heard words (plain skeletons) and the expected words give exactly the
  /// same chain, wherever the recogniser put its spaces. Exact on purpose: a
  /// wrong word inside a long chain must never be averaged away.
  static bool chainEquals(List<String> heard, List<PhoneticWord> expected) {
    var e = chain(expected, sounded: false);
    if (e.startsWith(_alefS)) e = e.substring(1);
    if (e.length < 4) return false;
    for (final h in heardChains(heard)) {
      final hh = h.startsWith(_alefS) ? h.substring(1) : h;
      if (hh == e) return true;
    }
    return false;
  }
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
LetterDiff _letterDiff(String heard, String expected, [Set<int>? silent]) {
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
          !_isMatres(heard[j - 1]) &&
          !(silent != null && silent.contains(i - 1))) {
        bad.add(i - 1);
        notes.add('پیتی «${expected[i - 1]}» وەک «${heard[j - 1]}» بیستراوە');
      }
      i--;
      j--;
    } else if (i > 0 && d[i][j] == d[i - 1][j] + 1) {
      if (!_isMatres(expected[i - 1]) &&
          !(silent != null && silent.contains(i - 1))) {
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

// ---------- granular error marks: the exact letter / sign inside a word ----------
const int _kShadda = 0x0651;
bool _isSignRune(int r) => (r >= 0x064B && r <= 0x0653) || r == 0x0670;
bool _isVowelRune(int r) => r == 0x064E || r == 0x064F || r == 0x0650;
bool _isTanweenRune(int r) => r >= 0x064B && r <= 0x064D;
int _foldRune(int r) => _arFold[r] ?? r;

/// Key of one faulty glyph inside a word: position of its letter cluster and
/// the sign (a harakah, shaddah, tanween, madd sign), or 0 = the letter itself.
int _faultKey(int pos, int code) => pos * 0x10000 + code;

/// The signs (harakat, shaddah, tanween, madd signs) written on one cluster.
List<int> _signsOf(_Cluster c) {
  final out = <int>[];
  var first = true;
  for (final r in c.text.runes) {
    if (first) {
      first = false;
      continue;
    }
    if (_isSignRune(r)) out.add(r);
  }
  return out;
}

/// What kind of sign the engine's tajweed error is about (best effort: the
/// error maps are searched for the rule's name, Arabic or English).
Set<String> _faultKinds(List<dynamic>? errs) {
  final out = <String>{};
  if (errs == null) return out;
  final madd = RegExp(r'madd|(?<![\u0621-\u064A])ال?مد(?![\u0621-\u064A])');
  for (final e in errs) {
    final t = '$e'.toLowerCase();
    if (madd.hasMatch(t)) out.add('madd');
    if (t.contains('shadd') ||
        t.contains('tashdid') ||
        t.contains('ghunna') ||
        t.contains('idgham') ||
        t.contains('شدة') ||
        t.contains('تشديد') ||
        t.contains('غنة') ||
        t.contains('إدغام') ||
        t.contains('ادغام')) {
      out.add('shadda');
    }
    if (t.contains('tanw') || t.contains('تنوين') || t.contains('تنوین')) {
      out.add('tanween');
    }
  }
  return out;
}

/// Faulty glyphs of the expected word for the given kinds of error.
Set<int> _kindFaults(List<_Cluster> cl, Set<String> kinds) {
  final out = <int>{};
  if (kinds.isEmpty) return out;
  for (var p = 0; p < cl.length; p++) {
    final sg = _signsOf(cl[p]);
    if (kinds.contains('shadda') && sg.contains(_kShadda)) {
      out.add(_faultKey(p, _kShadda));
    }
    if (kinds.contains('tanween')) {
      for (final r in sg) {
        if (_isTanweenRune(r)) out.add(_faultKey(p, r));
      }
    }
    if (kinds.contains('madd')) {
      for (final r in sg) {
        if (r == 0x0653 || r == 0x0670) out.add(_faultKey(p, r));
      }
      // the long-vowel letter that carries the madd: ا after fatha,
      // و after damma, ي after kasra
      if (p > 0) {
        final base = _foldRune(cl[p].text.runes.first);
        final prev = _signsOf(cl[p - 1]);
        final carries = (base == 0x0627 && prev.contains(0x064E)) ||
            (base == 0x0648 && prev.contains(0x064F)) ||
            (base == 0x064A && prev.contains(0x0650));
        final plainLetter = !sg.any((r) => _isVowelRune(r) || r == _kShadda);
        if (carries && plainLetter) out.add(_faultKey(p, 0));
      }
    }
  }
  return out;
}

/// Where in [text] the pattern [pat] fits best (fewest edits): [start, end
/// (exclusive), edits]. Among equal fits the latest one wins: the word was
/// said just now.
List<int> _approxLocate(String text, String pat) {
  final n = pat.length;
  final m = text.length;
  if (n == 0 || m == 0) return [0, 0, n];
  var prev = List<int>.generate(n + 1, (i) => i);
  var bestCost = prev[n];
  var bestEnd = 0;
  for (var j = 1; j <= m; j++) {
    final cur = List<int>.filled(n + 1, 0);
    for (var i = 1; i <= n; i++) {
      final c = pat.codeUnitAt(i - 1) == text.codeUnitAt(j - 1) ? 0 : 1;
      var v = prev[i - 1] + c;
      if (prev[i] + 1 < v) v = prev[i] + 1;
      if (cur[i - 1] + 1 < v) v = cur[i - 1] + 1;
      cur[i] = v;
    }
    if (cur[n] <= bestCost) {
      bestCost = cur[n];
      bestEnd = j;
    }
    prev = cur;
  }
  if (bestEnd == 0) return [0, 0, n];
  // the start: run the same search backwards from the end
  final rp = pat.split('').reversed.join();
  final rt = text.substring(0, bestEnd).split('').reversed.join();
  prev = List<int>.generate(n + 1, (i) => i);
  var len = bestEnd;
  for (var j = 1; j <= rt.length; j++) {
    final cur = List<int>.filled(n + 1, 0);
    for (var i = 1; i <= n; i++) {
      final c = rp.codeUnitAt(i - 1) == rt.codeUnitAt(j - 1) ? 0 : 1;
      var v = prev[i - 1] + c;
      if (prev[i] + 1 < v) v = prev[i] + 1;
      if (cur[i - 1] + 1 < v) v = cur[i - 1] + 1;
      cur[i] = v;
    }
    if (cur[n] == bestCost) {
      len = j;
      break;
    }
    prev = cur;
  }
  return [bestEnd - len, bestEnd, bestCost];
}

/// Pairs (expected cluster, heard cluster) that carry the same letter.
List<List<int>> _alignClusters(List<_Cluster> e, List<_Cluster> h) {
  int base(_Cluster c) => _foldRune(c.text.runes.first);
  final n = e.length;
  final m = h.length;
  final d = List<List<int>>.generate(n + 1, (_) => List<int>.filled(m + 1, 0));
  for (var i = 0; i <= n; i++) {
    d[i][0] = i;
  }
  for (var j = 0; j <= m; j++) {
    d[0][j] = j;
  }
  for (var i = 1; i <= n; i++) {
    for (var j = 1; j <= m; j++) {
      final c = base(e[i - 1]) == base(h[j - 1]) ? 0 : 1;
      var v = d[i - 1][j - 1] + c;
      if (d[i - 1][j] + 1 < v) v = d[i - 1][j] + 1;
      if (d[i][j - 1] + 1 < v) v = d[i][j - 1] + 1;
      d[i][j] = v;
    }
  }
  final out = <List<int>>[];
  var i = n;
  var j = m;
  while (i > 0 && j > 0) {
    final same = base(e[i - 1]) == base(h[j - 1]);
    if (d[i][j] == d[i - 1][j - 1] + (same ? 0 : 1)) {
      if (same) out.add([i - 1, j - 1]);
      i--;
      j--;
    } else if (d[i][j] == d[i - 1][j] + 1) {
      i--;
    } else {
      j--;
    }
  }
  return out.reversed.toList();
}

/// The pieces of one letter cluster: the letter and each of its signs, with
/// only the faulty ones in red; the rest of the word keeps its normal colour.
List<TextSpan> _signSpans(_Cluster c, int p, Set<int> faults, TextStyle plain,
    TextStyle hot, Color host) {
  final runes = c.text.runes.toList();
  var markFault = false;
  for (var k = 1; k < runes.length; k++) {
    if (faults.contains(_faultKey(p, runes[k]))) markFault = true;
  }
  final letterFault = faults.contains(_faultKey(p, 0));
  final out = <TextSpan>[
    TextSpan(
      text: String.fromCharCode(runes[0]),
      style: letterFault
          ? hot.copyWith(backgroundColor: const Color(0x66E53935))
          // a tiny sign is hard to see: its letter gets a faint pointer
          : (markFault ? plain.copyWith(backgroundColor: host) : plain),
    ),
  ];
  for (var k = 1; k < runes.length; k++) {
    out.add(TextSpan(
      text: String.fromCharCode(runes[k]),
      style: faults.contains(_faultKey(p, runes[k]))
          ? hot.copyWith(fontWeight: FontWeight.normal)
          : plain,
    ));
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

  /// Pronunciation of [words] taken from the vowelled text (null: layer off).
  final List<PhoneticWord>? phon;
  final Map<String, List<String>> _alt;

  RecitationAligner(this.words, {int hint = 0, this.phon})
      : st = List<int>.filled(words.length, 0),
        cursor = hint,
        _hint = hint,
        _alt = _altMap(words, phon);

  /// skeleton -> pronunciations that differ from it (الليل for اليل)
  static Map<String, List<String>> _altMap(
      List<String> words, List<PhoneticWord>? ph) {
    final m = <String, List<String>>{};
    if (ph == null || ph.length != words.length) return m;
    for (var i = 0; i < words.length; i++) {
      final s = ph[i].spell;
      if (ph[i].ortho != words[i] || s == words[i]) continue;
      final l = m.putIfAbsent(words[i], () => <String>[]);
      if (!l.contains(s)) l.add(s);
    }
    return m;
  }

  bool get finished => cursor >= words.length;
  double get _thr =>
      level == 0 ? 0.6 : (level == 1 ? 0.7 : (level == 2 ? 0.8 : 0.88));
  bool get _instant => level >= 3; // flag a wrong word without waiting
  bool _same(String h, String e) {
    if (_sameWord(h, e, _thr)) return true;
    if (!kPhoneticLayer) return false;
    return QuranPhonetics.sameSpelling(h, e, _thr, _alt[e]);
  }

  /// [heard words used, expected words covered] when the next heard words,
  /// read as one space-free chain, equal the next expected words.
  List<int>? _chainMatch() {
    final ph = phon;
    if (ph == null || ph.length != words.length) return null;
    for (var tot = 3; tot <= 6; tot++) {
      for (var k = 1; k <= 3; k++) {
        final m = tot - k;
        if (m < 1 || m > 3) continue;
        if (k > _pending.length || cursor + m > words.length) continue;
        if (QuranPhonetics.chainEquals(
            _pending.sublist(0, k), ph.sublist(cursor, cursor + m))) {
          return <int>[k, m];
        }
      }
    }
    return null;
  }

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

      // 3b. phonetic chain: the heard words and the expected words as one
      // space-free string (wasl alef dropped, al- merged into a sun letter)
      if (kPhoneticLayer && phon != null) {
        final c = _chainMatch();
        if (c != null) {
          for (var k = 0; k < c[1]; k++) {
            _ok(cursor + k);
          }
          cursor += c[1];
          rev++;
          _pending.removeRange(0, c[0]);
          _miss = 0;
          continue;
        }
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
// The three tiers (index 0 = level 1). All of them keep the same teacher:
// error detection, red word, 3-word window and the teacher's audio. They only
// differ in how strict the phonetic matching is.
const List<String> kCoachLevels = [
  'سووک و ئاسایی',
  'مامناوەند (پێشنیارکراو)',
  'قورس و ورد',
];
const List<String> kCoachLevelHints = [
  'خوێندنەوەی ڕەوان. هەڵەی بچووکی حەرەکات و تەجوید ناوەستێنێت، و تەنها هەڵەی ڕاستەقینەی وشە ڕاست دەکرێتەوە.',
  'حەرەکاتی سەرەکی دەپشکنێت. لەگەڵ هەڵە، سێ وشەکە (پێش، هەڵە، دوای) پیشان دەدرێن و مامۆستا دەیانڵێتەوە.',
  'تەجوید، مەد، شەدە و دەنگ بە وردی دەپشکنێت و تا ڕاست نەبێت ناڕوات. چاوەڕێی کۆتایی وشە دەکات، بۆیە کەمێک خاوترە.',
];

final GlobalKey<ScaffoldMessengerState> appMessenger =
    GlobalKey<ScaffoldMessengerState>();

enum CoachState { off, starting, listening, paused, correcting }

class CoachMarks {
  final List<String> tokens;
  final List<int> marks; // 0 unread, 1 correct, 2 mistake, 3 current word, 4 tajweed slip, 5 guidance (context of a mistake)
  final Map<int, Set<int>> letters; // token index -> wrong letter indexes
  final Map<int, Set<int>> signs; // token index -> faulty glyph keys (see _faultKey)
  const CoachMarks(this.tokens, this.marks,
      [this.letters = const {}, this.signs = const {}]);
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
  List<PhoneticWord> _phon = const <PhoneticWord>[];
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
  Timer? _stall; // neural: reader did not continue after a correction
  Timer? _posTimer; // saves the recitation position a moment after it changes
  int _savedG = -1;
  bool _observing = false; // lifecycle observer stays on, to resume after a lock
  bool _resumeAfterBg = false; // the app was sent to the background mid-session
  List<Ayah>? _lastAyahs;
  // audio focus: a phone call or another app's audio pauses the session
  asn.AudioSession? _session;
  StreamSubscription<asn.AudioInterruptionEvent>? _intSub;
  StreamSubscription<void>? _noisySub;
  Timer? _intRetry;
  bool _interrupted = false;
  int _intTries = 0;
  // Contextual error window: previous word, wrong word, next word (global
  // word indexes inside one ayah). -1 = no window.
  int _ctxLo = -1, _ctxHi = -1, _ctxG = -1;
  // neural (offline acoustic model) mode
  bool _neural = false;
  rq.ReciteQuran? _nTracker;
  rq.AudioProcessor? _nMic;
  StreamSubscription<rq.WordMatchedEvent>? _nSub;
  StreamSubscription<String>? _nTrSub;
  String _dbgEv = ''; // last engine event / resync, shown under the status
  String _dbgTr = '';
  final Map<int, rq.ContinuousQuranWord> _byGlobal = {};
  List<rq.ContinuousQuranWord> _nWords = const [];
  final Map<int, int> _wordFails = {}; // global word -> mistakes in a row
  int _wBase = 1; // is wordInAyah 0- or 1-based in the package
  DateTime _unmuteAt = DateTime(2000);
  final Map<int, Set<int>> _badLetters = {};
  final Map<int, Set<int>> _badSigns = {}; // word -> faulty glyphs (see _faultKey)
  int _micChunks = 0; // diagnostics: chunks the microphone produced
  int _fed = 0; // diagnostics: chunks given to the engine

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
    _lastAyahs = ayahs;
    _savedG = -1;
    // The screen must not dim or lock while the teacher listens.
    try {
      WakelockPlus.enable();
    } catch (_) {}
    // Continue where the last session stopped (ayah AND word), unless the
    // reader has moved to a different place on purpose.
    var hAyah = hintAyah;
    var hWord = 0;
    if (settings.coachSurah == surahNo &&
        settings.coachAyah > 0 &&
        (settings.coachAyah - hintAyah).abs() <= 3) {
      hAyah = settings.coachAyah;
      hWord = settings.coachWord;
    }
    _build(ayahs, hAyah, hWord);
    _set(CoachState.starting, 'مایکرۆفۆن ئامادە دەکرێت...');
    if (!_observing) {
      WidgetsBinding.instance.addObserver(this);
      _observing = true;
    }
    audio.addListener(_onAudio);
    if (audio.surah != 0) await audio.stop(); // the mic must not hear the speaker
    _neural = true; // all three levels use the offline engine
    await _initSession(); // audio focus: calls pause the session safely
    audio.trimCache(); // keep the downloaded audio under its size limit
    final ok = _neural ? await _initNeural() : await _init();
    if (!on) return;
    if (!ok) {
      await stop(msg: message);
      return;
    }
    if (_neural) {
      _prefetchAhead();
      _set(CoachState.listening, 'گوێم لێتە - دەستپێبکە بخوێنە');
      return;
    }
    await _listen();
  }

  Future<void> stop({String msg = ''}) async {
    if (!on && state == CoachState.off) return;
    _flushPos(); // keep the exact ayah and word for the next session
    _posTimer?.cancel();
    _intRetry?.cancel();
    _interrupted = false;
    try {
      WakelockPlus.disable();
    } catch (_) {}
    final wasCorrecting = _correcting;
    on = false;
    _correcting = false;
    _corrArmed = false;
    _restart?.cancel();
    _safety?.cancel();
    _idle?.cancel();
    _stall?.cancel();
    _ctxLo = _ctxHi = _ctxG = -1;
    _badLetters.clear();
    _badSigns.clear();
    audio.removeListener(_onAudio);
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
    await _releaseSession();
    if (msg.isNotEmpty) {
      appMessenger.currentState
          ?.showSnackBar(SnackBar(content: Text(msg)));
    }
  }

  // ---------- audio focus: calls and other apps ----------
  /// Holds the audio focus while the teacher listens, so Android/iOS tell us
  /// when a call or another app takes the audio away.
  Future<void> _initSession() async {
    try {
      final s = await asn.AudioSession.instance;
      await s.configure(asn.AudioSessionConfiguration(
        avAudioSessionCategory: asn.AVAudioSessionCategory.playAndRecord,
        avAudioSessionCategoryOptions:
            asn.AVAudioSessionCategoryOptions.allowBluetooth |
                asn.AVAudioSessionCategoryOptions.defaultToSpeaker,
        androidAudioAttributes: const asn.AndroidAudioAttributes(
          contentType: asn.AndroidAudioContentType.speech,
          usage: asn.AndroidAudioUsage.media,
        ),
        androidAudioFocusGainType: asn.AndroidAudioFocusGainType.gain,
      ));
      await s.setActive(true);
      if (_session == null) {
        _session = s;
        _intSub = s.interruptionEventStream.listen(_onInterruption);
        _noisySub = s.becomingNoisyEventStream.listen((_) => _onRouteChange());
      }
    } catch (_) {
      // without audio focus the coach still works, it just cannot pause itself
    }
  }

  /// Gives the audio focus back (normal listening to the Quran afterwards).
  Future<void> _releaseSession() async {
    try {
      final s = _session;
      if (s == null) return;
      await s.setActive(false);
      await s.configure(asn.AudioSessionConfiguration.music());
    } catch (_) {}
  }

  void _onInterruption(asn.AudioInterruptionEvent e) {
    if (!on || state == CoachState.starting) return;
    if (e.begin) {
      if (e.type == asn.AudioInterruptionType.duck) return; // a short prompt
      if (e.type == asn.AudioInterruptionType.unknown) {
        // another app took the audio for good: close cleanly, position kept
        stop(msg: 'دەنگێکی دیکە گوێگرتنی وەستاند. مایک دووبارە هەڵبکە، لە هەمان شوێن بەردەوام دەبێت.');
        return;
      }
      _pauseForInterruption();
    } else {
      _resumeFromInterruption();
    }
  }

  /// Headphones unplugged / Bluetooth changed: the microphone has another
  /// source now, so open it again.
  Future<void> _onRouteChange() async {
    if (!on || _interrupted || _correcting || state == CoachState.starting) {
      return;
    }
    await _restartMic();
    _unmuteAt = DateTime.now();
  }

  /// A call (or similar) started: close the microphone safely, keep the
  /// position, wait for the end.
  Future<void> _pauseForInterruption() async {
    if (_interrupted || !on) return;
    _interrupted = true;
    _intTries = 0;
    _flushPos();
    _stall?.cancel();
    _safety?.cancel();
    _idle?.cancel();
    _restart?.cancel();
    _correcting = false;
    _corrArmed = false;
    if (audio.surah != 0) {
      try {
        await audio.stop();
      } catch (_) {}
    }
    final old = _nMic;
    _nMic = null;
    if (old != null) {
      try {
        await (old as dynamic).stop();
      } catch (_) {}
      try {
        await (old as dynamic).dispose();
      } catch (_) {}
    }
    if (!on) return;
    _set(CoachState.paused,
        'وەستا - پەیوەندی تەلەفۆن یان دەنگێکی دیکە. کە تەواو بوو، خۆی بەردەوام دەبێت.');
    // the end event can get lost: ask for the audio focus again now and then
    _intRetry?.cancel();
    _intRetry = Timer.periodic(const Duration(seconds: 3), (_) => _tryResume());
  }

  Future<void> _tryResume() async {
    if (!on || !_interrupted) {
      _intRetry?.cancel();
      return;
    }
    if (++_intTries > 40) {
      // two minutes without the audio coming back
      stop(msg: 'گوێگرتن وەستا. مایک دووبارە هەڵبکە، لە هەمان شوێن بەردەوام دەبێت.');
      return;
    }
    var ok = false;
    try {
      final s = _session ?? await asn.AudioSession.instance;
      ok = await s.setActive(true);
    } catch (_) {}
    if (ok) await _resumeFromInterruption();
  }

  /// The call ended: microphone on again, engine back on the saved word.
  Future<void> _resumeFromInterruption() async {
    if (!_interrupted || !on) return;
    _interrupted = false;
    _intRetry?.cancel();
    _set(CoachState.listening, 'ئامادەبە...');
    _resyncTracker();
    await _restartMic();
    if (!on) return;
    _unmuteAt = DateTime.now();
    final ph = _ctxLo >= 0 ? _ctxPhrase() : _cursorWord();
    _set(CoachState.listening,
        ph.isNotEmpty ? 'بەردەوام بە لە: «$ph»' : 'گوێم لێتە - دەستپێبکە بخوێنە');
  }

  /// Called when the reading page is closed.
  void detach(int surahNo) {
    _resumeAfterBg = false;
    if (on && surah == surahNo) scheduleMicrotask(() => stop());
  }

  @override
  void notifyListeners() {
    super.notifyListeners();
    _trackPos();
  }

  /// Every change of the cursor schedules a save (one write per pause, not one
  /// per word).
  void _trackPos() {
    final al = _al;
    if (!on || al == null || _wayah.isEmpty || state == CoachState.starting) {
      return;
    }
    if (al.cursor == _savedG) return;
    _savedG = al.cursor;
    _posTimer?.cancel();
    _posTimer = Timer(const Duration(milliseconds: 600), _flushPos);
  }

  /// Writes the current ayah and word to the phone now.
  void _flushPos() {
    _posTimer?.cancel();
    final al = _al;
    if (al == null || _wayah.isEmpty || surah == 0) return;
    if (state == CoachState.starting) return;
    if (al.cursor >= _wayah.length) {
      settings.saveCoachPos(surah, 0, 0); // surah finished: nothing to resume
      return;
    }
    final g = al.cursor < 0 ? 0 : al.cursor;
    final ai = _wayah[g];
    settings.saveCoachPos(surah, _ayahs[ai].n, g - _starts[ai]);
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
    final signs = <int, Set<int>>{};
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
      if (al.st[g] == 2 || al.st[g] == 4) {
        final bs = _badSigns[g];
        if (bs != null && bs.isNotEmpty) signs[t] = bs;
      }
      // contextual error window: the wrong word red, its neighbours in the
      // guidance colour, until each of them has been read again correctly
      if (_ctxLo >= 0 && g >= _ctxLo && g <= _ctxHi && al.st[g] != 1) {
        out[t] = g == _ctxG ? 2 : 5;
      }
    }
    return CoachMarks(toks, out, letters, signs);
  }

  // ---------- setup ----------
  void _set(CoachState s, String m) {
    state = s;
    message = m;
    notifyListeners();
  }

  void _build(List<Ayah> ayahs, int hintAyah, [int hintWord = 0]) {
    _ayahs = ayahs;
    final tokens = <List<String>>[];
    final isWord = <List<bool>>[];
    final starts = <int>[];
    final wayah = <int>[];
    final words = <String>[];
    final phon = <PhoneticWord>[];
    for (var i = 0; i < ayahs.length; i++) {
      final toks = ayahs[i].ar.split(RegExp(r'\s+')).where((t) => t.isNotEmpty).toList();
      final flags = <bool>[];
      starts.add(words.length);
      for (final t in toks) {
        final w = _arNorm(t);
        flags.add(w.isNotEmpty);
        if (w.isNotEmpty) {
          words.add(w);
          phon.add(QuranPhonetics.analyze(t));
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
      if (ayahs[i].n == hintAyah) {
        var w = hintWord;
        final span = starts[i + 1] - starts[i];
        if (w >= span) w = span - 1;
        if (w < 0) w = 0;
        hint = starts[i] + w;
      }
    }
    _phon = phon;
    final al = RecitationAligner(words,
        hint: hint, phon: kPhoneticLayer ? phon : null);
    al.level = settings.coachLevel;
    _al = al;
    _wasLocked = false;
    _consumed = 0;
    _lastHeard = const [];
    _flushed = true;
    _corrArmed = false;
    _correcting = false;
    _badLetters.clear();
    _badSigns.clear();
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
    if (!on || _correcting || _neural) return;
    if (s == 'done' || s == 'notListening' || s == 'doneNoResult') {
      _flushPending();
      if (on && !_correcting) _scheduleRestart(const Duration(milliseconds: 350));
    }
  }

  void _onError(SpeechRecognitionError e) {
    if (!on || _correcting || _neural) return;
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
  /// Engine settings for the chosen level. The factories are used on purpose
  /// (the enum member names of MatchingStrictness are not known for sure).
  ///  1 easy     : forgiving matching, early commit, auto re-anchor
  ///  2 balanced : normal matching, early commit, auto re-anchor
  ///  3 strict   : strict matching, waits for the full vowel length (exact
  ///               madd / ghunna / shadda), no re-anchoring (gatekeeper)
  rq.TrackerConfig _trackerConfig() {
    final speed = const [
      rq.RecitationSpeed.fast,
      rq.RecitationSpeed.normal,
      rq.RecitationSpeed.slow,
    ][settings.coachSpeed];
    switch (settings.coachLevel) {
      case 1:
        return rq.TrackerConfig.easy(
          speed: speed,
          enableEarlyMatching: true,
          enableAutoReanchor: true,
          reanchorStallThreshold: 24,
        );
      case 3:
        return rq.TrackerConfig.strict(
          speed: speed,
          enableEarlyMatching: false,
          enableAutoReanchor: false,
          reanchorStallThreshold: 30,
        );
      default:
        return rq.TrackerConfig.normal(
          speed: speed,
          enableEarlyMatching: true,
          enableAutoReanchor: true,
          reanchorStallThreshold: 24,
        );
    }
  }

  /// How many corrections of the same word before the app lets it pass.
  int get _maxFails =>
      settings.coachLevel == 1 ? 2 : (settings.coachLevel == 3 ? 5 : 3);

  Future<bool> _initNeural() async {
    // The offline engine never asks for the microphone itself, so after a
    // fresh install it fails with "PCM reader failed to initialize". The
    // speech_to_text plugin shows the Android permission dialog when it is
    // initialised, so do that first (its result is not needed here).
    try {
      await _init();
    } catch (_) {}
    try {
      final repo = rq.QuranRepository(rq.QuranMetadataService());
      await repo.loadSurahAsync(surah);
      final tracker = rq.ReciteQuran(
        repository: repo,
        config: _trackerConfig(),
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
      // resumed session: put the engine on the saved word (it starts at word 0)
      final al0 = _al;
      if (al0 != null && al0.cursor > 0) _resyncTracker();
      // what the engine hears + its last result, shown under the status line
      _dbgEv = '';
      _dbgTr = '';
      _nTrSub = tracker.onTranscript.listen((t) {
        if (!on || !_neural) return;
        _dbgTr = t;
        heardText.value = '$_dbgEv  $_dbgTr';
      });
      await _startMic();
      return true;
    } catch (e) {
      await _teardownNeural();
      message = 'مۆدێلی دەنگ بار نەبوو (فایلی مۆدێلەکە لەناو ئەپەکەدا نییە، یان مایکرۆفۆن ڕێگەپێدراو نییە): $e';
      return false;
    }
  }

  Future<void> _startMic() async {
    final tr = _nTracker;
    if (tr == null) return;
    final mic = rq.AudioProcessor();
    _nMic = mic;
    await mic.start(onChunk: (chunk, isFinal) {
      if (!identical(_nMic, mic)) return; // an old microphone: ignore
      _micChunks++;
      if (!on || !_neural || _correcting || audio.playing) return;
      if (DateTime.now().isBefore(_unmuteAt)) return;
      _fed++;
      tr.feedAudioChunk(chunk, isFinal: isFinal);
    });
  }

  /// Playing the teacher's audio can leave the microphone stream dead on
  /// Android (audio focus). After every correction the microphone is closed
  /// and opened again, so the engine surely hears the re-read word.
  Future<void> _restartMic() async {
    final old = _nMic;
    _nMic = null;
    if (old != null) {
      try {
        await (old as dynamic).stop();
      } catch (_) {}
      try {
        await (old as dynamic).dispose();
      } catch (_) {}
    }
    if (!on || !_neural) return;
    try {
      await _startMic();
    } catch (_) {
      _dbgEv = '$_dbgEv [مایک هەڵە]';
      heardText.value = '$_dbgEv  $_dbgTr';
    }
  }

  /// The package's global word index of the app's word number [g].
  int? _globalOf(int g) {
    if (g < 0 || g >= _wayah.length) return null;
    final ai = _wayah[g];
    final ayahN = _ayahs[ai].n;
    final wi = g - _starts[ai] + _wBase;
    for (final w in _nWords) {
      if (w.ayah == ayahN && w.wordInAyah == wi) return w.globalIndex;
    }
    return null;
  }

  /// After a correction the engine must wait for the word the reader has to
  /// say again (not the word after it): clear its audio buffer and put its
  /// tracking cursor back on that word.
  void _resyncTracker() {
    final tr = _nTracker;
    final al = _al;
    if (tr == null || al == null) return;
    // with an error window the engine goes back to its first word, so the
    // reader says the whole short phrase again
    final target = _ctxLo >= 0 ? _ctxLo : al.cursor;
    final gi = _globalOf(target);
    if (gi == null) {
      _dbgEv = '[jump: ؟]';
      heardText.value = '$_dbgEv  $_dbgTr';
      return;
    }
    try {
      tr.resetBuffer();
      _dbgTr = ''; // old text must not vouch for words read after the correction
      tr.setTargetSurah(surah, startGlobalWord: gi, forceClear: true);
      tr.jumpToWord(gi);
      _dbgEv = '[jump #$gi]';
    } catch (e) {
      _dbgEv = '[jump هەڵە]';
    }
    heardText.value = '$_dbgEv  $_dbgTr';
  }

  /// Level 6: keep the next few words' audio ready on the phone.
  /// Keeps the teacher's audio of the current and the next ayah on the phone,
  /// so a correction can start with no network wait.
  void _prefetchAhead() {
    final al = _al;
    if (al == null || !_neural || _wayah.isEmpty) return;
    final g = al.cursor >= _wayah.length ? _wayah.length - 1 : al.cursor;
    if (g < 0) return;
    final ai = _wayah[g];
    audio.prefetchAyah(surah, _ayahs[ai].n);
    if (ai + 1 < _ayahs.length) audio.prefetchAyah(surah, _ayahs[ai + 1].n);
  }

  Future<void> _teardownNeural() async {
    final sub = _nSub;
    final trSub = _nTrSub;
    _nTrSub = null;
    try {
      await trSub?.cancel();
    } catch (_) {}
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
        DateTime.now().isBefore(_unmuteAt)) {
      return;
    }
    _stall?.cancel(); // the engine heard something: no stall
    _dbgEv = '[#${ev.wordId} ${ev.isRed ? 'سوور' : ((ev as dynamic).isNeutral == true ? 'بازدان' : 'سەوز')}]';
    heardText.value = '$_dbgEv  $_dbgTr';
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
    // level 1 lets small tajweed / diacritic slips pass; 2 and 3 correct them
    final slip = errs != null && errs.isNotEmpty && settings.coachLevel >= 2;
    al.locked = true;
    final pos = w.wordInAyah - _wBase + 1;
    // Second opinion for a word the engine called wrong: when the reader
    // joins words (wasl, al- + sun letter) the engine's word-by-word alignment
    // can fail although the recitation is right. The transcript is compared
    // as one space-free chain with the expected words (QuranPhonetics).
    if (ev.isRed && !_correcting && kPhoneticLayer) {
      final hi = _connectedSpan(ai, g); // a few microseconds of string work
      if (hi >= 0) {
        _acceptConnected(g, hi);
        return;
      }
    }
    if (ev.isRed || slip) {
      _flagNeural(ai, g, ev.isRed, slip ? _tajweedText(errs) : '', pos,
          errs: errs);
      return;
    }
    if ((ev as dynamic).isNeutral == true) return;
    if (_correcting) return; // stale result that arrived after the mistake
    al.st[g] = 1;
    _wordFails.remove(g);
    _badSigns.remove(g);
    al.cursor = g + 1;
    al.rev++;
    _ctxDoneCheck();
    if (al.cursor >= al.words.length) {
      stop(msg: 'ماشاءاللە! سوورەتەکەت تەواو کرد.');
      return;
    }
    _prefetchAhead();
    notifyListeners();
  }

  /// The error window is finished once all its words are green again: live
  /// tracking simply carries on from there.
  void _ctxDoneCheck() {
    final al = _al;
    if (al == null || _ctxLo < 0) return;
    if (al.cursor > _ctxHi) {
      // the reader (and the engine) are already past the window
      for (var k = _ctxLo; k <= _ctxHi && k < al.words.length; k++) {
        if (al.st[k] == 0) al.st[k] = 1;
      }
      _ctxLo = _ctxHi = _ctxG = -1;
      return;
    }
    for (var k = _ctxLo; k <= _ctxHi && k < al.words.length; k++) {
      if (al.st[k] != 1) return;
    }
    _ctxLo = _ctxHi = _ctxG = -1;
  }

  /// The words of the error window as text (previous, wrong, next).
  String _ctxPhrase() {
    if (_ctxLo < 0 || _ctxLo >= _wayah.length) return '';
    final out = <String>[];
    for (var k = _ctxLo; k <= _ctxHi && k < _wayah.length; k++) {
      final t = _wordText(_wayah[k], k);
      if (t.isNotEmpty) out.add(t);
    }
    return out.join(' ');
  }

  /// The exact glyphs of word [g] that are wrong: a letter, a shaddah, a
  /// tanween, a harakah or a madd sign. Two sources, both only REFINE a word
  /// the engine already flagged (they never create a mistake):
  ///  1. the engine's tajweed error (madd / shaddah-ghunna / tanween),
  ///  2. the recogniser's vowelled text for this word, compared glyph by glyph.
  /// Empty = could not tell, so the whole word is shown as wrong.
  Set<int> _pinpointSigns(int ai, int g, List<dynamic>? errs) {
    final tok = _wordText(ai, g);
    if (tok.isEmpty) return <int>{};
    final cl = _clusters(tok);
    final out = <int>{};
    out.addAll(_kindFaults(cl, _faultKinds(errs)));
    final expNorm = _arNorm(tok);
    final heardNorm = _arNorm(_dbgTr);
    if (expNorm.length >= 2 && heardNorm.length >= 2) {
      final span = expNorm.length * 4 > 40 ? expNorm.length * 4 : 40;
      final from = heardNorm.length > span ? heardNorm.length - span : 0;
      final loc = _approxLocate(heardNorm.substring(from), expNorm);
      if (loc[2] <= expNorm.length ~/ 2) {
        final s0 = from + loc[0];
        final e0 = from + loc[1];
        // letters that differ (silent letters and long vowels are not blamed)
        final ld = _letterDiff(
            heardNorm.substring(s0, e0), expNorm, _silentOf(g, expNorm));
        final cap = expNorm.length ~/ 2 > 0 ? expNorm.length ~/ 2 : 1;
        if (ld.bad.isNotEmpty && ld.bad.length <= cap) {
          for (var p = 0; p < cl.length; p++) {
            if (cl[p].idx >= 0 && ld.bad.contains(cl[p].idx)) {
              out.add(_faultKey(p, 0));
            }
          }
        }
        // harakat / shaddah / tanween on letters both sides have
        final hc = _clusters(_dbgTr)
            .where((c) => c.idx >= s0 && c.idx < e0)
            .toList();
        for (final pr in _alignClusters(cl, hc)) {
          final p = pr[0];
          final es = _signsOf(cl[p]);
          final hs = _signsOf(hc[pr[1]]);
          final ev = es.where(_isVowelRune).toSet();
          final hv = hs.where(_isVowelRune).toSet();
          final et = es.where(_isTanweenRune).toSet();
          final ht = hs.where(_isTanweenRune).toSet();
          if (ev.isNotEmpty &&
              hv.isNotEmpty &&
              !(ev.length == hv.length && ev.containsAll(hv))) {
            for (final r in ev) {
              out.add(_faultKey(p, r)); // another vowel was heard
            }
          }
          if (es.contains(_kShadda) &&
              !hs.contains(_kShadda) &&
              (hv.isNotEmpty || ht.isNotEmpty)) {
            out.add(_faultKey(p, _kShadda)); // the doubling was dropped
          }
          if (et.isNotEmpty && ht.isEmpty && hv.isNotEmpty) {
            for (final r in et) {
              out.add(_faultKey(p, r)); // tanween read as a plain vowel
            }
          }
        }
      }
    }
    return out;
  }

  /// Shows word [g] as wrong and starts the teacher-style correction.
  void _flagNeural(int ai, int g, bool wrongWord, String detail, int pos,
      {List<dynamic>? errs}) {
    final al = _al;
    if (al == null) return;
    // only the faulty letter / sign turns red (empty: the whole word does)
    final signs = _pinpointSigns(ai, g, errs);
    if (signs.isEmpty) {
      _badSigns.remove(g);
    } else {
      _badSigns[g] = signs;
    }
    al.st[g] = wrongWord ? 2 : 4;
    al.cursor = g;
    al.rev++;
    if (_correcting) {
      notifyListeners();
    } else {
      _correctNeural(ai, g, wrongWord, detail, pos);
    }
  }

  /// Last word index (inclusive) of a connected phrase around word [g] that the
  /// recogniser's text confirms, or -1. Smallest phrases first; each contains
  /// [g], stays inside the ayah, and is long enough to prove something.
  int _connectedSpan(int ai, int g) {
    if (!kPhoneticLayer || ai < 0 || ai + 1 >= _starts.length) return -1;
    final heard = _connSkel(_dbgTr);
    if (heard.length < 4) return -1;
    final a0 = _starts[ai];
    final a1 = _starts[ai + 1] - 1;
    for (var size = 1; size <= 5; size++) {
      for (var lo = g - size + 1; lo <= g; lo++) {
        final hi = lo + size - 1;
        if (lo < a0 || hi > a1 || hi >= _phon.length) continue;
        final ws = _phon.sublist(lo, hi + 1);
        // spelled as pronounced: wasl alef dropped, lam of al- merged
        final joined = _connSkel(
            QuranPhonetics.chain(ws, sounded: false, startOfUtterance: lo == a0));
        // plain letters, in case the recogniser writes al- unmerged
        final plain = _connSkel(ws.map((p) => p.ortho).join());
        final lv = settings.coachLevel;
        if (_connContains(heard, joined, lv) || _connContains(heard, plain, lv)) {
          return hi;
        }
      }
    }
    return -1;
  }

  /// The connected phrase g..hi was read correctly: green, move on.
  void _acceptConnected(int g, int hi) {
    final al = _al;
    if (al == null) return;
    for (var k = g; k <= hi && k < al.words.length; k++) {
      al.st[k] = 1;
      _wordFails.remove(k);
      _badLetters.remove(k);
      _badSigns.remove(k);
    }
    if (hi + 1 > al.cursor) al.cursor = hi + 1;
    al.rev++;
    _ctxDoneCheck();
    _stall?.cancel();
    if (al.cursor >= al.words.length) {
      stop(msg: 'ماشاءاللە! سوورەتەکەت تەواو کرد.');
      return;
    }
    _prefetchAhead();
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
    if ((_wordFails[g] ?? 0) >= _maxFails) {
      // corrected often enough: stop blocking, mark it and carry on
      _wordFails.remove(g);
      _ctxLo = _ctxHi = _ctxG = -1;
      al.st[g] = 4;
      al.cursor = g + 1;
      al.rev++;
      if (al.cursor >= al.words.length) {
        stop(msg: 'ماشاءاللە! سوورەتەکەت تەواو کرد.');
        return;
      }
      _set(CoachState.listening,
          'بەردەوام بە - وشەی «$bad» دواتر دووبارە بکەرەوە');
      return;
    }
    // live tracking is paused (_correcting) and the microphone is not fed
    _correcting = true;
    _corrArmed = false;
    final fails = (_wordFails[g] ?? 0) + 1;
    _wordFails[g] = fails;
    // Contextual error window: previous word, wrong word, next word (kept
    // inside the ayah). The teacher says exactly this phrase, connected, and
    // the reader has to say it again from its first word.
    final lo = g - 1 < _starts[ai] ? _starts[ai] : g - 1;
    final hi = g + 1 < _starts[ai + 1] ? g + 1 : _starts[ai + 1] - 1;
    _ctxLo = lo;
    _ctxHi = hi;
    _ctxG = g;
    for (var k = lo; k <= hi; k++) {
      if (k != g) al.st[k] = 0; // neighbours are shown as guidance until re-read
    }
    var before = 0;
    var through = 0;
    var total = 0;
    for (var k = _starts[ai]; k < _starts[ai + 1]; k++) {
      final n = al.words[k].length + 1;
      total += n;
      if (k < lo) before += n;
      if (k <= hi) through += n;
    }
    final from = total > 0 ? before / total : 0.0;
    final to = total > 0 ? through / total : 0.0;
    al.cursor = lo; // _resyncTracker puts the engine back on this word
    al.rev++;
    heardText.value = '';
    final phrase = _ctxPhrase();
    _set(
      CoachState.correcting,
      wrongWord
          ? 'هەڵە لە وشەی «$bad» - گوێبگرە: «$phrase»'
          : 'هەڵەی تەجوید لە وشەی «$bad»${detail.isEmpty ? '' : ' ($detail)'} - گوێبگرە: «$phrase»',
    );
    _safety?.cancel();
    _safety = Timer(const Duration(seconds: 12), _endCorrection);
    // always the connected ayah recording (never isolated word clips, which
    // sound chopped: "bismi ... Allah"), only the 3-word slice
    final f = audio.playCorrection(surah, ayah.n, from: from, to: to);
    _corrArmed = true;
    await f;
    if (_correcting && audio.corrMs > 0) {
      _safety?.cancel();
      _safety = Timer(Duration(milliseconds: audio.corrMs), _endCorrection);
    }
  }

  // ---------- correction ----------
  /// Letters of word [g] that are never pronounced (lam of al- before a sun
  /// letter): they must not be reported as "not heard".
  Set<int>? _silentOf(int g, String expected) {
    if (!kPhoneticLayer || g < 0 || g >= _phon.length) return null;
    final p = _phon[g];
    return (p.ortho == expected && p.silent.isNotEmpty) ? p.silent : null;
  }

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
      final ld =
          _letterDiff(ev.heard, ev.expected, _silentOf(ev.g, ev.expected));
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
      _resyncTracker();
      // The reader sees at once that it is their turn (no silent screen while
      // the microphone is re-opened); the engine is live a moment later.
      final sw = Stopwatch()..start();
      final ph0 = _ctxLo >= 0 ? _ctxPhrase() : '';
      if (ph0.isNotEmpty) _set(CoachState.listening, 'ئامادەبە: «$ph0»');
      await _restartMic();
      if (!on) return;
      _unmuteAt = DateTime.now();
      _dbgEv = '$_dbgEv [⏱ ${sw.elapsedMilliseconds}ms]'; // mic re-open time
      heardText.value = '$_dbgEv  $_dbgTr';
      // diagnostics: 2 s later show whether audio reaches the engine
      final c0 = _micChunks;
      final f0 = _fed;
      Timer(const Duration(seconds: 2), () {
        if (!on || !_neural) return;
        _dbgEv = '${_dbgEv.split(' [مایک').first} [مایک +${_micChunks - c0} / نێردرا +${_fed - f0}]';
        heardText.value = '$_dbgEv  $_dbgTr';
      });
      _prefetchAhead();
      // If the engine gives no word after the correction (it may be waiting
      // for the same word, or already be ahead), do not freeze on this word:
      // after 5 s the cursor moves on. Engine results still win when they come.
      _stall?.cancel();
      final pin = _al?.cursor ?? -1;
      _stall = Timer(const Duration(seconds: 5), () {
        final a = _al;
        if (!on || _correcting || a == null || a.cursor != pin) return;
        if (pin + 1 >= a.words.length) return;
        _wordFails.remove(pin);
        _ctxLo = _ctxHi = _ctxG = -1;
        a.cursor = pin + 1;
        a.rev++;
        _prefetchAhead();
        _set(CoachState.listening, 'گوێم لێتە - بەردەوام بخوێنە');
      });
      final ph = _ctxLo >= 0 ? _ctxPhrase() : '';
      final w = _cursorWord();
      _set(
          CoachState.listening,
          ph.isNotEmpty
              ? 'ئێستا ئەم دەستەواژەیە دووبارە بکەرەوە: «$ph»'
              : (w.isNotEmpty
                  ? 'ئامادەبە، لە وشەی «$w» دەست پێبکەوە...'
                  : 'گوێم لێتە'));
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
      // Android takes the microphone away in the background: stop cleanly
      // (the position is saved) and carry on from there when the app is back.
      _resumeAfterBg = true;
      stop(msg: 'گوێگرتن وەستا. کە گەڕایتەوە، لە هەمان شوێن بەردەوام دەبێت.');
    } else if (s == AppLifecycleState.resumed && _resumeAfterBg && !on) {
      _resumeAfterBg = false;
      final ay = _lastAyahs;
      final sn = settings.coachSurah;
      if (ay != null && sn > 0) {
        start(sn, ay, hintAyah: settings.coachAyah > 0 ? settings.coachAyah : 1);
      }
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
          final sg = m.signs[i];
          if ((m.marks[i] == 2 || m.marks[i] == 4) &&
              sg != null &&
              sg.isNotEmpty) {
            // granular: only the faulty letter / sign is red
            final cl = _clusters(m.tokens[i]);
            final plain = TextStyle(color: _inkColor(context));
            final hot = TextStyle(color: badColor, fontWeight: FontWeight.bold);
            spans.add(TextSpan(children: [
              for (var p = 0; p < cl.length; p++)
                ..._signSpans(cl[p], p, sg, plain, hot, const Color(0x44E53935)),
              if (i < m.tokens.length - 1) const TextSpan(text: ' '),
            ]));
            continue;
          }
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
            case 5: // guidance: the words around a mistake, to be read again
              s = TextStyle(
                color: dark ? const Color(0xFF4DB6AC) : const Color(0xFF00796B),
                backgroundColor: const Color(0x2200897B),
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
