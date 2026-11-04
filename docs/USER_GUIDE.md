# MIPI Tx D-PHY Model 使用說明

Timing knobs:
- `PACKET_INTERVAL_NS`: extra LP-11 gap between CSI-2 packets, in ns. Default: `2000`.
- `VBLANK_NS`: extra LP-11 gap after the FE short packet before the next FS short packet, in ns. Default: `10000`.
- Example: `.VBLANK_NS(1000)` adds 1000 ns after FE before the next FS.

本專案以 Verilog 建立一個 **MIPI Tx D-PHY 行為模型 (behavioural model)**，
用來驅動並驗證 **M31 MIPI Rx D-PHY model**。

- 1 / 2 / 4 條 active data lane + 1 條 clock lane，連續時脈 (continuous-clock) HS 模式
- 每條 lane 最高 **2.5 Gbps**；**只需設定 `LANE_SPEED_MBPS`，UI 與所有
  D-PHY 時序自動依 spec 推算**
- 最大 **8K** 影像尺寸（Hsize × Vsize 可調）
- 支援 **skew calibration**（per-lane skew 注入 + deskew calibration burst）
- 支援 **RAW8 / RAW10 / RAW12 / RAW14** 與 **YUV422 8-bit / 10-bit**，golden pattern
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
PAD_CDTX_L0P/N = data lane 0
PAD_CDTX_L1P/N = data lane 1
PAD_CDTX_L2P/N = data lane 2
PAD_CDTX_L3P/N = data lane 3
PAD_CDTX_L4P/N = clock lane
```

接到 M31 Rx D-PHY model 時，Tx 端 `PAD_CDTX_*` 對接 Rx 端 `PAD_CDRX_*`。

LP 狀態編碼（pad[2] = LP 準位）：

| 狀態   | Dp | Dn | 用途                       |
|--------|----|----|----------------------------|
| LP-11  | 1  | 1  | Stop state（待命）          |
| LP-01  | 0  | 1  | HS request 過程             |
| LP-00  | 0  | 0  | HS prepare（進入 HS 前）    |

HS 狀態：`P = {1'b0, bit, 1'b1}`、`N = {1'b0, ~bit, 1'b1}`。

---

## 3. Tx 頂層 Parameter / Port

```verilog
mipi_tx_dphy_model #(
    .LANE_SPEED_MBPS(2500),  // 每條 lane 的 bit rate（<=2500）；D-PHY 時序自動推算
    .LANE_NUM       (4),     // active data lanes: 1 / 2 / 4
    .HSIZE          (64),    // 每行像素數（最大 7680）
    .VSIZE          (8),     // 每張影像行數（最大 4320）
    .PACKET_INTERVAL_NS(2000),  // CSI-2 packet 間的 LP-11 gap，單位 ns；包含 FS/FE short packet
    .DATA_TYPE      (8'h2B), // 見下方 data type 表
    .PATTERN_SEL    (0),     // 0..5（見第 5 節）
    .SOLID_VAL      (14'h03AA),
    .NUM_FRAMES     (2),
    .SKEW_CAL_EN    (0),
    .SKEW_L0_PS(0), .SKEW_L1_PS(0), .SKEW_L2_PS(0), .SKEW_L3_PS(0),
    .GP_FILE("golden_pattern.txt")
) u_tx (
    .rst_n      (rst_n),       // 低有效 reset
    .trigger    (trigger),     // 拉高 -> 開始送資料（可重複觸發）
    /* 10 條 pad bus 連到 M31 Rx ... */
    .busy       (busy),        // 傳輸中
    .frame_done (frame_done)   // 每張 frame 完成時送出 1-cycle 脈衝
);
```

### 主要參數

| 參數                | 預設    | 說明                                            |
|---------------------|---------|-------------------------------------------------|
| `LANE_SPEED_MBPS`   | 2500    | 每條 lane 的 bit rate（Mbps，<=2500）。UI 與所有 D-PHY HS 進出時序自動推算 |
| `LANE_NUM`          | 4       | active data lane 數，支援 1 / 2 / 4             |
| `HSIZE`             | 64      | 每行 active pixel 數（最大 7680）               |
| `VSIZE`             | 8       | 每張 frame active line 數（最大 4320）          |
| `PACKET_INTERVAL_NS`| 2000    | CSI-2 packet 之間額外插入的 LP-11 gap，單位 ns；會套用在 FS short packet、每條 image line long packet、FE short packet 之間 |
| `DATA_TYPE`         | 0x2B    | CSI-2 data type：RAW8 / RAW10 / RAW12 / RAW14 / YUV422 |
| `PATTERN_SEL`       | 0       | golden pattern 選擇（0..5）                     |
| `SOLID_VAL`         | 0x3AA   | `PATTERN_SEL=4` 時使用的固定 sample 值          |
| `NUM_FRAMES`        | 2       | 每次 trigger 送出的 frame 數；0 會視為 1         |
| `SKEW_CAL_EN`       | 0       | 1 = 每張 frame 前送 deskew calibration burst    |
| `SKEW_Lx_PS`        | 0       | 每條 data lane 注入的 skew（ps）                |
| `SKEW_PREAMBLE`     | 32      | deskew burst 前導的 0 bit 數                     |
| `SKEW_CAL_BITS`     | 256     | deskew burst 中 0101… 切換的 bit 數              |
| `GP_FILE`           | golden_pattern.txt | 外部 golden pattern 檔路徑          |
| `VC`                | 0       | CSI-2 Virtual Channel                            |

### 時序自動計算

你只要設定 `LANE_SPEED_MBPS`，**UI 與所有 D-PHY HS 進出時序都會自動依
MIPI D-PHY spec 推算最佳（spec 最小）值**，並向上取整成整數個 UI（保證
≥ spec 下限，且 data bit 對齊到 DDR clock 格點）。使用者不需手動設定時序。

`PACKET_INTERVAL_NS` 是 CSI-2 packet 間的額外 idle gap，單位為 ns。模型內部
`timescale` 是 `1ps/1ps`，因此會自動乘以 1000 轉成 ps delay。此 gap 不是
D-PHY HS entry/exit spec timing 的一部分；它是在一個 packet 完成並回到 LP-11
之後、下一個 packet 開始之前插入，default `2000` 表示額外等待 2000 ns。

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
[tx] auto timing @ 2500Mbps: UI=400 LPX=50000 HS_PREP=41600 HS_ZERO=107600 ... packet_interval=0 (ns)
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
| `0x2D`      | RAW14        | 14            | 1               | 4 samples → 7 bytes |
| `0x1E`      | YUV422 8-bit | 8             | 2 (Cb,Y0,Cr,Y1) | 每 sample 1 byte    |
| `0x1F`      | YUV422 10-bit| 10            | 2 (Cb,Y0,Cr,Y1) | 4 samples → 5 bytes |

> YUV422 每個 pixel 帶 2 個 component（取樣），所以每行的 sample 數 = `2*Hsize`，
> packing 與相同位元數的 RAW 完全一致（YUV8 同 RAW8、YUV10 同 RAW10）。
> 模型把每個 component 當成一個 sample 送出，Rx 端則逐一輸出在 `Data` 上。

對齊需求：RAW10 / RAW14 / YUV10 的 sample 數需為 4 的倍數、RAW12 的 sample
數需為 2 的倍數（即 RAW10 `Hsize%4==0`、RAW12 `Hsize%2==0`、
RAW14 `Hsize%4==0`、YUV10 `Hsize%2==0`）。

> **內建設定檢查**：模型會在每次觸發送資料前自動檢查設定，違規時印出明確
> 訊息並停止模擬（`$finish`），避免產生錯誤資料：
> - `data_type` 非支援值
> - `Hsize`/`Vsize` 為 0、或超過 8K
> - 上述 bit-packing 對齊不符
> - `LANE_SPEED_MBPS` 超出 1..2500 範圍
> - `PACKET_INTERVAL_NS` 小於 0
>
> testbench 另在 elaboration 階段檢查 `YUV=1` 只能搭配 `FMT=8/10`。

每張 frame 的傳送順序：

```
[deskew calibration burst]（skew_cal_en=1 時）
Frame Start  (short packet, DT=0x00)
[PACKET_INTERVAL_NS gap]
line 0       (long packet,  DT=data_type)
[PACKET_INTERVAL_NS gap]
line 1
  ...
line Vsize-1
[PACKET_INTERVAL_NS gap]
Frame End    (short packet, DT=0x01)
```

- Packet Header：`DI, WC_L, WC_H, ECC`（含 MIPI 6-bit ECC）
- Long packet payload：依格式做 RAW8/10/12/14 或 YUV422 8/10-bit packing
- Packet Footer：CSI-2 CRC-16（poly 0x1021 反射形式，初值 0xFFFF）
- 4 條 lane 以 byte 為單位 round-robin 分配；每條 lane 起始送 sync byte `0xB8`
- Clock lane 採連續時脈，整張 frame 期間持續輸出 DDR clock
- `PACKET_INTERVAL_NS` 會影響 packet-to-packet 的間隔，包含 FS/FE short packet；
  例如 `.PACKET_INTERVAL_NS(100)` 代表每個 packet 後額外等待 100 ns 再送下一個 packet

> 若實際 M31 model 採用不同的 framing，請依其文件調整
> `build_line` / `build_short` 與時序參數。

---

## 5. Golden Pattern

`PATTERN_SEL` 選擇 golden pattern，位元數依 `DATA_TYPE` 自動套用遮罩
（RAW8 / YUV8→8、RAW10 / YUV10→10、RAW12→12 bit、RAW14→14 bit）。pattern 以 sample 為單位
產生（YUV422 的每個 component 都是一個 sample，`col` 索引跑遍 `2*Hsize`）：

| PATTERN_SEL | 名稱              | 內容                                   |
|-------------|-------------------|----------------------------------------|
| 0           | sequential / ramp | 連續遞增值 `(row*samples_per_line + col + frame)` |
| 1           | horizontal gradient | 值隨欄位 `col` 變化                   |
| 2           | vertical gradient | 值隨行 `row` 變化                      |
| 3           | checkerboard      | 8×8 方格的滿格 / 0                      |
| 4           | solid             | 固定值 `SOLID_VAL`                     |
| 5           | from file         | 由 `golden_pattern.txt` 載入           |

### 5.1 相關 Port / Parameter

Golden pattern 由 Tx 的 instance parameter 控制：

| 名稱          | 類型      | 預設 / 範圍          | 說明 |
|---------------|-----------|----------------------|------|
| `PATTERN_SEL` | parameter | `0..5`               | 選擇要送出的 pattern。testbench 用 Makefile 參數 `PAT` 指定。 |
| `SOLID_VAL`   | parameter | 14-bit value         | `PATTERN_SEL=4` 時送出的固定值；會依 RAW/YUV 位元數自動 mask。 |
| `GP_FILE`     | parameter | `"golden_pattern.txt"` | `PATTERN_SEL=5` 時讀取的外部 pattern 檔案路徑。 |
| `GP_MAX`      | parameter | `65536`              | 最多從 `GP_FILE` 載入的 sample 數。 |

這些都是 elaboration-time parameter，需要在 instantiate Tx / checker 時指定。

checker 端也要使用相同設定：

```verilog
mipi_rx_checker #(
    .BITS    (10),
    .HSIZE   (hsize_used_by_tx),
    .PATTERN (pattern_sel_used_by_tx),
    .SOLID   (solid_val_used_by_tx),
    .GP_FILE ("golden_pattern.txt")
) u_chk (...);
```

目前 testbench 中 `SOLID` 固定為 `14'h03AA`，Tx 的 `SOLID_VAL` 也設為同一個值。

