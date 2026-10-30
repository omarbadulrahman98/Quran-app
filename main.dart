// قورئانی پیرۆز - Flutter project (data from assets/quran/*.json)
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'dart:async';
import 'dart:io' show File, Directory, HttpClient, Platform;

import 'package:just_audio/just_audio.dart';
import 'package:just_audio_background/just_audio_background.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';
import 'dart:typed_data' show Int32List, Int64List, Uint16List;
import 'dart:ui' as ui show FrameTiming;
import 'package:flutter/foundation.dart' show compute, debugPrint;
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
import 'package:flutter_compass/flutter_compass.dart' as fc;
import 'package:flutter_local_notifications/flutter_local_notifications.dart'
    as fln;
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tzl;

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
  await PrayerData.load(); // assets/prayer_times.json -> extra cities / days
  try {
    // Adhan notifications: same PrayerCalc data as the prayer card.
    await locPrefs.ensureLoaded();
    await adhanPrefs.load();
    await AdhanScheduler.init();
    locPrefs.addListener(AdhanScheduler.scheduleSoon);
    adhanPrefs.addListener(AdhanScheduler.scheduleSoon);
    WidgetsBinding.instance.addObserver(_AdhanLifecycle());
    AdhanScheduler.scheduleSoon();
  } catch (_) {}
  assert(PrayerCalc.selfTest()); // debug only: Awqaf benchmark of 29/10/2026
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
        home: const DashboardPage(),
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
  final bool autoCoach; // opened from the microphone card: switch the teacher on
  const SurahPage({
    super.key,
    required this.number,
    this.initialAyah = 0,
    this.autoCoach = false,
  });

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
    if (widget.autoCoach) {
      _future.then((a) {
        if (!mounted) return;
        _ayahs = a;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _turnCoachOn();
        });
      }).catchError((Object _) {});
    }
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
    final a = coach.followAyah;
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
    // no start position: the reader may begin at any ayah, the coach finds it
    coach.start(widget.number, ay);
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
  int corrMs = 0; // estimated length of the slice being replayed (0 = whole rest of the ayah)

  Future<void> playCorrection(int s, int a,
      {double from = 0, double to = 0}) async {
    corrMs = 0;
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

  final HttpClient _http = HttpClient()
    ..connectionTimeout = const Duration(seconds: 6)
    ..maxConnectionsPerHost = 6;

  // Coach voice (one ayah per file), downloaded ahead of time so a correction
  // starts at once from a local file instead of waiting for the network.
  final Map<String, String> _ayahCache = {}; // 's_a' -> local mp3 (oldest first)
  final Set<String> _ayahLoading = {};

  String _coachUrl(int s, int a) =>
      'https://everyayah.com/data/$kCoachReciter/${s.toString().padLeft(3, '0')}${a.toString().padLeft(3, '0')}.mp3';

  bool _trimming = false; // one clean-up at a time
  final Set<String> _writing = {}; // files being downloaded right now

  /// Keeps the downloaded audio under [kAudioCacheMaxBytes]: the least recently
  /// used files go first, and anything older than [kAudioCacheMaxAge] goes
  /// anyway. Also removes files that earlier sessions or older app versions
  /// left in the temp folder. Files in [keepPaths] are never removed.
  Future<void> trimCache({Set<String> keepPaths = const {}}) async {
    if (_trimming) return;
    _trimming = true;
    try {
      final files = <_CachedFile>[];
      await for (final e in Directory.systemTemp.list()) {
        if (e is! File) continue;
        final name = e.uri.pathSegments.last;
        // '.mp3.part' = a download that never finished (older session)
        final ours = (name.startsWith('ay_') || name.startsWith('w_')) &&
            (name.endsWith('.mp3') || name.endsWith('.mp3.part'));
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
        if (keepPaths.contains(f.file.path) || _writing.contains(f.file.path)) {
          continue;
        }
        try {
          await f.file.delete();
          total -= f.size;
        } catch (_) {}
        _ayahCache.removeWhere((_, p) => p == f.file.path);
      }
    } catch (_) {
    } finally {
      _trimming = false;
    }
  }

  /// Marks a cached file as just used, so it is the last one to be removed.
  Future<void> _touch(String path) async {
    try {
      await File(path).setLastModified(DateTime.now());
    } catch (_) {}
  }

  /// Downloads [url] into [path]. The data goes to a '.part' file first and is
  /// renamed only when complete, so a broken download never leaves a half file
  /// that could be played or that wastes space.
  Future<bool> _download(String url, String path) async {
    final part = File('$path.part');
    _writing.add(path);
    _writing.add(part.path);
    try {
      final req = await _http.getUrl(Uri.parse(url));
      final res = await req.close();
      if (res.statusCode != 200) {
        await res.drain<void>();
        return false;
      }
      await res.timeout(const Duration(seconds: 20)).pipe(part.openWrite());
      await part.rename(path);
      return true;
    } catch (_) {
      try {
        if (part.existsSync()) await part.delete();
      } catch (_) {}
      return false;
    } finally {
      _writing.remove(path);
      _writing.remove(part.path);
    }
  }

  Future<void> prefetchAyah(int s, int a) async {
    final key = '${s}_$a';
    if (_ayahCache.containsKey(key) || _ayahLoading.contains(key)) return;
    _ayahLoading.add(key);
    try {
      final path = '${Directory.systemTemp.path}/ay_$key.mp3';
      if (await _download(_coachUrl(s, a), path)) {
        _ayahCache[key] = path;
        await trimCache(keepPaths: {path});
      }
    } catch (_) {
    } finally {
      _ayahLoading.remove(key);
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
  final n = pat.length;
  var prev = List<int>.generate(n + 1, (i) => i);
  var cur = List<int>.filled(n + 1, 0); // cur[0] stays 0: free start
  var best = prev[n];
  for (var j = 1; j <= text.length; j++) {
    final tj = text.codeUnitAt(j - 1);
    for (var i = 1; i <= n; i++) {
      final c = pat.codeUnitAt(i - 1) == tj ? 0 : 1;
      var v = prev[i - 1] + c;
      if (prev[i] + 1 < v) v = prev[i] + 1;
      if (cur[i - 1] + 1 < v) v = cur[i - 1] + 1;
      cur[i] = v;
    }
    if (cur[n] < best) best = cur[n];
    final t = prev;
    prev = cur;
    cur = t;
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
  var cur = List<int>.filled(n + 1, 0); // cur[0] stays 0: free start
  var bestCost = prev[n];
  var bestEnd = 0;
  for (var j = 1; j <= m; j++) {
    final tj = text.codeUnitAt(j - 1);
    for (var i = 1; i <= n; i++) {
      final c = pat.codeUnitAt(i - 1) == tj ? 0 : 1;
      var v = prev[i - 1] + c;
      if (prev[i] + 1 < v) v = prev[i] + 1;
      if (cur[i - 1] + 1 < v) v = cur[i - 1] + 1;
      cur[i] = v;
    }
    if (cur[n] <= bestCost) {
      bestCost = cur[n];
      bestEnd = j;
    }
    final t = prev;
    prev = cur;
    cur = t;
  }
  if (bestEnd == 0) return [0, 0, n];
  // the start: run the same search backwards from the end
  final rp = String.fromCharCodes(pat.codeUnits.reversed);
  final rt = String.fromCharCodes(text.substring(0, bestEnd).codeUnits.reversed);
  for (var i = 0; i <= n; i++) {
    prev[i] = i;
    cur[i] = 0;
  }
  var len = bestEnd;
  for (var j = 1; j <= rt.length; j++) {
    final tj = rt.codeUnitAt(j - 1);
    for (var i = 1; i <= n; i++) {
      final c = rp.codeUnitAt(i - 1) == tj ? 0 : 1;
      var v = prev[i - 1] + c;
      if (prev[i] + 1 < v) v = prev[i] + 1;
      if (cur[i - 1] + 1 < v) v = cur[i - 1] + 1;
      cur[i] = v;
    }
    if (cur[n] == bestCost) {
      len = j;
      break;
    }
    final t = prev;
    prev = cur;
    cur = t;
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
  'حەرەکاتی سەرەکی دەپشکنێت. لەگەڵ هەڵە، سێ وشەکە (پێش، هەڵە، دوای) پیشان دەدرێن و مامۆستا دەیانڵێتەوە. هەڵەی تەجویدی سەرەکی (مەدی لازم و متصل، غوننە، ئیدغام، ئیخفا...) ڕادەگرێت، بەڵام وردەکاری وەک قەڵقەلە و ماوەی مەدی جایز نا. لەگەڵ هەر هەڵەیەک وانەی پەیوەندیدار پیشان دەدرێت.',
  'تەجوید، مەد، شەدە و دەنگ بە وردی دەپشکنێت و تا ڕاست نەبێت ناڕوات. چاوەڕێی کۆتایی وشە دەکات، بۆیە کەمێک خاوترە. ماوەی مەد، کاتی غوننە و قەڵقەلە بە وردی دەپشکنرێن، بەڵام ئەو شێوازانەی وانەکان ڕێگەیان پێداوە (وەک مەدی عارض بە ٢، ٤ یان ٦ حەرەکە) هەڵە نابن.',
];

final GlobalKey<ScaffoldMessengerState> appMessenger =
    GlobalKey<ScaffoldMessengerState>();

/// A recited word further than this many words from the one the app expects
/// means the reader jumped to another place of the surah (free-flow).
const int kJumpWords = 12;

/// The microphone switches itself off when the engine processed no speech
/// for this long (saves battery and the engine's CPU).
const Duration kMicIdleTimeout = Duration(seconds: 60);

// ============================================================
//  Performance monitor: latency + frame metrics for the live coach.
//  Hot path = fixed ring buffers and one Stopwatch (no allocation per sample).
//  Show it on the phone: long-press the microphone dot in the coach panel.
// ============================================================
/// Nominal length of one audio processing cycle (one microphone chunk), ms.
const int kAudioCycleMs = 480;

/// false = no timing at all.
const bool kPerfMonitor = true;

/// true = a full report goes to the log (logcat) every 15 s while coaching.
const bool kPerfLog = true;

class _PerfMetric {
  _PerfMetric(this.budgetUs);

  /// A sample above this counts as "over" (0 = no budget).
  final int budgetUs;
  final Int32List _ring = Int32List(64);
  final Int32List _scratch = Int32List(64);
  int _next = 0;
  int count = 0;
  int over = 0;
  int maxUs = 0;
  int sumUs = 0;

  void add(int us) {
    if (us < 0) us = 0;
    if (us > 0x7fffffff) us = 0x7fffffff;
    _ring[_next] = us;
    _next = (_next + 1) & 63;
    count++;
    sumUs += us;
    if (us > maxUs) maxUs = us;
    if (budgetUs > 0 && us > budgetUs) over++;
  }

  int get avgUs => count == 0 ? 0 : sumUs ~/ count;

  /// 95th percentile of the last 64 samples.
  int get p95Us {
    final n = count < 64 ? count : 64;
    if (n == 0) return 0;
    for (var i = 0; i < 64; i++) {
      _scratch[i] = i < n ? _ring[i] : 0x7fffffff;
    }
    _scratch.sort();
    return _scratch[((n - 1) * 95) ~/ 100];
  }

  void reset() {
    _next = 0;
    count = 0;
    over = 0;
    maxUs = 0;
    sumUs = 0;
  }
}

class PerfMonitor {
  PerfMonitor._();

  final Stopwatch _clock = Stopwatch()..start();

  /// Monotonic microseconds (no DateTime allocation).
  int now() => _clock.elapsedMicroseconds;

  // ---- the 480 ms audio cycle ----
  /// Time between two microphone chunks (late = more than 1.5 cycles).
  final _PerfMetric chunkGap = _PerfMetric(kAudioCycleMs * 1500);

  /// Time the UI isolate spends inside feedAudioChunk (> 8 ms steals a frame).
  final _PerfMetric feed = _PerfMetric(8000);

  /// The whole microphone callback of one chunk.
  final _PerfMetric cycle = _PerfMetric(8000);

  /// Time from the last fed chunk to a word event from the engine.
  final _PerfMetric lag = _PerfMetric(kAudioCycleMs * 1000);

  // ---- app side ----
  /// The app's handling of one word event (colouring, phonetic check ...).
  final _PerfMetric wordEv = _PerfMetric(8000);

  // ---- dynamic ayah re-anchoring across the surah ----
  /// A whole free-flow search + jump (only runs that really searched).
  final _PerfMetric reanchor = _PerfMetric(8000);

  /// Only the surah-wide letter search.
  final _PerfMetric locate = _PerfMetric(4000);

  /// Putting the engine back on a word (resetBuffer + setTargetSurah + jump).
  final _PerfMetric resync = _PerfMetric(8000);

  /// Listening started -> first position found.
  final _PerfMetric firstAnchor = _PerfMetric(0);

  // ---- UI ----
  /// Building the coloured text of one ayah.
  final _PerfMetric marksBuild = _PerfMetric(4000);
  final _PerfMetric frameBuild = _PerfMetric(16000);
  final _PerfMetric frameRaster = _PerfMetric(16000);

  late final List<_PerfMetric> _all = [
    chunkGap, feed, cycle, lag, wordEv, reanchor, locate, resync,
    firstAnchor, marksBuild, frameBuild, frameRaster,
  ];

  int chunks = 0;
  int fed = 0;
  int frames = 0;
  int slowFrames = 0; // frame took more than 16.7 ms
  int frozenFrames = 0; // frame took more than 700 ms
  int reanchorJumps = 0; // free-flow search moved the reader
  int engineAnchors = 0; // the engine's own re-anchor moved the reader
  int uiRebuilt = 0; // ayah texts rebuilt
  int uiSkipped = 0; // ayah texts left alone (nothing changed in them)
  int skelLen = 0; // letters of the surah the search runs over

  int _lastChunkUs = -1;
  int _lastFedUs = -1;
  int _listenUs = -1;
  int _lastHudUs = 0;
  int _lastLogUs = 0;
  bool hudOn = false;
  bool _framesOn = false;
  final ValueNotifier<String> hud = ValueNotifier<String>('');
  late final void Function(List<ui.FrameTiming>) _framesCb = _onFrames;

  void reset() {
    for (final m in _all) {
      m.reset();
    }
    chunks = 0;
    fed = 0;
    frames = 0;
    slowFrames = 0;
    frozenFrames = 0;
    reanchorJumps = 0;
    engineAnchors = 0;
    uiRebuilt = 0;
    uiSkipped = 0;
    _lastChunkUs = -1;
    _lastFedUs = -1;
    _listenUs = -1;
    _lastHudUs = now();
    _lastLogUs = _lastHudUs;
  }

  /// A coaching session starts.
  void start() {
    if (!kPerfMonitor) return;
    reset();
    if (!_framesOn) {
      WidgetsBinding.instance.addTimingsCallback(_framesCb);
      _framesOn = true;
    }
  }

  /// A coaching session ends.
  void stop() {
    if (!kPerfMonitor) return;
    if (_framesOn) {
      WidgetsBinding.instance.removeTimingsCallback(_framesCb);
      _framesOn = false;
    }
    if (kPerfLog && chunks > 0) debugPrint(report());
    hud.value = '';
  }

  void toggleHud() {
    hudOn = !hudOn;
    hud.value = hudOn ? summary() : '';
  }

  void markListening() => _listenUs = now();

  void resetChunkClock() {
    _lastChunkUs = -1;
    _lastFedUs = -1;
  }

  /// A microphone chunk arrived at [t].
  void noteChunk(int t) {
    if (!kPerfMonitor) return;
    chunks++;
    final last = _lastChunkUs;
    _lastChunkUs = t;
    if (last >= 0) {
      final gap = t - last;
      if (gap < 5000000) chunkGap.add(gap); // longer = mic was restarted
    }
    if (t - _lastHudUs >= 1000000) {
      _lastHudUs = t;
      if (hudOn) hud.value = summary();
    }
    if (kPerfLog && t - _lastLogUs >= 15000000) {
      _lastLogUs = t;
      debugPrint(report());
    }
  }

  /// The chunk that arrived at [t0] was fed to the engine between [t1] and [t2].
  void noteFed(int t0, int t1, int t2) {
    if (!kPerfMonitor) return;
    fed++;
    feed.add(t2 - t1);
    cycle.add(t2 - t0);
    _lastFedUs = t2;
  }

  void noteWordEvent(int t) {
    if (!kPerfMonitor) return;
    final f = _lastFedUs;
    if (f >= 0 && t - f < 5000000) lag.add(t - f);
  }

  void noteAnchor({required bool first, required bool byEngine, required bool moved}) {
    if (!kPerfMonitor) return;
    if (first && _listenUs >= 0) {
      firstAnchor.add(now() - _listenUs);
      _listenUs = -1;
    }
    if (byEngine && moved) engineAnchors++;
  }

  void _onFrames(List<ui.FrameTiming> timings) {
    for (final ft in timings) {
      frames++;
      frameBuild.add(ft.buildDuration.inMicroseconds);
      frameRaster.add(ft.rasterDuration.inMicroseconds);
      final total = ft.totalSpan.inMicroseconds;
      if (total > 16700) slowFrames++;
      if (total > 700000) frozenFrames++;
    }
  }

  static String _f1(int us) => (us / 1000).toStringAsFixed(1);
  static String _f0(int us) => (us / 1000).round().toString();

  /// Four short lines for the phone screen (shown by a long-press on the mic).
  String summary() {
    return 'cycle ${_f0(chunkGap.avgUs)}/${_f0(chunkGap.p95Us)}ms late ${chunkGap.over} n$chunks\n'
        'feed ${_f1(feed.avgUs)}/${_f1(feed.p95Us)}/${_f1(feed.maxUs)}ms >8:${feed.over} lag ${_f0(lag.avgUs)}ms\n'
        'word ${_f1(wordEv.avgUs)}/${_f1(wordEv.maxUs)} anch ${_f1(reanchor.maxUs)}($reanchorJumps/${reanchor.count}) loc ${_f1(locate.p95Us)}\n'
        'ui $uiRebuilt/${uiRebuilt + uiSkipped} mk ${_f1(marksBuild.p95Us)} jank $slowFrames/$frames b${_f1(frameBuild.p95Us)} r${_f1(frameRaster.p95Us)}';
  }

  /// Full report (avg / p95 / max in ms) for the log.
  String report() {
    final sb = StringBuffer(
        '[perf] cycle=${kAudioCycleMs}ms surah=$skelLen letters chunks=$chunks fed=$fed\n');
    void row(String name, _PerfMetric m) {
      sb.write('[perf] ${name.padRight(10)} n=${m.count} avg=${_f1(m.avgUs)} '
          'p95=${_f1(m.p95Us)} max=${_f1(m.maxUs)} over=${m.over}\n');
    }

    row('chunkGap', chunkGap);
    row('feed', feed);
    row('cycle', cycle);
    row('lag', lag);
    row('wordEv', wordEv);
    row('reanchor', reanchor);
    row('locate', locate);
    row('resync', resync);
    row('firstAnchor', firstAnchor);
    row('marksBuild', marksBuild);
    row('frameBuild', frameBuild);
    row('frameRaster', frameRaster);
    sb.write('[perf] frames=$frames slow=$slowFrames frozen=$frozenFrames '
        'jumps=$reanchorJumps engineAnchors=$engineAnchors '
        'uiRebuilt=$uiRebuilt uiSkipped=$uiSkipped');
    return sb.toString();
  }
}

final PerfMonitor perf = PerfMonitor._();

/// The status line only needs the first tag and the last words: a long
/// transcript must not be shaped and laid out again on every update.
String _capHeard(String v) =>
    v.length <= 120 ? v : '${v.substring(0, 24)}…${v.substring(v.length - 90)}';

final Map<String, List<_Cluster>> _clusterCache = <String, List<_Cluster>>{};

/// [_clusters] with a small cache: the same word is split again on every
/// redraw of a wrong word (regex + one String per rune). The cached lists are
/// never changed by the callers.
List<_Cluster> _clustersCached(String token) {
  if (token.length > 48) return _clusters(token);
  final hit = _clusterCache[token];
  if (hit != null) return hit;
  if (_clusterCache.length >= 256) _clusterCache.clear();
  final cl = _clusters(token);
  _clusterCache[token] = cl;
  return cl;
}

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
  Timer? _micWatch; // switches the microphone off after a minute without speech
  DateTime _lastSpeechAt = DateTime.now(); // last time the engine processed speech
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
  bool _resuming = false; // a resume is already running (event + retry timer)
  // free-flow: the reader may start at, or jump to, any ayah of the surah
  bool _anchored = false; // a word was confirmed: the position is known
  DateTime _lastGreenAt = DateTime(2000); // last word the engine confirmed
  DateTime _lastLocateAt = DateTime(2000);
  String _skel = ''; // every word of the surah as one space-free letter chain
  List<int> _skelWord = const []; // chain index -> word number
  Uint16List _skelU16 = Uint16List(0); // the chain as code units (search)
  Int32List _locEnds = Int32List(1); // search result row, kept between calls
  final Int64List _peq = Int64List(0x50); // search: letter -> pattern mask
  String _heardSkelSrc = ''; // memo of _connSkel(transcript)
  String _heardSkel = '';
  Int32List _appToGlobal = Int32List(0); // app word number -> engine index
  bool _intDuringStart = false; // a call came while the engine was loading
  DateTime _lastChunkAt = DateTime(2000); // last audio chunk from the microphone
  DateTime _selfAudioUntil = DateTime(2000); // grace after our own teacher audio
  /// True while the teacher's own audio runs (or just ended). Android reports
  /// that as "audio focus lost", which is not a call and must not end the session.
  bool get _ownAudio =>
      _correcting ||
      audio.correcting ||
      DateTime.now().isBefore(_selfAudioUntil);
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
  // Lesson the reader should review for the last mistake (see TajweedBridge).
  // 0 = no lesson. Cleared when the word is read correctly or the coach stops.
  int guideLessonId = 0;
  String guideLabel = '';
  int _guideG = -1;
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

  /// Ayah to scroll to: only once the reader's place is known (otherwise the
  /// page would jump to ayah 1 when the mic is switched on).
  int get followAyah => _anchored ? cursorAyah : 0;

  /// [hintAyah] is kept for the callers but no longer used: the session always
  /// starts free (no forced resume position).
  Future<void> start(int surahNo, List<Ayah> ayahs, {int hintAyah = 1}) async {
    if (on) return;
    on = true;
    perf.start();
    _intDuringStart = false;
    surah = surahNo;
    _fails = 0;
    _lastAyahs = ayahs;
    _savedG = -1;
    // The screen must not dim or lock while the teacher listens.
    try {
      WakelockPlus.enable();
    } catch (_) {}
    // Free-flow: no forced resume position. The reader may start at any ayah
    // of the surah; the engine (auto re-anchor) and the position finder
    // (_tryFreeFlowJump) find the place by listening.
    _resetFreeFlow();
    _build(ayahs, 1, 0);
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
    if (_intDuringStart) {
      // a call arrived while loading: close the microphone and wait for it
      _intDuringStart = false;
      await _pauseForInterruption();
      return;
    }
    if (_neural) {
      perf.markListening();
      _prefetchAhead();
      _set(CoachState.listening, 'گوێم لێتە - لە هەر ئایەتێکەوە دەستپێبکە بخوێنە');
      _startMicWatch();
      return;
    }
    await _listen();
  }

  /// A new session never inherits the place of the previous one. The cursor is
  /// not put back on the old stopping point (that position is only kept for the
  /// "continue reading" card): the reader may start at ANY ayah, and the first
  /// heard words anchor the session there (_onNeuralWordImpl / _tryFreeFlowJump).
  void _resetFreeFlow() {
    _anchored = false;
    _lastGreenAt = DateTime.now();
    _lastLocateAt = DateTime(2000);
    _savedG = -1;
    _wordFails.clear();
    _badLetters.clear();
    _badSigns.clear();
    _ctxLo = _ctxHi = _ctxG = -1;
    _lastFinal = '';
    _lastFinalAt = DateTime(2000);
    _heardSkelSrc = '';
    _heardSkel = '';
    _dbgTr = '';
    _dbgEv = '';
    _unmuteAt = DateTime(2000);
    _stall?.cancel();
    _idle?.cancel();
    heardText.value = '';
  }

  /// The engine processed speech (a transcript or a word result): the
  /// inactivity clock starts again.
  void _noteSpeech() => _lastSpeechAt = DateTime.now();

  /// Switches the microphone off after [kMicIdleTimeout] without speech. The
  /// clock only runs while the microphone really listens: not while loading,
  /// during a correction, the teacher's own audio or a phone call.
  void _startMicWatch() {
    _lastSpeechAt = DateTime.now();
    _micWatch?.cancel();
    _micWatch = Timer.periodic(const Duration(seconds: 2), (_) {
      if (!on) {
        _micWatch?.cancel();
        return;
      }
      final now = DateTime.now();
      if (state == CoachState.starting ||
          _correcting ||
          _interrupted ||
          audio.playing ||
          _ownAudio) {
        _lastSpeechAt = now;
        return;
      }
      if (now.difference(_lastSpeechAt) >= kMicIdleTimeout) {
        stop(msg: 'مایکرۆفۆن خۆکارانە کوژایەوە، چونکە ١ خولەک هیچ دەنگێک نەبیسترا.');
      }
    });
  }

  Future<void> stop({String msg = ''}) async {
    if (!on && state == CoachState.off) return;
    _flushPos(); // keep the exact ayah and word for the next session
    _posTimer?.cancel();
    _anchored = false;
    _intRetry?.cancel();
    _interrupted = false;
    _intDuringStart = false;
    try {
      WakelockPlus.disable();
    } catch (_) {}
    final wasCorrecting = _correcting;
    on = false;
    perf.stop();
    _correcting = false;
    _corrArmed = false;
    _restart?.cancel();
    _safety?.cancel();
    _idle?.cancel();
    _stall?.cancel();
    _micWatch?.cancel();
    _micWatch = null;
    _ctxLo = _ctxHi = _ctxG = -1;
    _badLetters.clear();
    _badSigns.clear();
    guideLessonId = 0;
    guideLabel = '';
    _guideG = -1;
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

  /// Takes the audio focus back after the teacher's audio. Refused during a
  /// real phone call (then false: the session waits for the call to end).
  Future<bool> _reclaimFocus() async {
    final s = _session;
    if (s == null) return true; // no audio session: nothing to check
    try {
      return await s.setActive(true);
    } catch (_) {
      return true;
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
    if (!on) return;
    if (state == CoachState.starting) {
      // the engine is still loading: remember the call, start() pauses as
      // soon as it is ready (the microphone must not open in a call)
      if (e.begin) {
        if (e.type != asn.AudioInterruptionType.duck) _intDuringStart = true;
      } else {
        _intDuringStart = false;
      }
      return;
    }
    if (e.begin) {
      if (e.type == asn.AudioInterruptionType.duck) return; // a short prompt
      // the teacher's own audio took the focus: only the microphone input is
      // muted meanwhile, the session goes on (_endCorrection checks the focus)
      if (_ownAudio) return;
      if (e.type == asn.AudioInterruptionType.unknown) {
        // the audio focus was taken for good (another app, a sound...):
        // never close the session and show nothing. Take the focus back and
        // open the microphone again, silently.
        _reclaimAfterFocusLoss();
        return;
      }
      _pauseForInterruption();
    } else {
      _resumeFromInterruption();
    }
  }

  bool _reclaiming = false;

  /// Silent recovery after the audio focus was lost for good: no message, the
  /// session stays on. If the focus is refused (a real call is going on) the
  /// normal pause starts and retries by itself until the call is over.
  Future<void> _reclaimAfterFocusLoss() async {
    if (_reclaiming) return;
    _reclaiming = true;
    try {
      await Future.delayed(const Duration(milliseconds: 400));
      if (!on || _interrupted || _correcting || _ownAudio) return;
      if (state == CoachState.starting) return;
      final got = await _reclaimFocus();
      if (!on || _interrupted || _correcting) return;
      if (!got) {
        await _pauseForInterruption();
        return;
      }
      await _restartMic();
      _unmuteAt = DateTime.now();
    } finally {
      _reclaiming = false;
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
  Future<void> _pauseForInterruption({String? msg}) async {
    if (_interrupted || !on) return;
    _interrupted = true;
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
        msg ?? 'وەستا - پەیوەندی تەلەفۆن یان دەنگێکی دیکە. کە تەواو بوو، خۆی بەردەوام دەبێت.');
    // the end event can get lost: ask for the audio focus again now and then
    _intRetry?.cancel();
    _intRetry = Timer.periodic(const Duration(seconds: 3), (_) => _tryResume());
  }

  Future<void> _tryResume() async {
    if (!on || !_interrupted) {
      _intRetry?.cancel();
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
    if (!_interrupted || !on || _resuming) return;
    _resuming = true;
    try {
      _set(CoachState.listening, 'ئامادەبە...');
      _resyncTracker();
      final ok = await _restartMic();
      if (!on) return;
      if (!ok) {
        // the call may still hold the microphone: stay paused, the retry
        // timer tries again in a few seconds
        _set(CoachState.paused, 'مایکرۆفۆن هێشتا ئامادە نییە - چاوەڕێ دەکەم...');
        return;
      }
      _interrupted = false;
      _intRetry?.cancel();
      _unmuteAt = DateTime.now();
      final ph = _ctxLo >= 0 ? _ctxPhrase() : _cursorWord();
      _set(CoachState.listening,
          ph.isNotEmpty ? 'بەردەوام بە لە: «$ph»' : 'گوێم لێتە - دەستپێبکە بخوێنە');
    } finally {
      _resuming = false;
    }
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
    if (!_anchored) return; // nothing recited yet: keep the old position
    if (al.cursor >= _wayah.length) {
      settings.saveCoachPos(surah, 0, 0); // surah finished: nothing to resume
      return;
    }
    final g = al.cursor < 0 ? 0 : al.cursor;
    final ai = _wayah[g];
    settings.saveCoachPos(surah, _ayahs[ai].n, g - _starts[ai]);
  }

  /// Cheap fingerprint of everything [marksFor] would draw for one ayah
  /// (0 = drawn normally). It allocates nothing: an ayah's widget rebuilds only
  /// when this number changes, so a word confirmed in one ayah no longer
  /// re-lays-out every other ayah on screen.
  int markSignature(int surahNo, int ayahN) {
    final al = _al;
    if (!on || al == null || surah != surahNo || state == CoachState.starting) {
      return 0;
    }
    final ai = _ayahIndexOf(ayahN);
    if (ai < 0) return 0;
    final s = _starts[ai];
    final e = _starts[ai + 1];
    final cur = al.cursor;
    var touched = cur >= s && cur < e;
    var h = 17;
    for (var k = s; k < e; k++) {
      final st = al.st[k];
      if (st != 0) touched = true;
      var v = st;
      if (k == cur) v += 8;
      if (_ctxLo >= 0 && k >= _ctxLo && k <= _ctxHi) v += k == _ctxG ? 32 : 16;
      final bl = _badLetters[k];
      if (bl != null && bl.isNotEmpty) v += 64 * _setSig(bl);
      final bs = _badSigns[k];
      if (bs != null && bs.isNotEmpty) v += 4096 * _setSig(bs);
      h = (h * 31 + v) & 0x3fffffff;
    }
    return touched ? (h | 0x40000000) : 0;
  }

  static int _setSig(Set<int> s) {
    var x = s.length;
    for (final r in s) {
      x = (x * 31 + r) & 0xffff;
    }
    return x + 1;
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
    // the whole surah as one space-free chain, for the free-flow finder
    final sk = StringBuffer();
    final skw = <int>[];
    for (var k = 0; k < words.length; k++) {
      final c = _connSkel(words[k]);
      for (var q = 0; q < c.length; q++) {
        skw.add(k);
      }
      sk.write(c);
    }
    _skel = sk.toString();
    _skelWord = Int32List.fromList(skw);
    _skelU16 = Uint16List.fromList(_skel.codeUnits);
    _locEnds = Int32List(_skelU16.length + 1);
    _appToGlobal = Int32List(0);
    perf.skelLen = _skelU16.length;
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
  ///               madd / ghunna / shadda), auto re-anchor (slower threshold)
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
          enableAutoReanchor: true, // free-flow: the reader may jump anywhere
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
      _buildGlobalMap();
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
        if (t.trim().isNotEmpty && t != _dbgTr) _noteSpeech();
        _dbgTr = t;
        heardText.value = '$_dbgEv  $_dbgTr';
        _freeFlowCheck();
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
    perf.resetChunkClock();
    await mic.start(onChunk: (chunk, isFinal) {
      if (!identical(_nMic, mic)) return; // an old microphone: ignore
      final t0 = perf.now();
      perf.noteChunk(t0); // gap to the previous chunk = the audio cycle
      _micChunks++;
      final nowDt = DateTime.now(); // one clock read per chunk
      _lastChunkAt = nowDt;
      if (!on || !_neural || _correcting || audio.playing) return;
      if (nowDt.isBefore(_unmuteAt)) return;
      _fed++;
      final t1 = perf.now();
      tr.feedAudioChunk(chunk, isFinal: isFinal);
      perf.noteFed(t0, t1, perf.now());
    });
  }

  /// Playing the teacher's audio can leave the microphone stream dead on
  /// Android (audio focus). After every correction the microphone is closed
  /// and opened again, so the engine surely hears the re-read word.
  /// Returns false when the microphone could not be opened.
  Future<bool> _restartMic() async {
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
    if (!on || !_neural) return false;
    try {
      await _startMic();
      return true;
    } catch (_) {
      final bad = _nMic; // a microphone that never started
      _nMic = null;
      if (bad != null) {
        try {
          await (bad as dynamic).dispose();
        } catch (_) {}
      }
      _dbgEv = '$_dbgEv [مایک هەڵە]';
      heardText.value = '$_dbgEv  $_dbgTr';
      return false;
    }
  }

  /// app word number -> the package's global word index (-1 = no match),
  /// built once per session so a resync does not scan every word of the surah.
  void _buildGlobalMap() {
    final byKey = <int, int>{};
    for (final w in _nWords) {
      final key = w.ayah * 4096 + w.wordInAyah;
      if (!byKey.containsKey(key)) byKey[key] = w.globalIndex;
    }
    final out = Int32List(_wayah.length);
    for (var g = 0; g < _wayah.length; g++) {
      final ai = _wayah[g];
      final wi = g - _starts[ai] + _wBase;
      out[g] = byKey[_ayahs[ai].n * 4096 + wi] ?? -1;
    }
    _appToGlobal = out;
  }

  /// The package's global word index of the app's word number [g].
  int? _globalOf(int g) {
    if (g < 0 || g >= _wayah.length) return null;
    if (g < _appToGlobal.length) {
      final v = _appToGlobal[g];
      return v >= 0 ? v : null;
    }
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
    final t0 = perf.now();
    _resyncTrackerImpl();
    perf.resync.add(perf.now() - t0);
  }

  void _resyncTrackerImpl() {
    final tr = _nTracker;
    final al = _al;
    if (tr == null || al == null) return;
    _lastGreenAt = DateTime.now(); // the position finder waits a moment
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

  void _onNeuralWord(rq.WordMatchedEvent ev) {
    final t0 = perf.now();
    perf.noteWordEvent(t0);
    try {
      _onNeuralWordImpl(ev);
    } finally {
      perf.wordEv.add(perf.now() - t0);
    }
  }

  void _onNeuralWordImpl(rq.WordMatchedEvent ev) {
    final al = _al;
    if (!on || !_neural || al == null) return;
    // wordId is the package's global word index; fall back to the list position
    // results that were still in the pipe when the correction ended
    if (!_correcting &&
        DateTime.now().isBefore(_unmuteAt)) {
      return;
    }
    _stall?.cancel(); // the engine heard something: no stall
    _noteSpeech(); // ... and the inactivity clock starts again
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
    // Free-flow: the reader can be at any ayah. The first confirmed word of the
    // session, or one far from where the app expects the reader, moves the
    // position there instead of being judged. No verdict (red) is given for
    // words far from the expected place or before the place is known.
    if (!_correcting) {
      final far = g < al.cursor - 3 || g > al.cursor + kJumpWords;
      if (!_anchored || far) {
        if (ev.isRed || (ev as dynamic).isNeutral == true) return;
        _anchorAt(g, ai);
      }
      if (!ev.isRed) _lastGreenAt = DateTime.now();
    }
    final errs = (ev as dynamic).tajweedErrors as List<dynamic>?;
    // Tajweed slips: level 1 lets them pass, level 2 corrects the core rules,
    // level 3 everything (madd length, ghunna timing, qalqala ...). What the
    // lessons allow (madd arid 2/4/6, tanween when stopping ...) or what does
    // not apply to this word is dropped (TajweedBridge.judge).
    final verdict = _judgeTajweed(ai, g, errs);
    final slip = verdict.flag;
    al.locked = true;
    final pos = w.wordInAyah - _wBase + 1;
    // Second opinion for a word the engine called wrong: when the reader
    // joins words (wasl, al- + sun letter) the engine's word-by-word alignment
    // can fail although the recitation is right. The transcript is compared
    // as one space-free chain with the expected words (QuranPhonetics).
    // "wrong" from the engine: the reader may just have jumped to another
    // ayah, so look in the whole surah before correcting
    if (ev.isRed && !_correcting && _tryFreeFlowJump()) return;
    if (ev.isRed && !_correcting && kPhoneticLayer) {
      final hi = _connectedSpan(ai, g); // a few microseconds of string work
      if (hi >= 0) {
        _acceptConnected(g, hi);
        return;
      }
    }
    if (ev.isRed || slip) {
      _flagNeural(ai, g, ev.isRed, slip ? verdict.detail : '', pos,
          errs: slip ? errs : null, verdict: verdict);
      return;
    }
    if ((ev as dynamic).isNeutral == true) return;
    if (_correcting) return; // stale result that arrived after the mistake
    al.st[g] = 1;
    _wordFails.remove(g);
    _badSigns.remove(g);
    _clearGuideAt(g);
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

  // ---------- free-flow: find the reader's place in the whole surah ----------
  /// The first confirmed word (or a word far from the expected place): the
  /// reader's position is now there.
  void _anchorAt(int g, int ai) {
    final al = _al;
    if (al == null) return;
    final moved = al.cursor < g - 1 || al.cursor > g + 1;
    perf.noteAnchor(first: !_anchored, byEngine: true, moved: moved);
    _anchored = true;
    _stall?.cancel();
    _wordFails.clear();
    _badLetters.clear();
    _badSigns.clear();
    _ctxLo = _ctxHi = _ctxG = -1;
    if (moved) {
      al.cursor = g;
      al.rev++;
      _set(CoachState.listening,
          'ئایەتی ${_ayahs[ai].n} دۆزرایەوە - بەردەوام بە');
    }
  }

  /// Called whenever the engine's transcript changes. While the place is
  /// unknown (start of the session), or the engine has confirmed no word for a
  /// moment, the heard words are searched in the whole surah.
  void _freeFlowCheck() {
    if (!on || !_neural || _correcting || _interrupted || _al == null) return;
    if (state == CoachState.starting) return;
    final now = DateTime.now();
    // while the place is unknown (new session) look more often: re-anchor fast
    final gap = Duration(milliseconds: _anchored ? 700 : 300);
    if (now.difference(_lastLocateAt) < gap) {
      return;
    }
    if (_anchored &&
        now.difference(_lastGreenAt) < const Duration(milliseconds: 2500)) {
      return;
    }
    _lastLocateAt = now;
    _tryFreeFlowJump();
  }

  /// The heard text as a letter chain. The transcript is the same string for
  /// many calls, and normalising it (regex + StringBuffer) is not free.
  String _heardSkelOf(String t) {
    if (t != _heardSkelSrc) {
      _heardSkelSrc = t;
      _heardSkel = _connSkel(t);
    }
    return _heardSkel;
  }

  /// Best place of [pat] (a letter chain) in the surah's chain:
  /// [end index (exclusive), edits, edits of the best OTHER place], or null.
  ///
  /// Bit-parallel approximate matching (Myers / Hyyro): the pattern (at most
  /// 60 letters) lives in one 64-bit integer, so one surah letter costs a
  /// dozen integer operations instead of a whole column of the edit table.
  /// The edit counts are exactly those of the plain table. Nothing is
  /// allocated: the result row is a buffer kept between calls.
  List<int>? _locateInSurah(String pat) {
    final text = _skelU16;
    final n = pat.length;
    final m = text.length;
    if (n == 0 || m == 0 || n > 60) return null;
    final t0 = perf.now();
    final peq = _peq;
    for (var i = 0; i < peq.length; i++) {
      peq[i] = 0;
    }
    for (var i = 0; i < n; i++) {
      final c = pat.codeUnitAt(i) - 0x621;
      if (c >= 0 && c < peq.length) peq[c] |= 1 << i;
    }
    final mask = (1 << n) - 1;
    final high = 1 << (n - 1);
    var pv = mask;
    var mv = 0;
    var score = n;
    final ends = _locEnds;
    ends[0] = n;
    for (var j = 1; j <= m; j++) {
      final c = text[j - 1] - 0x621;
      final eq = (c >= 0 && c < peq.length) ? peq[c] : 0;
      final xv = eq | mv;
      final xh = ((((eq & pv) + pv) ^ pv) | eq) & mask;
      var ph = (mv | ~(xh | pv)) & mask;
      final mh = pv & xh;
      if ((ph & high) != 0) {
        score++;
      } else if ((mh & high) != 0) {
        score--;
      }
      ph = (ph << 1) & mask;
      pv = (((mh << 1) & mask) | ~(xv | ph)) & mask;
      mv = ph & xv;
      ends[j] = score;
    }
    var bj = 1;
    for (var j = 2; j <= m; j++) {
      if (ends[j] < ends[bj]) bj = j;
    }
    var other = n;
    for (var j = 1; j <= m; j++) {
      if ((j - bj).abs() > n + 2 && ends[j] < other) other = ends[j];
    }
    perf.locate.add(perf.now() - t0);
    return [bj, ends[bj], other];
  }

  /// Looks for the last heard words in the whole surah. When they fit one
  /// place clearly (and only one), far from where the app expects the reader,
  /// the position (and the engine) move there. True when it moved.
  bool _tryFreeFlowJump() {
    final t0 = perf.now();
    final searches = perf.locate.count;
    final moved = _tryFreeFlowJumpImpl();
    if (perf.locate.count != searches) {
      // a real surah search ran: time the whole search + jump
      perf.reanchor.add(perf.now() - t0);
      if (moved) perf.reanchorJumps++;
    }
    return moved;
  }

  bool _tryFreeFlowJumpImpl() {
    final al = _al;
    if (al == null || _skel.isEmpty) return false;
    final heard = _heardSkelOf(_dbgTr);
    if (heard.length < 12) return false; // too little to prove anything
    final tail = heard.length > 28 ? heard.substring(heard.length - 28) : heard;
    final r = _locateInSurah(tail);
    if (r == null) return false;
    final n = tail.length;
    if (r[1] > n ~/ 4 || r[2] - r[1] < 3) return false; // unclear or not unique
    final endW = _skelWord[r[0] - 1];
    final st = r[0] - n;
    final startW = _skelWord[st < 0 ? 0 : st];
    // the place the app expects: normal reading, the engine follows it
    if (_anchored &&
        endW >= al.cursor - 3 &&
        endW <= al.cursor + kJumpWords) {
      return false;
    }
    // the very beginning of the surah: the engine (waiting at word 0) handles it
    if (!_anchored && startW <= 1) return false;
    _jumpTo(startW, endW);
    return true;
  }

  /// The reader is at words [startW]..[endW] of the surah: mark them, put the
  /// cursor and the engine on the next word.
  void _jumpTo(int startW, int endW) {
    final al = _al;
    if (al == null) return;
    perf.noteAnchor(first: !_anchored, byEngine: false, moved: true);
    _anchored = true;
    _stall?.cancel();
    _wordFails.clear();
    _badLetters.clear();
    _badSigns.clear();
    _ctxLo = _ctxHi = _ctxG = -1;
    for (var k = startW; k <= endW && k < al.words.length; k++) {
      al.st[k] = 1;
    }
    al.cursor = endW + 1;
    al.locked = true;
    al.rev++;
    if (al.cursor >= al.words.length) {
      stop(msg: 'ماشاءاللە! سوورەتەکەت تەواو کرد.');
      return;
    }
    _resyncTracker(); // the engine now waits for the word after the heard ones
    _unmuteAt = DateTime.now().add(const Duration(milliseconds: 200));
    final ai = _wayah[al.cursor];
    _set(CoachState.listening,
        'ئایەتی ${_ayahs[ai].n} دۆزرایەوە - بەردەوام بە');
    _prefetchAhead();
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
    final cl = _clustersCached(tok);
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

  /// Level- and context-aware verdict on the engine's tajweed errors of word [g].
  TajweedVerdict _judgeTajweed(int ai, int g, List<dynamic>? errs) {
    if (errs == null || errs.isEmpty) return TajweedVerdict.none;
    final end = _starts[ai + 1];
    return TajweedBridge.judge(
      errs,
      word: _wordText(ai, g),
      next: g + 1 < end ? _wordText(ai, g + 1) : '',
      atWaqf: g == end - 1,
      level: settings.coachLevel,
    );
  }

  /// Remembers which lesson explains the mistake in word [g]: first from the
  /// engine's tajweed error, else from the exact glyphs marked red.
  void _setGuide(int ai, int g, TajweedVerdict? v, Set<int> signs) {
    var id = v?.lessonId ?? 0;
    if (id == 0 && signs.isNotEmpty) {
      final end = _starts[ai + 1];
      id = TajweedBridge.lessonForGlyphs(
          signs, _wordText(ai, g), g + 1 < end ? _wordText(ai, g + 1) : '',
          g == end - 1);
    }
    _setGuideId(id, g);
  }

  void _setGuideId(int id, int g) {
    final ls = id == 0 ? null : tajweedLessonById(id);
    guideLessonId = ls == null ? 0 : id;
    guideLabel = ls == null ? '' : ls.titleKu;
    _guideG = g;
  }

  /// The word [g] (or a later one) was read correctly: the hint is done.
  void _clearGuideAt(int g) {
    if (guideLessonId != 0 && g >= _guideG) {
      guideLessonId = 0;
      guideLabel = '';
      _guideG = -1;
    }
  }

  /// Shows word [g] as wrong and starts the teacher-style correction.
  void _flagNeural(int ai, int g, bool wrongWord, String detail, int pos,
      {List<dynamic>? errs, TajweedVerdict? verdict}) {
    final al = _al;
    if (al == null) return;
    // only the faulty letter / sign turns red (empty: the whole word does)
    final signs = _pinpointSigns(ai, g, errs);
    if (signs.isEmpty) {
      _badSigns.remove(g);
    } else {
      _badSigns[g] = signs;
    }
    _setGuide(ai, g, verdict, signs);
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
    final heard = _heardSkelOf(_dbgTr);
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
      _clearGuideAt(k);
    }
    if (hi + 1 > al.cursor) al.cursor = hi + 1;
    al.rev++;
    _ctxDoneCheck();
    _stall?.cancel();
    _lastGreenAt = DateTime.now();
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
    // a wrong letter is a makhraj mistake (lesson 2); a skipped word has none
    final lb = _badLetters[ev.g];
    _setGuideId(lb != null && lb.isNotEmpty ? 2 : 0, ev.g);
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
    _selfAudioUntil = DateTime.now().add(const Duration(seconds: 2));
    if (_neural) {
      // Android reports our own teacher audio as "focus lost": take the focus
      // back. During a real call this is refused: wait for the call instead.
      if (!await _reclaimFocus()) {
        if (on) await _pauseForInterruption();
        return;
      }
      if (!on) return;
      _resyncTracker();
      // The reader sees at once that it is their turn (no silent screen while
      // the microphone is re-opened); the engine is live a moment later.
      final sw = Stopwatch()..start();
      final ph0 = _ctxLo >= 0 ? _ctxPhrase() : '';
      if (ph0.isNotEmpty) _set(CoachState.listening, 'ئامادەبە: «$ph0»');
      // The microphone stayed open (its input was only muted while the teacher
      // spoke), so listening starts at once. It is closed and opened again only
      // when it stopped delivering audio.
      final alive = _nMic != null &&
          DateTime.now().difference(_lastChunkAt) <
              const Duration(milliseconds: 700);
      if (alive) {
        _unmuteAt = DateTime.now().add(const Duration(milliseconds: 150));
        // the stream can die right at the end of the teacher's audio: check
        Timer(const Duration(milliseconds: 900), () {
          if (!on || !_neural || _correcting || _interrupted) return;
          if (DateTime.now().difference(_lastChunkAt) >
              const Duration(milliseconds: 600)) {
            _restartMic();
          }
        });
      } else {
        final ok = await _restartMic();
        if (!on) return;
        if (!ok) {
          // never leave a dead microphone behind a "listening" status: wait
          // and try again by itself
          await _pauseForInterruption(
              msg: 'مایکرۆفۆن ئامادە نەبوو - خۆی دووبارە هەوڵ دەداتەوە...');
          return;
        }
        _unmuteAt = DateTime.now();
      }
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
      final sn = surah;
      if (ay != null && sn > 0) start(sn, ay); // free session, no forced position
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
                  // long-press: show / hide the performance numbers
                  GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onLongPress: perf.toggleHud,
                    child: _MicDot(
                      active: st == CoachState.listening,
                      color: accent,
                      icon: bad
                          ? Icons.volume_up
                          : (st == CoachState.paused ? Icons.mic_off : Icons.mic),
                    ),
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
                        if (coach.guideLessonId != 0)
                          TextButton.icon(
                            style: TextButton.styleFrom(
                              padding: EdgeInsets.zero,
                              minimumSize: const Size(0, 30),
                              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                              alignment: AlignmentDirectional.centerStart,
                              foregroundColor: _green,
                            ),
                            icon: const Icon(Icons.menu_book, size: 18),
                            label: Text(
                              'وانەی ${coach.guideLessonId} ببینەوە: ${coach.guideLabel}',
                              style: const TextStyle(
                                  fontSize: 13.5, fontWeight: FontWeight.bold),
                            ),
                            onPressed: () {
                              final id = coach.guideLessonId;
                              final nav = Navigator.of(context);
                              // the microphone is closed while the lesson is open
                              coach.stop(
                                  msg:
                                      'گوێگرتن وەستا بۆ پێداچوونەوەی وانە. دووبارە دەستی پێبکەرەوە.');
                              nav.push(MaterialPageRoute<void>(
                                  builder: (_) =>
                                      TajweedLessonsScreen(initialLessonId: id)));
                            },
                          ),
                        ValueListenableBuilder<String>(
                          valueListenable: perf.hud,
                          builder: (context, v, _) => v.isEmpty
                              ? const SizedBox.shrink()
                              : Text(
                                  v,
                                  maxLines: 4,
                                  softWrap: false,
                                  overflow: TextOverflow.clip,
                                  textDirection: TextDirection.ltr,
                                  style: TextStyle(
                                    fontSize: 10,
                                    height: 1.25,
                                    fontFamily: 'monospace',
                                    color: _mutedColor(context),
                                  ),
                                ),
                        ),
                        ValueListenableBuilder<String>(
                          valueListenable: coach.heardText,
                          builder: (context, v, _) => v.isEmpty
                              ? const SizedBox.shrink()
                              : Text(
                                  _capHeard(v),
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
// Rebuilds only when the fingerprint of ITS OWN words changes (see
// RecitationCoach.markSignature), not on every coach notification.
class _AyahArabic extends StatefulWidget {
  final Ayah a;
  final int surah;
  const _AyahArabic(this.a, this.surah);

  @override
  State<_AyahArabic> createState() => _AyahArabicState();
}

class _AyahArabicState extends State<_AyahArabic> {
  int _sig = 0;

  @override
  void initState() {
    super.initState();
    _sig = coach.markSignature(widget.surah, widget.a.n);
    coach.addListener(_onCoach);
  }

  @override
  void didUpdateWidget(_AyahArabic old) {
    super.didUpdateWidget(old);
    _sig = coach.markSignature(widget.surah, widget.a.n);
  }

  @override
  void dispose() {
    coach.removeListener(_onCoach);
    super.dispose();
  }

  void _onCoach() {
    if (!mounted) return;
    final s = coach.markSignature(widget.surah, widget.a.n);
    if (s == _sig) {
      perf.uiSkipped++;
      return;
    }
    _sig = s;
    perf.uiRebuilt++;
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final t0 = perf.now();
    final w = _content(context);
    perf.marksBuild.add(perf.now() - t0);
    return w;
  }

  Widget _content(BuildContext context) {
    final a = widget.a;
    final base = TextStyle(
      fontSize: settings.arabicSize,
      height: 2.0,
      color: _inkColor(context),
      fontFamilyFallback: _arFonts,
    );
    final m = coach.marksFor(widget.surah, a.n);
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
    // every style is made once per build and shared by all words
    final ink = TextStyle(color: _inkColor(context));
    final okStyle = TextStyle(color: okColor);
    final badStyle =
        TextStyle(color: badColor, backgroundColor: const Color(0x33E53935));
    const curStyle =
        TextStyle(color: _gold, backgroundColor: Color(0x33D9A21B));
    // tajweed slip (word right, rule wrong)
    const slipStyle =
        TextStyle(color: Color(0xFFEF8F00), backgroundColor: Color(0x44EF8F00));
    // guidance: the words around a mistake, to be read again
    final guideStyle = TextStyle(
      color: dark ? const Color(0xFF4DB6AC) : const Color(0xFF00796B),
      backgroundColor: const Color(0x2200897B),
    );
    final hot = TextStyle(color: badColor, fontWeight: FontWeight.bold);
    final hotLetter = TextStyle(
      color: badColor,
      fontWeight: FontWeight.bold,
      backgroundColor: const Color(0x66E53935),
    );
    // neighbouring words with the same style are joined into one run
    final spans = <TextSpan>[];
    final run = StringBuffer();
    TextStyle? runStyle;
    void flush() {
      if (run.isEmpty) return;
      spans.add(TextSpan(text: run.toString(), style: runStyle));
      run.clear();
    }

    for (var i = 0; i < m.tokens.length; i++) {
      final last = i == m.tokens.length - 1;
      final mark = m.marks[i];
      final wrong = m.letters[i];
      final sg = m.signs[i];
      if ((mark == 2 || mark == 4) && sg != null && sg.isNotEmpty) {
        // granular: only the faulty letter / sign is red
        flush();
        final cl = _clustersCached(m.tokens[i]);
        spans.add(TextSpan(children: [
          for (var p = 0; p < cl.length; p++)
            ..._signSpans(cl[p], p, sg, ink, hot, const Color(0x44E53935)),
          if (!last) const TextSpan(text: ' '),
        ]));
        continue;
      }
      if (mark == 2 && wrong != null && wrong.isNotEmpty) {
        flush();
        final cl = _clustersCached(m.tokens[i]);
        spans.add(TextSpan(children: [
          for (final c in cl)
            TextSpan(text: c.text, style: wrong.contains(c.idx) ? hotLetter : ink),
          if (!last) const TextSpan(text: ' '),
        ]));
        continue;
      }
      TextStyle? s;
      switch (mark) {
        case 1:
          s = okStyle;
          break;
        case 2:
          s = badStyle;
          break;
        case 3:
          s = curStyle;
          break;
        case 4:
          s = slipStyle;
          break;
        case 5:
          s = guideStyle;
          break;
      }
      if (run.isNotEmpty && !identical(s, runStyle)) flush();
      runStyle = s;
      run.write(m.tokens[i]);
      if (!last) run.write(' ');
    }
    flush();
    return Text.rich(
      TextSpan(style: base, children: spans),
      textDirection: TextDirection.rtl,
      textAlign: TextAlign.start,
    );
  }
}

// ============================================================
//  Dashboard (home screen) with 5 cards
//  1 قوُڕئانی پیرۆز   2 مایک و لیڤڵەکان   3 قیبلەنما
//  4 زیکرەکان          5 کاتەکانی بانگ
// ============================================================
String _two(int n) => n < 10 ? '0$n' : '$n';
String _hm(DateTime? t) => t == null ? '--:--' : '${_two(t.hour)}:${_two(t.minute)}';

String _hms(Duration d) {
  final s = d.inSeconds < 0 ? 0 : d.inSeconds;
  return '${_two(s ~/ 3600)}:${_two((s % 3600) ~/ 60)}:${_two(s % 60)}';
}

const List<String> _lvShort = ['سووک', 'مامناوەند', 'قورس'];

// ---------- places (offline list, no GPS permission needed) ----------
class PrayCity {
  final String ku;
  final double lat;
  final double lng;

  /// true = times follow the Kurdistan Awqaf timetables (see PrayerCalc).
  final bool awqaf;

  // Awqaf calibration, in minutes, added to the astronomical sunrise / noon /
  // Asr / sunset. The "s*" values are the extra minutes in mid-summer.
  final double dRise, dNoon, dAsr, dSet;
  final double sRise, sNoon, sAsr, sSet;

  // Fajr = sunrise - fajrGap, Isha = sunset + ishaGap (minutes, winter value;
  // sFajr / sIsha = extra minutes in mid-summer).
  final double fajrGap, ishaGap, sFajr, sIsha;

  /// Fixed UTC offset of the city (Iraq / Kurdistan = Asia/Baghdad = UTC+3, no
  /// DST). null = follow the phone's own time zone.
  final double? tz;

  const PrayCity(
    this.ku,
    this.lat,
    this.lng, {
    this.awqaf = false,
    this.dRise = 0,
    this.dNoon = 6,
    this.dAsr = 0.7,
    this.dSet = 8,
    this.sRise = 0,
    this.sNoon = 0,
    this.sAsr = 0,
    this.sSet = 0,
    this.fajrGap = 82,
    this.ishaGap = 76,
    this.sFajr = 4,
    this.sIsha = 4,
    this.tz,
  });
}

// Kurdistan Region cities only (Awqaf timetable). The first four are measured
// against the official timetables; the others borrow the default Awqaf
// calibration until their real days are added (assets/prayer_times.json).
// Coordinates of the newer towns are approximate: they only matter for days
// that are missing from the timetable (the engine fallback).
final List<PrayCity> kPrayCities = [
  // --- measured against the official Awqaf timetables ---
  PrayCity('هەولێر', 36.1912, 44.0092,
      awqaf: true,
      dRise: 5, dNoon: 8, dAsr: 3, dSet: 4.5,
      sRise: 6, sNoon: 3, sAsr: 8,
      fajrGap: 85, ishaGap: 75, sFajr: 15, sIsha: 0),
  PrayCity('سلێمانی', 35.5613, 45.4308, awqaf: true),
  PrayCity('دهۆک', 36.8672, 42.9989, awqaf: true),
  PrayCity('کەرکووک', 35.4681, 44.3922,
      awqaf: true,
      dRise: -3, dNoon: 5, dAsr: 3.5, dSet: 6, fajrGap: 83),
  PrayCity('هەڵەبجە', 35.1778, 45.9861, awqaf: true),
  PrayCity('شارەزور', 35.3500, 45.7500, awqaf: true),
  PrayCity('سەیدسادق', 35.3600, 45.8850, awqaf: true),
  PrayCity('پێنجوێن', 35.6200, 45.9500, awqaf: true),
  PrayCity('عەربەت', 35.4450, 45.5700, awqaf: true),
  PrayCity('ڕانیە', 36.2547, 44.8836,
      awqaf: true, dNoon: 7, dAsr: 2.5, dSet: 9),
  PrayCity('زاخۆ', 37.1439, 42.6872, awqaf: true),
  PrayCity('کەلار', 34.6275, 45.3197, awqaf: true),
  PrayCity('دەربەندیخان', 35.1100, 45.6967, awqaf: true),
  PrayCity('کفری', 34.6867, 44.9667, awqaf: true),
  PrayCity('بازیان', 35.5800, 45.1000, awqaf: true),
  PrayCity('چەمچەماڵ', 35.5292, 44.8325, awqaf: true),
  PrayCity('دوکان', 35.9500, 44.9833, awqaf: true),
  PrayCity('قەڵادزێ', 36.1833, 45.1333, awqaf: true),
  PrayCity('کۆیە', 36.0833, 44.6333, awqaf: true),
  PrayCity('سۆران', 36.6500, 44.5333, awqaf: true),
];

// City order of the previous version (the phone stored an index, not a name).
const List<String> _legacyCityNames = [
  'هەولێر', 'سلێمانی', 'دهۆک', 'کەرکووک', 'هەڵەبجە', 'زاخۆ', 'ڕانیە', 'کۆیە',
  'سۆران', 'کەلار', 'خانەقین', 'بەغدا', 'مووسڵ', 'بەسرە', 'سنە', 'مەهاباد',
  'کرماشان', 'ئامەد', 'وان', 'قامیشلۆ', 'ئیستەنبوڵ', 'تاران', 'ستۆکهۆڵم',
  'بەرلین', 'لەندەن',
];

/// Chosen city + Asr school, kept on the phone.
class LocPrefs extends ChangeNotifier {
  int city = 0;
  bool hanafi = false; // Kurds are mostly Shafi'i: Asr when shadow = 1x
  bool _loaded = false;
  Timer? _midnight;

  PrayCity get c => kPrayCities[city];

  /// Fires a few seconds after every midnight so each screen that listens to
  /// locPrefs re-reads DateTime.now() and shows the new day's times without
  /// an app restart (the 1 s / 30 s timers do the same; this is the guarantee).
  void _armMidnight() {
    _midnight?.cancel();
    final now = DateTime.now();
    final next = DateTime(now.year, now.month, now.day + 1, 0, 0, 5);
    _midnight = Timer(next.difference(now), () {
      notifyListeners();
      _armMidnight();
    });
  }

  Future<void> ensureLoaded() async {
    if (_loaded) return;
    _loaded = true;
    _armMidnight();
    try {
      final p = await SharedPreferences.getInstance();
      var idx = -1;
      final name = p.getString('pcityName');
      if (name != null) {
        idx = kPrayCities.indexWhere((e) => e.ku == name);
      } else {
        // old version saved an index into the old (longer) city list
        final old = p.getInt('pcity');
        if (old != null && old >= 0 && old < _legacyCityNames.length) {
          idx = kPrayCities.indexWhere((e) => e.ku == _legacyCityNames[old]);
        }
      }
      city = idx < 0 ? 0 : idx;
      hanafi = p.getBool('phanafi') ?? false;
      notifyListeners();
    } catch (_) {}
  }

  Future<void> setCity(int i) async {
    city = i.clamp(0, kPrayCities.length - 1).toInt();
    notifyListeners();
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString('pcityName', kPrayCities[city].ku);
    } catch (_) {}
  }

  Future<void> setHanafi(bool v) async {
    hanafi = v;
    notifyListeners();
    try {
      final p = await SharedPreferences.getInstance();
      await p.setBool('phanafi', v);
    } catch (_) {}
  }
}

final LocPrefs locPrefs = LocPrefs();

Future<void> _pickCity(BuildContext context) async {
  final i = await showModalBottomSheet<int>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (ctx) => SizedBox(
      height: MediaQuery.of(ctx).size.height * 0.7,
      child: ListView.builder(
        itemCount: kPrayCities.length,
        itemBuilder: (ctx, i) => ListTile(
          leading: Icon(
            i == locPrefs.city ? Icons.radio_button_checked : Icons.location_city,
            color: _gold,
          ),
          title: Text(kPrayCities[i].ku, style: const TextStyle(fontSize: 18)),
          onTap: () => Navigator.of(ctx).pop(i),
        ),
      ),
    ),
  );
  if (i != null) locPrefs.setCity(i);
}

// ---------- Qibla maths ----------
double qiblaBearing(double lat, double lng) {
  const kaabaLat = 21.4225;
  const kaabaLng = 39.8262;
  final p1 = lat * math.pi / 180;
  final p2 = kaabaLat * math.pi / 180;
  final dl = (kaabaLng - lng) * math.pi / 180;
  final y = math.sin(dl);
  final x = math.cos(p1) * math.tan(p2) - math.sin(p1) * math.cos(dl);
  final b = math.atan2(y, x) * 180 / math.pi;
  return (b + 360) % 360;
}

double distanceToKaaba(double lat, double lng) {
  const kaabaLat = 21.4225;
  const kaabaLng = 39.8262;
  const r = 6371.0;
  final dLat = (kaabaLat - lat) * math.pi / 180;
  final dLng = (kaabaLng - lng) * math.pi / 180;
  final a = math.sin(dLat / 2) * math.sin(dLat / 2) +
      math.cos(lat * math.pi / 180) *
          math.cos(kaabaLat * math.pi / 180) *
          math.sin(dLng / 2) *
          math.sin(dLng / 2);
  return 2 * r * math.atan2(math.sqrt(a), math.sqrt(1 - a));
}

// ---------- prayer times maths (works offline) ----------
const List<String> kPrayerNames = [
  'بەیانی (فەجر)',
  'خۆرهەڵات',
  'نیوەڕۆ (ظوهر)',
  'عەسر',
  'ئێوارە (مەغریب)',
  'خەوتنان (عیشا)',
];
const List<String> kPrayerShort = [
  'بەیانی',
  'خۆرهەڵات',
  'نیوەڕۆ',
  'عەسر',
  'ئێوارە',
  'خەوتنان',
];
const List<IconData> kPrayerIcons = [
  Icons.nights_stay,
  Icons.wb_twilight,
  Icons.wb_sunny,
  Icons.wb_sunny_outlined,
  Icons.wb_twilight,
  Icons.bedtime,
];

class PrayerDay {
  final DateTime? fajr, sunrise, dhuhr, asr, maghrib, isha;
  const PrayerDay(
      this.fajr, this.sunrise, this.dhuhr, this.asr, this.maghrib, this.isha);
  List<DateTime?> get list => [fajr, sunrise, dhuhr, asr, maghrib, isha];
}

class NextPrayer {
  final int index;
  final DateTime time;
  const NextPrayer(this.index, this.time);
}

/// Official Awqaf schedule, one table per city.
///   city name (PrayCity.ku) -> { 'MM-DD' -> [fajr, sunrise, dhuhr, asr, maghrib, isha] }
/// Times are 24h 'HH:MM' (Asia/Baghdad clock). A day found here is shown exactly as written (no
/// calculation, no drift); in Hanafi mode only Asr is moved. A day that is missing falls back to the calibrated
/// engine in PrayerCalc, so the app always works, even with an empty table.
/// The key has no year: one table serves every year (29 Feb has no entry
/// unless you add '02-29', so it uses the engine).
///
/// IMPORTANT: only days copied from the official Awqaf timetables belong
/// here. The days below are the ones I could verify (29/10/2026 from the
/// Awqaf app photos; the other days from the published Awqaf timetables).
/// Cities with an empty table use the engine until their days are added.
final Map<String, Map<String, List<String>>> kAwqafSchedule = {
  'سلێمانی': {
    '06-01': ['03:18', '04:44', '12:02', '15:46', '19:16', '20:36'],
    '06-02': ['03:18', '04:44', '12:02', '15:46', '19:17', '20:37'],
    '06-03': ['03:17', '04:43', '12:03', '15:46', '19:17', '20:37'],
    '06-05': ['03:17', '04:43', '12:03', '15:46', '19:19', '20:39'],
    '06-06': ['03:17', '04:43', '12:03', '15:47', '19:19', '20:39'],
    '06-07': ['03:17', '04:43', '12:03', '15:47', '19:20', '20:40'],
    '06-08': ['03:16', '04:42', '12:03', '15:47', '19:20', '20:40'],
    '10-27': ['04:54', '06:16', '11:48', '14:45', '17:17', '18:33'],
    '10-29': ['04:55', '06:17', '11:48', '14:44', '17:15', '18:31'],
  },
  'سەیدسادق': {
    '10-29': ['04:53', '06:15', '11:46', '14:42', '17:13', '18:29'],
  },
  'هەولێر': {
    '06-01': ['03:18', '04:59', '12:13', '16:03', '19:20', '20:35'],
    '06-02': ['03:18', '04:59', '12:13', '16:03', '19:20', '20:35'],
    '06-03': ['03:17', '04:58', '12:13', '16:03', '19:21', '20:36'],
    '06-05': ['03:17', '04:58', '12:13', '16:04', '19:21', '20:36'],
    '06-06': ['03:17', '04:57', '12:14', '16:04', '19:22', '20:37'],
    '06-07': ['03:17', '04:57', '12:14', '16:04', '19:22', '20:37'],
    '06-08': ['03:16', '04:57', '12:14', '16:04', '19:23', '20:38'],
    '10-02': ['04:36', '06:05', '12:04', '15:17', '17:53', '19:08'],
    '10-03': ['04:37', '06:06', '12:03', '15:16', '17:51', '19:06'],
    '10-04': ['04:38', '06:06', '12:03', '15:14', '17:49', '19:04'],
    '10-05': ['04:38', '06:07', '12:03', '15:13', '17:47', '19:02'],
    '10-06': ['04:39', '06:07', '12:01', '15:12', '17:45', '19:00'],
    '10-07': ['04:40', '06:08', '12:01', '15:12', '17:44', '18:59'],
    '10-27': ['05:02', '06:27', '11:56', '14:52', '17:18', '18:33'],
  },
  'کەرکووک': {
    '02-03': ['05:34', '06:57', '12:21', '15:14', '17:38', '18:54'],
    '02-10': ['05:28', '06:51', '12:22', '15:19', '17:45', '19:01'],
    '02-11': ['05:27', '06:50', '12:22', '15:20', '17:46', '19:02'],
  },
  'ڕانیە': {
    '03-01': ['05:09', '06:31', '12:20', '15:28', '18:04', '19:20'],
    '03-02': ['05:07', '06:29', '12:19', '15:29', '18:05', '19:21'],
    '03-03': ['05:06', '06:28', '12:19', '15:29', '18:06', '19:22'],
    '03-06': ['05:02', '06:24', '12:18', '15:31', '18:09', '19:25'],
    '03-07': ['05:01', '06:23', '12:18', '15:31', '18:10', '19:26'],
    '03-08': ['05:00', '06:22', '12:18', '15:32', '18:11', '19:27'],
    '03-09': ['04:59', '06:21', '12:18', '15:32', '18:12', '19:28'],
    '03-11': ['04:56', '06:17', '12:17', '15:33', '18:13', '19:29'],
    '03-12': ['04:55', '06:16', '12:17', '15:34', '18:14', '19:30'],
  },
  // No verified Awqaf days yet: these use the engine until you add days.
  // (Halabja: full year added; its sunrise column is calculated, the rest is from the timetable.)
  'دهۆک': {},
  'هەڵەبجە': {
    '01-01': ['05:36', '07:05', '12:05', '14:39', '17:00', '18:17'],
    '01-02': ['05:36', '07:05', '12:05', '14:40', '17:01', '18:18'],
    '01-03': ['05:36', '07:05', '12:06', '14:41', '17:02', '18:19'],
    '01-04': ['05:36', '07:05', '12:06', '14:42', '17:02', '18:19'],
    '01-05': ['05:36', '07:05', '12:07', '14:43', '17:03', '18:20'],
    '01-06': ['05:36', '07:05', '12:07', '14:43', '17:04', '18:21'],
    '01-07': ['05:36', '07:05', '12:08', '14:44', '17:05', '18:22'],
    '01-08': ['05:37', '07:05', '12:08', '14:45', '17:06', '18:23'],
    '01-09': ['05:37', '07:05', '12:08', '14:46', '17:07', '18:24'],
    '01-10': ['05:37', '07:05', '12:09', '14:47', '17:08', '18:25'],
    '01-11': ['05:37', '07:05', '12:09', '14:48', '17:09', '18:26'],
    '01-12': ['05:38', '07:05', '12:10', '14:48', '17:10', '18:27'],
    '01-13': ['05:38', '07:04', '12:10', '14:49', '17:10', '18:28'],
    '01-14': ['05:38', '07:04', '12:10', '14:50', '17:11', '18:29'],
    '01-15': ['05:38', '07:04', '12:10', '14:51', '17:12', '18:30'],
    '01-16': ['05:39', '07:04', '12:11', '14:52', '17:13', '18:31'],
    '01-17': ['05:39', '07:03', '12:11', '14:53', '17:14', '18:32'],
    '01-18': ['05:39', '07:03', '12:12', '14:54', '17:15', '18:33'],
    '01-19': ['05:40', '07:03', '12:12', '14:55', '17:16', '18:34'],
    '01-20': ['05:40', '07:02', '12:12', '14:56', '17:17', '18:35'],
    '01-21': ['05:39', '07:02', '12:13', '14:56', '17:18', '18:36'],
    '01-22': ['05:39', '07:01', '12:13', '14:57', '17:19', '18:37'],
    '01-23': ['05:38', '07:01', '12:13', '14:58', '17:20', '18:38'],
    '01-24': ['05:38', '07:00', '12:14', '14:59', '17:21', '18:39'],
    '01-25': ['05:37', '07:00', '12:14', '15:00', '17:22', '18:40'],
    '01-26': ['05:36', '06:59', '12:14', '15:01', '17:23', '18:41'],
    '01-27': ['05:35', '06:59', '12:14', '15:02', '17:24', '18:42'],
    '01-28': ['05:35', '06:58', '12:14', '15:03', '17:25', '18:42'],
    '01-29': ['05:34', '06:57', '12:15', '15:04', '17:27', '18:43'],
    '01-30': ['05:34', '06:57', '12:15', '15:04', '17:28', '18:44'],
    '01-31': ['05:33', '06:56', '12:15', '15:05', '17:29', '18:45'],
    '02-01': ['05:32', '06:55', '12:15', '15:06', '17:30', '18:45'],
    '02-02': ['05:31', '06:54', '12:15', '15:07', '17:31', '18:46'],
    '02-03': ['05:31', '06:54', '12:15', '15:08', '17:32', '18:47'],
    '02-04': ['05:30', '06:53', '12:15', '15:09', '17:33', '18:48'],
    '02-05': ['05:29', '06:52', '12:15', '15:09', '17:34', '18:49'],
    '02-06': ['05:28', '06:51', '12:15', '15:10', '17:35', '18:50'],
    '02-07': ['05:27', '06:50', '12:15', '15:11', '17:36', '18:50'],
    '02-08': ['05:26', '06:49', '12:15', '15:12', '17:37', '18:51'],
    '02-09': ['05:25', '06:48', '12:15', '15:13', '17:38', '18:52'],
    '02-10': ['05:25', '06:47', '12:15', '15:14', '17:39', '18:53'],
    '02-11': ['05:24', '06:46', '12:15', '15:14', '17:40', '18:54'],
    '02-12': ['05:23', '06:45', '12:15', '15:15', '17:41', '18:55'],
    '02-13': ['05:22', '06:44', '12:15', '15:16', '17:42', '18:56'],
    '02-14': ['05:21', '06:43', '12:15', '15:17', '17:43', '18:57'],
    '02-15': ['05:20', '06:42', '12:15', '15:17', '17:44', '18:58'],
    '02-16': ['05:19', '06:41', '12:15', '15:18', '17:45', '18:59'],
    '02-17': ['05:18', '06:40', '12:15', '15:19', '17:46', '19:00'],
    '02-18': ['05:16', '06:39', '12:15', '15:19', '17:47', '19:01'],
    '02-19': ['05:15', '06:38', '12:15', '15:20', '17:48', '19:02'],
    '02-20': ['05:13', '06:37', '12:15', '15:21', '17:49', '19:03'],
    '02-21': ['05:12', '06:35', '12:15', '15:22', '17:50', '19:04'],
    '02-22': ['05:11', '06:34', '12:15', '15:22', '17:51', '19:04'],
    '02-23': ['05:09', '06:33', '12:15', '15:23', '17:52', '19:05'],
    '02-24': ['05:08', '06:32', '12:15', '15:23', '17:53', '19:06'],
    '02-25': ['05:06', '06:31', '12:14', '15:24', '17:54', '19:07'],
    '02-26': ['05:05', '06:29', '12:14', '15:25', '17:55', '19:08'],
    '02-27': ['05:04', '06:28', '12:14', '15:25', '17:56', '19:09'],
    '02-28': ['05:03', '06:27', '12:14', '15:26', '17:57', '19:10'],
    '02-29': ['05:02', '06:27', '12:14', '15:26', '17:57', '19:10'],
    '03-01': ['05:02', '06:26', '12:14', '15:26', '17:57', '19:10'],
    '03-02': ['05:01', '06:24', '12:14', '15:27', '17:58', '19:11'],
    '03-03': ['04:59', '06:23', '12:13', '15:27', '17:59', '19:12'],
    '03-04': ['04:58', '06:22', '12:13', '15:28', '18:00', '19:12'],
    '03-05': ['04:57', '06:20', '12:13', '15:28', '18:00', '19:13'],
    '03-06': ['04:55', '06:19', '12:13', '15:29', '18:01', '19:14'],
    '03-07': ['04:54', '06:18', '12:13', '15:29', '18:02', '19:15'],
    '03-08': ['04:53', '06:16', '12:12', '15:30', '18:03', '19:15'],
    '03-09': ['04:51', '06:15', '12:12', '15:30', '18:04', '19:16'],
    '03-10': ['04:50', '06:14', '12:12', '15:31', '18:05', '19:17'],
    '03-11': ['04:49', '06:12', '12:11', '15:31', '18:06', '19:18'],
    '03-12': ['04:48', '06:11', '12:11', '15:32', '18:07', '19:18'],
    '03-13': ['04:47', '06:10', '12:11', '15:32', '18:08', '19:19'],
    '03-14': ['04:46', '06:08', '12:11', '15:33', '18:09', '19:20'],
    '03-15': ['04:44', '06:07', '12:10', '15:33', '18:10', '19:21'],
    '03-16': ['04:43', '06:05', '12:10', '15:33', '18:10', '19:22'],
    '03-17': ['04:41', '06:04', '12:10', '15:34', '18:11', '19:22'],
    '03-18': ['04:40', '06:03', '12:10', '15:34', '18:12', '19:23'],
    '03-19': ['04:39', '06:01', '12:09', '15:34', '18:13', '19:24'],
    '03-20': ['04:37', '06:00', '12:09', '15:35', '18:14', '19:25'],
    '03-21': ['04:35', '05:58', '12:09', '15:35', '18:15', '19:26'],
    '03-22': ['04:34', '05:57', '12:08', '15:35', '18:15', '19:27'],
    '03-23': ['04:33', '05:56', '12:08', '15:36', '18:16', '19:27'],
    '03-24': ['04:31', '05:54', '12:08', '15:36', '18:17', '19:28'],
    '03-25': ['04:30', '05:53', '12:08', '15:36', '18:18', '19:29'],
    '03-26': ['04:29', '05:51', '12:07', '15:36', '18:19', '19:30'],
    '03-27': ['04:28', '05:50', '12:07', '15:37', '18:19', '19:30'],
    '03-28': ['04:27', '05:48', '12:07', '15:37', '18:20', '19:31'],
    '03-29': ['04:25', '05:47', '12:06', '15:37', '18:21', '19:32'],
    '03-30': ['04:23', '05:46', '12:06', '15:37', '18:22', '19:33'],
    '03-31': ['04:22', '05:44', '12:06', '15:38', '18:23', '19:33'],
    '04-01': ['04:21', '05:43', '12:05', '15:38', '18:23', '19:34'],
    '04-02': ['04:20', '05:41', '12:05', '15:38', '18:24', '19:35'],
    '04-03': ['04:18', '05:40', '12:05', '15:38', '18:25', '19:35'],
    '04-04': ['04:17', '05:39', '12:05', '15:38', '18:26', '19:36'],
    '04-05': ['04:15', '05:37', '12:04', '15:39', '18:27', '19:37'],
    '04-06': ['04:14', '05:36', '12:04', '15:39', '18:28', '19:38'],
    '04-07': ['04:13', '05:35', '12:04', '15:39', '18:28', '19:39'],
    '04-08': ['04:11', '05:33', '12:03', '15:39', '18:29', '19:40'],
    '04-09': ['04:10', '05:32', '12:03', '15:39', '18:30', '19:40'],
    '04-10': ['04:08', '05:30', '12:03', '15:39', '18:31', '19:41'],
    '04-11': ['04:07', '05:29', '12:03', '15:40', '18:32', '19:42'],
    '04-12': ['04:05', '05:28', '12:02', '15:40', '18:32', '19:43'],
    '04-13': ['04:04', '05:27', '12:02', '15:40', '18:33', '19:44'],
    '04-14': ['04:02', '05:25', '12:02', '15:40', '18:34', '19:44'],
    '04-15': ['04:01', '05:24', '12:02', '15:40', '18:35', '19:45'],
    '04-16': ['04:00', '05:23', '12:01', '15:40', '18:36', '19:46'],
    '04-17': ['03:59', '05:21', '12:01', '15:41', '18:37', '19:47'],
    '04-18': ['03:58', '05:20', '12:01', '15:41', '18:37', '19:48'],
    '04-19': ['03:56', '05:19', '12:01', '15:41', '18:38', '19:49'],
    '04-20': ['03:55', '05:18', '12:01', '15:41', '18:39', '19:49'],
    '04-21': ['03:53', '05:16', '12:00', '15:41', '18:40', '19:50'],
    '04-22': ['03:53', '05:15', '12:00', '15:41', '18:41', '19:51'],
    '04-23': ['03:50', '05:14', '12:00', '15:41', '18:42', '19:52'],
    '04-24': ['03:49', '05:13', '12:00', '15:41', '18:42', '19:53'],
    '04-25': ['03:48', '05:12', '12:00', '15:42', '18:43', '19:54'],
    '04-26': ['03:45', '05:10', '11:59', '15:42', '18:44', '19:54'],
    '04-27': ['03:44', '05:09', '11:59', '15:42', '18:45', '19:55'],
    '04-28': ['03:43', '05:08', '11:59', '15:42', '18:46', '19:56'],
    '04-29': ['03:41', '05:07', '11:59', '15:42', '18:47', '19:57'],
    '04-30': ['03:40', '05:06', '11:59', '15:42', '18:48', '19:57'],
    '05-01': ['03:39', '05:05', '11:59', '15:42', '18:48', '19:58'],
    '05-02': ['03:38', '05:04', '11:59', '15:42', '18:49', '19:59'],
    '05-03': ['03:37', '05:03', '11:58', '15:42', '18:50', '20:00'],
    '05-04': ['03:36', '05:02', '11:58', '15:42', '18:51', '20:01'],
    '05-05': ['03:35', '05:01', '11:58', '15:43', '18:52', '20:02'],
    '05-06': ['03:34', '05:00', '11:58', '15:43', '18:53', '20:03'],
    '05-07': ['03:33', '04:59', '11:58', '15:43', '18:53', '20:03'],
    '05-08': ['03:32', '04:58', '11:58', '15:43', '18:54', '20:04'],
    '05-09': ['03:31', '04:57', '11:58', '15:43', '18:55', '20:05'],
    '05-10': ['03:31', '04:56', '11:58', '15:43', '18:56', '20:06'],
    '05-11': ['03:30', '04:55', '11:58', '15:43', '18:57', '20:07'],
    '05-12': ['03:29', '04:54', '11:58', '15:43', '18:58', '20:08'],
    '05-13': ['03:28', '04:54', '11:58', '15:44', '18:58', '20:09'],
    '05-14': ['03:27', '04:53', '11:58', '15:44', '18:59', '20:10'],
    '05-15': ['03:26', '04:52', '11:58', '15:44', '19:00', '20:11'],
    '05-16': ['03:25', '04:51', '11:58', '15:44', '19:00', '20:12'],
    '05-17': ['03:24', '04:51', '11:58', '15:44', '19:01', '20:13'],
    '05-18': ['03:23', '04:50', '11:58', '15:44', '19:02', '20:14'],
    '05-19': ['03:22', '04:49', '11:58', '15:44', '19:03', '20:15'],
    '05-20': ['03:21', '04:49', '11:58', '15:45', '19:04', '20:15'],
    '05-21': ['03:20', '04:48', '11:58', '15:45', '19:05', '20:17'],
    '05-22': ['03:20', '04:47', '11:58', '15:45', '19:05', '20:18'],
    '05-23': ['03:19', '04:47', '11:58', '15:45', '19:04', '20:19'],
    '05-24': ['03:18', '04:46', '11:58', '15:45', '19:07', '20:20'],
    '05-25': ['03:17', '04:46', '11:58', '15:45', '19:08', '20:21'],
    '05-26': ['03:16', '04:45', '11:58', '15:45', '19:08', '20:22'],
    '05-27': ['03:16', '04:45', '11:58', '15:46', '19:09', '20:23'],
    '05-28': ['03:15', '04:44', '11:59', '15:46', '19:10', '20:24'],
    '05-29': ['03:15', '04:44', '11:59', '15:46', '19:10', '20:25'],
    '05-30': ['03:14', '04:44', '11:59', '15:46', '19:11', '20:26'],
    '05-31': ['03:14', '04:43', '11:59', '15:46', '19:12', '20:27'],
    '06-01': ['03:14', '04:43', '11:59', '15:47', '19:12', '20:28'],
    '06-02': ['03:13', '04:43', '11:59', '15:47', '19:13', '20:29'],
    '06-03': ['03:13', '04:42', '12:00', '15:47', '19:14', '20:29'],
    '06-04': ['03:13', '04:42', '12:00', '15:47', '19:14', '20:30'],
    '06-05': ['03:13', '04:42', '12:00', '15:47', '19:15', '20:31'],
    '06-06': ['03:12', '04:42', '12:00', '15:48', '19:15', '20:32'],
    '06-07': ['03:12', '04:41', '12:00', '15:48', '19:16', '20:32'],
    '06-08': ['03:12', '04:41', '12:00', '15:48', '19:16', '20:33'],
    '06-09': ['03:12', '04:41', '12:01', '15:48', '19:17', '20:34'],
    '06-10': ['03:12', '04:41', '12:01', '15:48', '19:17', '20:35'],
    '06-11': ['03:11', '04:41', '12:01', '15:49', '19:18', '20:36'],
    '06-12': ['03:11', '04:41', '12:01', '15:49', '19:18', '20:36'],
    '06-13': ['03:11', '04:41', '12:01', '15:49', '19:19', '20:37'],
    '06-14': ['03:11', '04:41', '12:02', '15:49', '19:19', '20:37'],
    '06-15': ['03:11', '04:41', '12:02', '15:49', '19:20', '20:37'],
    '06-16': ['03:11', '04:41', '12:02', '15:50', '19:20', '20:37'],
    '06-17': ['03:11', '04:41', '12:02', '15:50', '19:20', '20:38'],
    '06-18': ['03:11', '04:41', '12:02', '15:50', '19:20', '20:38'],
    '06-19': ['03:11', '04:42', '12:03', '15:50', '19:21', '20:38'],
    '06-20': ['03:11', '04:42', '12:03', '15:51', '19:21', '20:38'],
    '06-21': ['03:12', '04:42', '12:03', '15:51', '19:21', '20:38'],
    '06-22': ['03:12', '04:42', '12:03', '15:51', '19:21', '20:39'],
    '06-23': ['03:12', '04:42', '12:03', '15:51', '19:22', '20:39'],
    '06-24': ['03:13', '04:43', '12:04', '15:51', '19:22', '20:39'],
    '06-25': ['03:13', '04:43', '12:04', '15:52', '19:22', '20:39'],
    '06-26': ['03:14', '04:43', '12:04', '15:52', '19:22', '20:39'],
    '06-27': ['03:14', '04:44', '12:04', '15:52', '19:22', '20:39'],
    '06-28': ['03:14', '04:44', '12:05', '15:52', '19:22', '20:39'],
    '06-29': ['03:15', '04:44', '12:05', '15:53', '19:22', '20:39'],
    '06-30': ['03:15', '04:45', '12:05', '15:53', '19:22', '20:39'],
    '07-01': ['03:15', '04:45', '12:05', '15:53', '19:21', '20:39'],
    '07-02': ['03:16', '04:46', '12:05', '15:53', '19:21', '20:39'],
    '07-03': ['03:16', '04:46', '12:05', '15:53', '19:21', '20:38'],
    '07-04': ['03:17', '04:47', '12:06', '15:53', '19:21', '20:38'],
    '07-05': ['03:17', '04:47', '12:06', '15:53', '19:21', '20:38'],
    '07-06': ['03:18', '04:48', '12:06', '15:54', '19:20', '20:38'],
    '07-07': ['03:18', '04:48', '12:06', '15:54', '19:20', '20:37'],
    '07-08': ['03:19', '04:49', '12:06', '15:54', '19:20', '20:37'],
    '07-09': ['03:19', '04:49', '12:06', '15:54', '19:20', '20:37'],
    '07-10': ['03:20', '04:50', '12:06', '15:54', '19:19', '20:36'],
    '07-11': ['03:21', '04:51', '12:07', '15:54', '19:19', '20:36'],
    '07-12': ['03:21', '04:51', '12:07', '15:54', '19:20', '20:36'],
    '07-13': ['03:22', '04:52', '12:07', '15:54', '19:19', '20:35'],
    '07-14': ['03:22', '04:52', '12:07', '15:54', '19:19', '20:35'],
    '07-15': ['03:23', '04:53', '12:07', '15:55', '19:18', '20:34'],
    '07-16': ['03:24', '04:54', '12:07', '15:55', '19:18', '20:34'],
    '07-17': ['03:25', '04:54', '12:07', '15:55', '19:17', '20:33'],
    '07-18': ['03:26', '04:55', '12:07', '15:55', '19:17', '20:32'],
    '07-19': ['03:27', '04:56', '12:08', '15:55', '19:16', '20:31'],
    '07-20': ['03:27', '04:56', '12:08', '15:55', '19:16', '20:30'],
    '07-21': ['03:28', '04:57', '12:08', '15:54', '19:15', '20:30'],
    '07-22': ['03:29', '04:58', '12:08', '15:54', '19:14', '20:30'],
    '07-23': ['03:30', '04:59', '12:08', '15:54', '19:14', '20:29'],
    '07-24': ['03:31', '04:59', '12:08', '15:54', '19:13', '20:29'],
    '07-25': ['03:32', '05:00', '12:08', '15:54', '19:12', '20:28'],
    '07-26': ['03:33', '05:01', '12:08', '15:54', '19:12', '20:28'],
    '07-27': ['03:34', '05:01', '12:08', '15:54', '19:11', '20:27'],
    '07-28': ['03:35', '05:02', '12:08', '15:54', '19:10', '20:27'],
    '07-29': ['03:36', '05:03', '12:08', '15:54', '19:09', '20:26'],
    '07-30': ['03:37', '05:04', '12:08', '15:53', '19:08', '20:25'],
    '07-31': ['03:38', '05:04', '12:07', '15:53', '19:07', '20:24'],
    '08-01': ['03:39', '05:05', '12:07', '15:53', '19:06', '20:23'],
    '08-02': ['03:40', '05:06', '12:07', '15:53', '19:05', '20:22'],
    '08-03': ['03:40', '05:07', '12:07', '15:53', '19:04', '20:21'],
    '08-04': ['03:41', '05:07', '12:07', '15:52', '19:03', '20:20'],
    '08-05': ['03:41', '05:08', '12:07', '15:52', '19:02', '20:19'],
    '08-06': ['03:42', '05:09', '12:07', '15:51', '19:01', '20:18'],
    '08-07': ['03:43', '05:10', '12:07', '15:51', '19:00', '20:17'],
    '08-08': ['03:44', '05:10', '12:07', '15:51', '18:59', '20:16'],
    '08-09': ['03:45', '05:11', '12:07', '15:51', '18:58', '20:15'],
    '08-10': ['03:46', '05:12', '12:06', '15:50', '18:57', '20:14'],
    '08-11': ['03:47', '05:13', '12:06', '15:50', '18:56', '20:13'],
    '08-12': ['03:48', '05:14', '12:06', '15:50', '18:55', '20:12'],
    '08-13': ['03:49', '05:14', '12:06', '15:49', '18:54', '20:11'],
    '08-14': ['03:50', '05:15', '12:06', '15:49', '18:53', '20:10'],
    '08-15': ['03:51', '05:16', '12:06', '15:48', '18:52', '20:09'],
    '08-16': ['03:52', '05:17', '12:05', '15:48', '18:50', '20:08'],
    '08-17': ['03:52', '05:17', '12:05', '15:47', '18:48', '20:07'],
    '08-18': ['03:53', '05:18', '12:05', '15:47', '18:48', '20:06'],
    '08-19': ['03:54', '05:19', '12:05', '15:46', '18:47', '20:05'],
    '08-20': ['03:55', '05:20', '12:04', '15:46', '18:46', '20:04'],
    '08-21': ['03:55', '05:20', '12:04', '15:45', '18:44', '20:03'],
    '08-22': ['03:56', '05:21', '12:04', '15:45', '18:43', '20:02'],
    '08-23': ['03:57', '05:22', '12:04', '15:44', '18:42', '20:01'],
    '08-24': ['03:58', '05:23', '12:03', '15:44', '18:40', '20:00'],
    '08-25': ['03:59', '05:23', '12:03', '15:43', '18:39', '19:59'],
    '08-26': ['04:00', '05:24', '12:03', '15:42', '18:38', '19:56'],
    '08-27': ['04:01', '05:25', '12:03', '15:42', '18:36', '19:54'],
    '08-28': ['04:02', '05:26', '12:02', '15:41', '18:35', '19:53'],
    '08-29': ['04:03', '05:26', '12:02', '15:40', '18:34', '19:52'],
    '08-30': ['04:03', '05:27', '12:02', '15:40', '18:32', '19:50'],
    '08-31': ['04:04', '05:28', '12:01', '15:39', '18:31', '19:48'],
    '09-01': ['04:05', '05:29', '12:01', '15:38', '18:30', '19:46'],
    '09-02': ['04:05', '05:29', '12:01', '15:37', '18:28', '19:44'],
    '09-03': ['04:06', '05:30', '12:00', '15:37', '18:27', '19:42'],
    '09-04': ['04:07', '05:31', '12:00', '15:36', '18:25', '19:40'],
    '09-05': ['04:08', '05:32', '12:00', '15:35', '18:24', '19:38'],
    '09-06': ['04:08', '05:32', '11:59', '15:34', '18:23', '19:36'],
    '09-07': ['04:09', '05:33', '11:59', '15:34', '18:21', '19:35'],
    '09-08': ['04:10', '05:34', '11:59', '15:33', '18:20', '19:33'],
    '09-09': ['04:11', '05:34', '11:58', '15:32', '18:18', '19:31'],
    '09-10': ['04:12', '05:35', '11:58', '15:31', '18:17', '19:29'],
    '09-11': ['04:13', '05:36', '11:58', '15:30', '18:15', '19:28'],
    '09-12': ['04:14', '05:37', '11:57', '15:29', '18:14', '19:27'],
    '09-13': ['04:15', '05:37', '11:57', '15:28', '18:13', '19:25'],
    '09-14': ['04:15', '05:38', '11:57', '15:28', '18:11', '19:23'],
    '09-15': ['04:16', '05:39', '11:56', '15:27', '18:10', '19:22'],
    '09-16': ['04:17', '05:40', '11:56', '15:26', '18:08', '19:22'],
    '09-17': ['04:18', '05:40', '11:56', '15:25', '18:07', '19:20'],
    '09-18': ['04:18', '05:41', '11:55', '15:24', '18:05', '19:18'],
    '09-19': ['04:19', '05:42', '11:55', '15:23', '18:04', '19:16'],
    '09-20': ['04:20', '05:43', '11:55', '15:22', '18:02', '19:15'],
    '09-21': ['04:21', '05:43', '11:54', '15:21', '18:01', '19:13'],
    '09-22': ['04:21', '05:44', '11:54', '15:20', '18:00', '19:11'],
    '09-23': ['04:22', '05:45', '11:54', '15:19', '17:58', '19:09'],
    '09-24': ['04:23', '05:46', '11:53', '15:18', '17:57', '19:08'],
    '09-25': ['04:24', '05:46', '11:53', '15:17', '17:55', '19:07'],
    '09-26': ['04:24', '05:47', '11:53', '15:16', '17:54', '19:06'],
    '09-27': ['04:25', '05:48', '11:52', '15:15', '17:52', '19:05'],
    '09-28': ['04:26', '05:49', '11:52', '15:14', '17:51', '19:04'],
    '09-29': ['04:27', '05:49', '11:52', '15:13', '17:50', '19:02'],
    '09-30': ['04:27', '05:50', '11:51', '15:12', '17:48', '19:01'],
    '10-01': ['04:28', '05:51', '11:51', '15:11', '17:47', '19:00'],
    '10-02': ['04:29', '05:52', '11:51', '15:10', '17:45', '18:59'],
    '10-03': ['04:29', '05:52', '11:50', '15:09', '17:44', '18:58'],
    '10-04': ['04:30', '05:53', '11:50', '15:08', '17:42', '18:56'],
    '10-05': ['04:31', '05:54', '11:50', '15:07', '17:41', '18:54'],
    '10-06': ['04:32', '05:55', '11:49', '15:06', '17:40', '18:52'],
    '10-07': ['04:33', '05:56', '11:49', '15:05', '17:38', '18:50'],
    '10-08': ['04:34', '05:56', '11:49', '15:04', '17:37', '18:48'],
    '10-09': ['04:35', '05:57', '11:48', '15:03', '17:35', '18:47'],
    '10-10': ['04:36', '05:58', '11:48', '15:02', '17:34', '18:45'],
    '10-11': ['04:37', '05:59', '11:48', '15:01', '17:33', '18:43'],
    '10-12': ['04:38', '06:00', '11:48', '15:00', '17:31', '18:41'],
    '10-13': ['04:38', '06:00', '11:47', '14:58', '17:30', '18:39'],
    '10-14': ['04:39', '06:01', '11:47', '14:57', '17:29', '18:38'],
    '10-15': ['04:39', '06:02', '11:47', '14:57', '17:27', '18:36'],
    '10-16': ['04:40', '06:03', '11:47', '14:56', '17:26', '18:34'],
    '10-17': ['04:41', '06:04', '11:46', '14:55', '17:25', '18:32'],
    '10-18': ['04:42', '06:05', '11:46', '14:54', '17:24', '18:30'],
    '10-19': ['04:43', '06:06', '11:46', '14:53', '17:22', '18:29'],
    '10-20': ['04:44', '06:06', '11:46', '14:53', '17:21', '18:28'],
    '10-21': ['04:45', '06:07', '11:46', '14:52', '17:20', '18:27'],
    '10-22': ['04:45', '06:08', '11:46', '14:51', '17:19', '18:26'],
    '10-23': ['04:46', '06:09', '11:46', '14:50', '17:17', '18:25'],
    '10-24': ['04:47', '06:10', '11:45', '14:49', '17:16', '18:24'],
    '10-25': ['04:47', '06:11', '11:45', '14:48', '17:15', '18:24'],
    '10-26': ['04:48', '06:12', '11:45', '14:47', '17:14', '18:23'],
    '10-27': ['04:49', '06:13', '11:45', '14:46', '17:13', '18:22'],
    '10-28': ['04:50', '06:14', '11:45', '14:45', '17:12', '18:21'],
    '10-29': ['04:51', '06:14', '11:45', '14:45', '17:10', '18:21'],
    '10-30': ['04:52', '06:15', '11:45', '14:44', '17:09', '18:20'],
    '10-31': ['04:53', '06:16', '11:45', '14:43', '17:08', '18:19'],
    '11-01': ['04:54', '06:17', '11:45', '14:42', '17:07', '18:18'],
    '11-02': ['04:55', '06:18', '11:45', '14:42', '17:06', '18:18'],
    '11-03': ['04:56', '06:19', '11:45', '14:41', '17:05', '18:17'],
    '11-04': ['04:57', '06:20', '11:45', '14:40', '17:05', '18:17'],
    '11-05': ['04:58', '06:21', '11:45', '14:39', '17:04', '18:16'],
    '11-06': ['04:59', '06:22', '11:45', '14:39', '17:03', '18:15'],
    '11-07': ['05:00', '06:23', '11:45', '14:38', '17:02', '18:14'],
    '11-08': ['05:01', '06:24', '11:45', '14:37', '17:01', '18:14'],
    '11-09': ['05:02', '06:25', '11:45', '14:37', '17:00', '18:13'],
    '11-10': ['05:03', '06:26', '11:45', '14:36', '16:59', '18:12'],
    '11-11': ['05:04', '06:27', '11:45', '14:35', '16:58', '18:12'],
    '11-12': ['05:05', '06:28', '11:45', '14:35', '16:58', '18:11'],
    '11-13': ['05:06', '06:29', '11:45', '14:34', '16:57', '18:10'],
    '11-14': ['05:07', '06:30', '11:45', '14:34', '16:56', '18:10'],
    '11-15': ['05:08', '06:31', '11:46', '14:33', '16:56', '18:09'],
    '11-16': ['05:09', '06:32', '11:46', '14:33', '16:55', '18:08'],
    '11-17': ['05:10', '06:33', '11:46', '14:32', '16:54', '18:07'],
    '11-18': ['05:11', '06:34', '11:46', '14:32', '16:54', '18:07'],
    '11-19': ['05:12', '06:35', '11:46', '14:31', '16:53', '18:06'],
    '11-20': ['05:13', '06:36', '11:47', '14:31', '16:53', '18:06'],
    '11-21': ['05:14', '06:37', '11:47', '14:31', '16:52', '18:06'],
    '11-22': ['05:15', '06:38', '11:47', '14:30', '16:52', '18:05'],
    '11-23': ['05:16', '06:39', '11:47', '14:30', '16:51', '18:05'],
    '11-24': ['05:16', '06:40', '11:48', '14:30', '16:51', '18:05'],
    '11-25': ['05:17', '06:41', '11:48', '14:30', '16:51', '18:05'],
    '11-26': ['05:18', '06:41', '11:48', '14:29', '16:50', '18:06'],
    '11-27': ['05:18', '06:42', '11:49', '14:29', '16:50', '18:06'],
    '11-28': ['05:19', '06:43', '11:49', '14:29', '16:50', '18:06'],
    '11-29': ['05:19', '06:44', '11:49', '14:29', '16:49', '18:06'],
    '11-30': ['05:20', '06:45', '11:50', '14:29', '16:49', '18:07'],
    '12-01': ['05:20', '06:46', '11:50', '14:29', '16:49', '18:07'],
    '12-02': ['05:21', '06:47', '11:50', '14:28', '16:49', '18:07'],
    '12-03': ['05:21', '06:48', '11:51', '14:28', '16:49', '18:07'],
    '12-04': ['05:22', '06:49', '11:51', '14:28', '16:49', '18:07'],
    '12-05': ['05:23', '06:49', '11:51', '14:28', '16:49', '18:07'],
    '12-06': ['05:23', '06:50', '11:52', '14:29', '16:49', '18:07'],
    '12-07': ['05:24', '06:51', '11:52', '14:29', '16:49', '18:08'],
    '12-08': ['05:25', '06:52', '11:53', '14:29', '16:49', '18:08'],
    '12-09': ['05:26', '06:53', '11:53', '14:29', '16:49', '18:08'],
    '12-10': ['05:27', '06:54', '11:54', '14:29', '16:49', '18:08'],
    '12-11': ['05:27', '06:54', '11:54', '14:29', '16:49', '18:08'],
    '12-12': ['05:28', '06:55', '11:55', '14:30', '16:50', '18:08'],
    '12-13': ['05:29', '06:56', '11:55', '14:30', '16:50', '18:08'],
    '12-14': ['05:30', '06:56', '11:56', '14:30', '16:50', '18:08'],
    '12-15': ['05:31', '06:57', '11:56', '14:31', '16:50', '18:09'],
    '12-16': ['05:32', '06:58', '11:57', '14:31', '16:51', '18:09'],
    '12-17': ['05:33', '06:58', '11:57', '14:32', '16:51', '18:09'],
    '12-18': ['05:34', '06:59', '11:58', '14:32', '16:51', '18:09'],
    '12-19': ['05:34', '06:59', '11:58', '14:33', '16:52', '18:09'],
    '12-20': ['05:35', '07:00', '11:59', '14:33', '16:52', '18:09'],
    '12-21': ['05:35', '07:01', '11:59', '14:33', '16:53', '18:09'],
    '12-22': ['05:35', '07:01', '12:00', '14:34', '16:53', '18:10'],
    '12-23': ['05:35', '07:02', '12:00', '14:34', '16:54', '18:10'],
    '12-24': ['05:35', '07:02', '12:01', '14:35', '16:54', '18:11'],
    '12-25': ['05:35', '07:02', '12:01', '14:35', '16:55', '18:11'],
    '12-26': ['05:35', '07:03', '12:02', '14:36', '16:55', '18:12'],
    '12-27': ['05:35', '07:03', '12:02', '14:36', '16:56', '18:13'],
    '12-28': ['05:36', '07:03', '12:03', '14:37', '16:57', '18:14'],
    '12-29': ['05:36', '07:04', '12:03', '14:38', '16:58', '18:15'],
    '12-30': ['05:36', '07:04', '12:04', '14:38', '16:58', '18:16'],
    '12-31': ['05:36', '07:04', '12:04', '14:39', '16:59', '18:17'],
  },
  'کەلار': {},
  'سۆران': {},
  'زاخۆ': {},
};

/// Timetables that live in a data file instead of in the code.
/// assets/prayer_times.json (copied to the app root by build.yml):
///   {"cities": {"<city>": {"lat": 36.19, "lng": 44.0,
///                          "days": {"MM-DD": [fajr, sunrise, dhuhr, asr, maghrib, isha]}}}}
/// Days are merged into kAwqafSchedule; a city that is not in kPrayCities yet
/// is added to the picker. A missing or broken file changes nothing (the
/// built-in tables and the engine keep working). Call once, before
/// locPrefs.ensureLoaded().
class PrayerData {
  static bool loaded = false;
  static int cities = 0, days = 0, skipped = 0;

  static bool _ok(List<String> v) {
    if (v.length != 6) return false;
    for (var i = 0; i < 6; i++) {
      if (!PrayerCalc._hhmm.hasMatch(v[i])) return false;
      if (i > 0 && v[i].compareTo(v[i - 1]) <= 0) return false; // must increase
    }
    return true;
  }

  static Future<void> load() async {
    try {
      final raw = await rootBundle.loadString('prayer_times.json');
      final root = jsonDecode(raw) as Map<String, dynamic>;
      final all = (root['cities'] as Map<String, dynamic>?) ?? const {};
      for (final e in all.entries) {
        final v = e.value as Map<String, dynamic>;
        final src = (v['days'] as Map<String, dynamic>?) ?? const {};
        final table = kAwqafSchedule.putIfAbsent(e.key, () => <String, List<String>>{});
        for (final d in src.entries) {
          final row = (d.value as List<dynamic>).map((x) => x.toString()).toList();
          if (_ok(row)) {
            table[d.key] = row;
            days++;
          } else {
            skipped++;
          }
        }
        if (!kPrayCities.any((c) => c.ku == e.key)) {
          kPrayCities.add(
              PrayCity(e.key, (v['lat'] as num?)?.toDouble() ?? 35.5,
                  (v['lng'] as num?)?.toDouble() ?? 44.5,
                  awqaf: true));
        }
        cities++;
      }
      loaded = true;
      debugPrint('prayer_times.json: $cities cities, $days days, $skipped skipped');
    } catch (e) {
      debugPrint('prayer_times.json not used: $e');
    }
  }
}

class PrayerCalc {
  static const double fajrAngle = 18; // Muslim World League
  static const double ishaAngle = 17;

  static double _rad(double d) => d * math.pi / 180;
  static double _deg(double r) => r * 180 / math.pi;
  static double _fix(double a, double b) {
    final r = a - b * (a / b).floorToDouble();
    return r < 0 ? r + b : r;
  }

  static double _julian(int y, int m, int d) {
    var yy = y;
    var mm = m;
    if (mm <= 2) {
      yy -= 1;
      mm += 12;
    }
    final a = (yy / 100).floor();
    final b = 2 - a + (a / 4).floor();
    return (365.25 * (yy + 4716)).floorToDouble() +
        (30.6001 * (mm + 1)).floorToDouble() +
        d +
        b -
        1524.5;
  }

  /// [declination in degrees, equation of time in hours]
  static List<double> _sun(double jd) {
    final d = jd - 2451545.0;
    final g = _fix(357.529 + 0.98560028 * d, 360);
    final q = _fix(280.459 + 0.98564736 * d, 360);
    final l = _fix(
        q + 1.915 * math.sin(_rad(g)) + 0.020 * math.sin(_rad(2 * g)), 360);
    final e = 23.439 - 0.00000036 * d;
    var ra = _deg(math.atan2(
            math.cos(_rad(e)) * math.sin(_rad(l)), math.cos(_rad(l)))) /
        15;
    ra = _fix(ra, 24);
    var eqt = q / 15 - ra;
    eqt = _fix(eqt + 12, 24) - 12;
    final decl = _deg(math.asin(math.sin(_rad(e)) * math.sin(_rad(l))));
    return [decl, eqt];
  }

  /// hours the sun needs to go from noon to [angle] degrees below the horizon
  static double? _angleTime(double angle, double decl, double lat) {
    final x = (-math.sin(_rad(angle)) -
            math.sin(_rad(decl)) * math.sin(_rad(lat))) /
        (math.cos(_rad(decl)) * math.cos(_rad(lat)));
    if (x.isNaN || x < -1 || x > 1) return null;
    return _deg(math.acos(x)) / 15;
  }

  /// [mins] after midnight on [date], read on the city's clock. With a fixed
  /// zone (Asia/Baghdad) the result is the right instant even when the phone is
  /// set to another zone; otherwise it is the phone's own wall clock.
  static DateTime _mk(DateTime date, int mins, double? fixedTz) {
    final off = fixedTz == null ? null : (fixedTz * 60).round();
    if (off == null || off == date.timeZoneOffset.inMinutes) {
      return DateTime(date.year, date.month, date.day)
          .add(Duration(minutes: mins));
    }
    return DateTime.utc(date.year, date.month, date.day)
        .add(Duration(minutes: mins - off))
        .toLocal();
  }

  static PrayerDay compute(PrayCity c, DateTime date,
      {bool hanafi = false, double? tzHours, bool ignoreSchedule = false}) {
    // Kurdistan / Iraq always use Asia/Baghdad (UTC+3), whatever the phone says.
    final fixedTz = tzHours == null ? (c.tz ?? (c.awqaf ? 3.0 : null)) : null;
    final exact = ignoreSchedule ? null : _fromSchedule(c, date, fixedTz);
    if (exact != null && !hanafi) return exact;
    if (exact != null) {
      // Hanafi: the official day stays for every prayer; only Asr moves, by the
      // engine's own Hanafi-minus-Shafi'i difference.
      final s = compute(c, date, tzHours: tzHours, ignoreSchedule: true);
      final h = compute(c, date, hanafi: true, tzHours: tzHours, ignoreSchedule: true);
      final sa = s.asr, ha = h.asr, ea = exact.asr;
      if (sa == null || ha == null || ea == null) return exact;
      return PrayerDay(exact.fajr, exact.sunrise, exact.dhuhr,
          ea.add(ha.difference(sa)), exact.maghrib, exact.isha);
    }
    final tz = tzHours ?? fixedTz ?? date.timeZoneOffset.inMinutes / 60.0;
    final jd = _julian(date.year, date.month, date.day) - c.lng / (15 * 24);
    final s = _sun(jd + 0.5);
    final decl = s[0];
    final eqt = s[1];
    final noon = 12 + tz - c.lng / 15 - eqt;

    double? before(double angle) {
      final t = _angleTime(angle, decl, c.lat);
      return t == null ? null : noon - t;
    }

    double? after(double angle) {
      final t = _angleTime(angle, decl, c.lat);
      return t == null ? null : noon + t;
    }

    final factor = hanafi ? 2.0 : 1.0;
    final asrAngle = -_deg(
        math.atan(1 / (factor + math.tan(_rad((c.lat - decl).abs())))));

    DateTime? at(double? h) {
      if (h == null || h.isNaN) return null;
      final mins = (_fix(h, 24) * 60).round();
      return _mk(date, mins, fixedTz);
    }

    final sunrise = before(0.833);
    final sunset = after(0.833);
    final asr = after(asrAngle);

    // ---- Kurdistan Awqaf timetable ----
    // The Awqaf tables are not a pure astronomical result: noon, sunset and
    // Asr carry a few extra minutes, and Fajr / Isha are a (nearly) fixed
    // number of minutes before sunrise / after sunset. The numbers per city
    // were measured against the official tables.
    if (c.awqaf && sunrise != null && sunset != null && asr != null) {
      // 0 in winter ... 1 in mid-summer (day length 12h -> 14.5h)
      final summer = ((sunset - sunrise - 12) / 2.5).clamp(0.0, 1.0).toDouble();
      double m(double base, double summerExtra) => (base + summer * summerExtra) / 60;

      final riseA = sunrise + m(c.dRise, c.sRise);
      final noonA = noon + m(c.dNoon, c.sNoon);
      final asrA = asr + m(c.dAsr, c.sAsr);
      final setA = sunset + m(c.dSet, c.sSet);
      return PrayerDay(
        at(riseA - m(c.fajrGap, c.sFajr)),
        at(riseA),
        at(noonA),
        at(asrA),
        at(setA),
        at(setA + m(c.ishaGap, c.sIsha)),
      );
    }

    // ---- plain astronomical (Muslim World League) ----
    return PrayerDay(
      at(before(fajrAngle)),
      at(sunrise),
      at(noon),
      at(asr),
      at(sunset),
      at(after(ishaAngle)),
    );
  }

  static final RegExp _hhmm = RegExp(r'^([01]\d|2[0-3]):[0-5]\d$');

  /// The exact Awqaf day from [kAwqafSchedule], or null (-> engine).
  static PrayerDay? _fromSchedule(PrayCity c, DateTime date, double? fixedTz) {
    final row = kAwqafSchedule[c.ku]?['${_two(date.month)}-${_two(date.day)}'];
    if (row == null || row.length != 6) return null;
    final out = <DateTime>[];
    for (final v in row) {
      if (!_hhmm.hasMatch(v)) return null; // malformed entry: use the engine
      out.add(_mk(date, int.parse(v.substring(0, 2)) * 60 + int.parse(v.substring(3, 5)),
          fixedTz));
    }
    return PrayerDay(out[0], out[1], out[2], out[3], out[4], out[5]);
  }

  /// true when [date] comes from the official Awqaf table for this city.
  static bool isOfficial(PrayCity c, DateTime date) =>
      kAwqafSchedule[c.ku]?['${_two(date.month)}-${_two(date.day)}']?.length == 6;

  /// Checks every table entry (format, order, city name). Debug only.
  static bool validateSchedule() {
    final key = RegExp(r'^(0[1-9]|1[0-2])-(0[1-9]|[12]\d|3[01])$');
    for (final city in kAwqafSchedule.entries) {
      if (!kPrayCities.any((x) => x.ku == city.key)) {
        debugPrint('Awqaf schedule: unknown city ${city.key}');
        return false;
      }
      for (final day in city.value.entries) {
        final v = day.value;
        var ok = key.hasMatch(day.key) && v.length == 6 && v.every(_hhmm.hasMatch);
        for (var i = 1; ok && i < 6; i++) {
          ok = v[i].compareTo(v[i - 1]) > 0; // fajr < sunrise < ... < isha
        }
        if (!ok) {
          debugPrint('Awqaf schedule: bad entry ${city.key} ${day.key} $v');
          return false;
        }
      }
    }
    return true;
  }

  /// Prints a 365-day Dart map of the ENGINE's times for [c] (year 2026) so
  /// you can paste it into kAwqafSchedule and then overwrite the days with the
  /// official Awqaf numbers. These are calculated, NOT official, until you
  /// replace them.
  static String exportYearTemplate(PrayCity c, {int year = 2026}) {
    final b = StringBuffer("  '${c.ku}': {\n");
    var d = DateTime(year, 1, 1);
    while (d.year == year) {
      final t = compute(PrayCity(c.ku, c.lat, c.lng, awqaf: true,
              dRise: c.dRise, dNoon: c.dNoon, dAsr: c.dAsr, dSet: c.dSet,
              sRise: c.sRise, sNoon: c.sNoon, sAsr: c.sAsr, sSet: c.sSet,
              fajrGap: c.fajrGap, ishaGap: c.ishaGap,
              sFajr: c.sFajr, sIsha: c.sIsha),
          d, tzHours: 3, ignoreSchedule: true).list.map((x) => "'${_hm(x)}'");
      b.writeln("    '${_two(d.month)}-${_two(d.day)}': [${t.join(', ')}],");
      d = DateTime(d.year, d.month, d.day + 1);
    }
    b.writeln('  },');
    return b.toString();
  }

  /// Debug check against the official Awqaf benchmark of 29/10/2026.
  /// Call once from main(): assert(PrayerCalc.selfTest());
  static bool selfTest() {
    const bench = {
      'سلێمانی': ['04:55', '06:17', '11:48', '14:44', '17:15', '18:31'],
      'سەیدسادق': ['04:53', '06:15', '11:46', '14:42', '17:13', '18:29'],
    };
    if (!validateSchedule()) return false;
    // engine alone (schedule ignored) must also hit the benchmark
    // fixed UTC+3 (Iraq) so the test does not depend on the device zone
    for (final e in bench.entries) {
      final c = kPrayCities.firstWhere((x) => x.ku == e.key);
      final d = compute(c, DateTime(2026, 10, 29),
          hanafi: false, tzHours: 3, ignoreSchedule: true);
      final got = d.list.map((t) => t == null ? '--' : _hm(t)).toList();
      if (got.join() != e.value.join()) {
        debugPrint('Awqaf self-test FAILED for ${e.key}: $got vs ${e.value}');
        return false;
      }
    }
    return true;
  }

  static NextPrayer next(PrayCity c, DateTime now, {bool hanafi = false}) {
    final today = compute(c, now, hanafi: hanafi).list;
    for (final i in const [0, 2, 3, 4, 5]) {
      final t = today[i];
      if (t != null && t.isAfter(now)) return NextPrayer(i, t);
    }
    final tomorrow = DateTime(now.year, now.month, now.day + 1);
    final tm = compute(c, tomorrow, hanafi: hanafi).list;
    return NextPrayer(0, tm[0] ?? tomorrow.add(const Duration(hours: 5)));
  }
}

// ---------- the dashboard ----------
class DashboardPage extends StatefulWidget {
  const DashboardPage({super.key});

  @override
  State<DashboardPage> createState() => _DashboardPageState();
}

class _DashboardPageState extends State<DashboardPage> {
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    locPrefs.ensureLoaded();
    tajProgress.ensureLoaded();
    _tick = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  void _open(Widget page) {
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => page));
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([settings, locPrefs, tajProgress]),
      builder: (context, _) {
        final city = locPrefs.c;
        final now = DateTime.now();
        final next = PrayerCalc.next(city, now, hanafi: locPrefs.hanafi);
        final bearing = qiblaBearing(city.lat, city.lng);
        final lv = (settings.coachLevel - 1).clamp(0, 2).toInt();
        final gridBg =
            _isDark(context) ? const Color(0xFF16201A) : const Color(0xFFEEEEEE);
        return Scaffold(
          bottomNavigationBar: const PlayerBar(),
          appBar: AppBar(
            leading: PopupMenuButton<int>(
              tooltip: 'مێنیو',
              icon: const Icon(Icons.menu),
              onSelected: (v) {
                if (v == 0) {
                  _open(const SearchPage());
                } else if (v == 1) {
                  _open(const BookmarksPage());
                } else {
                  settings.toggleDark();
                }
              },
              itemBuilder: (_) => const [
                PopupMenuItem<int>(value: 0, child: Text('گەڕان لە ئایەتەکان')),
                PopupMenuItem<int>(value: 1, child: Text('نیشانەکان')),
                PopupMenuItem<int>(value: 2, child: Text('تاریک / ڕووناک')),
              ],
            ),
            title: const Text(
              'قورئانی پیرۆز',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
            actions: [
              IconButton(
                tooltip: 'ڕێکخستنەکان',
                onPressed: () => _open(const SettingsPage()),
                icon: const Icon(Icons.settings),
              ),
            ],
          ),
          body: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 820),
              child: ListView(
                padding: EdgeInsets.zero,
                children: [
                  const Padding(
                    padding: EdgeInsets.fromLTRB(14, 12, 14, 0),
                    child: _DashBanner(),
                  ),
                  const _ContinueCard(),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(18, 18, 18, 10),
                    child: Text(
                      'بەشەکانی پرۆگرام:',
                      style: TextStyle(
                        fontSize: 19,
                        fontWeight: FontWeight.bold,
                        color: _inkColor(context),
                      ),
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.fromLTRB(12, 14, 12, 28),
                    decoration: BoxDecoration(
                      color: gridBg,
                      borderRadius:
                          const BorderRadius.vertical(top: Radius.circular(28)),
                    ),
                    child: GridView(
                      padding: EdgeInsets.zero,
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: 2,
                        mainAxisSpacing: 12,
                        crossAxisSpacing: 12,
                        mainAxisExtent: 150,
                      ),
                      children: [
                        // 1) Quran
                        _DashTile(
                          icon: Icons.menu_book,
                          color: _green,
                          title: 'قوُڕئانی پیرۆز',
                          subtitle: '١١٤ سوورەت',
                          onTap: () => _open(const SurahListPage()),
                        ),
                        // 2) Microphone & levels
                        _DashTile(
                          icon: Icons.mic,
                          color: const Color(0xFFC48A0E),
                          title: 'مایک و لیڤڵەکان',
                          subtitle: 'ئاست: ${_lvShort[lv]}',
                          onTap: () => _open(const MicLevelsPage()),
                        ),
                        // 3) Qibla
                        _DashTile(
                          icon: Icons.explore,
                          color: const Color(0xFF2E6F95),
                          title: 'قیبلەنما',
                          subtitle: '${city.ku} • ${bearing.round()}°',
                          onTap: () => _open(const QiblaPage()),
                        ),
                        // 4) Azkar
                        _DashTile(
                          icon: Icons.auto_awesome,
                          color: const Color(0xFF7B4B94),
                          title: 'زیکرەکان',
                          subtitle: 'بەیانیان و ئێواران',
                          onTap: () => _open(const AzkarPage()),
                        ),
                        // 5) Prayer times
                        _DashTile(
                          icon: Icons.access_time_filled,
                          color: const Color(0xFF2A8C82),
                          title: 'کاتەکانی بانگ',
                          subtitle:
                              '${kPrayerShort[next.index]} ${_hm(next.time)}',
                          onTap: () => _open(const PrayerTimesPage()),
                        ),
                        // 6) Tajweed & teaching
                        _DashTile(
                          icon: Icons.school,
                          color: const Color(0xFFB5552B),
                          title: 'تەجوید و فێرکردن',
                          subtitle:
                              '${tajProgress.read.length}/${kTajweedLessons.length} وانە خوێندراوەتەوە',
                          onTap: () => _open(const TajweedLessonsScreen()),
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

// ============================================================
//  تەجوید و فێرکردن - offline Tajweed curriculum (29 lessons)
// ============================================================

/// Font list for the Quranic examples. If you bundle a Uthmani Quran font
/// (e.g. KFGQPC Uthmanic Hafs), put its family name FIRST in this list.
/// Must match the `family:` name of the font in pubspec.yaml. If the font is
/// not bundled yet, Flutter silently falls back to the _arFonts list.
const String _uthmaniFont = 'UthmanicHafs';
const List<String> _tajQuranFonts = [_uthmaniFont, ..._arFonts];

class TajweedExample {
  final String text; // Uthmani Arabic
  final String ref; // 'surah:ayah' (empty when it is just a word)
  final String note; // Kurdish note
  const TajweedExample(this.text, {this.ref = '', this.note = ''});
}

class TajweedLesson {
  final int id;
  final String titleKu;
  final String titleAr;
  final String summary;
  final List<String> rules;
  final List<TajweedExample> examples;

  /// true = the rules are shown as 1, 2, 3 ... (when their order matters)
  final bool numberedRules;
  const TajweedLesson({
    required this.id,
    required this.titleKu,
    required this.titleAr,
    required this.summary,
    required this.rules,
    required this.examples,
    this.numberedRules = false,
  });
}

const List<TajweedLesson> kTajweedLessons = [
  TajweedLesson(
    id: 1,
    titleKu: 'ئیستعاذە و بەسمەلە',
    titleAr: 'الاستعاذة والبسملة',
    summary:
        'حوکمەکان و چۆنیەتی خوێندنەوەی أعوذ بالله و بسم الله لە سەرەتای خوێندنەوە و نێوان سورەتەکاندا.',
    numberedRules: true,
    rules: [
      'بڕینەوەی هەمووی (قطع الجميع): وەستان لەسەر ئیستعاذە، پاشان بەسمەلە، پاشان دەستپێکی سورەت.',
      'گەیاندنی هەمووی (وصل الجميع): خوێندنەوەی ئیستعاذە و بەسمەلە و دەستپێکی سورەت بە یەک هەناسە.',
      'بڕینی یەکەم و گەیاندنی دووەم و سێیەم: وەستان لەسەر ئیستعاذە، پاشان بەستنەوەی بەسمەلە بە سەرەتای سورەت.',
      'گەیاندنی یەکەم و دووەم و بڕینی سێیەم: بەستنەوەی ئیستعاذە بە بەسمەلە، پاشان وەستان پێش دەستپێکی سورەت.',
    ],
    examples: [
      TajweedExample('أَعُوذُ بِٱللَّهِ مِنَ ٱلشَّيْطَـٰنِ ٱلرَّجِيمِ',
          note: 'ئیستعاذە'),
      TajweedExample('بِسْمِ ٱللَّهِ ٱلرَّحْمَـٰنِ ٱلرَّحِيمِ',
          ref: '1:1', note: 'بەسمەلە'),
    ],
  ),
  TajweedLesson(
    id: 2,
    titleKu: 'مەخرەجی پیتەکان',
    titleAr: 'مخارج الحروف',
    summary:
        'مەخرەج واتە شوێنی دەرچوونی پیتەکە. پیتەکانی عەرەبی لە پێنج شوێنی گشتییەوە دەردەچن.',
    rules: [
      'پێنج شوێنی گشتی: الجوف (بۆشایی دەم و گەروو)، الحلق (گەروو)، اللسان (زمان)، الشفتان (دوو لێو)، الخيشوم (لووت).',
      'پیتەکانی مەد (ا و ي) لە الجوف دەردەچن.',
      'پیتەکانی گەروو شەشن: ء و ه (کۆتایی گەروو)، ع و ح (ناوەڕاست)، غ و خ (سەرەوەی گەروو).',
      'ق و ك لە کۆتایی زمان؛ ج ش ي لە ناوەڕاستی زمان؛ ل ن ر لە نووکی زمان.',
      'ب م و لە دوو لێو؛ ف لە ددانە سەرەوەکان و لێوی خوارەوە.',
      'بۆ دۆزینەوەی مەخرەج: پیتەکە ساکن بکە و هەمزەیەکی پێش بخە، وەک أَبْ، أَتْ، أَقْ.',
    ],
    examples: [
      TajweedExample('ٱلْحَمْدُ', ref: '1:2', note: 'ح لە ناوەڕاستی گەروو؛ م لە دوو لێو'),
      TajweedExample('قُلْ', ref: '112:1', note: 'ق لە کۆتایی زمان'),
    ],
  ),
  TajweedLesson(
    id: 3,
    titleKu: 'صیفاتە خاوەن دژەکان',
    titleAr: 'صِفَاتُ الْحُرُوفِ (التي لها ضد)',
    summary:
        'ئەو صیفاتە ذاتیانەی پیتەکان کە دژیان هەیە، و هەموو پیتێکی عەرەبی چەند صیفاتێکی لەم کۆمەڵانە تێدایە.',
    numberedRules: true,
    rules: [
      'الهمس (هەناسەدان) دژی الجهر (دەنگداری): پیتەکانی هەمس (فَحَثَّهُ شَخْصٌ سَکَتَ)، و جهر باقی پیتەکانە.',
      'الشدة (توندی) دژی الرخوَة (نەرمی)، و لە نێوانیاندا البَيْنِيَّة (ناوەند):\n• شدة: (أَجِدُ قَطْبٍ بَكَتْ).\n• بينية: (لَنْ عُمَرَ).\n• رخوة: باقي الحروف.',
      'الاستعلاء (بەرزبوونەوەی زمان بەرەو بنمیچ) دژی الاستفال (نزمبوونەوە): استعلاء (خُصَّ ضَغْطٍ قِظْ)، و استففال باقی پیتەکان.',
      'الإطباق (نووسانی زمان بە بنمیچ) دژی الانفتاح (کرانەوە): إطباق (ص، ض، ط، ظ)، و انفتاح باقی پیتەکان.',
      'الإذلاق (سووکی و خێرایی دەرچوون) دژی الإصمات (قورسی): إذلاق (فَرّ مِنْ لُبّ)، و إصمات باقی پیتەکان.',
    ],
    examples: [
      TajweedExample('صِرَٰطَ',
          ref: '1:7', note: 'استعلاء وإطباق في الصاد والطاء'),
      TajweedExample('نَسْتَعِينُ', ref: '1:5', note: 'همس في السين والتاء'),
    ],
  ),
  TajweedLesson(
    id: 4,
    titleKu: 'صیفاتی بێ دژ (الصفات التي لا ضد لها)',
    titleAr: 'صِفَاتُ الْحُرُوفِ (التي لا ضد لها)',
    summary:
        'ئەو صیفاتە ذاتیانەی پیتەکان کە پێچەوانەیان نییە، و هەر پیتێک یەکێک یان چەندێکی تێدایە.',
    numberedRules: true,
    rules: [
      'الصفير: دەنگێکی هاوشێوەی باڵندە لە پیتەکانی (ص، ز، س).',
      'القلقله: لەرزینەوە لە (قطب جد).',
      'اللين: دەرچوونی پیت بە نەرمی (و، ي) کاتێک ساکینن و پێشیان مەفتوحە (وەک: خَوْف، بَيْت).',
      'الانحراف: لادانی پیتی لام و ڕا لە مەخرەجیان خۆیانەوە بۆ شوێنێکی نزیک (ل، ر).',
      'التَّكْرِير: دووبارەبوونەوەی دەنگی پیتی (ر) بێ زیادەڕۆیی.',
      'التَّفَشِّی: بڵاوبوونەوەی هەوا لە دەمدا لە کاتی دەرچوونی پیتی (ش).',
      'الِاسْتِطَالَة: درێژبوونەوەی دەنگ لە سەرەتای مەخرەجی (ض) تا کۆتایی لێوارەکەی.',
    ],
    examples: [
      TajweedExample('ٱلصَّـٰبِرِينَ', ref: '2:153', note: 'الصفير في الصاد'),
      TajweedExample('ٱلْيَوْمَ', note: 'اللين في الواو'),
      TajweedExample('وَٱلشَّمْسِ', ref: '91:1', note: 'التفشي في الشين'),
    ],
  ),
  TajweedLesson(
    id: 5,
    titleKu: 'ئیزهار (الإظهار)',
    titleAr: 'الإظهار الحلقي (من أحكام النون الساكنة والتنوين)',
    summary:
        'پێناسەی ئیزهار و خوێندنەوەی نونی ساکین یان تنوین بە ئاشکرایی و بێ غوننە کاتێک دێنە پێش پیتەکانی قورگ.',
    numberedRules: true,
    rules: [
      'پیتەکانی ئیزهار ٦ پیتن (پیتەکانی قورگ): (ء، هـ، ع، ح، غ، خ).',
      'چۆنیەتی خوێندنەوە: نونی ساکین یان تنوینەکە بە ڕوونی دەردەبڕدرێت بێ ئەوەی وەستان یان غوننەی تێدا بکڕێت.',
      'ڕوودان: لە یەک وشەدا یان لە نێوان دوو وشەدا ڕوو دەدات.',
    ],
    examples: [
      TajweedExample('مَنْ ءَامَنَ', ref: '2:62', note: 'إظهار حرف الهمزة'),
      TajweedExample('يَنْـَٔوْنَ', ref: '6:26', note: 'إظهار في كلمة واحدة'),
      TajweedExample('سَمِيعٌ عَلِيمٌ', note: 'إظهار التنوين'),
      TajweedExample('مِنْ هَادٍ', ref: '13:33'),
      TajweedExample('أَنْعَمْتَ', ref: '1:7'),
      TajweedExample('مِنْ غِلٍّ', ref: '7:43'),
      TajweedExample('عَذَابٌ أَلِيمٌ'),
    ],
  ),
  TajweedLesson(
    id: 6,
    titleKu: 'ئیدغام (الإدغام)',
    titleAr: 'الإدغام (من أحكام النون الساكنة والتنوين)',
    summary:
        'پێناسەی ئیدغام و تێکەڵکردنی نونی ساکین یان تنوین لەگەڵ پیتەکانی ئیدغامدا (يرملون)، کە دابەش دەبێت بۆ سەر دوو بەش.',
    numberedRules: true,
    rules: [
      'ئیدغامی بغنة (مع الغنة): کاتێک نونی ساکین یان تنوین دێت پێش پیتەکانی (ی، ن، م، و - پیتەکانی ينمو)، ئەوا غوننەی تێدا دەکرێت.',
      'ئیدغامی بێ غوننە (بغير غنة): کاتێک نونی ساکین یان تنوین دێت پێش پیتەکانی (ل، ر)، بێ غوننە دەخوێنرێتەوە.',
      'مەرجی سەرەکی: ئیدغام تەنها لە نێوان دوو وشەدا دروست دەبێت (نونی ساکین لە کۆتایی وشەیەک و پیتەکەی تر لە سەرەتای وشەی دووەم).',
    ],
    examples: [
      TajweedExample('مَن يَعْمَلْ', ref: '99:7', note: 'إدغام بغنة'),
      TajweedExample('مِن لَّدُنْ', ref: '18:2', note: 'إدغام بغير غنة'),
      TajweedExample('غَفُورٌ رَّحِيمٌ', note: 'إدغام تنوين بغير غنة'),
      TajweedExample('ٱلدُّنْيَا',
          note: 'ئیدغام نییە: نوون و ی لە یەک وشەدان'),
    ],
  ),
  TajweedLesson(
    id: 7,
    titleKu: 'ئیقلاب (الإقلاب)',
    titleAr: 'الإقلاب (من أحكام النون الساكنة والتنوين)',
    summary:
        'گۆڕینی دەنگی نونی ساکین یان تنوین بۆ میمێکی شاراوە لەگەڵ بەجێهێنانی غوننە کاتێک دێتە پێش پیتی (ب).',
    numberedRules: true,
    rules: [
      'پیتی ئیقلاب تەنها ١ پیتە: پیتی (ب).',
      'چۆنیەتی خوێندنەوە: نونی ساکین یان تنوینەکە دەگۆڕدرێت بۆ پیتی (م) و بە غوننە و نەرمییەوە دەخوێنرێتەوە (لە قورئاندا ميمێکی بچووک ـۢ لەسەری دادەنرێت).',
      'ڕوودان: لە یەک وشەدا یان لە نێوان دوو وشەدا ڕوو دەدات.',
    ],
    examples: [
      TajweedExample('مِنۢ بَعْدِ', note: 'تُقرأ: مِمْ بَعْدِ'),
      TajweedExample('أَنۢبِئْهُم', ref: '2:33', note: 'إقلاب في كلمة واحدة'),
      TajweedExample('خَبِيرٌۢ بَصِيرٌ', note: 'إقلاب التنوين'),
    ],
  ),
  TajweedLesson(
    id: 8,
    titleKu: 'ئیخفایی حەقیقی',
    titleAr: 'الإخفاء الحقيقي (من أحكام النون الساكنة والتنوين)',
    summary:
        'شاردنەوەی دەنگی نونی ساکین یان تنوین لە نێوان ئیزهار و ئیدغامدا لەگەڵ بەجێهێنانی غوننە، کاتێک دێنە پێش پیتەکانی ئیخفا.',
    numberedRules: true,
    rules: [
      'پیتەکانی ئیخفا ١٥ پیتن (ئەو پیتانەی کە ماون دوای پیتەکانی ئیزهار، ئیدغام و ئیقلاب)، وەک: (ص، ذ، ث، ك، ج، ش، ق، س، د، ط، ز، ف، ت، ض، ظ).',
      'چۆنیەتی خوێندنەوە: نونی ساکین یان تنوين بە شاردراوەیی (بە بێ تەواوکردنی مەخرەجی نون) لەگەڵ غوننەیەکی درێژخایەن دەخوێنرێتەوە.',
      'ڕوودان: لە یەک وشەدا یان لە نێوان دوو وشەدا ڕوو دەدات.',
    ],
    examples: [
      TajweedExample('مِن صَلْصَـٰلٍ',
          ref: '15:26', note: 'إخفاء النون عند حرف الصاد'),
      TajweedExample('أَنفُسُكُمْ',
          note: 'إخفاء في كلمة واحدة عند حرف الفاء'),
      TajweedExample('رِزْقًا كَرِيمًا',
          ref: '33:31', note: 'إخفاء التنوين عند حرف الكاف'),
    ],
  ),
  TajweedLesson(
    id: 9,
    titleKu: 'ئیخفایی شەفەوی',
    titleAr: 'الإخفاء الشفوي (من أحكام الميم الساكنة)',
    summary:
        'شاردنەوەی دەنگی میمی ساکین کاتێک پیتی (ب) دێتە دوای، لەگەڵ بەجێهێنانی غوننە لە لێوەکانەوە.',
    numberedRules: true,
    rules: [
      'پیتەکەی: تەنها یەک پیتی هەیە ئەویش پیتی (ب)یە.',
      'چۆنیەتی خوێندنەوە: میمی ساکین بە شاردراوەیی و بە سووکی لەگەڵ غوننەیەک دەخوێنرێتەوە، بەبێ ئەوەی لێوەکان بە توندی بنووسێنرێن (بێ فشارێکی زۆر).',
      'مەرج: تەنها لە نێوان دوو وشەدا ڕوو دەدات.',
    ],
    examples: [
      TajweedExample('تَرْمِيهِم بِحِجَارَةٍ', ref: '105:4'),
      TajweedExample('وَمَن يَعْتَصِم بِٱللَّهِ', ref: '3:101'),
      TajweedExample('هُم بَـٰرِزُونَ', ref: '40:16'),
    ],
  ),
  TajweedLesson(
    id: 10,
    titleKu: 'ئیزهاری شەفەوی',
    titleAr: 'الإظهار الشفوي (من أحكام الميم الساكنة)',
    summary:
        'ئاشکراکردنی دەنگی میمی ساکین کاتێک پیتێکی جیا لە (ب) و (م) دێتە دوای، بەبێ غوننەی زیادە.',
    numberedRules: true,
    rules: [
      'پیتەکانی: هەموو پیتەکانی عەرەبی جگە لە دوو پیت (م) و (ب).',
      'چۆنیەتی خوێندنەوە: میمی ساکین بە ڕوونی و بێ هیچ شاردنەوە یان غوننەیەکی زیادە دەخوێنرێتەوە.',
      'سەرنجی گرنگ: زۆرترین ئاگاداربوون پێویستە کاتێک میمی ساکین دەکەوێتە پێش پیتی (ف) یان (و)، نەوەک بە هەڵە ئیخفا بکرێت (چونکە مەخرەجیان نزیکە).',
    ],
    examples: [
      TajweedExample('أَمْ لَمْ تُنذِرْهُمْ',
          ref: '2:6', note: 'إظهار عند حرف اللام'),
      TajweedExample('عَلَيْهِمْ دَآئِرَةُ ٱلسَّوْءِ', ref: '48:6'),
      TajweedExample('تَمْتَرُونَ'),
    ],
  ),
  TajweedLesson(
    id: 11,
    titleKu: 'پلەکانی غوننە',
    titleAr: 'مَرَاتِبُ الْغُنَّةِ (أقسامها ودرجاتها)',
    summary:
        'جیاوازیی هێز و ماوەی دەرچوونی غوننە لە بارودۆخە جیاوازەکانی خوێندنەوەدا، کە دابەش دەبێت بۆ ٤ پلە.',
    numberedRules: true,
    rules: [
      'ئەکبەم / أكمل ما تكون (بەهێزترین): لە (إدغام بغنة) و (إخفاء حقيقي وشَفەوی)دا.',
      'الكاملة (تەواو): لە میم و نونی تشدیدداردا (مّ، نّ) و لە (إدغام متماثلين صغير).',
      'الناقصة (کەم): لە نونی ساکینی ئیزهار و میمی ساکینی ئیزهاری شەفەویدا.',
      'أنقص ما تكون (کەمترین): لە نونی جووڵاودا (مفتوحة، مضمومة، مكسورة).',
    ],
    examples: [
      TajweedExample('إِنَّ', note: 'غنة كاملة في النون المشددة'),
      TajweedExample('مَن يَعْمَلْ',
          ref: '99:7', note: 'غنة أكمل ما تكون في الإدغام'),
      TajweedExample('أَنْعَمْتَ', ref: '1:7', note: 'غنة ناقصة في نون الإظهار'),
    ],
  ),
  TajweedLesson(
    id: 12,
    titleKu: 'مەددی سروشتی (ئەسڵی)',
    titleAr: 'المد الأصلي (أو الطبيعي)',
    summary:
        'ئەو مەدەیەی کە پیتەکەی پێویستی بە هیچ هۆکارێکی وەک همز یان سکوون نییە، بەڵکو بە خودی پیتەکەی دەوەستێت.',
    numberedRules: true,
    rules: [
      'پیتەکانی مەد (حروف المد الثلاثة): ئالف (مەفتوح پێش خۆی)، واو (مەضمووم پێش خۆی)، و یاء (مەکسوور پێش خۆی) - کە کۆکراونەتەوە لە وشەی (نُوحِیهَا).',
      'ماوەکەی (مقدار المد): بە بڕی دوو حەرەکەت (حركتان) دەخوێنرێتەوە، نە کەمتر و نە زیاتر.',
      'ناوەکەی تری: پێی دەوترێت (مەددی اصلی) چونكە بنەمای هەموو مدوودێکی تری لەسەر بنیاد ناوه.',
    ],
    examples: [
      TajweedExample('قَالَ', note: 'مد بالالف'),
      TajweedExample('يَقُولُ', note: 'مد بالواو'),
      TajweedExample('قِيلَ', ref: '2:11', note: 'مد بالياء'),
      TajweedExample('ٱلرَّحْمَـٰنِ', ref: '1:3'),
    ],
  ),
  TajweedLesson(
    id: 13,
    titleKu: 'مەددی لاوەکی بە هۆی همزەوە',
    titleAr: 'المد الفرعي بسبب الهمز (المتصل، المنفصل، البدل)',
    summary:
        'ئەو درێژکردنەوەیەیە کە زیاتر لە مددی سروشتی دەخوێنرێتەوە بە هۆی هاتنی (همزە) لە دوای پیتی مەدەوە.',
    numberedRules: true,
    rules: [
      'المد المتصل (پەیوەست): پیتی مەد و همزە لە یەک وشەدا کۆببنەوە (وەک: جَاءَ)، حوکمی واجبە و ٤ بۆ ٥ حەرەکەت درێژ دەکرێتەوە.',
      'المد المنفصل (جیاواز): پیتی مەد لە کۆتایی وشەیەکدا بێت و همزە لە سەرەتای وشەی دووەمدا بێت (وەک: فِي أَنْفُسِكُمْ)، حوکمی جایزە (٢، ٤، یان ٥ حەرەکەت).',
      'مد البدل: همزە پێش پیتی مەد بکەوێت (وەک: آمَنُوا)، و بە بڕی دوو حەرەکەت (طبیعی) دەخوێنرێتەوە.',
    ],
    examples: [
      TajweedExample('سَوَآءٌ', ref: '2:6', note: 'مد متصل واجب'),
      TajweedExample('بِمَآ أُنزِلَ', ref: '2:4', note: 'مد منفصل جایز'),
      TajweedExample('ءَامَنُوا۟', ref: '2:14', note: 'مد بدل'),
    ],
  ),
  TajweedLesson(
    id: 14,
    titleKu: 'مەدی لازم',
    titleAr: 'المد اللازم',
    summary:
        'سکونێکی ڕەسەن (یان شەددە) دوای پیتی مەد دێت. واجبە و شەش حەرەکە درێژ دەکرێت.',
    rules: [
      'مەدی لازمی کەلیمی موسەقەل: شەددە لە وشەدا دوای پیتی مەد.',
      'مەدی لازمی کەلیمی موخەففەف: سکون لە وشەدا دوای پیتی مەد (کەمە، تەنها لە دوو شوێنی سوورەتی یونس).',
      'مەدی لازمی حەرفی: لە پیتە بڕاوەکانی سەرەتای سوورەتەکان، کاتێک پیتەکە سێ پیتی تێدایە و ناوەڕاستی مەدە.',
    ],
    examples: [
      TajweedExample('ٱلضَّآلِّينَ', ref: '1:7'),
      TajweedExample('ٱلْحَآقَّةُ', ref: '69:1'),
      TajweedExample('ءَآلْـَٔـٰنَ', ref: '10:51'),
      TajweedExample('الٓمٓ', ref: '2:1', note: 'لام: شەش حەرەکە'),
    ],
  ),
  TajweedLesson(
    id: 15,
    titleKu: 'مەدی عارض و لین',
    titleAr: 'المد العارض للسكون والليّن',
    summary:
        'کاتێک لە کۆتایی وشەیەک دەوەستیت، سکونی کاتی دروست دەبێت و مەدەکە درێژ دەکرێت.',
    rules: [
      'مەدی عارض للسکون: پیتی مەد پێش پیتی کۆتایی، لە کاتی وەستاندا دوو، چوار یان شەش حەرەکە.',
      'مەدی لین: واو یان یاءی ساکنی دوای فەتحە، لە کاتی وەستاندا دوو، چوار یان شەش حەرەکە.',
      'ئەگەر بەردەوام بیت و نەوەستیت ئەم مەدە نامێنێت.',
    ],
    examples: [
      TajweedExample('نَسْتَعِينُ', ref: '1:5', note: 'عارض لە کاتی وەستان'),
      TajweedExample('ٱلرَّحِيمِ', ref: '1:3', note: 'عارض'),
      TajweedExample('ٱلْبَيْتِ', ref: '106:3', note: 'لین'),
      TajweedExample('خَوْفٍ', ref: '106:4', note: 'لین'),
    ],
  ),
  TajweedLesson(
    id: 16,
    titleKu: 'قەڵقەلە (لەرزینەوەی دەنگ)',
    titleAr: 'القلقلة (تعريفها ومراتبها)',
    summary:
        'لەرینەوە یان ڕەنگدانەوەی دەنگی پیتەکە لە مەخرەجەکەی خۆیدا کاتێک ساکین دەبێت، تاوەکو بە ڕوونی ببیسترێت.',
    numberedRules: true,
    rules: [
      'پیتەکانی قەڵقەلە ٥ پیتن و کۆکراونەتەوە لە ڕستەی: (قُطْبُ جَدٍّ) یعنی (ق، ط، ب، ج، د).',
      'پلەکانی قەڵقەلە (مراتب القلقلة):\n• قەڵقەلەی کەیبەور / کچوکە (الصغرى): کاتێک پیتی قەڵقەلە لە ناوەڕاستی وشەدا دێت و ساکینە (وەک: يَطْمَعُونَ).\n• قەڵقەلەی گەورە / مەزن (الكبرى): کاتێک پیتی قەڵقەلە لە کۆتایی وشەدا دێت و بە هۆی وەستانەوە ساکین دەبێت (وەک: الْفَلَقِ، أَحَدٌ).',
    ],
    examples: [
      TajweedExample('قُلْ أَعُوذُ بِرَبِّ ٱلْفَلَقِ',
          ref: '113:1', note: 'قلقلة كبرى عند القاف'),
      TajweedExample('وَمَا تَدْرِى نَفْسٌ مَّاذَا تَكْسِبُ',
          ref: '31:34',
          note: 'قلقلة صغرى في الدال، وكبرى في الباء عند الوقف'),
      TajweedExample('لَمْ يَلِدْ وَلَمْ يُولَدْ', ref: '112:3'),
    ],
  ),
  TajweedLesson(
    id: 17,
    titleKu: 'قورس و تەنک',
    titleAr: 'التفخيم والترقيق',
    summary:
        'پیتەکان یان بە دەنگی پڕ و قورس (تفخيم) دەخوێندرێنەوە، یان بە دەنگی تەنک (ترقيق).',
    rules: [
      'حەوت پیتی هەمیشە قورس: خ ص ض غ ط ق ظ.',
      'ئەلیفی مەد حوکمی پیتی پێش خۆی وەردەگرێت: دوای پیتی قورس قورسە، دوای پیتی تەنک تەنکە.',
      'ئەو پیتانەی ڕێژەیی قورس یان تەنک دەبن: ر و لامی «الله».',
      'پیتی ئەلیفی هەمزەی وەسڵ و پیتی ئەلیفی قطع بەپێی دەنگی خۆیان دەخوێندرێنەوە.',
    ],
    examples: [
      TajweedExample('ٱلصِّرَٰطَ', ref: '1:6'),
      TajweedExample('ٱلْمَغْضُوبِ', ref: '1:7'),
      TajweedExample('ٱلضَّآلِّينَ', ref: '1:7', note: 'ئەلیف دوای ض قورسە'),
    ],
  ),
  TajweedLesson(
    id: 18,
    titleKu: 'حوکمی ڕاء',
    titleAr: 'أحكام الراء',
    summary: 'ڕاء بەپێی بزوێن و پیتی پێشی، قورس یان تەنک دەخوێندرێتەوە.',
    rules: [
      'قورس: ڕاءی بە فەتحە یان زەمە؛ ڕاءی ساکن دوای فەتحە یان زەمە؛ ڕاءی ساکن دوای کەسرەی عارض.',
      'قورس: ڕاءی ساکن دوای کەسرە، ئەگەر پیتی استعلاء بەدوایدا بێت و لە هەمان وشەدا بێت، وەک مِرْصَادًا.',
      'تەنک: ڕاءی بە کەسرە؛ ڕاءی ساکن دوای کەسرەی ڕەسەن، ئەگەر پیتی استعلاء بەدوایدا نەبێت.',
      'لە کاتی وەستان لەسەر ڕاء، ئەگەر یاءی ساکن یان کەسرە پێش بێت ڕاءەکە تەنکە.',
    ],
    examples: [
      TajweedExample('رَبِّ', note: 'قورس'),
      TajweedExample('مِرْصَادًا', ref: '78:21', note: 'قورس'),
      TajweedExample('فِرْعَوْنَ', note: 'تەنک'),
      TajweedExample('رِجَالٌ', note: 'تەنک'),
      TajweedExample('قَدِيرٌ', note: 'تەنک لە وەستان'),
    ],
  ),
  TajweedLesson(
    id: 19,
    titleKu: 'لامی «الله»',
    titleAr: 'لام لفظ الجلالة',
    summary: 'لامی ناوی گەورەی خوا بەپێی بزوێنی پیتی پێشی قورس یان تەنک دەخوێندرێتەوە.',
    rules: [
      'قورس: ئەگەر پیتی پێشی فەتحە یان زەمە بێت.',
      'تەنک: ئەگەر پیتی پێشی کەسرە بێت.',
      'ئەگەر لە سەرەتای وشەکان بێت (ٱللَّهُ) بە فەتحەوە قورسە.',
    ],
    examples: [
      TajweedExample('قَالَ ٱللَّهُ', ref: '3:55', note: 'قورس'),
      TajweedExample('رَسُولُ ٱللَّهِ', note: 'قورس'),
      TajweedExample('بِسْمِ ٱللَّهِ', ref: '1:1', note: 'تەنک'),
    ],
  ),
  TajweedLesson(
    id: 20,
    titleKu: 'حوکمەکانی لامی تەعریف (قەمری و شەمسی)',
    titleAr: 'أحكام لام التعريف (اللام الشمسية واللام القمرية)',
    summary:
        'حوکمی لامی (ال) پێش ناوەکان، کە دابەش دەبێت بۆ سەر دوو بەشی (قەمری) و (شەمسی).',
    numberedRules: true,
    rules: [
      'لامی قەمری (الإظهار القمري): لامەکە بە ڕوونی دەخوێنرێتەوە کاتێک دێتە پێش ١٤ پیتی قەمری (کۆکراونەتەوە لە ڕستەی: ابغ حجك وخف عقيمه). پیتی لام سکوونی لەسەرە.',
      'لامی شەمسی (الإدغام الشمسي): لامەکە لە پیتەکەی دوای خۆی دەمژرێت و تێکەڵ دەبێت (ئیدغام دەبێت) لەگەڵ ١٤ پیتی شەمسی (ئەو پیتانەی تری عەرەبی)، و پیتی دووەم بە تەشدیید دەخوێنرێتەوە.',
    ],
    examples: [
      TajweedExample('ٱلْقَمَرُ', note: 'لام قەمری - مظهرة'),
      TajweedExample('ٱلْبَيْتُ', note: 'لام قەمری - مظهرة'),
      TajweedExample('ٱلشَّمْسُ', note: 'لام شەمسی - مدغمة مع التشديد'),
      TajweedExample('ٱلرَّحْمَـٰنُ', note: 'لام شەمسی - مدغمة مع التشديد'),
    ],
  ),
  TajweedLesson(
    id: 21,
    titleKu: 'المثلان والمتقاربان والمتجانسان',
    titleAr: 'المثلان والمتقاربان والمتجانسان (علاقات الحروف)',
    summary:
        'ناسینی پەیوەندیی نێوان دوو پیت کاتێک لە ڕووی مەخرەج و سيفاتەوە لە یەک دەچن یان نزیکن، کە دابەش دەبێت بۆ سێ بەش.',
    numberedRules: true,
    rules: [
      'المثلان (دوو پیتی یەکسان): ئەو دوو پیتەی لە یەک مەخرەج و صیفاتدا سەدا سەد یەکسانن (وەک: ب + ب، م + م). حوکمیان زۆرجار ئیدغامە ئەگەر یەکەمیان ساکین بێت (متقن صغير).',
      'المتقاربان (دوو پیتی نزیک): ئەو دوو پیتەی لە مەخرەج یان صیفاتدا زۆر لە یەکەوە نزیکن (وەک: ق + ك، ل + ر).',
      'المتجانسان (دوو پیتی هاومەخرەج و جیاواز لە صیفات): ئەو دوو پیتەی لە یەک مەخرەجدان بەڵام صیفاتیان جیاوازە (وەک پیتەکانی: ت، د، ط - یان - ث، ذ، ظ - یان - ب، م).',
    ],
    examples: [
      TajweedExample('إِذ ذَّهَبَ', ref: '21:87', note: 'مثلان'),
      TajweedExample('قَد تَّبَيَّنَ', ref: '2:256', note: 'متجانسان'),
      TajweedExample('رَبِحَت تِّجَـٰرَتُهُمْ', ref: '2:16', note: 'مثلان'),
      TajweedExample('أَلَمْ نَخْلُقكُّم', ref: '77:20', note: 'متقاربان'),
    ],
  ),
  TajweedLesson(
    id: 22,
    titleKu: 'وەستان و دەستپێکردنەوە',
    titleAr: 'الوقف والابتداء',
    summary:
        'وەستان بۆ هەناسەدان لە شوێنێکدایە کە واتا تێک نەچێت، و دەستپێکردنەوە لە شوێنێکەوە کە واتای ڕاست بدات.',
    rules: [
      'وەستانی تەواو (تام): واتا و ڕستەکە تەواو بووە.',
      'وەستانی کافی: واتای ڕستەکە تەواو بووە بەڵام بە ڕستەی دواتر پەیوەستە.',
      'وەستانی باش (حەسەن): واتایەکی باش دەدات بەڵام دەستپێکردنەوە لێی باش نییە.',
      'وەستانی ناشیرین (قەبیح): واتا دەشێوێنێت، وەک وەستان لەسەر «لَا» بەتەنها.',
      'نیشانەکانی مصحف: م = وەستانی پێویست، لا = مەوەستە، ج = ڕێگەپێدراوە، قلى = وەستان باشترە، صلى = بەردەوامبوون باشترە.',
      'ئەگەر دوو نیشانەی ۛ لە دوو شوێنی نزیک بوون، لە یەکێکیان دەوەستیت نەک هەردووکیان.',
    ],
    examples: [
      TajweedExample('ذَٰلِكَ ٱلْكِتَـٰبُ لَا رَيْبَ ۛ فِيهِ ۛ هُدًى لِّلْمُتَّقِينَ',
          ref: '2:2', note: 'نیشانەی موعانەقە: لە یەکێکیان بوەستە'),
    ],
  ),
  TajweedLesson(
    id: 23,
    titleKu: 'هەمزەی وەسڵ و قطع',
    titleAr: 'همزة الوصل والقطع',
    summary:
        'هەمزەی وەسڵ لە سەرەتای خوێندنەوە دەخوێندرێتەوە و لە ناوەڕاستی خوێندنەوە دەکەوێت، هەمزەی قطع هەمیشە دەخوێندرێتەوە.',
    rules: [
      'هەمزەی وەسڵ لە ئامرازی «ال»، لە فرمانی فەرمان، لە ڕابردووی پێنج و شەش پیتی، و لە چەند ناوێکی دیاریکراو دێت.',
      'لە دەستپێکردندا، هەمزەی وەسڵ بە کەسرە دەخوێندرێتەوە، مەگەر پیتی سێیەمی فرمانەکە زەمە بێت کە بە زەمە دەخوێندرێتەوە، و لە «ال» بە فەتحە.',
      'هەمزەی قطع لە هەموو حاڵەتێکدا دەخوێندرێتەوە، وەک هەمزەی فرمانی «أَنزَلَ» و «أَنعَمْتَ».',
    ],
    examples: [
      TajweedExample('ٱهْدِنَا', ref: '1:6', note: 'وەسڵ، بە کەسرە دەست پێدەکەیت'),
      TajweedExample('ٱقْرَأْ', ref: '96:1', note: 'وەسڵ'),
      TajweedExample('ٱلْحَمْدُ', ref: '1:2', note: 'وەسڵ، بە فەتحە'),
      TajweedExample('أَنْعَمْتَ', ref: '1:7', note: 'قطع'),
    ],
  ),
  TajweedLesson(
    id: 24,
    titleKu: 'هەڵەکانی خوێندنەوە و ئاداب',
    titleAr: 'اللحن الجلي والخفي وآداب التلاوة',
    summary:
        'لەحن واتە هەڵە لە خوێندنەوەدا. دوو جۆرە: ئاشکرا (جلی) و شاراوە (خەفی).',
    rules: [
      'لەحنی جلی: گۆڕینی پیت یان بزوێن، بە شێوەیەک واتا دەگۆڕێت، وەک خوێندنەوەی ع وەک ء.',
      'لەحنی خەفی: هەڵەی وردتر، وەک نەبوونی غونە، کورتکردنەوەی مەد، یان قورسکردنی پیتی تەنک.',
      'ئاداب: بە دەنگی ئارام و ڕوون بخوێنە، بە تەرتیل و بێ پەلە، لە شوێنێکی پاک، و دەم بشۆ.',
      'خوێندنەوەی بە تەجوید لە مامۆستایەکی شارەزاوە وەردەگیرێت، و ئەم وانانە تەنها یارمەتیدەرن.',
    ],
    examples: [
      TajweedExample('ٱلْعَـٰلَمِينَ', ref: '1:2', note: 'ع نابێت وەک ء بخوێندرێتەوە'),
      TajweedExample('ٱلصِّرَٰطَ', ref: '1:6', note: 'ص نابێت وەک س بخوێندرێتەوە'),
    ],
  ),
  TajweedLesson(
    id: 25,
    titleKu: 'وانەی هۆژدەیەم: مەددی لاوەکی بە هۆی سکوونەوە',
    titleAr: 'المد الفرعي بسبب السكون (العارض، اللين، اللازم)',
    summary:
        'ئەو درێژکردنەوەیەیە کە بە هۆی هاتنی (سکوون)ەوە لە دوای پیتی مەد یان پیتی لینەوە دروست دەبێت.',
    numberedRules: true,
    rules: [
      'المد العارض للسكون: پیتی مەد دێت و لە دوایەوە پیتێک بە هۆی وەستان لەسەری ساکین دەبێت (وەک: ٱلْعَـٰلَمِينَ)، دەتوانرێت ٢، ٤، یان ٦ حەرەکەت درێژ بکرێتەوە.',
      'مد اللين: واو یان یای ساکینی مەفتوح لە پێشەوە، پیتەکەی دوای سکوونی عارەزی هەبێت لە کاتی وەستاندا (وەک: خَوْف، بَيْت).',
      'المد اللازم: پیتی مەد لە دوایەوە سکوونی ڕەسەنی هەبێت لە هەمان وشە یان پیتدا (وەک: ٱلْحَآقَّةُ، ٱلصَّآخَّةُ)، و بە بڕی ٦ حەرەکەت بە پێویست دەخوێنرێتەوە.',
    ],
    examples: [
      TajweedExample('ٱلرَّحِيمِ', ref: '1:3', note: 'عارض للسكون'),
      TajweedExample('خَوْفٍ', ref: '106:4', note: 'مد لين'),
      TajweedExample('ٱلضَّآلِّينَ', ref: '1:7', note: 'مد لازم کلمی مثقل'),
    ],
  ),
  TajweedLesson(
    id: 26,
    titleKu: 'وانەی نۆزدەیەم: ڕیزبەندی و هێزی مەدەکان',
    titleAr: 'مراتب المدود وأقواها (قاعدة أقوى السببين)',
    summary:
        'تێگەیشتن لە ڕیزبەندی هێزی مەدەکان کاتێک لە یەک ئایەت یان یەک وشەدا دوو جۆر مەد کۆدەبنەوە، بۆ ئەوەی بەهێزترینیان پەیڕەو بکرێت.',
    numberedRules: true,
    rules: [
      'ڕیزبەندی هێزی مەدەکان (لە بەهێزترینەوە بۆ لاوازترین):\n• اللازم (بەهێزترینیانە).\n• المتصل.\n• العارض للسكون.\n• المنفصل.\n• البدل (لاوازترینیانە).',
      'یاسای ئەقوای سەبەبەین (قاعدة أقوى السببين): ئەگەر دوو هۆکاری مەد لەسەر یەک پیتی مەد کۆبووەوە، تەنها مەدە بەهێزەکە جێبەجێ دەکرێت و لاوازەکە لەبەرچاو ناگیرێت.',
    ],
    examples: [
      TajweedExample('أُو۟لَـٰٓئِكَ',
          ref: '2:5', note: 'المد المتصل يقدم على مد البدل'),
      TajweedExample('ءَآمِّينَ ٱلْبَيْتَ ٱلْحَرَامَ',
          ref: '5:2',
          note: 'اجتماع المد اللازم ومد البدل - پەیڕەوکردنی اللازم'),
    ],
  ),
  TajweedLesson(
    id: 27,
    titleKu: 'وانەی بیستەم: وەستان و دەستپێکردنەوە',
    titleAr: 'الوقف والابتداء (أنواعه وأحكامه)',
    summary:
        'ناسینی شوێنەکانی وەستان لەسەر ئایەتەکان و چۆنیەتی دەستپێکردنەوە، بۆ پاراستنی مانا دروستەکەی قورئانی پیرۆز.',
    numberedRules: true,
    rules: [
      'الوقف التام (وەستانی تەواو): وەستان لەسەر بڕگەیەک کە لە ڕووی مانا و ڕێزمانەوە بە تەواوی سەربەخۆیە و هیچ پەیوەندییەکی بە دوای خۆیەوە نییە.',
      'الوقف الكافي (وەستانی بەس): وەستان لەسەر شوێنێک کە مانا تەواوە، بەڵام لە ڕووی بابەتەوە بەشێوەیەک پەیوەندی بە دوای خۆیەوە هەیە.',
      'الوقف الحسن (وەستانی باش): وەستان لەسەر شوێنێک کە مانا سەربەخۆیە بەڵام لە ڕووی ڕێزمانەوە بەندە بە دوای خۆیەوە (جائیزە وەستان لەسەری بەڵام دەستپێکردنەوە لە هەمان شوێن دروست نییە).',
      'الوقف القبيح (وەستانی ناشیرین): وەستان لەسەر شوێنێک کە مانا تێکدەدات یان ناتەواوی دەکات (دروست نییە مەگەر بە ناچاری وەک نەمانی هەناسە).',
    ],
    examples: [
      TajweedExample('وَأُو۟لَـٰٓئِكَ هُمُ ٱلْمُفْلِحُونَ',
          ref: '2:5', note: 'وقف تام'),
      TajweedExample('ٱلْحَمْدُ لِلَّهِ رَبِّ ٱلْعَـٰلَمِينَ',
          ref: '1:2', note: 'وقف كافٍ / حسن'),
    ],
  ),
  TajweedLesson(
    id: 28,
    titleKu: 'وانەی بیست و یەکەم: تاء و هاکانی وەستان (تاءات)',
    titleAr: 'التاءات (هاء التأنيث المربوطة والتاء المفتوحة)',
    summary:
        'ناسینی جیاوازیی نێوان تاء و هاء لە کۆتایی وشەکاندا و چۆنیەتی وەستان لەسەریان بە دروستی.',
    numberedRules: true,
    rules: [
      'هاء التأنيث (التاء المربوطة ة / ـة): لە کاتی وەستاندا لەسەری بە (هاء ساکین - هـ) دەخوێنرێتەوە (وەک: جَنَّةٌ -> جَنَّهْ)، بەڵام لە کاتی بەستنەوەدا (وصلاً) بە (تاء) دەخوێنرێتەوە.',
      'التاء المفتوحة (المبسوطة ت): لە کاتی وەستان و لە کاتی بەستنەوەشدا لە هەموو بارێکدا بە (تاء) دەخوێنرێتەوە (وەک: رَحْمَتُ -> رَحْمَتْ).',
    ],
    examples: [
      TajweedExample('رَحْمَتُ ٱللَّهِ',
          ref: '11:73', note: 'تاء مفتوحة تقرأ تاء دائماً'),
      TajweedExample('جَنَّةٍ عَرْضُهَا',
          ref: '57:21',
          note: 'تاء مربوطة تقرأ هاء عند الوقف وتاء عند الوصل'),
    ],
  ),
  TajweedLesson(
    id: 29,
    titleKu: 'وانەی بیست و دووەم: همزەی وەصل و قەطع',
    titleAr: 'همزة الوصل وهمزة القطع (أحكامها وكيفية البدء بها)',
    summary:
        'جیاوازی نێوان همزەی وەصل و قەطع، و یاسای دەستپێکردن بە همزەی وەصل لە سەرەتای وشەکاندا.',
    numberedRules: true,
    rules: [
      'همزة القطع: همزەیەکی ڕەسەنە کە لە هەموو بارێکدا (سەرەتا، ناوەڕاست، کۆتایی وشە) بە ڕوونی دەخوێنرێتەوە (وەک: أَحْمَدَ، أَنزَلَ).',
      'همزة الوصل: همزەیەکە لە سەرەتای وشەدا دەخوێنرێتەوە بۆ ئەوەی بڕگە ساکینەکە بخوێنرێت، بەڵام لە کاتی بەستنەوەی وشەکە بە پێش خۆیەوە دەسڕێتەوە و ناخوێنرێتەوە (وەک: ٱلْحَمْدُ).',
      'چۆنیەتی دەستپێکردن: ئەگەر دەستپێکردن بە همزەی وەصل بێت، لە ناوەکاندا بە کەسرە دەست پێ دەکرێت (جگە لە «ٱل» کە بە فەتحە دەست پێ دەکرێت)، و لە فعلەکاندا سەیری پیتی سێیەمی فعلەکە دەکرێت (ئەگەر ضمة بوو بە ضمة دەست پێ دەکرێت، ئەگەر مفتوحة یان مكسورة بوو بە کەسرە دەست پێ دەکرێت).',
    ],
    examples: [
      TajweedExample('ٱهْدِنَا ٱلصِّرَٰطَ',
          ref: '1:6', note: 'همزة وصل في بداية الكلمة'),
      TajweedExample('أَمْ حَسِبْتَ أَنَّ',
          ref: '18:9', note: 'همزة قطع ثابتة'),
    ],
  ),
];

/// Which Tajweed lessons the user has opened, kept on the phone (offline).
// ============================================================
//  Tajweed bridge: Recitation coach <-> Tajweed lessons
//
//  1. Strictness by coach level (kCoachLevels):
//       level 1  tajweed slips are ignored (only wrong words are corrected)
//       level 2  the core rules are checked (madd lazim / muttasil / badal /
//                asli, ghunna, idgham, ikhfa, iqlab, shadda, tanween); fine
//                details (qalqala, tafkhim, ra, lam of Allah, jaiz madds and
//                every "too long" remark: madd / ghunna) are not reported
//       level 3  everything the engine reports is checked: madd length,
//                ghunna timing, qalqala, ...
//  2. Context-aware: an engine report is dropped when the lessons say the
//     reading is allowed or the rule does not apply to this word:
//       - madd arid / lin (lesson 15): 2, 4 or 6 counts are all correct
//         (only a lost madd, "too short", is a mistake)
//       - tanween at the end of an ayah is dropped when stopping (lesson 22)
//       - idgham needs a noon / tanween at the END of a word and a letter of
//         (ي ر م ل و ن) at the start of the next word (lesson 6): never
//         inside one word (ٱلدُّنْيَا), never when stopping
//       - qalqala needs a sakin qalqala letter (lesson 16), shadda needs a
//         shadda, tanween needs a tanween
//  3. Lesson mapping: every reported error is mapped to the lesson that
//     teaches it (see _lessonOf), using the real ids of kTajweedLessons
//     1..24 (the extra lessons 25..29 repeat lessons 12..23).
//
//  The engine (package recite_quran) does the acoustic measuring. Its error
//  maps are classified by keywords (Arabic / English). Set kTajweedDebug to
//  see the raw errors in the log and extend the keyword lists if needed.
// ============================================================
const bool kTajweedDebug = true;

enum TajweedKind {
  maddAsli,
  maddMuttasil,
  maddMunfasil,
  maddBadal,
  maddLazim,
  maddArid,
  maddLin,
  maddOther,
  ghunna,
  izhar,
  idgham,
  iqlab,
  ikhfa,
  qalqala,
  shadda,
  tanween,
  tafkhim,
  raa,
  lamJalala,
  lamTarif,
  waqf,
  hamzaWasl,
  other,
}

enum TajweedDir { unknown, tooShort, tooLong }

class TajweedFinding {
  final TajweedKind kind;
  final TajweedDir dir;
  final int lessonId; // 0 = no lesson
  final bool flag; // true: the coach reports it
  final String why; // for the log
  const TajweedFinding(this.kind, this.dir, this.lessonId, this.flag, this.why);
}

class TajweedVerdict {
  final bool flag; // at least one finding must be reported
  final int lessonId; // lesson of the first reported finding (else first finding)
  final String detail; // Kurdish text for the coach message
  final List<TajweedFinding> findings;
  const TajweedVerdict(this.flag, this.lessonId, this.detail, this.findings);
  static const TajweedVerdict none =
      TajweedVerdict(false, 0, '', <TajweedFinding>[]);
}

class _TajCls {
  final TajweedKind kind;
  final TajweedDir dir;
  const _TajCls(this.kind, this.dir);
}

/// The lesson with this id (null when it does not exist).
TajweedLesson? tajweedLessonById(int id) {
  for (final l in kTajweedLessons) {
    if (l.id == id) return l;
  }
  return null;
}

class TajweedBridge {
  TajweedBridge._();

  /// kind -> lesson id of kTajweedLessons
  static const Map<TajweedKind, int> _lessonOf = <TajweedKind, int>{
    TajweedKind.maddAsli: 12,
    TajweedKind.maddMuttasil: 13,
    TajweedKind.maddMunfasil: 13,
    TajweedKind.maddBadal: 13,
    TajweedKind.maddLazim: 14,
    TajweedKind.maddArid: 15,
    TajweedKind.maddLin: 15,
    TajweedKind.maddOther: 12,
    TajweedKind.ghunna: 11,
    TajweedKind.izhar: 5,
    TajweedKind.idgham: 6,
    TajweedKind.iqlab: 7,
    TajweedKind.ikhfa: 8,
    TajweedKind.qalqala: 16,
    TajweedKind.shadda: 11, // refined by the word (_shaddaLesson)
    TajweedKind.tanween: 5, // refined by the next word (nunLesson)
    TajweedKind.tafkhim: 17,
    TajweedKind.raa: 18,
    TajweedKind.lamJalala: 19,
    TajweedKind.lamTarif: 20,
    TajweedKind.waqf: 22,
    TajweedKind.hamzaWasl: 23,
    TajweedKind.other: 24, // lahn: lesson of reading mistakes
  };

  static const Map<TajweedKind, String> _label = <TajweedKind, String>{
    TajweedKind.maddAsli: 'مەددی سروشتی',
    TajweedKind.maddMuttasil: 'مەددی متصل',
    TajweedKind.maddMunfasil: 'مەددی منفصل',
    TajweedKind.maddBadal: 'مەددی بەدەل',
    TajweedKind.maddLazim: 'مەددی لازم',
    TajweedKind.maddArid: 'مەددی عارض',
    TajweedKind.maddLin: 'مەددی لین',
    TajweedKind.maddOther: 'مەد',
    TajweedKind.ghunna: 'غوننە',
    TajweedKind.izhar: 'ئیزهار',
    TajweedKind.idgham: 'ئیدغام',
    TajweedKind.iqlab: 'ئیقلاب',
    TajweedKind.ikhfa: 'ئیخفا',
    TajweedKind.qalqala: 'قەڵقەلە',
    TajweedKind.shadda: 'شەدە',
    TajweedKind.tanween: 'تەنوین',
    TajweedKind.tafkhim: 'قورس و تەنک',
    TajweedKind.raa: 'حوکمی ڕاء',
    TajweedKind.lamJalala: 'لامی «الله»',
    TajweedKind.lamTarif: 'لامی تەعریف',
    TajweedKind.waqf: 'وەستان',
    TajweedKind.hamzaWasl: 'هەمزەی وەسڵ',
    TajweedKind.other: 'هەڵەی تەجوید',
  };

  /// Fine details: reported from level 3 on only.
  static const Set<TajweedKind> _fine = <TajweedKind>{
    TajweedKind.qalqala,
    TajweedKind.tafkhim,
    TajweedKind.raa,
    TajweedKind.lamJalala,
    TajweedKind.maddMunfasil,
    TajweedKind.maddArid,
    TajweedKind.maddLin,
    TajweedKind.waqf,
  };

  /// Strongest cause first (lesson 19: the stronger madd wins).
  static const List<TajweedKind> _rank = <TajweedKind>[
    TajweedKind.maddLazim,
    TajweedKind.maddMuttasil,
    TajweedKind.maddArid,
    TajweedKind.maddMunfasil,
    TajweedKind.maddBadal,
    TajweedKind.maddAsli,
  ];

  static const List<int> _idghamLetters = <int>[
    0x064A, 0x0631, 0x0645, 0x0644, 0x0648, 0x0646, // ي ر م ل و ن
  ];
  static const List<int> _izharLetters = <int>[
    0x0621, 0x0622, 0x0623, 0x0625, 0x0647, 0x0639, 0x062D, 0x063A, 0x062E,
  ];

  static final RegExp _maddRe = RegExp(
      r'madd|elongat|prolong|(?<![\u0621-\u064A])ال?مد(?![\u0621-\u064A])');
  static final RegExp _linRe = RegExp(r'\bleen\b|\blin\b');
  static final RegExp _shortRe = RegExp(
      r'\bshort|insufficient|missing|omitted|not\s+(?:enough|held|extended|prolonged)|قصير|قصر|ناقص|نقص|عدم|لم يمد');
  static final RegExp _longRe = RegExp(
      r'\blong|excess|too much|over[-\s]?(?:extend|prolong)|طويل|زائد|زياده|اطال|مبالغ');

  // ---------------------------------------------------------------
  //  1. engine error -> kind + direction
  // ---------------------------------------------------------------
  static String _blob(dynamic e) {
    final sb = StringBuffer();
    void add(dynamic v, int depth) {
      if (v == null || depth > 4) return;
      if (v is Map) {
        v.forEach((k, x) {
          if (x == true) {
            sb.write(' ');
            sb.write(k);
          }
          add(x, depth + 1);
        });
      } else if (v is Iterable) {
        for (final x in v) {
          add(x, depth + 1);
        }
      } else if (v is! bool) {
        sb.write(' ');
        sb.write(v);
      }
    }

    add(e, 0);
    if (e is! Map && e is! Iterable && e is! String) {
      try {
        add((e as dynamic).toJson(), 0);
      } catch (_) {}
    }
    return sb.toString().toLowerCase();
  }

  static _TajCls classify(dynamic err) {
    final t = _blob(err);
    final a = t
        .replaceAll(_arStrip, '')
        .replaceAll(RegExp('[أإآٱ]'), 'ا')
        .replaceAll('ى', 'ي')
        .replaceAll('ة', 'ه');
    bool has(List<String> keys) {
      for (final k in keys) {
        if (t.contains(k) || a.contains(k)) return true;
      }
      return false;
    }

    final sh = _shortRe.hasMatch(t) || _shortRe.hasMatch(a);
    final lg = _longRe.hasMatch(t) || _longRe.hasMatch(a);
    final dir = sh == lg
        ? TajweedDir.unknown
        : (sh ? TajweedDir.tooShort : TajweedDir.tooLong);

    TajweedKind k = TajweedKind.other;
    if (has(const ['qalqal', 'قلقل'])) {
      k = TajweedKind.qalqala;
    } else if (has(const ['lazim', 'لازم'])) {
      k = TajweedKind.maddLazim;
    } else if (has(const ['muttasil', 'متصل'])) {
      k = TajweedKind.maddMuttasil;
    } else if (has(const ['munfasil', 'منفصل'])) {
      k = TajweedKind.maddMunfasil;
    } else if (has(const ['badal', 'بدل'])) {
      k = TajweedKind.maddBadal;
    } else if (has(const ['arid', 'عارض'])) {
      k = TajweedKind.maddArid;
    } else if (_linRe.hasMatch(t) || a.contains('لين')) {
      k = TajweedKind.maddLin;
    } else if (has(const ['asli', 'natural', 'tabii', 'اصلي', 'طبيعي'])) {
      k = TajweedKind.maddAsli;
    } else if (_maddRe.hasMatch(t) || _maddRe.hasMatch(a)) {
      k = TajweedKind.maddOther;
    } else if (has(const ['iqlab', 'اقلاب'])) {
      k = TajweedKind.iqlab;
    } else if (has(const ['ikhfa', 'اخفاء'])) {
      k = TajweedKind.ikhfa;
    } else if (has(const ['idgham', 'ادغام'])) {
      k = TajweedKind.idgham;
    } else if (has(const ['izhar', 'اظهار'])) {
      k = TajweedKind.izhar;
    } else if (has(const ['ghunn', 'غنه', 'nasal'])) {
      k = TajweedKind.ghunna;
    } else if (has(const ['shadd', 'tashdid', 'شده', 'تشديد'])) {
      k = TajweedKind.shadda;
    } else if (has(const ['tanw', 'تنوين', 'تنوین'])) {
      k = TajweedKind.tanween;
    } else if (has(const ['tafkh', 'tarqiq', 'تفخيم', 'ترقيق'])) {
      k = TajweedKind.tafkhim;
    } else if (has(const ['shams', 'qamar', 'شمسي', 'قمري'])) {
      k = TajweedKind.lamTarif;
    } else if (has(const ['waqf', 'وقف'])) {
      k = TajweedKind.waqf;
    } else if (has(const ['wasl', 'وصل'])) {
      k = TajweedKind.hamzaWasl;
    }
    return _TajCls(k, dir);
  }

  static bool _isMadd(TajweedKind k) =>
      k == TajweedKind.maddAsli ||
      k == TajweedKind.maddMuttasil ||
      k == TajweedKind.maddMunfasil ||
      k == TajweedKind.maddBadal ||
      k == TajweedKind.maddLazim ||
      k == TajweedKind.maddArid ||
      k == TajweedKind.maddLin ||
      k == TajweedKind.maddOther;

  // ---------------------------------------------------------------
  //  2. what the vowelled text of the word says (the lessons' rules)
  // ---------------------------------------------------------------
  static bool _has(_Cluster c, int code) {
    var first = true;
    for (final r in c.text.runes) {
      if (first) {
        first = false;
        continue;
      }
      if (r == code) return true;
    }
    return false;
  }

  static int _raw(_Cluster c) => c.text.runes.first;
  static int _base(_Cluster c) => _foldRune(c.text.runes.first);
  static bool _isSakin(_Cluster c) => _has(c, 0x0652) || _has(c, 0x06E1);
  static bool _hasTanween(_Cluster c) =>
      _has(c, 0x064B) || _has(c, 0x064C) || _has(c, 0x064D);
  static bool _hasVowel(_Cluster c) =>
      _has(c, 0x064E) || _has(c, 0x064F) || _has(c, 0x0650);
  static bool _isHamza(int r) =>
      r == 0x0621 ||
      r == 0x0622 ||
      r == 0x0623 ||
      r == 0x0624 ||
      r == 0x0625 ||
      r == 0x0626;

  /// The cluster [i] is (or carries) a long-vowel letter: alef after fatha,
  /// waw after damma, ya after kasra, a letter with a dagger alef, or آ.
  static bool _carrier(List<_Cluster> cl, int i) {
    final c = cl[i];
    final raw = _raw(c);
    if (_has(c, 0x0670)) return true;
    if (raw == 0x0622) return true;
    if (i == 0 || raw == 0x0671) return false;
    if (_hasVowel(c) || _has(c, _kShadda) || _hasTanween(c)) return false;
    final f = _foldRune(raw);
    final prev = cl[i - 1];
    if (f == 0x0627) return _has(prev, 0x064E);
    if (f == 0x0648) return _has(prev, 0x064F);
    if (f == 0x064A) {
      return _has(prev, 0x0650) ||
          ((raw == 0x0649 || raw == 0x06CC) && _has(prev, 0x064E));
    }
    return false;
  }

  static int _firstRaw(String s) {
    for (final r in s.runes) {
      if (_arStrip.hasMatch(String.fromCharCode(r))) continue;
      return r;
    }
    return 0;
  }

  /// Which madd the word contains (the strongest one), from its own text.
  /// [next] = next word of the ayah ('' = none), [atWaqf] = last word of an ayah.
  static TajweedKind maddKind(List<_Cluster> cl, String next, bool atWaqf) {
    final found = <TajweedKind>{};
    for (var i = 0; i < cl.length; i++) {
      if (!_carrier(cl, i)) continue;
      if (_has(cl[i], 0x0621)) {
        // a hamza written right after the madd letter (جَآءَ): same word
        found.add(TajweedKind.maddMuttasil);
        continue;
      }
      if (i + 1 < cl.length) {
        final nx = cl[i + 1];
        if (_isHamza(_raw(nx))) {
          found.add(TajweedKind.maddMuttasil);
          continue;
        }
        if (_has(nx, _kShadda) || _isSakin(nx)) {
          found.add(TajweedKind.maddLazim);
          continue;
        }
        if (atWaqf && i + 2 == cl.length) {
          found.add(TajweedKind.maddArid);
          continue;
        }
      } else if (next.isNotEmpty && _isHamza(_firstRaw(next))) {
        found.add(TajweedKind.maddMunfasil);
        continue;
      }
      if ((i > 0 &&
              (_isHamza(_raw(cl[i - 1])) || _has(cl[i - 1], 0x0621))) ||
          (i == 0 && _raw(cl[i]) == 0x0622)) {
        found.add(TajweedKind.maddBadal);
        continue;
      }
      found.add(TajweedKind.maddAsli);
    }
    for (final k in _rank) {
      if (found.contains(k)) return k;
    }
    // disconnected letters at the start of a surah (الٓمٓ): madd lazim harfi
    if (cl.length <= 3 && cl.any((c) => _has(c, 0x0653))) {
      return TajweedKind.maddLazim;
    }
    if (atWaqf && cl.length >= 3) {
      final i = cl.length - 2;
      final f = _base(cl[i]);
      if ((f == 0x0648 || f == 0x064A) &&
          _isSakin(cl[i]) &&
          _has(cl[i - 1], 0x064E)) {
        return TajweedKind.maddLin;
      }
    }
    return TajweedKind.maddOther;
  }

  /// Lesson of the noon-sakin / tanween / meem-sakin rule that applies to
  /// this word (its end, then its inside); 0 = the text does not say.
  static int nunLesson(List<_Cluster> cl, String next) {
    if (cl.isEmpty) return 0;
    final last = cl.last;
    final lb = _base(last);
    final plain = !(_hasVowel(last) || _has(last, _kShadda) || _hasTanween(last));
    var tanween = _hasTanween(last);
    if (!tanween && cl.length >= 2 && lb == 0x0627 && _has(cl[cl.length - 2], 0x064B)) {
      tanween = true; // fathatan written on the letter before the alef
    }
    final nunSakin = lb == 0x0646 && plain;
    final mimSakin = lb == 0x0645 && plain;
    if (next.isNotEmpty && (tanween || nunSakin || mimSakin)) {
      final r = _firstRaw(next);
      if (r != 0 && r != 0x0671) {
        final f = _foldRune(r);
        if (mimSakin) {
          if (f == 0x0628) return 9; // ikhfa shafawi
          if (f == 0x0645) return 21; // two meems meet
          return 10; // izhar shafawi
        }
        if (_izharLetters.contains(r)) return 5;
        if (_idghamLetters.contains(f)) return 6;
        if (f == 0x0628) return 7;
        return 8;
      }
      return 0;
    }
    // inside the word: izhar / iqlab / ikhfa (never idgham)
    for (var i = 0; i + 1 < cl.length; i++) {
      final c = cl[i];
      if (_base(c) != 0x0646) continue;
      if (_hasVowel(c) || _has(c, _kShadda) || _hasTanween(c)) continue;
      final r = _raw(cl[i + 1]);
      final f = _foldRune(r);
      if (_izharLetters.contains(r) || _idghamLetters.contains(f)) return 5;
      if (f == 0x0628) return 7;
      return 8;
    }
    return 0;
  }

  /// Lesson for a doubled letter: after a madd letter 14, noon / meem 11,
  /// lam of al- before a sun letter 20, any other doubled letter 21.
  static int _shaddaLesson(List<_Cluster> cl) {
    for (var i = 1; i < cl.length; i++) {
      // a madd letter before the doubled letter wins (ٱلضَّآلِّينَ)
      if (_has(cl[i], _kShadda) && _carrier(cl, i - 1)) return 14;
    }
    for (var i = 0; i < cl.length; i++) {
      if (!_has(cl[i], _kShadda)) continue;
      final f = _base(cl[i]);
      if (f == 0x0646 || f == 0x0645) return 11;
      if (i >= 2 &&
          _base(cl[i - 1]) == 0x0644 &&
          _foldRune(_raw(cl[i - 2])) == 0x0627) {
        return 20;
      }
      return 21;
    }
    return 0;
  }

  static bool _hasQalqala(List<_Cluster> cl, bool atWaqf) {
    const q = <int>[0x0642, 0x0637, 0x0628, 0x062C, 0x062F]; // ق ط ب ج د
    for (var i = 0; i < cl.length; i++) {
      if (!q.contains(_base(cl[i]))) continue;
      if (_isSakin(cl[i]) || (atWaqf && i == cl.length - 1)) return true;
    }
    return false;
  }

  static bool _hasNunMim(List<_Cluster> cl) {
    for (final c in cl) {
      final b = _base(c);
      if (b == 0x0646 || b == 0x0645 || _hasTanween(c)) return true;
    }
    return false;
  }

  /// Does the engine's claim make sense for this word? (the lessons' rules)
  static bool _fits(
      TajweedKind k, List<_Cluster> cl, String next, bool atWaqf) {
    if (cl.isEmpty) return true;
    switch (k) {
      case TajweedKind.qalqala:
        return _hasQalqala(cl, atWaqf);
      case TajweedKind.shadda:
        return cl.any((c) => _has(c, _kShadda));
      case TajweedKind.tanween:
        return cl.any(_hasTanween) ||
            (cl.length >= 2 && _has(cl[cl.length - 2], 0x064B));
      case TajweedKind.ghunna:
      case TajweedKind.izhar:
      case TajweedKind.ikhfa:
        return _hasNunMim(cl);
      case TajweedKind.idgham:
        {
          if (next.isEmpty) return false; // stopping: nothing to merge with
          final l = nunLesson(cl, next);
          return l == 6 || (l == 0 && _hasNunMim(cl));
        }
      case TajweedKind.iqlab:
        {
          if (next.isEmpty) return false;
          final l = nunLesson(cl, next);
          return l == 7 || (l == 0 && _hasNunMim(cl));
        }
      default:
        return true;
    }
  }

  /// Is the reading allowed by the lessons although the engine complains?
  static bool _permissible(TajweedKind k, TajweedDir d, bool atWaqf) {
    switch (k) {
      case TajweedKind.maddArid:
      case TajweedKind.maddLin:
        return d != TajweedDir.tooShort; // 2, 4 or 6 counts are all correct
      case TajweedKind.tanween:
        return atWaqf; // the tanween is dropped when stopping
      default:
        return false;
    }
  }

  static int _lessonFor(TajweedKind k, List<_Cluster> cl, String next) {
    switch (k) {
      case TajweedKind.tanween:
        {
          final l = nunLesson(cl, next);
          return l != 0 ? l : 5;
        }
      case TajweedKind.shadda:
        {
          final l = _shaddaLesson(cl);
          return l != 0 ? l : 11;
        }
      case TajweedKind.idgham:
      case TajweedKind.ikhfa:
      case TajweedKind.izhar:
      case TajweedKind.iqlab:
        {
          final l = nunLesson(cl, next);
          return l != 0 ? l : (_lessonOf[k] ?? 0);
        }
      default:
        return _lessonOf[k] ?? 0;
    }
  }

  // ---------------------------------------------------------------
  //  3. the verdict of the coach
  // ---------------------------------------------------------------
  /// [errs] = tajweedErrors of the engine for [word]. [level] = settings.coachLevel.
  static TajweedVerdict judge(List<dynamic>? errs,
      {required String word,
      String next = '',
      bool atWaqf = false,
      required int level}) {
    if (errs == null || errs.isEmpty) return TajweedVerdict.none;
    final cl = word.isEmpty ? <_Cluster>[] : _clustersCached(word);
    final out = <TajweedFinding>[];
    final seen = <String>{};
    for (final e in errs) {
      if (kTajweedDebug) debugPrint('[tajweed] engine error: $e');
      final c = classify(e);
      var kind = c.kind;
      // The word's own text decides WHICH madd it is (except arid / lin,
      // which depend on a stop the engine heard).
      if (_isMadd(kind) &&
          kind != TajweedKind.maddArid &&
          kind != TajweedKind.maddLin &&
          cl.isNotEmpty) {
        final tk = maddKind(cl, next, atWaqf);
        if (tk != TajweedKind.maddOther) kind = tk;
      }
      if (!seen.add('${kind.index}_${c.dir.index}')) continue;
      final lesson = _lessonFor(kind, cl, next);
      var flag = true;
      var why = 'reported by the engine';
      if (level <= 1) {
        flag = false;
        why = 'level 1: tajweed slips are not corrected';
      } else if (!_fits(kind, cl, next, atWaqf)) {
        flag = false;
        why = 'the rule does not apply to this word (lesson $lesson)';
      } else if (_permissible(kind, c.dir, atWaqf)) {
        flag = false;
        why = 'allowed by lesson $lesson';
      } else if (level == 2 &&
          (_fine.contains(kind) || c.dir == TajweedDir.tooLong)) {
        flag = false;
        why = 'fine detail: reported from level 3';
      }
      if (kTajweedDebug) {
        debugPrint(
            '[tajweed]   -> ${kind.name} ${c.dir.name} lesson $lesson flag=$flag ($why)');
      }
      out.add(TajweedFinding(kind, c.dir, lesson, flag, why));
    }
    if (out.isEmpty) return TajweedVerdict.none;
    final flagged = out.where((f) => f.flag).toList();
    final first = flagged.isNotEmpty ? flagged.first : out.first;
    var detail = '';
    if (flagged.isNotEmpty) {
      final parts = <String>[];
      for (final f in flagged.take(2)) {
        final d = f.dir == TajweedDir.tooShort
            ? ' (کورتە)'
            : (f.dir == TajweedDir.tooLong ? ' (زۆر درێژە)' : '');
        parts.add('${_label[f.kind] ?? 'هەڵەی تەجوید'}$d');
      }
      detail = parts.join(' • ');
      if (first.lessonId != 0) detail = '$detail • وانەی ${first.lessonId}';
    }
    return TajweedVerdict(flagged.isNotEmpty, first.lessonId, detail, out);
  }

  /// Lesson for the exact glyphs the coach marked red in a word (a wrong
  /// word the engine gave no tajweed error for): madd sign, shadda, tanween,
  /// a vowel (lahn) or a letter (makhraj). 0 = none.
  static int lessonForGlyphs(
      Iterable<int> faults, String word, String next, bool atWaqf) {
    if (word.isEmpty) return 0;
    final cl = _clustersCached(word);
    var madd = false, shad = false, tan = false, vow = false, letter = false;
    for (final key in faults) {
      final code = key & 0xFFFF;
      final pos = key >> 16;
      if (code == _kShadda) {
        shad = true;
      } else if (_isTanweenRune(code)) {
        tan = true;
      } else if (code == 0x0653 || code == 0x0670) {
        madd = true;
      } else if (_isVowelRune(code)) {
        vow = true;
      } else if (code == 0) {
        if (pos >= 0 && pos < cl.length && _carrier(cl, pos)) {
          madd = true;
        } else {
          letter = true;
        }
      }
    }
    if (madd) return _lessonOf[maddKind(cl, next, atWaqf)] ?? 12;
    if (shad) {
      final l = _shaddaLesson(cl);
      return l != 0 ? l : 11;
    }
    if (tan) {
      final l = nunLesson(cl, next);
      return l != 0 ? l : 5;
    }
    if (vow) return 24;
    if (letter) return 2;
    return 0;
  }
}

class TajweedProgress extends ChangeNotifier {
  final Set<int> read = <int>{};
  bool _loaded = false;

  Future<void> ensureLoaded() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final p = await SharedPreferences.getInstance();
      read
        ..clear()
        ..addAll((p.getStringList('tajRead') ?? const <String>[])
            .map(int.tryParse)
            .whereType<int>());
      notifyListeners();
    } catch (_) {}
  }

  bool isRead(int id) => read.contains(id);

  Future<void> markRead(int id) async {
    if (!read.add(id)) return;
    notifyListeners();
    try {
      final p = await SharedPreferences.getInstance();
      await p.setStringList('tajRead', read.map((e) => '$e').toList());
    } catch (_) {}
  }

  Future<void> reset() async {
    read.clear();
    notifyListeners();
    try {
      final p = await SharedPreferences.getInstance();
      await p.remove('tajRead');
    } catch (_) {}
  }
}

final TajweedProgress tajProgress = TajweedProgress();

class TajweedLessonsScreen extends StatefulWidget {
  /// Opens the screen at this lesson (expanded and marked as read), e.g. the
  /// lesson the Recitation coach points to. 0 = the normal list.
  final int initialLessonId;
  const TajweedLessonsScreen({super.key, this.initialLessonId = 0});

  @override
  State<TajweedLessonsScreen> createState() => _TajweedLessonsScreenState();
}

class _TajweedLessonsScreenState extends State<TajweedLessonsScreen> {
  @override
  void initState() {
    super.initState();
    tajProgress.ensureLoaded().then((_) {
      if (widget.initialLessonId != 0) {
        tajProgress.markRead(widget.initialLessonId);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final startAt = kTajweedLessons
        .indexWhere((l) => l.id == widget.initialLessonId);
    return ListenableBuilder(
      listenable: tajProgress,
      builder: (context, _) {
        final done = tajProgress.read.length;
        final total = kTajweedLessons.length;
        return Scaffold(
          appBar: AppBar(
            title: const Text('تەجوید و فێرکردن',
                style: TextStyle(fontWeight: FontWeight.bold)),
            actions: [
              if (done > 0)
                IconButton(
                  tooltip: 'سفرکردنەوەی پێشکەوتن',
                  icon: const Icon(Icons.restart_alt),
                  onPressed: () => tajProgress.reset(),
                ),
            ],
          ),
          body: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 820),
              child: ScrollablePositionedList.builder(
                initialScrollIndex: startAt >= 0 ? startAt + 2 : 0,
                padding: const EdgeInsets.fromLTRB(14, 14, 14, 28),
                itemCount: total + 2,
                itemBuilder: (context, i) {
                  if (i == 0) return _TajProgressCard(done: done, total: total);
                  if (i == 1) return const _TajQuizBanner();
                  final lesson = kTajweedLessons[i - 2];
                  return _TajLessonCard(
                    lesson: lesson,
                    isRead: tajProgress.isRead(lesson.id),
                    initiallyExpanded: lesson.id == widget.initialLessonId,
                  );
                },
              ),
            ),
          ),
        );
      },
    );
  }
}

class _TajProgressCard extends StatelessWidget {
  final int done;
  final int total;
  const _TajProgressCard({required this.done, required this.total});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: _cardColor(context),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: _lineColor(context)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.school, color: _green),
              const SizedBox(width: 8),
              Expanded(
                child: Text('پێشکەوتنی تۆ',
                    style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                        color: _inkColor(context))),
              ),
              Text('$done / $total',
                  style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.bold,
                      color: _mutedColor(context))),
            ],
          ),
          const SizedBox(height: 10),
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: LinearProgressIndicator(
              value: total == 0 ? 0 : done / total,
              minHeight: 8,
              color: _green,
              backgroundColor: _lineColor(context),
            ),
          ),
          const SizedBox(height: 8),
          Text('هەر وانەیەک کە بیکەیتەوە وەک خوێندراو دیاری دەکرێت. هەموو وانەکان بێ ئینتەرنێت کار دەکەن.',
              style: TextStyle(
                  fontSize: 12.5, height: 1.6, color: _mutedColor(context))),
        ],
      ),
    );
  }
}

class _TajQuizBanner extends StatelessWidget {
  const _TajQuizBanner();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Material(
        color: const Color(0xFFB5552B),
        borderRadius: BorderRadius.circular(16),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const TajweedQuizPage())),
          child: const Padding(
            padding: EdgeInsets.all(16),
            child: Row(
              children: [
                Icon(Icons.quiz, color: Colors.white, size: 40),
                SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('تاقیکردنەوە',
                          style: TextStyle(
                              color: Colors.white,
                              fontSize: 19,
                              fontWeight: FontWeight.bold)),
                      SizedBox(height: 2),
                      Text('٨ پرسیار لەسەر حوکمەکانی تەجوید',
                          style: TextStyle(color: Colors.white70, fontSize: 13)),
                    ],
                  ),
                ),
                Icon(Icons.chevron_left, color: Colors.white),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _TajLessonCard extends StatelessWidget {
  final TajweedLesson lesson;
  final bool isRead;
  final bool initiallyExpanded;
  const _TajLessonCard(
      {required this.lesson,
      this.isRead = false,
      this.initiallyExpanded = false});

  @override
  Widget build(BuildContext context) {
    final ink = _inkColor(context);
    final muted = _mutedColor(context);
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      elevation: 0,
      color: _cardColor(context),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: _lineColor(context)),
      ),
      clipBehavior: Clip.antiAlias,
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          key: PageStorageKey<int>(lesson.id),
          initiallyExpanded: initiallyExpanded,
          onExpansionChanged: (open) {
            if (open) tajProgress.markRead(lesson.id);
          },
          leading: CircleAvatar(
            backgroundColor: isRead ? _green : _green.withAlpha(30),
            child: isRead
                ? const Icon(Icons.check, color: Colors.white, size: 20)
                : Text('${lesson.id}',
                    style: const TextStyle(
                        color: _green, fontWeight: FontWeight.bold)),
          ),
          title: Text('وانەی ${lesson.id}: ${lesson.titleKu}',
              style: TextStyle(
                  fontSize: 17, fontWeight: FontWeight.bold, color: ink)),
          subtitle: Text(lesson.titleAr,
              style: TextStyle(
                  fontSize: 15, color: muted, fontFamilyFallback: _arFonts)),
          childrenPadding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
          expandedCrossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(lesson.summary,
                style: TextStyle(fontSize: 15, height: 1.8, color: ink)),
            const SizedBox(height: 10),
            for (final r in lesson.rules)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (lesson.numberedRules)
                      Container(
                        width: 24,
                        height: 24,
                        margin: const EdgeInsets.only(top: 4, left: 8),
                        alignment: Alignment.center,
                        decoration: const BoxDecoration(
                            color: _gold, shape: BoxShape.circle),
                        child: Text('${lesson.rules.indexOf(r) + 1}',
                            style: const TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.bold,
                                color: Colors.white)),
                      )
                    else
                      const Padding(
                        padding: EdgeInsets.only(top: 8, left: 8),
                        child: Icon(Icons.circle, size: 7, color: _gold),
                      ),
                    Expanded(
                      child: Text(r,
                          style: TextStyle(
                              fontSize: 14.5, height: 1.75, color: ink)),
                    ),
                  ],
                ),
              ),
            if (lesson.examples.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text('نموونە:',
                  style: TextStyle(
                      fontSize: 15, fontWeight: FontWeight.bold, color: ink)),
              for (final e in lesson.examples)
                Container(
                  width: double.infinity,
                  margin: const EdgeInsets.only(top: 8),
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: _green.withAlpha(16),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Directionality(
                        textDirection: TextDirection.rtl,
                        child: SizedBox(
                          width: double.infinity,
                          child: Text(e.text,
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                  fontSize: 26,
                                  height: 2.0,
                                  color: ink,
                                  fontFamily: _uthmaniFont,
                                  fontFamilyFallback: _tajQuranFonts)),
                        ),
                      ),
                      if (e.ref.isNotEmpty || e.note.isNotEmpty)
                        Text(
                          [
                            if (e.ref.isNotEmpty) '(${e.ref})',
                            if (e.note.isNotEmpty) e.note,
                          ].join('  •  '),
                          textAlign: TextAlign.center,
                          style: TextStyle(fontSize: 12.5, color: muted),
                        ),
                    ],
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }
}

class _TajQ {
  final String phrase;
  final String answer;
  const _TajQ(this.phrase, this.answer);
}

const List<_TajQ> _kTajQuiz = [
  _TajQ('مِنْ قَبْلُ', 'إخفاء'),
  _TajQ('مِنْ هَادٍ', 'إظهار'),
  _TajQ('مِنْ بَعْدِ', 'إقلاب'),
  _TajQ('مَنْ يَقُولُ', 'إدغام'),
  _TajQ('جَاءَ', 'مد متصل'),
  _TajQ('الضَّالِّينَ', 'مد لازم'),
  _TajQ('يَقْطَعُونَ', 'قلقلة'),
  _TajQ('إِنَّ', 'غنة'),
];

const List<String> _kTajChoices = [
  'إظهار', 'إدغام', 'إقلاب', 'إخفاء', 'مد متصل', 'مد لازم', 'قلقلة', 'غنة',
];

class TajweedQuizPage extends StatefulWidget {
  const TajweedQuizPage({super.key});

  @override
  State<TajweedQuizPage> createState() => _TajweedQuizPageState();
}

class _TajweedQuizPageState extends State<TajweedQuizPage> {
  int _i = 0;
  int _score = 0;
  String? _picked;
  late List<List<String>> _options;

  @override
  void initState() {
    super.initState();
    _shuffle();
  }

  void _shuffle() {
    final rnd = math.Random();
    _options = [
      for (final q in _kTajQuiz)
        ([
          q.answer,
          ...(_kTajChoices.where((c) => c != q.answer).toList()..shuffle(rnd))
              .take(3),
        ]..shuffle(rnd)),
    ];
    _i = 0;
    _score = 0;
    _picked = null;
  }

  void _pick(String v) {
    if (_picked != null) return;
    setState(() {
      _picked = v;
      if (v == _kTajQuiz[_i].answer) _score++;
    });
  }

  @override
  Widget build(BuildContext context) {
    final done = _i >= _kTajQuiz.length;
    return Scaffold(
      appBar: AppBar(
        title: const Text('تاقیکردنەوەی تەجوید',
            style: TextStyle(fontWeight: FontWeight.bold)),
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 600),
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: done ? _result(context) : _question(context),
          ),
        ),
      ),
    );
  }

  Widget _result(BuildContext context) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        const Icon(Icons.emoji_events, size: 72, color: _gold),
        const SizedBox(height: 12),
        Text('$_score / ${_kTajQuiz.length}',
            style: TextStyle(
                fontSize: 36,
                fontWeight: FontWeight.bold,
                color: _inkColor(context))),
        const SizedBox(height: 6),
        Text(
          _score == _kTajQuiz.length
              ? 'ماشاءالله، هەموو وەڵامەکانت ڕاستن'
              : 'باشە، وانەکان دووبارە بخوێنەرەوە و هەوڵبدەرەوە',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 15, color: _mutedColor(context)),
        ),
        const SizedBox(height: 20),
        FilledButton.icon(
          onPressed: () => setState(_shuffle),
          icon: const Icon(Icons.refresh),
          label: const Text('دووبارە'),
        ),
      ],
    );
  }

  Widget _question(BuildContext context) {
    final q = _kTajQuiz[_i];
    final opts = _options[_i];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        LinearProgressIndicator(value: (_i + 1) / _kTajQuiz.length),
        const SizedBox(height: 8),
        Text('پرسیاری ${_i + 1} لە ${_kTajQuiz.length}',
            textAlign: TextAlign.center,
            style: TextStyle(color: _mutedColor(context))),
        const SizedBox(height: 18),
        Text('ئەم نموونەیە کام حوکمی تجویدە؟',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 16, color: _inkColor(context))),
        const SizedBox(height: 14),
        Container(
          padding: const EdgeInsets.symmetric(vertical: 22),
          decoration: BoxDecoration(
            color: _cardColor(context),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: _lineColor(context)),
          ),
          child: Text(q.phrase,
              textAlign: TextAlign.center,
              style: TextStyle(
                  fontSize: 32,
                  color: _inkColor(context),
                  fontFamilyFallback: _arFonts)),
        ),
        const SizedBox(height: 16),
        for (final o in opts)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: OutlinedButton(
              style: OutlinedButton.styleFrom(
                minimumSize: const Size.fromHeight(50),
                backgroundColor: _picked == null
                    ? null
                    : o == q.answer
                        ? const Color(0x331E7A3E)
                        : o == _picked
                            ? const Color(0x33C0392B)
                            : null,
              ),
              onPressed: () => _pick(o),
              child: Text(o,
                  style: TextStyle(
                      fontSize: 19,
                      color: _inkColor(context),
                      fontFamilyFallback: _arFonts)),
            ),
          ),
        const Spacer(),
        if (_picked != null)
          FilledButton(
            onPressed: () => setState(() {
              _i++;
              _picked = null;
            }),
            child: Text(_i + 1 == _kTajQuiz.length ? 'ئەنجام' : 'دواتر'),
          ),
      ],
    );
  }
}

