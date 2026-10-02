#!/usr/bin/env python3
"""把縮時繪圖影片拆成畫面、去除相似畫面，輸出關鍵幀與 keyframes.json。

流程：
  1. ffmpeg 依 --fps 抽幀，縮成 64x64 灰階
  2. 跟「上一張保留的畫面」比較平均差異，小於 --threshold 就丟掉
  3. 保留數量超過 --max-frames 時，依累積變化量平均挑選
  4. 用原解析度（或 --size）輸出選中的畫面

只需要 ffmpeg / ffprobe 和 Python 標準函式庫。

範例：
  python tools/video_to_stages.py samples/video/timelapse.mp4 --out out/keyframes \\
      --stage-marks "0:sketch,3.6:lineart,6.4:color,8.4:shading"
"""

from __future__ import annotations

import argparse
import bisect
import json
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

FORMAT = "draw-reasoning/keyframes"
FORMAT_VERSION = 1
THUMB = 64
KNOWN_STAGES = ("sketch", "lineart", "color", "shading")
SELECT_CHUNK = 100  # 每次 ffmpeg select 最多挑幾張，避免表達式太長


def run(cmd: list[str], **kwargs) -> subprocess.CompletedProcess:
    try:
        return subprocess.run(cmd, check=True, **kwargs)
    except FileNotFoundError:
        sys.exit(f"找不到 {cmd[0]}，請先安裝 ffmpeg")
    except subprocess.CalledProcessError as e:
        err = e.stderr.decode(errors="replace") if isinstance(e.stderr, bytes) else (e.stderr or "")
        sys.exit(f"{cmd[0]} 執行失敗：\n{err.strip()}")


def probe(video: Path) -> dict:
    out = run(
        ["ffprobe", "-v", "error", "-select_streams", "v:0",
         "-show_entries", "stream=width,height:format=duration", "-of", "json", str(video)],
        capture_output=True,
    ).stdout
    info = json.loads(out)
    if not info.get("streams"):
        sys.exit(f"{video} 裡沒有影像串流")
    stream = info["streams"][0]
    duration = info.get("format", {}).get("duration")
    return {
        "width": stream.get("width"),
        "height": stream.get("height"),
        "duration": round(float(duration), 3) if duration else None,
    }


def base_filters(args) -> list[str]:
    filters = []
    if args.crop:
        filters.append(f"crop={args.crop}")
    filters.append(f"fps={args.fps}")
    return filters


def read_thumbnails(video: Path, filters: list[str]) -> list[bytes]:
    vf = ",".join(filters + [f"scale={THUMB}:{THUMB}:flags=area", "format=gray"])
    raw = run(
        ["ffmpeg", "-nostdin", "-v", "error", "-i", str(video), "-vf", vf,
         "-f", "rawvideo", "-pix_fmt", "gray", "-"],
        capture_output=True,
    ).stdout
    size = THUMB * THUMB
    return [raw[i:i + size] for i in range(0, len(raw) - size + 1, size)]


def frame_diff(a: bytes, b: bytes) -> float:
    """平均絕對差異，0（完全相同）～1。"""
    return sum(abs(x - y) for x, y in zip(a, b)) / (len(a) * 255)


def select_frames(thumbs: list[bytes], threshold: float, max_frames: int) -> list[int]:
    n = len(thumbs)
    kept = [0]
    for i in range(1, n):
        if frame_diff(thumbs[i], thumbs[kept[-1]]) >= threshold:
            kept.append(i)
    # 一定保留最後一張（完成圖）：和最後保留的畫面有差異時，用它取代
    last = n - 1
    if kept[-1] != last and frame_diff(thumbs[last], thumbs[kept[-1]]) > 0:
        if len(kept) > 1:
            kept[-1] = last
        else:
            kept.append(last)

    if len(kept) <= max_frames:
        return kept

    # 依累積變化量平均挑選，頭尾一定保留
    cumulative = [0.0]
    for i in range(1, n):
        cumulative.append(cumulative[-1] + frame_diff(thumbs[i], thumbs[i - 1]))
    values = [cumulative[k] for k in kept]
    start, total = values[0], values[-1] - values[0]
    chosen: list[int] = []
    for k in range(max_frames):
        target = start + total * k / (max_frames - 1)
        j = bisect.bisect_left(values, target)
        if j > 0 and (j == len(values) or target - values[j - 1] <= values[j] - target):
            j -= 1
        if not chosen or kept[j] > chosen[-1]:
            chosen.append(kept[j])
    if chosen[-1] != kept[-1]:
        chosen.append(kept[-1])
    return chosen


def extract_frames(video: Path, filters: list[str], indices: list[int], size: int, dest: Path) -> list[Path]:
    """依抽幀後的序號輸出 PNG，回傳依 indices 順序的檔案路徑。"""
    scale = []
    if size > 0:
        scale = [f"scale=w='min({size},iw)':h='min({size},ih)':force_original_aspect_ratio=decrease"]
    outputs: list[Path] = []
    with tempfile.TemporaryDirectory() as tmp:
        for c in range(0, len(indices), SELECT_CHUNK):
            chunk = indices[c:c + SELECT_CHUNK]
            expr = "+".join(f"eq(n,{i})" for i in chunk)
            vf = ",".join(filters + [f"select='{expr}'"] + scale)
            pattern = Path(tmp) / f"c{c:06d}_%06d.png"
            run(["ffmpeg", "-nostdin", "-v", "error", "-i", str(video), "-vf", vf,
                 "-fps_mode", "passthrough", str(pattern)], capture_output=True)
            produced = sorted(Path(tmp).glob(f"c{c:06d}_*.png"))
            if len(produced) != len(chunk):
                sys.exit(f"預期輸出 {len(chunk)} 張，實際只有 {len(produced)} 張")
            for src in produced:
                target = dest / f"{len(outputs) + 1:06d}.png"
                shutil.move(str(src), target)
                outputs.append(target)
    return outputs


