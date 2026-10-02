#!/usr/bin/env python3
"""把 recorder 匯出的資料和影片關鍵幀統一轉成 dataset.jsonl。

每一筆是（前一張畫布, 動作或下一張畫布, 階段標籤, 來源）：
  - level "action"   ：recorder 的每個 stroke / erase / undo
  - level "stage"    ：recorder 每個階段結束時的畫布（上一階段結束 → 這一階段結束）
  - level "keyframe" ：影片相鄰兩張關鍵幀

畫布用 {"image": 圖片路徑或 null（空白畫布）, "replay": [要在圖上依序重畫的動作 id]} 表示。
加上 --render 時，replay 不為空的畫布會用 Pillow 實際畫成 PNG（需要 pip install Pillow）。

範例：
  python tools/build_dataset.py --recorder samples/recorder --video out/keyframes --out out/dataset
"""

from __future__ import annotations

import argparse
import bisect
import json
import shutil
import sys
import zipfile
from collections import Counter
from io import BytesIO
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from canvas_replay import effective_after, render  # noqa: E402

SESSION_FORMAT = "draw-reasoning/session"
KEYFRAMES_FORMAT = "draw-reasoning/keyframes"


# ---------------------------------------------------------------------------
# 讀取來源
# ---------------------------------------------------------------------------
class SnapshotStore:
    """截圖可以放在 zip 裡，也可以是解壓後的資料夾。"""

    def __init__(self, path: Path | None):
        self.path = path
        self.zip = zipfile.ZipFile(path) if path and path.suffix == ".zip" else None
        self.names = set(self.zip.namelist()) if self.zip else None

    def exists(self, name: str) -> bool:
        if self.path is None:
            return False
        if self.zip:
            return name in self.names
        return (self.path / name).is_file()

    def read(self, name: str) -> bytes:
        if self.zip:
            return self.zip.read(name)
        return (self.path / name).read_bytes()


def find_session(path: Path) -> tuple[Path, SnapshotStore]:
    if path.is_dir():
        candidates = sorted(path.glob("session*.json"))
        if len(candidates) != 1:
            sys.exit(f"{path} 裡應該剛好有一個 session*.json，找到 {len(candidates)} 個")
        session_path = candidates[0]
    else:
        session_path = path
    folder = session_path.parent
    sid = json.loads(session_path.read_text(encoding="utf-8")).get("session_id", "")
    for cand in (folder / f"snapshots_{sid}.zip", folder / "snapshots.zip"):
        if cand.is_file():
            return session_path, SnapshotStore(cand)
    if (folder / "snapshots").is_dir():
        return session_path, SnapshotStore(folder)
    print(f"注意：{session_path} 旁邊找不到截圖（snapshots_*.zip 或 snapshots/）", file=sys.stderr)
    return session_path, SnapshotStore(None)


def validate_session(session: dict, label: str) -> list[str]:
    problems = []
    if session.get("format") != SESSION_FORMAT:
        problems.append(f"format 不是 {SESSION_FORMAT}")
    seen: set[int] = set()
    undone: set[int] = set()
    last_id = 0
    for a in session["actions"]:
        if a["id"] <= last_id:
            problems.append(f"動作 id {a['id']} 沒有遞增")
        last_id = a["id"]
        if a["type"] not in ("stroke", "erase", "undo"):
            problems.append(f"動作 {a['id']} 的 type 不明：{a['type']}")
        if a["type"] == "undo":
            tid = a.get("target_id")
            if tid not in seen:
                problems.append(f"undo {a['id']} 指向不存在的動作 {tid}")
            elif tid in undone:
                problems.append(f"undo {a['id']} 指向已被復原的動作 {tid}")
            undone.add(tid)
        else:
            if not a["points"]:
                problems.append(f"動作 {a['id']} 沒有任何點")
            seen.add(a["id"])
    for p in problems:
        print(f"[{label}] 警告：{p}", file=sys.stderr)
    return problems