### 5.2 使用範例

使用內建 ramp pattern：

```bash
cd sim
make FMT=10 PAT=0
```

使用 checkerboard pattern：

```bash
make FMT=12 PAT=3
```

使用 solid pattern。testbench 預設固定值為 `14'h03AA`：

```bash
make FMT=10 PAT=4
```

若要改 solid value，請在自己的 testbench 中設定 Tx 的 `SOLID_VAL`，並同步設定
checker 的 `SOLID`：

```verilog
localparam [13:0] SOLID_PATTERN = 14'h0155;

mipi_tx_dphy_model #(
    .PATTERN_SEL(4),
    .SOLID_VAL  (SOLID_PATTERN)
) u_tx (...);

mipi_rx_checker #(
    .BITS (10),
    .HSIZE(64),
    .PATTERN(4),
    .SOLID(SOLID_PATTERN)
) u_chk (...);
```

使用外部 golden pattern 檔：

```bash
make FMT=10 PAT=5
make FMT=10 PAT=5 GP_FILE=patterns/my_golden_pattern.txt
```

若檔案不在 repo root，請在 Tx 與 checker 使用相同的 `GP_FILE`：

```verilog
mipi_tx_dphy_model #(
    .GP_FILE("../patterns/my_golden_pattern.txt"),
    .GP_MAX (131072)
) u_tx (...);

mipi_rx_checker #(
    .HSIZE (64),
    .GP_FILE("../patterns/my_golden_pattern.txt"),
    .GP_MAX (131072)
) u_chk (...);
```

