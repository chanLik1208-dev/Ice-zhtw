# draw-reasoning

訓練一個「像 LLM 推理一樣畫畫」的模型：不是一次生成整張圖，而是看著目前的畫布一步一步畫下去，
並且會修正（擦掉、復原、重畫）。

目前是第一階段：**收集與整理訓練資料**。訓練之後會在 Google Compute Engine 上做。

## 設計原則

- **文字提示詞**：整張圖有一個提示詞（可以修改，保留歷史），每個動作也可以附一句說明，
  讓模型學會「依照文字畫」以及「為什麼這樣畫、為什麼要修正」。
- **階段式 + 先規劃**：步驟以繪畫階段為單位（草稿 → 線稿 → 上色 → 陰影），每個階段可以先寫一句規劃；
  同時保留逐筆資料，留給之後的實驗。
- **修正動作一定要完整記錄**：erase、undo 是模型學會「推理」的關鍵，任何工具都不會過濾掉它們。
- **只用自己或取得同意的作品**：每份資料都帶 `author` 和 `consent`（`self`／`permission`）。
- **大型原始資料不進 Git**：影片、截圖 zip 之後放 Google Cloud Storage；repo 只放程式碼和少量樣本。

## 目錄

```
draw-reasoning/
├── recorder/index.html        單一 HTML 畫板（零依賴、可離線，手機和電腦都能用）
├── tools/
│   ├── video_to_stages.py     縮時影片 → 去重後的關鍵幀
│   ├── build_dataset.py       recorder 資料 + 關鍵幀 → dataset.jsonl
│   ├── canvas_replay.py       依動作重建畫布（build_dataset 和之後的訓練程式共用）
│   └── requirements.txt       只有 --render 需要 Pillow
└── samples/
    ├── recorder/              一份完整 session（四個階段，含擦除與復原）
    └── video/timelapse.mp4    用上面的截圖合成的 10 秒縮時影片
```

樣本都由程式自動產生（Playwright 操作畫板），不涉及任何人的作品。

## 端到端快速測試

需要 Python 3.9+ 和 ffmpeg 5.0+。

```bash
cd draw-reasoning
python3 tools/video_to_stages.py samples/video/timelapse.mp4 --out out/keyframes \
    --stage-marks "0:sketch,3.6:lineart,6.4:color,8.4:shading" --prompt "一間紅屋頂的小房子，左上角有太陽"
python3 tools/build_dataset.py --recorder samples/recorder --video out/keyframes --out out/dataset
```

預期輸出 32 筆：逐筆 22、階段級 4、關鍵幀 6。

---

## 1. recorder/index.html

直接用瀏覽器開啟（`file://` 也可以），或放在任何靜態網站上（手機建議這樣用）：

```bash
python3 -m http.server 8000   # 然後打開 http://<電腦 IP>:8000/recorder/
```

| 功能 | 說明 |
|---|---|
| 提示詞 | 最上面的輸入框。**畫第一筆之前必填**；之後可以修改，每次修改都會記下是在第幾個動作之後改的 |
| 下一筆的說明 | 選填。打好字後，下一個動作（筆畫、擦除或復原）會帶上這句說明，用完自動清空；按「加到上一筆」則是補在剛畫完的那一筆 |
| 筆刷／橡皮擦 | 兩者的粗細各自記憶。快捷鍵 `B`／`E` |
| 顏色 | 色票或自訂顏色 |
| 復原 | 按鈕或 `Ctrl/⌘ + Z`。沒有重做（redo） |
| 階段 | 草稿／線稿／上色／陰影，快捷鍵 `1`～`4`；旁邊的輸入框可以寫這個階段的規劃 |
| 每 N 筆截圖 | 預設 1（每個動作後都截一張）。切換階段和匯出時，如果最後一個動作還沒有截圖，也會補一張 |
| 只用觸控筆 | 打勾後忽略手指和滑鼠，避免手掌誤觸 |
| 匯出 | 下載 `session_<id>.json` 和 `snapshots_<id>.zip`，**兩個都要下載** |
| 新畫布 | 清掉暫存，重新開始（請先匯出） |

