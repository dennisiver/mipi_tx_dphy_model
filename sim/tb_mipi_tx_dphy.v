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
 `define FMT 10          // 8 / 10 / 12
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

module tb_mipi_tx_dphy;

    localparam integer UI_PS = 400;     // 2.5 Gbps

    // data type from format
    localparam [7:0] DT = (`FMT==8)  ? 8'h2A :
                          (`FMT==12) ? 8'h2C : 8'h2B;

    // injected per-lane skew (only when SKEW=1); kept < UI/2 for the stub
    localparam integer SK0 = `SKEW ?   0 : 0;
    localparam integer SK1 = `SKEW ?  40 : 0;
    localparam integer SK2 = `SKEW ?  90 : 0;
    localparam integer SK3 = `SKEW ? 150 : 0;

    reg         rst_n;
    reg         trigger;
    reg  [15:0] hsize, vsize, num_frames;
    reg  [7:0]  data_type;
    reg  [2:0]  pattern_sel;
    reg  [11:0] solid_val;
    reg         skew_cal_en;

    // ---- the 5 differential lanes (P/N, 3-bit digital encoding) ----------
    wire [2:0] L0P,L0N, L1P,L1N, L2P,L2N, L3P,L3N, L4P,L4N;

    // ---- reserved parallel-video wires (tap point for any hierarchy) -----
    // For the real M31 model, drive these from the M31 parallel output ports
    // (e.g. assign rx_pxclk = u_m31.PXCLK; ... ) instead of the stub.
    wire        rx_pxclk;
    wire        rx_vsync;
    wire        rx_hsync;
    wire        rx_stb;
    wire [11:0] rx_data;

    // ------------------------------------------------------------------ Tx
    mipi_tx_dphy_model #(
        .UI_PS      (UI_PS),
        .SKEW_L0_PS (SK0), .SKEW_L1_PS (SK1),
        .SKEW_L2_PS (SK2), .SKEW_L3_PS (SK3),
        .GP_FILE    ("golden_pattern.txt")
    ) U_TX (
        .rst_n      (rst_n),
        .trigger    (trigger),
        .hsize      (hsize),
        .vsize      (vsize),
        .data_type  (data_type),
        .pattern_sel(pattern_sel),
        .solid_val  (solid_val),
        .num_frames (num_frames),
        .skew_cal_en(skew_cal_en),
        .PAD_CDRX_L0P(L0P), .PAD_CDRX_L0N(L0N),
        .PAD_CDRX_L1P(L1P), .PAD_CDRX_L1N(L1N),
        .PAD_CDRX_L2P(L2P), .PAD_CDRX_L2N(L2N),
        .PAD_CDRX_L3P(L3P), .PAD_CDRX_L3N(L3N),
        .PAD_CDRX_L4P(L4P), .PAD_CDRX_L4N(L4N),
        .busy       (),
        .frame_done ()
    );

    // ------------------------------------------------- Rx (stub or M31) ---
    mipi_rx_dphy_stub #(
        .UI_PS    (UI_PS),
        .DATA_BITS(`FMT)
    ) U_RX (
        .PAD_CDRX_L0P(L0P), .PAD_CDRX_L0N(L0N),
        .PAD_CDRX_L1P(L1P), .PAD_CDRX_L1N(L1N),
        .PAD_CDRX_L2P(L2P), .PAD_CDRX_L2N(L2N),
        .PAD_CDRX_L3P(L3P), .PAD_CDRX_L3N(L3N),
        .PAD_CDRX_L4P(L4P), .PAD_CDRX_L4N(L4N),
        .Pxclk(rx_pxclk), .Vsync(rx_vsync), .Hsync(rx_hsync),
        .Stb(rx_stb), .Data(rx_data)
    );

    // ------------------------------------------------------------- checker
    mipi_rx_checker #(
        .BITS    (`FMT),
        .PATTERN (`PAT),
        .SOLID   (12'h3AA),
        .GP_FILE ("golden_pattern.txt"),
        .VERBOSE (1)
    ) U_CHK (
        .rst_n      (rst_n),
        .pxclk      (rx_pxclk),
        .vsync      (rx_vsync),
        .hsync      (rx_hsync),
        .stb        (rx_stb),
        .data       (rx_data),
        .hsize      (hsize),
        .error_count(),
        .pixel_count(),
        .checking   ()
    );

    // -------------------------------------------------------- stimulus ----
    initial begin
        $dumpfile("tb_mipi_tx_dphy.vcd");
        $dumpvars(0, tb_mipi_tx_dphy);

        rst_n       = 1'b0;
        trigger     = 1'b0;
        hsize       = `HS;
        vsize       = `VS;
        num_frames  = `NF;
        data_type   = DT;
        pattern_sel = `PAT;
        solid_val   = 12'h3AA;
        skew_cal_en = `SKEW;

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
            $finish;
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