/// Top banner: the city photo (assets/banner.jpg) with the title on top.
/// The box uses the photo's own ratio (1392x748), so nothing is cropped.
class _DashBanner extends StatelessWidget {
  const _DashBanner();

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(20),
      child: AspectRatio(
        aspectRatio: 1392 / 748,
        child: Stack(
          fit: StackFit.expand,
          children: [
            Image.asset(
              'assets/banner.jpg',
              fit: BoxFit.cover, // ratio is identical, so no part is cut
              filterQuality: FilterQuality.medium,
              errorBuilder: (_, __, ___) => const DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [Color(0xFF17394F), Color(0xFF1E7A3E)],
                  ),
                ),
              ),
            ),
            // soft dark layer at the bottom so the text stays readable
            const DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Color(0x00000000), Color(0x22000000), Color(0xB3000000)],
                  stops: [0.0, 0.45, 1.0],
                ),
              ),
            ),
            const Positioned.fill(
              child: Padding(
                padding: EdgeInsets.fromLTRB(22, 10, 22, 14),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.end,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'قورئانی پیرۆز',
                      style: TextStyle(
                        fontSize: 38,
                        height: 1.4,
                        fontWeight: FontWeight.bold,
                        color: Color(0xFFF0C14B),
                        fontFamilyFallback: _arFonts,
                        shadows: [Shadow(color: Color(0xCC000000), blurRadius: 8)],
                      ),
                    ),
                    SizedBox(height: 2),
                    Text(
                      'بِسْمِ ٱللَّهِ ٱلرَّحْمَٰنِ ٱلرَّحِيمِ',
                      style: TextStyle(
                        fontSize: 18,
                        color: Colors.white,
                        fontFamilyFallback: _arFonts,
                        shadows: [Shadow(color: Color(0xCC000000), blurRadius: 6)],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// One square tile: big icon on top, name below (like the reference design).
class _DashTile extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  const _DashTile({
    required this.icon,
    required this.color,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: _isDark(context) ? _cardColor(context) : Colors.white,
      elevation: 2,
      shadowColor: Colors.black38,
      borderRadius: BorderRadius.circular(14),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                width: 68,
                height: 68,
                decoration: BoxDecoration(
                  color: color.withAlpha(28),
                  shape: BoxShape.circle,
                ),
                child: Icon(icon, size: 38, color: color),
              ),
              const SizedBox(height: 8),
              Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 16.5,
                  fontWeight: FontWeight.bold,
                  color: _inkColor(context),
                ),
              ),
              const SizedBox(height: 2),
              Text(
                subtitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 12, color: _mutedColor(context)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------- shared small widgets for the new pages ----------
class _RadioTile extends StatelessWidget {
  final String label;
  final String? sub;
  final bool on;
  final VoidCallback onTap;
  const _RadioTile({
    required this.label,
    required this.on,
    required this.onTap,
    this.sub,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Material(
        color: _cardColor(context),
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: BorderSide(color: on ? _gold : _lineColor(context)),
        ),
        child: ListTile(
          onTap: onTap,
          leading: Icon(
            on ? Icons.radio_button_checked : Icons.radio_button_off,
            color: _gold,
          ),
          title: Text(label, style: TextStyle(fontSize: 16, color: _inkColor(context))),
          subtitle: sub == null
              ? null
              : Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    sub!,
                    style: TextStyle(fontSize: 12.5, height: 1.6, color: _mutedColor(context)),
                  ),
                ),
        ),
      ),
    );
  }
}

