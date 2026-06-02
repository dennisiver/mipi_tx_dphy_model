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

> **內建設定檢查**：模型會在每次觸發送資料前自動檢查設定，違規時印出明確
> 訊息並停止模擬（`$finish`），避免產生錯誤資料：
> - `data_type` 非支援值
> - `Hsize`/`Vsize` 為 0、或超過 8K
> - 上述 bit-packing 對齊不符
> - `LANE_SPEED_MBPS` 超出 1..2500 範圍
>
> testbench 另在 elaboration 階段檢查 `YUV=1` 只能搭配 `FMT=8/10`。

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

### 5.1 相關 Port / Parameter

Golden pattern 由 Tx 的 runtime port 與 instance parameter 一起控制：

| 名稱          | 類型      | 預設 / 範圍          | 說明 |
|---------------|-----------|----------------------|------|
| `pattern_sel` | input port | `0..5`               | 選擇要送出的 pattern。testbench 用 Makefile 參數 `PAT` 指定。 |
| `solid_val`   | input port | 12-bit value         | `pattern_sel=4` 時送出的固定值；會依 RAW/YUV 位元數自動 mask。 |
| `GP_FILE`     | parameter | `"golden_pattern.txt"` | `pattern_sel=5` 時讀取的外部 pattern 檔案路徑。 |
| `GP_MAX`      | parameter | `65536`              | 最多從 `GP_FILE` 載入的 sample 數。 |

`pattern_sel` 與 `solid_val` 是 runtime configuration，在每次 trigger 開始送 frame sequence
時被 Tx sample；也就是 transmission 進行中改變這兩個 port，不會影響已經開始的那一輪傳輸。
`GP_FILE` 與 `GP_MAX` 是 elaboration-time parameter，需要在 instantiate Tx / checker 時指定。

checker 端也要使用相同設定：

```verilog
mipi_rx_checker #(
    .BITS    (10),
    .PATTERN (pattern_sel_used_by_tx),
    .SOLID   (solid_val_used_by_tx),
    .GP_FILE ("golden_pattern.txt")
) u_chk (...);
```

目前 testbench 中 `SOLID` 固定為 `12'h3AA`，Tx 的 `solid_val` 也設為同一個值。

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

使用 solid pattern。testbench 預設固定值為 `12'h3AA`：

```bash
make FMT=10 PAT=4
```

若要改 solid value，請在自己的 testbench 中設定 Tx 的 `solid_val`，並同步設定
checker 的 `SOLID`：

```verilog
localparam [11:0] SOLID_PATTERN = 12'h155;

mipi_tx_dphy_model u_tx (
    .pattern_sel(3'd4),
    .solid_val  (SOLID_PATTERN),
    // other ports...
);

mipi_rx_checker #(
    .BITS (10),
    .PATTERN(4),
    .SOLID(SOLID_PATTERN)
) u_chk (...);
```

使用外部 golden pattern 檔：

```bash
make FMT=10 PAT=5
```

若檔案不在 repo root，請在 Tx 與 checker 使用相同的 `GP_FILE`：

```verilog
mipi_tx_dphy_model #(
    .GP_FILE("../patterns/my_golden_pattern.txt"),
    .GP_MAX (131072)
) u_tx (...);

mipi_rx_checker #(
    .GP_FILE("../patterns/my_golden_pattern.txt"),
    .GP_MAX (131072)
) u_chk (...);
```

### golden_pattern.txt 格式

- 每行一個 **十六進位** 值（`#` 開頭為註解、空白行會被略過）
- 讀入後依資料格式自動遮罩到對應位元數
- sample 索引依 `golden_pixel(frame,row,col,hsize,...)` 計算為 `row*hsize + col`；
  YUV422 時 `col` 會跑遍 `2*Hsize`，因此 file pattern 會以 sample/component 為單位被取用
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

testbench 中 `make SKEW=1` 會使用下列示範值：

```verilog
SKEW_L0_PS = 0
SKEW_L1_PS = 40
SKEW_L2_PS = 90
SKEW_L3_PS = 150
```

這些值刻意保持小於 `UI/2`，方便示範用 `mipi_rx_dphy_stub` 正確取樣。接真正
M31 Rx model 時，可依 M31 spec 與欲驗證的 skew margin 調整。

### 6.2 Deskew Calibration Burst

`skew_cal_en = 1` 時，每張 frame 前會先送 deskew calibration burst，再送 CSI-2
Frame Start / line packets / Frame End：

```text
clock lane 進入 HS continuous clock
[deskew calibration burst]  <-- skew_cal_en=1 時送出
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

Tx 會在 4 條 data lane 同時送出這段 calibration burst，但每條 lane 仍會套用
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
mipi_tx_dphy_model #(
    .LANE_SPEED_MBPS(2500),
    .SKEW_L0_PS(0),
    .SKEW_L1_PS(40),
    .SKEW_L2_PS(90),
    .SKEW_L3_PS(150),
    .SKEW_PREAMBLE(32),
    .SKEW_CAL_BITS(256)
) u_tx (
    .skew_cal_en(1'b1),
    // other ports...
);
```

若只想注入 skew、但不送 calibration burst，可設定 `SKEW_Lx_PS` 非 0，
並讓 `skew_cal_en = 1'b0`。這種情境可用來觀察 Rx 在沒有 deskew training 時的容忍度。

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
