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

// ==================== ASTC Decoder Integration ====================
// Compressed texture fetch interface from TMU
logic        astc_in_valid, astc_in_ready;
logic [127:0] astc_in_block; // 128-bit ASTC block input (typical), can widen as needed
// Configuration registers (to be driven by CP or TMU cfg path)
logic [3:0]  astc_blk_w, astc_blk_h;    // block dimensions
logic [1:0]  astc_num_partitions;
logic        astc_dual_plane_en;
logic [4:0]  astc_wt_quant_level;
logic        astc_hdr_mode_en; // HDR decoding enable

// Outputs to pixel backend
logic        astc_px_valid, astc_px_ready;
logic [511:0] astc_px_rgba; // packed pixel stream for a microtile
logic [7:0]   astc_px_count; // number of pixels valid

// Submodule wires
logic part_out_valid, part_out_ready;
logic [7:0] part_texel_count;
logic [143:0] plane_sel_flat;
logic [287:0] part_id_flat; // 2b * 144

// Instantiate partition decoder
astc_partition_decoder u_astc_part (
  .clk(clk_2GHz), .rst_n(rst_n),
  .cfg_block_w(astc_blk_w), .cfg_block_h(astc_blk_h), .cfg_dual_plane_enable(astc_dual_plane_en),
  .in_valid(astc_in_valid), .in_ready(astc_in_ready), .in_num_partitions(astc_num_partitions), .in_partition_seed(astc_in_block[9:0]),
  .out_valid(part_out_valid), .out_ready(part_out_ready), .out_texel_count(part_texel_count), .out_partition_id_flat(part_id_flat), .out_plane_sel_flat(plane_sel_flat)
);

// Weight unquantization
logic wt_out_valid, wt_out_ready; logic [1151:0] wt_weights_u8; // 144*8
astc_weight_unquant u_astc_wt (
  .clk(clk_2GHz), .rst_n(rst_n), .in_valid(part_out_valid), .in_ready(part_out_ready),
  .cfg_block_w(astc_blk_w), .cfg_block_h(astc_blk_h), .cfg_wt_quant_level(astc_wt_quant_level),
  .in_weights_q(astc_in_block[255:0]), .in_weight_count(part_texel_count),
  .out_valid(wt_out_valid), .out_ready(wt_out_ready), .out_weights_u8(wt_weights_u8)
);

// Endpoint unquantization + color reconstruction + HDR handling wrapper
logic ep_out_valid, ep_out_ready; logic [511:0] px_rgba_bus; logic [7:0] px_count_bus;
astc_endpoint_color u_astc_ep (
  .clk(clk_2GHz), .rst_n(rst_n),
  .in_valid(wt_out_valid), .in_ready(wt_out_ready),
  .cfg_block_w(astc_blk_w), .cfg_block_h(astc_blk_h), .cfg_hdr_mode(astc_hdr_mode_en), .cfg_dual_plane(astc_dual_plane_en),
  .partition_ids(part_id_flat), .plane_sel(plane_sel_flat), .weights_u8(wt_weights_u8), .texel_count(part_texel_count), .block_bits(astc_in_block),
  .out_valid(ep_out_valid), .out_ready(ep_out_ready), .px_rgba(px_rgba_bus), .px_count(px_count_bus)
);

// Hook to pixel backend
assign astc_px_valid = ep_out_valid;
assign px_rgba_bus_to_backend = px_rgba_bus; // existing bus assumed
assign px_count_to_backend    = px_count_bus;
assign ep_out_ready = astc_px_ready;

// Connect TMU fetch to ASTC input
assign astc_in_valid = tmu_astc_block_valid;
assign tmu_astc_block_ready = astc_in_ready;
assign astc_in_block = tmu_astc_block_data;
// Example default cfg; replace with CP register connections
assign astc_blk_w = tmu_astc_cfg_blk_w; assign astc_blk_h = tmu_astc_cfg_blk_h; assign astc_num_partitions = tmu_astc_cfg_num_parts;
assign astc_dual_plane_en = tmu_astc_cfg_dual_plane; assign astc_wt_quant_level = tmu_astc_cfg_wt_q; assign astc_hdr_mode_en = tmu_astc_cfg_hdr;
// gpu_core_top.sv (excerpt) - integrate power management blocks

