# 改版資訊 (Revision History)

| 版本   | 日期       | 說明 |
|--------|------------|------|
| v1.6.1 | 2026-11-04 | HS raw dump 依 header 寫到最後一個 packet 的 CRC，不寫 HS-trail byte。 |
| v1.6.0 | 2026-11-04 | Rx stub 新增 LP / HS raw byte dump（`RAW_DUMP_EN`），LP 與 HS 分成兩個檔案。 |
| v1.5.0 | 2026-11-03 | Rx stub DSI DCS Long Write 可寫成 RGB888 PPM；新增 `DSI_PPM_EN` / `DSI_HSIZE` / `DSI_VSIZE` parameter。 |
| v1.4.1 | 2026-10-24 | 修正 YUV422 golden pattern 的行索引（PATTERN 0/5）。 |
| v1.4.0 | 2026-09-15 | Rx stub HS 路徑新增 DSI data type / DCS command 解碼顯示。 |
| v1.3.0 | 2026-08-05 | Rx stub 新增 LPDT/CSI-2/DSI command decode、LP data log、BTA 與 ULPS。 |
| v1.2.0 | 2026-06-30 | 新增 `PACKET_INTERVAL_NS`，可調整 CSI-2 packet 間 LP-11 gap，包含 FS/FE short packet。 |
| v1.1.0 | 2026-06-02 | 時序由 lane speed 自動推算；新增 YUV422 8/10-bit。 |
| v1.0.0 | 2026-06-02 | 首次釋出。 |

---

## v1.6.1 (2026-11-04)

### 修正

- **HS raw dump 不再寫入 HS-trail byte**：HS-trail 期間 HS valid 仍為 1 時，stub 會把 trail 的位元收成
  `00`/`ff` byte。v1.6.0 會把它們寫在行尾，造成 byte 數比 packet 長度多。
  現在依 header 逐個 packet 計算長度（long `4+WC+2`、short `4`），寫到最後一個 packet 的 CRC 為止。
- long/short 判斷：CSI-2 為 `DT >= 0x10`；DSI 為 `DT[3:0] >= 9`；AUTO 時 CSI-2 影像 DT 用 CSI-2 規則，
  其他 DT 用 DSI 規則。
- 最後一個 packet 之後，每條 lane 剩下的 byte 都是同一個 `00` 或 `ff` 時，判定為 trail。

### 注意

- 同一 burst 內的後續 packet（例如 EoTp `08 0f 0f 01`）仍會寫入。
- 第一個 packet 一定寫入；packet 長度超過 burst 結尾或 WC 為 X 時，寫出收到的全部 byte，方便除錯。
- 行首的 byte 數欄位是實際寫入的 byte 數。

---

## v1.6.0 (2026-11-04)

### 新增

- `mipi_rx_dphy_stub` 新增 parameter `RAW_DUMP_EN`、`RAW_LP_FILE`、`RAW_HS_FILE`，以及 plusarg `+RAW_DUMP`。
- `RAW_LP_FILE`（預設 `mipi_lp_raw.txt`）：每個 LPDT transaction 寫一行，格式 `transaction bytes data_hex...`。
- `RAW_HS_FILE`（預設 `mipi_hs_raw.txt`）：每個 HS burst 寫一行，格式 `burst bytes data_hex...`，
  內容是 sync byte 之後依 lane 合併的全部 byte（header、ECC、payload、CRC，以及同一 burst 內的後續 packet）。
  HS-trail 的處理見 v1.6.1。
- 行首不寫時間。

### 注意

- `RAW_DUMP_EN` 預設 `0`，沒有開啟的 testbench 行為不變，也不建立檔案。
- `LP_DATA_FILE` 不受影響。
- LP transaction 超過 `MAXBPL` byte 時只寫前 `MAXBPL` 個，並印 WARNING。

---

## v1.5.0 (2026-11-03)

### 新增

- `mipi_rx_dphy_stub` 把 DSI HS 的 DCS Long Write（DT `0x39`）payload 當成 RGB888 line，
  寫成 `dsi_rgb_frame_NNNN.ppm`（P3）。依 WC 判斷格式：
  `WC = 3*HSIZE` 代表 payload 全是 pixel；`WC = 3*HSIZE+1` 代表 `payload[0]` 是 DCS command，
  `0x2C` 開新 frame，`0x3C` 接續目前的 frame。
- 新增 parameter `DSI_PPM_EN`、`DSI_HSIZE`、`DSI_VSIZE`。testbench 可以直接在 instance 上開啟，
  不需要改 run command。
