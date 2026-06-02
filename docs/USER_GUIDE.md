# MIPI Tx D-PHY Model 使用說明

本專案以 Verilog 建立一個 **MIPI Tx D-PHY 行為模型 (behavioural model)**，
用來驅動並驗證 **M31 MIPI Rx D-PHY model**。

- 4 條 data lane + 1 條 clock lane，連續時脈 (continuous-clock) HS 模式
- 每條 lane 最高 **2.5 Gbps**；**只需設定 `LANE_SPEED_MBPS`，UI 與所有
  D-PHY 時序自動依 spec 推算**
- 最大 **8K** 影像尺寸（Hsize × Vsize 可調）
- 支援 **skew calibration**（per-lane skew 注入 + deskew calibration burst）
- 支援 **RAW8 / RAW10 / RAW12** 與 **YUV422 8-bit / 10-bit**，golden pattern
  位元數依格式自動選擇
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
│   ├── golden_pixel.v         # golden pattern 產生 / 載入（include 檔，非獨立 module）
│   └── mipi_csi2_func.v       # CSI-2 ECC / CRC-16 函式（include 檔，非獨立 module）
├── sim/
│   ├── tb_mipi_tx_dphy.v      # 自我比對 testbench
│   ├── mipi_rx_dphy_stub.v    # 示範用 Rx 解碼模型（替換成真正 M31 模型）
│   └── Makefile               # 編譯 / 模擬腳本（Icarus Verilog）
├── golden_pattern.txt         # 範例 golden pattern（pattern_sel = 5 時使用）
└── docs/
    ├── USER_GUIDE.md          # 本文件
    └── REVISION_HISTORY.md    # 改版資訊