### golden_pattern.txt 格式

- 每行一個 **十六進位** 值（`#` 開頭為註解、空白行會被略過）
- 讀入後依資料格式自動遮罩到對應位元數
- sample 索引依 `golden_pixel(frame,row,col,hsize,...)` 計算為 `row*hsize + col`，
  其中 `hsize` 為**每行 sample 數**（RAW = `Hsize`，YUV422 = `2*Hsize`）；
  YUV422 時檔案即依每行 `2*Hsize` 個 component（Cb,Y0,Cr,Y1,...）連續排列
- 超出檔案長度時會循環取用，也就是 `index % loaded_count`

範例：

```
000
0AA
0FF
155
```

---

## 6. Skew Calibration

本 model 提供兩個互相搭配的功能：

1. **Per-lane skew injection**：在 Tx 端故意讓每條 data lane 的 HS burst 起跑時間
   加上不同延遲，模擬 PCB routing、封裝或 PHY 造成的 lane-to-lane skew。
2. **Deskew calibration burst**：在正式 CSI-2 frame packet 前送出一段校正用 HS pattern，
   供 Rx D-PHY 做 lane deskew / alignment。

### 6.1 Per-Lane Skew Injection

每條 data lane 可用獨立參數設定延遲量，單位是 ps：

```verilog
parameter integer SKEW_L0_PS = 0,
parameter integer SKEW_L1_PS = 0,
parameter integer SKEW_L2_PS = 0,
parameter integer SKEW_L3_PS = 0,
```