- 原有的 plusarg `+DSI_PPM`、`+DSI_HSIZE`、`+DSI_VSIZE` 保留，並覆蓋 parameter 值。

### 注意

- 三個 parameter 預設都是 `0`，沒有傳 parameter 或 plusarg 的 testbench 行為不變。
- 開啟後 HSIZE / VSIZE 超出範圍時會 `$fatal`，與原本只用 plusarg 時相同。
- DSI 影像不輸出到 Pxclk/Data，`mipi_rx_checker` 的 `PPM_EN` / `RAW_EN` 對 DSI 沒有作用；
  DSI 也沒有 RAW dump。

---

## v1.4.1 (2026-10-24)

### 修正

- **YUV422 golden pattern 行索引**：`golden_pixel` 的 `hsize` 原本傳入 pixel 數，
  但 YUV422 每行有 `2*Hsize` 個 sample，導致相鄰兩行的 sample 索引重疊一半。
  Tx 與 `mipi_rx_checker` 改傳每行 sample 數（RAW = `Hsize`，YUV422 = `2*Hsize`），
  `golden_pattern.txt` 可直接依每行 `2*Hsize` 個 component 排列。

### 注意

- RAW 格式行為不變。
- YUV422 的 `PATTERN_SEL=0`（ramp）與 `5`（file）送出的值會與舊版不同；
  Tx 與 checker 同步修改，自我比對結果不受影響。

---

## v1.4.0 (2026-09-15)

### 新增

- `mipi_rx_dphy_stub` HS packet 依 `LP_PROTOCOL` 解碼 DSI：`0=AUTO` 時非 CSI-2 影像 DT 以 DSI 名稱顯示
  （取代 `ignored packet` WARNING）；`2=DSI` 時所有 HS packet 以 DSI 顯示；`1=CSI-2` 行為不變。
- DCS Short Write / DCS Read / DCS Long Write 另外顯示 DCS command。
- DSI type 表補上 pixel stream（RGB565/666/888/101010/121212、YCbCr 4:2:2/4:2:0）、
  Compression Mode、PPS、Compressed Pixel Stream。

### 注意

- DSI HS packet 只解碼顯示，不輸出到 Pxclk/Data，也不做 frame/line 檢查。
- 每個 HS burst 只解第一個 packet；同一 burst 內的後續 packet（例如 EoTp）不逐一解析。
- LP 路徑輸出文字不變（`[rx_stub][lp][DSI]`）。

---

## v1.3.0 (2026-08-05)

### 新增

- `mipi_rx_dphy_stub` 支援 D-PHY Escape entry、LPDT/Trigger/ULPS command decode。
- `LP_PROTOCOL=0/1/2` 分別提供 AUTO、CSI-2、DSI LP packet 顯示；DSI DCS opcode 額外解碼。
- LPDT payload 寫入 `LP_DATA_FILE` 文字檔，保留時間、transaction、byte index 與 byte value。
- 收到 BTA 後執行 reverse-direction hand-off，並可自動送 reverse BTA 歸還 bus。
- data lane 及 clock lane ULPS entry/exit 與 `T_WAKEUP_PS` 檢查。
- 新增 `tb_mipi_rx_dphy_lp.v` 與 `make lp` 專用測試。

---

## v1.2.0 (2026-06-30)

### 新增

- **Packet interval**：Tx 新增 `PACKET_INTERVAL_NS` parameter，單位 ns。
  模型會在 CSI-2 packet 完成並回到 LP-11 後、下一個 packet 開始前插入額外 gap。
  此間隔套用於 FS short packet、每條 image line long packet、FE short packet 之間；
  default `0` 表示維持既有連續送 packet 的行為。

### 注意

- `LANE_SPEED_MBPS` 仍只負責 D-PHY UI 與 HS entry/exit timing 的自動推算；
  `PACKET_INTERVAL_NS` 是 packet-to-packet idle gap，不屬於 D-PHY spec 最小時序推算。

## v1.1.0 (2026-06-02)

### 變更

- **時序自動計算**：移除手動的 `UI_PS` / `T_*_PS` 參數，改為單一旋鈕
  `LANE_SPEED_MBPS`。UI 與所有 D-PHY HS 進出時序（T-LPX、T-HS-PREPARE、
  T-HS-ZERO、T-HS-TRAIL、T-CLK-PREPARE、T-CLK-ZERO、T-CLK-TRAIL、
  T-CLK-PRE、T-CLK-POST）依 MIPI D-PHY spec 關係式自動推算最小合規值，
  並向上取整成整數個 UI（對齊 DDR clock 格點）。模型啟動時會印出實際時序。
