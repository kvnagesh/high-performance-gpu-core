// Command Processor with job scheduling, ring buffers, context mgmt
`timescale 1ns/1ps

module cmd_processor #(
  parameter ADDR_WIDTH = 64,
  parameter DATA_WIDTH = 256,
  parameter QUEUES     = 8,
  parameter CTX_SLOTS  = 8,
  parameter REG_AW     = 16,
  parameter REG_DW     = 32
)(
  input  logic                 clk,
  input  logic                 rst_n,

  // Host CSR (AXI-Lite bridge externally)
  input  logic                 reg_we,
  input  logic                 reg_re,
  input  logic [REG_AW-1:0]    reg_addr,
  input  logic [REG_DW-1:0]    reg_wdata,
  output logic [REG_DW-1:0]    reg_rdata,
  output logic                 reg_rvalid,

  // AXI4 master to fetch command buffers (connect to DMA or memory)
  output logic [ADDR_WIDTH-1:0]cmd_fetch_addr,
  output logic                 cmd_fetch_req,
  input  logic                 cmd_fetch_ack,
  input  logic [DATA_WIDTH-1:0]cmd_fetch_data,
  input  logic                 cmd_fetch_valid,

  // DMA engine interface for payload transfers
  output logic                 dma_desc_valid,
  input  logic                 dma_desc_ready,
  output logic [ADDR_WIDTH-1:0]dma_src_addr,
  output logic [ADDR_WIDTH-1:0]dma_dst_addr,
  output logic [31:0]          dma_bytes,
  output logic [1:0]           dma_type,
  output logic [3:0]           dma_src_dev,
  output logic [3:0]           dma_dst_dev,
  output logic [3:0]           dma_src_prot,
  output logic [3:0]           dma_dst_prot,
  input  logic                 dma_xfer_done,
  input  logic                 dma_xfer_error,

  // Job dispatch to GPU front-end(s)
  output logic                 job_valid,
  input  logic                 job_ready,
  output logic [127:0]         job_desc,
  input  logic                 job_done,

  // Interrupt/status
  output logic                 irq,
  output logic [QUEUES-1:0]    queue_irq,

  // Power hooks
  input  logic                 pwr_gate,
  input  logic                 clock_enable,
  output logic                 cp_idle
);

  // Per-queue ring buffer registers (submission and completion rings)
  typedef struct packed {
    logic enable;
    logic irq_en;
    logic [ADDR_WIDTH-1:0] sq_base;
    logic [31:0]           sq_size; // in entries
    logic [31:0]           sq_head;
    logic [31:0]           sq_tail;

    logic [ADDR_WIDTH-1:0] cq_base;
    logic [31:0]           cq_size;
    logic [31:0]           cq_head;
    logic [31:0]           cq_tail;
  } queue_regs_t;

  queue_regs_t q[QUEUES];

  // Context table (save/restore minimal set)
  typedef struct packed {
    logic        valid;
    logic [31:0] ctx_id;
    logic [ADDR_WIDTH-1:0] scratch_ptr;
    logic [63:0] flags;
  } ctx_t;

  ctx_t ctx_table[CTX_SLOTS];

  // Scheduler state
  logic [2:0]  sched_state;
  logic [3:0]  cur_q;
  logic        have_job;
  logic [127:0]cur_job_desc;

  // Simple round-robin over enabled queues with pending work
  function logic queue_has_work(input queue_regs_t qr);
    queue_has_work = qr.enable && (qr.sq_head != qr.sq_tail);
  endfunction

  // CSR map per-queue: base + stride 0x40 per queue
  localparam Q_STRIDE = 16'h0040;

  // CSR read/write
  integer i;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (i=0;i<QUEUES;i++) begin
        q[i].enable   <= 1'b0; q[i].irq_en <= 1'b0;
        q[i].sq_base  <= '0; q[i].sq_size <= '0; q[i].sq_head <= '0; q[i].sq_tail <= '0;
        q[i].cq_base  <= '0; q[i].cq_size <= '0; q[i].cq_head <= '0; q[i].cq_tail <= '0;
      end
      reg_rdata  <= '0; reg_rvalid <= 1'b0;
    end else begin
      reg_rvalid <= 1'b0;
      if (reg_we) begin
        for (i=0;i<QUEUES;i++) begin
          automatic logic [REG_AW-1:0] base = i*Q_STRIDE;
          unique case (reg_addr)
            base+16'h00: q[i].enable    <= reg_wdata[0];
            base+16'h04: q[i].irq_en    <= reg_wdata[0];
            base+16'h08: q[i].sq_base[31:0]  <= reg_wdata;
            base+16'h0C: q[i].sq_base[63:32] <= reg_wdata;
            base+16'h10: q[i].sq_size   <= reg_wdata;
            base+16'h14: q[i].sq_head   <= reg_wdata;
            base+16'h18: q[i].sq_tail   <= reg_wdata;
            base+16'h1C: q[i].cq_base[31:0]  <= reg_wdata;
            base+16'h20: q[i].cq_base[63:32] <= reg_wdata;
            base+16'h24: q[i].cq_size   <= reg_wdata;
            base+16'h28: q[i].cq_head   <= reg_wdata;
            base+16'h2C: q[i].cq_tail   <= reg_wdata;
            default: ;
          endcase
        end
      end
      if (reg_re) begin
        reg_rvalid <= 1'b1;
        reg_rdata  <= '0;
        for (i=0;i<QUEUES;i++) begin
          automatic logic [REG_AW-1:0] base = i*Q_STRIDE;
          unique case (reg_addr)
            base+16'h00: reg_rdata <= {31'h0,q[i].enable};
            base+16'h04: reg_rdata <= {31'h0,q[i].irq_en};
            base+16'h08: reg_rdata <= q[i].sq_base[31:0];
            base+16'h0C: reg_rdata <= q[i].sq_base[63:32];
            base+16'h10: reg_rdata <= q[i].sq_size;
            base+16'h14: reg_rdata <= q[i].sq_head;
            base+16'h18: reg_rdata <= q[i].sq_tail;
            base+16'h1C: reg_rdata <= q[i].cq_base[31:0];
            base+16'h20: reg_rdata <= q[i].cq_base[63:32];
            base+16'h24: reg_rdata <= q[i].cq_size;
            base+16'h28: reg_rdata <= q[i].cq_head;
            base+16'h2C: reg_rdata <= q[i].cq_tail;
            default: ;
          endcase
        end
      end
    end
  end

  // Power/idle
  assign cp_idle = (sched_state==3'd0);
  wire clk_en = clock_enable & ~pwr_gate;

  // Scheduler FSM
  localparam S_IDLE=3'd0, S_FETCH=3'd1, S_PARSE=3'd2, S_DISPATCH=3'd3, S_WAIT_DONE=3'd4, S_POST=3'd5;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      sched_state <= S_IDLE; cur_q <= '0; have_job <= 1'b0; cur_job_desc <= '0;
    end else begin
      if (!clk_en) begin
        // hold state in clock gated mode
      end else begin
        unique case (sched_state)
          S_IDLE: begin
            // round-robin find queue with work
            for (i=0;i<QUEUES;i++) begin
              automatic int idx = (cur_q + i) % QUEUES;
              if (queue_has_work(q[idx])) begin
                cur_q <= idx[3:0];
                sched_state <= S_FETCH;
                break;
              end
            end
          end
          S_FETCH: begin
            // issue fetch for SQ head entry
            cmd_fetch_req  <= 1'b1;
            cmd_fetch_addr <= q[cur_q].sq_base + (q[cur_q].sq_head % q[cur_q].sq_size)* (DATA_WIDTH/8);
            if (cmd_fetch_ack) begin
              sched_state <= S_PARSE;
            end
          end
          S_PARSE: begin
            if (cmd_fetch_valid) begin
              // For now, assume 128-bit job descriptor at low bits of fetched line
              cur_job_desc <= cmd_fetch_data[127:0];
              have_job <= 1'b1;
              sched_state <= S_DISPATCH;
            end
          end
          S_DISPATCH: begin
            if (job_ready && have_job) begin
              // Present job to pipeline
              sched_state <= S_WAIT_DONE;
              have_job <= 1'b0;
            end
          end
          S_WAIT_DONE: begin
            if (job_done) begin
              sched_state <= S_POST;
            end
          end
          S_POST: begin
            // Update SQ head and produce a CQ entry (completion)
            q[cur_q].sq_head <= q[cur_q].sq_head + 1;
            q[cur_q].cq_tail <= q[cur_q].cq_tail + 1; // completion produced
            sched_state <= S_IDLE;
          end
          default: sched_state <= S_IDLE;
        endcase
      end
    end
  end

  // Job descriptor mapping to dispatch port
  assign job_valid = (sched_state==S_DISPATCH) && have_job;
  assign job_desc  = cur_job_desc;

  // Generate IRQ per-queue when CQ updates
  genvar qi;
  generate for (qi=0; qi<QUEUES; qi++) begin : gen_irq
    assign queue_irq[qi] = q[qi].irq_en && (q[qi].cq_tail != q[qi].cq_head);
  end endgenerate
  assign irq = |queue_irq;

endmodule
