// DMA Engine module for GPU Command Processor
// Supports mem2mem and mem2dev transfers with AXI4 master interface, burst capable
// Ring buffer aware, large command/job buffers, power mgmt hooks

`timescale 1ns/1ps

module dma_engine #(
  parameter ADDR_WIDTH = 64,
  parameter DATA_WIDTH = 256,
  parameter ID_WIDTH   = 6,
  parameter LEN_WIDTH  = 8,
  parameter BURST_MAX_BEATS = 16
)(
  input  logic                 clk,
  input  logic                 rst_n,

  // Control/CSR interface (simple CSR bus; to be bridged from host/AXI-Lite)
  input  logic                 csr_we,
  input  logic                 csr_re,
  input  logic [15:0]          csr_addr,
  input  logic [31:0]          csr_wdata,
  output logic [31:0]          csr_rdata,
  output logic                 csr_rvalid,

  // Power management hooks
  input  logic                 pwr_gate,
  input  logic                 clock_enable,
  output logic                 dma_idle,

  // Descriptor/ring interface from Command Processor
  input  logic                 desc_valid,
  output logic                 desc_ready,
  input  logic [ADDR_WIDTH-1:0]src_addr,
  input  logic [ADDR_WIDTH-1:0]dst_addr,
  input  logic [31:0]          bytes,
  input  logic [1:0]           xfer_type, // 0: mem2mem, 1: mem2dev, 2: dev2mem
  input  logic [3:0]           src_dev,   // device port id (for dev transfers)
  input  logic [3:0]           dst_dev,
  input  logic [3:0]           src_axi_prot,
  input  logic [3:0]           dst_axi_prot,

  output logic                 xfer_done,
  output logic                 xfer_error,

  // AXI4 master for memory reads
  output logic [ID_WIDTH-1:0]  m_axi_arid,
  output logic [ADDR_WIDTH-1:0]m_axi_araddr,
  output logic [LEN_WIDTH-1:0] m_axi_arlen,
  output logic [2:0]           m_axi_arsize,
  output logic [1:0]           m_axi_arburst,
  output logic                 m_axi_arvalid,
  input  logic                 m_axi_arready,
  input  logic [ID_WIDTH-1:0]  m_axi_rid,
  input  logic [DATA_WIDTH-1:0]m_axi_rdata,
  input  logic [1:0]           m_axi_rresp,
  input  logic                 m_axi_rlast,
  input  logic                 m_axi_rvalid,
  output logic                 m_axi_rready,

  // AXI4 master for memory writes
  output logic [ID_WIDTH-1:0]  m_axi_awid,
  output logic [ADDR_WIDTH-1:0]m_axi_awaddr,
  output logic [LEN_WIDTH-1:0] m_axi_awlen,
  output logic [2:0]           m_axi_awsize,
  output logic [1:0]           m_axi_awburst,
  output logic                 m_axi_awvalid,
  input  logic                 m_axi_awready,
  output logic [DATA_WIDTH-1:0]m_axi_wdata,
  output logic [(DATA_WIDTH/8)-1:0] m_axi_wstrb,
  output logic                 m_axi_wlast,
  output logic                 m_axi_wvalid,
  input  logic                 m_axi_wready,
  input  logic [ID_WIDTH-1:0]  m_axi_bid,
  input  logic [1:0]           m_axi_bresp,
  input  logic                 m_axi_bvalid,
  output logic                 m_axi_bready,

  // Simple device-side streaming interfaces (optional hookup by top)
  output logic                 dev_tx_valid,
  input  logic                 dev_tx_ready,
  output logic [DATA_WIDTH-1:0]dev_tx_data,
  output logic                 dev_tx_last,
  input  logic                 dev_rx_valid,
  output logic                 dev_rx_ready,
  input  logic [DATA_WIDTH-1:0]dev_rx_data,
  input  logic                 dev_rx_last
);

  // Internal regs
  typedef enum logic [2:0] {IDLE, READ, WRITE, STREAM_OUT, STREAM_IN, COMPLETE, ERROR} state_e;
  state_e state, nstate;

  logic [ADDR_WIDTH-1:0] rd_addr, wr_addr;
  logic [31:0]           bytes_left;
  logic [LEN_WIDTH-1:0]  burst_beats;
  logic [DATA_WIDTH-1:0] fifo_wdata, fifo_rdata;
  logic                  fifo_we, fifo_re, fifo_full, fifo_empty;

  // Simple synchronous FIFO for read->write path
  simple_fifo #(
    .WIDTH(DATA_WIDTH), .DEPTH(32)
  ) u_fifo (
    .clk(clk), .rst_n(rst_n),
    .wr_en(fifo_we), .wr_data(fifo_wdata), .full(fifo_full),
    .rd_en(fifo_re), .rd_data(fifo_rdata), .empty(fifo_empty)
  );

  // CSR: basic status and config
  logic [31:0] cfg_ctrl; // bit0 enable, bit1 irq_en
  logic [31:0] sts_reg;  // bit0 busy, bit1 err

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      cfg_ctrl <= 32'h0;
      csr_rdata <= '0;
      csr_rvalid <= 1'b0;
    end else begin
      csr_rvalid <= 1'b0;
      if (csr_we) begin
        case (csr_addr)
          16'h0000: cfg_ctrl <= csr_wdata;
          default: ;
        endcase
      end
      if (csr_re) begin
        csr_rvalid <= 1'b1;
        case (csr_addr)
          16'h0000: csr_rdata <= cfg_ctrl;
          16'h0004: csr_rdata <= sts_reg;
          default: csr_rdata <= 32'h0;
        endcase
      end
    end
  end

  // Power and idle
  assign dma_idle = (state==IDLE);
  wire clk_en = clock_enable & ~pwr_gate;

  // Handshake to accept descriptor
  assign desc_ready = clk_en && (state==IDLE);

  // Main FSM
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state <= IDLE;
      rd_addr <= '0; wr_addr <= '0; bytes_left <= '0;
    end else begin
      state <= nstate;
      if (desc_valid && desc_ready) begin
        rd_addr    <= src_addr;
        wr_addr    <= dst_addr;
        bytes_left <= bytes;
      end else begin
        // advance addresses on beats
        if (m_axi_rvalid && m_axi_rready) rd_addr <= rd_addr + (DATA_WIDTH/8);
        if (m_axi_wvalid && m_axi_wready) wr_addr <= wr_addr + (DATA_WIDTH/8);
        if ((m_axi_rvalid && m_axi_rready) || (dev_rx_valid && dev_rx_ready) || (m_axi_wvalid && m_axi_wready && xfer_type==2)) begin
          if (bytes_left >= (DATA_WIDTH/8)) bytes_left <= bytes_left - (DATA_WIDTH/8);
          else bytes_left <= 0;
        end
      end
    end
  end

  // Next-state and AXI logic
  always_comb begin
    nstate = state;
    // defaults
    {m_axi_arid,m_axi_araddr,m_axi_arlen,m_axi_arsize,m_axi_arburst,m_axi_arvalid} = '0;
    {m_axi_rready} = '0;
    {m_axi_awid,m_axi_awaddr,m_axi_awlen,m_axi_awsize,m_axi_awburst,m_axi_awvalid} = '0;
    {m_axi_wdata,m_axi_wstrb,m_axi_wlast,m_axi_wvalid} = '0;
    {m_axi_bready} = '0;
    {dev_tx_valid,dev_tx_data,dev_tx_last} = '0;
    {dev_rx_ready} = '0;
    {fifo_we,fifo_wdata,fifo_re} = '0;
    xfer_done  = 1'b0;
    xfer_error = 1'b0;

    sts_reg = 32'(0);
    sts_reg[0] = (state!=IDLE);

    unique case (state)
      IDLE: begin
        if (desc_valid && desc_ready && cfg_ctrl[0]) begin
          case (xfer_type)
            2'd0: nstate = READ;        // mem->mem
            2'd1: nstate = READ;        // mem->dev
            2'd2: nstate = STREAM_IN;   // dev->mem
            default: nstate = ERROR;
          endcase
        end
      end

      // Memory read path fills FIFO
      READ: begin
        // issue AR when space available
        if (!fifo_full && bytes_left!=0) begin
          m_axi_arvalid = 1'b1;
          m_axi_araddr  = rd_addr;
          m_axi_arlen   = BURST_MAX_BEATS-1;
          m_axi_arsize  = $clog2(DATA_WIDTH/8);
          m_axi_arburst = 2'b01; // INCR
        end
        // accept R beats into FIFO
        m_axi_rready = !fifo_full;
        if (m_axi_rvalid && m_axi_rready) begin
          fifo_we     = 1'b1;
          fifo_wdata  = m_axi_rdata;
        end
        // move to write or stream-out once we have data or all bytes read
        if ((xfer_type==0 || xfer_type==2'd2) && !fifo_empty) nstate = WRITE;
        if ((xfer_type==1) && !fifo_empty) nstate = STREAM_OUT;
        if (bytes_left==0 && fifo_empty) nstate = COMPLETE;
      end

      // Memory write path drains FIFO
      WRITE: begin
        if (!fifo_empty) begin
          m_axi_awvalid = 1'b1;
          m_axi_awaddr  = wr_addr;
          m_axi_awlen   = BURST_MAX_BEATS-1;
          m_axi_awsize  = $clog2(DATA_WIDTH/8);
          m_axi_awburst = 2'b01; // INCR

          m_axi_wvalid  = 1'b1;
          m_axi_wdata   = fifo_rdata;
          m_axi_wstrb   = { (DATA_WIDTH/8){1'b1} };
          m_axi_wlast   = 1'b1; // simple 1-beat model per cycle; burst coalescing TBD
          fifo_re       = m_axi_wready;
        end
        m_axi_bready = 1'b1;
        if ((bytes_left==0) && fifo_empty) nstate = COMPLETE;
      end

      // Stream to device (mem->dev)
      STREAM_OUT: begin
        if (!fifo_empty) begin
          dev_tx_valid = 1'b1;
          dev_tx_data  = fifo_rdata;
          dev_tx_last  = (bytes_left==0);
          fifo_re      = dev_tx_ready;
        end
        if ((bytes_left==0) && fifo_empty) nstate = COMPLETE;
      end

      // Stream from device (dev->mem)
      STREAM_IN: begin
        dev_rx_ready = !fifo_full;
        if (dev_rx_valid && dev_rx_ready) begin
          fifo_we    = 1'b1;
          fifo_wdata = dev_rx_data;
        end
        if (!fifo_empty) nstate = WRITE;
      end

      COMPLETE: begin
        xfer_done = 1'b1;
        nstate = IDLE;
      end

      ERROR: begin
        xfer_error = 1'b1;
        nstate = IDLE;
      end
    endcase
  end

endmodule

// Simple FIFO module (placeholder; replace with optimized implementation)
module simple_fifo #(parameter WIDTH=32, parameter DEPTH=32)(
  input  logic clk, rst_n,
  input  logic wr_en,
  input  logic [WIDTH-1:0] wr_data,
  output logic full,
  input  logic rd_en,
  output logic [WIDTH-1:0] rd_data,
  output logic empty
);
  localparam ADDR=$clog2(DEPTH);
  logic [WIDTH-1:0] mem[DEPTH-1:0];
  logic [ADDR:0] wptr, rptr;
  assign full  = (wptr[ADDR]!=rptr[ADDR]) && (wptr[ADDR-1:0]==rptr[ADDR-1:0]);
  assign empty = (wptr==rptr);
  assign rd_data = mem[rptr[ADDR-1:0]];
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      wptr <= '0; rptr <= '0;
    end else begin
      if (wr_en && !full) begin
        mem[wptr[ADDR-1:0]] <= wr_data;
        wptr <= wptr + 1'b1;
      end
      if (rd_en && !empty) begin
        rptr <= rptr + 1'b1;
      end
    end
  end
endmodule