def parse_stage_marks(text: str | None) -> list[tuple[float, str]]:
    if not text:
        return []
    marks = []
    for item in text.split(","):
        item = item.strip()
        if not item:
            continue
        sec, _, stage = item.partition(":")
        if not stage:
            sys.exit(f"--stage-marks 格式錯誤：{item!r}（應為 秒數:階段）")
        if stage not in KNOWN_STAGES:
            print(f"注意：階段 {stage!r} 不在 {KNOWN_STAGES} 之中", file=sys.stderr)
        marks.append((float(sec), stage))
    return sorted(marks)


def stage_at(marks: list[tuple[float, str]], t: float) -> str | None:
    stage = None
    for sec, name in marks:
        if sec <= t + 1e-9:
            stage = name
    return stage


def main() -> None:
    ap = argparse.ArgumentParser(description="把縮時影片拆成去重後的關鍵幀")
    ap.add_argument("video", type=Path, help="縮時影片")
    ap.add_argument("--out", type=Path, required=True, help="輸出資料夾（會產生 keyframes/ 和 keyframes.json）")
    ap.add_argument("--fps", type=float, default=2.0, help="每秒抽幾張來比較（預設 2）")
    ap.add_argument("--threshold", type=float, default=0.003,
                    help="相似度門檻：和上一張保留畫面的平均差異（0～1）低於此值就丟掉（預設 0.003）")
    ap.add_argument("--max-frames", type=int, default=64, help="最多輸出幾張（預設 64，至少 2）")
    ap.add_argument("--size", type=int, default=1024, help="輸出畫面長邊上限，0 代表原尺寸（預設 1024）")
    ap.add_argument("--crop", help="先裁切出畫布區域，ffmpeg crop 格式 w:h:x:y（螢幕錄影時用）")
    ap.add_argument("--stage-marks", help='依秒數標階段，例如 "0:sketch,95:lineart,200:color"')
    ap.add_argument("--ref", help="來源名稱（預設為影片檔名）")
    ap.add_argument("--author", default="", help="作者")
    ap.add_argument("--prompt", help="這支影片在畫什麼（文字提示詞），會寫進 keyframes.json")
    ap.add_argument("--consent", choices=["self", "permission"], default="self",
                    help="授權：self 自己的作品／permission 已取得同意（預設 self）")
    ap.add_argument("--overwrite", action="store_true", help="輸出資料夾已有關鍵幀時覆蓋")
    args = ap.parse_args()

    if not args.video.is_file():
        sys.exit(f"找不到影片：{args.video}")
    if args.max_frames < 2:
        sys.exit("--max-frames 至少要 2")
    if args.fps <= 0:
        sys.exit("--fps 必須大於 0")

    frames_dir = args.out / "keyframes"
    manifest_path = args.out / "keyframes.json"
    if frames_dir.exists() and any(frames_dir.iterdir()):
        if not args.overwrite:
            sys.exit(f"{frames_dir} 已有檔案，要覆蓋請加 --overwrite")
        shutil.rmtree(frames_dir)
    frames_dir.mkdir(parents=True, exist_ok=True)

    info = probe(args.video)
    filters = base_filters(args)
    thumbs = read_thumbnails(args.video, filters)
    if not thumbs:
        sys.exit("影片沒有抽出任何畫面")
    indices = select_frames(thumbs, args.threshold, args.max_frames)
    files = extract_frames(args.video, filters, indices, args.size, frames_dir)

    marks = parse_stage_marks(args.stage_marks)
    frames = []
    prev = None
    for idx, path in zip(indices, files):
        t = round(idx / args.fps, 3)
        frames.append({
            "file": f"keyframes/{path.name}",
            "index": idx,
            "t": t,
            "diff": round(frame_diff(thumbs[idx], thumbs[prev]), 5) if prev is not None else 0.0,
            "stage": stage_at(marks, t),
        })
        prev = idx

    manifest = {
        "format": FORMAT,
        "version": FORMAT_VERSION,
        "source": {
            "kind": "video",
            "ref": args.ref or args.video.stem,
            "file": args.video.name,
            "author": args.author,
            "consent": args.consent,
        },
        "video": info,
        "params": {
            "fps": args.fps,
            "threshold": args.threshold,
            "max_frames": args.max_frames,
            "size": args.size,
            "crop": args.crop,
            "stage_marks": args.stage_marks,
        },
        "prompt": (args.prompt or "").strip() or None,
        "sampled_frames": len(thumbs),
        "frames": frames,
    }
    manifest_path.write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"抽樣 {len(thumbs)} 張 → 輸出 {len(frames)} 張關鍵幀到 {frames_dir}")
    print(f"清單：{manifest_path}")


if __name__ == "__main__":
    main()
