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
//  Port style mirrors the M31 model (3-bit-per-pad inout buses).  Only the
//  receive direction is implemented (no BTA / escape mode).
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
    parameter integer STRICT_PROTOCOL_FINISH = 1
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

    // derived unit interval (matches the Tx) and generated pixel-clock period
    localparam integer UI_PS      = (LANE_SPEED_MBPS <= 0) ? 400 : (1000000 / LANE_SPEED_MBPS);
    localparam integer PXCLK_HALF = (UI_PS <= 2) ? 1 : (UI_PS / 2); // 1 event per UI

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
                if (dt == DT_FS) begin             // Frame Start
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

    // ---- drain FIFO onto the parallel output -----------------------------
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
        Pxclk = 1'b0; Vsync = 1'b1; Hsync = 1'b1; Stb = 1'b0; VC = 2'h0; Data = 14'h0;
        wptr = 0; rptr = 0; frame_active = 4'h0;
        dbg_frame_no[0] = 0; dbg_frame_no[1] = 0; dbg_frame_no[2] = 0; dbg_frame_no[3] = 0;
        dbg_line_no[0] = 0; dbg_line_no[1] = 0; dbg_line_no[2] = 0; dbg_line_no[3] = 0;
        if (LANE_NUM != 1 && LANE_NUM != 2 && LANE_NUM != 4) begin
            $display("[rx_stub] CONFIG ERROR: LANE_NUM=%0d unsupported; use 1, 2, or 4", LANE_NUM);
            $fatal(1);
        end
        reset_lanes;
    end
    always #(PXCLK_HALF) Pxclk = ~Pxclk;

endmodule
