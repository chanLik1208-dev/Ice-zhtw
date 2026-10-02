# draw-reasoning

訓練一個「像 LLM 推理一樣畫畫」的模型：不是一次生成整張圖，而是看著目前的畫布一步一步畫下去，
並且會修正（擦掉、復原、重畫）。

目前是第一階段：**收集與整理訓練資料**。訓練之後會在 Google Compute Engine 上做。

## 設計原則

- **文字提示詞**：整張圖有一個提示詞（可以修改，保留歷史），每個動作也可以附一句說明，
  讓模型學會「依照文字畫」以及「為什麼這樣畫、為什麼要修正」。
- **階段式 + 先規劃**：步驟以繪畫階段為單位（草稿 → 線稿 → 底色 → 陰影 → 高光 → 細節，適合動漫人物），
  每個階段可以先寫一句規劃；
  同時保留逐筆資料，留給之後的實驗。
- **修正動作一定要完整記錄**：erase、undo（包括復原漆桶） 是模型學會「推理」的關鍵，任何工具都不會過濾掉它們。
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
    ├── recorder/              一份完整 session：Q 版動漫女孩頭像，六個階段，
    │                          含擦除、復原、漆桶、半透明、防手抖、放大作畫、提示詞修改
    └── video/timelapse.mp4    用上面的截圖合成的 15 秒縮時影片
```

樣本都由程式自動產生（Playwright 操作畫板），不涉及任何人的作品。

## 端到端快速測試

需要 Python 3.9+ 和 ffmpeg 5.0+。

```bash
cd draw-reasoning
python3 tools/video_to_stages.py samples/video/timelapse.mp4 --out out/keyframes \
    --stage-marks "0:sketch,3.6:lineart,6.4:base,9.2:shading,10.4:highlight,11.2:detail" \
    --prompt "Q版動漫女孩頭像，粉色長髮有光澤、藍色大眼睛，害羞地微笑"