- 畫布內部固定 1024×1024，顯示時依螢幕縮放。
- 所有資料即時暫存在瀏覽器的 IndexedDB，重新整理或關掉分頁再打開都可以接著畫。
- 觸控筆的壓感來自 PointerEvent；滑鼠沒有壓感，會固定記成 0.5。

### session.json

```jsonc
{
  "format": "draw-reasoning/session",
  "version": 1,
  "session_id": "20261002-111228-ef18",
  "created_at": "2026-10-02T11:12:28.000Z",
  "exported_at": "2026-10-02T11:13:10.000Z",
  "canvas": { "width": 1024, "height": 1024, "background": "#ffffff" },
  "source": { "kind": "recorder", "author": "", "consent": "self" },
  "settings": { "snapshot_every": 1 },
  "stages": ["sketch", "lineart", "color", "shading"],
  "prompt_events": [
    { "after_action_id": 0, "prompt": "一間小房子，旁邊有太陽" },
    { "after_action_id": 8, "prompt": "一間紅屋頂的小房子，左上角有太陽" }
  ],
  "stage_events": [
    { "after_action_id": 0, "stage": "sketch", "note": "先抓房子和太陽的大輪廓" },
    { "after_action_id": 8, "stage": "lineart", "note": "用深色把輪廓描乾淨" }
  ],
  "snapshots": [
    { "file": "snapshots/000001.png", "after_action_id": 1, "stage": "sketch", "reason": "auto" }
  ],
  "actions": [
    { "id": 1, "type": "stroke", "points": [[0.248, 0.4696, 0.4, 74], ...],
      "color": "#9e9e9e", "width": 0.0029, "target_id": null, "stage": "sketch", "pointer": "pen", "t": 74, "caption": null },
    { "id": 4, "type": "erase", "points": [...], "color": null, "width": 0.0156, ..., "caption": "擦掉多餘的中線" },
    { "id": 6, "type": "undo", "points": [], "color": null, "width": null, "target_id": 5,
      "stage": "sketch", "pointer": null, "t": 12362, "caption": "太陽太靠右，構圖不平衡，復原" }
  ]
}
```

**動作（actions）**

| 欄位 | 說明 |
|---|---|
| `id` | 從 1 開始遞增 |
| `type` | `stroke`／`erase`／`undo` |
| `points` | `[x, y, pressure, t]`。x、y 以畫布寬高正規化成 0～1（小數 4 位）；筆畫拖出畫布時會略超出 0～1，原樣保留。pressure 0～1（小數 3 位）。t 是距離 session 開始的毫秒數 |
| `color` | stroke 的顏色（`#rrggbb`）；erase、undo 為 null |
| `width` | 最大線寬，以畫布寬度為 1（小數 4 位）；undo 為 null |
| `target_id` | undo 時指向被復原的動作，其餘為 null |
| `stage` | 動作發生時的階段標籤 |
| `pointer` | `pen`／`touch`／`mouse`；undo 為 null |
| `t` | 動作開始的時間（毫秒，同上）。undo 沒有點，所以要靠這個欄位 |
| `caption` | 這個動作的文字說明，沒有就是 null |

- **undo 規則**：一律復原「最後一個還沒被復原的 stroke 或 erase」，連續按就一路往回。
  沒有 redo，所以被復原的動作不會再回來。
- **prompt_events**：提示詞的修改歷史。`after_action_id` 之後的動作都用這一版，直到下一次修改；
  第一筆一定是 `after_action_id: 0`。中間沒有新動作就連續修改的話，只會留下最後的內容。
- **stage_events**：每次切換階段記一筆；`after_action_id` 是切換前最後一個動作的 id，`note` 是那個階段的規劃。
- **snapshots**：`after_action_id` 這個動作完成後的畫布 PNG。`reason` 為 `auto`／`stage_change`／`export`。

### 繪圖規則

`recorder/index.html` 和 `tools/canvas_replay.py` 用同一套規則，任何一邊修改，另一邊都要跟著改：