這些延遲只套用在 data lane 的 HS burst 開始前，不會改變 payload 內容。概念上：

```text
lane0: |HS burst starts here|
lane1:      |HS burst starts here|   + SKEW_L1_PS
lane2:           |HS burst starts here| + SKEW_L2_PS
lane3:                |HS burst starts here| + SKEW_L3_PS
```

testbench 中 `make SKEW=1` 會依 `UI_PS` 比例產生示範 skew，改變 `SPEED` 時 skew
也會跟著縮放：

```verilog
SKEW_L0_PS = 0
SKEW_L1_PS = UI_PS / 10
SKEW_L2_PS = UI_PS / 4
SKEW_L3_PS = UI_PS * 3 / 8
```

例如 `SPEED=2500` 時 `UI_PS=400`，上述值約為 40 ps / 100 ps / 150 ps。
這些值刻意保持小於 `UI/2`，方便示範用 `mipi_rx_dphy_stub` 正確取樣。接真正
M31 Rx model 時，可依 M31 spec 與欲驗證的 skew margin 調整。

### 6.2 Deskew Calibration Burst

`SKEW_CAL_EN = 1` 時，每張 frame 前會先送 deskew calibration burst，再送 CSI-2
Frame Start / line packets / Frame End：

```text
clock lane 進入 HS continuous clock
[deskew calibration burst]  <-- SKEW_CAL_EN=1 時送出
Frame Start short packet
line 0 long packet
line 1 long packet
...
Frame End short packet
```