```

> **編譯注意**：`golden_pixel.v` 與 `mipi_csi2_func.v` 是 **include 檔**
> （內含 `function`/`task`，被 `` `include `` 進其他 module，本身不是獨立
> module）。請**不要**把它們當頂層原始檔編譯，只要用 `-I rtl` 指定 include
> 路徑即可（Makefile 已如此設定）。避免使用 `iverilog rtl/*.v` 這種 glob，
> 否則會因 function 在 module 之外而報錯。

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
    .LANE_SPEED_MBPS(2500),  // 唯一的時序旋鈕：每條 lane 的 bit rate（<=2500）
    .SKEW_L0_PS(0), .SKEW_L1_PS(0), .SKEW_L2_PS(0), .SKEW_L3_PS(0),
    .GP_FILE("golden_pattern.txt")
) u_tx (
    .rst_n      (rst_n),       // 低有效 reset
    .trigger    (trigger),     // 拉高 -> 開始送資料（可重複觸發）
    .hsize      (hsize),       // 每行像素數（最大 7680）
    .vsize      (vsize),       // 每張影像行數（最大 4320）
    .data_type  (data_type),   // 見下方 data type 表
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
| `LANE_SPEED_MBPS`   | 2500    | **唯一時序旋鈕**：每條 lane 的 bit rate（Mbps，<=2500）。UI 與所有 D-PHY 時序自動推算 |
| `SKEW_Lx_PS`        | 0       | 每條 data lane 注入的 skew（ps）                |
| `SKEW_PREAMBLE`     | 32      | deskew burst 前導的 0 bit 數                     |
| `SKEW_CAL_BITS`     | 256     | deskew burst 中 0101… 切換的 bit 數              |
| `GP_FILE`           | golden_pattern.txt | 外部 golden pattern 檔路徑          |
| `VC`                | 0       | CSI-2 Virtual Channel                            |

### 時序自動計算

你只要設定 `LANE_SPEED_MBPS`，**UI 與所有 D-PHY HS 進出時序都會自動依
MIPI D-PHY spec 推算最佳（spec 最小）值**，並向上取整成整數個 UI（保證
≥ spec 下限，且 data bit 對齊到 DDR clock 格點）。使用者不需手動設定時序。

```
UI(ps) = 1,000,000 / LANE_SPEED_MBPS        例：2500 -> 400 ps

採用的 spec 關係式（最小值）：
  T-LPX                      >= 50 ns
  T-HS-PREPARE               >= 40 ns + 4*UI
  T-HS-PREPARE + T-HS-ZERO   >= 145 ns + 10*UI
  T-HS-TRAIL                 >= max(8*UI, 60 ns + 4*UI)
  T-CLK-PREPARE              >= 38 ns
  T-CLK-PREPARE + T-CLK-ZERO >= 300 ns
  T-CLK-TRAIL                >= 60 ns
  T-CLK-PRE                  >= 8*UI（clock 先進 HS 才送 data）
  T-CLK-POST                 >= 60 ns + 52*UI
```

模型啟動時會印出實際採用的時序，例如：

```
[tx] auto timing @ 2500Mbps: UI=400 LPX=50000 HS_PREP=41600 HS_ZERO=107600 ...
```

> **提醒**：示範用 Rx 在 bit 週期中央取樣，可容忍約 < UI/2 的注入 skew；
> 真正 M31 model 的容忍範圍依其 spec。

---

## 4. 封包格式（CSI-2）

### 支援的 data type

| `data_type` | 格式         | sample 位元數 | samples / pixel | packing             |
|-------------|--------------|---------------|-----------------|---------------------|
| `0x2A`      | RAW8         | 8             | 1               | 每 sample 1 byte    |
| `0x2B`      | RAW10        | 10            | 1               | 4 samples → 5 bytes |
| `0x2C`      | RAW12        | 12            | 1               | 2 samples → 3 bytes |
| `0x1E`      | YUV422 8-bit | 8             | 2 (Cb,Y0,Cr,Y1) | 每 sample 1 byte    |
| `0x1F`      | YUV422 10-bit| 10            | 2 (Cb,Y0,Cr,Y1) | 4 samples → 5 bytes |

> YUV422 每個 pixel 帶 2 個 component（取樣），所以每行的 sample 數 = `2*Hsize`，
> packing 與相同位元數的 RAW 完全一致（YUV8 同 RAW8、YUV10 同 RAW10）。
> 模型把每個 component 當成一個 sample 送出，Rx 端則逐一輸出在 `Data` 上。

對齊需求：RAW10 / YUV10 的 sample 數需為 4 的倍數、RAW12 的 sample 數需為 2
的倍數（即 RAW10 `Hsize%4==0`、RAW12 `Hsize%2==0`、YUV10 `Hsize%2==0`）。

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
- Long packet payload：依格式做 RAW8/10/12 或 YUV422 8/10-bit packing
- Packet Footer：CSI-2 CRC-16（poly 0x1021 反射形式，初值 0xFFFF）
- 4 條 lane 以 byte 為單位 round-robin 分配；每條 lane 起始送 sync byte `0xB8`
- Clock lane 採連續時脈，整張 frame 期間持續輸出 DDR clock

> 若實際 M31 model 採用不同的 framing，請依其文件調整
> `build_line` / `build_short` 與時序參數。

---

## 5. Golden Pattern

`pattern_sel` 選擇 golden pattern，位元數依 `data_type` 自動套用遮罩
（RAW8 / YUV8→8、RAW10 / YUV10→10、RAW12→12 bit）。pattern 以 sample 為單位
產生（YUV422 的每個 component 都是一個 sample，`col` 索引跑遍 `2*Hsize`）：

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

# YUV422 8-bit / 10-bit
make YUV=1 FMT=8
make YUV=1 FMT=10

# 改 lane speed（時序自動推算）
make SPEED=1500

# 開啟 skew 注入 + deskew calibration
make SKEW=1

# 回歸（RAW 18 種 + YUV422 12 種）
make matrix

# 開波形
make wave
```

testbench 的 `+define` 旋鈕：`FMT`(8/10/12)、`YUV`(0/1)、`SPEED`(Mbps)、
`HS`、`VS`、`PAT`(0..5)、`NF`、`SKEW`(0/1)。

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
3. 視 M31 規格調整：`LANE_SPEED_MBPS`（時序會自動推算）、CSI-2 framing、
   以及比對器的極性參數。
4. 重新 `make` 執行比對。

> `mipi_rx_dphy_stub.v` 僅供整條鏈路自我測試使用，不代表 M31 的實際行為。
