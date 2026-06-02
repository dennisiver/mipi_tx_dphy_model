# MIPI Tx D-PHY Model 使用說明

本專案以 Verilog 建立一個 **MIPI Tx D-PHY 行為模型 (behavioural model)**，
用來驅動並驗證 **M31 MIPI Rx D-PHY model**。

- 4 條 data lane + 1 條 clock lane，連續時脈 (continuous-clock) HS 模式
- 每條 lane 最高 **2.5 Gbps**（UI 可調，預設 400 ps）
- 最大 **8K** 影像尺寸（Hsize × Vsize 可調）
- 支援 **skew calibration**（per-lane skew 注入 + deskew calibration burst）
- 支援 **RAW8 / RAW10 / RAW12**，golden pattern 位元數依格式自動選擇
- 多種內建 golden pattern + 可由 `golden_pattern.txt` 載入
- **input trigger** 控制 Tx 開始送資料的時間
- 內建 Rx 平行輸出 (Pxclk/Vsync/Hsync/Stb/Data) 的 **比對器**

---

## 1. 檔案結構

```
mipi_tx_dphy_model/
├── rtl/
│   ├── mipi_tx_dphy_model.v   # Tx D-PHY 頂層模型（主檔）
│   ├── mipi_rx_checker.v      # Rx 平行輸出比對器
│   ├── golden_pixel.vh        # golden pattern 產生 / 載入（Tx、checker 共用）
│   └── mipi_csi2_func.vh      # CSI-2 ECC / CRC-16 函式
├── sim/
│   ├── tb_mipi_tx_dphy.v      # 自我比對 testbench
│   ├── mipi_rx_dphy_stub.v    # 示範用 Rx 解碼模型（替換成真正 M31 模型）
│   └── Makefile               # 編譯 / 模擬腳本（Icarus Verilog）
├── golden_pattern.txt         # 範例 golden pattern（pattern_sel = 5 時使用）
└── docs/
    ├── USER_GUIDE.md          # 本文件
    └── REVISION_HISTORY.md    # 改版資訊
```

---

## 2. 介面：3-bit 數位 HS/LP 編碼

為了用數位方式模擬 High-Speed 與 Low-Power 訊號，每個 pad（P 或 N）拆成 3 bits，
與 M31 Rx model 完全一致：

| bit  | 名稱            | 說明                                                            |
|------|-----------------|-----------------------------------------------------------------|
| [2]  | Low-Power 訊號  | 在 LP 狀態驅動 LP 準位；進入 HS 後維持 0                          |
| [1]  | High-Speed 訊號 | P = bit，N = ~bit；只有在 [0] = 1 時才有效，其餘時間維持 0        |
| [0]  | High-Speed valid| 從 HS-Zero 開始拉高，直到回到 LP 才拉低                          |

Lane 對應（與 M31 預設相同）：

```
PAD_CDRX_L0P/N = data lane 0
PAD_CDRX_L1P/N = data lane 1
PAD_CDRX_L2P/N = data lane 2
PAD_CDRX_L3P/N = data lane 3
PAD_CDRX_L4P/N = clock lane
```

LP 狀態編碼（pad[2] = LP 準位）：

| 狀態   | Dp | Dn | 用途                       |
|--------|----|----|----------------------------|
| LP-11  | 1  | 1  | Stop state（待命）          |
| LP-01  | 0  | 1  | HS request 過程             |
| LP-00  | 0  | 0  | HS prepare（進入 HS 前）    |

HS 狀態：`P = {1'b0, bit, 1'b1}`、`N = {1'b0, ~bit, 1'b1}`。

---

## 3. Tx 頂層 Port

```verilog
mipi_tx_dphy_model #(
    .UI_PS(400),          // 1 UI = 400 ps -> 2.5 Gbps（可調整線速）
    .SKEW_L0_PS(0), .SKEW_L1_PS(0), .SKEW_L2_PS(0), .SKEW_L3_PS(0),
    .GP_FILE("golden_pattern.txt")
) u_tx (
    .rst_n      (rst_n),       // 低有效 reset
    .trigger    (trigger),     // 拉高 -> 開始送資料（可重複觸發）
    .hsize      (hsize),       // 每行像素數（最大 7680）
    .vsize      (vsize),       // 每張影像行數（最大 4320）
    .data_type  (data_type),   // 0x2A=RAW8, 0x2B=RAW10, 0x2C=RAW12
    .pattern_sel(pattern_sel), // 0..5（見第 5 節）
    .solid_val  (solid_val),   // solid pattern 的固定值
    .num_frames (num_frames),  // 每次觸發送幾張 frame
    .skew_cal_en(skew_cal_en), // 1 = 每張 frame 前送 deskew calibration burst
    /* 10 條 pad bus 連到 M31 Rx ... */
    .busy       (busy),        // 傳輸中
    .frame_done (frame_done)   // 每張 frame 完成時送出 1-cycle 脈衝
);
```

### 主要參數

| 參數                | 預設    | 說明                                            |
|---------------------|---------|-------------------------------------------------|
| `UI_PS`             | 400     | 1 個 UI 的 ps 數；400 ps = 2.5 Gbps             |
| `T_*_PS`            | 見原始碼| 抽象化的 D-PHY 時序（建議維持 UI 的整數倍）      |
| `SKEW_Lx_PS`        | 0       | 每條 data lane 注入的 skew（ps）                |
| `SKEW_PREAMBLE`     | 32      | deskew burst 前導的 0 bit 數                     |
| `SKEW_CAL_BITS`     | 256     | deskew burst 中 0101… 切換的 bit 數              |
| `GP_FILE`           | golden_pattern.txt | 外部 golden pattern 檔路徑          |
| `VC`                | 0       | CSI-2 Virtual Channel                            |

