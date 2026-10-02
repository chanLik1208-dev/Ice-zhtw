#!/usr/bin/env python3
"""把 Google Quick, Draw! 資料集轉成 draw-reasoning 的 session 格式（每行一個 session 的 .jsonl.gz）。

Quick, Draw! 有 345 類、約 5000 萬張「一筆一筆畫出來」的塗鴉，授權為 CC BY 4.0：
  https://github.com/googlecreativelab/quickdraw-dataset
使用時必須註明出處（attribution），每個 session 的 source 裡都有寫。

邊下載邊轉換，原始檔不會存到磁碟；每一類輸出一個檔案，已完成的類別重跑時會跳過（可中斷續傳）。
只用 Python 標準函式庫。

範例：
  # 每類 100 張，先試試看
  python tools/quickdraw_to_sessions.py --categories all --per-category 100 --out data/quickdraw
  # 全部（約 5000 萬張，建議在 GCE 上跑，輸出再同步到 GCS）
  python tools/quickdraw_to_sessions.py --categories all --workers 16 --out /mnt/data/quickdraw
  # 已經下載好的 ndjson
  python tools/quickdraw_to_sessions.py --input cat.ndjson --out data/quickdraw
"""

from __future__ import annotations

import argparse
import gzip
import json
import sys
import time
import urllib.parse
import urllib.request
from concurrent.futures import ProcessPoolExecutor, as_completed
from datetime import datetime, timezone
from pathlib import Path

CATEGORIES_URL = "https://raw.githubusercontent.com/googlecreativelab/quickdraw-dataset/master/categories.txt"
DATA_URL = "https://storage.googleapis.com/quickdraw_dataset/full/{variant}/{word}.ndjson"
LICENSE = "CC BY 4.0"
ATTRIBUTION = "Quick, Draw! dataset by Google (https://quickdraw.withgoogle.com/data), CC BY 4.0"

SESSION_FORMAT = "draw-reasoning/session"
SESSION_VERSION = 2
CANVAS_SIZE = 1024
XY_DIGITS = 4


def slug(word: str) -> str:
    return word.strip().lower().replace(" ", "_")


