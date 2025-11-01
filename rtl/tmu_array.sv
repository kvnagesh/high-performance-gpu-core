//==============================================================================
// Module: tmu_array
// Description: 16-TMU array with ASTC/AFRC compression support
// Features: Round-robin scheduling, texture cache, compression decode
//==============================================================================

module tmu_array (
    input logic clk,
    input logic rst_n,
    
    // Request interface from shader cores
    input logic [15:0] req_valid,          // 16 possible requesters
    input logic [15:0][31:0] req_u,        // U coordinates
    input logic [15:0][31:0] req_v,        // V coordinates
    input logic [15:0][3:0] req_lod,       // Level of detail
    input logic [15:0][7:0] req_format,    // Texture format
    output logic [15:0] req_ready,
    
    // Response interface
    output logic [15:0] rsp_valid,
    output logic [15:0][127:0] rsp_data,   // RGBA filtered sample
    input logic [15:0] rsp_ready,
    
    // Texture memory interface
    output logic [15:0] tex_req,
    output logic [15:0][31:0] tex_addr,
    input logic [15:0] tex_valid,
    input logic [15:0][511:0] tex_data,    // 64-byte cache line
    
    // Power management
    input logic power_gate_en,
    
    // Performance counters
    output logic [31:0] perf_requests,
    output logic [31:0] perf_cache_hits
);

    //==========================================================================
    // Parameters
    //==========================================================================
    localparam NUM_TMUS = 16;
    localparam CACHE_ENTRIES = 64;         // Per-TMU cache
    localparam ASTC_BLOCK_SIZE = 128;      // bits
    localparam AFRC_BLOCK_SIZE = 128;      // bits
    
    //==========================================================================
    // Texture Format Definitions
    //==========================================================================
    typedef enum logic [7:0] {
        FMT_RGBA8     = 8'h00,
        FMT_RGBA16F   = 8'h01,
        FMT_RGBA32F   = 8'h02,
        FMT_RGB565    = 8'h03,
        FMT_RGBA4     = 8'h04,
        FMT_ASTC_4x4  = 8'h10,             // ASTC 4x4 block
        FMT_ASTC_5x5  = 8'h11,
        FMT_ASTC_6x6  = 8'h12,
        FMT_ASTC_8x8  = 8'h13,
        FMT_AFRC_4x4  = 8'h20,             // AFRC 4x4 block
        FMT_AFRC_8x8  = 8'h21,
        FMT_BC1       = 8'h30,             // Legacy S3TC/DXT
        FMT_BC3       = 8'h31
    } tex_format_t;
    
    //==========================================================================
    // Round-Robin Arbiter for Request Distribution
    //==========================================================================
    logic [3:0] rr_pointer;                // Current TMU pointer
    logic [15:0][3:0] req_to_tmu;          // Which TMU handles each request
    logic [15:0][15:0] tmu_req_valid;      // Per-TMU request valid
    
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rr_pointer <= 4'h0;
        end else begin
            if (|req_valid) begin
                rr_pointer <= (rr_pointer + 1'b1) % NUM_TMUS;
            end
        end
    end
    
    // Assign requests to TMUs in round-robin fashion
    always_comb begin
        for (int i = 0; i < 16; i++) begin
            req_to_tmu[i] = (rr_pointer + i) % NUM_TMUS;
            for (int t = 0; t < NUM_TMUS; t++) begin
                tmu_req_valid[i][t] = req_valid[i] && (req_to_tmu[i] == t);
            end
        end
    end
    
    //==========================================================================
    // TMU Instances (16 independent texture units)
    //==========================================================================
    genvar tmu_id;
    generate
        for (tmu_id = 0; tmu_id < NUM_TMUS; tmu_id++) begin : tmu_gen
            
            // Per-TMU signals
            logic tmu_req_v;
            logic [31:0] tmu_u, tmu_v;
            logic [3:0] tmu_lod;
            logic [7:0] tmu_format;
            logic tmu_rsp_v;
            logic [127:0] tmu_rsp_data;
            
            // Texture cache
            logic [511:0] cache_data [CACHE_ENTRIES];
            logic [31:0] cache_tag [CACHE_ENTRIES];
            logic [CACHE_ENTRIES-1:0] cache_valid;
            
            // Request selection (priority encoder for this TMU)
            always_comb begin
                tmu_req_v = 1'b0;
                tmu_u = 32'h0;
                tmu_v = 32'h0;
                tmu_lod = 4'h0;
                tmu_format = 8'h0;
                
                for (int i = 0; i < 16; i++) begin
                    if (tmu_req_valid[i][tmu_id]) begin
                        tmu_req_v = 1'b1;
                        tmu_u = req_u[i];
                        tmu_v = req_v[i];
                        tmu_lod = req_lod[i];
                        tmu_format = req_format[i];
                        break;
                    end
                end
            end
            
            //==================================================================
            // Texture Sampler Core
            //==================================================================
            logic [31:0] tex_address;
            logic cache_hit;
            logic [5:0] cache_idx;
            logic [511:0] tex_line;
            
            // Address calculation (simplified)
            assign tex_address = {tmu_u[31:6], tmu_v[31:6], tmu_lod, 2'b00};
            
            // Cache lookup
            always_comb begin
                cache_hit = 1'b0;
                cache_idx = 6'h0;
                tex_line = 512'h0;
                
                for (int c = 0; c < CACHE_ENTRIES; c++) begin
                    if (cache_valid[c] && (cache_tag[c] == tex_address)) begin
                        cache_hit = 1'b1;
                        cache_idx = c[5:0];
                        tex_line = cache_data[c];
                        break;
                    end
                end
            end
            
            // Issue texture memory request on cache miss
            assign tex_req[tmu_id] = tmu_req_v && !cache_hit;
            assign tex_addr[tmu_id] = tex_address;
            
            // Update cache on memory response
            always_ff @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    cache_valid <= {CACHE_ENTRIES{1'b0}};
                end else begin
                    if (tex_valid[tmu_id]) begin
                        cache_data[cache_idx] <= tex_data[tmu_id];
                        cache_tag[cache_idx] <= tex_address;
                        cache_valid[cache_idx] <= 1'b1;
                    end
                end
            end
            
            //==================================================================
            // Compression Decoder (ASTC/AFRC)
            //==================================================================
            logic is_compressed;
            logic [127:0] compressed_block;
            logic [127:0] decompressed_rgba;
            
            assign is_compressed = (tmu_format >= FMT_ASTC_4x4) && (tmu_format <= FMT_AFRC_8x8);
            assign compressed_block = tex_line[127:0];
            
            // ASTC Decoder (simplified endpoint interpolation)
            always_comb begin
                if (tmu_format >= FMT_ASTC_4x4 && tmu_format <= FMT_ASTC_8x8) begin
                    // ASTC endpoint extraction and weight interpolation
                    logic [31:0] endpoint0, endpoint1;
                    logic [5:0] weight;
                    
                    endpoint0 = compressed_block[31:0];
                    endpoint1 = compressed_block[63:32];
                    weight = compressed_block[69:64];
                    
                    // Linear interpolation
                    decompressed_rgba[31:0]   = endpoint0 + ((endpoint1 - endpoint0) * weight) / 64;
                    decompressed_rgba[63:32]  = endpoint0 + ((endpoint1 - endpoint0) * weight) / 64;
                    decompressed_rgba[95:64]  = endpoint0 + ((endpoint1 - endpoint0) * weight) / 64;
                    decompressed_rgba[127:96] = 32'hFFFFFFFF; // Alpha = 1.0
                end else if (tmu_format >= FMT_AFRC_4x4 && tmu_format <= FMT_AFRC_8x8) begin
                    // AFRC decompression (gradient-based reconstruction)
                    logic [31:0] base_color;
                    logic [7:0] gradient_x, gradient_y;
                    
                    base_color = compressed_block[31:0];
                    gradient_x = compressed_block[39:32];
                    gradient_y = compressed_block[47:40];
                    
                    // Reconstruct color with gradients
                    decompressed_rgba[31:0]   = base_color + {gradient_x, gradient_y, 16'h0};
                    decompressed_rgba[63:32]  = base_color;
                    decompressed_rgba[95:64]  = base_color - {gradient_x, gradient_y, 16'h0};
                    decompressed_rgba[127:96] = 32'hFFFFFFFF;
                end else begin
                    // Uncompressed format - direct fetch
                    decompressed_rgba = tex_line[127:0];
                end
            end
            
            //==================================================================
            // Bilinear Filtering
            //==================================================================
            logic [127:0] filtered_sample;
            logic [1:0] frac_u, frac_v;
            
            assign frac_u = tmu_u[1:0];
            assign frac_v = tmu_v[1:0];
            
            // Simplified bilinear interpolation
            always_comb begin
                // Weight calculation
                logic [3:0] w00, w01, w10, w11;
                w00 = (4 - frac_u) * (4 - frac_v);
                w01 = (4 - frac_u) * frac_v;
                w10 = frac_u * (4 - frac_v);
                w11 = frac_u * frac_v;
                
                // Weighted sum (simplified for one texel)
                filtered_sample = (decompressed_rgba * w00) / 16;
            end
            
            //==================================================================
            // TMU Response
            //==================================================================
            always_ff @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    tmu_rsp_v <= 1'b0;
                    tmu_rsp_data <= 128'h0;
                end else begin
                    if (tmu_req_v && (cache_hit || tex_valid[tmu_id])) begin
                        tmu_rsp_v <= 1'b1;
                        tmu_rsp_data <= filtered_sample;
                    end else if (rsp_ready[tmu_id]) begin
                        tmu_rsp_v <= 1'b0;
                    end
                end
            end
            
            // Connect to output arrays
            assign rsp_valid[tmu_id] = tmu_rsp_v;
            assign rsp_data[tmu_id] = tmu_rsp_data;
            assign req_ready[tmu_id] = !tmu_req_v || cache_hit;
        end
    endgenerate
    
    //==========================================================================
    // Performance Counters
    //==========================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            perf_requests <= 32'h0;
            perf_cache_hits <= 32'h0;
        end else begin
            if (|req_valid) begin
                perf_requests <= perf_requests + 1'b1;
            end
            // Count cache hits across all TMUs
            for (int t = 0; t < NUM_TMUS; t++) begin
                if (tmu_gen[t].cache_hit) begin
                    perf_cache_hits <= perf_cache_hits + 1'b1;
                end
            end
        end
    end
    
endmodule