Widget _sectionHead(String t) => Padding(
      padding: const EdgeInsets.fromLTRB(4, 22, 4, 6),
      child: Text(
        t,
        style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold, color: _gold),
      ),
    );

Future<int?> _pickSurah(BuildContext context) {
  return showModalBottomSheet<int>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (ctx) => SizedBox(
      height: MediaQuery.of(ctx).size.height * 0.7,
      child: ListView.builder(
        itemCount: kSurahs.length,
        itemBuilder: (ctx, i) {
          final s = kSurahs[i];
          return ListTile(
            leading: _Badge(s.n),
            title: Text(
              s.ar,
              style: const TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.bold,
                fontFamilyFallback: _arFonts,
              ),
            ),
            subtitle: Text(s.en, textDirection: TextDirection.ltr),
            onTap: () => Navigator.of(ctx).pop(s.n),
          );
        },
      ),
    ),
  );
}

// ============================================================
//  2) Microphone & levels  (guide + difficulty + start the teacher)
// ============================================================
class MicLevelsPage extends StatefulWidget {
  const MicLevelsPage({super.key});

  @override
  State<MicLevelsPage> createState() => _MicLevelsPageState();
}

class _MicLevelsPageState extends State<MicLevelsPage> {
  late int _surah;

  @override
  void initState() {
    super.initState();
    if (settings.coachSurah >= 1 && settings.coachSurah <= 114) {
      _surah = settings.coachSurah;
    } else if (settings.lastSurah >= 1 && settings.lastSurah <= 114) {
      _surah = settings.lastSurah;
    } else {
      _surah = 1;
    }
  }

