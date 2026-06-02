//============================================================================
//  mipi_rx_dphy_stub.v
//----------------------------------------------------------------------------
//  *** ILLUSTRATIVE / SELF-TEST Rx model -- replace with the real M31 model ***
//
//  Decodes the digital HS/LP pad encoding produced by mipi_tx_dphy_model and
//  reproduces a parallel video output (Pxclk, Vsync, Hsync, Stb, Data[11:0])
//  similar to what the M31 MIPI Rx D-PHY model exposes, so that the whole
//  Tx -> link -> checker path can be exercised without the encrypted M31 IP.
//
//  Port style mirrors the M31 model (3-bit-per-pad inout buses).  Only the
//  receive direction is implemented (no BTA / escape mode).
//============================================================================
`timescale 1ps/1ps

module mipi_rx_dphy_stub #(
    parameter integer UI_PS      = 400,
    parameter integer DATA_BITS  = 10,     // 8/10/12 -> RAW8/RAW10/RAW12
    parameter integer PXCLK_HALF = 300,    // half period of generated Pxclk
    parameter integer MAXQ       = 16384,  // output FIFO depth (>= one line)
    parameter integer MAXBPL     = 8192    // max bytes per lane per burst
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
    output reg [11:0] Data
);

    // ---- recovered clock / per-lane HS view ------------------------------
    wire clk_hs  = PAD_CDRX_L4P[1];
    wire clk_val = PAD_CDRX_L4P[0];

    wire [3:0] lane_val = {PAD_CDRX_L3P[0], PAD_CDRX_L2P[0],
                           PAD_CDRX_L1P[0], PAD_CDRX_L0P[0]};
    wire [3:0] lane_bit = {PAD_CDRX_L3P[1], PAD_CDRX_L2P[1],
                           PAD_CDRX_L1P[1], PAD_CDRX_L0P[1]};
    wire       any_val  = |lane_val;

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
            for (L = 0; L < 4; L = L + 1) begin
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
    // entry = {Vsync, Hsync, Stb, Data[11:0]}
    reg [14:0] q_mem [0:MAXQ-1];
    integer    wptr, rptr;

    task push_evt;
        input v; input h; input s; input [11:0] d;
        begin
            q_mem[wptr % MAXQ] = {v, h, s, d};
            wptr = wptr + 1;
        end
    endtask

    // merged-stream byte accessor : byte k came from lane (k%4), index (k/4)
    function [7:0] mbyte;
        input integer k;
        begin
            mbyte = lane_byte[k % 4][k / 4];
        end
    endfunction

    // ---- parse one received burst into output events ---------------------
    task parse_burst;
        integer total, wc, g, base, np;
        reg [7:0]  di, b0, b1, b2, b3, lsb;
        reg [5:0]  dt;
        begin
            total = lane_nb[0] + lane_nb[1] + lane_nb[2] + lane_nb[3];
            if (total < 1) ;                       // empty burst, ignore
            else begin
                di = mbyte(0);
                dt = di[5:0];
                if (dt == 6'h00) begin             // Frame Start
                    push_evt(1'b1, 1'b0, 1'b0, 12'h0);
                end else if (dt == 6'h01) begin    // Frame End
                    // no event
                end else if (total >= 6) begin     // long packet (image line)
                    wc = {mbyte(2), mbyte(1)};
                    push_evt(1'b0, 1'b1, 1'b0, 12'h0);     // Hsync
                    if (DATA_BITS == 8) begin
                        for (g = 0; g < wc; g = g + 1)
                            push_evt(1'b0, 1'b0, 1'b1, {4'h0, mbyte(4+g)});
                    end else if (DATA_BITS == 10) begin
                        np = wc / 5;
                        for (g = 0; g < np; g = g + 1) begin
                            base = 4 + g*5;
                            b0 = mbyte(base); b1 = mbyte(base+1);
                            b2 = mbyte(base+2); b3 = mbyte(base+3);
                            lsb = mbyte(base+4);
                            push_evt(1'b0,1'b0,1'b1, {2'h0, b0, lsb[1:0]});
                            push_evt(1'b0,1'b0,1'b1, {2'h0, b1, lsb[3:2]});
                            push_evt(1'b0,1'b0,1'b1, {2'h0, b2, lsb[5:4]});
                            push_evt(1'b0,1'b0,1'b1, {2'h0, b3, lsb[7:6]});
                        end
                    end else begin // 12-bit
                        np = wc / 3;
                        for (g = 0; g < np; g = g + 1) begin
                            base = 4 + g*3;
                            b0 = mbyte(base); b1 = mbyte(base+1); b2 = mbyte(base+2);
                            push_evt(1'b0,1'b0,1'b1, {b0, b2[3:0]});
                            push_evt(1'b0,1'b0,1'b1, {b1, b2[7:4]});
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
            Data  <= 12'h0;
        end
    end

    // ---- init / free-running pixel clock ---------------------------------
    initial begin
        Pxclk = 1'b0; Vsync = 1'b0; Hsync = 1'b0; Stb = 1'b0; Data = 12'h0;
        wptr = 0; rptr = 0;
        reset_lanes;
    end
    always #(PXCLK_HALF) Pxclk = ~Pxclk;

endmodule
