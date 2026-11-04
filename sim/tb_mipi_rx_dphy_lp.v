//============================================================================
//  Focused D-PHY LPDT / BTA / ULPS test for mipi_rx_dphy_stub
//============================================================================
`timescale 1ps/1ps

module tb_mipi_rx_dphy_lp;
    localparam integer PHASE_PS = 100;
    localparam integer WAKEUP_PS = 500;

    tri [2:0] L0P, L0N, L1P, L1N, L2P, L2N, L3P, L3N, L4P, L4N;
    reg master_en, master_dp, master_dn;
    reg clock_en, clock_dp, clock_dn;

    assign L0P = master_en ? {master_dp, 2'b00} : 3'bzzz;
    assign L0N = master_en ? {master_dn, 2'b00} : 3'bzzz;
    assign L1P = 3'b100; assign L1N = 3'b100;
    assign L2P = 3'b100; assign L2N = 3'b100;
    assign L3P = 3'b100; assign L3N = 3'b100;
    assign L4P = clock_en ? {clock_dp, 2'b00} : 3'bzzz;
    assign L4N = clock_en ? {clock_dn, 2'b00} : 3'bzzz;

    wire pxclk, vsync, hsync, stb;
    wire [1:0] vc;
    wire [13:0] data;

    mipi_rx_dphy_stub #(
        .LANE_NUM(1),
        .MAXQ(64),
        .MAXBPL(64),
        .LP_PROTOCOL(0),
        .LP_DATA_FILE("mipi_lp_data_test.txt"),
        .LP_PHASE_PS(PHASE_PS),
        .T_TA_GO_PS(2*PHASE_PS),
        .T_TA_SURE_PS(2*PHASE_PS),
        .BTA_AUTO_RETURN(1),
        .BTA_HOLD_PS(2*PHASE_PS),
        .T_WAKEUP_PS(WAKEUP_PS),
        .STRICT_ULPS_WAKEUP(1)
    ) U_DUT (
        .PAD_CDRX_L0P(L0P), .PAD_CDRX_L0N(L0N),
        .PAD_CDRX_L1P(L1P), .PAD_CDRX_L1N(L1N),
        .PAD_CDRX_L2P(L2P), .PAD_CDRX_L2N(L2N),
        .PAD_CDRX_L3P(L3P), .PAD_CDRX_L3N(L3N),
        .PAD_CDRX_L4P(L4P), .PAD_CDRX_L4N(L4N),
        .Pxclk(pxclk), .Vsync(vsync), .Hsync(hsync),
        .Stb(stb), .VC(vc), .Data(data)
    );

    task drive_lp;
        input dp;
        input dn;
        begin
            master_dp = dp; master_dn = dn; master_en = 1'b1;
            #(PHASE_PS);
        end
    endtask

    task drive_clock_lp;
        input dp;
        input dn;
        begin
            clock_dp = dp; clock_dn = dn; clock_en = 1'b1;
            #(PHASE_PS);
        end
    endtask

    task escape_entry;
        begin
            drive_lp(1,1); drive_lp(1,0); drive_lp(0,0);
            drive_lp(0,1); drive_lp(0,0);
        end
    endtask

    task send_lp_bit;
        input value;
        begin
            if (value) drive_lp(1,0); else drive_lp(0,1);
            drive_lp(0,0);
        end
    endtask

    task send_lp_byte;
        input [7:0] value;
        integer b;
        begin
            for (b = 0; b < 8; b = b + 1)
                send_lp_bit(value[b]);
        end
    endtask

    task escape_exit;
        begin
            drive_lp(1,0);
            drive_lp(1,1);
        end
    endtask

    task send_lpdt_packet;
        input [7:0] b0;
        input [7:0] b1;
        input [7:0] b2;
        input [7:0] b3;
        begin
            escape_entry;
            send_lp_byte(8'h87); // on-wire command pattern 11100001
            send_lp_byte(b0); send_lp_byte(b1);
            send_lp_byte(b2); send_lp_byte(b3);
            escape_exit;
        end
    endtask

    initial begin
        master_en = 1'b1; master_dp = 1'b1; master_dn = 1'b1;
        clock_en = 1'b1; clock_dp = 1'b1; clock_dn = 1'b1;
        #(4*PHASE_PS);

        // DSI DCS Short Write: Exit Sleep Mode.
        send_lpdt_packet(8'h05, 8'h11, 8'h00, 8'h00);

        // CSI-2 RAW8 packet header (AUTO mode prints both protocol views).
        send_lpdt_packet(8'h2A, 8'h00, 8'h00, 8'h00);

        // Forward BTA request.  Release the master and require the stub to
        // acquire reverse direction, return to Stop, then turn the bus back.
        drive_lp(1,1); drive_lp(1,0); drive_lp(0,0);
        drive_lp(1,0); drive_lp(0,0);
        master_en = 1'b0;
        wait (U_DUT.lp0_tx_en === 1'b1);
        wait ({L0P[2],L0N[2]} === 2'b11);
        wait (U_DUT.lp0_tx_en === 1'b0);
        drive_lp(0,0); drive_lp(1,0); drive_lp(1,1);

        // Data-lane ULPS entry and compliant Mark-1 wake-up.
        escape_entry;
        send_lp_byte(8'h78); // on-wire command pattern 00011110
        #(WAKEUP_PS);
        drive_lp(1,0);
        #(WAKEUP_PS-PHASE_PS);
        drive_lp(1,1);

        // Clock-lane ULPS entry and wake-up.
        drive_clock_lp(1,1); drive_clock_lp(1,0); drive_clock_lp(0,0);
        #(WAKEUP_PS);
        drive_clock_lp(1,0);
        #(WAKEUP_PS-PHASE_PS);
        drive_clock_lp(1,1);

        if (U_DUT.lp_total_bytes != 8) begin
            $display("[tb_lp] ERROR: received %0d LPDT bytes, expected 8", U_DUT.lp_total_bytes);
            $fatal(1);
        end
        if (U_DUT.lp_transaction != 2 || U_DUT.lpdt_active ||
            U_DUT.data_ulps_active || U_DUT.bta_busy) begin
            $display("[tb_lp] ERROR: final LP state is incorrect");
            $fatal(1);
        end
        if (U_DUT.clk_ulps_state != 0) begin
            $display("[tb_lp] ERROR: clock lane did not leave ULPS");
            $fatal(1);
        end
        $display("[tb_lp] RESULT : PASS");
        $finish;
    end

    initial begin
        #100000;
        $display("[tb_lp] WATCHDOG timeout");
        $fatal(1);
    end
endmodule
