//============================================================================
//  mipi_rx_checker.v
//----------------------------------------------------------------------------
//  Compares the parallel video output of the (M31) Rx D-PHY model against the
//  same golden pattern used by the Tx model.
//
//  Rx parallel port (connect through the reserved wires in the testbench so it
//  can be tapped from any signal hierarchy):
//      Pxclk, Vsync, Hsync, Stb, Data[11:0]
//
//  Assumptions (override the *_ACT parameters to match the real M31 polarity):
//      Stb   high  = a valid pixel is present on Data this Pxclk
//      Vsync edge  = start of a new frame   (row/col reset)
//      Hsync edge  = start of a new line    (col reset, row++)
//============================================================================
`timescale 1ps/1ps

module mipi_rx_checker #(
    parameter integer BITS      = 10,      // pixel bit-width (8/10/12)
    parameter integer PATTERN   = 0,       // must match the Tx pattern_sel
    parameter integer SOLID     = 0,       // must match the Tx solid_val
    parameter integer GP_MAX    = 65536,
    parameter         GP_FILE   = "golden_pattern.txt",
    parameter         VSYNC_ACT = 1'b1,    // active level of Vsync
    parameter         HSYNC_ACT = 1'b1,    // active level of Hsync
    parameter         STB_ACT   = 1'b1,    // active level of Stb
    parameter integer VERBOSE   = 0        // 1 = print every mismatch
)(
    input  wire        rst_n,
    input  wire        pxclk,
    input  wire        vsync,
    input  wire        hsync,
    input  wire        stb,
    input  wire [11:0] data,
    input  wire [15:0] hsize,

    output reg  [31:0] error_count,
    output reg  [31:0] pixel_count,
    output reg         checking
);

    reg [11:0] gp_mem [0:GP_MAX-1];
    integer    gp_fcount;

    `include "golden_pixel.vh"

    reg [31:0] frame;
    reg [15:0] row, col;
    reg        vs_d, hs_d;
    reg        started;
    reg [11:0] exp, got, mask;

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

            // Vsync leading edge -> new frame.  Each line (including the
            // first) is preceded by an Hsync, so seed row to -1 here.
            if ((vsync == VSYNC_ACT) && (vs_d != VSYNC_ACT)) begin
                if (started) frame <= frame + 1;
                started  <= 1'b1;
                checking <= 1'b1;
                row <= 16'hFFFF;
                col <= 0;
            end
            // Hsync leading edge -> new line
            else if ((hsync == HSYNC_ACT) && (hs_d != HSYNC_ACT)) begin
                row <= row + 1;
                col <= 0;
            end

            // valid pixel -> compare
            if (started && (stb == STB_ACT)) begin
                exp = golden_pixel(frame, row, col, hsize, PATTERN, BITS, SOLID);
                got = data & mask;
                pixel_count <= pixel_count + 1;
                if (got !== exp) begin
                    error_count <= error_count + 1;
                    if (VERBOSE)
                        $display("[chk] %0t MISMATCH f=%0d r=%0d c=%0d exp=0x%03h got=0x%03h",
                                 $time, frame, row, col, exp, got);
                end
                col <= col + 1;
            end
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
