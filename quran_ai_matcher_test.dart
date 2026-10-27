import 'package:flutter_test/flutter_test.dart';
import 'package:quran_kurdish/quran_ai_matcher.dart';

void main() {
  // Al-Fatihah 1:2 in the Uthmani spelling used by quran.json.
  final tokens = splitWords('ٱلْحَمْدُ لِلَّهِ رَبِّ ٱلْعَٰلَمِينَ');

  test('ordinary spelling matches the Uthmani text', () {
    final r = matchRecitation(
        expectedTokens: tokens, heard: 'الحمد لله رب العالمين', isFinal: true);
    expect(r.matched, 4);
    expect(r.total, 4);
  });

  test('unrelated speech matches nothing', () {
    final r = matchRecitation(
        expectedTokens: tokens, heard: 'قل هو الله احد', isFinal: true);
    expect(r.matched, lessThan(2));
  });

  test('partial speech leaves the rest pending, final marks them missed', () {
    final live = matchRecitation(
        expectedTokens: tokens, heard: 'الحمد لله', isFinal: false);
    expect(live.statuses.sublist(2), everyElement(WordStatus.pending));
    final done = matchRecitation(
        expectedTokens: tokens, heard: 'الحمد لله', isFinal: true);
    expect(done.statuses.sublist(2), everyElement(WordStatus.missed));
  });

  test('one misheard word does not derail the following words', () {
    final r = matchRecitation(
        expectedTokens: tokens, heard: 'الحمد لله زيد العالمين', isFinal: true);
    expect(r.statuses[2], WordStatus.missed);
    expect(r.statuses[3], WordStatus.matched);
  });

  test('normalizeArabic strips marks and folds spelling variants', () {
    expect(normalizeArabic('ٱلْعَٰلَمِينَ'), normalizeArabic('العالمين'));
    expect(normalizeArabic('ٱللَّهِ'), normalizeArabic('الله'));
  });
}