calibration burst 的 pattern 由兩個參數控制：

| 參數             | 預設 | 說明                                      |
|------------------|------|-------------------------------------------|
| `SKEW_PREAMBLE`  | 32   | burst 開頭連續送出的 0 bit 數              |
| `SKEW_CAL_BITS`  | 256  | preamble 後連續送出的 `0101...` toggle bit 數 |

實際送出的 bit 序列概念如下：

```text
000000...0000 010101010101...
^ preamble    ^ calibration toggle pattern
```

Tx 會在 `LANE_NUM` 條 active data lane 同時送出這段 calibration burst，但每條 lane 仍會套用
`SKEW_Lx_PS`。因此 Rx 可以利用這段固定且容易偵測的 pattern 估計各 lane 相對時間差，
再對後續 CSI-2 packet 做 deskew。

### 6.3 使用範例

使用 Makefile 開啟 skew injection 與 calibration burst：

```bash
cd sim
make SKEW=1
```

若要在自己的 testbench 直接設定 Tx instance，可寫成：

```verilog
localparam integer LANE_SPEED_MBPS = 2500;
localparam integer UI_PS = 1000000 / LANE_SPEED_MBPS;

mipi_tx_dphy_model #(
    .LANE_SPEED_MBPS(LANE_SPEED_MBPS),
    .SKEW_L0_PS(0),
    .SKEW_L1_PS(UI_PS / 10),
    .SKEW_L2_PS(UI_PS / 4),
    .SKEW_L3_PS(UI_PS * 3 / 8),
    .SKEW_CAL_EN(1),
    .SKEW_PREAMBLE(32),
    .SKEW_CAL_BITS(256)
) u_tx (
    // other ports...
);
```

若只想注入 skew、但不送 calibration burst，可設定 `SKEW_Lx_PS` 非 0，
並讓 `SKEW_CAL_EN = 0`。這種情境可用來觀察 Rx 在沒有 deskew training 時的容忍度。

---

## 7. Rx 比對器與「預留 wire」

testbench 內建的 `mipi_rx_dphy_stub.v` 加上 `mipi_rx_checker.v` 可視為
simulation/self-test 用的簡化 Rx model：

```
mipi_tx_dphy_model
    -> D-PHY lanes
    -> mipi_rx_dphy_stub
    -> Pxclk/Vsync/Hsync/Stb/Data
    -> mipi_rx_checker
```

其中 `mipi_rx_dphy_stub` 負責接收 Tx 的 D-PHY digital pad encoding，使用
clock lane L4 取樣 data lane L0~L3，解出 CSI-2 packet，並輸出類似 Rx
parallel video interface 的訊號；`mipi_rx_checker` 則將這些平行輸出與
golden pattern 比對。這組模型適合驗證 Tx 的 D-PHY lane mapping、CSI-2
framing、packet/pixel data 與基本時序，但它不是完整的 M31 Rx IP model。
若要驗證實際 M31 Rx 行為，仍需依第 9 節替換成真正的 M31 Rx D-PHY model
並接上實際 MIPI RX controller。

