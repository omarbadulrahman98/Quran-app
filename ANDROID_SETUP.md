# ڕێکخستنی Android بۆ ئاگادارکردنەوەی بانگ

بەبێ ئەم ٤ هەنگاوە ئاگادارکردنەوەکان کار ناکەن. هیچکامیان لە `main.dart` نین.

## ١. pubspec.yaml
فایلی `pubspec.yaml`ی ناو ئەم فۆڵدەرە لەگەڵ فایلی خۆتدا بیگۆڕەوە (تەنها دوو دێڕی نوێ: `flutter_local_notifications` و `timezone`)، پاشان:

    flutter pub get

## ٢. android/app/src/main/AndroidManifest.xml

ئەمانە لە ناو `<manifest>` و **پێش** `<application>` دابنێ:

    <uses-permission android:name="android.permission.POST_NOTIFICATIONS"/>
    <uses-permission android:name="android.permission.RECEIVE_BOOT_COMPLETED"/>
    <uses-permission android:name="android.permission.VIBRATE"/>
    <uses-permission android:name="android.permission.SCHEDULE_EXACT_ALARM"/>

ئەمانە لە ناو `<application>` دابنێ (تەنها بۆ `<activity>`ەکە دانەنێ):

    <receiver android:exported="false"
        android:name="com.dexterous.flutterlocalnotifications.ScheduledNotificationReceiver" />
    <receiver android:exported="false"
        android:name="com.dexterous.flutterlocalnotifications.ScheduledNotificationBootReceiver">
        <intent-filter>
            <action android:name="android.intent.action.BOOT_COMPLETED"/>
            <action android:name="android.intent.action.MY_PACKAGE_REPLACED"/>
            <action android:name="android.intent.action.QUICKBOOT_POWERON" />
            <action android:name="com.htc.intent.action.QUICKBOOT_POWERON"/>
        </intent-filter>
    </receiver>

## ٣. android/app/build.gradle (یان build.gradle.kts)

Groovy:

    android {
        compileSdk = 34            // یان بەرزتر
        compileOptions {
            coreLibraryDesugaringEnabled true
            sourceCompatibility JavaVersion.VERSION_1_8
            targetCompatibility JavaVersion.VERSION_1_8
        }
    }
    dependencies {
        coreLibraryDesugaring 'com.android.tools:desugar_jdk_libs:2.0.4'
    }

Kotlin DSL:

    compileOptions { isCoreLibraryDesugaringEnabled = true }
    dependencies { coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.0.4") }

ئەگەر ڕیلیزی `minifyEnabled` بەکاردەهێنیت و ئاگادارکردنەوەکان تێکچوون، ئەم ڕێسایە بۆ `proguard-rules.pro` زیاد بکە:

    -keep class com.dexterous.flutterlocalnotifications.** { *; }

## ٤. دەنگی بانگ
فایلی دەنگی بانگم **نییە و دروستم نەکردووە**. خۆت فایلێکی mp3 کە مافی بەکارهێنانت هەیە بدۆزەرەوە و بیکە بە:

    android/app/src/main/res/raw/adhan.mp3

(ناوەکەی دەبێت وەک خۆی `adhan` بێت، بە پیتی بچووک و بێ بۆشایی.) ئەگەر فایلەکە نەبێت، هەڵبژاردنی «دەنگی بانگ» بێ دەنگ یان بە دەنگی ئاسایی دەبێت.

## تاقیکردنەوە (لەسەر مۆبایلی ڕاستەقینە)
1. ئەپەکە دابمەزرێنە، لە لاپەڕەی بانگ، زەنگی نوێژێک بکە بە «دەنگی بانگ» و مۆڵەتەکان قبوڵ بکە (ئاگادارکردنەوە + «Alarms & reminders»).
2. زەنگی هەمان نوێژ بۆ ٢ خولەک دوای ئێستا ڕێکبخە: هەموو ڕۆژێک ئەو کاتانەی `PrayerCalc` دەیدات ئاگادارکردنەوە دەبێت. بۆ تاقیکردنەوەی خێرا کاتی مۆبایل بگۆڕە بۆ نزیک نوێژێک.
3. ئەپەکە بە تەواوی دابخە (swipe) و چاوەڕێ بکە: دەبێت بانگ بدات.
4. مۆبایلەکە ڕیستارت بکە بێ کردنەوەی ئەپ: ئاگادارکردنەوەکان دەبێت بمێننەوە.
5. شار یان حەنەفی/شافیعی بگۆڕە و دووبارە سەیر بکە: ئاگادارکردنەوەکان بە کاتی نوێ دەبن.

تێبینی: لەسەر Xiaomi/Samsung/Oppo ڕەنگە «Battery optimization» یان «Autostart» ئاگادارکردنەوەکان دوابخات؛ ئەپەکە لەو لیستە دەربهێنە.
