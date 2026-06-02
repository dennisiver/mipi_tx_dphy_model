//============================================================================
//  mipi_tx_dphy_model.v
//----------------------------------------------------------------------------
//  Behavioural MIPI D-PHY transmitter model (CSI-2 framing) intended to drive
//  the M31 MIPI Rx D-PHY model.
//
//      * 4 data lanes + 1 clock lane, continuous-clock HS mode
//      * up to 2.5 Gbps/lane   (UI programmable, default 400 ps)
//      * up to 8K frame size   (Hsize x Vsize programmable)
//      * per-lane skew injection + deskew-calibration burst
//      * RAW8 / RAW10 / RAW12 data formats (auto pixel bit-width)
//      * built-in golden patterns + golden_pattern.txt loader
//      * input trigger gates the start of transmission
//
//  Digital HS/LP pad encoding (matches the M31 Rx model), 3 bits per pad:
//      [2] : Low-Power level  (driven during LP states, held 0 during HS)
//      [1] : High-Speed data  (P = bit, N = ~bit; only meaningful when [0]=1)
//      [0] : High-Speed valid (1 from HS-0 until return to LP, else 0)
//
//  This is a *simulation model*, not synthesizable RTL.  Protocol timing is
//  abstracted through the T_*_PS parameters so that simulation stays fast;
//  tune them to the exact M31 requirements if necessary.
//============================================================================
`timescale 1ps/1ps

module mipi_tx_dphy_model #(
    // ---- line rate -------------------------------------------------------
    parameter integer UI_PS          = 400,    // unit interval; 400ps = 2.5Gbps
    // ---- abstracted D-PHY timing (picoseconds) ---------------------------
    // NOTE: keep these as integer multiples of UI_PS so the data bit grid
    //       stays aligned to the DDR clock edges (the model samples mid-eye).
    parameter integer T_LPX_PS       = 4800,   // LP state period
    parameter integer T_HS_PREP_PS   = 4000,   // data lane HS-prepare (LP-00)
    parameter integer T_HS_ZERO_PS   = 4000,   // data lane HS-zero
    parameter integer T_HS_TRAIL_PS  = 3200,   // data lane HS-trail
    parameter integer T_CLK_PREP_PS  = 4000,   // clock lane HS-prepare
    parameter integer T_CLK_ZERO_PS  = 6000,   // clock lane HS-zero
    parameter integer T_CLK_TRAIL_PS = 3200,   // clock lane HS-trail
    parameter integer T_CLK_PRE_PS   = 20000,  // clock running before 1st data burst
    parameter integer T_FRAME_GAP_PS = 20000,  // idle after FE before clock exit
    // ---- per-lane skew injection (picoseconds) ---------------------------
    parameter integer SKEW_L0_PS     = 0,
    parameter integer SKEW_L1_PS     = 0,
    parameter integer SKEW_L2_PS     = 0,
    parameter integer SKEW_L3_PS     = 0,
    // ---- deskew calibration burst ----------------------------------------
    parameter integer SKEW_PREAMBLE  = 32,     // leading 0 bits
    parameter integer SKEW_CAL_BITS  = 256,    // toggling 0101.. bits
    // ---- golden pattern --------------------------------------------------
    parameter integer GP_MAX         = 65536,
    parameter         GP_FILE        = "golden_pattern.txt",
    // ---- virtual channel -------------------------------------------------
    parameter integer VC             = 0
)(
    input  wire        rst_n,        // active-low reset
    input  wire        trigger,      // start transmission on rising edge / level high

    // runtime configuration (sampled when a frame sequence starts) ---------
    input  wire [15:0] hsize,        // active pixels per line   (max 7680)
    input  wire [15:0] vsize,        // active lines per frame   (max 4320)
    input  wire [7:0]  data_type,    // CSI-2 DT: 0x2A=RAW8 0x2B=RAW10 0x2C=RAW12
    input  wire [2:0]  pattern_sel,  // 0..5 (see golden_pixel.vh)
    input  wire [11:0] solid_val,    // value for solid pattern
    input  wire [15:0] num_frames,   // number of frames to send per trigger
    input  wire        skew_cal_en,  // 1 = send deskew calibration burst/frame

    // pad interface to the M31 Rx D-PHY model (Tx drives) ------------------
    output wire [2:0]  PAD_CDRX_L0P, output wire [2:0] PAD_CDRX_L0N,  // data lane 0
    output wire [2:0]  PAD_CDRX_L1P, output wire [2:0] PAD_CDRX_L1N,  // data lane 1
    output wire [2:0]  PAD_CDRX_L2P, output wire [2:0] PAD_CDRX_L2N,  // data lane 2
    output wire [2:0]  PAD_CDRX_L3P, output wire [2:0] PAD_CDRX_L3N,  // data lane 3
    output wire [2:0]  PAD_CDRX_L4P, output wire [2:0] PAD_CDRX_L4N,  // clock lane

    // status ---------------------------------------------------------------
    output reg         busy,
    output reg         frame_done
);

    // CSI-2 data types
    localparam [7:0] DT_FS    = 8'h00;
    localparam [7:0] DT_FE    = 8'h01;
    localparam [7:0] DT_RAW8  = 8'h2A;
    localparam [7:0] DT_RAW10 = 8'h2B;
    localparam [7:0] DT_RAW12 = 8'h2C;

    // packet buffers
    localparam integer MAXB = 24576;            // max bytes in one HS packet
    reg  [7:0] pkt  [0:MAXB-1];                  // assembled packet bytes
    integer    pkt_len;
    reg  [7:0] lbuf [0:3][0:(MAXB/4)+3];         // per-lane byte buffers
    integer    lcnt [0:3];

    // golden pattern storage (used by golden_pixel.vh)
    reg  [11:0] gp_mem [0:GP_MAX-1];
    integer     gp_fcount;

    // lane pad drive registers : index 0..3 = data lanes, 4 = clock lane
    reg  [2:0] padP [0:4];
    reg  [2:0] padN [0:4];

    assign PAD_CDRX_L0P = padP[0];  assign PAD_CDRX_L0N = padN[0];
    assign PAD_CDRX_L1P = padP[1];  assign PAD_CDRX_L1N = padN[1];
    assign PAD_CDRX_L2P = padP[2];  assign PAD_CDRX_L2N = padN[2];
    assign PAD_CDRX_L3P = padP[3];  assign PAD_CDRX_L3N = padN[3];
    assign PAD_CDRX_L4P = padP[4];  assign PAD_CDRX_L4N = padN[4];

    // sampled run-time configuration
    reg [15:0] cfg_h, cfg_v, cfg_nf;
    reg [7:0]  cfg_dt;
    reg [2:0]  cfg_pat;
    reg [11:0] cfg_solid;
    reg        cfg_skew;
    integer    cfg_bits;

    integer    lane_skew [0:3];
    reg        clk_hs_active;

    `include "mipi_csi2_func.v"
    `include "golden_pixel.v"

    // ----- format helper --------------------------------------------------
    function integer dt_bits;
        input [7:0] dt;
        begin
            case (dt)
                DT_RAW8 : dt_bits = 8;
                DT_RAW10: dt_bits = 10;
                DT_RAW12: dt_bits = 12;
                default : dt_bits = 8;
            endcase
        end
    endfunction

    // ----- low level pad drivers -----------------------------------------
    task automatic set_lp;                        // drive an LP state
        input integer lane;
        input         dp;
        input         dn;
        begin
            padP[lane] = {dp, 1'b0, 1'b0};
            padN[lane] = {dn, 1'b0, 1'b0};
        end
    endtask

    task automatic set_hs;                        // drive one HS bit (valid)
        input integer lane;
        input         b;
        begin
            padP[lane] = {1'b0,  b, 1'b1};
            padN[lane] = {1'b0, ~b, 1'b1};
        end
    endtask

    // ----- single data-lane HS burst -------------------------------------
    task automatic tx_lane_stream;
        input integer lane;
        input integer nbytes;
        integer i, bb;
        reg [7:0] by;
        reg       lastbit;
        begin
            #(lane_skew[lane]);
            set_hs(lane, 1'b0);  #(T_HS_ZERO_PS);          // HS-0
            by = 8'hB8;                                    // sync byte (LSB first)
            for (bb = 0; bb < 8; bb = bb + 1) begin set_hs(lane, by[bb]); #(UI_PS); end
            lastbit = by[7];
            for (i = 0; i < nbytes; i = i + 1) begin       // payload
                by = lbuf[lane][i];
                for (bb = 0; bb < 8; bb = bb + 1) begin set_hs(lane, by[bb]); #(UI_PS); end
                lastbit = by[7];
            end
            set_hs(lane, lastbit); #(T_HS_TRAIL_PS);       // HS-trail
            set_lp(lane, 1'b1, 1'b1);                      // back to LP-11 (Stop)
        end
    endtask

    // ----- deskew calibration burst on one data lane ---------------------
    task automatic tx_lane_deskew;
        input integer lane;
        integer i;
        begin
            #(lane_skew[lane]);
            set_hs(lane, 1'b0); #(T_HS_ZERO_PS);
            for (i = 0; i < SKEW_PREAMBLE; i = i + 1) begin set_hs(lane, 1'b0);    #(UI_PS); end
            for (i = 0; i < SKEW_CAL_BITS; i = i + 1) begin set_hs(lane, i[0]);    #(UI_PS); end
            set_hs(lane, 1'b0); #(T_HS_TRAIL_PS);
            set_lp(lane, 1'b1, 1'b1);
        end
    endtask

    // ----- send the assembled packet across the 4 data lanes -------------
    task send_packet;
        integer i, L;
        begin
            lcnt[0]=0; lcnt[1]=0; lcnt[2]=0; lcnt[3]=0;
            for (i = 0; i < pkt_len; i = i + 1) begin
                L = i % 4;
                lbuf[L][lcnt[L]] = pkt[i];
                lcnt[L] = lcnt[L] + 1;
            end
            // LP-11 -> LP-01 -> LP-00 (HS request) on all data lanes
            set_lp(0,1'b0,1'b1); set_lp(1,1'b0,1'b1); set_lp(2,1'b0,1'b1); set_lp(3,1'b0,1'b1);
            #(T_LPX_PS);
            set_lp(0,1'b0,1'b0); set_lp(1,1'b0,1'b0); set_lp(2,1'b0,1'b0); set_lp(3,1'b0,1'b0);
            #(T_HS_PREP_PS);
            fork
                tx_lane_stream(0, lcnt[0]);
                tx_lane_stream(1, lcnt[1]);
                tx_lane_stream(2, lcnt[2]);
                tx_lane_stream(3, lcnt[3]);
            join
            #(T_LPX_PS);
        end
    endtask

    // ----- deskew calibration burst across all data lanes ----------------
    task send_skew_cal;
        begin
            set_lp(0,1'b0,1'b1); set_lp(1,1'b0,1'b1); set_lp(2,1'b0,1'b1); set_lp(3,1'b0,1'b1);
            #(T_LPX_PS);
            set_lp(0,1'b0,1'b0); set_lp(1,1'b0,1'b0); set_lp(2,1'b0,1'b0); set_lp(3,1'b0,1'b0);
            #(T_HS_PREP_PS);
            fork
                tx_lane_deskew(0);
                tx_lane_deskew(1);
                tx_lane_deskew(2);
                tx_lane_deskew(3);
            join
            #(T_LPX_PS);
        end
    endtask

    // ----- clock lane : LP entry, continuous DDR clock, LP exit ----------
    task clk_lane_run;
        begin
            set_lp(4,1'b1,1'b1); #(T_LPX_PS);
            set_lp(4,1'b0,1'b1); #(T_LPX_PS);
            set_lp(4,1'b0,1'b0); #(T_CLK_PREP_PS);
            set_hs(4,1'b0);      #(T_CLK_ZERO_PS);
            clk_hs_active = 1'b1;
            while (clk_hs_active) begin
                set_hs(4,1'b0); #(UI_PS);
                set_hs(4,1'b1); #(UI_PS);
            end
            set_hs(4,1'b0); #(T_CLK_TRAIL_PS);
            set_lp(4,1'b1,1'b1);
        end
    endtask

    // ----- build a CSI-2 short packet (FS / FE) --------------------------
    task build_short;
        input [7:0]  dt;
        input [15:0] dat;
        reg [7:0] di;
        begin
            di     = {VC[1:0], dt[5:0]};
            pkt[0] = di;
            pkt[1] = dat[7:0];
            pkt[2] = dat[15:8];
            pkt[3] = csi2_ecc({pkt[2], pkt[1], pkt[0]});
            pkt_len = 4;
        end
    endtask

    // ----- build a CSI-2 long packet (one image line) --------------------
    task build_line;
        input [31:0] frame;
        input [15:0] row;
        integer c, b, wc;
        reg [11:0] p0, p1, p2, p3;
        reg [15:0] crc;
        reg [7:0]  di;
        begin
            b = 4;                                   // payload starts after PH
            if (cfg_bits == 8) begin
                for (c = 0; c < cfg_h; c = c + 1) begin
                    p0 = golden_pixel(frame,row,c[15:0],cfg_h,cfg_pat,cfg_bits,cfg_solid);
                    pkt[b] = p0[7:0]; b = b + 1;
                end
            end else if (cfg_bits == 10) begin
                for (c = 0; c < cfg_h; c = c + 4) begin
                    p0 = golden_pixel(frame,row,(c  )&16'hFFFF,cfg_h,cfg_pat,cfg_bits,cfg_solid);
                    p1 = golden_pixel(frame,row,(c+1)&16'hFFFF,cfg_h,cfg_pat,cfg_bits,cfg_solid);
                    p2 = golden_pixel(frame,row,(c+2)&16'hFFFF,cfg_h,cfg_pat,cfg_bits,cfg_solid);
                    p3 = golden_pixel(frame,row,(c+3)&16'hFFFF,cfg_h,cfg_pat,cfg_bits,cfg_solid);
                    pkt[b  ] = p0[9:2];
                    pkt[b+1] = p1[9:2];
                    pkt[b+2] = p2[9:2];
                    pkt[b+3] = p3[9:2];
                    pkt[b+4] = {p3[1:0], p2[1:0], p1[1:0], p0[1:0]};
                    b = b + 5;
                end
            end else begin // 12-bit
                for (c = 0; c < cfg_h; c = c + 2) begin
                    p0 = golden_pixel(frame,row,(c  )&16'hFFFF,cfg_h,cfg_pat,cfg_bits,cfg_solid);
                    p1 = golden_pixel(frame,row,(c+1)&16'hFFFF,cfg_h,cfg_pat,cfg_bits,cfg_solid);
                    pkt[b  ] = p0[11:4];
                    pkt[b+1] = p1[11:4];
                    pkt[b+2] = {p1[3:0], p0[3:0]};
                    b = b + 3;
                end
            end
            wc = b - 4;                              // word count = payload bytes
            di = {VC[1:0], cfg_dt[5:0]};
            pkt[0] = di;
            pkt[1] = wc[7:0];
            pkt[2] = wc[15:8];
            pkt[3] = csi2_ecc({pkt[2], pkt[1], pkt[0]});
            crc = 16'hFFFF;                           // payload CRC-16
            for (c = 4; c < b; c = c + 1) crc = csi2_crc_byte(crc, pkt[c]);
            pkt[b  ] = crc[7:0];
            pkt[b+1] = crc[15:8];
            pkt_len  = b + 2;
        end
    endtask

    // ----- one complete frame --------------------------------------------
    task send_frame;
        input [31:0] fnum;
        integer r;
        begin
            fork
                clk_lane_run;
                begin
                    #(T_CLK_PRE_PS);                 // let the clock reach HS
                    if (cfg_skew) send_skew_cal;
                    build_short(DT_FS, fnum[15:0]);  send_packet;
                    for (r = 0; r < cfg_v; r = r + 1) begin
                        build_line(fnum, r[15:0]);   send_packet;
                    end
                    build_short(DT_FE, fnum[15:0]);  send_packet;
                    #(T_FRAME_GAP_PS);
                    clk_hs_active = 1'b0;             // stop clock lane
                end
            join
        end
    endtask

    // ----- idle all lanes to LP-11 ---------------------------------------
    task idle_all;
        integer k;
        begin
            for (k = 0; k < 5; k = k + 1) set_lp(k, 1'b1, 1'b1);
        end
    endtask

    // ----- main control ---------------------------------------------------
    integer fi;
    initial begin
        busy        = 1'b0;
        frame_done  = 1'b0;
        clk_hs_active = 1'b0;
        idle_all;
        lane_skew[0] = SKEW_L0_PS;
        lane_skew[1] = SKEW_L1_PS;
        lane_skew[2] = SKEW_L2_PS;
        lane_skew[3] = SKEW_L3_PS;
        gp_fcount   = 0;
        gp_load;
    end

    always @(negedge rst_n) begin
        clk_hs_active = 1'b0;
        idle_all;
        busy       = 1'b0;
        frame_done = 1'b0;
    end

    // trigger-gated, retriggerable frame engine
    initial begin : engine
        @(posedge rst_n);
        forever begin
            wait (trigger === 1'b1);
            // sample configuration
            cfg_h     = hsize;
            cfg_v     = vsize;
            cfg_dt    = data_type;
            cfg_pat   = pattern_sel;
            cfg_solid = solid_val;
            cfg_nf    = (num_frames == 0) ? 16'd1 : num_frames;
            cfg_skew  = skew_cal_en;
            cfg_bits  = dt_bits(data_type);
            busy      = 1'b1;
            $display("[tx] %0t START  %0dx%0d  DT=0x%02h (%0d-bit)  pattern=%0d  frames=%0d  skew_cal=%0b",
                     $time, cfg_h, cfg_v, cfg_dt, cfg_bits, cfg_pat, cfg_nf, cfg_skew);
            for (fi = 0; fi < cfg_nf; fi = fi + 1) begin
                send_frame(fi[31:0]);
                frame_done = 1'b1; #(1); frame_done = 1'b0;
                $display("[tx] %0t frame %0d done", $time, fi);
            end
            idle_all;
            busy = 1'b0;
            $display("[tx] %0t ALL FRAMES DONE", $time);
            wait (trigger === 1'b0);                 // arm for next trigger
        end
    end

endmodule