`mipi_rx_checker` 直接比對 Rx 的平行輸出：

```
Pxclk, Vsync, Hsync, Stb, Data[13:0]
```

`Data[13:0]` is MSB-aligned by format:

| Format | Valid bits on `Data[13:0]` |
|--------|-----------------------------|
| RAW8 / YUV422_8 | `Data[13:6]` |
| RAW10 / YUV422_10 | `Data[13:4]` |
| RAW12 | `Data[13:2]` |
| RAW14 | `Data[13:0]` |

testbench 中以一組 **預留 wire** 接出，方便從任意 signal hierarchy 取訊號：

```verilog
wire        rx_pxclk;
wire        rx_vsync;
wire        rx_hsync;
wire        rx_stb;
wire [13:0] rx_data;
```

接真正 M31 Rx D-PHY model 時，M31 model 輸出的是 PPI 介面，不是最終
parallel video port。請先把 M31 的 PPI output 接到設計裡的 MIPI RX
controller，再將這些 checker wire 接到 MIPI RX controller 的平行輸出，例如：

```verilog
assign rx_pxclk = u_mipi_rx_controller.PXCLK;
assign rx_vsync = u_mipi_rx_controller.VSYNC;
assign rx_hsync = u_mipi_rx_controller.HSYNC;
assign rx_stb   = u_mipi_rx_controller.STB;
assign rx_data  = u_mipi_rx_controller.DATA;
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
make FMT=14 HS=128 VS=16 PAT=2 NF=1

# YUV422 8-bit / 10-bit
make YUV=1 FMT=8
make YUV=1 FMT=10

# 改 lane speed（時序自動推算）
make SPEED=1500

# 開啟 skew 注入 + deskew calibration
make SKEW=1

# 指定 active data lane 數
make LANE_NUM=2

# 回歸（RAW 24 種 + YUV422 12 種）
make matrix

# 開波形
make wave
```

testbench 的 `+define` 旋鈕：`FMT`(8/10/12/14)、`YUV`(0/1)、`SPEED`(Mbps)、
`HS`、`VS`、`PAT`(0..5)、`LANE_NUM`(1/2/4)、`NF`、`SKEW`(0/1)。

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
   instance；Tx 端 pad 名稱為 `PAD_CDTX_L0P/N … L4P/N`，對接 M31 Rx 端
   `PAD_CDRX_L0P/N … L4P/N`。
2. 將 M31 Rx D-PHY model 的 PPI output 接到自己的 MIPI RX controller。
3. 把第 7 節的 `rx_*` 預留 wire 接到 MIPI RX controller 的平行輸出。
4. 視 M31 規格調整：`LANE_SPEED_MBPS`（時序會自動推算）、CSI-2 framing、
   以及比對器的極性參數。
5. 重新 `make` 執行比對。

> `mipi_rx_dphy_stub.v` 僅供整條鏈路自我測試使用，不代表 M31 的實際行為。

---

## 10. Rx stub Low-Power / BTA / ULPS

`mipi_rx_dphy_stub` 會在 data lane 0 辨識 D-PHY Control/Escape sequence：

- Escape entry：`LP-11 -> LP-10 -> LP-00 -> LP-01 -> LP-00`
- LPDT、ULPS、Reset 與 Trigger escape command（spaced-one-hot、LSB-first）
- BTA request：`LP-11 -> LP-10 -> LP-00 -> LP-10 -> LP-00`
- data lane 與 clock lane ULPS entry/exit；exit 的 `LP-10` Mark-1 必須滿足 `T_WAKEUP_PS`

LPDT payload 的第一個 byte 會依 `LP_PROTOCOL` 顯示 CSI-2 或 DSI packet type；
DSI DCS packet 的 command byte 也會顯示名稱。D-PHY LPDT 不帶上層協定標誌，
所以 `LP_PROTOCOL=0` 的 AUTO 模式會同時列出 CSI-2/DSI 候選；需要唯一判讀時請指定：

