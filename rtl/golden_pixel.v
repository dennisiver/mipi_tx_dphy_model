//============================================================================
//  golden_pixel.v   (include file -- not a standalone module)
//----------------------------------------------------------------------------
//  Shared golden-pattern generator helpers.
//
//  This file is `included inside a module body.  The including module MUST
//  declare the following items *before* the `include directive:
//
//      localparam integer GP_MAX  = <max number of values from file>;
//      localparam         GP_FILE = "<path to golden_pattern.txt>";
//      reg  [11:0] gp_mem [0:GP_MAX-1];   // storage for file pattern
//      integer     gp_fcount;            // number of values actually loaded
//
//  The including module should call task gp_load() once (typically in an
//  initial block) so that the file-based pattern (PATTERN==5) is available.
//
//  Pixel value bit-width is selected automatically from the data format by
//  passing the "bits" argument (8/10/12 for RAW8/RAW10/RAW12).
//============================================================================

// ---------------------------------------------------------------------------
//  gp_load : read golden_pattern.txt (one hexadecimal value per line)
// ---------------------------------------------------------------------------
task gp_load;
    integer fd;
    integer r;
    integer n;
    reg [31:0] v;
    reg [1023:0] dump;
    begin
        gp_fcount = 0;
        fd = $fopen(GP_FILE, "r");
        if (fd == 0) begin
            $display("[golden] NOTE: '%s' not opened - file pattern returns 0", GP_FILE);
        end else begin
            n = 0;
            while (!$feof(fd) && (n < GP_MAX)) begin
                r = $fscanf(fd, "%h", v);          // one hex value per line
                if (r == 1) begin
                    gp_mem[n] = v[11:0];
                    n = n + 1;
                end else begin
                    r = $fgets(dump, fd);          // skip comment / blank line
                end
            end
            gp_fcount = n;
            $fclose(fd);
            $display("[golden] loaded %0d value(s) from '%s'", n, GP_FILE);
        end
    end
endtask

// ---------------------------------------------------------------------------
//  gp_mask : data-format dependent value mask
// ---------------------------------------------------------------------------
function [11:0] gp_mask;
    input integer bits;
    begin
        if (bits >= 12)      gp_mask = 12'hFFF;
        else if (bits <= 0)  gp_mask = 12'h000;
        else                 gp_mask = (1 << bits) - 1;
    end
endfunction

// ---------------------------------------------------------------------------
//  golden_pixel : returns the expected pixel value for (frame,row,col)
//
//  pattern : 0 = sequential / ramp   (running index, wraps with bit width)
//            1 = horizontal gradient (value follows column)
//            2 = vertical   gradient (value follows row)
//            3 = checkerboard        (8x8 blocks, full-scale / 0)
//            4 = solid colour        (constant = solid)
//            5 = from golden_pattern.txt
// ---------------------------------------------------------------------------
function [11:0] golden_pixel;
    input [31:0] frame;
    input [15:0] row;
    input [15:0] col;
    input [15:0] hsize;
    input integer pattern;
    input integer bits;
    input integer solid;
    reg  [11:0] mask;
    reg  [31:0] lin;
    integer     idx;
    begin
        mask = gp_mask(bits);
        case (pattern)
            0: golden_pixel = (row*hsize + col + frame) & mask;
            1: golden_pixel = col & mask;
            2: golden_pixel = row & mask;
            3: golden_pixel = ((((col>>3) + (row>>3)) & 1) != 0) ? mask : 12'h0;
            4: golden_pixel = solid & mask;
            5: begin
                   lin = row*hsize + col;
                   if (gp_fcount > 0) begin
                       idx = lin % gp_fcount;
                       golden_pixel = gp_mem[idx] & mask;
                   end else begin
                       golden_pixel = 12'h0;
                   end
               end
            default: golden_pixel = (row*hsize + col + frame) & mask;
        endcase
    end
endfunction
