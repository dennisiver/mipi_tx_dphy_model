//============================================================================
//  mipi_csi2_func.vh
//----------------------------------------------------------------------------
//  MIPI CSI-2 packet helper functions : ECC (packet header) and CRC-16
//  (long-packet payload).  `included inside a module body.
//============================================================================

// ---------------------------------------------------------------------------
//  csi2_ecc : 6-bit Hamming ECC over the 24-bit packet header.
//             d[7:0]   = byte0 (Data Identifier)
//             d[15:8]  = byte1 (Word Count LSB)
//             d[23:16] = byte2 (Word Count MSB)
//             Result is returned in bits [5:0]; [7:6] are always 0.
// ---------------------------------------------------------------------------
function [7:0] csi2_ecc;
    input [23:0] d;
    reg [5:0] p;
    begin
        p[0] = d[0]^d[1]^d[2]^d[4]^d[5]^d[7]^d[10]^d[11]^d[13]^d[16]^d[20]^d[21]^d[22]^d[23];
        p[1] = d[0]^d[1]^d[3]^d[4]^d[6]^d[8]^d[10]^d[12]^d[14]^d[17]^d[20]^d[21]^d[22]^d[23];
        p[2] = d[0]^d[2]^d[3]^d[5]^d[6]^d[9]^d[11]^d[12]^d[15]^d[18]^d[20]^d[21]^d[22];
        p[3] = d[1]^d[2]^d[3]^d[7]^d[8]^d[9]^d[13]^d[14]^d[15]^d[19]^d[20]^d[21]^d[23];
        p[4] = d[4]^d[5]^d[6]^d[7]^d[8]^d[9]^d[16]^d[17]^d[18]^d[19]^d[20]^d[22]^d[23];
        p[5] = d[10]^d[11]^d[12]^d[13]^d[14]^d[15]^d[16]^d[17]^d[18]^d[19]^d[21]^d[22]^d[23];
        csi2_ecc = {2'b00, p};
    end
endfunction

// ---------------------------------------------------------------------------
//  csi2_crc_byte : incremental CSI-2 CRC-16.
//             Polynomial x^16+x^12+x^5+1 processed LSB-first
//             (reflected form 0x8408), initial value 0xFFFF.
//             Feed every payload byte in transmit order; transmit the final
//             value low-byte first.
// ---------------------------------------------------------------------------
function [15:0] csi2_crc_byte;
    input [15:0] crc;
    input [7:0]  data;
    integer i;
    reg [15:0] c;
    reg        fb;
    begin
        c = crc;
        for (i = 0; i < 8; i = i + 1) begin
            fb = c[0] ^ data[i];
            c  = c >> 1;
            if (fb) c = c ^ 16'h8408;
        end
        csi2_crc_byte = c;
    end
endfunction