`LP_PROTOCOL` 也作用於 HS packet（每個 HS burst 只解第一個 packet；DSI 只解碼顯示，不輸出到平行介面；
DCS Long Write 可另外寫成 PPM，見 10.1）：

- `0=AUTO`：CSI-2 FS/FE/LS/LE 與 YUV/RAW 影像處理不變；其他 DT 以 DSI 名稱顯示
  （`[rx_stub][hs][DSI]`，DCS packet 另印 `[rx_stub][hs][DSI-DCS]` command），取代 `ignored packet` WARNING。
- `1=CSI-2`：非支援 DT 維持 `ignored packet` WARNING。
- `2=DSI`：所有 HS packet 都以 DSI 解碼顯示，不做 CSI-2 frame/line 檢查，也不輸出影像。

| Parameter | Default | 說明 |
|-----------|---------|------|
| `LP_PROTOCOL` | `0` | `0=AUTO`、`1=CSI-2`、`2=DSI`；LPDT 與 HS packet 共用 |
| `LP_DATA_FILE` | `mipi_lp_data.txt` | 收到 LPDT 後建立的文字檔；每列含 time、transaction、byte index、hex data |
| `LP_PHASE_PS` | `50000` | stub 回驅 BTA LP state 的 phase 時間 |
| `T_TA_GO_PS` / `T_TA_SURE_PS` | `200000` / `100000` | BTA hand-off timing |
| `BTA_AUTO_RETURN` | `1` | 收到 BTA、取得 reverse direction 後自動送 reverse BTA 並歸還 bus |
| `BTA_HOLD_PS` | `200000` | reverse direction 保持 LP-11 的時間 |
| `T_WAKEUP_PS` | `1000000000` | ULPS exit Mark-1 最短時間，預設 1 ms |
| `STRICT_ULPS_WAKEUP` | `1` | `1` 時 T_WAKEUP 違規會 `$fatal` |

stub 取得 BTA reverse direction 時會回驅 `LP-00 -> LP-10 -> LP-11`；若
`BTA_AUTO_RETURN=1`，保持 `BTA_HOLD_PS` 後再送 Turnaround Request 並釋放 lane 0。
若測試需要由 peripheral 傳回自訂 LP data，可設 `BTA_AUTO_RETURN=0`，由 testbench
透過 hierarchy 控制或擴充 response stimulus。

專用測試：

```bash
cd sim
make lp
```

測試涵蓋 DSI DCS command、CSI-2 Data Type、LP data file、雙向 BTA，以及 data/clock lane ULPS。

### 10.1 DSI RGB888 PPM dump

stub 可以把 DSI HS 的 DCS Long Write（DT `0x39`）payload 當成 RGB888 影像 line，
直接寫成 P3 PPM 檔。這個路徑不經過平行介面，所以不需要 `mipi_rx_checker`。
`mipi_rx_checker` 的 `PPM_EN` / `RAW_EN` 對 DSI 沒有作用。

| Parameter | Default | Plusarg | 說明 |
|-----------|---------|---------|------|
| `DSI_PPM_EN` | `0` | `+DSI_PPM=<0/1>` | `1` 時開啟 DSI PPM dump |
| `DSI_HSIZE` | `0` | `+DSI_HSIZE=<n>` | 每條 line 的 pixel 數，範圍 1..21844 |
| `DSI_VSIZE` | `0` | `+DSI_VSIZE=<n>` | 每張 frame 的 line 數，必須 > 0 |

- 先載入 parameter，再讀 plusarg。有傳 plusarg 時，plusarg 優先；沒傳時保留 parameter 值。
- 開啟後 HSIZE 或 VSIZE 超出範圍，或 `LP_PROTOCOL=1`（CSI-2），stub 會印 `CONFIG ERROR` 並 `$fatal`。
- 輸出檔名：`dsi_rgb_frame_NNNN.ppm`（NNNN 從 0001 開始），寫在模擬的執行目錄。
- 每個 pixel 佔 3 byte，依序是 R、G、B。