> **時序提醒**：模型在 bit 週期中央取樣，並假設 data 與 clock 對齊在同一個
> UI 格點上。請讓所有 `T_*_PS` 維持 `UI_PS` 的整數倍，注入的 skew 也應小於
> 約 UI/2，示範用 Rx 才能正確解碼（真正 M31 model 的容忍範圍依其 spec）。

---

## 4. 封包格式（CSI-2）

每張 frame 的傳送順序：

```
[deskew calibration burst]（skew_cal_en=1 時）
Frame Start  (short packet, DT=0x00)
line 0       (long packet,  DT=data_type)
line 1
  ...
line Vsize-1
Frame End    (short packet, DT=0x01)
```

- Packet Header：`DI, WC_L, WC_H, ECC`（含 MIPI 6-bit ECC）
- Long packet payload：依格式做 RAW8/10/12 bit packing
- Packet Footer：CSI-2 CRC-16（poly 0x1021 反射形式，初值 0xFFFF）
- 4 條 lane 以 byte 為單位 round-robin 分配；每條 lane 起始送 sync byte `0xB8`
- Clock lane 採連續時脈，整張 frame 期間持續輸出 DDR clock

> 若實際 M31 model 採用不同的 framing，請依其文件調整
> `build_line` / `build_short` 與時序參數。

---

## 5. Golden Pattern

`pattern_sel` 選擇 golden pattern，位元數依 `data_type` 自動套用遮罩
（RAW8→8、RAW10→10、RAW12→12 bit）：

| pattern_sel | 名稱              | 內容                                   |
|-------------|-------------------|----------------------------------------|
| 0           | sequential / ramp | 連續遞增值 `(row*hsize + col + frame)` |
| 1           | horizontal gradient | 值隨欄位 `col` 變化                   |
| 2           | vertical gradient | 值隨行 `row` 變化                      |
| 3           | checkerboard      | 8×8 方格的滿格 / 0                      |
| 4           | solid             | 固定值 `solid_val`                     |
| 5           | from file         | 由 `golden_pattern.txt` 載入           |

### golden_pattern.txt 格式

- 每行一個 **十六進位** 值（`#` 開頭為註解、空白行會被略過）
- 讀入後依資料格式自動遮罩到對應位元數
- 像素索引 `row*hsize + col`，超出檔案長度時循環取用

範例：

```
000
0AA
0FF
155
```

---

## 6. Skew Calibration

1. **Per-lane skew 注入**：用 `SKEW_Lx_PS` 對各條 data lane 注入不同延遲，
   模擬實際走線造成的 lane 間 skew。
2. **Deskew calibration burst**：`skew_cal_en = 1` 時，每張 frame 前會送出
   一段（前導 0 + 連續 0101…）的校正樣式，供 M31 Rx 做 per-lane deskew。

`SKEW_PREAMBLE`、`SKEW_CAL_BITS` 可調整校正樣式長度。

---

## 7. Rx 比對器與「預留 wire」

`mipi_rx_checker` 直接比對 Rx 的平行輸出：

```
Pxclk, Vsync, Hsync, Stb, Data[11:0]
```

testbench 中以一組 **預留 wire** 接出，方便從任意 signal hierarchy 取訊號：

```verilog
wire        rx_pxclk;
wire        rx_vsync;
wire        rx_hsync;
wire        rx_stb;
wire [11:0] rx_data;
```

接真正 M31 model 時，把這些 wire 改接到 M31 的平行輸出埠即可，例如：

```verilog
assign rx_pxclk = u_m31.PXCLK;
assign rx_vsync = u_m31.VSYNC;
assign rx_hsync = u_m31.HSYNC;
assign rx_stb   = u_m31.STB;
assign rx_data  = u_m31.DATA;
```

比對器假設 `Stb` 高 = 該 Pxclk 有有效像素、`Vsync/Hsync` 前緣分別代表
frame/line 起始。若 M31 極性不同，可用 `VSYNC_ACT / HSYNC_ACT / STB_ACT`
參數調整。比對結果用 `error_count`、`pixel_count` 回報，或呼叫 `U_CHK.report`。

---

## 8. 模擬流程（Icarus Verilog）

```bash
cd sim

# 預設：RAW10、64x8、ramp、2 frames
make

# 指定格式 / 尺寸 / pattern / frame 數
make FMT=12 HS=128 VS=16 PAT=2 NF=1

# 開啟 skew 注入 + deskew calibration
make SKEW=1

# 小型回歸（所有格式 × 所有 pattern）
make matrix

# 開波形
make wave
```

testbench 的 `+define` 旋鈕：`FMT`(8/10/12)、`HS`、`VS`、`PAT`(0..5)、
`NF`、`SKEW`(0/1)。

通過時輸出：

```
[chk] ==== compare summary ====
[chk] pixels checked : N
[chk] mismatches     : 0
[chk] RESULT : PASS
```

---

## 9. 接上真正的 M31 Rx D-PHY model

1. 在 `tb_mipi_tx_dphy.v` 中，把 `mipi_rx_dphy_stub` (U_RX) 換成 M31 的
   instance，pad 名稱對應 `PAD_CDRX_L0P/N … L4P/N`。
2. 把第 7 節的 `rx_*` 預留 wire 接到 M31 的平行輸出。
3. 視 M31 規格調整：`UI_PS`、各 `T_*_PS` 時序、CSI-2 framing、以及
   比對器的極性參數。
4. 重新 `make` 執行比對。

> `mipi_rx_dphy_stub.v` 僅供整條鏈路自我測試使用，不代表 M31 的實際行為。
