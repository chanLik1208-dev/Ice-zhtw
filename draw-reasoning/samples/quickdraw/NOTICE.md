# Quick, Draw! 樣本

`quickdraw_sample.jsonl.gz` 收錄 cat、face、The Eiffel Tower 三類各 4 張，由 `tools/quickdraw_to_sessions.py` 轉換。

資料來源：Quick, Draw! dataset by Google（https://quickdraw.withgoogle.com/data），
以 [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/) 授權。
轉換時只調整了座標（依外框置中縮放到 0～1），並補上 draw-reasoning 格式需要的欄位，沒有改動筆畫內容。
