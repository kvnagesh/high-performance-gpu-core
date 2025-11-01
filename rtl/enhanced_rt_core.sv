// Enhanced Ray Tracing Core (multi-ray, coherence-optimized)
module enhanced_rt_core (
    input  logic        clk,
    input  logic        rst_n,

    // Control
    input  logic        rt_enable,
    input  logic [3:0]  rays_per_cycle_cfg, // 8..16 suggested

    // Ray input
    input  logic        ray_valid,
    input  logic [255:0] ray_data,     // org, dir, tmin,tmax, mask
    output logic        ray_ready,

    // BVH memory interface (read-only accelerator SRAM/L2)
    output logic        bvh_req,
    output logic [63:0] bvh_addr,
    input  logic [511:0] bvh_data,
    input  logic        bvh_valid,

    // Triangle/Box accelerator
    output logic        tri_test_req,
    output logic [511:0] tri_test_data,
    input  logic        tri_test_done,
    input  logic [31:0] tri_hit_mask,

    // Hit output
    output logic        hit_valid,
    output logic [127:0] hit_data,
    input  logic        hit_ready,

    // Perf
    output logic [31:0] perf_rays_in,
    output logic [31:0] perf_rays_tested,
    output logic [31:0] perf_hits
);

    // Coherence-optimized ray packetizer (group rays by direction quadrant)
    typedef struct packed {logic [255:0] ray; logic [3:0] quad;} ray_t;
    ray_t in_fifo [0:63];
    logic [5:0] in_wr, in_rd; logic in_full, in_empty;

    assign in_full = (in_wr+1)==in_rd; assign in_empty = in_wr==in_rd;
    assign ray_ready = !in_full;

    function automatic [3:0] quadrant(input [255:0] r);
        quadrant = {r[128], r[129], r[130], r[131]}; // sign bits of dir xyz + w
    endfunction

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin in_wr<=0; in_rd<=0; perf_rays_in<=0; end
        else begin
            if (ray_valid && !in_full) begin
                in_fifo[in_wr].ray <= ray_data;
                in_fifo[in_wr].quad <= quadrant(ray_data);
                in_wr <= in_wr+1; perf_rays_in <= perf_rays_in + 1'b1;
            end
        end
    end

    // Simple scheduler: issue up to rays_per_cycle_cfg rays with same quadrant
    ray_t issue_buf [0:15]; logic [3:0] issue_count;

    task automatic schedule_rays;
        logic [3:0] q; integer i;
        begin
            issue_count = 0; q = in_fifo[in_rd].quad;
            for (i=0; i<16; i++) begin
                if (!in_empty && issue_count < rays_per_cycle_cfg && in_fifo[in_rd].quad==q) begin
                    issue_buf[issue_count] = in_fifo[in_rd];
                    in_rd <= in_rd + 1; issue_count++;
                end
            end
        end
    endtask

    // BVH traversal state (high-level placeholder)
    typedef enum logic [1:0] {IDLE, FETCH_NODE, TEST_NODE, EMIT_HIT} state_t;
    state_t state;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= IDLE; bvh_req<=0; tri_test_req<=0; hit_valid<=0;
            perf_rays_tested<=0; perf_hits<=0;
        end else begin
            hit_valid<=0; tri_test_req<=0; bvh_req<=0;
            case (state)
                IDLE: if (rt_enable && !in_empty) begin schedule_rays(); state<=FETCH_NODE; end
                FETCH_NODE: begin bvh_req<=1; bvh_addr<=64'h0; if (bvh_valid) state<=TEST_NODE; end
                TEST_NODE: begin
                    tri_test_req<=1; tri_test_data<=bvh_data; if (tri_test_done) begin
                        perf_rays_tested <= perf_rays_tested + issue_count;
                        if (|tri_hit_mask) begin
                            hit_valid<=1; hit_data<= {96'h0, tri_hit_mask[31:0]};
                            if (hit_ready) begin perf_hits<=perf_hits+1; state<=IDLE; end
                        end else state<=IDLE;
                    end
                end
            endcase
        end
    end

        //==========================================================================
    // BVH Cache for Coherent Access (ARM G720 Enhancement)
    //==========================================================================
    
    // 4KB BVH cache (32 entries × 128 bytes)
    logic [1023:0] bvh_cache [0:31];  // 128 bytes per entry
    logic [4:0]    bvh_cache_tag [0:31];
    logic          bvh_cache_valid [0:31];
    logic [31:0]   bvh_cache_hits, bvh_cache_misses;
    
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int i = 0; i < 32; i++) bvh_cache_valid[i] <= 1'b0;
            bvh_cache_hits <= 32'h0;
            bvh_cache_misses <= 32'h0;
        end else if (bvh_req) begin
            // Check cache hit
            logic [4:0] cache_idx = bvh_addr[9:5];
            logic [4:0] cache_tag = bvh_addr[14:10];
            
            if (bvh_cache_valid[cache_idx] && bvh_cache_tag[cache_idx] == cache_tag) begin
                // Cache hit
                bvh_cache_hits <= bvh_cache_hits + 1'b1;
            end else begin
                // Cache miss - fetch from memory
                bvh_cache_misses <= bvh_cache_misses + 1'b1;
                if (bvh_valid) begin
                    bvh_cache[cache_idx] <= bvh_data;
                    bvh_cache_tag[cache_idx] <= cache_tag;
                    bvh_cache_valid[cache_idx] <= 1'b1;
                end
            end
        end
    end
    
    //==========================================================================
    // Ray Sorting by Direction for Better Coherency
    //==========================================================================
    
    // Enhanced 16-quadrant sorting (finer granularity)
    function automatic [3:0] direction_bucket(input [255:0] ray);
        logic [31:0] dx, dy, dz;
        dx = ray[127:96];   // Direction X
        dy = ray[159:128];  // Direction Y
        dz = ray[191:160];  // Direction Z
        
        // 16 buckets based on dominant axis and signs
        logic [1:0] dominant_axis;
        if ($abs(dx) > $abs(dy) && $abs(dx) > $abs(dz))
            dominant_axis = 2'b00;  // X-dominant
        else if ($abs(dy) > $abs(dz))
            dominant_axis = 2'b01;  // Y-dominant
        else
            dominant_axis = 2'b10;  // Z-dominant
            
        direction_bucket = {dominant_axis, dx[31], dy[31]};
    endfunction
    
    // Ray sorting buffer (16 buckets)
    ray_t ray_buckets [0:15][0:3];  // 16 buckets × 4 rays each
    logic [1:0] bucket_count [0:15];
    
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int i = 0; i < 16; i++) bucket_count[i] <= 2'h0;
        end else if (ray_valid && !in_full) begin
            logic [3:0] bucket = direction_bucket(ray_data);
            if (bucket_count[bucket] < 2'd3) begin
                ray_buckets[bucket][bucket_count[bucket]].ray <= ray_data;
                ray_buckets[bucket][bucket_count[bucket]].quad <= bucket;
                bucket_count[bucket] <= bucket_count[bucket] + 1'b1;
            end
        end
    end
    
    //==========================================================================
    // Multi-Ray SIMD Processing (8-16 rays simultaneously)
    //==========================================================================
    
    // SIMD ray-box intersection (process 16 rays in parallel)
    logic [15:0] simd_ray_active;
    logic [15:0] simd_ray_hit;
    logic [255:0] simd_rays [0:15];
    
    always_comb begin
        simd_ray_active = 16'h0;
        simd_ray_hit = 16'h0;
        
        // Load up to 16 rays from issue buffer
        for (int i = 0; i < 16; i++) begin
            if (i < issue_count) begin
                simd_rays[i] = issue_buf[i].ray;
                simd_ray_active[i] = 1'b1;
            end
        end
        
        // Parallel ray-box intersection (simplified)
        for (int i = 0; i < 16; i++) begin
            if (simd_ray_active[i]) begin
                // Placeholder: Real implementation would do AABB test
                simd_ray_hit[i] = simd_rays[i][0];  // Simplified
            end
        end
    end
    
    //==========================================================================
    // Prefetch Logic for BVH Nodes
    //==========================================================================
    
    logic [63:0] prefetch_addr_queue [0:3];
    logic [1:0]  prefetch_queue_wr, prefetch_queue_rd;
    logic        prefetch_active;
    
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            prefetch_queue_wr <= 2'h0;
            prefetch_queue_rd <= 2'h0;
            prefetch_active <= 1'b0;
        end else begin
            // Prefetch next probable BVH nodes based on ray direction
            if (state == TEST_NODE && issue_count > 0) begin
                // Predict next node addresses
                prefetch_addr_queue[prefetch_queue_wr] <= bvh_addr + 64'h40;
                prefetch_queue_wr <= prefetch_queue_wr + 1'b1;
                prefetch_active <= 1'b1;
            end
        end
    end
    
    //==========================================================================
    // Performance Statistics
    //==========================================================================
    
    logic [31:0] perf_coherent_groups;  // Number of coherent ray groups processed
    logic [31:0] perf_cache_hit_rate;   // BVH cache hit rate percentage
    
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            perf_coherent_groups <= 32'h0;
        end else if (state == IDLE && issue_count > 1) begin
            perf_coherent_groups <= perf_coherent_groups + 1'b1;
        end
    end
    
    // Calculate cache hit rate
    always_comb begin
        logic [31:0] total_accesses = bvh_cache_hits + bvh_cache_misses;
        if (total_accesses > 32'h0)
            perf_cache_hit_rate = (bvh_cache_hits * 32'd100) / total_accesses;
        else
            perf_cache_hit_rate = 32'h0;
    end

endmodule
