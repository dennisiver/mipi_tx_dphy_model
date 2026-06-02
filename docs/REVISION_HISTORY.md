# 改版資訊 (Revision History)

| 版本   | 日期       | 說明 |
|--------|------------|------|
| v1.0.0 | 2026-06-02 | 首次釋出。 |

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
  - RAW8 / RAW10 / RAW12 三種格式，含正確的 CSI-2 bit packing。
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
  - `mipi_rx_checker` 比對 Rx 平行輸出 (Pxclk/Vsync/Hsync/Stb/Data[11:0])，
    回報 `pixel_count` / `error_count`，並提供可接 signal hierarchy 的預留 wire。

- **控制**
  - `trigger` input 控制傳輸起始時間，且可重複觸發。
  - `busy` / `frame_done` 狀態輸出。

- **驗證環境**
  - 自我比對 testbench `tb_mipi_tx_dphy.v` 與示範用 Rx 解碼模型
    `mipi_rx_dphy_stub.v`。
  - Icarus Verilog 用 `Makefile`，含回歸 `make matrix`。

### 驗證結果

- 以 Icarus Verilog 完成 RAW8 / RAW10 / RAW12 × pattern 0..5 的回歸，
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
