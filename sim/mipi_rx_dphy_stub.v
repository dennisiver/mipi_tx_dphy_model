//============================================================================
//  mipi_rx_dphy_stub.v
//----------------------------------------------------------------------------
//  *** ILLUSTRATIVE / SELF-TEST Rx model -- replace with the real M31 model ***
//
//  Decodes the digital HS/LP pad encoding produced by mipi_tx_dphy_model and
//  reproduces a parallel video output (Pxclk, Vsync, Hsync, Stb, Data[13:0])
//  similar to what the M31 MIPI Rx D-PHY model exposes, so that the whole
//  Tx -> link -> checker path can be exercised without the encrypted M31 IP.
//  Data is MSB-aligned to match the M31 Rx convention.
//  Vsync/Hsync are low-active level signals; Stb is high-active.
//
//  Port style mirrors the M31 model (3-bit-per-pad inout buses).  Lane 0 also
//  decodes D-PHY Escape Mode (LPDT / triggers / ULPS) and performs the BTA
//  hand-off sequence.  Received LPDT bytes are written to LP_DATA_FILE.
//============================================================================
`timescale 1ps/1ps

module mipi_rx_dphy_stub #(
    parameter integer LANE_SPEED_MBPS = 2500, // must match the Tx lane speed
    parameter integer LANE_NUM   = 4,      // active data lanes: 1, 2, or 4
    parameter integer DATA_BITS  = 10,     // 8/10/12/14 -> RAW8/RAW10/RAW12/RAW14
    parameter integer VC_FILTER  = -1,     // -1: output all VCs; 0..3: output only this VC
    parameter integer EXPECT_FRAME_LINES = 0, // 0: no line-count check; >0: require FE after this many lines
    parameter integer MAXQ       = 262144, // output FIFO depth (>= one line)
    parameter integer MAXBPL     = 24576,  // max bytes per lane per burst
    parameter integer SAMPLE_DELAY_PS = 1,
    parameter integer DEBUG_COLLECT_BITS = 0,
    parameter integer DEBUG_BITS_PER_LANE = 80,
    parameter integer DEBUG_BYTES_PER_LANE = 12,
    parameter integer DEBUG_PACKET_HEADERS = 0,
    parameter integer DEBUG_FRAME_EVENTS = 0,
    parameter integer DEBUG_LINE_EVENTS = 0,
    parameter integer DEBUG_VALID_DATA = 0,
    parameter integer STRICT_PROTOCOL_FINISH = 1,
    parameter integer LP_PROTOCOL = 0,       // 0:auto, 1:CSI-2, 2:DSI
    parameter         LP_DATA_FILE = "mipi_lp_data.txt",
    parameter integer LP_PHASE_PS = 50000,   // nominal LP symbol phase / T_LPX
    parameter integer T_TA_GO_PS = 200000,
    parameter integer T_TA_SURE_PS = 100000,
    parameter integer BTA_AUTO_RETURN = 1,
    parameter integer BTA_HOLD_PS = 200000,
    parameter integer T_WAKEUP_PS = 1000000000,
    parameter integer STRICT_ULPS_WAKEUP = 1,
    parameter integer DSI_PPM_EN = 0,        // 1: dump DSI DCS RGB888 lines as PPM; +DSI_PPM overrides
    parameter integer DSI_HSIZE  = 0,        // DSI PPM pixels per line; +DSI_HSIZE overrides
    parameter integer DSI_VSIZE  = 0,        // DSI PPM lines per frame; +DSI_VSIZE overrides
    parameter integer RAW_DUMP_EN = 0,       // 1: dump each LPDT transaction / HS burst as one hex line; +RAW_DUMP overrides
    parameter         RAW_LP_FILE = "mipi_lp_raw.txt",
    parameter         RAW_HS_FILE = "mipi_hs_raw.txt"
)(
    inout  [2:0] PAD_CDRX_L0P, inout [2:0] PAD_CDRX_L0N,
    inout  [2:0] PAD_CDRX_L1P, inout [2:0] PAD_CDRX_L1N,
    inout  [2:0] PAD_CDRX_L2P, inout [2:0] PAD_CDRX_L2N,
    inout  [2:0] PAD_CDRX_L3P, inout [2:0] PAD_CDRX_L3N,
    inout  [2:0] PAD_CDRX_L4P, inout [2:0] PAD_CDRX_L4N,

    output reg        Pxclk,
    output reg        Vsync,
    output reg        Hsync,
    output reg        Stb,
    output reg [1:0]  VC,
    output reg [13:0] Data
);

    // The stub normally listens.  During BTA it drives a complete LP encoding
    // ({LP level, HS data=0, HS valid=0}) on lane 0.
    reg lp0_tx_en, lp0_tx_dp, lp0_tx_dn, bta_busy;
    assign PAD_CDRX_L0P = lp0_tx_en ? {lp0_tx_dp, 2'b00} : 3'bzzz;
    assign PAD_CDRX_L0N = lp0_tx_en ? {lp0_tx_dn, 2'b00} : 3'bzzz;

    wire lp0_dp = PAD_CDRX_L0P[2];
    wire lp0_dn = PAD_CDRX_L0N[2];
    wire clp_dp = PAD_CDRX_L4P[2];
    wire clp_dn = PAD_CDRX_L4N[2];

    // The parallel output runs at the per-lane byte-clock rate.
    localparam integer UI_PS      = (LANE_SPEED_MBPS <= 0) ? 400 : (1000000 / LANE_SPEED_MBPS);
    localparam integer PXCLK_HALF = (LANE_SPEED_MBPS <= 0) ? 1600 :
                                   ((4000000 + LANE_SPEED_MBPS / 2) / LANE_SPEED_MBPS);

    // ---- recovered clock / per-lane HS view ------------------------------
    wire clk_hs  = PAD_CDRX_L4P[1];
    wire clk_val = PAD_CDRX_L4P[0];

    wire [3:0] lane_val = {PAD_CDRX_L3P[0], PAD_CDRX_L2P[0],
                           PAD_CDRX_L1P[0], PAD_CDRX_L0P[0]};
    wire [3:0] lane_bit = {PAD_CDRX_L3P[1], PAD_CDRX_L2P[1],
                           PAD_CDRX_L1P[1], PAD_CDRX_L0P[1]};
    wire [3:0] lane_mask = (LANE_NUM == 1) ? 4'b0001 :
                           (LANE_NUM == 2) ? 4'b0011 : 4'b1111;
    wire       any_val  = |(lane_val & lane_mask);

    // ---- per-lane byte collection state ----------------------------------
    reg [7:0]  lane_sr   [0:3];
    reg        lane_sync [0:3];
    integer    lane_bcnt [0:3];
    integer    lane_nb   [0:3];
    reg [7:0]  lane_byte [0:3][0:MAXBPL-1];
    integer    lane_dbg_bits  [0:3];
    integer    lane_dbg_bytes [0:3];
    reg [3:0]  frame_active;
    integer    dbg_frame_no [0:3];
    integer    dbg_line_no  [0:3];

    integer dsi_ppm_en, dsi_hsize, dsi_vsize;
    integer dsi_ppm_fd, dsi_ppm_frame_no, dsi_ppm_line_no, dsi_ppm_errors;
    reg     dsi_ppm_open, dsi_ppm_drop_warned;
    reg [8*256-1:0] dsi_ppm_filename;

    integer   raw_dump_en, raw_lp_fd, raw_hs_fd, raw_hs_burst;
    reg [7:0] raw_lp_buf [0:MAXBPL-1];

    integer i;

    localparam [5:0] DT_FS    = 6'h00;
    localparam [5:0] DT_FE    = 6'h01;
    localparam [5:0] DT_LS    = 6'h02;
    localparam [5:0] DT_LE    = 6'h03;
    localparam [5:0] DT_YUV8  = 6'h1E;
    localparam [5:0] DT_YUV10 = 6'h1F;
    localparam [5:0] DT_RAW8  = 6'h2A;
    localparam [5:0] DT_RAW10 = 6'h2B;
    localparam [5:0] DT_RAW12 = 6'h2C;
    localparam [5:0] DT_RAW14 = 6'h2D;

    // D-PHY Escape entry-command values as seen by the receiver.  Escape
    // symbols are received LSB-first; for example LPDT is transmitted on the
    // wire as 11100001 and accumulates below as 8'h87.
    localparam [7:0] ESC_LPDT       = 8'h87;
    localparam [7:0] ESC_ULPS       = 8'h78;
    localparam [7:0] ESC_UNDEF_1    = 8'hF9;
    localparam [7:0] ESC_UNDEF_2    = 8'h7B;
    localparam [7:0] ESC_RESET      = 8'h46;
    localparam [7:0] ESC_TRIGGER_3  = 8'hBA;
    localparam [7:0] ESC_TRIGGER_4  = 8'h84;
    localparam [7:0] ESC_TRIGGER_5  = 8'h05;

    localparam integer LP_PROTO_AUTO = 0;
    localparam integer LP_PROTO_CSI2 = 1;
    localparam integer LP_PROTO_DSI  = 2;

    localparam [3:0] LP_CTRL_IDLE       = 4'd0;
    localparam [3:0] LP_CTRL_REQ        = 4'd1;
    localparam [3:0] LP_CTRL_BRIDGE     = 4'd2;
    localparam [3:0] LP_CTRL_ESC_MARK   = 4'd3;
    localparam [3:0] LP_CTRL_BTA_MARK   = 4'd4;
    localparam [3:0] LP_CTRL_ESCAPE     = 4'd5;
    localparam [3:0] LP_CTRL_ULPS       = 4'd6;

    reg [3:0] lp_ctrl_state;
    reg       lp_pending_valid;
    reg       lp_pending_bit;
    reg       lp_entry_done;
    reg       lpdt_active;
    reg       data_ulps_active;
    reg [7:0] lp_shift;
    reg [7:0] lp_first_di;
    integer   lp_bit_count;
    integer   lp_byte_count;
    integer   lp_total_bytes;
    integer   lp_transaction;
    integer   lp_fd;
    time      data_ulps_mark_time;

    reg [2:0] clk_ulps_state;
    time      clk_ulps_mark_time;

    function lp_state_valid;
        input dp;
        input dn;
        begin
            lp_state_valid = (({dp,dn} === 2'b00) ||
                              ({dp,dn} === 2'b01) ||
                              ({dp,dn} === 2'b10) ||
                              ({dp,dn} === 2'b11));
        end
    endfunction

    task display_csi2_lp_type;
        input [7:0] di;
        reg [5:0] dt;
        begin
            dt = di[5:0];
            case (dt)
                6'h00: $display("[rx_stub][lp][CSI-2] t=%0t VC%0d Frame Start", $time, di[7:6]);
                6'h01: $display("[rx_stub][lp][CSI-2] t=%0t VC%0d Frame End", $time, di[7:6]);
                6'h02: $display("[rx_stub][lp][CSI-2] t=%0t VC%0d Line Start", $time, di[7:6]);
                6'h03: $display("[rx_stub][lp][CSI-2] t=%0t VC%0d Line End", $time, di[7:6]);
                6'h08,6'h09,6'h0A,6'h0B,6'h0C,6'h0D,6'h0E,6'h0F:
                    $display("[rx_stub][lp][CSI-2] t=%0t VC%0d Generic Short Packet DT=0x%02h", $time, di[7:6], dt);
                6'h12: $display("[rx_stub][lp][CSI-2] t=%0t VC%0d Embedded 8-bit Non-Image Data", $time, di[7:6]);
                6'h10,6'h11,6'h13,6'h14,6'h15,6'h16,6'h17:
                    $display("[rx_stub][lp][CSI-2] t=%0t VC%0d Generic Long Packet DT=0x%02h", $time, di[7:6], dt);
                6'h18: $display("[rx_stub][lp][CSI-2] t=%0t VC%0d YUV420-8", $time, di[7:6]);
                6'h19: $display("[rx_stub][lp][CSI-2] t=%0t VC%0d YUV420-10", $time, di[7:6]);
                6'h1E: $display("[rx_stub][lp][CSI-2] t=%0t VC%0d YUV422-8", $time, di[7:6]);
                6'h1F: $display("[rx_stub][lp][CSI-2] t=%0t VC%0d YUV422-10", $time, di[7:6]);
                6'h20: $display("[rx_stub][lp][CSI-2] t=%0t VC%0d RGB444", $time, di[7:6]);
                6'h21: $display("[rx_stub][lp][CSI-2] t=%0t VC%0d RGB555", $time, di[7:6]);
                6'h22: $display("[rx_stub][lp][CSI-2] t=%0t VC%0d RGB565", $time, di[7:6]);
                6'h23: $display("[rx_stub][lp][CSI-2] t=%0t VC%0d RGB666", $time, di[7:6]);
                6'h24: $display("[rx_stub][lp][CSI-2] t=%0t VC%0d RGB888", $time, di[7:6]);
                6'h28: $display("[rx_stub][lp][CSI-2] t=%0t VC%0d RAW6", $time, di[7:6]);
                6'h29: $display("[rx_stub][lp][CSI-2] t=%0t VC%0d RAW7", $time, di[7:6]);
                6'h2A: $display("[rx_stub][lp][CSI-2] t=%0t VC%0d RAW8", $time, di[7:6]);
                6'h2B: $display("[rx_stub][lp][CSI-2] t=%0t VC%0d RAW10", $time, di[7:6]);
                6'h2C: $display("[rx_stub][lp][CSI-2] t=%0t VC%0d RAW12", $time, di[7:6]);
                6'h2D: $display("[rx_stub][lp][CSI-2] t=%0t VC%0d RAW14", $time, di[7:6]);
                6'h2E: $display("[rx_stub][lp][CSI-2] t=%0t VC%0d RAW16", $time, di[7:6]);
                6'h2F: $display("[rx_stub][lp][CSI-2] t=%0t VC%0d RAW20", $time, di[7:6]);
                6'h30,6'h31,6'h32,6'h33,6'h34,6'h35,6'h36,6'h37:
                    $display("[rx_stub][lp][CSI-2] t=%0t VC%0d User-defined DT=0x%02h", $time, di[7:6], dt);
                default:
                    $display("[rx_stub][lp][CSI-2] t=%0t VC%0d Reserved/unknown DT=0x%02h", $time, di[7:6], dt);
            endcase
        end
    endtask

    task display_dsi_lp_type;
        input [8*2-1:0] path;   // "lp" or "hs"
        input [7:0] di;
        reg [5:0] dt;
        begin
            dt = di[5:0];
            case (dt)
                6'h01: $display("[rx_stub][%0s][DSI] t=%0t V Sync Start", path, $time);
                6'h02: $display("[rx_stub][%0s][DSI] t=%0t Color Mode Off Command", path, $time);
                6'h03: $display("[rx_stub][%0s][DSI] t=%0t VC%0d Generic Short Write, 0 parameter", path, $time, di[7:6]);
                6'h04: $display("[rx_stub][%0s][DSI] t=%0t VC%0d Generic Read, 0 parameter", path, $time, di[7:6]);
                6'h05: $display("[rx_stub][%0s][DSI] t=%0t VC%0d DCS Short Write, 0 parameter", path, $time, di[7:6]);
                6'h06: $display("[rx_stub][%0s][DSI] t=%0t VC%0d DCS Read", path, $time, di[7:6]);
                6'h07: $display("[rx_stub][%0s][DSI] t=%0t VC%0d Compression Mode Command", path, $time, di[7:6]);
                6'h08: $display("[rx_stub][%0s][DSI] t=%0t End of Transmission Packet", path, $time);
                6'h09: $display("[rx_stub][%0s][DSI] t=%0t VC%0d Null Packet", path, $time, di[7:6]);
                6'h0A: $display("[rx_stub][%0s][DSI] t=%0t VC%0d Picture Parameter Set", path, $time, di[7:6]);
                6'h0B: $display("[rx_stub][%0s][DSI] t=%0t VC%0d Compressed Pixel Stream", path, $time, di[7:6]);
                6'h0C: $display("[rx_stub][%0s][DSI] t=%0t VC%0d Loosely Packed Pixel Stream, 20-bit YCbCr 4:2:2", path, $time, di[7:6]);
                6'h0D: $display("[rx_stub][%0s][DSI] t=%0t VC%0d Packed Pixel Stream, 30-bit RGB 10-10-10", path, $time, di[7:6]);
                6'h0E: $display("[rx_stub][%0s][DSI] t=%0t VC%0d Packed Pixel Stream, 16-bit RGB 5-6-5", path, $time, di[7:6]);
                6'h11: $display("[rx_stub][%0s][DSI] t=%0t V Sync End", path, $time);
                6'h12: $display("[rx_stub][%0s][DSI] t=%0t Color Mode On Command", path, $time);
                6'h13: $display("[rx_stub][%0s][DSI] t=%0t VC%0d Generic Short Write, 1 parameter", path, $time, di[7:6]);
                6'h14: $display("[rx_stub][%0s][DSI] t=%0t VC%0d Generic Read, 1 parameter", path, $time, di[7:6]);
                6'h15: $display("[rx_stub][%0s][DSI] t=%0t VC%0d DCS Short Write, 1 parameter", path, $time, di[7:6]);
                6'h19: $display("[rx_stub][%0s][DSI] t=%0t VC%0d Blanking Packet", path, $time, di[7:6]);
                6'h1C: $display("[rx_stub][%0s][DSI] t=%0t VC%0d Packed Pixel Stream, 24-bit YCbCr 4:2:2", path, $time, di[7:6]);
                6'h1D: $display("[rx_stub][%0s][DSI] t=%0t VC%0d Packed Pixel Stream, 36-bit RGB 12-12-12", path, $time, di[7:6]);
                6'h1E: $display("[rx_stub][%0s][DSI] t=%0t VC%0d Packed Pixel Stream, 18-bit RGB 6-6-6", path, $time, di[7:6]);
                6'h21: $display("[rx_stub][%0s][DSI] t=%0t H Sync Start", path, $time);
                6'h22: $display("[rx_stub][%0s][DSI] t=%0t Shut Down Peripheral Command", path, $time);
                6'h23: $display("[rx_stub][%0s][DSI] t=%0t VC%0d Generic Short Write, 2 parameters", path, $time, di[7:6]);
                6'h24: $display("[rx_stub][%0s][DSI] t=%0t VC%0d Generic Read, 2 parameters", path, $time, di[7:6]);
                6'h29: $display("[rx_stub][%0s][DSI] t=%0t VC%0d Generic Long Write", path, $time, di[7:6]);
                6'h2C: $display("[rx_stub][%0s][DSI] t=%0t VC%0d Packed Pixel Stream, 16-bit YCbCr 4:2:2", path, $time, di[7:6]);
                6'h2E: $display("[rx_stub][%0s][DSI] t=%0t VC%0d Loosely Packed Pixel Stream, 18-bit RGB 6-6-6", path, $time, di[7:6]);
                6'h31: $display("[rx_stub][%0s][DSI] t=%0t H Sync End", path, $time);
                6'h32: $display("[rx_stub][%0s][DSI] t=%0t Turn On Peripheral Command", path, $time);
                6'h37: $display("[rx_stub][%0s][DSI] t=%0t VC%0d Set Maximum Return Packet Size", path, $time, di[7:6]);
                6'h39: $display("[rx_stub][%0s][DSI] t=%0t VC%0d DCS Long Write", path, $time, di[7:6]);
                6'h3D: $display("[rx_stub][%0s][DSI] t=%0t VC%0d Packed Pixel Stream, 12-bit YCbCr 4:2:0", path, $time, di[7:6]);
                6'h3E: $display("[rx_stub][%0s][DSI] t=%0t VC%0d Packed Pixel Stream, 24-bit RGB 8-8-8", path, $time, di[7:6]);
                default:
                    $display("[rx_stub][%0s][DSI] t=%0t VC%0d Reserved/unknown DT=0x%02h", path, $time, di[7:6], dt);
            endcase
        end
    endtask

    task display_dsi_command;
        input [8*2-1:0] path;   // "lp" or "hs"
        input [7:0] cmd;
        begin
            case (cmd)
                8'h01: $display("[rx_stub][%0s][DSI-DCS] t=%0t command=0x%02h Software Reset", path, $time, cmd);
                8'h10: $display("[rx_stub][%0s][DSI-DCS] t=%0t command=0x%02h Enter Sleep Mode", path, $time, cmd);
                8'h11: $display("[rx_stub][%0s][DSI-DCS] t=%0t command=0x%02h Exit Sleep Mode", path, $time, cmd);
                8'h20: $display("[rx_stub][%0s][DSI-DCS] t=%0t command=0x%02h Display Inversion Off", path, $time, cmd);
                8'h21: $display("[rx_stub][%0s][DSI-DCS] t=%0t command=0x%02h Display Inversion On", path, $time, cmd);
                8'h28: $display("[rx_stub][%0s][DSI-DCS] t=%0t command=0x%02h Set Display Off", path, $time, cmd);
                8'h29: $display("[rx_stub][%0s][DSI-DCS] t=%0t command=0x%02h Set Display On", path, $time, cmd);
                8'h2A: $display("[rx_stub][%0s][DSI-DCS] t=%0t command=0x%02h Set Column Address", path, $time, cmd);
                8'h2B: $display("[rx_stub][%0s][DSI-DCS] t=%0t command=0x%02h Set Page Address", path, $time, cmd);
                8'h2C: $display("[rx_stub][%0s][DSI-DCS] t=%0t command=0x%02h Write Memory Start", path, $time, cmd);
                8'h35: $display("[rx_stub][%0s][DSI-DCS] t=%0t command=0x%02h Set Tear On", path, $time, cmd);
                8'h36: $display("[rx_stub][%0s][DSI-DCS] t=%0t command=0x%02h Set Address Mode", path, $time, cmd);
                8'h3A: $display("[rx_stub][%0s][DSI-DCS] t=%0t command=0x%02h Set Pixel Format", path, $time, cmd);
                8'h3C: $display("[rx_stub][%0s][DSI-DCS] t=%0t command=0x%02h Write Memory Continue", path, $time, cmd);
                8'h44: $display("[rx_stub][%0s][DSI-DCS] t=%0t command=0x%02h Set Tear Scanline", path, $time, cmd);
                8'h51: $display("[rx_stub][%0s][DSI-DCS] t=%0t command=0x%02h Write Display Brightness", path, $time, cmd);
                8'h53: $display("[rx_stub][%0s][DSI-DCS] t=%0t command=0x%02h Write Control Display", path, $time, cmd);
                8'h55: $display("[rx_stub][%0s][DSI-DCS] t=%0t command=0x%02h Write CABC", path, $time, cmd);
                default: $display("[rx_stub][%0s][DSI-DCS] t=%0t command=0x%02h", path, $time, cmd);
            endcase
        end
    endtask

    // ---- raw byte dump (RAW_DUMP_EN=1): one LPDT transaction / HS burst per line
    task raw_write_lp;
        integer k;
        begin
            if (raw_lp_fd != 0) begin
                $fwrite(raw_lp_fd, "%0d %0d", lp_transaction, lp_byte_count);
                for (k = 0; k < lp_byte_count && k < MAXBPL; k = k + 1)
                    $fwrite(raw_lp_fd, " %02x", raw_lp_buf[k]);
                $fwrite(raw_lp_fd, "\n");
                $fflush(raw_lp_fd);
                if (lp_byte_count > MAXBPL)
                    $display("[rx_stub][raw] WARNING: LPDT transaction %0d has %0d bytes; only the first MAXBPL=%0d are dumped",
                             lp_transaction, lp_byte_count, MAXBPL);
            end
        end
    endtask

    // Long/short by DT.  CSI-2: DT >= 0x10 is long.  DSI: DT[3:0] >= 9 is long.
    // AUTO follows parse_burst: CSI-2 image DTs are CSI-2, all others are DSI.
    function raw_is_long;
        input [5:0] dt;
        begin
            if (LP_PROTOCOL == LP_PROTO_CSI2)
                raw_is_long = (dt >= 6'h10);
            else if (LP_PROTOCOL == LP_PROTO_AUTO &&
                     (dt == DT_YUV8 || dt == DT_YUV10 || dt == DT_RAW8 ||
                      dt == DT_RAW10 || dt == DT_RAW12 || dt == DT_RAW14))
                raw_is_long = 1'b1;
            else
                raw_is_long = (dt[3:0] >= 4'h9);
        end
    endfunction

    // HS-trail: every remaining byte of a lane repeats one 00/FF value.
    // Merged byte k belongs to lane k%LANE_NUM, so compare with byte k-LANE_NUM.
    function raw_is_trail;
        input integer p;
        input integer total;
        integer k;
        reg     ok;
        begin
            ok = 1'b1;
            for (k = p; k < total && ok; k = k + 1) begin
                if (k < p + LANE_NUM) begin
                    if (mbyte(k) !== 8'h00 && mbyte(k) !== 8'hFF)
                        ok = 1'b0;
                end else if (mbyte(k) !== mbyte(k - LANE_NUM))
                    ok = 1'b0;
            end
            raw_is_trail = ok;
        end
    endfunction

    // Write each packet up to its CRC (long: 4+WC+2, short: 4) and drop the
    // HS-trail bytes after the last packet.  The first packet is always kept;
    // a packet that runs past the burst end (or has an X WC) keeps every received byte.
    task raw_write_hs;
        input integer total;
        integer k, p, plen, n;
        reg [7:0] di;
        reg       done;
        begin
            if (raw_hs_fd != 0) begin
                raw_hs_burst = raw_hs_burst + 1;
                p = 0;
                done = 1'b0;
                while (!done && p < total) begin
                    if (p + 4 > total || (p > 0 && raw_is_trail(p, total)))
                        done = 1'b1;
                    else begin
                        di = mbyte(p);
                        plen = raw_is_long(di[5:0]) ? (6 + {mbyte(p+2), mbyte(p+1)}) : 4;
                        if ((^plen) === 1'bx || p + plen > total) begin
                            p = total;
                            done = 1'b1;
                        end else
                            p = p + plen;
                    end
                end
                n = (p == 0) ? total : p;
                $fwrite(raw_hs_fd, "%0d %0d", raw_hs_burst, n);
                for (k = 0; k < n; k = k + 1)
                    $fwrite(raw_hs_fd, " %02x", mbyte(k));
                $fwrite(raw_hs_fd, "\n");
                $fflush(raw_hs_fd);
            end
        end
    endtask

    task start_lpdt;
        begin
            if (lp_fd == 0) begin
                lp_fd = $fopen(LP_DATA_FILE, "w");
                if (lp_fd == 0) begin
                    $display("[rx_stub] ERROR: cannot open LP_DATA_FILE '%0s'", LP_DATA_FILE);
                    $fatal(1);
                end
                $fwrite(lp_fd, "# MIPI D-PHY LPDT receive log\n");
                $fwrite(lp_fd, "# time_ps transaction byte_index data_hex\n");
            end
            lpdt_active = 1'b1;
            lp_entry_done = 1'b1;
            lp_shift = 8'h00;
            lp_bit_count = 0;
            lp_byte_count = 0;
            lp_transaction = lp_transaction + 1;
            $display("[rx_stub][lp] t=%0t Escape command LPDT (on-wire 11100001), transaction=%0d",
                     $time, lp_transaction);
            if (lp_fd != 0) begin
                $fwrite(lp_fd, "# transaction %0d start time_ps=%0t protocol=%0d\n",
                        lp_transaction, $time, LP_PROTOCOL);
                $fflush(lp_fd);
            end
        end
    endtask

    task handle_escape_command;
        input [7:0] cmd;
        begin
            case (cmd)
                ESC_LPDT: start_lpdt;
                ESC_ULPS: begin
                    lp_entry_done = 1'b1;
                    data_ulps_active = 1'b1;
                    lp_ctrl_state = LP_CTRL_ULPS;
                    $display("[rx_stub][lp] t=%0t Escape command ULPS (on-wire 00011110): data lane 0 entered LP-00",
                             $time);
                end
                ESC_RESET: begin
                    lp_entry_done = 1'b1;
                    $display("[rx_stub][lp] t=%0t Escape trigger Reset", $time);
                end
                ESC_TRIGGER_3: begin
                    lp_entry_done = 1'b1;
                    $display("[rx_stub][lp] t=%0t Escape trigger Tearing Effect / Trigger-1", $time);
                end
                ESC_TRIGGER_4: begin
                    lp_entry_done = 1'b1;
                    $display("[rx_stub][lp] t=%0t Escape trigger Acknowledge / Trigger-2", $time);
                end
                ESC_TRIGGER_5: begin
                    lp_entry_done = 1'b1;
                    $display("[rx_stub][lp] t=%0t Escape trigger Unknown-5 / Trigger-3", $time);
                end
                ESC_UNDEF_1: begin
                    lp_entry_done = 1'b1;
                    $display("[rx_stub][lp] WARNING t=%0t unsupported Escape command Undefined-1 ignored", $time);
                end
                ESC_UNDEF_2: begin
                    lp_entry_done = 1'b1;
                    $display("[rx_stub][lp] WARNING t=%0t unsupported Escape command Undefined-2 ignored", $time);
                end
                default: begin
                    lp_entry_done = 1'b1;
                    $display("[rx_stub][lp] WARNING t=%0t unassigned Escape command receiver_value=0x%02h ignored",
                             $time, cmd);
                end
            endcase
        end
    endtask

    task handle_lp_byte;
        input [7:0] value;
        reg [5:0] first_dt;
        begin
            $display("[rx_stub][lp][data] t=%0t transaction=%0d byte=%0d value=0x%02h",
                     $time, lp_transaction, lp_byte_count, value);
            if (lp_fd != 0) begin
                $fwrite(lp_fd, "%0t %0d %0d %02x\n",
                        $time, lp_transaction, lp_byte_count, value);
                $fflush(lp_fd);
            end
            if (raw_lp_fd != 0 && lp_byte_count < MAXBPL)
                raw_lp_buf[lp_byte_count] = value;
            if (lp_byte_count == 0) begin
                lp_first_di = value;
                if (LP_PROTOCOL == LP_PROTO_CSI2)
                    display_csi2_lp_type(value);
                else if (LP_PROTOCOL == LP_PROTO_DSI)
                    display_dsi_lp_type("lp", value);
                else begin
                    $display("[rx_stub][lp] AUTO protocol decode; CSI-2/DSI data-type values may overlap");
                    display_csi2_lp_type(value);
                    display_dsi_lp_type("lp", value);
                end
            end else if (LP_PROTOCOL == LP_PROTO_DSI || LP_PROTOCOL == LP_PROTO_AUTO) begin
                first_dt = lp_first_di[5:0];
                // Short packets carry the DCS opcode in header byte 1.  A
                // DCS long write carries it in payload byte 0 (stream byte 4).
                if ((lp_byte_count == 1 &&
                     (first_dt == 6'h05 || first_dt == 6'h06 || first_dt == 6'h15)) ||
                    (lp_byte_count == 4 && first_dt == 6'h39))
                    display_dsi_command("lp", value);
            end
            lp_byte_count = lp_byte_count + 1;
            lp_total_bytes = lp_total_bytes + 1;
        end
    endtask

    task commit_lp_bit;
        input bit_value;
        reg [7:0] completed;
        begin
            completed = lp_shift;
            completed[lp_bit_count] = bit_value;
            if (lp_bit_count == 7) begin
                if (!lp_entry_done)
                    handle_escape_command(completed);
                else if (lpdt_active)
                    handle_lp_byte(completed);
                lp_shift = 8'h00;
                lp_bit_count = 0;
            end else begin
                lp_shift[lp_bit_count] = bit_value;
                lp_bit_count = lp_bit_count + 1;
            end
        end
    endtask

    task finish_lp_escape;
        begin
            if (lpdt_active) begin
                $display("[rx_stub][lp] t=%0t LPDT transaction=%0d complete, bytes=%0d",
                         $time, lp_transaction, lp_byte_count);
                if (lp_fd != 0) begin
                    $fwrite(lp_fd, "# transaction %0d end time_ps=%0t bytes=%0d\n",
                            lp_transaction, $time, lp_byte_count);
                    $fflush(lp_fd);
                end
                raw_write_lp;
            end
            lpdt_active = 1'b0;
            lp_entry_done = 1'b0;
            lp_pending_valid = 1'b0;
            lp_shift = 8'h00;
            lp_bit_count = 0;
            lp_ctrl_state = LP_CTRL_IDLE;
        end
    endtask

    task bta_response;
        begin
            $display("[rx_stub][bta] t=%0t Turnaround Request received; waiting T_TA-GO=%0d ps",
                     $time, T_TA_GO_PS);
            #(T_TA_GO_PS);
            lp0_tx_dp = 1'b0; lp0_tx_dn = 1'b0; lp0_tx_en = 1'b1;
            #(LP_PHASE_PS);
            lp0_tx_dp = 1'b1; lp0_tx_dn = 1'b0; // LP-10 / Mark-1
            #(LP_PHASE_PS);
            lp0_tx_dp = 1'b1; lp0_tx_dn = 1'b1; // LP-11 / Stop
            $display("[rx_stub][bta] t=%0t reverse direction acquired; response LP-00 -> LP-10 -> LP-11 complete",
                     $time);
            if (BTA_AUTO_RETURN) begin
                #(BTA_HOLD_PS);
                // Return the bus using the same Turnaround Request sequence.
                lp0_tx_dp = 1'b1; lp0_tx_dn = 1'b0;
                #(LP_PHASE_PS);
                lp0_tx_dp = 1'b0; lp0_tx_dn = 1'b0;
                #(LP_PHASE_PS);
                lp0_tx_dp = 1'b1; lp0_tx_dn = 1'b0;
                #(LP_PHASE_PS);
                lp0_tx_dp = 1'b0; lp0_tx_dn = 1'b0;
                #(T_TA_SURE_PS);
                lp0_tx_en = 1'b0;
                bta_busy = 1'b0;
                $display("[rx_stub][bta] t=%0t reverse Turnaround Request complete; bus released to initiator",
                         $time);
            end
        end
    endtask

    // Lane-0 Control/Escape state decoder.  A bit is committed only after
    // its Mark-0/Mark-1 is followed by LP-00.  Consequently the LP-10 ->
    // LP-11 Escape exit is not mistaken for one more data bit.
    always @(lp0_dp or lp0_dn) begin
        if (!lp0_tx_en && lp_state_valid(lp0_dp, lp0_dn)) begin
            case (lp_ctrl_state)
                LP_CTRL_IDLE: begin
                    if ({lp0_dp,lp0_dn} == 2'b10)
                        lp_ctrl_state = LP_CTRL_REQ;
                end
                LP_CTRL_REQ: begin
                    if ({lp0_dp,lp0_dn} == 2'b00)
                        lp_ctrl_state = LP_CTRL_BRIDGE;
                    else if ({lp0_dp,lp0_dn} != 2'b10)
                        lp_ctrl_state = LP_CTRL_IDLE;
                end
                LP_CTRL_BRIDGE: begin
                    if ({lp0_dp,lp0_dn} == 2'b01)
                        lp_ctrl_state = LP_CTRL_ESC_MARK;
                    else if ({lp0_dp,lp0_dn} == 2'b10)
                        lp_ctrl_state = LP_CTRL_BTA_MARK;
                    else if ({lp0_dp,lp0_dn} == 2'b11)
                        lp_ctrl_state = LP_CTRL_IDLE;
                end
                LP_CTRL_ESC_MARK: begin
                    if ({lp0_dp,lp0_dn} == 2'b00) begin
                        lp_ctrl_state = LP_CTRL_ESCAPE;
                        lp_entry_done = 1'b0;
                        lpdt_active = 1'b0;
                        lp_pending_valid = 1'b0;
                        lp_shift = 8'h00;
                        lp_bit_count = 0;
                        $display("[rx_stub][lp] t=%0t Escape Mode entry detected", $time);
                    end else
                        lp_ctrl_state = LP_CTRL_IDLE;
                end
                LP_CTRL_BTA_MARK: begin
                    if ({lp0_dp,lp0_dn} == 2'b00) begin
                        lp_ctrl_state = LP_CTRL_IDLE;
                        if (!bta_busy) begin
                            bta_busy = 1'b1;
                            fork
                                bta_response;
                            join_none
                        end
                    end else
                        lp_ctrl_state = LP_CTRL_IDLE;
                end
                LP_CTRL_ESCAPE: begin
                    if (!lp_pending_valid &&
                        ({lp0_dp,lp0_dn} == 2'b10 || {lp0_dp,lp0_dn} == 2'b01)) begin
                        lp_pending_valid = 1'b1;
                        lp_pending_bit = ({lp0_dp,lp0_dn} == 2'b10);
                    end else if (lp_pending_valid && {lp0_dp,lp0_dn} == 2'b00) begin
                        commit_lp_bit(lp_pending_bit);
                        lp_pending_valid = 1'b0;
                    end else if (lp_pending_valid && lp_pending_bit &&
                                 {lp0_dp,lp0_dn} == 2'b11) begin
                        finish_lp_escape;
                    end else if ({lp0_dp,lp0_dn} == 2'b11) begin
                        $display("[rx_stub][lp] WARNING t=%0t Escape Mode aborted before a valid Mark-1 exit",
                                 $time);
                        finish_lp_escape;
                    end
                end
                LP_CTRL_ULPS: begin
                    if ({lp0_dp,lp0_dn} == 2'b10) begin
                        data_ulps_mark_time = $time;
                    end else if ({lp0_dp,lp0_dn} == 2'b11 && data_ulps_active) begin
                        if (($time - data_ulps_mark_time) < T_WAKEUP_PS) begin
                            $display("[rx_stub][ulps] ERROR t=%0t data-lane T_WAKEUP=%0t ps, required >=%0d ps",
                                     $time, $time-data_ulps_mark_time, T_WAKEUP_PS);
                            if (STRICT_ULPS_WAKEUP)
                                $fatal(1);
                        end else begin
                            $display("[rx_stub][ulps] t=%0t data lane 0 exit complete after Mark-1=%0t ps",
                                     $time, $time-data_ulps_mark_time);
                        end
                        data_ulps_active = 1'b0;
                        finish_lp_escape;
                    end
                end
                default: lp_ctrl_state = LP_CTRL_IDLE;
            endcase
        end
    end

    // Clock lane ULPS uses the Control-Mode LP-11 -> LP-10 -> LP-00 entry,
    // then the same Mark-1 (LP-10) / Stop (LP-11) wake-up sequence.
    always @(clp_dp or clp_dn) begin
        if (lp_state_valid(clp_dp, clp_dn)) begin
            case (clk_ulps_state)
                3'd0: if ({clp_dp,clp_dn} == 2'b10) clk_ulps_state = 3'd1;
                3'd1: begin
                    if ({clp_dp,clp_dn} == 2'b00) begin
                        clk_ulps_state = 3'd2;
                        $display("[rx_stub][ulps] t=%0t clock lane entered ULPS", $time);
                    end else if ({clp_dp,clp_dn} != 2'b10)
                        clk_ulps_state = 3'd0;
                end
                3'd2: if ({clp_dp,clp_dn} == 2'b10) begin
                    clk_ulps_mark_time = $time;
                    clk_ulps_state = 3'd3;
                end
                3'd3: if ({clp_dp,clp_dn} == 2'b11) begin
                    if (($time - clk_ulps_mark_time) < T_WAKEUP_PS) begin
                        $display("[rx_stub][ulps] ERROR t=%0t clock-lane T_WAKEUP=%0t ps, required >=%0d ps",
                                 $time, $time-clk_ulps_mark_time, T_WAKEUP_PS);
                        if (STRICT_ULPS_WAKEUP)
                            $fatal(1);
                    end else begin
                        $display("[rx_stub][ulps] t=%0t clock lane exit complete after Mark-1=%0t ps",
                                 $time, $time-clk_ulps_mark_time);
                    end
                    clk_ulps_state = 3'd0;
                end
                default: clk_ulps_state = 3'd0;
            endcase
        end
    end

    task reset_lanes;
        integer L;
        begin
            for (L = 0; L < 4; L = L + 1) begin
                lane_sr[L]   = 8'h00;
                lane_sync[L] = 1'b0;
                lane_bcnt[L] = 0;
                lane_nb[L]   = 0;
                lane_dbg_bits[L]  = 0;
                lane_dbg_bytes[L] = 0;
            end
        end
    endtask

    // sample one bit per data lane on every clock edge (centre of the eye)
    task collect_bits;
        integer L;
        reg [7:0] sr;
        begin
            for (L = 0; L < LANE_NUM; L = L + 1) begin
                if (lane_val[L]) begin
                    sr = {lane_bit[L], lane_sr[L][7:1]};   // LSB-first into [7]
                    if (DEBUG_COLLECT_BITS && (lane_dbg_bits[L] < DEBUG_BITS_PER_LANE)) begin
                        $display("[rx_stub][bits] t=%0t lane=%0d bit_idx=%0d bit=%0b sr_next=%02h sync=%0b bcnt=%0d nb=%0d",
                                 $time, L, lane_dbg_bits[L], lane_bit[L], sr,
                                 lane_sync[L], lane_bcnt[L], lane_nb[L]);
                    end
                    lane_dbg_bits[L] = lane_dbg_bits[L] + 1;
                    lane_sr[L] = sr;
                    if (!lane_sync[L]) begin
                        if (sr == 8'hB8) begin              // sync byte found
                            if (DEBUG_COLLECT_BITS) begin
                                $display("[rx_stub][sync] t=%0t lane=%0d sync_byte=B8 bit_idx=%0d",
                                         $time, L, lane_dbg_bits[L]-1);
                            end
                            lane_sync[L] = 1'b1;
                            lane_bcnt[L] = 0;
                        end
                    end else begin
                        lane_bcnt[L] = lane_bcnt[L] + 1;
                        if (lane_bcnt[L] == 8) begin
                            if (lane_nb[L] < MAXBPL) lane_byte[L][lane_nb[L]] = sr;
                            if (DEBUG_COLLECT_BITS && (lane_dbg_bytes[L] < DEBUG_BYTES_PER_LANE)) begin
                                $display("[rx_stub][byte] t=%0t lane=%0d byte_idx=%0d byte=%02h",
                                         $time, L, lane_dbg_bytes[L], sr);
                            end
                            lane_dbg_bytes[L] = lane_dbg_bytes[L] + 1;
                            lane_nb[L]   = lane_nb[L] + 1;
                            lane_bcnt[L] = 0;
                        end
                    end
                end
            end
        end
    endtask

    always @(posedge clk_hs or negedge clk_hs) begin
        if (clk_val) begin
            #(SAMPLE_DELAY_PS);  // sample after clock edge; TX data/clock share one digital UI grid
            collect_bits;
        end
    end

    always @(posedge any_val) begin
        reset_lanes;
    end

    // A one-sample-wide byte-clock output may lag multi-lane bursts; packet
    // gaps and MAXQ must cover the resulting backlog.
    // ---- output event FIFO (single writer / single reader) ---------------
    // entry = {VC[1:0], Vsync, Hsync, Stb, Data[13:0]}
    reg [18:0] q_mem [0:MAXQ-1];
    integer    wptr, rptr;

    task push_evt;
        input [1:0] vc;
        input v; input h; input s; input [13:0] d;
        begin
            if ((wptr - rptr) >= MAXQ) begin
                $display("[rx_stub] ERROR: output FIFO overflow (MAXQ=%0d)", MAXQ);
                $fatal(1);
            end
            q_mem[wptr % MAXQ] = {vc, v, h, s, d};
            wptr = wptr + 1;
        end
    endtask

    // merged-stream byte accessor : byte k came from lane (k%LANE_NUM), index (k/LANE_NUM)
    function [7:0] mbyte;
        input integer k;
        begin
            mbyte = lane_byte[k % LANE_NUM][k / LANE_NUM];
        end
    endfunction

    task protocol_error;
        input [8*64-1:0] msg;
        input [1:0] vc;
        input [5:0] dt;
        input integer total;
        begin
            $display("[rx_stub][proto] ERROR t=%0t %0s vc=%0d dt=0x%02h total=%0d frame_active=%0b frame=%0d line=%0d q=%0d header=%02h %02h %02h %02h",
                     $time, msg, vc, dt, total, frame_active[vc], dbg_frame_no[vc], dbg_line_no[vc],
                     wptr - rptr, mbyte(0), mbyte(1), mbyte(2), mbyte(3));
            if (STRICT_PROTOCOL_FINISH)
                $fatal(1);
        end
    endtask

    task lane_activity_error;
        input integer total;
        begin
            $display("[rx_stub][lane] ERROR t=%0t LANE_NUM=%0d but one or more configured lanes received no bytes: lane_nb=%0d,%0d,%0d,%0d total=%0d",
                     $time, LANE_NUM, lane_nb[0], lane_nb[1], lane_nb[2], lane_nb[3], total);
            $display("[rx_stub][lane] HINT: check Tx/Rx lane-number setting or pad mapping; a 4-lane stub cannot decode a 2-lane burst.");
            $fatal(1);
        end
    endtask

    task dsi_ppm_close;
        begin
            if (dsi_ppm_fd != 0) begin
                $fclose(dsi_ppm_fd);
                dsi_ppm_fd = 0;
            end
            dsi_ppm_open = 1'b0;
            dsi_ppm_line_no = 0;
        end
    endtask

    task dsi_ppm_start;
        begin
            dsi_ppm_frame_no = dsi_ppm_frame_no + 1;
            dsi_ppm_line_no = 0;
            $sformat(dsi_ppm_filename, "dsi_rgb_frame_%04d.ppm", dsi_ppm_frame_no);
            dsi_ppm_fd = $fopen(dsi_ppm_filename, "w");
            if (dsi_ppm_fd == 0) begin
                $display("[rx_stub][dsi_ppm] ERROR: cannot open %0s", dsi_ppm_filename);
                $fatal(1);
            end
            $fwrite(dsi_ppm_fd, "P3\n%0d %0d\n255\n", dsi_hsize, dsi_vsize);
            dsi_ppm_open = 1'b1;
            dsi_ppm_drop_warned = 1'b0;
            $display("[rx_stub][dsi_ppm] dumping frame %0d to %0s", dsi_ppm_frame_no, dsi_ppm_filename);
        end
    endtask

    task dsi_ppm_incomplete;
        begin
            $display("[rx_stub][dsi_ppm] ERROR: incomplete frame %0d: lines=%0d expected=%0d file=%0s",
                     dsi_ppm_frame_no, dsi_ppm_line_no, dsi_vsize, dsi_ppm_filename);
            dsi_ppm_errors = dsi_ppm_errors + 1;
            dsi_ppm_close;
        end
    endtask

    // DCS long-write payloads are RGB888 bytes, not parallel-port samples.
    task dsi_ppm_packet;
        input [1:0] vc;
        input integer total;
        integer wc, base, x;
        reg has_cmd;
        reg [7:0] cmd;
        begin : packet
            if (total < 4) begin
                $display("[rx_stub][dsi_ppm] ERROR: truncated DCS header (total=%0d)", total);
                $fatal(1);
            end
            wc = {mbyte(2), mbyte(1)};
            if (6 + wc > total) begin
                dsi_ppm_errors = dsi_ppm_errors + 1;
                protocol_error("truncated DCS long-write payload or CRC", vc, 6'h39, total);
                disable packet;
            end

            if (wc == 3 * dsi_hsize)
                has_cmd = 1'b0;
            else if (wc == 3 * dsi_hsize + 1)
                has_cmd = 1'b1;
            else begin
                if (wc > 0) begin
                    case (mbyte(4))
                        8'h01, 8'h10, 8'h11, 8'h20, 8'h21, 8'h28, 8'h29,
                        8'h2A, 8'h2B, 8'h35, 8'h36, 8'h3A, 8'h44,
                        8'h51, 8'h53, 8'h55: begin
                            display_dsi_command("hs", mbyte(4));
                            disable packet;
                        end
                    endcase
                end
                dsi_ppm_errors = dsi_ppm_errors + 1;
                protocol_error("DCS WC matches neither RGB888 line bytes nor +1", vc, 6'h39, total);
                disable packet;
            end

            base = has_cmd ? 5 : 4;
            if (has_cmd) begin
                cmd = mbyte(4);
                if (cmd == 8'h2C) begin
                    if (dsi_ppm_open)
                        dsi_ppm_incomplete;
                    dsi_ppm_start;
                end else if (cmd == 8'h3C) begin
                    if (!dsi_ppm_open) begin
                        if (!dsi_ppm_drop_warned) begin
                            $display("[rx_stub][dsi_ppm] WARNING: 0x3C before 0x2C; dropping line");
                            dsi_ppm_drop_warned = 1'b1;
                        end
                        disable packet;
                    end
                end else begin
                    display_dsi_command("hs", cmd);
                    disable packet;
                end
            end else if (!dsi_ppm_open) begin
                dsi_ppm_start;
            end

            for (x = 0; x < dsi_hsize; x = x + 1)
                $fwrite(dsi_ppm_fd, "%0d %0d %0d\n",
                        mbyte(base + 3*x), mbyte(base + 3*x + 1), mbyte(base + 3*x + 2));
            dsi_ppm_line_no = dsi_ppm_line_no + 1;
            if (dsi_ppm_line_no == dsi_vsize) begin
                $display("[rx_stub][dsi_ppm] completed frame %0d: %0s", dsi_ppm_frame_no, dsi_ppm_filename);
                dsi_ppm_close;
            end
        end
    endtask

    // ---- display a DSI HS packet (decode only, no parallel output) --------
    task decode_dsi_hs_packet;
        input [7:0] di;
        input integer total;
        reg [5:0] dt;
        begin
            dt = di[5:0];
            if (dsi_ppm_en && dt == 6'h39)
                dsi_ppm_packet(di[7:6], total);
            else begin
                display_dsi_lp_type("hs", di);
                // Short packets carry the DCS opcode in header byte 1.  A
                // DCS long write carries it in payload byte 0 (stream byte 4).
                if (dt == 6'h05 || dt == 6'h06 || dt == 6'h15)
                    display_dsi_command("hs", mbyte(1));
                else if (dt == 6'h39 && total >= 5)
                    display_dsi_command("hs", mbyte(4));
            end
        end
    endtask

    // ---- parse one received burst into output events ---------------------
    task parse_burst;
        integer total, wc, g, base, np;
        reg [7:0]  di, b0, b1, b2, b3, b4, b5, b6, lsb;
        reg [5:0]  dt;
        reg [1:0]  vc;
        reg        vc_out_en;
        begin
            total = 0;
            for (g = 0; g < LANE_NUM; g = g + 1) total = total + lane_nb[g];
            if (total < 1) ;                       // empty burst, ignore
            else begin
                if ((LANE_NUM >= 1 && lane_nb[0] == 0) ||
                    (LANE_NUM >= 2 && lane_nb[1] == 0) ||
                    (LANE_NUM >= 4 && (lane_nb[2] == 0 || lane_nb[3] == 0)))
                    lane_activity_error(total);
                raw_write_hs(total);
                di = mbyte(0);
                vc = di[7:6];
                dt = di[5:0];
                vc_out_en = ((VC_FILTER < 0) || (vc == VC_FILTER));
                if (DEBUG_PACKET_HEADERS) begin
                    $display("[rx_stub][pkt] t=%0t vc=%0d dt=0x%02h data=0x%04h ecc=0x%02h total=%0d lane_nb=%0d,%0d,%0d,%0d header=%02h %02h %02h %02h",
                             $time, vc, dt, {mbyte(2), mbyte(1)}, mbyte(3), total,
                             lane_nb[0], lane_nb[1], lane_nb[2], lane_nb[3],
                             mbyte(0), mbyte(1), mbyte(2), mbyte(3));
                end
                if (LP_PROTOCOL == LP_PROTO_DSI) begin // DSI: decode/display only
                    decode_dsi_hs_packet(di, total);
                end else if (dt == DT_FS) begin    // Frame Start
                    if (frame_active[vc])
                        protocol_error("Frame Start before previous Frame End", vc, dt, total);
                    dbg_frame_no[vc] = dbg_frame_no[vc] + 1;
                    dbg_line_no[vc] = 0;
                    if (DEBUG_FRAME_EVENTS)
                        $display("[rx_stub][flow] t=%0t VC%0d FRAME_START frame=%0d data=0x%04h total=%0d q=%0d",
                                 $time, vc, dbg_frame_no[vc], {mbyte(2), mbyte(1)}, total, wptr - rptr);
                    frame_active[vc] = 1'b1;
                end else if (dt == DT_FE) begin    // Frame End
                    if (!frame_active[vc])
                        protocol_error("Frame End received outside frame", vc, dt, total);
                    if (DEBUG_FRAME_EVENTS)
                        $display("[rx_stub][flow] t=%0t VC%0d FRAME_END frame=%0d data=0x%04h lines=%0d total=%0d q=%0d",
                                 $time, vc, dbg_frame_no[vc], {mbyte(2), mbyte(1)}, dbg_line_no[vc], total, wptr - rptr);
                    if (frame_active[vc]) begin
                        frame_active[vc] = 1'b0;
                        if (vc_out_en)
                            push_evt(vc, 1'b1, 1'b1, 1'b0, 14'h0);
                    end
                end else if (dt == DT_LS) begin    // Line Start short packet
                    if (!frame_active[vc])
                        protocol_error("Line Start received before Frame Start", vc, dt, total);
                    if (DEBUG_FRAME_EVENTS)
                        $display("[rx_stub][flow] t=%0t VC%0d LINE_START_SHORT frame=%0d line=%0d data=0x%04h total=%0d q=%0d",
                                 $time, vc, dbg_frame_no[vc], dbg_line_no[vc], {mbyte(2), mbyte(1)}, total, wptr - rptr);
                end else if (dt == DT_LE) begin    // Line End short packet
                    if (!frame_active[vc])
                        protocol_error("Line End received outside frame", vc, dt, total);
                    if (DEBUG_FRAME_EVENTS)
                        $display("[rx_stub][flow] t=%0t VC%0d LINE_END_SHORT frame=%0d line=%0d data=0x%04h total=%0d q=%0d",
                                 $time, vc, dbg_frame_no[vc], dbg_line_no[vc], {mbyte(2), mbyte(1)}, total, wptr - rptr);
                end else if (total >= 6 &&
                             (dt == DT_YUV8 || dt == DT_YUV10 ||
                              dt == DT_RAW8 || dt == DT_RAW10 ||
                              dt == DT_RAW12 || dt == DT_RAW14)) begin // long packet (image line)
                    if (!frame_active[vc])
                        protocol_error("Image line received before Frame Start", vc, dt, total);
                    if (frame_active[vc] && (EXPECT_FRAME_LINES > 0) &&
                        (dbg_line_no[vc] >= EXPECT_FRAME_LINES))
                        protocol_error("Line after expected count before FE", vc, dt, total);
                    wc = {mbyte(2), mbyte(1)};
                    if (DEBUG_LINE_EVENTS)
                        $display("[rx_stub][flow] t=%0t VC%0d LINE_START_LONG frame=%0d line=%0d dt=0x%02h wc=%0d total=%0d q=%0d",
                                 $time, vc, dbg_frame_no[vc], dbg_line_no[vc], dt, wc, total, wptr - rptr);
                    if (frame_active[vc]) begin
                        if (vc_out_en)
                            push_evt(vc, 1'b0, 1'b0, 1'b0, 14'h0);     // Vsync/Hsync active together
                        if (DATA_BITS == 8) begin
                            for (g = 0; g < wc; g = g + 1) begin
                                if (vc_out_en)
                                    push_evt(vc, 1'b0, 1'b0, 1'b1, {mbyte(4+g), 6'h0});
                            end
                        end else if (DATA_BITS == 10) begin
                            np = wc / 5;
                            for (g = 0; g < np; g = g + 1) begin
                                base = 4 + g*5;
                                b0 = mbyte(base); b1 = mbyte(base+1);
                                b2 = mbyte(base+2); b3 = mbyte(base+3);
                                lsb = mbyte(base+4);
                                if (vc_out_en) begin
                                    push_evt(vc, 1'b0,1'b0,1'b1, {b0, lsb[1:0], 4'h0});
                                    push_evt(vc, 1'b0,1'b0,1'b1, {b1, lsb[3:2], 4'h0});
                                    push_evt(vc, 1'b0,1'b0,1'b1, {b2, lsb[5:4], 4'h0});
                                    push_evt(vc, 1'b0,1'b0,1'b1, {b3, lsb[7:6], 4'h0});
                                end
                            end
                        end else if (DATA_BITS == 12) begin
                            np = wc / 3;
                            for (g = 0; g < np; g = g + 1) begin
                                base = 4 + g*3;
                                b0 = mbyte(base); b1 = mbyte(base+1); b2 = mbyte(base+2);
                                if (vc_out_en) begin
                                    push_evt(vc, 1'b0,1'b0,1'b1, {b0, b2[3:0], 2'h0});
                                    push_evt(vc, 1'b0,1'b0,1'b1, {b1, b2[7:4], 2'h0});
                                end
                            end
                        end else begin // 14-bit
                            np = wc / 7;
                            for (g = 0; g < np; g = g + 1) begin
                                base = 4 + g*7;
                                b0 = mbyte(base); b1 = mbyte(base+1);
                                b2 = mbyte(base+2); b3 = mbyte(base+3);
                                b4 = mbyte(base+4); b5 = mbyte(base+5); b6 = mbyte(base+6);
                                if (vc_out_en) begin
                                    push_evt(vc, 1'b0,1'b0,1'b1, {b0, b4[5:0]});
                                    push_evt(vc, 1'b0,1'b0,1'b1, {b1, b5[3:0], b4[7:6]});
                                    push_evt(vc, 1'b0,1'b0,1'b1, {b2, b6[1:0], b5[7:4]});
                                    push_evt(vc, 1'b0,1'b0,1'b1, {b3, b6[7:2]});
                                end
                            end
                        end
                        if (DEBUG_LINE_EVENTS)
                            $display("[rx_stub][flow] t=%0t VC%0d LINE_END_LONG frame=%0d line=%0d dt=0x%02h q=%0d",
                                     $time, vc, dbg_frame_no[vc], dbg_line_no[vc], dt, wptr - rptr);
                        dbg_line_no[vc] = dbg_line_no[vc] + 1;
                    end
                end else if (LP_PROTOCOL == LP_PROTO_AUTO) begin // not a CSI-2 image DT: show as DSI
                    decode_dsi_hs_packet(di, total);
                end else begin
                    $display("[rx_stub] WARNING: ignored packet vc=%0d dt=0x%02h total=%0d header=%02h %02h %02h %02h lane_nb=%0d,%0d,%0d,%0d time=%0t",
                             vc, dt, total,
                             mbyte(0), mbyte(1), mbyte(2), mbyte(3),
                             lane_nb[0], lane_nb[1], lane_nb[2], lane_nb[3], $time);
                end
            end
            reset_lanes;
        end
    endtask

    always @(negedge any_val) parse_burst;

    // Update at the falling edge; control and data are stable at the next
    // rising edge where the checker samples this byte-clocked interface.
    always @(negedge Pxclk) begin
        if (rptr != wptr) begin
            if (DEBUG_VALID_DATA && q_mem[rptr % MAXQ][14]) begin
                $display("[rx_stub][data] t=%0t rptr=%0d vc=%0d d=0x%04h q=%0d",
                         $time, rptr, q_mem[rptr % MAXQ][18:17],
                         q_mem[rptr % MAXQ][13:0], wptr - rptr);
            end
            {VC, Vsync, Hsync, Stb, Data} <= q_mem[rptr % MAXQ];
            rptr <= rptr + 1;
        end else begin
            VC    <= VC;
            Vsync <= Vsync;
            Hsync <= 1'b1;
            Stb   <= 1'b0;
            Data  <= 14'h0;
        end
    end

    // ---- init / free-running pixel clock ---------------------------------
    initial begin
        integer got_plusarg;
        Pxclk = 1'b0; Vsync = 1'b1; Hsync = 1'b1; Stb = 1'b0; VC = 2'h0; Data = 14'h0;
        wptr = 0; rptr = 0; frame_active = 4'h0;
        lp0_tx_en = 1'b0; lp0_tx_dp = 1'b1; lp0_tx_dn = 1'b1; bta_busy = 1'b0;
        lp_ctrl_state = LP_CTRL_IDLE;
        lp_pending_valid = 1'b0; lp_pending_bit = 1'b0;
        lp_entry_done = 1'b0; lpdt_active = 1'b0; data_ulps_active = 1'b0;
        lp_shift = 8'h00; lp_first_di = 8'h00;
        lp_bit_count = 0; lp_byte_count = 0; lp_total_bytes = 0; lp_transaction = 0; lp_fd = 0;
        data_ulps_mark_time = 0; clk_ulps_mark_time = 0; clk_ulps_state = 0;
        dbg_frame_no[0] = 0; dbg_frame_no[1] = 0; dbg_frame_no[2] = 0; dbg_frame_no[3] = 0;
        dbg_line_no[0] = 0; dbg_line_no[1] = 0; dbg_line_no[2] = 0; dbg_line_no[3] = 0;
        dsi_ppm_en = DSI_PPM_EN; dsi_hsize = DSI_HSIZE; dsi_vsize = DSI_VSIZE;
        dsi_ppm_fd = 0; dsi_ppm_frame_no = 0; dsi_ppm_line_no = 0; dsi_ppm_errors = 0;
        dsi_ppm_open = 1'b0; dsi_ppm_drop_warned = 1'b0;
        // plusargs override the parameters; an absent plusarg leaves the value unchanged
        got_plusarg = $value$plusargs("DSI_PPM=%d", dsi_ppm_en);
        got_plusarg = $value$plusargs("DSI_HSIZE=%d", dsi_hsize);
        got_plusarg = $value$plusargs("DSI_VSIZE=%d", dsi_vsize);
        if (dsi_ppm_en) begin
            if (dsi_hsize <= 0 || dsi_vsize <= 0 || dsi_hsize > 21844) begin
                $display("[rx_stub][dsi_ppm] CONFIG ERROR: require DSI_HSIZE=1..21844 and DSI_VSIZE>0");
                $fatal(1);
            end
            if (LP_PROTOCOL == LP_PROTO_CSI2) begin
                $display("[rx_stub][dsi_ppm] CONFIG ERROR: LP_PROTOCOL=1 does not decode DSI HS packets");
                $fatal(1);
            end
        end
        raw_dump_en = RAW_DUMP_EN; raw_lp_fd = 0; raw_hs_fd = 0; raw_hs_burst = 0;
        got_plusarg = $value$plusargs("RAW_DUMP=%d", raw_dump_en);
        if (raw_dump_en) begin
            raw_lp_fd = $fopen(RAW_LP_FILE, "w");
            raw_hs_fd = $fopen(RAW_HS_FILE, "w");
            if (raw_lp_fd == 0 || raw_hs_fd == 0) begin
                $display("[rx_stub][raw] ERROR: cannot open RAW_LP_FILE '%0s' or RAW_HS_FILE '%0s'",
                         RAW_LP_FILE, RAW_HS_FILE);
                $fatal(1);
            end
            $fwrite(raw_lp_fd, "# MIPI D-PHY LPDT raw receive log\n");
            $fwrite(raw_lp_fd, "# transaction bytes data_hex...\n");
            $fwrite(raw_hs_fd, "# MIPI D-PHY HS raw receive log (lane-merged packets after the sync byte, HS-trail dropped)\n");
            $fwrite(raw_hs_fd, "# burst bytes data_hex...\n");
            $display("[rx_stub][raw] dumping LPDT to %0s, HS bursts to %0s", RAW_LP_FILE, RAW_HS_FILE);
        end
        if (LANE_NUM != 1 && LANE_NUM != 2 && LANE_NUM != 4) begin
            $display("[rx_stub] CONFIG ERROR: LANE_NUM=%0d unsupported; use 1, 2, or 4", LANE_NUM);
            $fatal(1);
        end
        if (LP_PROTOCOL < LP_PROTO_AUTO || LP_PROTOCOL > LP_PROTO_DSI) begin
            $display("[rx_stub] CONFIG ERROR: LP_PROTOCOL=%0d unsupported; use 0=AUTO, 1=CSI-2, or 2=DSI",
                     LP_PROTOCOL);
            $fatal(1);
        end
        if (LP_PHASE_PS <= 0 || T_TA_GO_PS < 0 || T_TA_SURE_PS < 0 ||
            BTA_HOLD_PS < 0 || T_WAKEUP_PS < 0) begin
            $display("[rx_stub] CONFIG ERROR: LP/BTA/ULPS timing parameters must be non-negative and LP_PHASE_PS must be > 0");
            $fatal(1);
        end
        reset_lanes;
    end
    always #(PXCLK_HALF) Pxclk = ~Pxclk;

    // final blocks cannot enable tasks; inline dsi_ppm_incomplete/dsi_ppm_close
    final begin
        if (dsi_ppm_open) begin
            $display("[rx_stub][dsi_ppm] ERROR: incomplete frame %0d: lines=%0d expected=%0d file=%0s",
                     dsi_ppm_frame_no, dsi_ppm_line_no, dsi_vsize, dsi_ppm_filename);
            if (dsi_ppm_fd != 0)
                $fclose(dsi_ppm_fd);
        end
        if (raw_lp_fd != 0)
            $fclose(raw_lp_fd);
        if (raw_hs_fd != 0)
            $fclose(raw_hs_fd);
    end

endmodule
