#!/usr/bin/env python3
"""bangv22.sqlite -> prayer_times.json  (the data file the app loads at start)

Usage:  python3 convert_bang_db.py bangv22.sqlite prayer_times.json

Each city table has: D (MM-DD), bayani (fajr), xorhalatn (sunrise), niwaro
(dhuhr), asr, eywara (maghrib), esha. Times may be written in 12-hour style
(02:39 for 14:39); they are converted to 24-hour. Rows that are duplicated with
different values, malformed, or not in increasing order are NOT written; they
are listed in the report so you can check them against the official timetable.
"""
import json, re, sqlite3, sys

# table name (lower case) -> Kurdish city name used in the app (PrayCity.ku).
# Only Kurdistan Region cities are kept; any other table is skipped.
NAMES = {
    'hawler': 'هەولێر', 'hewler': 'هەولێر', 'erbil': 'هەولێر', 'arbil': 'هەولێر',
    'slemani': 'سلێمانی', 'sulaymaniyah': 'سلێمانی', 'sulaimani': 'سلێمانی', 'sulaymaniya': 'سلێمانی',
    'duhok': 'دهۆک', 'dihok': 'دهۆک', 'dohuk': 'دهۆک',
    'kirkuk': 'کەرکووک', 'karkuk': 'کەرکووک',
    'halabja': 'هەڵەبجە', 'helebje': 'هەڵەبجە',
    'shahrazur': 'شارەزور', 'sharazur': 'شارەزور', 'shahrizor': 'شارەزور', 'sharazoor': 'شارەزور',
    'saidsadiq': 'سەیدسادق', 'sayidsadiq': 'سەیدسادق', 'sidsadiq': 'سەیدسادق',
    'penjwen': 'پێنجوێن', 'penjwin': 'پێنجوێن', 'penjween': 'پێنجوێن',
    'arbat': 'عەربەت', 'arabat': 'عەربەت',
    'ranya': 'ڕانیە', 'rania': 'ڕانیە', 'ranye': 'ڕانیە',
    'zakho': 'زاخۆ', 'zaxo': 'زاخۆ',
    'kalar': 'کەلار',
    'darbandikhan': 'دەربەندیخان', 'darbandixan': 'دەربەندیخان', 'derbendikhan': 'دەربەندیخان',
    'kifri': 'کفری', 'kfri': 'کفری',
    'bazian': 'بازیان', 'bazyan': 'بازیان',
    'chamchamal': 'چەمچەماڵ', 'chamchamall': 'چەمچەماڵ',
    'dukan': 'دوکان', 'dokan': 'دوکان',
    'qaladze': 'قەڵادزێ', 'qaladiza': 'قەڵادزێ', 'qalat': 'قەڵادزێ', 'qaladzey': 'قەڵادزێ',
    'koya': 'کۆیە', 'koye': 'کۆیە', 'koysinjaq': 'کۆیە',
    'soran': 'سۆران',
}
# approximate centre of each city (only used as a fallback if a day is missing)
COORDS = {
    'هەولێر': (36.1912, 44.0092), 'سلێمانی': (35.5613, 45.4308), 'دهۆک': (36.8672, 42.9989),
    'کەرکووک': (35.4681, 44.3922), 'هەڵەبجە': (35.1778, 45.9861), 'شارەزور': (35.3500, 45.7500),
    'سەیدسادق': (35.3600, 45.8850), 'پێنجوێن': (35.6200, 45.9500), 'عەربەت': (35.4450, 45.5700),
    'ڕانیە': (36.2547, 44.8836), 'زاخۆ': (37.1439, 42.6872), 'کەلار': (34.6275, 45.3197),
    'دەربەندیخان': (35.1100, 45.6967), 'کفری': (34.6867, 44.9667), 'بازیان': (35.5800, 45.1000),
    'چەمچەماڵ': (35.5292, 44.8325), 'دوکان': (35.9500, 44.9833), 'قەڵادزێ': (36.1833, 45.1333),
    'کۆیە': (36.0833, 44.6333), 'سۆران': (36.6500, 44.5333),
}
COLS = ['bayani', 'xorhalatn', 'niwaro', 'asr', 'eywara', 'esha']
T = re.compile(r'(\d{1,2})\s*[:.]\s*(\d{2})')


def to_min(v, col):
    m = T.search(str(v or ''))
    if not m:
        return None
    h, mi = int(m.group(1)), int(m.group(2))
    if mi > 59 or h > 23:
        return None
    pm = 'p' in str(v).lower()
    if pm and h < 12:
        h += 12
    # 12-hour style tables: afternoon prayers are written without PM
    if col == 'niwaro' and h < 10:
        h += 12
    if col in ('asr', 'eywara', 'esha') and h < 12:
        h += 12
    return h * 60 + mi


def main(db_path, out_path):
    db = sqlite3.connect(db_path)
    tables = [r[0] for r in db.execute("SELECT name FROM sqlite_master WHERE type='table'")]
    out, report = {}, []
    for t in tables:
        cols = {r[1].lower(): r[1] for r in db.execute(f'PRAGMA table_info("{t}")')}
        if 'd' not in cols or not all(c in cols for c in COLS):
            report.append(f'[skip] table {t}: columns {sorted(cols)} do not match')
            continue
        key = re.sub(r'[^a-z]', '', t.lower())
        ku = NAMES.get(key) or NAMES.get(t.lower())
        if not ku:
            report.append(f'[skipped] table "{t}": not in the Kurdistan list (if it should be, add its name to NAMES)')
            continue
        days, seen = {}, {}
        sel = ', '.join(f'"{cols[c]}"' for c in ['d'] + COLS)
        for row in db.execute(f'SELECT {sel} FROM "{t}"'):
            dm = re.match(r'\s*(\d{1,2})\s*[-/]\s*(\d{1,2})', str(row[0] or ''))
            if not dm:
                report.append(f'[bad date] {ku}: {row[0]!r}')
                continue
            d = f'{int(dm.group(1)):02d}-{int(dm.group(2)):02d}'
            mins = [to_min(v, c) for v, c in zip(row[1:], COLS)]
            if None in mins or any(mins[i] >= mins[i + 1] for i in range(5)):
                report.append(f'[bad row] {ku} {d}: {list(row[1:])}')
                seen[d] = 'bad'
                days.pop(d, None)
                continue
            val = [f'{m // 60:02d}:{m % 60:02d}' for m in mins]
            if d in seen:
                if seen[d] != val:
                    report.append(f'[conflict] {ku} {d}: {seen[d]} vs {val} (first kept)')
                continue
            seen[d] = val
            days[d] = val
        entry = {'days': dict(sorted(days.items()))}
        if ku in COORDS:
            entry['lat'], entry['lng'] = COORDS[ku]
        out[ku] = entry
        missing = 366 - len(days)
        report.append(f'{ku}: {len(days)} days' + (f' ({missing} missing -> engine)' if missing else ''))
    with open(out_path, 'w', encoding='utf-8') as f:
        json.dump({'cities': out}, f, ensure_ascii=False, separators=(',', ':'))
    print('\n'.join(report))


if __name__ == '__main__':
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    main(sys.argv[1], sys.argv[2])
