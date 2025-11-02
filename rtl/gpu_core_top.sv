// Insert Pixel Backend between rasterizer and AFBC/tile writeback
// Declarations for connections
  // Fragment signals from rasterizer
  logic        pb_frag_valid;
  logic        pb_frag_ready;
  logic [127:0] pb_frag_data;
  logic [15:0]  pb_frag_x, pb_frag_y;
  logic [31:0]  pb_frag_depth;
  logic [7:0]   pb_frag_stencil;
  logic [31:0]  pb_frag_r, pb_frag_g, pb_frag_b, pb_frag_a;
  logic [3:0]   pb_frag_rt;
  logic         pb_early_z_kill, pb_early_z_valid;

  // Tile/DRAM interface
  logic         pb_tile_valid, pb_tile_ready;
  logic [15:0]  pb_tile_x, pb_tile_y;
  logic [3:0]   pb_tile_rt;
  logic         pb_tile_complete, pb_tile_use_afbc;
  logic [63:0]  pb_tile_addr;
  logic [31:0]  pb_tile_size;
  logic         pb_dram_wr_req, pb_dram_wr_ack;
  logic [63:0]  pb_dram_addr;
  logic [31:0]  pb_dram_len;
  logic [255:0] pb_dram_wdata;
  logic         pb_dram_last;

  // Simple mapping from rasterizer for now
  assign pb_frag_valid   = rast_frag_valid;
  assign rast_frag_ready = pb_frag_ready;
  assign pb_frag_x       = rast_frag_x;
  assign pb_frag_y       = rast_frag_y;
  assign pb_frag_depth   = 32'(0);
  assign pb_frag_stencil = 8'(0);
  assign pb_frag_r       = 32'(0);
  assign pb_frag_g       = 32'(0);
  assign pb_frag_b       = 32'(0);
  assign pb_frag_a       = 32'hFFFF_FFFF; // opaque
  assign pb_frag_rt      = 4'(0);
  assign pb_early_z_kill = 1'b0;
  assign pb_early_z_valid= 1'b0;

  // Configuration CSR passthrough (tie-off here; hook to host later)
  logic pb_reg_we, pb_reg_re; logic [15:0] pb_reg_addr; logic [31:0] pb_reg_wdata, pb_reg_rdata; logic pb_reg_rvalid;
  assign pb_reg_we=1'b0; assign pb_reg_re=1'b0; assign pb_reg_addr='0; assign pb_reg_wdata='0;

  // Instantiate pixel backend
  pixel_backend #(
    .FRAG_DATA_WIDTH (128),
    .DEPTH_WIDTH     (32),
    .STENCIL_WIDTH   (8),
    .COLOR_WIDTH     (32),
    .NUM_RENDER_TARGETS(4),
    .TILE_WIDTH      (16),
    .TILE_HEIGHT     (16),
    .REG_ADDR_WIDTH  (16),
    .REG_DATA_WIDTH  (32)
  ) u_pixel_backend (
    .clk               (clk_2GHz),
    .rst_n             (rst_n),
    .frag_valid        (pb_frag_valid),
    .frag_ready        (pb_frag_ready),
    .frag_data         (pb_frag_data),
    .frag_x            (pb_frag_x),
    .frag_y            (pb_frag_y),
    .frag_depth        (pb_frag_depth),
    .frag_stencil      (pb_frag_stencil),
    .frag_color_r      (pb_frag_r),
    .frag_color_g      (pb_frag_g),
    .frag_color_b      (pb_frag_b),
    .frag_color_a      (pb_frag_a),
    .frag_render_target(pb_frag_rt),
    .early_z_kill      (pb_early_z_kill),
    .early_z_valid     (pb_early_z_valid),
    .reg_write_en      (pb_reg_we),
    .reg_write_addr    (pb_reg_addr),
    .reg_write_data    (pb_reg_wdata),
    .reg_read_en       (pb_reg_re),
    .reg_read_addr     (pb_reg_addr),
    .reg_read_data     (pb_reg_rdata),
    .reg_read_valid    (pb_reg_rvalid),
    .tile_valid        (pb_tile_valid),
    .tile_ready        (pb_tile_ready),
    .tile_x            (pb_tile_x),
    .tile_y            (pb_tile_y),
    .tile_render_target(pb_tile_rt),
    .tile_complete     (pb_tile_complete),
    .tile_use_afbc     (pb_tile_use_afbc),
    .tile_addr         (pb_tile_addr),
    .tile_size         (pb_tile_size),
    .dram_write_req    (pb_dram_wr_req),
    .dram_write_ack    (pb_dram_wr_ack),
    .dram_write_addr   (pb_dram_addr),
    .dram_write_len    (pb_dram_len),
    .dram_write_data   (pb_dram_wdata),
    .dram_write_last   (pb_dram_last),
    .pixel_count       (),
    .tile_count        (),
    .pipeline_busy     (),
    .pipeline_stall    ()
  );

  // Connect tile writeback to memory controller stub (tie-offs for now)
  assign pb_tile_ready  = 1'b1;
  assign pb_dram_wr_ack = mem_ready;
  // Example DRAM address passthrough
  assign mem_write_req  = pb_dram_wr_req;
  assign mem_addr       = pb_dram_addr[31:0];
  assign mem_data       = pb_dram_wdata;