- testbench / Rx stub 同步改用 `LANE_SPEED_MBPS`（`SPEED` define），
  Rx 取樣與 Pxclk 週期也由 lane speed 推算。

### 新增

- **YUV422 8-bit（DT 0x1E）與 YUV422 10-bit（DT 0x1F）**。YUV422 每 pixel
  帶 2 個 component（Cb,Y0,Cr,Y1 → 2 samples/pixel），每行 sample 數 =
  `2*Hsize`，packing 與相同位元數的 RAW 一致（YUV8↔RAW8、YUV10↔RAW10）。
  golden pattern 與比對器自動沿用，比對以 sample 為單位。
- Makefile / testbench 新增 `YUV`、`SPEED` 旋鈕；`make matrix` 擴充為
  RAW（18 種）+ YUV422（12 種）共 30 種組合，全數 PASS。
- **設定檢查**：模型在送資料前檢查 data_type、Hsize/Vsize、bit-packing 對齊
  與 `LANE_SPEED_MBPS` 範圍，違規即印出訊息並 `$finish`；testbench 於
  elaboration 階段擋下 `YUV=1` 搭配非 8/10-bit 的誤用。

### 注意

- YUV422 僅支援 8-bit / 10-bit（已由檢查強制擋下與 `FMT=12` 併用）。

---

## v1.0.0 (2026-06-02)

首版 MIPI Tx D-PHY behavioural model，可對接 M31 MIPI Rx D-PHY model。

### 新增功能

- **D-PHY 鏈路**
  - 4 條 data lane + 1 條 clock lane，連續時脈 (continuous-clock) HS 模式。
  - 每條 lane 最高 2.5 Gbps；UI 由 `UI_PS` 參數設定（預設 400 ps）。
  - 3-bit/pad 的數位 HS/LP 編碼（[2]=LP、[1]=HS、[0]=HS valid），
    與 M31 Rx model 介面一致。
  - LP-11 → LP-01 → LP-00 → HS-0 → sync(0xB8) → payload → HS-trail
    的完整進出 HS 流程。

- **影像 / 封包**
  - 支援最大 8K（Hsize × Vsize 可調，runtime input）。
  - RAW8 / RAW10 / RAW12 / RAW14 格式，含正確的 CSI-2 bit packing。
  - CSI-2 framing：Frame Start / line long packet / Frame End，
    含 6-bit ECC 與 CRC-16。
  - 4-lane byte round-robin 分配。

- **Skew Calibration**
  - 每條 data lane 可注入獨立 skew（`SKEW_Lx_PS`）。
  - `skew_cal_en` 控制每張 frame 前送出 deskew calibration burst
    （前導 0 + 0101… 切換樣式，長度可調）。

- **Golden Pattern 與比對**
  - 內建 pattern：ramp / horizontal gradient / vertical gradient /
    checkerboard / solid。
  - 支援 `golden_pattern.txt` 載入（每行一個十六進位值，自動依格式遮罩）。
  - `mipi_rx_checker` 比對 Rx 平行輸出 (Pxclk/Vsync/Hsync/Stb/Data[13:0])，
    回報 `pixel_count` / `error_count`，並提供可接 signal hierarchy 的預留 wire。

- **控制**
  - `trigger` input 控制傳輸起始時間，且可重複觸發。
  - `busy` / `frame_done` 狀態輸出。

- **驗證環境**
  - 自我比對 testbench `tb_mipi_tx_dphy.v` 與示範用 Rx 解碼模型
    `mipi_rx_dphy_stub.v`。
  - Icarus Verilog 用 `Makefile`，含回歸 `make matrix`。

### 驗證結果

- 以 Icarus Verilog 完成 RAW8 / RAW10 / RAW12 / RAW14 × pattern 0..5 的回歸，
  全數 PASS；含 deskew calibration（注入 40/90/150 ps skew）情境亦 PASS。
- 反向測試確認比對器能正確偵測 mismatch。

### 已知限制 / 注意事項

- 本模型為**行為模擬模型**，非可合成 RTL；D-PHY 時序經抽象化以加速模擬，
  必要時請依 M31 規格調整 `T_*_PS`。
- 示範用 `mipi_rx_dphy_stub.v` 在 bit 週期中央取樣，假設 data 與 clock
  對齊在同一 UI 格點，可容忍約 < UI/2 的 lane skew；正式驗證請替換為真正
  M31 model。
- 預設 CSI-2 framing 若與 M31 實作不同，需調整 `build_line` / `build_short`
  及比對器極性參數。