// ========= Existing content above =========

// Power management includes
`include "power_state_machine.sv"

import psm_pkg::*;

// Parameters
localparam int unsigned NUM_DOMAINS = 8; // e.g., {Shader, RT, Raster, TMU, L2, MemCtrl, CP, Fabric}

// Clocks and resets assumed: clk_2GHz, rst_n

// Per-domain PSMs
psm_cmd_t      psm_cmd    [NUM_DOMAINS];
psm_status_t   psm_status [NUM_DOMAINS];
logic          psm_clk_req[NUM_DOMAINS];
logic          psm_clk_ack[NUM_DOMAINS];
logic  [2:0]   psm_clk_mode[NUM_DOMAINS];
logic          psm_vreq   [NUM_DOMAINS];
logic          psm_vack   [NUM_DOMAINS];
logic  [2:0]   psm_vlevel [NUM_DOMAINS];
psm_ctrl_t     psm_ctrl   [NUM_DOMAINS];
logic          domain_idle[NUM_DOMAINS];
logic          domain_wake_ev[NUM_DOMAINS];
logic          domain_thermal_throttle[NUM_DOMAINS];
logic          domain_fatal_err[NUM_DOMAINS];

// Dependency matrix
logic [NUM_DOMAINS-1:0] dep_matrix [NUM_DOMAINS];
// Example: shader depends on L2 and MemCtrl
// dep_matrix[0] = 'b00010010; // fill via CP in real design

// DVFS algorithm outputs
logic [2:0] dvfs_perf_req [NUM_DOMAINS];
logic [NUM_DOMAINS-1:0] dvfs_boost_active;

// Thermal throttle outputs
logic [2:0] therm_cap_domain [NUM_DOMAINS];
logic [2:0] therm_cap_global;
logic       therm_crit_shutdown;
logic [NUM_DOMAINS-1:0] throt_active;
logic [31:0] overtemp_events;

// Coordination engine signals
logic [2:0] global_perf;
logic [NUM_DOMAINS-1:0] coord_clk_req, coord_clk_ack;
logic [NUM_DOMAINS-1:0] coord_vreq, coord_vack;
logic [1:0] clk_sel [NUM_DOMAINS];
logic [15:0] active_mask;
logic [31:0] throttles_cnt, fault_cnt;

// Power sequencer
logic [NUM_DOMAINS-1:0] pwrup_req, pwrdn_req;
logic [NUM_DOMAINS-1:0] iso_en, rst_assert, pwr_sw_en, clk_en;
logic [NUM_DOMAINS-1:0] seq_busy, seq_fault;

// ========== Instantiate blocks ==========

// Thermal governor
thermal_throttle #(.NUM_SENSORS(8), .NUM_DOMAINS(NUM_DOMAINS)) u_therm (
  .clk(clk_2GHz), .rst_n(rst_n),
  .ts_code_i(ts_code_bus), .ts_valid_i(ts_valid_bus), .ts_analog_ready_i(ts_ana_rdy_bus),
  .domain_sensor_map_i(domain_sensor_map),
  .th_warn_hi_i(cfg_th_warn_hi), .th_warn_lo_i(cfg_th_warn_lo),
  .th_throt_hi_i(cfg_th_throt_hi), .th_throt_lo_i(cfg_th_throt_lo),
  .th_crit_hi_i(cfg_th_crit_hi), .th_crit_lo_i(cfg_th_crit_lo),
  .perf_cap_domain_o(therm_cap_domain), .perf_cap_global_o(therm_cap_global),
  .crit_shutdown_o(therm_crit_shutdown), .throt_active_o(throt_active), .overtemp_events_o(overtemp_events)
);

// DVFS policy
dvfs_algorithms #(.NUM_DOMAINS(NUM_DOMAINS)) u_dvfs (
  .clk(clk_2GHz), .rst_n(rst_n),
  .util_pct_i(util_pct_bus), .ipc_i(ipc_bus), .bw_bytes_ps_i(bw_bus),
  .thermal_cap_i(therm_cap_domain), .irq_latency_req_i(irq_lat_req_bus),
  .up_thresh_pct_i(cfg_dvfs_up), .down_thresh_pct_i(cfg_dvfs_down), .hysteresis_pct_i(cfg_dvfs_hyst),
  .min_hold_ms_i(cfg_min_hold_ms), .max_boost_ms_i(cfg_max_boost_ms),
  .perf_req_o(dvfs_perf_req), .boost_active_o(dvfs_boost_active)
);

// Coordination engine
power_coordination_engine #(.NUM_DOMAINS(NUM_DOMAINS)) u_coord (
  .clk(clk_2GHz), .rst_n(rst_n),
  .psm_state_i('{for (int d=0; d<NUM_DOMAINS; d++) psm_status[d].cur_state}),
  .perf_req_i(dvfs_perf_req),
  .psm_busy_i('{for (int d=0; d<NUM_DOMAINS; d++) psm_status[d].busy}),
  .psm_fault_i('{for (int d=0; d<NUM_DOMAINS; d++) psm_status[d].fault}),
  .global_perf_o(global_perf),
  .clk_req_o(coord_clk_req), .clk_ack_i(coord_clk_ack),
  .vreq_o(coord_vreq), .vack_i(coord_vack),
  .clk_sel_o(clk_sel),
  .dep_matrix_i(dep_matrix),
  .active_mask_o(active_mask), .throttles_cnt_o(throttles_cnt), .fault_cnt_o(fault_cnt)
);

// Power sequencer
power_sequencer #(.NUM_DOMAINS(NUM_DOMAINS)) u_pseq (
  .clk(clk_2GHz), .rst_n(rst_n),
  .pwrup_req_i(pwrup_req), .pwrdn_req_i(pwrdn_req),
  .iso_en_o(iso_en), .rst_assert_o(rst_assert), .pwr_sw_en_o(pwr_sw_en), .clk_en_o(clk_en),
  .domain_idle_i(domain_idle),
  .dep_matrix_i(dep_matrix),
  .seq_busy_o(seq_busy), .seq_fault_o(seq_fault)
);

// Per-domain PSM instances
for (genvar d=0; d<NUM_DOMAINS; d++) begin : GEN_PSM
  power_state_machine #(.NAME("domain"), .TIMEOUT_US(20000)) u_psm (
    .clk(clk_2GHz), .rst_n(rst_n),
    .cmd_i(psm_cmd[d]), .status_o(psm_status[d]),
    .clk_req_o(psm_clk_req[d]), .clk_ack_i(coord_clk_ack[d]), .clk_mode_o(psm_clk_mode[d]),
    .vreq_o(psm_vreq[d]), .vack_i(coord_vack[d]), .vlevel_o(psm_vlevel[d]),
    .ctrl_o(psm_ctrl[d]),
    .idle_i(domain_idle[d]), .wake_ev_i(domain_wake_ev[d]),
    .thermal_throttle_i(domain_thermal_throttle[d]), .fatal_err_i(domain_fatal_err[d])
  );
end

// Glue: connect coordination engine acks/reqs to PSMs and clock/voltage providers
assign coord_clk_ack = clk_provider_ack_bus; // from clock unit
assign coord_vack    = volt_provider_ack_bus; // from PMIC/VRM
assign clk_provider_req_bus = coord_clk_req | psm_clk_req; // OR policy
assign volt_provider_req_bus = coord_vreq | psm_vreq;

// Clock mux per domain
for (genvar d=0; d<NUM_DOMAINS; d++) begin : GEN_CLKMUX
  always_comb begin
    unique case (clk_sel[d])
      2'd0: domain_clk_en[d] = 1'b0;
      2'd1: domain_clk_en[d] = pllA_en[d];
      2'd2: domain_clk_en[d] = pllB_en[d];
      2'd3: domain_clk_en[d] = osc_en[d];
    endcase
  end
end

// Sequencer controls to power domain controls
assign iso_signals   = iso_en;
assign rst_signals   = rst_assert;
assign pwr_switch_en = pwr_sw_en;
assign clk_enables   = clk_en;

// Host-visible telemetry and CSRs can read: psm_status, global_perf, throttles_cnt, fault_cnt, overtemp_events
// Extreme event handling
always_ff @(posedge clk_2GHz or negedge rst_n) begin
  if (!rst_n) begin
    sys_shutdown <= 1'b0;
  end else begin
    if (therm_crit_shutdown) sys_shutdown <= 1'b1;
  end
end

// ========= Existing content below (MMU/IOMMU and ASTC integration) =========
