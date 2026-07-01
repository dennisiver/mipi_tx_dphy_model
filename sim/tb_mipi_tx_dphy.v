//============================================================================
//  tb_mipi_tx_dphy.v
//----------------------------------------------------------------------------
//  Self-checking testbench for the MIPI Tx D-PHY model.
//
//      mipi_tx_dphy_model  --(10 x 3-bit pads)-->  Rx D-PHY model  -->
//      parallel video (Pxclk/Vsync/Hsync/Stb/Data) --> mipi_rx_checker
//
//  The Rx here is the illustrative mipi_rx_dphy_stub.  To verify against the
//  real M31 Rx D-PHY model, swap U_RX for the M31 instance (same pad names)
//  and re-route the "reserved" parallel wires below to the M31 output ports.
//
//  Configuration is selected with the +defines below, e.g.:
//      iverilog ... -DFMT=10 -DHS=64 -DVS=8 -DPAT=0 -DSKEW=1
//============================================================================
`timescale 1ps/1ps

`ifndef FMT
 `define FMT 10          // 8 / 10 / 12 / 14
`endif
`ifndef HS
 `define HS  64          // Hsize
`endif
`ifndef VS
 `define VS  8           // Vsize
`endif
`ifndef PAT
 `define PAT 0           // pattern 0..5
`endif
`ifndef NF
 `define NF  2           // number of frames
`endif
`ifndef SKEW
 `define SKEW 0          // 1 = enable deskew calibration + lane skew injection
`endif
`ifndef SPEED
 `define SPEED 2500      // per-lane HS bit rate in Mbps (timing auto-derived)
`endif
`ifndef YUV
 `define YUV 0           // 0 = RAW (FMT 8/10/12/14), 1 = YUV422 (FMT 8/10)
`endif
`ifndef GP_FILE
 `define GP_FILE "golden_pattern.txt"
`endif
`ifndef LANE_NUM
 `define LANE_NUM 4