  Future<void> _choose() async {
    final n = await _pickSurah(context);
    if (n != null && mounted) setState(() => _surah = n);
  }

  // Opens the surah and switches the smart teacher (RecitationCoach) on.
  void _start() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => SurahPage(number: _surah, autoCoach: true),
      ),
    );
  }

  Widget _feature(BuildContext context, IconData icon, String title, String text) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: _cardColor(context),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: _lineColor(context)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: _gold.withAlpha(40),
                shape: BoxShape.circle,
              ),
              child: Icon(icon, color: _gold, size: 22),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      fontSize: 15.5,
                      fontWeight: FontWeight.bold,
                      color: _inkColor(context),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    text,
                    style: TextStyle(fontSize: 13, height: 1.7, color: _mutedColor(context)),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: settings,
      builder: (context, _) {
        final info = kSurahs[_surah - 1];
        return Scaffold(
          appBar: AppBar(
            title: const Text('مایک و لیڤڵەکان',
                style: TextStyle(fontWeight: FontWeight.bold)),
          ),
          bottomNavigationBar: Material(
            color: _cardColor(context),
            elevation: 8,
            child: SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
                child: Row(
                  children: [
                    OutlinedButton.icon(
                      onPressed: _choose,
                      icon: const Icon(Icons.menu_book, size: 18),
                      label: Text(
                        info.ar,
                        style: const TextStyle(fontSize: 17, fontFamilyFallback: _arFonts),
                      ),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: _gold,
                        side: const BorderSide(color: _gold),
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: _start,
                        icon: const Icon(Icons.mic),
                        label: const Text('دەستپێکردنی مامۆستا',
                            style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                        style: FilledButton.styleFrom(
                          backgroundColor: _green,
                          padding: const EdgeInsets.symmetric(vertical: 14),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          body: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 820),
              child: ListView(
                padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
                children: [
                  Container(
                    padding: const EdgeInsets.all(18),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(20),
                      gradient: const LinearGradient(
                        begin: Alignment.topRight,
                        end: Alignment.bottomLeft,
                        colors: [Color(0xFFC48A0E), Color(0xFF9A6A05)],
                      ),
                    ),
                    child: Row(
                      children: [
                        Container(
                          width: 56,
                          height: 56,
                          decoration: const BoxDecoration(
                            color: Color(0x33FFFFFF),
                            shape: BoxShape.circle,
                          ),
                          child: const Icon(Icons.mic, color: Colors.white, size: 30),
                        ),
                        const SizedBox(width: 14),
                        const Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'مامۆستای زیرەکی قورئان',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 19,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              SizedBox(height: 4),
                              Text(
                                'بخوێنە، مامۆستا گوێت لێ دەگرێت و کاتێک هەڵە بکەیت یەکسەر ڕاستت دەکاتەوە.',
                                style: TextStyle(
                                  color: Color(0xE6FFFFFF),
                                  fontSize: 13,
                                  height: 1.6,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  _sectionHead('چۆن کار دەکات؟'),
                  _feature(
                    context,
                    Icons.shuffle,
                    'خوێندنەوەی ئازاد',
                    'لە هەر ئایەتێکی سوورەتەکەوە دەست بە خوێندن بکە. مامۆستا بە گوێگرتن خۆی شوێنەکەت دەدۆزێتەوە و دەتبات بۆ ئەو ئایەتە، پێویست ناکات بە دەست بگەڕێیت.',
                  ),
                  _feature(
                    context,
                    Icons.bolt,
                    'وەڵامی دەنگیی دەستبەجێ',
                    'کاتێک وشەیەک هەڵە دەخوێنیت، ئەو وشەیە سوور دەبێت و مامۆستا یەکسەر دەنگی ڕاستی دەڵێتەوە (وشەی پێش، هەڵە و دوای). تۆش دووبارەی دەکەیتەوە و بەردەوام دەبیت.',
                  ),
                  _feature(
                    context,
                    Icons.wifi_off,
                    'گوێگرتن بێ ئینتەرنێت',
                    'مۆدێلی ناسینەوەی دەنگ لەناو مۆبایلەکەتدایە، بۆیە گوێگرتن بێ ئینتەرنێت کار دەکات. تەنها دەنگی مامۆستا (مشاری العفاسی) ئینتەرنێتی دەوێت.',
                  ),
                  _feature(
                    context,
                    Icons.spellcheck,
                    'نیشاندانی وردی هەڵە',
                    'تەنها ئەو پیت، شەدە، تەنوین، حەرەکە یان مەدەی هەڵەیە سوور دەبێت، نەک هەموو وشەکە.',
                  ),
                  _feature(
                    context,
                    Icons.timer_off,
                    'کوژانەوەی خۆکار',
                    'ئەگەر ١ خولەک هیچ دەنگێک نەبیسترێت، مایکرۆفۆن خۆی دەکوژێتەوە بۆ پاراستنی باتری.',
                  ),
                  _feature(
                    context,
                    Icons.bookmark_added,
                    'هەمیشە ئازادیت',
                    'لە کاتی خوێندن شاشە ناکوژێتەوە. هەر جارێک مایک بکەیتەوە، لە هەر ئایەتێکەوە دەتوانیت دەست پێبکەیت؛ دوایین ئایەت تەنها بۆ کارتی «بەردەوامبوون» پاشەکەوت دەکرێت.',
                  ),
                  _sectionHead('ئاستی وردی'),
                  for (var i = 0; i < kCoachLevels.length; i++)
                    _RadioTile(
                      label: kCoachLevels[i],
                      sub: kCoachLevelHints[i],
                      on: settings.coachLevel == i + 1,
                      onTap: () => settings.setCoachLevel(i + 1),
                    ),
                  _sectionHead('خێرایی خوێندنەوە'),
                  Text(
                    'دیاری دەکات مەدەکان چەند درێژ بن. ئەگەر بە خێرایی دەخوێنیت (حدر) مەدی کورت وەک هەڵە نابینرێت، و ئەگەر بە خاوی (تحقیق) مەدی درێژ وەک هەڵە نابینرێت.',
                    style: TextStyle(fontSize: 13, height: 1.7, color: _mutedColor(context)),
                  ),
                  const SizedBox(height: 6),
                  _RadioTile(
                    label: 'خێرا - حدر (مەد 2 دەنگ)',
                    on: settings.coachSpeed == 0,
                    onTap: () => settings.setCoachSpeed(0),
                  ),
                  _RadioTile(
                    label: 'ناوەند - تدویر (مەد 4 دەنگ)',
                    on: settings.coachSpeed == 1,
                    onTap: () => settings.setCoachSpeed(1),
                  ),
                  _RadioTile(
                    label: 'خاو - تحقیق (مەد 5 تا 6 دەنگ)',
                    on: settings.coachSpeed == 2,
                    onTap: () => settings.setCoachSpeed(2),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    'ئاست و خێرایی خۆکارانە پاشەکەوت دەکرێن و لە دەستپێکردنی داهاتووی مامۆستادا بەکاردێن.',
                    style: TextStyle(fontSize: 12.5, height: 1.7, color: _mutedColor(context)),
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
//  3) Qibla compass
// ============================================================
class QiblaPage extends StatefulWidget {
  const QiblaPage({super.key});

  @override
  State<QiblaPage> createState() => _QiblaPageState();
}

class _QiblaPageState extends State<QiblaPage> {
  StreamSubscription<fc.CompassEvent>? _sub;
  double? _heading; // degrees clockwise from magnetic north
  bool _noSensor = false;

  @override
  void initState() {
    super.initState();
    locPrefs.ensureLoaded();
    try {
      final stream = fc.FlutterCompass.events;
      if (stream == null) {
        _noSensor = true;
      } else {
        _sub = stream.listen(_onCompass, onError: (Object _) {
          if (mounted) setState(() => _noSensor = true);
        });
      }
    } catch (_) {
      _noSensor = true;
    }
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  void _onCompass(fc.CompassEvent e) {
    if (!mounted) return;
    final h = e.heading;
    if (h == null) {
      if (_heading == null) setState(() => _noSensor = true);
      return;
    }
    var v = (h + 360) % 360;
    final old = _heading;
    if (old != null) {
      // light smoothing so the dial does not shake
      final d = ((v - old + 540) % 360) - 180;
      v = (old + d * 0.3 + 360) % 360;
    }
    setState(() {
      _heading = v;
      _noSensor = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: locPrefs,
      builder: (context, _) {
        final c = locPrefs.c;
        final q = qiblaBearing(c.lat, c.lng);
        final km = distanceToKaaba(c.lat, c.lng);
        final h = _heading;
        final diff = h == null ? null : (((q - h + 540) % 360) - 180);
        final aligned = diff != null && diff.abs() <= 4;
        final color = aligned ? const Color(0xFF2E9E50) : _gold;

        String status;
        if (aligned) {
          status = 'ڕووت لە قیبلەیە ✓';
        } else if (diff != null) {
          status =
              'مۆبایلەکە بسوڕێنە تا نیشانەی مزگەوت دەگاتە سەرەوە (${diff.abs().round()}° ماوە)';
        } else if (_noSensor) {
          status =
              'ئەم مۆبایلە سێنسەری کۆمپاسی نییە یان کار ناکات. ئاڕاستەی قیبلە بە ڕێژەی باکوور: ${q.round()}°';
        } else {
          status = 'چاوەڕێی سێنسەری کۆمپاس...';
        }

        return Scaffold(
          appBar: AppBar(
            title: const Text('قیبلەنما', style: TextStyle(fontWeight: FontWeight.bold)),
          ),
          body: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 820),
              child: ListView(
                padding: const EdgeInsets.fromLTRB(12, 12, 12, 28),
                children: [
                  Material(
                    color: _cardColor(context),
                    clipBehavior: Clip.antiAlias,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                      side: BorderSide(color: _lineColor(context)),
                    ),
                    child: ListTile(
                      onTap: () => _pickCity(context),
                      leading: const Icon(Icons.location_on, color: _gold),
                      title: Text(c.ku,
                          style: TextStyle(fontSize: 17, color: _inkColor(context))),
                      subtitle: const Text('شار'),
                      trailing: const Icon(Icons.expand_more),
                    ),
                  ),
                  const SizedBox(height: 18),
                  Center(
                    child: SizedBox(
                      width: 320,
                      height: 320,
                      child: Stack(
                        alignment: Alignment.center,
                        children: [
                          Transform.rotate(
                            angle: -(h ?? 0) * math.pi / 180,
                            child: SizedBox(
                              width: 320,
                              height: 320,
                              child: Stack(
                                alignment: Alignment.center,
                                children: [
                                  CustomPaint(
                                    size: const Size(320, 320),
                                    painter: _DialPainter(
                                      _lineColor(context),
                                      _mutedColor(context),
                                      _gold,
                                    ),
                                  ),
                                  Transform.rotate(
                                    angle: q * math.pi / 180,
                                    child: SizedBox(
                                      width: 320,
                                      height: 320,
                                      child: Align(
                                        alignment: Alignment.topCenter,
                                        child: Padding(
                                          padding: const EdgeInsets.only(top: 2),
                                          child: Container(
                                            width: 40,
                                            height: 40,
                                            decoration: BoxDecoration(
                                              color: color,
                                              shape: BoxShape.circle,
                                            ),
                                            child: const Icon(Icons.mosque,
                                                color: Colors.white, size: 22),
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                          // fixed needle: points to the top of the phone
                          Icon(Icons.navigation, size: 72, color: color),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    status,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: aligned ? 20 : 15,
                      fontWeight: FontWeight.bold,
                      height: 1.6,
                      color: aligned ? const Color(0xFF2E9E50) : _inkColor(context),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Expanded(child: _InfoBox('ئاڕاستەی قیبلە', '${q.round()}°')),
                      const SizedBox(width: 10),
                      Expanded(child: _InfoBox('دووری تا مەککە', '${km.round()} کم')),
                    ],
                  ),
                  const SizedBox(height: 14),
                  Text(
                    'بۆ ئەنجامی باشتر مۆبایلەکە تەخت بگرە و لە ئاسن و ئامێری مەگنەتی دووری بخەرەوە. ئەگەر کۆمپاسەکە ڕاست نەبوو، مۆبایلەکە بە شێوەی ٨ لە هەوادا بجوڵێنە.',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 12.5, height: 1.7, color: _mutedColor(context)),
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

class _InfoBox extends StatelessWidget {
  final String label;
  final String value;
  const _InfoBox(this.label, this.value);

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 10),
      decoration: BoxDecoration(
        color: _cardColor(context),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: _lineColor(context)),
      ),
      child: Column(
        children: [
          Text(label, style: TextStyle(fontSize: 12.5, color: _mutedColor(context))),
          const SizedBox(height: 4),
          Text(
            value,
            textDirection: TextDirection.ltr,
            style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: _gold),
          ),
        ],
      ),
    );
  }
}

class _DialPainter extends CustomPainter {
  final Color line;
  final Color ink;
  final Color gold;
  const _DialPainter(this.line, this.ink, this.gold);

  @override
  void paint(Canvas canvas, Size size) {
    final c = Offset(size.width / 2, size.height / 2);
    const r = 112.0;
    canvas.drawCircle(
      c,
      r,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = line,
    );
    final tick = Paint()
      ..strokeWidth = 1.5
      ..color = line;
    for (var i = 0; i < 72; i++) {
      final a = i * 5 * math.pi / 180;
      final len = i % 18 == 0 ? 16.0 : (i % 6 == 0 ? 11.0 : 6.0);
      final p1 = Offset(c.dx + (r - len) * math.sin(a), c.dy - (r - len) * math.cos(a));
      final p2 = Offset(c.dx + r * math.sin(a), c.dy - r * math.cos(a));
      canvas.drawLine(p1, p2, tick);
    }
    void letter(String t, double deg, Color col, double fs) {
      final tp = TextPainter(
        text: TextSpan(
          text: t,
          style: TextStyle(color: col, fontSize: fs, fontWeight: FontWeight.bold),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      final a = deg * math.pi / 180;
      tp.paint(
        canvas,
        Offset(
          c.dx + 86 * math.sin(a) - tp.width / 2,
          c.dy - 86 * math.cos(a) - tp.height / 2,
        ),
      );
    }

    letter('N', 0, gold, 20);
    letter('E', 90, ink, 15);
    letter('S', 180, ink, 15);
    letter('W', 270, ink, 15);
  }

  @override
  bool shouldRepaint(covariant _DialPainter old) =>
      old.line != line || old.ink != ink || old.gold != gold;
}

// ============================================================
//  4) Azkar (morning / evening) with counters
// ============================================================
class _Dhikr {
  final String id;
  final int count;
  final String ku;
  final String? ar; // own text
  final int surah; // 0 = use [ar]; otherwise the text comes from quran.json
  final int from;
  final int to; // 0 = until the end of the surah
  const _Dhikr(this.id, this.count, this.ku,
      {this.ar, this.surah = 0, this.from = 1, this.to = 0});
}

const String _azMulkM =
    'أَصْبَحْنَا وَأَصْبَحَ الْمُلْكُ لِلَّهِ، وَالْحَمْدُ لِلَّهِ، لَا إِلَٰهَ إِلَّا اللَّهُ وَحْدَهُ لَا شَرِيكَ لَهُ، لَهُ الْمُلْكُ وَلَهُ الْحَمْدُ وَهُوَ عَلَىٰ كُلِّ شَيْءٍ قَدِيرٌ. رَبِّ أَسْأَلُكَ خَيْرَ مَا فِي هَٰذَا الْيَوْمِ وَخَيْرَ مَا بَعْدَهُ، وَأَعُوذُ بِكَ مِنْ شَرِّ مَا فِي هَٰذَا الْيَوْمِ وَشَرِّ مَا بَعْدَهُ. رَبِّ أَعُوذُ بِكَ مِنَ الْكَسَلِ وَسُوءِ الْكِبَرِ. رَبِّ أَعُوذُ بِكَ مِنْ عَذَابٍ فِي النَّارِ وَعَذَابٍ فِي الْقَبْرِ';
const String _azMulkE =
    'أَمْسَيْنَا وَأَمْسَى الْمُلْكُ لِلَّهِ، وَالْحَمْدُ لِلَّهِ، لَا إِلَٰهَ إِلَّا اللَّهُ وَحْدَهُ لَا شَرِيكَ لَهُ، لَهُ الْمُلْكُ وَلَهُ الْحَمْدُ وَهُوَ عَلَىٰ كُلِّ شَيْءٍ قَدِيرٌ. رَبِّ أَسْأَلُكَ خَيْرَ مَا فِي هَٰذِهِ اللَّيْلَةِ وَخَيْرَ مَا بَعْدَهَا، وَأَعُوذُ بِكَ مِنْ شَرِّ مَا فِي هَٰذِهِ اللَّيْلَةِ وَشَرِّ مَا بَعْدَهَا. رَبِّ أَعُوذُ بِكَ مِنَ الْكَسَلِ وَسُوءِ الْكِبَرِ. رَبِّ أَعُوذُ بِكَ مِنْ عَذَابٍ فِي النَّارِ وَعَذَابٍ فِي الْقَبْرِ';
const String _azBikaM =
    'اللَّهُمَّ بِكَ أَصْبَحْنَا، وَبِكَ أَمْسَيْنَا، وَبِكَ نَحْيَا، وَبِكَ نَمُوتُ، وَإِلَيْكَ النُّشُورُ';
const String _azBikaE =
    'اللَّهُمَّ بِكَ أَمْسَيْنَا، وَبِكَ أَصْبَحْنَا، وَبِكَ نَحْيَا، وَبِكَ نَمُوتُ، وَإِلَيْكَ الْمَصِيرُ';
const String _azIstighfar =
    'اللَّهُمَّ أَنْتَ رَبِّي لَا إِلَٰهَ إِلَّا أَنْتَ، خَلَقْتَنِي وَأَنَا عَبْدُكَ، وَأَنَا عَلَىٰ عَهْدِكَ وَوَعْدِكَ مَا اسْتَطَعْتُ، أَعُوذُ بِكَ مِنْ شَرِّ مَا صَنَعْتُ، أَبُوءُ لَكَ بِنِعْمَتِكَ عَلَيَّ، وَأَبُوءُ بِذَنْبِي فَاغْفِرْ لِي فَإِنَّهُ لَا يَغْفِرُ الذُّنُوبَ إِلَّا أَنْتَ';
const String _azBismillah =
    'بِسْمِ اللَّهِ الَّذِي لَا يَضُرُّ مَعَ اسْمِهِ شَيْءٌ فِي الْأَرْضِ وَلَا فِي السَّمَاءِ وَهُوَ السَّمِيعُ الْعَلِيمُ';
const String _azRadiytu =
    'رَضِيتُ بِاللَّهِ رَبًّا، وَبِالْإِسْلَامِ دِينًا، وَبِمُحَمَّدٍ نَبِيًّا';
const String _azHasbi =
    'حَسْبِيَ اللَّهُ لَا إِلَٰهَ إِلَّا هُوَ عَلَيْهِ تَوَكَّلْتُ وَهُوَ رَبُّ الْعَرْشِ الْعَظِيمِ';
const String _azTasbih = 'سُبْحَانَ اللَّهِ وَبِحَمْدِهِ';
const String _azTahlil =
    'لَا إِلَٰهَ إِلَّا اللَّهُ وَحْدَهُ لَا شَرِيكَ لَهُ، لَهُ الْمُلْكُ وَلَهُ الْحَمْدُ وَهُوَ عَلَىٰ كُلِّ شَيْءٍ قَدِيرٌ';
const String _azSalawat = 'اللَّهُمَّ صَلِّ وَسَلِّمْ عَلَىٰ نَبِيِّنَا مُحَمَّدٍ';
const String _azIstighfar100 = 'أَسْتَغْفِرُ اللَّهَ وَأَتُوبُ إِلَيْهِ';
const String _azKalimat = 'أَعُوذُ بِكَلِمَاتِ اللَّهِ التَّامَّاتِ مِنْ شَرِّ مَا خَلَقَ';
const String _azHayy =
    'يَا حَيُّ يَا قَيُّومُ بِرَحْمَتِكَ أَسْتَغِيثُ، أَصْلِحْ لِي شَأْنِي كُلَّهُ، وَلَا تَكِلْنِي إِلَىٰ نَفْسِي طَرْفَةَ عَيْنٍ';

const String _kuBismillah =
    'بە ناوی ئەو خوایەی کە لەگەڵ ناوی ئەودا هیچ شتێک زیان ناگەیەنێت، نە لە زەوی و نە لە ئاسمان، و ئەو بیسەر و زانایە.';
const String _kuRadiytu =
    'ڕازیم بە خوا وەک پەروەردگار، بە ئیسلام وەک ئایین، و بە موحەممەد (د.خ) وەک پێغەمبەر.';
const String _kuHasbi =
    'خوا بەسە بۆم، جگە لەو هیچ پەرستراوێک نییە، پشتم بەو بەستووە و ئەو پەروەردگاری عەرشی مەزنە.';

const List<_Dhikr> _azMorning = [
  _Dhikr('kursi', 1, 'ئایەتولکورسی (بەقەرە، ئایەتی ٢٥٥)', surah: 2, from: 255, to: 255),
  _Dhikr('ikhlas', 3, 'سورەتی ئیخلاس', surah: 112),
  _Dhikr('falaq', 3, 'سورەتی فەلەق', surah: 113),
  _Dhikr('nas', 3, 'سورەتی ناس', surah: 114),
  _Dhikr('mulk', 1,
      'بەیانیمان کرد و هەموو پاشایەتییەک هی خوایە. خوایە، چاکەی ئەم ڕۆژە و دوای ئەویشت لێ دەخوازم و پەنا دەگرم بە تۆ لە خراپەی ئەم ڕۆژە و دوای ئەویش.',
      ar: _azMulkM),
  _Dhikr('bika', 1,
      'خوایە، بە تۆ بەیانیمان کرد و بە تۆ ئێوارەمان کرد، بە تۆ دەژین و بە تۆ دەمرین و بۆ لای تۆیە زیندووبوونەوە.',
      ar: _azBikaM),
  _Dhikr('istighfar', 1,
      'خوایە، تۆ پەروەردگاری منی و جگە لە تۆ هیچ پەرستراوێک نییە. منت دروستکردووە و من بەندەی تۆم و تا توانام لەسەر پەیمانی تۆم. پەنات پێ دەگرم لە خراپەی ئەوەی کردوومە. دان بە نیعمەتی تۆدا دەنێم و دان بە گوناهی خۆمدا دەنێم، کەواتە ببورە، چونکە جگە لە تۆ کەس گوناه نابورێت.',
      ar: _azIstighfar),
  _Dhikr('bismillah', 3, _kuBismillah, ar: _azBismillah),
  _Dhikr('radiytu', 3, _kuRadiytu, ar: _azRadiytu),
  _Dhikr('hayy', 1,
      'ئەی زیندووی هەمیشەیی، ئەی پایەدار، بە ڕەحمەتی تۆ هاوار دەکەم. هەموو کارەکانم ڕێکبخە و بۆ چاوتروکانێکیش من مەسپێرە بە خۆم.',
      ar: _azHayy),
  _Dhikr('hasbi', 7, _kuHasbi, ar: _azHasbi),
  _Dhikr('tahlil', 10,
      'هیچ پەرستراوێک نییە جگە لە خوای تاک و تەنیا، هاوبەشی نییە. پاشایەتی هی ئەو و ستایش هی ئەوە و ئەو بەسەر هەموو شتێکدا تواناداره.',
      ar: _azTahlil),
  _Dhikr('tasbih', 100, 'پاکی بۆ خوا و سوپاسی هەر بۆ ئەو.', ar: _azTasbih),
  _Dhikr('istighfar100', 100, 'داوای لێبوردن لە خوا دەکەم و تۆبە دەکەم بۆی.',
      ar: _azIstighfar100),
  _Dhikr('salawat', 10, 'خوایە، ڕەحمەت و سڵاو بنێرە بۆ پێغەمبەرمان موحەممەد.',
      ar: _azSalawat),
];

const List<_Dhikr> _azEvening = [
  _Dhikr('kursi', 1, 'ئایەتولکورسی (بەقەرە، ئایەتی ٢٥٥)', surah: 2, from: 255, to: 255),
  _Dhikr('ikhlas', 3, 'سورەتی ئیخلاس', surah: 112),
  _Dhikr('falaq', 3, 'سورەتی فەلەق', surah: 113),
  _Dhikr('nas', 3, 'سورەتی ناس', surah: 114),
  _Dhikr('mulk', 1,
      'ئێوارەمان کرد و هەموو پاشایەتییەک هی خوایە. خوایە، چاکەی ئەم شەوە و دوای ئەویشت لێ دەخوازم و پەنا دەگرم بە تۆ لە خراپەی ئەم شەوە و دوای ئەویش.',
      ar: _azMulkE),
  _Dhikr('bika', 1,
      'خوایە، بە تۆ ئێوارەمان کرد و بە تۆ بەیانیمان کرد، بە تۆ دەژین و بە تۆ دەمرین و بۆ لای تۆیە گەڕانەوە.',
      ar: _azBikaE),
  _Dhikr('istighfar', 1,
      'خوایە، تۆ پەروەردگاری منی و جگە لە تۆ هیچ پەرستراوێک نییە. منت دروستکردووە و من بەندەی تۆم و تا توانام لەسەر پەیمانی تۆم. پەنات پێ دەگرم لە خراپەی ئەوەی کردوومە. دان بە نیعمەتی تۆدا دەنێم و دان بە گوناهی خۆمدا دەنێم، کەواتە ببورە، چونکە جگە لە تۆ کەس گوناه نابورێت.',
      ar: _azIstighfar),
  _Dhikr('bismillah', 3, _kuBismillah, ar: _azBismillah),
  _Dhikr('radiytu', 3, _kuRadiytu, ar: _azRadiytu),
  _Dhikr('kalimat', 3, 'پەنا دەگرم بە وشە تەواوەکانی خوا لە خراپەی ئەوەی دروستی کردووە.',
      ar: _azKalimat),
  _Dhikr('hayy', 1,
      'ئەی زیندووی هەمیشەیی، ئەی پایەدار، بە ڕەحمەتی تۆ هاوار دەکەم. هەموو کارەکانم ڕێکبخە و بۆ چاوتروکانێکیش من مەسپێرە بە خۆم.',
      ar: _azHayy),
  _Dhikr('hasbi', 7, _kuHasbi, ar: _azHasbi),
  _Dhikr('tahlil', 10,
      'هیچ پەرستراوێک نییە جگە لە خوای تاک و تەنیا، هاوبەشی نییە. پاشایەتی هی ئەو و ستایش هی ئەوە و ئەو بەسەر هەموو شتێکدا تواناداره.',
      ar: _azTahlil),
  _Dhikr('tasbih', 100, 'پاکی بۆ خوا و سوپاسی هەر بۆ ئەو.', ar: _azTasbih),
  _Dhikr('istighfar100', 100, 'داوای لێبوردن لە خوا دەکەم و تۆبە دەکەم بۆی.',
      ar: _azIstighfar100),
  _Dhikr('salawat', 10, 'خوایە، ڕەحمەت و سڵاو بنێرە بۆ پێغەمبەرمان موحەممەد.',
      ar: _azSalawat),
];

/// Quran-based azkar take their text from quran.json (loaded once).
final Map<String, String> _azQuran = <String, String>{};
final ValueNotifier<int> _azQuranTick = ValueNotifier<int>(0);

/// Counters of today; they start from zero again every new day.
class AzkarStore extends ChangeNotifier {
  String _day = '';
  Map<String, int> done = <String, int>{};
  bool _loaded = false;

  static String _today() {
    final n = DateTime.now();
    return '${n.year}-${_two(n.month)}-${_two(n.day)}';
  }

  Future<void> ensureLoaded() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final p = await SharedPreferences.getInstance();
      final day = p.getString('azDay') ?? '';
      if (day == _today()) {
        final s = p.getString('azDone');
        if (s != null) {
          final m = jsonDecode(s) as Map<String, dynamic>;
          done = m.map((k, v) => MapEntry(k, (v as num).toInt()));
        }
      }
      _day = _today();
      notifyListeners();
    } catch (_) {
      _day = _today();
    }
  }

  int taps(String key) => done[key] ?? 0;

  void tap(String key, int max) {
    if (_day != _today()) {
      _day = _today();
      done = <String, int>{};
    }
    final v = taps(key);
    if (v >= max) return;
    done[key] = v + 1;
    notifyListeners();
    _save();
  }

  void reset(String key) {
    done.remove(key);
    notifyListeners();
    _save();
  }

  void resetSet(String prefix) {
    done.removeWhere((k, _) => k.startsWith('$prefix:'));
    notifyListeners();
    _save();
  }

  Future<void> _save() async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString('azDay', _day);
      await p.setString('azDone', jsonEncode(done));
    } catch (_) {}
  }
}

final AzkarStore azkarStore = AzkarStore();

class AzkarPage extends StatefulWidget {
  const AzkarPage({super.key});

  @override
  State<AzkarPage> createState() => _AzkarPageState();
}

class _AzkarPageState extends State<AzkarPage> {
  @override
  void initState() {
    super.initState();
    azkarStore.ensureLoaded();
    _loadQuran();
  }

  Future<void> _loadQuran() async {
    for (final d in [..._azMorning, ..._azEvening]) {
      if (d.surah == 0 || _azQuran.containsKey(d.id)) continue;
      try {
        final list = await loadSurah(d.surah);
        final parts = <String>[];
        for (final a in list) {
          if (a.n >= d.from && (d.to == 0 || a.n <= d.to)) parts.add(a.ar);
        }
        _azQuran[d.id] = parts.join(' ');
        _azQuranTick.value++;
      } catch (_) {}
    }
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      initialIndex: DateTime.now().hour < 15 ? 0 : 1,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('زیکرەکان', style: TextStyle(fontWeight: FontWeight.bold)),
          actions: [
            Builder(
              builder: (ctx) => IconButton(
                tooltip: 'سفرکردنەوەی ژمێرەرەکانی ئەم بەشە',
                icon: const Icon(Icons.restart_alt),
                onPressed: () {
                  final i = DefaultTabController.of(ctx).index;
                  azkarStore.resetSet(i == 0 ? 'm' : 'e');
                },
              ),
            ),
          ],
          bottom: const TabBar(
            labelColor: Colors.white,
            unselectedLabelColor: Color(0xB3FFFFFF),
            indicatorColor: _gold,
            tabs: [Tab(text: 'بەیانیان'), Tab(text: 'ئێواران')],
          ),
        ),
        body: const TabBarView(
          children: [
            _AzkarList(setKey: 'm', items: _azMorning),
            _AzkarList(setKey: 'e', items: _azEvening),
          ],
        ),
      ),
    );
  }
}

class _AzkarList extends StatelessWidget {
  final String setKey;
  final List<_Dhikr> items;
  const _AzkarList({required this.setKey, required this.items});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([azkarStore, settings, _azQuranTick]),
      builder: (context, _) => _body(context),
    );
  }

  Widget _body(BuildContext context) {
    var done = 0;
    for (final d in items) {
      if (azkarStore.taps('$setKey:${d.id}') >= d.count) done++;
    }
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 820),
        child: ListView(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 28),
          children: [
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: _cardColor(context),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: _lineColor(context)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '$done / ${items.length} زیکر تەواو بوون',
                    style: TextStyle(
                      fontSize: 14.5,
                      fontWeight: FontWeight.bold,
                      color: _inkColor(context),
                    ),
                  ),
                  const SizedBox(height: 8),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: LinearProgressIndicator(
                      value: items.isEmpty ? 0 : done / items.length,
                      minHeight: 8,
                      color: _gold,
                      backgroundColor: _lineColor(context),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'بۆ ژماردن لەسەر کارتەکە دابگرە. بۆ سفرکردنەوەی یەک زیکر، بەردەوام دایبگرە.',
                    style: TextStyle(fontSize: 12, color: _mutedColor(context)),
                  ),
                ],
              ),
            ),
            for (final d in items) _DhikrCard(setKey: setKey, d: d),
          ],
        ),
      ),
    );
  }
}

class _DhikrCard extends StatelessWidget {
  final String setKey;
  final _Dhikr d;
  const _DhikrCard({required this.setKey, required this.d});

  @override
  Widget build(BuildContext context) {
    final key = '$setKey:${d.id}';
    final taps = azkarStore.taps(key);
    final finished = taps >= d.count;
    final left = (d.count - taps).clamp(0, d.count).toInt();
    final text = d.surah == 0 ? (d.ar ?? '') : (_azQuran[d.id] ?? '');
    final size = settings.arabicSize.clamp(20, 34).toDouble();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Material(
        color: _cardColor(context),
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18),
          side: BorderSide(
            color: finished ? _green : _lineColor(context),
            width: finished ? 1.8 : 1,
          ),
        ),
        child: InkWell(
          onTap: finished ? null : () => azkarStore.tap(key, d.count),
          onLongPress: () => azkarStore.reset(key),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (text.isNotEmpty)
                  Text(
                    text,
                    textAlign: TextAlign.center,
                    textDirection: TextDirection.rtl,
                    style: TextStyle(
                      fontSize: size,
                      height: 1.9,
                      color: _inkColor(context),
                      fontFamilyFallback: _arFonts,
                    ),
                  )
                else
                  const SizedBox(
                    height: 32,
                    child: Center(
                      child: SizedBox(
                        width: 22,
                        height: 22,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    ),
                  ),
                const SizedBox(height: 10),
                Text(
                  d.ku,
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 13, height: 1.7, color: _mutedColor(context)),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                      decoration: BoxDecoration(
                        color: finished ? _green : _gold.withAlpha(45),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            finished ? Icons.check_circle : Icons.touch_app,
                            size: 18,
                            color: finished ? Colors.white : _gold,
                          ),
                          const SizedBox(width: 6),
                          Text(
                            finished ? 'تەواو بوو' : 'ماوە: $left',
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              color: finished ? Colors.white : _gold,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const Spacer(),
                    Text(
                      '$taps / ${d.count}',
                      textDirection: TextDirection.ltr,
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        color: _inkColor(context),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ============================================================
//  5) Prayer times
// ============================================================
// ============================================================
//  Adhan notifications (Android) - uses PrayerCalc, like the card
// ============================================================

/// Per prayer (fajr, dhuhr, asr, maghrib, isha):
/// 0 = off, 1 = silent notification, 2 = notification + phone sound,
/// 3 = Adhan sound (res/raw/adhan.mp3).
class AdhanPrefs extends ChangeNotifier {
  final List<int> mode = [0, 0, 0, 0, 0];

  Future<void> load() async {
    try {
      final p = await SharedPreferences.getInstance();
      for (var i = 0; i < 5; i++) {
        mode[i] = (p.getInt('adhanMode$i') ?? 0).clamp(0, 3).toInt();
      }
    } catch (_) {}
  }

  Future<void> setMode(int slot, int v) async {
    mode[slot] = v;
    notifyListeners();
    try {
      final p = await SharedPreferences.getInstance();
      await p.setInt('adhanMode$slot', v);
    } catch (_) {}
  }
}

final AdhanPrefs adhanPrefs = AdhanPrefs();

IconData _adhanIcon(int mode) {
  switch (mode) {
    case 1:
      return Icons.notifications_none;
    case 2:
      return Icons.notifications_active;
    case 3:
      return Icons.volume_up;
    default:
      return Icons.notifications_off_outlined;
  }
}

Future<void> _pickAdhanMode(BuildContext context, int slot) async {
  const labels = [
    'کوژاوە',
    'ئاگادارکردنەوەی بێدەنگ',
    'ئاگادارکردنەوە + دەنگی مۆبایل',
    'دەنگی بانگ',
  ];
  final name = kPrayerShort[const [0, 2, 3, 4, 5][slot]];
  final v = await showModalBottomSheet<int>(
    context: context,
    showDragHandle: true,
    builder: (ctx) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text('بانگی $name',
                style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
          ),
          for (var m = 0; m < 4; m++)
            ListTile(
              leading: Icon(_adhanIcon(m), color: _gold),
              title: Text(labels[m]),
              trailing: adhanPrefs.mode[slot] == m
                  ? const Icon(Icons.check, color: _green)
                  : null,
              onTap: () => Navigator.of(ctx).pop(m),
            ),
        ],
      ),
    ),
  );
  if (v == null) return;
  await adhanPrefs.setMode(slot, v);
  if (v != 0) await AdhanScheduler.ensurePermissions();
}

class _AdhanLifecycle with WidgetsBindingObserver {
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // date / time zone / settings may have changed while the app was away
    if (state == AppLifecycleState.resumed) AdhanScheduler.scheduleSoon();
  }
}

class AdhanScheduler {
  static final fln.FlutterLocalNotificationsPlugin _plugin =
      fln.FlutterLocalNotificationsPlugin();
  static bool _ready = false;
  static bool _busy = false;
  static bool _again = false;
  static Timer? _debounce;

  static const int _base = 7000; // notification ids 7000 .. 7000 + _days * 5
  static const int _days = 14; // rolling window, rebuilt on every app start
  static const List<int> _idx = [0, 2, 3, 4, 5]; // PrayerDay.list positions
  static const List<String> _chIds = [
    'adhan_silent_v1',
    'adhan_default_v1',
    'adhan_sound_v1',
  ];

  static fln.AndroidFlutterLocalNotificationsPlugin? get _android =>
      _plugin.resolvePlatformSpecificImplementation<
          fln.AndroidFlutterLocalNotificationsPlugin>();

  static Future<void> init() async {
    if (_ready || !Platform.isAndroid) return;
    try {
      tzdata.initializeTimeZones();
      await _plugin.initialize(const fln.InitializationSettings(
        android: fln.AndroidInitializationSettings('@mipmap/ic_launcher'),
      ));
      final a = _android;
      if (a != null) {
        await a.createNotificationChannel(const fln.AndroidNotificationChannel(
          'adhan_silent_v1',
          'بانگ (بێدەنگ)',
          description: 'کاتی نوێژ، بێ دەنگ',
          importance: fln.Importance.high,
          playSound: false,
          enableVibration: false,
        ));
        await a.createNotificationChannel(const fln.AndroidNotificationChannel(
          'adhan_default_v1',
          'بانگ (دەنگی مۆبایل)',
          description: 'کاتی نوێژ، بە دەنگی ئاسایی مۆبایل',
          importance: fln.Importance.high,
        ));
        await a.createNotificationChannel(const fln.AndroidNotificationChannel(
          'adhan_sound_v1',
          'بانگ (دەنگی بانگ)',
          description: 'کاتی نوێژ، بە دەنگی بانگ',
          importance: fln.Importance.max,
          sound: fln.RawResourceAndroidNotificationSound('adhan'),
          audioAttributesUsage: fln.AudioAttributesUsage.alarm,
        ));
      }
      _ready = true;
    } catch (e) {
      debugPrint('Adhan init failed: $e');
    }
  }

  /// Notification permission (Android 13+) and exact alarms (Android 12+).
  static Future<bool> ensurePermissions() async {
    if (!_ready) await init();
    final a = _android;
    if (!_ready || a == null) return false;
    var ok = true;
    try {
      ok = await a.requestNotificationsPermission() ?? true;
      if (!(await a.canScheduleExactNotifications() ?? false)) {
        await a.requestExactAlarmsPermission();
      }
    } catch (e) {
      debugPrint('Adhan permissions failed: $e');
    }
    scheduleSoon();
    return ok;
  }

  /// Rebuilds all alarms a second from now (many changes arrive together).
  static void scheduleSoon() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(seconds: 1), () {
      _run();
    });
  }

  static Future<void> _run() async {
    if (!_ready) return;
    if (_busy) {
      _again = true;
      return;
    }
    _busy = true;
    try {
      do {
        _again = false;
        await _reschedule();
      } while (_again);
    } catch (e) {
      debugPrint('Adhan schedule failed: $e');
    } finally {
      _busy = false;
    }
  }

  static Future<void> _reschedule() async {
    final exact = await _android?.canScheduleExactNotifications() ?? false;
    final sm = exact
        ? fln.AndroidScheduleMode.exactAllowWhileIdle
        : fln.AndroidScheduleMode.inexactAllowWhileIdle;
    for (var i = 0; i < _days * 5; i++) {
      await _plugin.cancel(_base + i);
    }
    final c = locPrefs.c;
    final hanafi = locPrefs.hanafi;
    final now = DateTime.now();
    for (var d = 0; d < _days; d++) {
      final date = DateTime(now.year, now.month, now.day + d);
      final day = PrayerCalc.compute(c, date, hanafi: hanafi).list;
      for (var k = 0; k < 5; k++) {
        final m = adhanPrefs.mode[k];
        final t = day[_idx[k]];
        if (m == 0 || t == null || !t.isAfter(now)) continue;
        final name = kPrayerShort[_idx[k]];
        await _plugin.zonedSchedule(
          _base + d * 5 + k,
          'کاتی نوێژی $name',
          '${c.ku} \u2022 ${_hm(t)}',
          tzl.TZDateTime.from(t, tzl.UTC), // an exact instant, zone-proof
          fln.NotificationDetails(
            android: fln.AndroidNotificationDetails(
              _chIds[m - 1],
              'بانگ',
              channelDescription: 'کاتی نوێژ',
              importance: m == 3 ? fln.Importance.max : fln.Importance.high,
              priority: fln.Priority.high,
              playSound: m != 1,
              sound: m == 3
                  ? const fln.RawResourceAndroidNotificationSound('adhan')
                  : null,
              enableVibration: m != 1,
              category: m == 3
                  ? fln.AndroidNotificationCategory.alarm
                  : fln.AndroidNotificationCategory.reminder,
              audioAttributesUsage: m == 3
                  ? fln.AudioAttributesUsage.alarm
                  : fln.AudioAttributesUsage.notification,
            ),
          ),
          androidScheduleMode: sm,
          uiLocalNotificationDateInterpretation:
              fln.UILocalNotificationDateInterpretation.absoluteTime,
        );
      }
    }
  }
}

Widget _prayerChip(String text, Color color) => Container(
      margin: const EdgeInsetsDirectional.only(start: 8),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withAlpha(40),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color),
      ),
      child: Text(text, style: TextStyle(fontSize: 11, color: color)),
    );

class PrayerTimesPage extends StatefulWidget {
  const PrayerTimesPage({super.key});

  @override
  State<PrayerTimesPage> createState() => _PrayerTimesPageState();
}

class _PrayerTimesPageState extends State<PrayerTimesPage> {
  Timer? _t;

  @override
  void initState() {
    super.initState();
    locPrefs.ensureLoaded();
    _t = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _t?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([locPrefs, adhanPrefs]),
      builder: (context, _) {
        final now = DateTime.now();
        final c = locPrefs.c;
        final day = PrayerCalc.compute(c, now, hanafi: locPrefs.hanafi).list;
        final next = PrayerCalc.next(c, now, hanafi: locPrefs.hanafi);
        // Previous prayer point, for the progress bar (prayer -> next prayer).
        final int prevIndex;
        if (next.index == 0) {
          prevIndex = 5;
        } else if (next.index == 2) {
          final sr = day[1];
          prevIndex = (sr != null && !now.isBefore(sr)) ? 1 : 0;
        } else {
          prevIndex = next.index - 1;
        }
        final DateTime? prevTime = next.index == 0
            ? PrayerCalc.compute(
                c,
                DateTime(next.time.year, next.time.month, next.time.day - 1),
                hanafi: locPrefs.hanafi,
              ).isha
            : day[prevIndex];
        var progress = 0.0;
        if (prevTime != null) {
          final total = next.time.difference(prevTime).inSeconds;
          if (total > 0) {
            progress = (now.difference(prevTime).inSeconds / total)
                .clamp(0.0, 1.0)
                .toDouble();
          }
        }
        var cur = -1; // the prayer whose time is running now
        if (next.index == 0) {
          cur = 5;
        } else {
          for (var k = 0; k < 6; k++) {
            final t = day[k];
            if (t != null && !t.isAfter(now)) cur = k;
          }
          if (cur == 1) cur = -1; // after sunrise: no prayer time is running
        }
        return Scaffold(
          appBar: AppBar(
            title: const Text('کاتەکانی بانگ', style: TextStyle(fontWeight: FontWeight.bold)),
          ),
          body: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 820),
              child: ListView(
                padding: const EdgeInsets.fromLTRB(12, 12, 12, 28),
                children: [
                  Material(
                    color: _cardColor(context),
                    clipBehavior: Clip.antiAlias,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                      side: BorderSide(color: _lineColor(context)),
                    ),
                    child: ListTile(
                      onTap: () => _pickCity(context),
                      leading: const Icon(Icons.location_on, color: _gold),
                      title: Text(c.ku,
                          style: TextStyle(fontSize: 17, color: _inkColor(context))),
                      subtitle: const Text('شار'),
                      trailing: const Icon(Icons.expand_more),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Container(
                    padding: const EdgeInsets.all(18),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(20),
                      gradient: const LinearGradient(
                        begin: Alignment.topRight,
                        end: Alignment.bottomLeft,
                        colors: [Color(0xFF2A8C82), Color(0xFF17635C)],
                      ),
                    ),
                    child: Column(
                      children: [
                        const Text('نوێژی داهاتوو',
                            style: TextStyle(color: Color(0xCCFFFFFF), fontSize: 13)),
                        const SizedBox(height: 2),
                        Text(
                          kPrayerShort[next.index],
                          style: const TextStyle(
                            color: Color(0xFFF0C14B),
                            fontSize: 22,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          _hms(next.time.difference(now)),
                          textDirection: TextDirection.ltr,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 42,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 14),
                        ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: LinearProgressIndicator(
                            value: progress,
                            minHeight: 8,
                            backgroundColor: const Color(0x33FFFFFF),
                            valueColor: const AlwaysStoppedAnimation<Color>(
                                Color(0xFFF0C14B)),
                          ),
                        ),
                        const SizedBox(height: 8),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(
                              '${kPrayerShort[prevIndex]}  ${_hm(prevTime)}',
                              style: const TextStyle(
                                  color: Color(0xE6FFFFFF), fontSize: 13),
                            ),
                            Text(
                              '${kPrayerShort[next.index]}  ${_hm(next.time)}',
                              style: const TextStyle(
                                  color: Color(0xE6FFFFFF), fontSize: 13),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 14),
                  SegmentedButton<bool>(
                    segments: const [
                      ButtonSegment<bool>(value: false, label: Text('عەسر: شافیعی')),
                      ButtonSegment<bool>(value: true, label: Text('عەسر: حەنەفی')),
                    ],
                    selected: {locPrefs.hanafi},
                    onSelectionChanged: (s) => locPrefs.setHanafi(s.first),
                  ),
                  const SizedBox(height: 10),
                  for (var i = 0; i < 6; i++)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                        decoration: BoxDecoration(
                          color: _cardColor(context),
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(
                            color: i == next.index ? _gold : _lineColor(context),
                            width: i == next.index ? 2 : 1,
                          ),
                        ),
                        child: Row(
                          children: [
                            Icon(kPrayerIcons[i], color: _gold),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Row(
                                children: [
                                  Flexible(
                                    child: Text(
                                      kPrayerNames[i],
                                      style: TextStyle(
                                        fontSize: 16,
                                        fontWeight: i == next.index
                                            ? FontWeight.bold
                                            : FontWeight.normal,
                                        color: _inkColor(context),
                                      ),
                                    ),
                                  ),
                                  if (i == next.index)
                                    _prayerChip('بانگی داهاتوو', _gold)
                                  else if (i == cur)
                                    _prayerChip('ئێستا', _green),
                                ],
                              ),
                            ),
                            Text(
                              _hm(day[i]),
                              textDirection: TextDirection.ltr,
                              style: TextStyle(
                                fontSize: 20,
                                fontWeight: FontWeight.bold,
                                color: i == next.index ? _gold : _inkColor(context),
                              ),
                            ),
                            if (i != 1) ...[
                              const SizedBox(width: 6),
                              InkResponse(
                                onTap: () =>
                                    _pickAdhanMode(context, i == 0 ? 0 : i - 1),
                                child: Padding(
                                  padding: const EdgeInsets.all(4),
                                  child: Icon(
                                    _adhanIcon(adhanPrefs.mode[i == 0 ? 0 : i - 1]),
                                    size: 24,
                                    color: adhanPrefs.mode[i == 0 ? 0 : i - 1] == 0
                                        ? _mutedColor(context)
                                        : _gold,
                                  ),
                                ),
                              ),
                            ] else
                              const SizedBox(width: 40),
                          ],
                        ),
                      ),
                    ),
                  const SizedBox(height: 10),
                  Material(
                    color: _cardColor(context),
                    clipBehavior: Clip.antiAlias,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                      side: BorderSide(color: _lineColor(context)),
                    ),
                    child: ListTile(
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                            builder: (_) => const PrayerMonthPage()),
                      ),
                      leading: const Icon(Icons.calendar_month, color: _gold),
                      title: Text('کاتەکانی مانگانە',
                          style: TextStyle(fontSize: 16, color: _inkColor(context))),
                      trailing: const Icon(Icons.chevron_right),
                    ),
                  ),
                  const SizedBox(height: 14),
                  Text(
                    c.awqaf
                        ? 'کاتەکان لەگەڵ ڕۆژمێری ئەوقافی هەرێمی کوردستان ڕێکخراون و بەپێی شاری هەڵبژێردراو و کاتژمێری مۆبایلەکەت، بێ ئینتەرنێت هەژمار دەکرێن. لەوانەیە چەند خولەکێک جیاوازی هەبێت، بۆیە بۆ بانگی ڕاستەقینە ڕۆژمێری مزگەوتی ناوچەکەت ببینە.'
                        : 'کاتەکان بە ژمێریاری ئەستێرەناسی (فەجر ١٨° و عیشا ١٧°) بەپێی شاری هەڵبژێردراو و کاتژمێری مۆبایلەکەت هەژمار دەکرێن، بێ ئینتەرنێت. لەوانەیە چەند خولەکێک لەگەڵ ڕۆژمێری فەرمی ئەوقاف جیاواز بن، بۆیە بۆ بانگی ڕاستەقینە ڕۆژمێری مزگەوتی ناوچەکەت ببینە.',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 12.5, height: 1.7, color: _mutedColor(context)),
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
//  Monthly prayer timetable (same engine / same data as the card)
// ============================================================
const List<String> _kMonthsKu = [
  'کانوونی دووەم', 'شوبات', 'ئازار', 'نیسان', 'ئایار', 'حوزەیران',
  'تەمموز', 'ئاب', 'ئەیلوول', 'تشرینی یەکەم', 'تشرینی دووەم', 'کانوونی یەکەم',
];

class PrayerMonthPage extends StatefulWidget {
  const PrayerMonthPage({super.key});

  @override
  State<PrayerMonthPage> createState() => _PrayerMonthPageState();
}

class _PrayerMonthPageState extends State<PrayerMonthPage> {
  late DateTime _m;

  @override
  void initState() {
    super.initState();
    final n = DateTime.now();
    _m = DateTime(n.year, n.month, 1);
  }

  void _go(int d) => setState(() => _m = DateTime(_m.year, _m.month + d, 1));

  @override
  Widget build(BuildContext context) {
    final c = locPrefs.c;
    final hanafi = locPrefs.hanafi;
    final today = DateTime.now();
    final days = DateTime(_m.year, _m.month + 1, 0).day;
    TextStyle cell(bool bold, Color col) => TextStyle(
          fontSize: 12.5,
          fontWeight: bold ? FontWeight.bold : FontWeight.normal,
          color: col,
        );

    final rows = <Widget>[];
    for (var i = 1; i <= days; i++) {
      final d = DateTime(_m.year, _m.month, i);
      final t = PrayerCalc.compute(c, d, hanafi: hanafi).list;
      final isToday =
          d.year == today.year && d.month == today.month && d.day == today.day;
      final official = PrayerCalc.isOfficial(c, d);
      rows.add(Container(
        margin: const EdgeInsets.symmetric(vertical: 2),
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 9),
        decoration: BoxDecoration(
          color: official ? _gold.withAlpha(30) : _cardColor(context),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: isToday ? _gold : _lineColor(context),
            width: isToday ? 2 : 1,
          ),
        ),
        child: Row(
          children: [
            SizedBox(
              width: 28,
              child: Text('$i',
                  textAlign: TextAlign.center,
                  style: cell(true, _inkColor(context))),
            ),
            for (final x in t)
              Expanded(
                child: Text(
                  _hm(x),
                  textAlign: TextAlign.center,
                  textDirection: TextDirection.ltr,
                  style: cell(false, _inkColor(context)),
                ),
              ),
          ],
        ),
      ));
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('کاتەکانی مانگانە',
            style: TextStyle(fontWeight: FontWeight.bold)),
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 820),
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
                child: Directionality(
                  textDirection: TextDirection.ltr,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      IconButton(
                        onPressed: () => _go(-1),
                        icon: const Icon(Icons.chevron_left),
                      ),
                      Column(
                        children: [
                          Text(
                            '${_kMonthsKu[_m.month - 1]} ${_m.year}',
                            style: TextStyle(
                              fontSize: 17,
                              fontWeight: FontWeight.bold,
                              color: _inkColor(context),
                            ),
                          ),
                          Text(c.ku,
                              style: TextStyle(
                                  fontSize: 13, color: _mutedColor(context))),
                        ],
                      ),
                      IconButton(
                        onPressed: () => _go(1),
                        icon: const Icon(Icons.chevron_right),
                      ),
                    ],
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                child: Row(
                  children: [
                    const SizedBox(width: 34),
                    for (final n in kPrayerShort)
                      Expanded(
                        child: FittedBox(
                          fit: BoxFit.scaleDown,
                          child: Text(n,
                              style: TextStyle(
                                  fontSize: 11.5,
                                  fontWeight: FontWeight.bold,
                                  color: _gold)),
                        ),
                      ),
                  ],
                ),
              ),
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 24),
                  children: [
                    ...rows,
                    const SizedBox(height: 10),
                    Text(
                      c.awqaf
                          ? 'ڕۆژە ڕەنگکراوەکان لە خشتەی ڕەسمی ئەوقافەوە وەرگیراون؛ ڕۆژەکانی تر هەژمار دەکرێن و لەوانەیە چەند خولەکێک جیاواز بن.'
                          : 'هەموو کاتەکان بە ژمێریاری ئەستێرەناسی هەژمار دەکرێن و لەوانەیە چەند خولەکێک لەگەڵ ڕۆژمێری فەرمی جیاواز بن.',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                          fontSize: 12, height: 1.7, color: _mutedColor(context)),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
