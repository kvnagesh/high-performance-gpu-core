//=============================================================================
// Module: pixel_backend.sv
// Description: Parent module for pixel backend processing pipeline
//
// PRODUCTION FEATURES TO BE SUPPORTED:
// - Integration with Rasterizer Output: Accept fragment data and early-Z signals
//   from rasterizer.sv
// - Depth/Stencil Testing: Hierarchical Z-binning for early kill, per-fragment
//   depth/stencil logic with updates
//   * Support formats: D24S8, D32, stencil mask/write logic
// - Blending: Alpha blending (SRC_ALPHA, ONE_MINUS_SRC_ALPHA, etc.)
//   * Programmable blend factors
//   * Integer and float pipeline options
//   * Multiple Render Targets (MRT) support
// - Tile Writeback: Buffer completed tiles in SRAM, burst-write to DRAM
//   * AFBC support for bandwidth reduction
// - Programmable State Register Files: Configure depth, stencil, and blend
//   operations per modern API requirements
//
// This module orchestrates the pixel backend pipeline, instantiating and
// connecting depth_stencil.sv, blender.sv, and tile_writeback.sv as children.
//=============================================================================
module pixel_backend #(
  parameter int FRAG_DATA_WIDTH = 128,    // Fragment data bus width
  parameter int DEPTH_WIDTH      = 32,    // Depth value width
  parameter int STENCIL_WIDTH    = 8,     // Stencil value width
  parameter int COLOR_WIDTH      = 32,    // Color channel width per pixel
  parameter int NUM_RENDER_TARGETS = 4,   // Maximum MRT count
  parameter int TILE_WIDTH       = 16,    // Tile width in pixels
  parameter int TILE_HEIGHT      = 16,    // Tile height in pixels
  parameter int REG_ADDR_WIDTH   = 16,    // Register address width
  parameter int REG_DATA_WIDTH   = 32     // Register data width
) (
  // Clock and Reset
  input  logic                           clk,
  input  logic                           rst_n,
  // Rasterizer Fragment Input Interface
  input  logic                           frag_valid,
  output logic                           frag_ready,
  input  logic [FRAG_DATA_WIDTH-1:0]     frag_data,
  input  logic [15:0]                    frag_x,              // Fragment X coordinate
  input  logic [15:0]                    frag_y,              // Fragment Y coordinate
  input  logic [DEPTH_WIDTH-1:0]         frag_depth,          // Fragment depth value
  input  logic [STENCIL_WIDTH-1:0]       frag_stencil,        // Fragment stencil value
  input  logic [COLOR_WIDTH-1:0]         frag_color_r,        // Fragment color (Red)
  input  logic [COLOR_WIDTH-1:0]         frag_color_g,        // Fragment color (Green)
  input  logic [COLOR_WIDTH-1:0]         frag_color_b,        // Fragment color (Blue)
  input  logic [COLOR_WIDTH-1:0]         frag_color_a,        // Fragment color (Alpha)
  input  logic [3:0]                     frag_render_target,  // Target render target ID
  // Early-Z Signals from Rasterizer
  input  logic                           early_z_kill,        // Early-Z killed this fragment
  input  logic                           early_z_valid,       // Early-Z result valid
  // Programmable State Register Interface
  input  logic                           reg_write_en,
  input  logic [REG_ADDR_WIDTH-1:0]      reg_write_addr,
  input  logic [REG_DATA_WIDTH-1:0]      reg_write_data,
  input  logic                           reg_read_en,
  input  logic [REG_ADDR_WIDTH-1:0]      reg_read_addr,
  output logic [REG_DATA_WIDTH-1:0]      reg_read_data,
  output logic                           reg_read_valid,
  // AFBC Compression / Tile Writeback Output Interface
  output logic                           tile_valid,
  input  logic                           tile_ready,
  output logic [15:0]                    tile_x,              // Tile X coordinate
  output logic [15:0]                    tile_y,              // Tile Y coordinate
  output logic [3:0]                     tile_render_target,  // Render target for this tile
  output logic                           tile_complete,       // Tile is complete
  output logic                           tile_use_afbc,       // Use AFBC compression
  output logic [63:0]                    tile_addr,           // DRAM address for tile
  output logic [31:0]                    tile_size,           // Tile data size in bytes
  // DRAM Write Interface (for tile writeback)
  output logic                           dram_write_req,
  input  logic                           dram_write_ack,
  output logic [63:0]                    dram_write_addr,
  output logic [31:0]                    dram_write_len,
  output logic [255:0]                   dram_write_data,
  output logic                           dram_write_last,
  // Status and Debug
  output logic [31:0]                    pixel_count,         // Processed pixel count
  output logic [31:0]                    tile_count,          // Completed tile count
  output logic                           pipeline_busy,       // Pipeline active
  output logic                           pipeline_stall       // Pipeline stalled
);
  //---------------------------------------------------------------------------
  // Register file definition (minimal map, expandable)
  //---------------------------------------------------------------------------
  typedef struct packed {
    logic       depth_enable;
    logic [1:0] depth_func;       // 0: LESS, 1: LEQUAL, 2: GREATER, 3: ALWAYS
    logic       depth_write;
    logic       depth_format;     // 0: D24S8, 1: D32
    logic       stencil_enable;
    logic [7:0] stencil_ref;
    logic [7:0] stencil_mask;
    logic [7:0] stencil_write_mask;
    logic [2:0] stencil_func;     // CMP func
    logic [2:0] stencil_op_sfail; // ops: KEEP/REPLACE/INCR/DECR/INVERT/...
    logic [2:0] stencil_op_dfail;
    logic [2:0] stencil_op_dpass;
  } ds_cfg_t;

  typedef struct packed {
    logic       blend_enable[NUM_RENDER_TARGETS];
    logic [3:0] src_factor[NUM_RENDER_TARGETS]; // ENUM factors
    logic [3:0] dst_factor[NUM_RENDER_TARGETS];
    logic [2:0] eq_rgb[NUM_RENDER_TARGETS];     // ADD/SUB/REV_SUB/MIN/MAX
    logic [2:0] eq_a[NUM_RENDER_TARGETS];
    logic       int_pipeline;                   // 0: float, 1: integer
    logic [7:0] const_color_r, const_color_g, const_color_b, const_color_a;
  } blend_cfg_t;

  ds_cfg_t   ds_cfg;
  blend_cfg_t blend_cfg;

  // Simple register bank (placeholder decode)
  // 0x0000-0x0003: ds_cfg packed words, 0x0100-: blend cfg
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      ds_cfg <= '0; blend_cfg <= '0;
    end else if (reg_write_en) begin
      unique case (reg_write_addr[11:0])
        12'h000: ds_cfg[31:0] <= reg_write_data;
        12'h004: ds_cfg[63:32] <= reg_write_data;
        12'h100: blend_cfg[31:0] <= reg_write_data;
        default: ;
      endcase
    end
  end

  always_comb begin
    reg_read_valid = 1'b0;
    reg_read_data  = '0;
    if (reg_read_en) begin
      reg_read_valid = 1'b1;
      unique case (reg_read_addr[11:0])
        12'h000: reg_read_data = ds_cfg[31:0];
        12'h004: reg_read_data = ds_cfg[63:32];
        12'h100: reg_read_data = blend_cfg[31:0];
        default: reg_read_valid = 1'b0;
      endcase
    end
  end

  //---------------------------------------------------------------------------
  // Inter-stage wires
  //---------------------------------------------------------------------------
  // Depth/Stencil -> Blender
  logic                           ds_o_valid, ds_o_ready, ds_o_pass;
  logic [15:0]                    ds_o_x, ds_o_y;
  logic [COLOR_WIDTH-1:0]         ds_o_r, ds_o_g, ds_o_b, ds_o_a;
  logic [3:0]                     ds_o_rt;
  // Blender -> Tile writeback
  logic                           bl_o_valid, bl_o_ready;
  logic [15:0]                    bl_o_x, bl_o_y;
  logic [COLOR_WIDTH-1:0]         bl_o_r[NUM_RENDER_TARGETS];
  logic [COLOR_WIDTH-1:0]         bl_o_g[NUM_RENDER_TARGETS];
  logic [COLOR_WIDTH-1:0]         bl_o_b[NUM_RENDER_TARGETS];
  logic [COLOR_WIDTH-1:0]         bl_o_a[NUM_RENDER_TARGETS];
  logic [3:0]                     bl_o_rt;

  // Backpressure
  assign frag_ready = ds_o_ready; // bubble through for now

  //---------------------------------------------------------------------------
  // Child: depth_stencil
  //---------------------------------------------------------------------------
  depth_stencil #(
    .DEPTH_WIDTH   (DEPTH_WIDTH),
    .STENCIL_WIDTH (STENCIL_WIDTH),
    .COLOR_WIDTH   (COLOR_WIDTH),
    .TILE_WIDTH    (TILE_WIDTH),
    .TILE_HEIGHT   (TILE_HEIGHT)
  ) u_depth_stencil (
    .clk              (clk),
    .rst_n            (rst_n),
    // rasterizer input
    .frag_valid_i     (frag_valid),
    .frag_ready_o     (ds_o_ready),
    .frag_x_i         (frag_x),
    .frag_y_i         (frag_y),
    .frag_depth_i     (frag_depth),
    .frag_stencil_i   (frag_stencil),
    .frag_r_i         (frag_color_r),
    .frag_g_i         (frag_color_g),
    .frag_b_i         (frag_color_b),
    .frag_a_i         (frag_color_a),
    .frag_rt_i        (frag_render_target),
    // early Z from rasterizer
    .early_z_kill_i   (early_z_kill),
    .early_z_valid_i  (early_z_valid),
    // config
    .cfg_i            (ds_cfg),
    // outputs to blender
    .frag_valid_o     (ds_o_valid),
    .frag_pass_o      (ds_o_pass),
    .frag_x_o         (ds_o_x),
    .frag_y_o         (ds_o_y),
    .frag_r_o         (ds_o_r),
    .frag_g_o         (ds_o_g),
    .frag_b_o         (ds_o_b),
    .frag_a_o         (ds_o_a),
    .frag_rt_o        (ds_o_rt)
  );

  //---------------------------------------------------------------------------
  // Child: blender (supports MRT)
  //---------------------------------------------------------------------------
  blender #(
    .COLOR_WIDTH        (COLOR_WIDTH),
    .NUM_RENDER_TARGETS (NUM_RENDER_TARGETS)
  ) u_blender (
    .clk              (clk),
    .rst_n            (rst_n),
    .frag_valid_i     (ds_o_valid & ds_o_pass),
    .frag_ready_o     (bl_o_ready),
    .frag_x_i         (ds_o_x),
    .frag_y_i         (ds_o_y),
    .frag_r_i         (ds_o_r),
    .frag_g_i         (ds_o_g),
    .frag_b_i         (ds_o_b),
    .frag_a_i         (ds_o_a),
    .frag_rt_i        (ds_o_rt),
    .cfg_i            (blend_cfg),
    .frag_valid_o     (bl_o_valid),
    .frag_x_o         (bl_o_x),
    .frag_y_o         (bl_o_y),
    .frag_r_o         (bl_o_r),
    .frag_g_o         (bl_o_g),
    .frag_b_o         (bl_o_b),
    .frag_a_o         (bl_o_a),
    .frag_rt_o        (bl_o_rt)
  );

  //---------------------------------------------------------------------------
  // Child: tile_writeback (AFBC capable)
  //---------------------------------------------------------------------------
  tile_writeback #(
    .COLOR_WIDTH        (COLOR_WIDTH),
    .TILE_WIDTH         (TILE_WIDTH),
    .TILE_HEIGHT        (TILE_HEIGHT),
    .NUM_RENDER_TARGETS (NUM_RENDER_TARGETS)
  ) u_tile_writeback (
    .clk               (clk),
    .rst_n             (rst_n),
    // from blender
    .frag_valid_i      (bl_o_valid),
    .frag_ready_o      (bl_o_ready),
    .frag_x_i          (bl_o_x),
    .frag_y_i          (bl_o_y),
    .frag_r_i          (bl_o_r),
    .frag_g_i          (bl_o_g),
    .frag_b_i          (bl_o_b),
    .frag_a_i          (bl_o_a),
    .frag_rt_i         (bl_o_rt),
    // tile/AFBC out
    .tile_valid_o      (tile_valid),
    .tile_ready_i      (tile_ready),
    .tile_x_o          (tile_x),
    .tile_y_o          (tile_y),
    .tile_rt_o         (tile_render_target),
    .tile_complete_o   (tile_complete),
    .tile_use_afbc_o   (tile_use_afbc),
    .tile_addr_o       (tile_addr),
    .tile_size_o       (tile_size),
    // DRAM burst
    .dram_write_req_o  (dram_write_req),
    .dram_write_ack_i  (dram_write_ack),
    .dram_write_addr_o (dram_write_addr),
    .dram_write_len_o  (dram_write_len),
    .dram_write_data_o (dram_write_data),
    .dram_write_last_o (dram_write_last)
  );

  //---------------------------------------------------------------------------
  // Basic counters and pipeline status (placeholder implementation)
  //---------------------------------------------------------------------------
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      pixel_count <= 0; tile_count <= 0;
    end else begin
      if (ds_o_valid & ds_o_pass & bl_o_ready) pixel_count <= pixel_count + 1;
      if (tile_valid & tile_ready & tile_complete) tile_count <= tile_count + 1;
    end
  end

  assign pipeline_busy  = frag_valid | ds_o_valid | bl_o_valid | tile_valid;
  assign pipeline_stall = frag_valid & ~frag_ready;
endmodule // pixel_backend
