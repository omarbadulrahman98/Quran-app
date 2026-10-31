#!/usr/bin/env python3
"""
Build-time helper for the Madani Mushaf page view.

usage:  python3 fetch_qcf.py app

Creates
  app/assets/qcf/p001.ttf ... p604.ttf   (King Fahd Complex page fonts, QCF V1)
  app/assets/quran_pages.json            (page -> line -> words -> glyph codes)

Data comes from the public Quran.com API (v4).  If a download fails the script
prints a clear message and exits with an error so the build stops (instead of
shipping a broken Mushaf).
"""
import json
import os
import sys
import time
import urllib.request
import urllib.error
from concurrent.futures import ThreadPoolExecutor

APP = sys.argv[1] if len(sys.argv) > 1 else "app"
QCF_DIR = os.path.join(APP, "assets", "qcf")
PAGES_JSON = os.path.join(APP, "assets", "quran_pages.json")
os.makedirs(QCF_DIR, exist_ok=True)

API = "https://api.quran.com/api/v4/verses/by_page/{p}"
FONT_URLS = [
    "https://verses.quran.com/fonts/quran/hafs/v1/ttf/p{p}.ttf",
    "https://static.qurancdn.com/fonts/quran/hafs/v1/ttf/p{p}.ttf",
]
FONT_WOFF2 = [
    "https://verses.quran.com/fonts/quran/hafs/v1/woff2/p{p}.woff2",
    "https://static.qurancdn.com/fonts/quran/hafs/v1/woff2/p{p}.woff2",
]
UA = {"User-Agent": "Mozilla/5.0 (quran-kurdish build)"}


def get(url, tries=4):
    last = None
    for i in range(tries):
        try:
            req = urllib.request.Request(url, headers=UA)
            with urllib.request.urlopen(req, timeout=60) as r:
                return r.read()
        except Exception as e:  # noqa: BLE001
            last = e
            time.sleep(1.5 * (i + 1))
    raise RuntimeError("download failed: %s (%s)" % (url, last))


# ------------------------------------------------------------------ fonts
def woff2_to_ttf(data):
    from fontTools.ttLib import TTFont  # pip install fonttools brotli
    import io

    f = TTFont(io.BytesIO(data))
    f.flavor = None
    out = io.BytesIO()
    f.save(out)
    return out.getvalue()


def fetch_font(p):
    dst = os.path.join(QCF_DIR, "p%03d.ttf" % p)
    if os.path.exists(dst) and os.path.getsize(dst) > 2000:
        return
    errs = []
    for u in FONT_URLS:
        try:
            data = get(u.format(p=p), tries=2)
            if data[:4] in (b"\x00\x01\x00\x00", b"true", b"OTTO"):
                open(dst, "wb").write(data)
                return
            errs.append("not a ttf: " + u.format(p=p))
        except Exception as e:  # noqa: BLE001
            errs.append(str(e))
    for u in FONT_WOFF2:
        try:
            data = get(u.format(p=p), tries=2)
            open(dst, "wb").write(woff2_to_ttf(data))
            return
        except Exception as e:  # noqa: BLE001
            errs.append(str(e))
    raise RuntimeError("font p%d failed:\n  %s" % (p, "\n  ".join(errs)))


# ------------------------------------------------------------------ data
def fetch_page(p):
    words = []
    page_no = 1
    while True:
        url = (API.format(p=p)
               + "?words=true&word_fields=code_v1,v1_page,line_number,page_number"
               + "&per_page=50&mushaf=2&page=%d" % page_no)
        try:
            j = json.loads(get(url))
        except RuntimeError:
            # some deployments reject mushaf=2: retry without it
            j = json.loads(get(url.replace("&mushaf=2", "")))
        for v in j["verses"]:
            s, a = [int(x) for x in v["verse_key"].split(":")]
            for w in v["words"]:
                code = w.get("code_v1")
                if not code:
                    continue
                words.append({
                    "code": code,
                    "s": s,
                    "a": a,
                    "pos": int(w["position"]),
                    "end": 1 if w.get("char_type_name") == "end" else 0,
                    "line": int(w["line_number"]),
                    "fp": int(w.get("v1_page") or w.get("page_number") or p),
                })
        nxt = (j.get("pagination") or {}).get("next_page")
        if not nxt:
            break
        page_no = nxt
    return words


def build_page(p, words):
    """-> {"n": p, "slots": 8|15, "rows": [[kind, surah, words], ...]}

    kind 0 = text line, 1 = surah banner, 2 = bismillah line.
    Rows are in top-to-bottom order; the API line numbers are only used to
    order and group the words (so it does not matter whether they count the
    banner / bismillah lines or not).
    """
    slots = 8 if p <= 2 else 15
    by_line = {}
    for w in words:
        by_line.setdefault(w["line"], []).append(w)
    rows = []
    for ln in sorted(by_line):
        ws = sorted(by_line[ln], key=lambda x: (x["a"], x["pos"]))
        starts = [w for w in ws if w["a"] == 1 and w["pos"] == 1]
        if starts:
            s = starts[0]["s"]
            rows.append([1, s, []])
            if s not in (1, 9):
                rows.append([2, s, []])
        rows.append([0, 0, [[w["code"], w["s"], w["a"], w["pos"], w["end"]]
                            for w in ws]])
    if len(rows) != slots:
        print("warning: page %d has %d rows (expected %d)" % (p, len(rows), slots))
    fp = {w["fp"] for w in words}
    if fp != {p}:
        print("note: page %d uses font pages %s" % (p, sorted(fp)))
    return {"n": p, "slots": slots, "rows": rows}


def main():
    t0 = time.time()
    print("downloading 604 fonts ...")
    with ThreadPoolExecutor(max_workers=8) as ex:
        list(ex.map(fetch_font, range(1, 605)))
    print("fonts ok (%.0fs)" % (time.time() - t0))

    print("downloading page data ...")
    with ThreadPoolExecutor(max_workers=6) as ex:
        raw = list(ex.map(fetch_page, range(1, 605)))
    pages = []
    bad = 0
    for p, words in enumerate(raw, start=1):
        if not words:
            raise RuntimeError("page %d has no words" % p)
        pg = build_page(p, words)
        if len(pg["rows"]) != pg["slots"]:
            bad += 1
        pages.append(pg)
    # codes of the Bismillah (verse 1:1) in the font of page 1
    bism = [w["code"] for w in raw[0] if w["s"] == 1 and w["a"] == 1 and not w["end"]]
    out = {"v": 1, "bism": bism, "pages": pages}
    with open(PAGES_JSON, "w", encoding="utf-8") as f:
        json.dump(out, f, ensure_ascii=False, separators=(",", ":"))
    print("quran_pages.json: %d KB, %d pages (%d with an unexpected row count)" %
          (os.path.getsize(PAGES_JSON) // 1024, len(pages), bad))


if __name__ == "__main__":
    try:
        main()
    except Exception as e:  # noqa: BLE001
        print("ERROR:", e)
        sys.exit(1)