1. 每個動作先在第一點畫一個圓點（直徑 = 該點線寬），再把相鄰兩點連成圓頭線段。
2. 線段線寬 = `width × 畫布寬 × 兩端壓力係數的平均`。
3. 壓力係數：`pointer == "pen"` 時為 `0.15 + 0.85 × pressure`，其他（滑鼠、觸控）固定為 1。
4. erase 用背景色畫；undo 會把目標從畫布上拿掉，然後重畫剩下的動作。

Pillow 沒有反鋸齒，`canvas_replay.py` 用 2 倍超取樣近似。和瀏覽器截圖比對：從空白畫布重畫整張圖時，
差異超過 25% 的像素約 0.16%；疊在截圖上補畫幾筆時約 0.03%，差異都在線條邊緣。

---

## 2. tools/video_to_stages.py

把縮時影片拆成畫面、去除相似畫面，輸出關鍵幀。只需要 ffmpeg 和 Python 標準函式庫。

```bash
python3 tools/video_to_stages.py my_timelapse.mp4 --out data/keyframes/my_timelapse \
    --threshold 0.003 --max-frames 64 --stage-marks "0:sketch,95:lineart,200:color,320:shading"
```

流程：依 `--fps` 抽幀並縮成 64×64 灰階 → 跟上一張保留的畫面比較平均差異，低於 `--threshold` 就丟掉
→ 數量超過 `--max-frames` 時，依累積變化量平均挑選（頭尾一定保留）→ 以 `--size` 輸出 PNG。

| 參數 | 預設 | 說明 |
|---|---|---|
| `--out` | （必填） | 輸出資料夾，會產生 `keyframes/` 和 `keyframes.json` |
| `--fps` | 2 | 每秒抽幾張來比較 |
| `--threshold` | 0.003 | 相似度門檻（平均差異，0～1）。線稿在白底上只佔很少像素，門檻要設低；畫面太多就調高或用 `--max-frames` 限制 |
| `--max-frames` | 64 | 最多輸出幾張（至少 2） |
| `--size` | 1024 | 輸出長邊上限，0 代表原尺寸（不會放大） |
| `--crop` | 無 | 螢幕錄影時先裁出畫布，ffmpeg 格式 `w:h:x:y` |
| `--stage-marks` | 無 | 依秒數標階段；沒標的話 `stage` 是 null |
| `--prompt` | 無 | 這支影片在畫什麼（文字提示詞） |
| `--ref` | 影片檔名 | 來源名稱 |
| `--author`／`--consent` | 空／`self` | 來源與授權 |
| `--overwrite` | 否 | 輸出資料夾已有關鍵幀時覆蓋 |

用樣本試不同門檻（`--fps 2`）：0.001 → 12 張、0.003 → 7 張、0.005 → 6 張、0.01 → 4 張（草稿階段完全被跳過）。

### keyframes.json

```jsonc
{
  "format": "draw-reasoning/keyframes",
  "version": 1,
  "source": { "kind": "video", "ref": "timelapse", "file": "timelapse.mp4", "author": "", "consent": "self" },
  "video": { "width": 512, "height": 512, "duration": 9.8 },
  "prompt": "一間紅屋頂的小房子，左上角有太陽",
  "params": { "fps": 2.0, "threshold": 0.003, "max_frames": 64, "size": 1024, "crop": null, "stage_marks": "..." },
  "sampled_frames": 20,
  "frames": [
    { "file": "keyframes/000001.png", "index": 0, "t": 0.0, "diff": 0.0, "stage": "sketch" },
    { "file": "keyframes/000002.png", "index": 6, "t": 3.0, "diff": 0.00566, "stage": "sketch" }
  ]
}
```

`index` 是抽幀後的序號，`t` 是秒數，`diff` 是和上一張關鍵幀的差異。
`stage` 和 `prompt` 都可以事後直接在檔案裡修改，build_dataset 會照用。

---

## 3. tools/build_dataset.py

把 recorder 資料和影片關鍵幀統一轉成 JSONL。

```bash
python3 tools/build_dataset.py \
    --recorder data/recorder/session_xxx.json \
    --recorder data/recorder/another_session_dir \
    --video data/keyframes/my_timelapse \
    --out data/dataset            # 加 --render 會把需要重播的畫布畫成 PNG
```

