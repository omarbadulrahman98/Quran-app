// Quran AI Teacher - Stage 1: word-level matching of recognised speech against
// the expected ayah. Pure Dart (no Flutter imports) so it can be unit-tested.
//
// Quran.json uses Uthmani spelling (dagger alef, Alef Wasla, small marks) while
// speech recognisers return ordinary Arabic spelling, so both sides are reduced
// to the same "skeleton" before comparing.

import 'dart:math' as math;

enum WordStatus { pending, matched, missed, ignored }

class MatchResult {
  final List<WordStatus> statuses; // one per expected token
  final int matched;
  final int total;
  const MatchResult(this.statuses, this.matched, this.total);

  double get score => total == 0 ? 0 : matched / total;
}

final RegExp _marks = RegExp(
    '[\u0610-\u061A\u064B-\u065F\u0670\u06D6-\u06ED\u0640\u200B-\u200F\u061C]');

const Map<String, String> _fold = {
  '\u0623': '\u0627', // alef with hamza above
  '\u0625': '\u0627', // alef with hamza below
  '\u0622': '\u0627', // alef with madda
  '\u0671': '\u0627', // alef wasla
  '\u0649': '\u064A', // alef maqsura -> ya
  '\u06CC': '\u064A', // farsi ya -> ya
  '\u06A9': '\u0643', // keheh -> kaf
  '\u0629': '\u0647', // ta marbuta -> ha
  '\u0624': '\u0648', // waw with hamza -> waw
  '\u0626': '\u064A', // ya with hamza -> ya
};

/// Reduces Arabic text to a comparable skeleton: removes diacritics, Quranic
/// marks and tatweel, folds letter variants, and drops alef and hamza (which
/// Uthmani and ordinary spelling write differently).
String normalizeArabic(String input) {
  final out = StringBuffer();
  for (final rune in input.replaceAll(_marks, '').runes) {
    final ch = String.fromCharCode(rune);
    final folded = _fold[ch] ?? ch;
    if (folded == '\u0627' || folded == '\u0621') continue;
    final code = folded.codeUnitAt(0);
    if (code < 0x0621 || code > 0x064A) continue; // keep Arabic letters only
    out.write(folded);
  }
  return out.toString();
}

List<String> splitWords(String text) =>
    text.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();

int _distance(String a, String b) {
  if (a == b) return 0;
  if (a.isEmpty) return b.length;
  if (b.isEmpty) return a.length;
  var prev = List<int>.generate(b.length + 1, (i) => i);
  for (var i = 1; i <= a.length; i++) {
    final cur = List<int>.filled(b.length + 1, 0);
    cur[0] = i;
    for (var j = 1; j <= b.length; j++) {
      final cost = a.codeUnitAt(i - 1) == b.codeUnitAt(j - 1) ? 0 : 1;
      cur[j] = math.min(
        math.min(cur[j - 1] + 1, prev[j] + 1),
        prev[j - 1] + cost,
      );
    }
    prev = cur;
  }
  return prev[b.length];
}

bool _similar(String a, String b) {
  if (a == b) return true;
  final longest = math.max(a.length, b.length);
  final allowed = longest >= 7 ? 2 : (longest >= 4 ? 1 : 0);
  return _distance(a, b) <= allowed;
}

/// Compares [heard] (recogniser output) with the expected ayah tokens.
///
/// Expected words are checked in order. Each is looked for within [lookahead]
/// spoken words of the current position, so one misheard word does not derail
/// the rest. While [isFinal] is false, words the speaker has not reached yet
/// are [WordStatus.pending]; once final they count as [WordStatus.missed].
MatchResult matchRecitation({
  required List<String> expectedTokens,
  required String heard,
  required bool isFinal,
  int lookahead = 3,
}) {
  final spoken = <String>[];
  for (final w in splitWords(heard)) {
    final n = normalizeArabic(w);
    if (n.isNotEmpty) spoken.add(n);
  }

  final statuses =
      List<WordStatus>.filled(expectedTokens.length, WordStatus.ignored);
  var cursor = 0;
  var matched = 0;
  var total = 0;

  for (var i = 0; i < expectedTokens.length; i++) {
    final expected = normalizeArabic(expectedTokens[i]);
    if (expected.isEmpty) continue; // stays ignored
    total++;

    if (cursor >= spoken.length) {
      statuses[i] = isFinal ? WordStatus.missed : WordStatus.pending;
      continue;
    }

    var found = -1;
    final end = math.min(spoken.length, cursor + lookahead);
    for (var k = cursor; k < end; k++) {
      if (_similar(expected, spoken[k])) {
        found = k;
        break;
      }
    }

    if (found >= 0) {
      statuses[i] = WordStatus.matched;
      matched++;
      cursor = found + 1;
    } else {
      statuses[i] = WordStatus.missed;
    }
  }

  return MatchResult(statuses, matched, total);
}
