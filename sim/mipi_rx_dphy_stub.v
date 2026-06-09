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
//
//  Port style mirrors the M31 model (3-bit-per-pad inout buses).  Only the
//  receive direction is implemented (no BTA / escape mode).
//============================================================================
`timescale 1ps/1ps

module mipi_rx_dphy_stub #(
    parameter integer LANE_SPEED_MBPS = 2500, // must match the Tx lane speed
    parameter integer LANE_NUM   = 4,      // active data lanes: 1, 2, or 4
    parameter integer DATA_BITS  = 10,     // 8/10/12/14 -> RAW8/RAW10/RAW12/RAW14
    parameter integer MAXQ       = 16384,  // output FIFO depth (>= one line)
    parameter integer MAXBPL     = 24576   // max bytes per lane per burst
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
    output reg [13:0] Data
);

    // derived unit interval (matches the Tx) and generated pixel-clock period
    localparam integer UI_PS      = (LANE_SPEED_MBPS <= 0) ? 400 : (1000000 / LANE_SPEED_MBPS);
    localparam integer PXCLK_HALF = UI_PS;        // 1 pixel every 2 UI (drains fast)

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

    integer i;

    task reset_lanes;
        integer L;
        begin
            for (L = 0; L < 4; L = L + 1) begin
                lane_sr[L]   = 8'h00;
                lane_sync[L] = 1'b0;
                lane_bcnt[L] = 0;
                lane_nb[L]   = 0;
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
                    lane_sr[L] = sr;
                    if (!lane_sync[L]) begin
                        if (sr == 8'hB8) begin              // sync byte found
                            lane_sync[L] = 1'b1;
                            lane_bcnt[L] = 0;
                        end
                    end else begin
                        lane_bcnt[L] = lane_bcnt[L] + 1;
                        if (lane_bcnt[L] == 8) begin
                            if (lane_nb[L] < MAXBPL) lane_byte[L][lane_nb[L]] = sr;
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
            #(UI_PS/2);          // sample at centre of the bit period
            collect_bits;
        end
    end

    always @(posedge any_val) reset_lanes;

    // ---- output event FIFO (single writer / single reader) ---------------
    // entry = {Vsync, Hsync, Stb, Data[13:0]}
    reg [16:0] q_mem [0:MAXQ-1];
    integer    wptr, rptr;

    task push_evt;
        input v; input h; input s; input [13:0] d;
        begin
            if ((wptr - rptr) >= MAXQ) begin
                $display("[rx_stub] ERROR: output FIFO overflow (MAXQ=%0d)", MAXQ);
                $fatal(1);
            end
            q_mem[wptr % MAXQ] = {v, h, s, d};
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

    // ---- parse one received burst into output events ---------------------
    task parse_burst;
        integer total, wc, g, base, np;
        reg [7:0]  di, b0, b1, b2, b3, b4, b5, b6, lsb;
        reg [5:0]  dt;
        begin
            total = 0;
            for (g = 0; g < LANE_NUM; g = g + 1) total = total + lane_nb[g];
            if (total < 1) ;                       // empty burst, ignore
            else begin
                di = mbyte(0);
                dt = di[5:0];
                if (dt == 6'h00) begin             // Frame Start
                    push_evt(1'b1, 1'b0, 1'b0, 14'h0);
                end else if (dt == 6'h01) begin    // Frame End
                    // no event
                end else if (total >= 6) begin     // long packet (image line)
                    wc = {mbyte(2), mbyte(1)};
                    push_evt(1'b0, 1'b1, 1'b0, 14'h0);     // Hsync
                    if (DATA_BITS == 8) begin
                        for (g = 0; g < wc; g = g + 1)
                            push_evt(1'b0, 1'b0, 1'b1, {mbyte(4+g), 6'h0});
                    end else if (DATA_BITS == 10) begin
                        np = wc / 5;
                        for (g = 0; g < np; g = g + 1) begin
                            base = 4 + g*5;
                            b0 = mbyte(base); b1 = mbyte(base+1);
                            b2 = mbyte(base+2); b3 = mbyte(base+3);
                            lsb = mbyte(base+4);
                            push_evt(1'b0,1'b0,1'b1, {lsb[1:0], b0, 4'h0});
                            push_evt(1'b0,1'b0,1'b1, {lsb[3:2], b1, 4'h0});
                            push_evt(1'b0,1'b0,1'b1, {lsb[5:4], b2, 4'h0});
                            push_evt(1'b0,1'b0,1'b1, {lsb[7:6], b3, 4'h0});
                        end
                    end else if (DATA_BITS == 12) begin
                        np = wc / 3;
                        for (g = 0; g < np; g = g + 1) begin
                            base = 4 + g*3;
                            b0 = mbyte(base); b1 = mbyte(base+1); b2 = mbyte(base+2);
                            push_evt(1'b0,1'b0,1'b1, {b2[3:0], b0, 2'h0});
                            push_evt(1'b0,1'b0,1'b1, {b2[7:4], b1, 2'h0});
                        end
                    end else begin // 14-bit
                        np = wc / 7;
                        for (g = 0; g < np; g = g + 1) begin
                            base = 4 + g*7;
                            b0 = mbyte(base); b1 = mbyte(base+1);
                            b2 = mbyte(base+2); b3 = mbyte(base+3);
                            b4 = mbyte(base+4); b5 = mbyte(base+5); b6 = mbyte(base+6);
                            push_evt(1'b0,1'b0,1'b1, {b4[5:0], b0});
                            push_evt(1'b0,1'b0,1'b1, {b5[3:0], b4[7:6], b1});
                            push_evt(1'b0,1'b0,1'b1, {b6[1:0], b5[7:4], b2});
                            push_evt(1'b0,1'b0,1'b1, {b6[7:2], b3});
                        end
                    end
                end
            end
        end
    endtask

    always @(negedge any_val) parse_burst;

    // ---- drain FIFO onto the parallel output -----------------------------
    always @(negedge Pxclk) begin
        if (rptr != wptr) begin
            {Vsync, Hsync, Stb, Data} <= q_mem[rptr % MAXQ];
            rptr <= rptr + 1;
        end else begin
            Vsync <= 1'b0;
            Hsync <= 1'b0;
            Stb   <= 1'b0;
            Data  <= 14'h0;
        end
    end

    // ---- init / free-running pixel clock ---------------------------------
    initial begin
        Pxclk = 1'b0; Vsync = 1'b0; Hsync = 1'b0; Stb = 1'b0; Data = 14'h0;
        wptr = 0; rptr = 0;
        if (LANE_NUM != 1 && LANE_NUM != 2 && LANE_NUM != 4) begin
            $display("[rx_stub] CONFIG ERROR: LANE_NUM=%0d unsupported; use 1, 2, or 4", LANE_NUM);
            $fatal(1);
        end
        reset_lanes;
    end
    always #(PXCLK_HALF) Pxclk = ~Pxclk;

endmodule