python3 tools/build_dataset.py --recorder samples/recorder --video out/keyframes --out out/dataset
```

預期輸出 47 筆：逐筆 34、階段級 6、關鍵幀 7。

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
| 筆刷／橡皮擦 | 粗細和不透明度各自記憶。快捷鍵 `B`／`E` |
| 漆桶 | 點一下填滿封閉區域；這時「粗細」滑桿變成「容差」（預設 32）。快捷鍵 `G` |
| 滴管 | 從畫布取色，取完自動切回筆刷；也可以按住 `Alt` 點畫布。不算動作。快捷鍵 `I` |
| 顏色 | 色票（含膚色、髮色）或自訂顏色 |
| 不透明度 | 5%～100%。半透明的一筆在交叉處不會變深，適合疊陰影、腮紅 |
| 防手抖 | 0（關閉）～10。數字越大線條越平順，但會稍微落後筆尖 |
| 縮放／平移 | 電腦：滾輪縮放、空白鍵或中鍵拖曳平移、`+`／`-`／`0`（重設）。手機：雙指捏合；第二根手指放下時，第一根手指剛開始的那一筆會取消。勾選「只用觸控筆」時一指就能平移 |
| 復原 | 按鈕或 `Ctrl/⌘ + Z`。沒有重做（redo） |
| 階段 | 草稿／線稿／底色／陰影／高光／細節，快捷鍵 `1`～`6`；旁邊的輸入框可以寫這個階段的規劃 |
| 每 N 筆截圖 | 預設 1（每個動作後都截一張）。切換階段和匯出時，如果最後一個動作還沒有截圖，也會補一張 |
| 只用觸控筆 | 打勾後忽略手指和滑鼠，避免手掌誤觸 |
| 匯出 | 下載 `session_<id>.json` 和 `snapshots_<id>.zip`，**兩個都要下載** |
| 新畫布 | 清掉暫存，重新開始（請先匯出） |
| 更多 | 只在手機（窄螢幕）出現：次要設定平常收起來，把畫面留給畫布 |

- 畫布內部固定 1024×1024，顯示時依螢幕和縮放倍率調整；放大只是看得比較清楚，座標一樣是 0～1。
- 所有資料即時暫存在瀏覽器的 IndexedDB，重新整理或關掉分頁再打開都可以接著畫。
- 觸控筆的壓感來自 PointerEvent；滑鼠沒有壓感，會固定記成 0.5。

### session.json

```jsonc
{
  "format": "draw-reasoning/session",
  "version": 2,
  "session_id": "20261002-114343-3a22",
  "created_at": "2026-10-02T11:43:43.000Z",
  "exported_at": "2026-10-02T11:44:25.000Z",
  "canvas": { "width": 1024, "height": 1024, "background": "#ffffff" },
  "source": { "kind": "recorder", "author": "", "consent": "self" },
  "settings": { "snapshot_every": 1 },
  "stages": ["sketch", "lineart", "base", "shading", "highlight", "detail"],
  "prompt_events": [
    { "after_action_id": 0, "prompt": "Q版動漫女孩頭像，粉色長髮、藍色大眼睛，微笑" },
    { "after_action_id": 25, "prompt": "Q版動漫女孩頭像，粉色長髮有光澤、藍色大眼睛，害羞地微笑" }
  ],
  "stage_events": [
    { "after_action_id": 0, "stage": "sketch", "note": "抓頭的圓形、頭髮外形和眼睛位置" },
    { "after_action_id": 8, "stage": "lineart", "note": "深色描出臉、頭髮、瀏海和眼睛輪廓，要封閉才好填色" }
  ],
  "snapshots": [
    { "file": "snapshots/000001.png", "after_action_id": 1, "stage": "sketch", "reason": "auto" }
  ],
  "actions": [
    { "id": 5, "type": "undo", "points": [], "smooth": null, "color": null, "width": null, "opacity": null,
      "tolerance": null, "target_id": 4, "stage": "sketch", "pointer": null, "t": 10778, "zoom": null,
      "caption": "脖子畫太長，先不要" },
    { "id": 9, "type": "stroke", "points": [[0.4988, 0.2803, 0.6, 13890], ...],
      "smooth": { "strength": 4, "points": [[0.4988, 0.2803, 0.6, 13890], ...] },
      "color": "#3a2a2a", "width": 0.0039, "opacity": 1, "tolerance": null, "target_id": null,
      "stage": "lineart", "pointer": "pen", "t": 13890, "zoom": 1, "caption": null },
    { "id": 16, "type": "fill", "points": [[0.5, 0.235, 0.5, 32447]], "smooth": null, "color": "#f48fb1",
      "width": null, "opacity": 1, "tolerance": 32, ..., "zoom": 1, "caption": "頭髮外圈" },
    { "id": 23, "type": "stroke", ..., "color": "#d81b60", "width": 0.0176, "opacity": 0.35, ... },
    { "id": 29, "type": "stroke", ..., "color": "#3949ab", "width": 0.0098, "opacity": 1, ..., "zoom": 6.05, ... }
  ]
}
```

**動作（actions）**

| 欄位 | 說明 |
|---|---|
| `id` | 從 1 開始遞增 |
| `type` | `stroke`／`erase`／`fill`／`undo` |
| `points` | `[x, y, pressure, t]`。x、y 以畫布寬高正規化成 0～1（小數 4 位）；筆畫拖出畫布時會略超出 0～1，原樣保留。pressure 0～1（小數 3 位）。t 是距離 session 開始的毫秒數 |
| `smooth` | 防手抖：`{ "strength": 1～10, "points": [...] }`，畫面上畫的是這組平滑後的點；`points` 仍是手的原始軌跡。沒開就是 null |
| `color` | stroke、fill 的顏色（`#rrggbb`）；erase、undo 為 null |
| `width` | 最大線寬，以畫布寬度為 1（小數 4 位）；fill、undo 為 null |
| `opacity` | 不透明度 0～1；undo 為 null |
| `tolerance` | fill 的容差（每個色版 0～255）；其他為 null |
| `target_id` | undo 時指向被復原的動作，其餘為 null |
| `stage` | 動作發生時的階段標籤 |
| `pointer` | `pen`／`touch`／`mouse`；undo 為 null |
| `t` | 動作開始的時間（毫秒，同上）。undo 沒有點，所以要靠這個欄位 |
| `zoom` | 動作當下的縮放倍率（1 = 整張畫布塞滿畫面）；undo 為 null |
| `caption` | 這個動作的文字說明，沒有就是 null |

- fill 的 `points` 只有一個點：點擊的位置。
- **undo 規則**：一律復原「最後一個還沒被復原的 stroke、erase 或 fill」，連續按就一路往回。
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
5. 有 `smooth` 時畫 `smooth.points`，否則畫 `points`。
6. 每一筆先不透明地畫在空白圖層，再以 `opacity` 疊上去，所以半透明筆畫交叉處不會變深。
7. fill：從點擊位置做 4 連通填色，RGB 每個色版和起點顏色相差 ≤ `tolerance` 的都算同一區，
   再往外擴 1px（8 連通）蓋住線條邊緣的反鋸齒，最後以 `opacity` 混色。

