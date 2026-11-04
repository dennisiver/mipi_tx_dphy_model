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
    parameter integer VSIZE     = 8,       // active lines per frame
    parameter integer YUV       = 0,       // 0 = RAW, 1 = YUV422 (Cb,Y0,Cr,Y1)
    parameter integer COMPARE_EN = 1,      // 0 = PPM dump only, no golden compare
    parameter integer PATTERN   = 0,       // must match the Tx pattern_sel
    parameter integer SOLID     = 0,       // must match the Tx solid_val
    parameter integer GP_MAX    = 65536,
    parameter         GP_FILE   = "golden_pattern.txt",
    parameter         VSYNC_ACT = 1'b0,    // active level of Vsync
    parameter         HSYNC_ACT = 1'b0,    // active level of Hsync
    parameter         STB_ACT   = 1'b1,    // active level of Stb
    parameter integer DEBUG_SYNC = 0,
    parameter integer VERBOSE   = 0,       // 1 = print every mismatch
    parameter integer PPM_EN    = 0,       // 1 = dump every complete Rx frame as P3 PPM
    parameter integer RAW_EN    = 0,       // 1 = dump raw samples as <prefix>_frame_NNNN.fmt
    parameter         PPM_PREFIX = "rx"
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

    localparam [15:0] CFG_SPL = HSIZE * (YUV ? 2 : 1);   // samples per line
    wire vs_edge = (vsync == VSYNC_ACT) && (vs_d != VSYNC_ACT);
    wire hs_edge = (hsync == HSYNC_ACT) && (hs_d != HSYNC_ACT);
    wire frame_active = (vsync == VSYNC_ACT);
    wire line_active  = (hsync == HSYNC_ACT);

    localparam integer PPM_SAMPLES_PER_FRAME = HSIZE * VSIZE * (YUV ? 2 : 1);
    localparam integer PPM_PIXELS_PER_FRAME  = HSIZE * VSIZE;
    localparam integer RAW_SAMPLES_PER_LINE  = HSIZE * (YUV ? 2 : 1);

    integer ppm_fd;
    integer ppm_frame_no;
    integer ppm_sample_count;
    integer ppm_pixel_count;
    integer ppm_error_count;
    integer ppm_yuv_phase;
    integer ppm_sample;
    integer ppm_cb, ppm_cr, ppm_y0, ppm_y1;
    reg     ppm_active;
    reg [8*256-1:0] ppm_filename;

    integer raw_fd;
    integer raw_frame_no;
    integer raw_count;
    reg     raw_open;
    reg [13:0] raw_val;
    reg [8*256-1:0] raw_filename;

    function integer ppm_clip8;
        input integer value;
        begin
            if (value < 0)
                ppm_clip8 = 0;
            else if (value > 255)
                ppm_clip8 = 255;
            else
                ppm_clip8 = value;
        end
    endfunction

    function integer ppm_raw_to_8;
        input integer value;
        integer max_value;
        begin
            max_value = (1 << BITS) - 1;
            ppm_raw_to_8 = (value * 255 + (max_value / 2)) / max_value;
        end
    endfunction

    function integer ppm_yuv_to_8;
        input integer value;
        begin
            if (BITS > 8)
                ppm_yuv_to_8 = ppm_clip8(value >> (BITS - 8));
            else
                ppm_yuv_to_8 = ppm_clip8(value);
        end
    endfunction

    task ppm_write_yuv_pixel;
        input integer y;
        input integer cb;
        input integer cr;
        integer c, d, e, r, g, b;
        begin
            c = y - 16;
            if (c < 0) c = 0;
            d = cb - 128;
            e = cr - 128;
            r = ppm_clip8((298*c + 409*e + 128) >>> 8);
            g = ppm_clip8((298*c - 100*d - 208*e + 128) >>> 8);
            b = ppm_clip8((298*c + 516*d + 128) >>> 8);
            $fwrite(ppm_fd, "%0d %0d %0d ", r, g, b);
        end
    endtask

    task ppm_close_frame;
        begin
            if (ppm_fd != 0) begin
                $fwrite(ppm_fd, "\n");
                $fclose(ppm_fd);
                ppm_fd = 0;
            end
            ppm_active = 1'b0;
        end
    endtask

    task ppm_fail_incomplete;
        begin
            $display("[ppm] ERROR: incomplete frame %0d: samples=%0d expected=%0d file=%0s",
                     ppm_frame_no, ppm_sample_count,
                     PPM_SAMPLES_PER_FRAME, ppm_filename);
            ppm_error_count = ppm_error_count + 1;
            ppm_close_frame;
        end
    endtask

    initial begin
        gp_fcount   = 0;
        if (COMPARE_EN) gp_load;
        error_count = 0;
        pixel_count = 0;
        checking    = 1'b0;
        frame = 0; row = 0; col = 0;
        vs_d = ~VSYNC_ACT; hs_d = ~HSYNC_ACT;
        started = 1'b0;
        mask = gp_mask(BITS);
        ppm_fd = 0;
        ppm_frame_no = 0;
        ppm_sample_count = 0;
        ppm_pixel_count = 0;
        ppm_error_count = 0;
        ppm_yuv_phase = 0;
        ppm_active = 1'b0;
        raw_fd = 0;
        raw_frame_no = 0;
        raw_count = 0;
        raw_open = 1'b0;
        if (PPM_EN && ((HSIZE <= 0) || (VSIZE <= 0))) begin
            $display("[ppm] CONFIG ERROR: HSIZE and VSIZE must be greater than zero");
            $fatal(1);
        end
        if (PPM_EN && YUV && ((HSIZE % 2) != 0)) begin
            $display("[ppm] CONFIG ERROR: YUV422 requires an even HSIZE (got %0d)", HSIZE);
            $fatal(1);
        end
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
                got = (BITS >= 14) ? (data & mask) : ((data >> (14 - BITS)) & mask);
                pixel_count <= pixel_count + 1;
                if (COMPARE_EN) begin
                    exp = golden_pixel(next_frame, next_row, next_col, CFG_SPL, PATTERN, BITS, SOLID);
                    if (got !== exp) begin
                        error_count <= error_count + 1;
                        if (VERBOSE)
                            $display("[chk] %0t MISMATCH f=%0d r=%0d c=%0d exp=0x%04h got=0x%04h",
                                     $time, next_frame, next_row, next_col, exp, got);
                    end
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

    // PPM capture intentionally uses only Vsync and Stb. Hsync is not used,
    // so a pipeline delay between sync generation and Rx PAD data cannot
    // shift the dumped image horizontally.
    always @(posedge pxclk or negedge rst_n) begin
        if (!rst_n) begin
            if (ppm_fd != 0)
                ppm_close_frame;
            ppm_frame_no = 0;
            ppm_sample_count = 0;
            ppm_pixel_count = 0;
            ppm_error_count = 0;
            ppm_yuv_phase = 0;
            ppm_active = 1'b0;
        end else if (PPM_EN) begin
            if (vs_edge) begin
                if (ppm_active)
                    ppm_fail_incomplete;

                ppm_frame_no = ppm_frame_no + 1;
                ppm_sample_count = 0;
                ppm_pixel_count = 0;
                ppm_yuv_phase = 0;
                $sformat(ppm_filename, "%0s_frame_%04d.ppm", PPM_PREFIX, ppm_frame_no);
                ppm_fd = $fopen(ppm_filename, "w");
                if (ppm_fd == 0) begin
                    $display("[ppm] ERROR: cannot open %0s", ppm_filename);
                    ppm_error_count = ppm_error_count + 1;
                    ppm_active = 1'b0;
                end else begin
                    $fwrite(ppm_fd, "P3\n%0d %0d\n255\n", HSIZE, VSIZE);
                    ppm_active = 1'b1;
                    $display("[ppm] dumping frame %0d to %0s", ppm_frame_no, ppm_filename);
                end
            end

            if (ppm_active && frame_active && (stb == STB_ACT)) begin
                ppm_sample = (BITS >= 14) ? (data & mask) :
                             ((data >> (14 - BITS)) & mask);
                ppm_sample_count = ppm_sample_count + 1;

                if (!YUV) begin
                    ppm_sample = ppm_raw_to_8(ppm_sample);
                    $fwrite(ppm_fd, "%0d %0d %0d ", ppm_sample, ppm_sample, ppm_sample);
                    ppm_pixel_count = ppm_pixel_count + 1;
                    if ((ppm_pixel_count % HSIZE) == 0)
                        $fwrite(ppm_fd, "\n");
                end else begin
                    case (ppm_yuv_phase)
                        0: begin ppm_cb = ppm_yuv_to_8(ppm_sample); ppm_yuv_phase = 1; end
                        1: begin ppm_y0 = ppm_yuv_to_8(ppm_sample); ppm_yuv_phase = 2; end
                        2: begin ppm_cr = ppm_yuv_to_8(ppm_sample); ppm_yuv_phase = 3; end
                        default: begin
                            ppm_y1 = ppm_yuv_to_8(ppm_sample);
                            ppm_write_yuv_pixel(ppm_y0, ppm_cb, ppm_cr);
                            ppm_write_yuv_pixel(ppm_y1, ppm_cb, ppm_cr);
                            ppm_pixel_count = ppm_pixel_count + 2;
                            ppm_yuv_phase = 0;
                            if ((ppm_pixel_count % HSIZE) == 0)
                                $fwrite(ppm_fd, "\n");
                        end
                    endcase
                end

                if (ppm_sample_count == PPM_SAMPLES_PER_FRAME) begin
                    if (ppm_pixel_count != PPM_PIXELS_PER_FRAME) begin
                        $display("[ppm] ERROR: frame %0d pixels=%0d expected=%0d",
                                 ppm_frame_no, ppm_pixel_count, PPM_PIXELS_PER_FRAME);
                        ppm_error_count = ppm_error_count + 1;
                    end else begin
                        $display("[ppm] completed frame %0d: %0s", ppm_frame_no, ppm_filename);
                    end
                    ppm_close_frame;
                end
            end
        end
    end

    //------------------------------------------------------------------
    //  Raw sample dump  (RAW_EN=1)
    //------------------------------------------------------------------
    //  Writes the received samples with no conversion at all -- no 8-bit
    //  rescale, no YUV->RGB, no clipping.  Use this when you need the
    //  actual values; the PPM path is for eyeballing only and loses the
    //  low bits (RAW) or is lossy through the colour matrix (YUV).
    //
    //  <PPM_PREFIX>_frame_0001.fmt : one hex sample per column, space
    //  separated, newline every HSIZE*(YUV?2:1) samples.  Same shape as
    //  Sensor_input_*.fmt, so fmt_view.py / fmt_to_golden.py read it.
    //
    //  The data bus is MSB-aligned, so the sample is extracted the same
    //  way the compare and PPM paths do it:  data >> (14 - BITS), masked
    //  to BITS.  What is NOT applied is any value conversion -- no 8-bit
    //  rescale, no colour matrix, no clipping -- so the number written is
    //  the sample as received, at full BITS precision.
    //
    //  Independent of PPM_EN: either, both, or neither may be enabled.
    //  Like the PPM path this uses only Vsync and Stb, never Hsync.
    //------------------------------------------------------------------
    always @(posedge pxclk or negedge rst_n) begin
        if (!rst_n) begin
            if (raw_fd != 0)
                $fclose(raw_fd);
            raw_fd       = 0;
            raw_frame_no = 0;
            raw_count    = 0;
            raw_open     = 1'b0;
        end else if (RAW_EN) begin
            if (vs_edge) begin
                if (raw_fd != 0) begin          // previous frame was short
                    $display("[raw] WARNING: frame %0d ended early: %0d of %0d samples",
                             raw_frame_no, raw_count, PPM_SAMPLES_PER_FRAME);
                    $fwrite(raw_fd, "\n");
                    $fclose(raw_fd);
                    raw_fd = 0;
                end
                raw_frame_no = raw_frame_no + 1;
                raw_count    = 0;
                $sformat(raw_filename, "%0s_frame_%04d.fmt", PPM_PREFIX, raw_frame_no);
                raw_fd = $fopen(raw_filename, "w");
                if (raw_fd == 0) begin
                    $display("[raw] ERROR: cannot open %0s", raw_filename);
                    raw_open = 1'b0;
                end else begin
                    raw_open = 1'b1;
                    $display("[raw] dumping frame %0d to %0s", raw_frame_no, raw_filename);
                end
            end

            if (raw_open && frame_active && (stb == STB_ACT)) begin
                raw_val = (BITS >= 14) ? (data & mask)
                                       : ((data >> (14 - BITS)) & mask);
                $fwrite(raw_fd, "%h", raw_val);
                raw_count = raw_count + 1;
                if ((raw_count % RAW_SAMPLES_PER_LINE) == 0)
                    $fwrite(raw_fd, "\n");
                else
                    $fwrite(raw_fd, " ");

                if (raw_count == PPM_SAMPLES_PER_FRAME) begin
                    $fclose(raw_fd);
                    raw_fd   = 0;
                    raw_open = 1'b0;
                    $display("[raw] completed frame %0d: %0d samples (%0d per line) -> %0s",
                             raw_frame_no, raw_count, RAW_SAMPLES_PER_LINE, raw_filename);
                end
            end
        end
    end

    // convenience report task
    task report;
        begin
            if (PPM_EN && ppm_active)
                ppm_fail_incomplete;
            $display("[chk] ==== compare summary ====");
            $display("[chk] pixels checked : %0d", pixel_count);
            $display("[chk] mismatches     : %0d", error_count);
            if (PPM_EN)
                $display("[chk] PPM errors     : %0d", ppm_error_count);
            if (error_count == 0 && pixel_count != 0 &&
                (!PPM_EN || ppm_error_count == 0))
                $display("[chk] RESULT : PASS");
            else
                $display("[chk] RESULT : FAIL");
        end
    endtask

endmodule