def parse_timestamp(text: str | None) -> str | None:
    # 例："2017-03-02 23:25:10.07453 UTC"
    if not text:
        return None
    try:
        dt = datetime.strptime(text.replace(" UTC", ""), "%Y-%m-%d %H:%M:%S.%f")
    except ValueError:
        return None
    return dt.replace(tzinfo=timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z")


def convert(record: dict, variant: str, width: float, margin: float, prompt_template: str) -> dict | None:
    """一張 Quick, Draw! 塗鴉 → 一個 session。座標依外框置中縮放到 [margin, 1 - margin]。"""
    strokes = [s for s in record.get("drawing", []) if s and s[0]]
    if not strokes:
        return None
    xs = [x for s in strokes for x in s[0]]
    ys = [y for s in strokes for y in s[1]]
    min_x, min_y = min(xs), min(ys)
    span = max(max(xs) - min_x, max(ys) - min_y, 1e-6)
    scale = (1 - 2 * margin) / span
    off_x = (1 - (max(xs) - min_x) * scale) / 2
    off_y = (1 - (max(ys) - min_y) * scale) / 2
    has_time = variant == "raw" and all(len(s) >= 3 for s in strokes)

    actions = []
    for i, s in enumerate(strokes, start=1):
        ts = s[2] if has_time else [None] * len(s[0])
        points = [
            [round(off_x + (x - min_x) * scale, XY_DIGITS), round(off_y + (y - min_y) * scale, XY_DIGITS),
             0.5, int(t) if t is not None else None]
            for x, y, t in zip(s[0], s[1], ts)
        ]
        actions.append({
            "id": i, "type": "stroke", "points": points, "smooth": None, "color": "#222222",
            "width": width, "opacity": 1, "tolerance": None, "target_id": None, "stage": "sketch",
            "pointer": None, "t": points[0][3], "zoom": None, "caption": None,
        })

    word = record.get("word", "")
    return {
        "format": SESSION_FORMAT,
        "version": SESSION_VERSION,
        "session_id": f"qd-{record.get('key_id', '')}",
        "created_at": parse_timestamp(record.get("timestamp")),
        "canvas": {"width": CANVAS_SIZE, "height": CANVAS_SIZE, "background": "#ffffff"},
        "source": {
            "kind": "quickdraw",
            "author": "Quick, Draw! players",
            "consent": "open-license",
            "license": LICENSE,
            "attribution": ATTRIBUTION,
            "variant": variant,
            "word": word,
            "countrycode": record.get("countrycode"),
            "recognized": record.get("recognized"),
        },
        "settings": {},
        "stages": ["sketch"],
        "prompt_events": [{"after_action_id": 0, "prompt": prompt_template.format(word=word)}],
        "stage_events": [{"after_action_id": 0, "stage": "sketch", "note": ""}],
        "snapshots": [],
        "actions": actions,
    }


def open_lines(source: str):
    """本機檔案或網址，一行一行讀（網址是串流，不會整個下載）。"""
    if source.startswith("http"):
        resp = urllib.request.urlopen(source, timeout=120)
        return resp, (line.decode("utf-8") for line in resp)
    opener = gzip.open if source.endswith(".gz") else open
    f = opener(source, "rt", encoding="utf-8")
    return f, f


def process(name: str, source: str, out_dir: str, opts: dict) -> dict:
    out = Path(out_dir) / f"{slug(name)}.jsonl.gz"
    if out.exists():
        return {"category": name, "skipped": True}
    tmp = out.with_suffix(".tmp")
    kept = seen = 0
    started = time.time()
    for attempt in range(4):
        try:
            handle, lines = open_lines(source)
            kept = seen = 0
            with gzip.open(tmp, "wt", encoding="utf-8") as f:
                for line in lines:
                    if not line.strip():
                        continue
                    seen += 1
                    record = json.loads(line)
                    if opts["recognized_only"] and not record.get("recognized", True):
                        continue
                    session = convert(record, opts["variant"], opts["width"], opts["margin"], opts["prompt"])
                    if session is None:
                        continue
                    f.write(json.dumps(session, ensure_ascii=False, separators=(",", ":")) + "\n")
                    kept += 1
                    if opts["per_category"] and kept >= opts["per_category"]:
                        break
            handle.close()
            break
        except (OSError, ValueError) as e:  # 網路中斷時重試
            if attempt == 3:
                tmp.unlink(missing_ok=True)
                return {"category": name, "error": str(e)}
            time.sleep(2 ** (attempt + 1))
    tmp.rename(out)
    return {"category": name, "file": out.name, "sessions": kept, "read": seen,
            "seconds": round(time.time() - started, 1)}


def main() -> None:
    ap = argparse.ArgumentParser(description="把 Quick, Draw! 轉成 draw-reasoning 的 session 分片")
    src = ap.add_mutually_exclusive_group(required=True)
    src.add_argument("--categories", help='類別，逗號分隔（例如 "cat,dog"），或 all 代表全部 345 類')
    src.add_argument("--input", nargs="+", help="已經下載好的 .ndjson / .ndjson.gz 檔")
    ap.add_argument("--out", type=Path, required=True, help="輸出資料夾")
    ap.add_argument("--variant", choices=["raw", "simplified"], default="raw",
                    help="raw 有每個點的時間（預設）；simplified 檔案小很多但沒有時間")
    ap.add_argument("--per-category", type=int, default=0, help="每類最多幾張，0 代表全部（預設）")
    ap.add_argument("--include-unrecognized", action="store_true",
                    help="也收沒被遊戲辨識出來的塗鴉（預設只收辨識成功的）")
    ap.add_argument("--width", type=float, default=0.006, help="線寬，以畫布寬度為 1（預設 0.006）")
    ap.add_argument("--margin", type=float, default=0.1, help="四周留白比例（預設 0.1）")
    ap.add_argument("--prompt", default="{word}", help='提示詞樣板（預設 "{word}"，例如 "a doodle of a {word}"）')
    ap.add_argument("--workers", type=int, default=4, help="同時處理幾類（預設 4）")
    args = ap.parse_args()

    out_dir = args.out / args.variant
    out_dir.mkdir(parents=True, exist_ok=True)
    opts = {
        "variant": args.variant, "per_category": args.per_category, "recognized_only": not args.include_unrecognized,
        "width": args.width, "margin": args.margin, "prompt": args.prompt,
    }

    if args.input:
        jobs = [(Path(p).name.split(".")[0], p) for p in args.input]
    else:
        if args.categories == "all":
            words = urllib.request.urlopen(CATEGORIES_URL, timeout=60).read().decode().splitlines()
        else:
            words = args.categories.split(",")
        words = [w.strip() for w in words if w.strip()]
        jobs = [(w, DATA_URL.format(variant=args.variant, word=urllib.parse.quote(w))) for w in words]

    results = []
    with ProcessPoolExecutor(max_workers=max(1, args.workers)) as pool:
        futures = [pool.submit(process, name, source, str(out_dir), opts) for name, source in jobs]
        for i, fut in enumerate(as_completed(futures), start=1):
            r = fut.result()
            results.append(r)
            if r.get("error"):
                status = f"失敗：{r['error']}"
            elif r.get("skipped"):
                status = "已存在，略過"
            else:
                status = f"{r['sessions']} 張（{r['seconds']} 秒）"
            print(f"[{i}/{len(jobs)}] {r['category']}: {status}", flush=True)

    manifest_path = out_dir / "manifest.json"
    manifest = json.loads(manifest_path.read_text(encoding="utf-8")) if manifest_path.exists() else {"categories": {}}
    for r in results:
        if r.get("file"):
            manifest["categories"][r["category"]] = {"file": r["file"], "sessions": r["sessions"]}
    manifest.update({
        "format": "draw-reasoning/quickdraw-sessions",
        "variant": args.variant,
        "license": LICENSE,
        "attribution": ATTRIBUTION,
        "updated_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "total_sessions": sum(c["sessions"] for c in manifest["categories"].values()),
    })
    manifest_path.write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")

    failed = [r["category"] for r in results if r.get("error")]
    print(f"完成：{len(manifest['categories'])} 類、共 {manifest['total_sessions']} 張 → {out_dir}")
    if failed:
        print(f"失敗 {len(failed)} 類（重跑同一個指令會只補這些）：{', '.join(failed)}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
