// Insert Pixel Backend between rasterizer and AFBC/tile writeback
// Existing declarations kept...
// MMU/IOMMU integration wires
logic         mmu_req_valid, mmu_req_ready;
logic [47:0]  mmu_req_vaddr;
logic [15:0]  mmu_req_asid;
logic [2:0]   mmu_req_access;
logic         mmu_resp_valid, mmu_resp_ready;
logic [47:0]  mmu_resp_paddr;
logic [1:0]   mmu_resp_page_sz;
logic         mmu_resp_r, mmu_resp_w, mmu_resp_x;
logic         mmu_resp_fault; logic [3:0] mmu_resp_fault_cause;
logic         ptw_ar_valid, ptw_ar_ready; logic [47:0] ptw_ar_addr; logic [7:0] ptw_ar_len; logic [2:0] ptw_ar_size; logic [1:0] ptw_ar_burst;
logic         ptw_r_valid, ptw_r_ready; logic [63:0] ptw_r_data; logic ptw_r_last;
logic         tlb_flush_global, tlb_flush_asid_valid; logic [15:0] tlb_flush_asid;
logic         tlb_invalidate_va_valid; logic [47:0] tlb_invalidate_va;
logic         mmu_enable; logic [47:0] satp_ppn; logic [15:0] satp_asid; logic [1:0] config_sum_mxr;
// IOMMU wires
logic         iommu_req_valid, iommu_req_ready; logic [15:0] iommu_dev_id; logic [19:0] iommu_pasid; logic [47:0] iommu_iova; logic [2:0] iommu_access;
logic         iommu_resp_valid, iommu_resp_ready; logic [47:0] iommu_resp_paddr; logic iommu_resp_r, iommu_resp_w, iommu_resp_x; logic iommu_resp_fault; logic [7:0] iommu_resp_fault_code;
logic         ctx_ar_valid, ctx_ar_ready; logic [47:0] ctx_ar_addr; logic ctx_r_valid, ctx_r_ready; logic [255:0] ctx_r_data;
logic         iommu_ptw_ar_valid, iommu_ptw_ar_ready; logic [47:0] iommu_ptw_ar_addr; logic iommu_ptw_r_valid, iommu_ptw_r_ready; logic [63:0] iommu_ptw_r_data;
logic         iommu_enable; logic [47:0] root_ctx_table_pa; logic iommu_tlb_flush;

// Instantiate MMU
mmu u_mmu (
  .clk(clk_2GHz), .rst_n(rst_n),
  .req_valid(mmu_req_valid), .req_ready(mmu_req_ready), .req_vaddr(mmu_req_vaddr), .req_asid(mmu_req_asid), .req_access(mmu_req_access),
  .resp_valid(mmu_resp_valid), .resp_ready(mmu_resp_ready), .resp_paddr(mmu_resp_paddr), .resp_page_sz(mmu_resp_page_sz), .resp_perm_r(mmu_resp_r), .resp_perm_w(mmu_resp_w), .resp_perm_x(mmu_resp_x), .resp_fault(mmu_resp_fault), .resp_fault_cause(mmu_resp_fault_cause),
  .ptw_ar_valid(ptw_ar_valid), .ptw_ar_ready(ptw_ar_ready), .ptw_ar_addr(ptw_ar_addr), .ptw_ar_len(ptw_ar_len), .ptw_ar_size(ptw_ar_size), .ptw_ar_burst(ptw_ar_burst),
  .ptw_r_valid(ptw_r_valid), .ptw_r_ready(ptw_r_ready), .ptw_r_data(ptw_r_data), .ptw_r_last(ptw_r_last),
  .tlb_flush_global(tlb_flush_global), .tlb_flush_asid_valid(tlb_flush_asid_valid), .tlb_flush_asid(tlb_flush_asid), .tlb_invalidate_va_valid(tlb_invalidate_va_valid), .tlb_invalidate_va(tlb_invalidate_va),
  .mmu_enable(mmu_enable), .satp_ppn(satp_ppn), .satp_asid(satp_asid), .config_sum_mxr(config_sum_mxr)
);