瀏覽器裡重新整理後重畫的結果，和當下的截圖逐像素一致。
Pillow 沒有反鋸齒，`canvas_replay.py` 的筆畫用 2 倍超取樣近似，漆桶則在原解析度計算。和瀏覽器截圖比對：
從空白畫布重畫整張圖時，差異超過 25% 的像素約 0.13%；疊在前一張截圖上補一筆時最多約 0.03%
（漆桶和半透明筆畫是 0%），差異都在線條邊緣。

**第 1 版 session**（四個階段、沒有 fill／opacity／smooth／zoom）一樣可以用：缺少的欄位視為預設值，
`color` 階段會轉成 `base`。

---

## 2. tools/video_to_stages.py

把縮時影片拆成畫面、去除相似畫面，輸出關鍵幀。只需要 ffmpeg 和 Python 標準函式庫。

```bash
python3 tools/video_to_stages.py my_timelapse.mp4 --out data/keyframes/my_timelapse \
    --threshold 0.003 --max-frames 64 \
    --stage-marks "0:sketch,95:lineart,200:base,320:shading,400:highlight,450:detail"
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

用樣本試不同門檻（`--fps 2`）：0.001 → 13 張、0.003 → 8 張、0.005 → 5 張、0.01 → 4 張。
半透明陰影、高光這類變化很小的步驟，在門檻高時容易被併進相鄰的關鍵幀。

### keyframes.json

```jsonc
{
  "format": "draw-reasoning/keyframes",
  "version": 1,
  "source": { "kind": "video", "ref": "timelapse", "file": "timelapse.mp4", "author": "", "consent": "self" },
  "video": { "width": 512, "height": 512, "duration": 14.6 },
  "prompt": "Q版動漫女孩頭像，粉色長髮有光澤、藍色大眼睛，害羞地微笑",
  "params": { "fps": 2.0, "threshold": 0.003, "max_frames": 64, "size": 1024, "crop": null, "stage_marks": "..." },
  "sampled_frames": 29,
  "frames": [
    { "file": "keyframes/000001.png", "index": 0, "t": 0.0, "diff": 0.0, "stage": "sketch" },
    { "file": "keyframes/000002.png", "index": 6, "t": 3.0, "diff": 0.0043, "stage": "sketch" }
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
// level "action"：每個 stroke / erase / fill / undo 一筆
{ "id": "rec/20261002-114343-3a22/a000005", "level": "action",
  "source": { "kind": "recorder", "ref": "20261002-114343-3a22", "author": "…", "consent": "self",
              "session_file": "sessions/20261002-114343-3a22.json" },
  "stage": "sketch",
  "prompt": "Q版動漫女孩頭像，粉色長髮、藍色大眼睛，微笑",
  "before": { "image": "images/rec-20261002-114343-3a22/000004.png", "replay": [] },
  "target": { "kind": "action",
              "action": { "id": 5, "type": "undo", "target_id": 4, "caption": "脖子畫太長，先不要", … } } }

// level "stage"：上一階段結束的畫布 → 這一階段結束的畫布
{ "id": "rec/20261002-114343-3a22/s03", "level": "stage", "source": { … }, "stage": "base",
  "prompt": "Q版動漫女孩頭像，粉色長髮、藍色大眼睛，微笑",
  "before": { "image": "images/rec-…/000015.png", "replay": [] },
  "target": { "kind": "canvas", "image": "images/rec-…/000022.png", "replay": [],
              "plan": "用漆桶填頭髮、臉、眼睛", "actions": { "first": 16, "last": 22, "count": 7 } } }

// level "keyframe"：影片相鄰兩張關鍵幀
{ "id": "vid/timelapse/k0002", "level": "keyframe",
  "source": { "kind": "video", "ref": "timelapse", "author": "", "consent": "self" }, "stage": "sketch",
  "prompt": "Q版動漫女孩頭像，粉色長髮有光澤、藍色大眼睛，害羞地微笑",
  "before": { "image": "images/vid-timelapse/000002.png", "replay": [], "t": 3.0 },
  "target": { "kind": "canvas", "image": "images/vid-timelapse/000003.png", "replay": [], "t": 3.5 } }
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
