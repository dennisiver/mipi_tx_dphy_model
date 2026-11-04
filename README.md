# mipi_tx_dphy_model

Timing knobs:
- `PACKET_INTERVAL_NS`: extra LP-11 gap between CSI-2 packets, in ns. Default: `2000`.
- `VBLANK_NS`: extra LP-11 gap after FE before the next FS, in ns. Default: `10000`.
- Example: `make VBLANK=1000` adds 1000 ns after FE before the next FS.

以 Verilog 建立的 **MIPI Tx D-PHY 行為模型**，用來驅動並驗證
**M31 MIPI Rx D-PHY model**。

- 1 / 2 / 4 active data lane + 1 clock lane，連續時脈 HS 模式，最高 **2.5 Gbps/lane**
- `LANE_SPEED_MBPS` 控制 lane speed；UI 與所有 D-PHY 時序自動依 spec 推算
- `PACKET_INTERVAL_NS` 可設定 CSI-2 packet 間 LP-11 gap，包含 FS/FE short packet
- 最大 **8K**（Hsize × Vsize 可調）、RAW8 / RAW10 / RAW12 / RAW14、YUV422 8/10-bit
- **Skew calibration**：per-lane skew 注入 + deskew calibration burst
- 多種內建 golden pattern + `golden_pattern.txt` 載入，位元數依格式自動選擇
- **input trigger** 控制傳輸起始時間
- Rx 平行輸出 (Pxclk/Vsync/Hsync/Stb/Data) 比對器，預留 wire 可接 signal hierarchy
- Rx checker 可選擇將每張 frame 輸出為 P3 PPM；RAW 轉灰階、YUV422 轉 RGB
- Rx stub 支援 LPDT/Trigger/ULPS Escape command、CSI-2/DSI LP packet 顯示、LP data 文字檔與 BTA hand-off

## 快速開始

```bash
cd sim
make                 # 預設 RAW10 64x8 ramp，2 frames
make YUV=1 FMT=8     # YUV422 8-bit
make SPEED=1500      # 改 lane speed（時序自動推算）
make SKEW=1          # 開啟 skew 注入 + deskew calibration
make PPM=1           # 輸出 rx_frame_0001.ppm、rx_frame_0002.ppm...
make matrix          # 回歸：RAW + YUV422 × 所有 pattern
make lp              # LPDT command/data、BTA、ULPS 專用測試
```

通過時輸出 `[chk] RESULT : PASS`。

## 檔案

| 路徑                          | 說明                              |
|-------------------------------|-----------------------------------|
| `rtl/mipi_tx_dphy_model.v`    | Tx D-PHY 頂層模型                  |
| `rtl/mipi_rx_checker.v`       | Rx 平行輸出比對器                  |
| `rtl/golden_pixel.v`          | golden pattern 產生 / 載入（include 檔）|
| `rtl/mipi_csi2_func.v`        | CSI-2 ECC / CRC（include 檔）      |
| `sim/tb_mipi_tx_dphy.v`       | 自我比對 testbench                 |
| `sim/tb_mipi_rx_dphy_lp.v`    | LPDT / BTA / ULPS testbench        |
| `sim/mipi_rx_dphy_stub.v`     | 示範用 Rx 模型（替換為真正 M31）   |
| `golden_pattern.txt`          | 範例 golden pattern                |

詳細說明見 [`docs/USER_GUIDE.md`](docs/USER_GUIDE.md)；
改版資訊見 [`docs/REVISION_HISTORY.md`](docs/REVISION_HISTORY.md)。