# ---------------------------------------------------------------------------
# 輸出
# ---------------------------------------------------------------------------
class Builder:
    def __init__(self, out: Path, do_render: bool):
        self.out = out
        self.do_render = do_render
        self.records: list[dict] = []

    def emit(self, record: dict) -> None:
        self.records.append(record)

    def write(self) -> Path:
        path = self.out / "dataset.jsonl"
        with path.open("w", encoding="utf-8") as f:
            for r in self.records:
                f.write(json.dumps(r, ensure_ascii=False, separators=(",", ":")) + "\n")
        return path

    # -- recorder ------------------------------------------------------------
    def add_recorder(self, path: Path) -> None:
        session_path, store = find_session(path)
        session = json.loads(session_path.read_text(encoding="utf-8"))
        sid = session["session_id"]
        validate_session(session, sid)

        prefix = f"rec-{sid}"
        image_dir = self.out / "images" / prefix
        image_dir.mkdir(parents=True, exist_ok=True)
        sessions_dir = self.out / "sessions"
        sessions_dir.mkdir(parents=True, exist_ok=True)
        session_rel = f"sessions/{sid}.json"
        shutil.copyfile(session_path, self.out / session_rel)

        src = session.get("source", {})
        source = {
            "kind": "recorder",
            "ref": sid,
            "author": src.get("author", ""),
            "consent": src.get("consent", ""),
            "session_file": session_rel,
        }
        actions = session["actions"]
        effective = effective_after(actions)

        snapshots = {s["after_action_id"]: s["file"] for s in session.get("snapshots", [])
                     if store.exists(s["file"])}
        missing = len(session.get("snapshots", [])) - len(snapshots)
        if missing:
            print(f"[{sid}] 警告：{missing} 張截圖在 session.json 裡有記錄但找不到檔案", file=sys.stderr)
        snap_ids = sorted(snapshots)
        copied: dict[int, str] = {}
        rendered: dict[int, dict] = {}

        def snapshot_path(after_id: int) -> str:
            if after_id not in copied:
                name = Path(snapshots[after_id]).name
                (image_dir / name).write_bytes(store.read(snapshots[after_id]))
                copied[after_id] = f"images/{prefix}/{name}"
            return copied[after_id]

        def canvas_ref(after_id: int) -> dict:
            """after_id 這個動作之後的畫布。找最近一張「之後只多了新筆畫」的截圖，其餘用 replay 補上。"""
            if after_id == 0:
                return {"image": None, "replay": []}
            target = effective[after_id]
            base_id, replay = None, list(target)
            pos = bisect.bisect_right(snap_ids, after_id)
            for j in reversed(snap_ids[:pos]):
                base = effective[j]
                if target[:len(base)] == base:
                    base_id, replay = j, list(target[len(base):])
                    break
            if self.do_render and replay:
                return render_ref(after_id, base_id, replay)
            return {"image": snapshot_path(base_id) if base_id is not None else None, "replay": replay}

        def render_ref(after_id: int, base_id: int | None, replay: list[int]) -> dict:
            if after_id not in rendered:
                base = None
                if base_id is not None:
                    from PIL import Image
                    base = Image.open(BytesIO(store.read(snapshots[base_id])))
                name = f"render_{after_id:06d}.png"
                render(session, replay, base).save(image_dir / name)
                rendered[after_id] = {"image": f"images/{prefix}/{name}", "replay": [], "rendered": True}
            return rendered[after_id]

        # 逐筆
        prev_id = 0
        for a in actions:
            self.emit({
                "id": f"rec/{sid}/a{a['id']:06d}",
                "level": "action",
                "source": source,
                "stage": a.get("stage") or "unknown",
                "before": canvas_ref(prev_id),
                "target": {"kind": "action", "action": a},
            })
            prev_id = a["id"]

        # 階段級：連續同一階段的動作算一段
        segments: list[list[dict]] = []
        for a in actions:
            if segments and segments[-1][-1].get("stage") == a.get("stage"):
                segments[-1].append(a)
            else:
                segments.append([a])
        events = session.get("stage_events", [])
        prev_end = 0
        for k, seg in enumerate(segments):
            first, last = seg[0]["id"], seg[-1]["id"]
            stage = seg[0].get("stage") or "unknown"
            active_events = [e for e in events if e["after_action_id"] < first]
            note = active_events[-1].get("note") if active_events else None
            if active_events and active_events[-1].get("stage") != stage:
                note = None
            after = canvas_ref(last)
            self.emit({
                "id": f"rec/{sid}/s{k + 1:02d}",
                "level": "stage",
                "source": source,
                "stage": stage,
                "before": canvas_ref(prev_end),
                "target": {
                    "kind": "canvas",
                    **after,
                    "plan": note or None,
                    "actions": {"first": first, "last": last, "count": len(seg)},
                },
            })
            prev_end = last

    # -- video ---------------------------------------------------------------
    def add_video(self, path: Path) -> None:
        manifest_path = path / "keyframes.json" if path.is_dir() else path
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        if manifest.get("format") != KEYFRAMES_FORMAT:
            sys.exit(f"{manifest_path} 不是 {KEYFRAMES_FORMAT}")
        folder = manifest_path.parent
        src = manifest["source"]
        ref = src["ref"]
        prefix = f"vid-{ref}"
        image_dir = self.out / "images" / prefix
        image_dir.mkdir(parents=True, exist_ok=True)
        source = {"kind": "video", "ref": ref, "author": src.get("author", ""),
                  "consent": src.get("consent", "")}

        paths = []
        for fr in manifest["frames"]:
            name = Path(fr["file"]).name
            shutil.copyfile(folder / fr["file"], image_dir / name)
            paths.append(f"images/{prefix}/{name}")

        frames = manifest["frames"]
        for i in range(1, len(frames)):
            self.emit({
                "id": f"vid/{ref}/k{i:04d}",
                "level": "keyframe",
                "source": source,
                "stage": frames[i].get("stage") or "unknown",
                "before": {"image": paths[i - 1], "replay": [], "t": frames[i - 1]["t"]},
                "target": {"kind": "canvas", "image": paths[i], "replay": [], "t": frames[i]["t"]},
            })


