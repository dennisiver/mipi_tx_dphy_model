#============================================================================
#  Makefile for the MIPI Tx D-PHY model self-checking testbench
#
#  Usage:
#     make                  # build + run the default RAW10 64x8 ramp test
#     make FMT=12 HS=128 VS=16 PAT=2
#     make YUV=1 FMT=8      # YUV422 8-bit
#     make SPEED=1500       # 1.5 Gbps/lane (D-PHY timing auto-derived)
#     make SKEW=1           # enable per-lane skew injection + deskew calibration
#     make wave             # run and open the VCD in gtkwave
#     make matrix           # run a small regression matrix
#     make clean
#
#  Knobs (passed as -D defines to the testbench):
#     FMT   : 8 | 10 | 12   sample bit-width
#     YUV   : 0 = RAW (8/10/12) , 1 = YUV422 (FMT must be 8 or 10)
#     SPEED : per-lane bit rate in Mbps (<=2500); all timing auto-derived
#     HS    : Hsize (active pixels per line)
#     VS    : Vsize (active lines per frame)
#     PAT   : 0..5 golden pattern (0 ramp,1 hgrad,2 vgrad,3 checker,4 solid,5 file)
#     NF    : number of frames
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
NF    ?= 2
SKEW  ?= 0

DEFS := -D FMT=$(FMT) -D YUV=$(YUV) -D SPEED=$(SPEED) -D HS=$(HS) -D VS=$(VS) \
        -D PAT=$(PAT) -D NF=$(NF) -D SKEW=$(SKEW)
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
	@echo "--- RAW (FMT 8/10/12) x patterns 0..5 ---"; \
	for f in 8 10 12; do \
	  for p in 0 1 2 3 4 5; do \
	    $(IVERILOG) -g2012 -I $(INCDIR) -o $(OUT) -D FMT=$$f -D YUV=0 -D PAT=$$p -D HS=64 -D VS=4 -D NF=1 -D SKEW=0 $(SRCS) 2>/dev/null; \
	    r=`cd $(RUNDIR) && $(VVP) $(CURDIR)/$(OUT) 2>/dev/null | grep RESULT`; \
	    echo "RAW  FMT=$$f PAT=$$p : $$r"; \
	  done; \
	done; \
	echo "--- YUV422 (FMT 8/10) x patterns 0..5 ---"; \
	for f in 8 10; do \
	  for p in 0 1 2 3 4 5; do \
	    $(IVERILOG) -g2012 -I $(INCDIR) -o $(OUT) -D FMT=$$f -D YUV=1 -D PAT=$$p -D HS=64 -D VS=4 -D NF=1 -D SKEW=0 $(SRCS) 2>/dev/null; \
	    r=`cd $(RUNDIR) && $(VVP) $(CURDIR)/$(OUT) 2>/dev/null | grep RESULT`; \
	    echo "YUV  FMT=$$f PAT=$$p : $$r"; \
	  done; \
	done

clean:
	rm -f $(OUT) *.vvp $(RUNDIR)/tb_mipi_tx_dphy.vcd