- `--recorder` 可以給 session json 或它所在的資料夾；截圖 zip（`snapshots_<id>.zip` 或 `snapshots.zip`）
  或解壓後的 `snapshots/` 要在同一個資料夾。可重複。
- `--video` 可以給 video_to_stages 的輸出資料夾或 `keyframes.json`。可重複。
- 會檢查 session（id 是否遞增、undo 是否指向存在且還沒被復原的動作等），有問題就印出警告。

輸出資料夾可以整包上傳到 GCS：

```
out/dataset/
├── dataset.jsonl
├── images/rec-<session_id>/…png    用到的截圖（--render 時另有 render_*.png）
├── images/vid-<ref>/…png
└── sessions/<session_id>.json      原始 session，replay 時要用
```

### dataset.jsonl

每行一筆（前一張畫布, 動作或下一張畫布, 階段標籤, 來源）：

```jsonc
// level "action"：每個 stroke / erase / undo 一筆
{ "id": "rec/20261002-111228-ef18/a000006", "level": "action",
  "source": { "kind": "recorder", "ref": "20261002-111228-ef18", "author": "…", "consent": "self",
              "session_file": "sessions/20261002-111228-ef18.json" },
  "stage": "sketch",
  "prompt": "一間小房子，旁邊有太陽",
  "before": { "image": "images/rec-20261002-111228-ef18/000005.png", "replay": [] },
  "target": { "kind": "action",
              "action": { "id": 6, "type": "undo", "target_id": 5, "caption": "太陽太靠右，構圖不平衡，復原", … } } }

// level "stage"：上一階段結束的畫布 → 這一階段結束的畫布
{ "id": "rec/20261002-111228-ef18/s02", "level": "stage", "source": { … }, "stage": "lineart",
  "prompt": "一間紅屋頂的小房子，左上角有太陽",
  "before": { "image": "images/rec-…/000008.png", "replay": [] },
  "target": { "kind": "canvas", "image": "images/rec-…/000015.png", "replay": [],
              "plan": "用深色把輪廓描乾淨", "actions": { "first": 9, "last": 15, "count": 7 } } }

// level "keyframe"：影片相鄰兩張關鍵幀
{ "id": "vid/timelapse/k0003", "level": "keyframe",
  "source": { "kind": "video", "ref": "timelapse", "author": "", "consent": "self" }, "stage": "lineart",
  "prompt": "一間紅屋頂的小房子，左上角有太陽",
  "before": { "image": "images/vid-timelapse/000003.png", "replay": [], "t": 3.5 },
  "target": { "kind": "canvas", "image": "images/vid-timelapse/000004.png", "replay": [], "t": 5.5 } }
```

**畫布的表示法**：`{ "image": 圖片路徑或 null（空白畫布）, "replay": [動作 id…] }`，
代表「在 image 上依序重畫 replay 裡的動作」。

- 每 1 筆截圖（預設）時，`replay` 幾乎都是空的，直接用瀏覽器的截圖。
- 截圖比較稀疏時，會找最近一張「之後只多了新筆畫」的截圖，再用 replay 補上。
  如果中間有 undo 復原了截圖裡的筆畫，就往前找更早的截圖，必要時從空白畫布開始。
- 訓練時用 `canvas_replay.render(session, replay, base_image)` 還原，session 在 `source.session_file`。
- 加上 `--render` 時，replay 不為空的畫布會直接畫成 `render_<id>.png`，並標上 `"rendered": true`。

- `prompt`：逐筆是畫那一筆時有效的版本；階段級是那個階段第一筆時的版本；影片是 `--prompt`。沒有就是 null。
- 動作的文字說明在 `target.action.caption`。
- `stage` 沒有標籤時是 `"unknown"`。

---

## 之後

- 原始資料：`gs://<bucket>/draw-reasoning/raw/{recorder,video}/`，處理後：`…/datasets/<日期>/`。
- 訓練資料讀取器直接吃 `dataset.jsonl` 和 `canvas_replay.py`。
