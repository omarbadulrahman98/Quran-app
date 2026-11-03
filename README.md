# قورئانی پیرۆز (Quran Kurdish)

ئەپی قورئان بە کوردی (فلەتەر / ئەندرۆید). APK لە GitHub Actions دروست دەکرێت، نەک لەسەر کۆمپیوتەر.

## بیڵدکردن
Actions ← **Build APK** ← Run workflow. دوای ٥-١٥ خولەک APK لە **Releases** دەردەکەوێت.
لە لۆگی بیڵد بەشی `flutter analyze` ببینە (هەڵە و کۆدی بێ بەکارهێنان) و `flutter --version`.

## فایلەکان
| فایل | ڕۆڵ |
|---|---|
| `main.dart` | هەموو کۆدی ئەپەکە |
| `pubspec.yaml` | پاکێج و ئەسێتەکان |
| `.github/workflows/build.yml` | بیڵدی APK |
| `fetch_qcf.py` | لە کاتی بیڵد فۆنتەکانی ٦٠٤ پەڕەی موسحەف دادەبەزێنێت |
| `patch_android.py` | ڕێکخستنی ئەندرۆید (مۆڵەت، دەنگی بانگ) دوای `flutter create` |
| `quran.json` | دەقی قورئان و تەفسیر |
| `prayer_times.json` | خشتەی کاتەکانی بانگ بۆ شارەکان |
| `UthmanicHafs.ttf`, `surah_name.ttf`, `surah_titles.zip` | فۆنت و وێنەی ناوی سووڕەتەکان |
| `banner.jpg`, `banner2.jpg` | وێنەی پەڕەی سەرەکی / کاتەکانی بانگ |
| `adhan_*.mp3`, `azkar.mp3` | دەنگی بانگ و زیکر |

## کلیلی واژوو (یەکجار)
بۆ ئەوەی APKـی نوێ لەسەر کۆنەکە دابمەزرێت (بێ سڕینەوە): لە Settings ← Secrets and variables ← Actions دوو Secret زیاد بکە:
`KEYSTORE_BASE64` (ناوەڕۆکی فایلی KEYSTORE_BASE64.txt) و `KEYSTORE_PASSWORD`. کلیلەکە لە ڕیپۆ مەنێ و پاشەکەوتی بکە، ئەگەر ون بێت ناتوانیت ئەپەکە نوێ بکەیتەوە.

## یاساکان
- فایلێک زیاد بکەیت کە ئەپەکە بەکاری دەهێنێت، دەبێت لە `build.yml` بگوازرێتەوە بۆ `app/`.
- دوای یەکەم بیڵدی سەرکەوتوو `pubspec.lock` لە Release دابەزێنە و لە ڕیپۆ دایبنێ، بۆ ئەوەی وەشانی پاکێجەکان نەگۆڕێت.