stub 依 WC 判斷 payload 的格式：

| WC | payload 格式 | frame 邊界 |
|----|--------------|------------|
| `3*HSIZE` | 全部是 pixel | 沒有開檔時開新 frame；收滿 `VSIZE` 條 line 時關檔 |
| `3*HSIZE+1` | `payload[0]` 是 DCS command，pixel 從 `payload[1]` 開始 | `0x2C` 開新 frame；`0x3C` 接續目前的 frame |
| 其他 | 不是影像 line | 已知 DCS command 只顯示名稱；其他值算 protocol error |

- 有 command 時，`0x3C` 出現在第一個 `0x2C` 之前，該 line 會被丟掉，並印一次 WARNING。
- frame 還沒收滿 `VSIZE` 條 line 就收到新的 `0x2C`，或模擬結束，stub 會印 `incomplete frame` ERROR。
- WC 不符合時呼叫 `protocol_error`；`STRICT_PROTOCOL_FINISH=1` 時模擬會停止。

使用範例（320×240 RGB888）：

```verilog
mipi_rx_dphy_stub #(
    .LANE_SPEED_MBPS (600),
    .LANE_NUM        (1),
    .DSI_PPM_EN      (1),
    .DSI_HSIZE       (320),
    .DSI_VSIZE       (240)
) U_RX_0 ( ... );
```

不改 testbench 時，也可以在 run command 加上 `+DSI_PPM=1 +DSI_HSIZE=320 +DSI_VSIZE=240`。

預期 log：

```
[rx_stub][dsi_ppm] dumping frame 1 to dsi_rgb_frame_0001.ppm
[rx_stub][dsi_ppm] completed frame 1: dsi_rgb_frame_0001.ppm
```

### 10.2 LP / HS raw byte dump

stub 可以把收到的 byte 原樣寫成兩個文字檔，LP 和 HS 各一個。CSI-2 和 DSI 都適用。

| Parameter | Default | Plusarg | 說明 |
|-----------|---------|---------|------|
| `RAW_DUMP_EN` | `0` | `+RAW_DUMP=<0/1>` | `1` 時開啟兩個 raw 檔 |
| `RAW_LP_FILE` | `mipi_lp_raw.txt` | - | LPDT raw 檔名 |
| `RAW_HS_FILE` | `mipi_hs_raw.txt` | - | HS raw 檔名 |

- 檔案在模擬開始時建立。開檔失敗時印 `[rx_stub][raw] ERROR` 並 `$fatal`。
- 每個 LPDT transaction 或每個 HS burst 寫一行，格式是 `序號 byte數 hex_byte...`，行首不寫時間。
- LP 檔：一行是一個 LPDT transaction 的全部 byte，在 Escape exit 時寫出。
  每個 transaction 最多存 `MAXBPL` 個 byte；超過時印 WARNING，只寫前 `MAXBPL` 個。
- HS 檔：一行是一個 HS burst 在 sync byte（`B8`）之後的全部 byte，依 lane 合併後的順序排列，
  包含 packet header、ECC、payload、CRC，以及同一 burst 內的後續 packet（例如 EoTp）。
  stub 只解析每個 burst 的第一個 packet，但 raw 檔會寫出整個 burst。
- `LP_DATA_FILE`（每個 byte 一行，含時間）不受影響，仍照原本方式產生。

範例（DSI，320×240 RGB888，WC=961，1 lane）：

```
# MIPI D-PHY HS raw receive log (lane-merged burst after the sync byte)
# burst bytes data_hex...
1 967 39 c1 03 xx 2c 00 01 02 ...
2 967 39 c1 03 xx 3c c0 c1 c2 ...
```

`967 = 4`（header）`+ 961`（payload）`+ 2`（CRC）。實際 byte 數以 burst 內容為準。