`endif

module tb_mipi_tx_dphy;

    localparam integer SPEED = `SPEED;          // per-lane Mbps
    localparam integer UI_PS = (SPEED <= 0) ? 400 : (1000000 / SPEED); // derived UI (for skew reference)
    localparam integer EXP_SAMPLES_PER_LINE = (`YUV) ? (2 * `HS) : `HS;
    localparam integer EXP_FRAMES = (`NF == 0) ? 1 : `NF;
    localparam integer EXP_PIXELS = EXP_SAMPLES_PER_LINE * `VS * EXP_FRAMES;
    localparam [13:0] SOLID_PATTERN = 14'h03AA;

    // data type from format.  YUV422: FMT must be 8 or 10.
    localparam [7:0] DT = (`YUV) ? ((`FMT==10) ? 8'h1F : 8'h1E) :
                          (`FMT==8)  ? 8'h2A :
                          (`FMT==12) ? 8'h2C :
                          (`FMT==14) ? 8'h2D : 8'h2B;

    // injected per-lane skew (only when SKEW=1); scales with UI and stays < UI/2
    localparam integer SK0 = `SKEW ?   0 : 0;
    localparam integer SK1 = `SKEW ? (UI_PS / 10)     : 0;
    localparam integer SK2 = `SKEW ? (UI_PS / 4)      : 0;
    localparam integer SK3 = `SKEW ? ((UI_PS * 3) / 8): 0;

    reg         rst_n;
    reg         trigger;

    // ---- the 5 differential lanes (P/N, 3-bit digital encoding) ----------
    wire [2:0] L0P,L0N, L1P,L1N, L2P,L2N, L3P,L3N, L4P,L4N;

    // ---- reserved parallel-video wires (tap point for any hierarchy) -----
    // For the real M31 model, drive these from the M31 parallel output ports
    // (e.g. assign rx_pxclk = u_m31.PXCLK; ... ) instead of the stub.
    wire        rx_pxclk;
    wire        rx_vsync;
    wire        rx_hsync;
    wire        rx_stb;
    wire [1:0]  rx_vc;
    wire [13:0] rx_data;

    // ------------------------------------------------------------------ Tx
    mipi_tx_dphy_model #(
        .LANE_SPEED_MBPS (SPEED),
        .LANE_NUM        (`LANE_NUM),
        .HSIZE           (`HS),
        .VSIZE           (`VS),
        .DATA_TYPE       (DT),
        .PATTERN_SEL     (`PAT),
        .SOLID_VAL       (SOLID_PATTERN),
        .NUM_FRAMES      (`NF),
        .SKEW_CAL_EN     (`SKEW),
        .SKEW_L0_PS (SK0), .SKEW_L1_PS (SK1),
        .SKEW_L2_PS (SK2), .SKEW_L3_PS (SK3),
        .GP_FILE    (`GP_FILE)
    ) U_TX (
        .rst_n      (rst_n),
        .trigger    (trigger),
        .PAD_CDTX_L0P(L0P), .PAD_CDTX_L0N(L0N),
        .PAD_CDTX_L1P(L1P), .PAD_CDTX_L1N(L1N),
        .PAD_CDTX_L2P(L2P), .PAD_CDTX_L2N(L2N),
        .PAD_CDTX_L3P(L3P), .PAD_CDTX_L3N(L3N),
        .PAD_CDTX_L4P(L4P), .PAD_CDTX_L4N(L4N),
        .busy       (),
        .frame_done ()
    );

    // ------------------------------------------------- Rx (stub or M31) ---
    mipi_rx_dphy_stub #(
        .LANE_SPEED_MBPS (SPEED),
        .LANE_NUM        (`LANE_NUM),
        .DATA_BITS       (`FMT),
        .EXPECT_FRAME_LINES(`VS)
    ) U_RX (
        .PAD_CDRX_L0P(L0P), .PAD_CDRX_L0N(L0N),
        .PAD_CDRX_L1P(L1P), .PAD_CDRX_L1N(L1N),
        .PAD_CDRX_L2P(L2P), .PAD_CDRX_L2N(L2N),
        .PAD_CDRX_L3P(L3P), .PAD_CDRX_L3N(L3N),
        .PAD_CDRX_L4P(L4P), .PAD_CDRX_L4N(L4N),
        .Pxclk(rx_pxclk), .Vsync(rx_vsync), .Hsync(rx_hsync),
        .Stb(rx_stb), .VC(rx_vc), .Data(rx_data)
    );

    // ------------------------------------------------------------- checker
    mipi_rx_checker #(
        .BITS    (`FMT),
        .HSIZE   (`HS),
        .PATTERN (`PAT),
        .SOLID   (SOLID_PATTERN),
        .GP_FILE (`GP_FILE),
        .VSYNC_ACT(1'b0),
        .HSYNC_ACT(1'b0),
        .VERBOSE (1)
    ) U_CHK (
        .rst_n      (rst_n),
        .pxclk      (rx_pxclk),
        .vsync      (rx_vsync),
        .hsync      (rx_hsync),
        .stb        (rx_stb),
        .data       (rx_data),
        .error_count(),
        .pixel_count(),
        .checking   ()
    );

    // -------- elaboration-time configuration check ------------------------
    initial begin
        if ((SPEED <= 0) || (SPEED > 2500)) begin
            $display("[tb] CONFIG ERROR: SPEED must be in range 1..2500 Mbps (got %0d)", SPEED);
            $fatal(1);
        end
        if (`YUV && (`FMT != 8) && (`FMT != 10)) begin
            $display("[tb] CONFIG ERROR: YUV422 supports FMT=8 or FMT=10 only (got FMT=%0d)", `FMT);
            $fatal(1);
        end
        if ((`FMT != 8) && (`FMT != 10) && (`FMT != 12) && (`FMT != 14)) begin
            $display("[tb] CONFIG ERROR: FMT must be 8, 10, 12 or 14 (got %0d)", `FMT);
            $fatal(1);
        end
        if ((`LANE_NUM != 1) && (`LANE_NUM != 2) && (`LANE_NUM != 4)) begin
            $display("[tb] CONFIG ERROR: LANE_NUM must be 1, 2 or 4 (got %0d)", `LANE_NUM);
            $fatal(1);
        end
    end

    // -------------------------------------------------------- stimulus ----
    initial begin
        $dumpfile("tb_mipi_tx_dphy.vcd");
        $dumpvars(0, tb_mipi_tx_dphy);

        rst_n       = 1'b0;
        trigger     = 1'b0;

        #20000 rst_n = 1'b1;

        // input trigger gates the start of transmission
        #20000 trigger = 1'b1;
        $display("[tb] trigger asserted at %0t", $time);

        // wait until the whole sequence is finished, then a margin to drain
        wait (U_TX.busy === 1'b1);
        wait (U_TX.busy === 1'b0);
        trigger = 1'b0;
        #2000000;            // allow the Rx FIFO to drain to the checker

        U_CHK.report;
        if (U_CHK.pixel_count == 0) begin
            $display("[tb] ERROR: no pixels were checked");
            $fatal(1);
        end
        if (U_CHK.pixel_count != EXP_PIXELS) begin
            $display("[tb] ERROR: checked %0d pixels/samples, expected %0d",
                     U_CHK.pixel_count, EXP_PIXELS);
            $fatal(1);
        end
        if (U_CHK.error_count != 0) begin
            $display("[tb] ERROR: checker reported %0d mismatch(es)", U_CHK.error_count);
            $fatal(1);
        end
        $finish;
    end

    // global watchdog
    initial begin
        #5000000000;        // 5 ms
        $display("[tb] WATCHDOG timeout");
        $finish;
    end

endmodule
