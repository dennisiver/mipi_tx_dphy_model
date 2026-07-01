//============================================================================
//  mipi_rx_checker.v
//----------------------------------------------------------------------------
//  Compares the parallel video output of the (M31) Rx D-PHY model against the
//  same golden pattern used by the Tx model.
//
//  Rx parallel port (connect through the reserved wires in the testbench so it
//  can be tapped from any signal hierarchy):
//      Pxclk, Vsync, Hsync, Stb, Data[13:0]
//
//  Data is MSB-aligned by format:
//      RAW8/YUV422_8   -> Data[13:6]
//      RAW10/YUV422_10 -> Data[13:4]
//      RAW12           -> Data[13:2]
//      RAW14           -> Data[13:0]
//
//  Assumptions (override the *_ACT parameters to match the real M31 polarity):
//      Vsync active level = frame active
//      Hsync active level = line active
//      Stb active level   = a valid pixel is present on Data this Pxclk
//============================================================================
`timescale 1ps/1ps

module mipi_rx_checker #(
    parameter integer BITS      = 10,      // pixel bit-width (8/10/12/14)
    parameter integer HSIZE     = 64,      // active pixels per line
    parameter integer PATTERN   = 0,       // must match the Tx pattern_sel
    parameter integer SOLID     = 0,       // must match the Tx solid_val
    parameter integer GP_MAX    = 65536,
    parameter         GP_FILE   = "golden_pattern.txt",
    parameter         VSYNC_ACT = 1'b0,    // active level of Vsync
    parameter         HSYNC_ACT = 1'b0,    // active level of Hsync
    parameter         STB_ACT   = 1'b1,    // active level of Stb
    parameter integer DEBUG_SYNC = 0,
    parameter integer VERBOSE   = 0        // 1 = print every mismatch
)(
    input  wire        rst_n,
    input  wire        pxclk,
    input  wire        vsync,
    input  wire        hsync,
    input  wire        stb,
    input  wire [13:0] data,

    output reg  [31:0] error_count,
    output reg  [31:0] pixel_count,
    output reg         checking
);

    reg [13:0] gp_mem [0:GP_MAX-1];
    integer    gp_fcount;

    `ifndef GOLDEN_PIXEL_INC
        `define GOLDEN_PIXEL_INC "golden_pixel.v"
    `endif
    `include `GOLDEN_PIXEL_INC

    reg [31:0] frame;
    reg [31:0] row, col;
    reg [31:0] next_frame, next_row, next_col;
    reg        vs_d, hs_d;
    reg        started;
    reg        next_started, next_checking;
    reg [13:0] exp, got, mask;

    localparam [15:0] CFG_HSIZE = HSIZE[15:0];
    wire vs_edge = (vsync == VSYNC_ACT) && (vs_d != VSYNC_ACT);
    wire hs_edge = (hsync == HSYNC_ACT) && (hs_d != HSYNC_ACT);
    wire frame_active = (vsync == VSYNC_ACT);
    wire line_active  = (hsync == HSYNC_ACT);

    initial begin
        gp_fcount   = 0;
        gp_load;
        error_count = 0;
        pixel_count = 0;
        checking    = 1'b0;
        frame = 0; row = 0; col = 0;
        vs_d = ~VSYNC_ACT; hs_d = ~HSYNC_ACT;
        started = 1'b0;
        mask = gp_mask(BITS);
    end

    always @(posedge pxclk or negedge rst_n) begin
        if (!rst_n) begin
            error_count <= 0;
            pixel_count <= 0;
            checking    <= 1'b0;
            frame       <= 0;
            row         <= 0;
            col         <= 0;
            vs_d        <= ~VSYNC_ACT;
            hs_d        <= ~HSYNC_ACT;
            started     <= 1'b0;
        end else begin
            vs_d <= vsync;
            hs_d <= hsync;

            next_frame    = frame;
            next_row      = row;
            next_col      = col;
            next_started  = started;
            next_checking = checking;

            // Vsync leading edge -> new frame. Each line is represented by
            // Hsync active level; the leading edge advances the row counter.
            if (vs_edge) begin
                if (DEBUG_SYNC)
                    $display("[chk][sync] %0t VS edge next_f=%0d hsync=%0b row=%0d col=%0d",
                             $time, started ? (frame + 1) : 1, hsync, row, col);
                if (started)
                    next_frame = frame + 1;
                else
                    next_frame = 1;
                next_started  = 1'b1;
                next_checking = 1'b1;
                next_row = hs_edge ? 32'h0 : 32'hFFFF_FFFF;
                next_col = 0;
            end
            // Hsync leading edge -> new line
            else if (hs_edge) begin
                if (DEBUG_SYNC)
                    $display("[chk][sync] %0t HS edge f=%0d next_r=%0d vsync=%0b",
                             $time, frame, row + 1, vsync);
                next_row = row + 1;
                next_col = 0;
            end

            // valid pixel -> compare
            if (next_started && frame_active && line_active && (stb == STB_ACT)) begin
                exp = golden_pixel(next_frame, next_row, next_col, CFG_HSIZE, PATTERN, BITS, SOLID);
                got = (BITS >= 14) ? (data & mask) : ((data >> (14 - BITS)) & mask);
                pixel_count <= pixel_count + 1;
                if (got !== exp) begin
                    error_count <= error_count + 1;
                    if (VERBOSE)
                        $display("[chk] %0t MISMATCH f=%0d r=%0d c=%0d exp=0x%04h got=0x%04h",
                                 $time, next_frame, next_row, next_col, exp, got);
                end
                next_col = next_col + 1;
            end

            frame    <= next_frame;
            row      <= next_row;
            col      <= next_col;
            started  <= next_started;
            checking <= next_checking;
        end
    end

    // convenience report task
    task report;
        begin
            $display("[chk] ==== compare summary ====");
            $display("[chk] pixels checked : %0d", pixel_count);
            $display("[chk] mismatches     : %0d", error_count);
            if (error_count == 0 && pixel_count != 0)
                $display("[chk] RESULT : PASS");
            else
                $display("[chk] RESULT : FAIL");
        end
    endtask

endmodule
