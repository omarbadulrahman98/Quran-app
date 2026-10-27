// Quran AI Teacher - Stage 1 (isolated screen).
// Pick an ayah, tap the button, recite it; the platform speech recogniser
// streams partial results and each word of the ayah is marked matched/missed.
// No correction playback and no Tajweed analysis yet (later stages).

import 'package:flutter/material.dart';
import 'package:speech_to_text/speech_recognition_error.dart';
import 'package:speech_to_text/speech_recognition_result.dart';
import 'package:speech_to_text/speech_to_text.dart';

import 'main.dart' show Ayah, kSurahs, loadSurah;
import 'quran_ai_matcher.dart';

class QuranAiTeacherPage extends StatefulWidget {
  const QuranAiTeacherPage({super.key});

  @override
  State<QuranAiTeacherPage> createState() => _QuranAiTeacherPageState();
}

class _QuranAiTeacherPageState extends State<QuranAiTeacherPage> {
  static const List<String> _fonts = [
    'Amiri',
    'Noto Naskh Arabic',
    'Scheherazade New',
    'Traditional Arabic',
    'Arial',
  ];

  final SpeechToText _stt = SpeechToText();
  bool _engineReady = false;
  bool _busy = false; // initialising the engine
  bool _listening = false;
  String? _localeId;
  String _notice = '';
  double _level = 0;
  String _heard = '';

  int _surah = 1;
  int _ayahNo = 1;
  List<Ayah> _ayahs = const [];
  bool _loading = true;
  List<String> _tokens = const [];
  List<WordStatus> _statuses = const [];
  int _matched = 0;
  int _total = 0;

  @override
  void initState() {
    super.initState();
    _loadAyahs();
  }

  @override
  void dispose() {
    _stt.cancel();
    super.dispose();
  }

  // ---------- target ayah ----------
  Future<void> _loadAyahs() async {
    setState(() => _loading = true);
    final list = await loadSurah(_surah);
    if (!mounted) return;
    setState(() {
      _ayahs = list;
      if (_ayahNo > list.length) _ayahNo = 1;
      _loading = false;
      _resetAttempt();
    });
  }

  void _resetAttempt() {
    _heard = '';
    _notice = '';
    _tokens = _ayahs.isEmpty ? const [] : splitWords(_ayahs[_ayahNo - 1].ar);
    _statuses = const [];
    _matched = 0;
    _total = 0;
  }

  Future<void> _changeTarget({int? surah, int? ayah}) async {
    if (_listening) await _stt.cancel();
    if (!mounted) return;
    setState(() => _listening = false);
    if (surah != null && surah != _surah) {
      _surah = surah;
      _ayahNo = 1;
      await _loadAyahs();
    } else if (ayah != null) {
      setState(() {
        _ayahNo = ayah;
        _resetAttempt();
      });
    }
  }

  // ---------- speech engine ----------
  /// Initialises the recogniser. This is also what asks for the microphone
  /// (and, on iOS, speech-recognition) permission.
  Future<bool> _initEngine() async {
    setState(() {
      _busy = true;
      _notice = '';
    });
    var ok = false;
    try {
      ok = await _stt.initialize(onStatus: _onStatus, onError: _onError);
    } catch (_) {
      ok = false;
    }
    if (!mounted) return false;

    if (!ok) {
      setState(() {
        _busy = false;
        _notice = 'مایکرۆفۆن یان ناسینەوەی دەنگ بەردەست نییە. مۆڵەتی مایکرۆفۆن '
            'لە ڕێکخستنەکانی مۆبایلەکە بپشکنە و دڵنیابە خزمەتگوزاری ناسینەوەی '
            'دەنگی گووگڵ دامەزراوە.';
      });
      return false;
    }

    final locales = await _stt.locales();
    final arabic = locales
        .where((l) => l.localeId.toLowerCase().startsWith('ar'))
        .toList();
    if (!mounted) return false;
    if (arabic.isEmpty) {
      setState(() {
        _busy = false;
        _notice = 'ناسینەوەی دەنگی عەرەبی لەسەر ئەم ئامێرە بەردەست نییە.';
      });
      return false;
    }
    final preferred = arabic.firstWhere(
      (l) => l.localeId.toLowerCase().contains('sa'),
      orElse: () => arabic.first,
    );
    setState(() {
      _localeId = preferred.localeId;
      _engineReady = true;
      _busy = false;
    });
    return true;
  }

  Future<void> _toggle() async {
    if (_busy || _tokens.isEmpty) return;
    if (_listening) {
      await _stt.stop();
      return;
    }
    if (!_engineReady && !await _initEngine()) return;

    setState(() {
      _heard = '';
      _notice = '';
      _listening = true;
      _apply(false);
    });
    await _stt.listen(
      onResult: _onResult,
      localeId: _localeId,
      listenFor: const Duration(seconds: 90),
      pauseFor: const Duration(seconds: 6),
      onSoundLevelChange: _onLevel,
    );
  }

  void _onResult(SpeechRecognitionResult r) {
    if (!mounted) return;
    setState(() {
      _heard = r.recognizedWords;
      _apply(r.finalResult);
    });
  }

