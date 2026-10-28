#!/usr/bin/env python3
"""Patches the android project made by `flutter create` (run: python3 patch_android.py app).
Safe to run twice: every change is skipped when it is already there."""
import re
import sys
from pathlib import Path

root = Path(sys.argv[1] if len(sys.argv) > 1 else 'app')
mf = root / 'android/app/src/main/AndroidManifest.xml'
s = mf.read_text(encoding='utf-8')

# namespace needed for tools:ignore
if 'xmlns:tools' not in s:
    s = s.replace('<manifest ', '<manifest xmlns:tools="http://schemas.android.com/tools" ', 1)

# permissions: internet (audio streaming), microphone (live recitation check),
# wake-lock / foreground service (background playback)
for perm in [
    'android.permission.INTERNET',
    'android.permission.RECORD_AUDIO',
    'android.permission.WAKE_LOCK',
    'android.permission.FOREGROUND_SERVICE',
    'android.permission.FOREGROUND_SERVICE_MEDIA_PLAYBACK',
]:
    if f'"{perm}"' not in s:
        s = s.replace('<application', f'<uses-permission android:name="{perm}"/>\n    <application', 1)

# Android 11+: the app must be allowed to see the speech recognition service
intent = '<intent><action android:name="android.speech.RecognitionService"/></intent>'
if 'android.speech.RecognitionService' not in s:
    if '</queries>' in s:
        s = s.replace('</queries>', '    ' + intent + '\n    </queries>', 1)
    else:
        s = s.replace('<application', f'<queries>\n        {intent}\n    </queries>\n    <application', 1)

# app name
s = re.sub(r'android:label="[^"]*"', 'android:label="Quran Kurdish"', s, count=1)

# just_audio_background / audio_service
s = s.replace('android:name=".MainActivity"',
              'android:name="com.ryanheise.audioservice.AudioServiceActivity"', 1)
if 'com.ryanheise.audioservice.AudioService"' not in s:
    block = '''        <service android:name="com.ryanheise.audioservice.AudioService"
            android:foregroundServiceType="mediaPlayback"
            android:exported="true" tools:ignore="Instantiatable">
            <intent-filter>
                <action android:name="android.media.browse.MediaBrowserService"/>
            </intent-filter>
        </service>
        <receiver android:name="com.ryanheise.audioservice.MediaButtonReceiver"
            android:exported="true" tools:ignore="Instantiatable">
            <intent-filter>
                <action android:name="android.intent.action.MEDIA_BUTTON"/>
            </intent-filter>
        </receiver>
'''
    s = s.replace('</application>', block + '    </application>', 1)

mf.write_text(s, encoding='utf-8')
print('AndroidManifest.xml patched')

# sherpa_onnx / record need a newer minSdk than flutter's default
for name in ('build.gradle.kts', 'build.gradle'):
    gf = root / 'android/app' / name
    if not gf.exists():
        continue
    g = gf.read_text(encoding='utf-8')
    g2 = re.sub(r'minSdk\s*=\s*flutter\.minSdkVersion', 'minSdk = 24', g)
    g2 = re.sub(r'minSdkVersion\s+flutter\.minSdkVersion', 'minSdkVersion 24', g2)
    if g2 != g:
        gf.write_text(g2, encoding='utf-8')
        print(name, 'minSdk set to 24')
