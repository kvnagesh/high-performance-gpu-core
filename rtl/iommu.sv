// iommu.sv - IOMMU for GPU/DMA clients with device-side translation and protection
// Supports PCIe-like devices, GPU engines; ATS/PRI-friendly hooks; per-device context tables
// SPDX-License-Identifier: Apache-2.0

module iommu #(
  parameter IPA_BITS       = 48,   // IO virtual address (device view)
  parameter PA_BITS        = 48,
  parameter DEV_ID_BITS    = 16,
  parameter PASID_BITS     = 20,
  parameter CTX_ENTRIES    = 256,
  parameter TLB_ENTRIES    = 256
) (
  input  logic                 clk,
  input  logic                 rst_n,

  // Device request (from DMA/shader/CP treated as devices)
  input  logic                 req_valid,
  output logic                 req_ready,
  input  logic [DEV_ID_BITS-1:0] req_dev_id,
  input  logic [PASID_BITS-1:0]  req_pasid,
  input  logic [IPA_BITS-1:0]    req_iova,
  input  logic [2:0]            req_access, // 0=fetch 1=read 2=write 3=atomic

  // Response
  output logic                 resp_valid,
  input  logic                 resp_ready,
  output logic [PA_BITS-1:0]  resp_paddr,
  output logic                 resp_r,
  output logic                 resp_w,
  output logic                 resp_x,
  output logic                 resp_fault,
  output logic [7:0]          resp_fault_code,

  // Context table fetch (through system memory)
  output logic                 ctx_ar_valid,
  input  logic                 ctx_ar_ready,
  output logic [PA_BITS-1:0]  ctx_ar_addr,
  input  logic                 ctx_r_valid,
  output logic                 ctx_r_ready,
  input  logic [255:0]        ctx_r_data,

  // PTW interface reused from MMU via shared walk port (arbited at top)
  output logic                 ptw_ar_valid,
  input  logic                 ptw_ar_ready,
  output logic [PA_BITS-1:0]  ptw_ar_addr,
  input  logic                 ptw_r_valid,
  output logic                 ptw_r_ready,
  input  logic [63:0]         ptw_r_data,

  // Management
  input  logic                 enable,
  input  logic [PA_BITS-1:0]  root_ctx_table_pa,
  input  logic                 tlb_flush
);

  typedef struct packed {
    logic valid;
    logic [DEV_ID_BITS-1:0] dev_id;
    logic [PASID_BITS-1:0]  pasid;
    logic [IPA_BITS-1:12]   iova_tag;
    logic [PA_BITS-1:12]    pa_tag;
    logic r,w,x;
  } tlb_t;

  tlb_t tlb [TLB_ENTRIES];
  logic [$clog2(TLB_ENTRIES)-1:0] rr_ptr;

  // simple IOVA->PA lookup; otherwise do 2-step: fetch context, then walk page tables
  typedef enum logic [2:0] {S_IDLE,S_CTX_REQ,S_CTX_WAIT,S_PTW_REQ,S_PTW_WAIT,S_DONE,S_FAULT} state_e;
  state_e st;

  // Latched request
  logic [DEV_ID_BITS-1:0]  l_dev;
  logic [PASID_BITS-1:0]   l_pasid;
  logic [IPA_BITS-1:0]     l_iova;
  logic [2:0]              l_acc;

  // Context format (256 bits): [0]=V, [63:12] = pt_root_ppn, [95:64] perm, others reserved
  logic [255:0] ctx_q; logic ctx_v;
  logic [PA_BITS-1:0] pt_root_pa;

  // TLB hit
  tlb_t h; logic hit;
  function automatic tlb_t tlb_lookup(input logic [DEV_ID_BITS-1:0] dev, input logic [PASID_BITS-1:0] pasid, input logic [IPA_BITS-1:0] iova, output logic hit_o);
    tlb_t r; r='0; hit_o=1'b0;
    for (int i=0;i<TLB_ENTRIES;i++) begin
      if (tlb[i].valid && tlb[i].dev_id==dev && tlb[i].pasid==pasid && tlb[i].iova_tag==iova[IPA_BITS-1:12]) begin r=tlb[i]; hit_o=1'b1; break; end
    end
    return r;
  endfunction

  assign req_ready = (st==S_IDLE) && resp_ready;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      st<=S_IDLE; rr_ptr<='0; for (int i=0;i<TLB_ENTRIES;i++) tlb[i].valid<=1'b0;
    end else begin
      if (tlb_flush) for (int i=0;i<TLB_ENTRIES;i++) tlb[i].valid<=1'b0;
      case(st)
        S_IDLE: begin
          if (enable && req_valid && req_ready) begin
            l_dev<=req_dev_id; l_pasid<=req_pasid; l_iova<=req_iova; l_acc<=req_access;
            // Check TLB
            h = tlb_lookup(req_dev_id, req_pasid, req_iova, hit);
            if (hit) begin st<=S_DONE; end else begin st<=S_CTX_REQ; end
          end
        end
        S_CTX_REQ: begin
          if (ctx_ar_ready) begin
            // two-level context: use dev_id and PASID to index 4KB context entries (256b each)
            ctx_ar_addr <= root_ctx_table_pa + { {(PA_BITS-28){1'b0}}, l_dev, l_pasid[15:0], 4'b0000};
            st<=S_CTX_WAIT;
          end
        end
        S_CTX_WAIT: begin
          if (ctx_r_valid) begin
            ctx_q <= ctx_r_data; ctx_v <= ctx_r_data[0];
            if (ctx_v) begin pt_root_pa <= {ctx_r_data[63:12],12'b0}; st<=S_PTW_REQ; end
            else begin st<=S_FAULT; resp_fault_code<=8'h01; end
          end
        end
        S_PTW_REQ: begin
          // Reuse PTW port like MMU; compute PTE address root + index
          if (ptw_ar_ready) begin
            ptw_ar_addr <= pt_root_pa + { {(PA_BITS-21){1'b0}}, l_iova[38:30], 3'b000};
            st<=S_PTW_WAIT;
          end
        end
        S_PTW_WAIT: begin
          if (ptw_r_valid) begin
            // Simplified single-level 2MB pages for IOMMU demonstration; extendable to multi-level
            logic v,r,w,x; logic [PA_BITS-1:12] ppn;
            v=ptw_r_data[0]; r=ptw_r_data[1]; w=ptw_r_data[2]; x=ptw_r_data[3]; ppn=ptw_r_data[53:12];
            if (!v) begin st<=S_FAULT; resp_fault_code<=8'h02; end
            else begin
              // Install TLB
              tlb[rr_ptr].valid<=1'b1; tlb[rr_ptr].dev_id<=l_dev; tlb[rr_ptr].pasid<=l_pasid; tlb[rr_ptr].iova_tag<=l_iova[IPA_BITS-1:12];
              tlb[rr_ptr].pa_tag<=ppn; tlb[rr_ptr].r<=r; tlb[rr_ptr].w<=w; tlb[rr_ptr].x<=x; rr_ptr<=rr_ptr+1'b1; st<=S_DONE;
            end
          end
        end
        S_DONE: begin
          st<=S_IDLE;
        end
        S_FAULT: begin
          st<=S_IDLE;
        end
      endcase
    end
  end

  // Response
  always_comb begin
    resp_valid=1'b0; resp_paddr='0; resp_r=0; resp_w=0; resp_x=0; resp_fault=0; resp_fault_code='0;
    ctx_ar_valid=1'b0; ctx_ar_addr='0; ctx_r_ready=1'b1;
    ptw_ar_valid=1'b0; ptw_ar_addr='0; ptw_r_ready=1'b1;
    if (enable && req_valid) begin
      h = tlb_lookup(req_dev_id, req_pasid, req_iova, hit);
      if (hit) begin
        resp_valid = 1'b1;
        resp_paddr = {h.pa_tag, req_iova[11:0]};
        resp_r = h.r; resp_w=h.w; resp_x=h.x;
      end else begin
        // drive fetches when in states
        if (st==S_CTX_REQ) ctx_ar_valid=1'b1;
        if (st==S_PTW_REQ) ptw_ar_valid=1'b1;
      end
    end
  end

endmodule
