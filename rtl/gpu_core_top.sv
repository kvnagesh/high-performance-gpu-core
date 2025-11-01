//==============================================================================
// Module: gpu_core_top
// Description: Top-level GPU core integration for high-performance mobile gaming
//              - 2 TFLOPs compute @ 2GHz
//              - Console-class rendering with ray tracing and VRS
//              - Optimized for power efficiency and mobile SoC integration
//==============================================================================

module gpu_core_top #(
    parameter integer NUM_SHADER_CORES  = 16,   // Configurable for scalability
    parameter integer NUM_TMUS          = 8,    // Texture mapping units
    parameter integer NUM_RAY_UNITS     = 4,    // Ray tracing acceleration units
    parameter integer CACHE_LINE_SIZE   = 128,  // bytes
    parameter integer L2_CACHE_SIZE     = 512   // KB
) (
    // Clock and reset
    input  logic clk_2GHz,
    input  logic rst_n,
    
    // Host interface (command processor)
    input  logic [63:0] host_cmd_data,
    input  logic        host_cmd_valid,
    output logic        host_cmd_ready,
    output logic [31:0] gpu_status,
    
    // Memory interface (LPDDR5/HBM)
    output logic [31:0]  mem_addr,
    output logic         mem_read_req,
    output logic         mem_write_req,
    inout  logic [255:0] mem_data,
    input  logic         mem_ready,
    
    // Power management
    output logic       power_down,
    input  logic [1:0] perf_mode,  // 00: Low, 01: Balanced, 10: High, 11: Turbo
    
    // Debug and monitoring
    output logic [31:0] debug_counters,
    output logic [7:0]  thermal_status
);

    // Internal signals
    logic [NUM_SHADER_CORES-1:0] shader_busy;
    logic [NUM_RAY_UNITS-1:0]    ray_unit_busy;
    logic                        cache_miss;
    logic [15:0]                 active_threads;
    
    //==========================================================================
    // Interconnect signals for instruction cache and memory
    //==========================================================================
    logic [31:0] icache_instr [NUM_SHADER_CORES];
    logic [NUM_SHADER_CORES-1:0] icache_valid;
    logic [NUM_SHADER_CORES-1:0] icache_ready;
    
    // Memory controller interconnect
    logic [31:0] mem_ctrl_addr;
    logic        mem_ctrl_read;
    logic        mem_ctrl_write;
    logic [255:0] mem_ctrl_wdata;
    logic [255:0] mem_ctrl_rdata;
    logic        mem_ctrl_ready;
    
    // TMU interconnect signals
    logic [NUM_TMUS-1:0]         tmu_req_valid;
    logic [NUM_TMUS-1:0]         tmu_req_ready;
    logic [31:0]                 tmu_addr [NUM_TMUS];
    logic [NUM_TMUS-1:0][127:0]  tmu_texel_out;
    logic [NUM_TMUS-1:0]         tmu_out_valid;
    
    // Rasterizer signals
    logic        rast_prim_valid;
    logic        rast_prim_ready;
    logic [15:0] rast_v0_x, rast_v0_y, rast_v1_x, rast_v1_y, rast_v2_x, rast_v2_y;
    logic        rast_frag_valid;
    logic        rast_frag_ready;
    logic [15:0] rast_frag_x, rast_frag_y;
    
    //==========================================================================
    // Shader Core Array - Main compute engines
    //==========================================================================
    
    // Power management signals
    logic [NUM_SHADER_CORES-1:0] shader_power_gate;  // Per-core power gating
    logic [NUM_RAY_UNITS-1:0]    ray_unit_power_gate;  // Per-RT unit power gating
    logic [NUM_TMUS-1:0]         tmu_power_gate;  // Per-TMU power gating
    logic [NUM_SHADER_CORES-1:0] shader_clk_gate;  // Per-core clock gating
    logic                        dvfs_voltage_req;  // Voltage scaling request
    logic [7:0]                  dvfs_freq_div;  // Frequency divider
    logic                        thermal_throttle;  // Thermal throttling active
    
    genvar i;
    generate
        for (i = 0; i < NUM_SHADER_CORES; i++) begin : shader_core_array
            shader_core #(
                .SIMD_WIDTH(32),
                .REG_FILE_SIZE(256)
            ) shader_inst (
                .clk(clk_2GHz),
                .rst_n(rst_n),
                .busy(shader_busy[i]),
                
                // Instruction interface - Connected to instruction cache
                .instruction(icache_instr[i]),
                .instr_valid(icache_valid[i]),
                .instr_ready(icache_ready[i]),
                
                // Power management
                .power_gate_en(!shader_power_gate[i]),  // Active low power gating
                .clk_gate_en(!shader_clk_gate[i]),      // Active low clock gating
                
                // Memory interface
                .mem_addr(),
                .mem_read(),
                .mem_write(),
                .mem_data(),
                
                // Status outputs
                .active_warps(),
                .inst_count(),
                .alu_utilization()
            );
        end
    endgenerate

    //==========================================================================
    // Ray Tracing Units - Hardware RT acceleration
    //==========================================================================
    generate
        for (i = 0; i < NUM_RAY_UNITS; i++) begin : ray_tracing_unit_array
            ray_tracing_unit ray_inst (
                .clk(clk_2GHz),
                .rst_n(rst_n),
                .busy(ray_unit_busy[i]),
                
                // Power management
                .power_gate_en(!ray_unit_power_gate[i])  // Active low power gating
            );
        end
    endgenerate

    //==========================================================================
    // Texture Management Units (TMUs)
    //==========================================================================
    generate
        for (i = 0; i < NUM_TMUS; i++) begin : tmu_array
            tmu_enhanced tmu_inst (
                .clk(clk_2GHz),
                .rst_n(rst_n),
                
                // Texture request interface
                .req_valid(tmu_req_valid[i]),
                .req_ready(tmu_req_ready[i]),
                .tex_addr(tmu_addr[i]),
                .tex_u(16'h0),  // U coordinate
                .tex_v(16'h0),  // V coordinate
                
                // Texture output interface
                .texel_out(tmu_texel_out[i]),
                .out_valid(tmu_out_valid[i]),
                .out_ready(1'b1),
                
                // Power management
                .power_gate_en(!tmu_power_gate[i])  // Active low power gating
            );
        end
    endgenerate

    //==========================================================================
    // Variable Rate Shading Unit
    //==========================================================================
    vrs_tier2_unit vrs_inst (
        .clk(clk_2GHz),
        .rst_n(rst_n)
    );

    //==========================================================================
    // Rasterizer Pipeline
    //==========================================================================
    rasterizer #(
        .COORD_W(16),
        .ATTR_W(128),
        .NUM_ATTR(16),
        .SUBPIX_BITS(4)
    ) raster_inst (
        .clk(clk_2GHz),
        .rst_n(rst_n),
        
        // Triangle input interface
        .prim_valid(rast_prim_valid),
        .prim_ready(rast_prim_ready),
        .v0_x(rast_v0_x), .v0_y(rast_v0_y),
        .v1_x(rast_v1_x), .v1_y(rast_v1_y),
        .v2_x(rast_v2_x), .v2_y(rast_v2_y),
        .v0_z(16'h0), .v0_w(16'h0),
        .v1_z(16'h0), .v1_w(16'h0),
        .v2_z(16'h0), .v2_w(16'h0),
        .v0_attr('{default: 128'h0}),
        .v1_attr('{default: 128'h0}),
        .v2_attr('{default: 128'h0}),
        
        // Fragment output interface
        .frag_valid(rast_frag_valid),
        .frag_ready(rast_frag_ready),
        .frag_x(rast_frag_x),
        .frag_y(rast_frag_y),
        .frag_z(),
        .frag_attr(),
        
        // Viewport and scissor configuration
        .vp_x(16'h0), .vp_y(16'h0), .vp_w(16'd1920), .vp_h(16'd1080),
        .sc_x(16'h0), .sc_y(16'h0), .sc_w(16'd1920), .sc_h(16'd1080),
        
        // Performance counters
        .perf_prims_in(),
        .perf_frags_out(),
        .perf_pixels_covered()
    );

    //==========================================================================
    // Cache Hierarchy (L0/L1/L2 unified)
    //==========================================================================
    cache_hierarchy #(
        .L2_SIZE(L2_CACHE_SIZE),
        .LINE_SIZE(CACHE_LINE_SIZE)
    ) cache_inst (
        .clk(clk_2GHz),
        .rst_n(rst_n),
        
        // Instruction cache interface
        .icache_req(icache_ready),
        .icache_addr('{default: 32'h0}),
        .icache_data(icache_instr),
        .icache_valid(icache_valid),
        
        // Data cache interface
        .dcache_req(1'b0),
        .dcache_addr(32'h0),
        .dcache_wdata(256'h0),
        .dcache_we(1'b0),
        .dcache_rdata(),
        .dcache_valid(),
        
        // L2 cache miss signal
        .cache_miss(cache_miss),
        
        // Memory controller interface
        .mem_req(),
        .mem_addr(),
        .mem_wdata(),
        .mem_we(),
        .mem_rdata(mem_ctrl_rdata),
        .mem_ready(mem_ctrl_ready)
    );

    //==========================================================================
    // Memory Controller
    //==========================================================================
    memory_controller mem_ctrl (
        .clk(clk_2GHz),
        .rst_n(rst_n),
        
        // Internal interface from cache
        .int_addr(mem_ctrl_addr),
        .int_read(mem_ctrl_read),
        .int_write(mem_ctrl_write),
        .int_wdata(mem_ctrl_wdata),
        .int_rdata(mem_ctrl_rdata),
        .int_ready(mem_ctrl_ready),
        
        // External memory interface (LPDDR5/HBM)
        .mem_addr(mem_addr),
        .mem_read_req(mem_read_req),
        .mem_write_req(mem_write_req),
        .mem_data(mem_data),
        .mem_ready(mem_ready)
    );

    //==========================================================================
    // Power Manager - Dynamic voltage/frequency scaling
    //==========================================================================
    dvfs_controller dvfs_inst (
        .clk(clk_2GHz),
        .rst_n(rst_n),
        .perf_mode(perf_mode),
        .power_down(power_down),
        .thermal_status(thermal_status),
        
        // Power gating outputs
        .shader_power_gate(shader_power_gate),
        .ray_unit_power_gate(ray_unit_power_gate),
        .tmu_power_gate(tmu_power_gate),
        .shader_clk_gate(shader_clk_gate),
        
        // DVFS control outputs
        .voltage_req(dvfs_voltage_req),
        .freq_divider(dvfs_freq_div),
        .thermal_throttle(thermal_throttle),
        
        // Utilization inputs for adaptive power management
        .shader_utilization(shader_busy),
        .ray_unit_utilization(ray_unit_busy)
    );

    //==========================================================================
    // Status and monitoring
    //==========================================================================
    always_ff @(posedge clk_2GHz or negedge rst_n) begin
        if (!rst_n) begin
            gpu_status      <= 32'h0;
            debug_counters  <= 32'h0;
        end else begin
            // Aggregate status from all units
            gpu_status[NUM_SHADER_CORES-1:0] <= shader_busy;
            gpu_status[16]                    <= |ray_unit_busy;  // Any RT unit active
            gpu_status[17]                    <= cache_miss;
            gpu_status[31:18]                 <= active_threads[13:0];
        end
    end

endmodule
