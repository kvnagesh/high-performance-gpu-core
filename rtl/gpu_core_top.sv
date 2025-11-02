// Insert Pixel Backend between rasterizer and AFBC/tile writeback
// Existing declarations kept...

// Command Processor and DMA Engine integration
// Declarations
logic                cp_reg_we, cp_reg_re; 
logic [15:0]         cp_reg_addr; 
logic [31:0]         cp_reg_wdata, cp_reg_rdata; 
logic                cp_reg_rvalid;
logic                cp_irq; logic [7:0] cp_queue_irq;
logic                cp_pwr_gate, cp_clk_en;
assign cp_pwr_gate = 1'b0; assign cp_clk_en = 1'b1; // TODO: hook to real power manager

// Command fetch side (to memory or DMA). For now, tie to memory controller stubs
logic [63:0]         cp_cmd_addr; 
logic                cp_cmd_req, cp_cmd_ack; 
logic [255:0]        cp_cmd_data; 
logic                cp_cmd_valid;
assign cp_cmd_ack   = mem_ready; // simple ack from mem for now
assign cp_cmd_data  = mem_rdata; // assume a read data bus exists in top
assign cp_cmd_valid = mem_rvalid;

// DMA descriptor wires
logic                dma_desc_valid, dma_desc_ready; 
logic [63:0]         dma_src_addr, dma_dst_addr; 
logic [31:0]         dma_bytes; 
logic [1:0]          dma_type; 
logic [3:0]          dma_src_dev, dma_dst_dev, dma_src_prot, dma_dst_prot; 
logic                dma_done, dma_err;

// Job dispatch wires
logic                job_valid, job_ready, job_done; 
logic [127:0]        job_desc;
assign job_ready = 1'b1; // TODO: backpressure from pipeline front-end
assign job_done  = 1'b0; // TODO: signal from completion path

// Instantiate Command Processor
cmd_processor #(
  .ADDR_WIDTH(64), .DATA_WIDTH(256), .QUEUES(8), .CTX_SLOTS(8), .REG_AW(16), .REG_DW(32)
) u_cmdp (
  .clk(clk_2GHz), .rst_n(rst_n),
  .reg_we(cp_reg_we), .reg_re(cp_reg_re), .reg_addr(cp_reg_addr), .reg_wdata(cp_reg_wdata), .reg_rdata(cp_reg_rdata), .reg_rvalid(cp_reg_rvalid),
  .cmd_fetch_addr(cp_cmd_addr), .cmd_fetch_req(cp_cmd_req), .cmd_fetch_ack(cp_cmd_ack), .cmd_fetch_data(cp_cmd_data), .cmd_fetch_valid(cp_cmd_valid),
  .dma_desc_valid(dma_desc_valid), .dma_desc_ready(dma_desc_ready), .dma_src_addr(dma_src_addr), .dma_dst_addr(dma_dst_addr), .dma_bytes(dma_bytes), .dma_type(dma_type), .dma_src_dev(dma_src_dev), .dma_dst_dev(dma_dst_dev), .dma_src_prot(dma_src_prot), .dma_dst_prot(dma_dst_prot), .dma_xfer_done(dma_done), .dma_xfer_error(dma_err),
  .job_valid(job_valid), .job_ready(job_ready), .job_desc(job_desc), .job_done(job_done),
  .irq(cp_irq), .queue_irq(cp_queue_irq),
  .pwr_gate(cp_pwr_gate), .clock_enable(cp_clk_en), .cp_idle()
);

// Instantiate DMA Engine (AXI master ports to memory controller)
dma_engine #(
  .ADDR_WIDTH(64), .DATA_WIDTH(256), .ID_WIDTH(6), .LEN_WIDTH(8), .BURST_MAX_BEATS(16)
) u_dma (
  .clk(clk_2GHz), .rst_n(rst_n),
  .csr_we(1'b0), .csr_re(1'b0), .csr_addr('0), .csr_wdata('0), .csr_rdata(), .csr_rvalid(),
  .pwr_gate(cp_pwr_gate), .clock_enable(cp_clk_en), .dma_idle(),
  .desc_valid(dma_desc_valid), .desc_ready(dma_desc_ready), .src_addr(dma_src_addr), .dst_addr(dma_dst_addr), .bytes(dma_bytes), .xfer_type(dma_type), .src_dev(dma_src_dev), .dst_dev(dma_dst_dev), .src_axi_prot(dma_src_prot), .dst_axi_prot(dma_dst_prot), .xfer_done(dma_done), .xfer_error(dma_err),
  // AXI read
  .m_axi_arid(mem_arid), .m_axi_araddr(mem_araddr), .m_axi_arlen(mem_arlen), .m_axi_arsize(mem_arsize), .m_axi_arburst(mem_arburst), .m_axi_arvalid(mem_arvalid), .m_axi_arready(mem_arready), .m_axi_rid(mem_rid), .m_axi_rdata(mem_rdata), .m_axi_rresp(mem_rresp), .m_axi_rlast(mem_rlast), .m_axi_rvalid(mem_rvalid), .m_axi_rready(mem_rready),
  // AXI write
  .m_axi_awid(mem_awid), .m_axi_awaddr(mem_awaddr), .m_axi_awlen(mem_awlen), .m_axi_awsize(mem_awsize), .m_axi_awburst(mem_awburst), .m_axi_awvalid(mem_awvalid), .m_axi_awready(mem_awready), .m_axi_wdata(mem_wdata), .m_axi_wstrb(mem_wstrb), .m_axi_wlast(mem_wlast), .m_axi_wvalid(mem_wvalid), .m_axi_wready(mem_wready), .m_axi_bid(mem_bid), .m_axi_bresp(mem_bresp), .m_axi_bvalid(mem_bvalid), .m_axi_bready(mem_bready),
  // Device streams (optional)
  .dev_tx_valid(), .dev_tx_ready(1'b0), .dev_tx_data(), .dev_tx_last(), .dev_rx_valid(1'b0), .dev_rx_ready(), .dev_rx_data('0), .dev_rx_last(1'b0)
);

// Hook command fetch to AXI read path using DMA or direct MC: simple direct mapping
assign mem_read_req = cp_cmd_req; // assumes top has mem_read_req
assign mem_araddr   = cp_cmd_addr[31:0]; // truncate for now

// TODO: Hook cp_irq to external interrupt line
// TODO: Expose cp_reg_* via host AXI-Lite bridge

// Existing Pixel Backend code remains below...
