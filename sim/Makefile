#============================================================================
#  Makefile for the MIPI Tx D-PHY model self-checking testbench
#
#  Usage:
#     make                  # build + run the default RAW10 64x8 ramp test
#     make FMT=14 HS=128 VS=16 PAT=2
#     make YUV=1 FMT=8      # YUV422 8-bit
#     make PAT=5 GP_FILE=patterns/my_golden_pattern.txt
#     make LANE_NUM=2      # active data lanes: 1, 2, or 4
#     make SPEED=1500       # 1.5 Gbps/lane (D-PHY timing auto-derived)
#     make VBLANK=1000      # add 1000 ns after FE before next FS
#     make PACKET_INTERVAL=2000  # set the gap between CSI-2 packets in ns
#     make SKEW=1           # enable per-lane skew injection + deskew calibration
#     make wave             # run and open the VCD in gtkwave
#     make matrix           # run a small regression matrix
#     make clean
#
#  Knobs (passed as -D defines to the testbench):
#     FMT   : 8 | 10 | 12 | 14   sample bit-width
#     YUV   : 0 = RAW (8/10/12/14) , 1 = YUV422 (FMT must be 8 or 10)
#     SPEED : per-lane bit rate in Mbps (<=2500); all timing auto-derived
#     HS    : Hsize (active pixels per line)
#     VS    : Vsize (active lines per frame)
#     PAT   : 0..5 golden pattern (0 ramp,1 hgrad,2 vgrad,3 checker,4 solid,5 file)
#     GP_FILE : file path used when PAT=5
#     LANE_NUM : 1 | 2 | 4 active data lanes
#     NF    : number of frames
#     VBLANK: extra gap after FE before next FS, in ns
#     PACKET_INTERVAL: gap between CSI-2 packets, in ns
#     SKEW  : 0 | 1  enable skew injection + deskew calibration
#============================================================================
IVERILOG ?= iverilog
VVP      ?= vvp
TOP_DIR  := ..
RTL      := $(TOP_DIR)/rtl
INCDIR   := $(RTL)

SRCS := $(RTL)/mipi_tx_dphy_model.v \
        $(RTL)/mipi_rx_checker.v \
        mipi_rx_dphy_stub.v \
        tb_mipi_tx_dphy.v

FMT   ?= 10
YUV   ?= 0
SPEED ?= 2500
HS    ?= 64
VS    ?= 8
PAT   ?= 0
GP_FILE ?= golden_pattern.txt
LANE_NUM ?= 4
NF    ?= 2
PACKET_INTERVAL ?= 2000
VBLANK ?= 10000
SKEW  ?= 0

DEFS := -D FMT=$(FMT) -D YUV=$(YUV) -D SPEED=$(SPEED) -D HS=$(HS) -D VS=$(VS) \
        -D PAT=$(PAT) -D GP_FILE=\"$(GP_FILE)\" -D LANE_NUM=$(LANE_NUM) -D NF=$(NF) \
        -D PACKET_INTERVAL=$(PACKET_INTERVAL) \
        -D VBLANK=$(VBLANK) -D SKEW=$(SKEW)
OUT  := tb.vvp

# Run the model from the repository root so golden_pattern.txt is found.
RUNDIR := $(TOP_DIR)

.PHONY: all run wave matrix clean
all: run

$(OUT): $(SRCS)
	$(IVERILOG) -g2012 -I $(INCDIR) -o $(OUT) $(DEFS) $(SRCS)

run: $(OUT)
	cd $(RUNDIR) && $(VVP) $(CURDIR)/$(OUT)

wave: run
	gtkwave $(RUNDIR)/tb_mipi_tx_dphy.vcd &

matrix:
	@echo "--- RAW (FMT 8/10/12/14) x patterns 0..5 ---"; \
	for f in 8 10 12 14; do \
	  for p in 0 1 2 3 4 5; do \
	    $(IVERILOG) -g2012 -I $(INCDIR) -o $(OUT) -D FMT=$$f -D YUV=0 -D PAT=$$p -D HS=64 -D VS=4 -D LANE_NUM=$(LANE_NUM) -D NF=1 -D SKEW=0 $(SRCS) 2>/dev/null; \
	    r=`cd $(RUNDIR) && $(VVP) $(CURDIR)/$(OUT) 2>/dev/null | grep RESULT`; \
	    echo "RAW  FMT=$$f PAT=$$p : $$r"; \
	  done; \
	done; \
	echo "--- YUV422 (FMT 8/10) x patterns 0..5 ---"; \
	for f in 8 10; do \
	  for p in 0 1 2 3 4 5; do \
	    $(IVERILOG) -g2012 -I $(INCDIR) -o $(OUT) -D FMT=$$f -D YUV=1 -D PAT=$$p -D HS=64 -D VS=4 -D LANE_NUM=$(LANE_NUM) -D NF=1 -D SKEW=0 $(SRCS) 2>/dev/null; \
	    r=`cd $(RUNDIR) && $(VVP) $(CURDIR)/$(OUT) 2>/dev/null | grep RESULT`; \
	    echo "YUV  FMT=$$f PAT=$$p : $$r"; \
	  done; \
	done

clean:
	rm -f $(OUT) *.vvp $(RUNDIR)/tb_mipi_tx_dphy.vcd