// Instantiate IOMMU (optional)
iommu u_iommu (
  .clk(clk_2GHz), .rst_n(rst_n),
  .req_valid(iommu_req_valid), .req_ready(iommu_req_ready), .req_dev_id(iommu_dev_id), .req_pasid(iommu_pasid), .req_iova(iommu_iova), .req_access(iommu_access),
  .resp_valid(iommu_resp_valid), .resp_ready(iommu_resp_ready), .resp_paddr(iommu_resp_paddr), .resp_r(iommu_resp_r), .resp_w(iommu_resp_w), .resp_x(iommu_resp_x), .resp_fault(iommu_resp_fault), .resp_fault_code(iommu_resp_fault_code),
  .ctx_ar_valid(ctx_ar_valid), .ctx_ar_ready(ctx_ar_ready), .ctx_ar_addr(ctx_ar_addr), .ctx_r_valid(ctx_r_valid), .ctx_r_ready(ctx_r_ready), .ctx_r_data(ctx_r_data),
  .ptw_ar_valid(iommu_ptw_ar_valid), .ptw_ar_ready(iommu_ptw_ar_ready), .ptw_ar_addr(iommu_ptw_ar_addr), .ptw_r_valid(iommu_ptw_r_valid), .ptw_r_ready(iommu_ptw_r_ready), .ptw_r_data(iommu_ptw_r_data),
  .enable(iommu_enable), .root_ctx_table_pa(root_ctx_table_pa), .tlb_flush(iommu_tlb_flush)
);

// Simple arbitration to memory controller for PTW and IOMMU fetches (round-robin)
// Map to existing memory controller AXI read channel signals: mem_ar*, mem_r*
logic arb_sel;
always_ff @(posedge clk_2GHz or negedge rst_n) begin
  if (!rst_n) arb_sel <= 1'b0; else if ((ptw_ar_valid & ptw_ar_ready) | (iommu_ptw_ar_valid & iommu_ptw_ar_ready)) arb_sel <= ~arb_sel;
end
assign ptw_ar_ready       = (!arb_sel) ? mem_arready : 1'b0;
assign iommu_ptw_ar_ready = ( arb_sel) ? mem_arready : 1'b0;
assign mem_arvalid        = (!arb_sel) ? ptw_ar_valid : iommu_ptw_ar_valid;
assign mem_araddr         = (!arb_sel) ? ptw_ar_addr[31:0] : iommu_ptw_ar_addr[31:0];
assign mem_arlen          = 8'd0; assign mem_arsize = 3'd3; assign mem_arburst = 2'b01; // single 8B beat
assign ptw_r_valid        = (!arb_sel) ? mem_rvalid : 1'b0;
assign ptw_r_data         = mem_rdata[63:0];
assign ptw_r_last         = mem_rlast;
assign mem_rready         = (!arb_sel) ? ptw_r_ready : iommu_ptw_r_ready;
assign iommu_ptw_r_valid  = ( arb_sel) ? mem_rvalid : 1'b0;
assign iommu_ptw_r_data   = mem_rdata[63:0];

// Connect clients to MMU/IOMMU
// Shader instruction/data fetch -> MMU
assign mmu_req_valid  = shader_mem_req_valid; // from shader_core
assign shader_mem_req_ready = mmu_req_ready;
assign mmu_req_vaddr  = shader_mem_vaddr;
assign mmu_req_asid   = current_asid;
assign mmu_req_access = shader_mem_access;
assign mmu_resp_ready = shader_mem_resp_ready;
assign shader_mem_resp_valid = mmu_resp_valid;
assign shader_mem_paddr      = mmu_resp_paddr;
assign shader_mem_fault      = mmu_resp_fault;

// DMA source/dest addresses -> IOMMU
assign iommu_req_valid = dma_addr_translate_req;
assign dma_addr_translate_ready = iommu_req_ready;
assign iommu_dev_id    = {12'd0, dma_src_dev}; // simple dev-id map
assign iommu_pasid     = 20'd0; // PASID disabled for now
assign iommu_iova      = dma_translate_addr;
assign iommu_access    = dma_translate_access;
assign iommu_resp_ready= 1'b1;
assign dma_translated_paddr = iommu_resp_paddr;
assign dma_translation_fault = iommu_resp_fault;

// Default MMU/IOMMU config (to be driven by CP registers)
assign mmu_enable   = 1'b1; assign satp_ppn = boot_page_table_root; assign satp_asid = boot_asid; assign config_sum_mxr = 2'b00;
assign iommu_enable = 1'b1; assign root_ctx_table_pa = boot_ctx_root; assign iommu_tlb_flush = 1'b0;