def main() -> None:
    ap = argparse.ArgumentParser(description="把 recorder 資料和影片關鍵幀轉成 dataset.jsonl")
    ap.add_argument("--recorder", type=Path, action="append", default=[],
                    help="session_*.json 或放它的資料夾（截圖 zip 要在同一個資料夾）；可重複")
    ap.add_argument("--video", type=Path, action="append", default=[],
                    help="video_to_stages.py 的輸出資料夾或 keyframes.json；可重複")
    ap.add_argument("--out", type=Path, required=True, help="輸出資料夾")
    ap.add_argument("--render", action="store_true",
                    help="replay 不為空的畫布用 Pillow 畫成 PNG（需要 Pillow）")
    args = ap.parse_args()

    if not args.recorder and not args.video:
        sys.exit("至少要給一個 --recorder 或 --video")
    if args.render:
        try:
            import PIL  # noqa: F401
        except ImportError:
            sys.exit("--render 需要 Pillow：pip install Pillow")

    args.out.mkdir(parents=True, exist_ok=True)
    builder = Builder(args.out, args.render)
    for p in args.recorder:
        builder.add_recorder(p)
    for p in args.video:
        builder.add_video(p)
    path = builder.write()

    levels = Counter(r["level"] for r in builder.records)
    types = Counter(r["target"]["action"]["type"] for r in builder.records if r["level"] == "action")
    pending = sum(1 for r in builder.records if r["before"]["replay"])
    print(f"寫出 {len(builder.records)} 筆到 {path}")
    print("  依層級：" + "、".join(f"{k} {v}" for k, v in sorted(levels.items())))
    if types:
        print("  逐筆動作：" + "、".join(f"{k} {v}" for k, v in sorted(types.items())))
    print(f"  需要重播才能還原「前一張畫布」的紀錄：{pending}")


if __name__ == "__main__":
    main()