  void _onStatus(String status) {
    if (!mounted) return;
    if (status == 'notListening' || status == 'done') {
      setState(() {
        _listening = false;
        _level = 0;
        if (_heard.isNotEmpty) {
          _apply(true);
        } else {
          _notice = 'هیچ دەنگێک نەبیسترا.';
        }
      });
    }
  }

  void _onError(SpeechRecognitionError e) {
    if (!mounted) return;
    setState(() {
      _listening = false;
      _level = 0;
      _notice = (e.errorMsg == 'error_no_match' ||
              e.errorMsg == 'error_speech_timeout')
          ? 'هیچ دەنگێک نەبیسترا.'
          : 'هەڵەی ناسینەوەی دەنگ: ${e.errorMsg}';
    });
  }

  // Visual indicator only; the reported range differs per platform.
  void _onLevel(double level) {
    if (!mounted) return;
    setState(() => _level = ((level + 2) / 12).clamp(0.0, 1.0).toDouble());
  }

  void _apply(bool isFinal) {
    final r = matchRecitation(
        expectedTokens: _tokens, heard: _heard, isFinal: isFinal);
    _statuses = r.statuses;
    _matched = r.matched;
    _total = r.total;
  }

  // ---------- UI ----------
  Widget _pickers() {
    return Row(
      children: [
        Expanded(
          flex: 3,
          child: DropdownButton<int>(
            isExpanded: true,
            value: _surah,
            items: [
              for (final s in kSurahs)
                DropdownMenuItem(value: s.n, child: Text('${s.n}. ${s.ar}')),
            ],
            onChanged: (v) => v == null ? null : _changeTarget(surah: v),
          ),
        ),
        const SizedBox(width: 16),
        Expanded(
          flex: 2,
          child: DropdownButton<int>(
            isExpanded: true,
            value: _ayahNo,
            items: [
              for (var i = 1; i <= _ayahs.length; i++)
                DropdownMenuItem(value: i, child: Text('ئایەتی $i')),
            ],
            onChanged: (v) => v == null ? null : _changeTarget(ayah: v),
          ),
        ),
      ],
    );
  }

  Widget _ayahText(ColorScheme cs) {
    final spans = <InlineSpan>[];
    for (var i = 0; i < _tokens.length; i++) {
      final status = i < _statuses.length ? _statuses[i] : WordStatus.ignored;
      TextStyle? style;
      if (status == WordStatus.matched) {
        style = const TextStyle(
            color: Color(0xFF2E9E57), fontWeight: FontWeight.bold);
      } else if (status == WordStatus.missed) {
        style = const TextStyle(
            color: Color(0xFFE5484D), fontWeight: FontWeight.bold);
      }
      spans.add(TextSpan(text: _tokens[i], style: style));
      if (i < _tokens.length - 1) spans.add(const TextSpan(text: ' '));
    }
    return Text.rich(
      TextSpan(
        style: TextStyle(
          fontSize: 28,
          height: 2.0,
          color: cs.onSurface,
          fontFamilyFallback: _fonts,
        ),
        children: spans,
      ),
      textAlign: TextAlign.center,
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final showScore = _total > 0 && _statuses.isNotEmpty && _heard.isNotEmpty;

    return Scaffold(
      appBar: AppBar(title: const Text('مامۆستای قورئان (AI)')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                _pickers(),
                const SizedBox(height: 12),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: _ayahText(cs),
                  ),
                ),
                const SizedBox(height: 12),
                if (_listening)
                  LinearProgressIndicator(value: _level, minHeight: 6),
                if (_heard.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  Text('ئەوەی بیستراوە:',
                      style: TextStyle(color: cs.onSurfaceVariant)),
                  const SizedBox(height: 4),
                  Text(
                    _heard,
                    style: TextStyle(
                        fontSize: 20,
                        height: 1.8,
                        fontFamilyFallback: _fonts),
                  ),
                ],
                if (showScore) ...[
                  const SizedBox(height: 12),
                  Text(
                    'وشەی هاوتا: $_matched لە $_total '
                    '(${(_matched / _total * 100).round()}%)',
                    style: const TextStyle(
                        fontSize: 16, fontWeight: FontWeight.bold),
                  ),
                ],
                if (_notice.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  Text(_notice, style: TextStyle(color: cs.error, height: 1.7)),
                ],
                if (_heard.isEmpty && _notice.isEmpty && !_listening)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Text(
                      'دوگمەکە دابگرە و ئایەتەکە بە دەنگی بەرز بخوێنەوە.',
                      style: TextStyle(color: cs.onSurfaceVariant),
                    ),
                  ),
              ],
            ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: FilledButton.icon(
            onPressed: (_loading || _busy) ? null : _toggle,
            icon: Icon(_listening ? Icons.stop : Icons.mic),
            label: Text(_busy
                ? '...'
                : (_listening ? 'وەستان' : 'دەستپێکردنی خوێندنەوە')),
          ),
        ),
      ),
    );
  }
}
