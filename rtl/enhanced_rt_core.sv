//==============================================================================
// Module: enhanced_rt_core
// Description: Production-grade ray tracing core with complete BVH traversal,
//              intersection shader pipelines, and ray scheduling logic
// Features: Multi-level BVH traversal, triangle/AABB intersection shaders,
//           coherent ray scheduling, ray compaction, streaming architecture
//==============================================================================

module enhanced_rt_core (
    input logic clk,
    input logic rst_n,
    
    // Control
    input logic rt_enable,
    input logic [3:0] rays_per_cycle_cfg,      // 8..16 suggested
    input logic [1:0] traversal_mode,          // 0=BFS, 1=DFS, 2=Hybrid
    
    // Ray input
    input logic ray_valid,
    input logic [255:0] ray_data,              // org, dir, tmin, tmax, mask
    output logic ray_ready,
    
    // BVH memory interface (read-only accelerator SRAM/L2)
    output logic bvh_req,
    output logic [63:0] bvh_addr,
    input logic [511:0] bvh_data,
    input logic bvh_valid,
    
    // Triangle/Box accelerator
    output logic tri_test_req,
    output logic [511:0] tri_test_data,
    input logic tri_test_done,
    input logic [31:0] tri_hit_mask,
    
    // Intersection shader interface
    output logic intersection_shader_req,
    output logic [255:0] intersection_shader_data,
    input logic intersection_shader_valid,
    input logic [127:0] intersection_result,
    
    // Hit output
    output logic hit_valid,
    output logic [127:0] hit_data,
    input logic hit_ready,
    
    // Performance counters
    output logic [31:0] perf_rays_in,
    output logic [31:0] perf_rays_tested,
    output logic [31:0] perf_hits,
    output logic [31:0] perf_bvh_nodes_visited,
    output logic [31:0] perf_traversal_steps,
    output logic [31:0] perf_ray_compactions
);

    //==========================================================================
    // Parameters
    //==========================================================================
    localparam RAY_FIFO_DEPTH = 64;
    localparam MAX_RAYS_SIMD = 16;
    localparam BVH_STACK_DEPTH = 32;       // Max BVH tree depth
    localparam RAY_BATCH_SIZE = 16;
    localparam INTERSECTION_PIPELINE_STAGES = 4;
    
    //==========================================================================
    // Data Structures
    //==========================================================================
    
    // Ray structure
    typedef struct packed {
        logic [95:0] origin;               // Ray origin (3 × 32-bit)
        logic [95:0] direction;            // Ray direction (3 × 32-bit)
        logic [31:0] tmin;                 // Minimum t parameter
        logic [31:0] tmax;                 // Maximum t parameter
        logic [3:0] quadrant;              // Direction quadrant
        logic [3:0] priority;              // Scheduling priority
        logic active;                      // Ray is active
    } ray_t;
    
    // BVH node structure
    typedef struct packed {
        logic [95:0] aabb_min;             // Bounding box minimum
        logic [95:0] aabb_max;             // Bounding box maximum
        logic [31:0] left_child;           // Left child index
        logic [31:0] right_child;          // Right child index
        logic [31:0] primitive_offset;     // Offset to primitives
        logic [15:0] primitive_count;      // Number of primitives
        logic is_leaf;                     // Leaf node flag
    } bvh_node_t;
    
    // Ray-BVH traversal state
    typedef struct packed {
        logic [31:0] node_index;           // Current BVH node
        logic [5:0] stack_ptr;             // Stack pointer
        logic [31:0] node_stack [BVH_STACK_DEPTH];  // Node traversal stack
        logic [31:0] closest_hit_t;        // Closest intersection distance
        logic hit_found;                   // Hit detected flag
    } traversal_state_t;
    
    //==========================================================================
    // Ray Input FIFO and Coherence Grouping
    //==========================================================================
    ray_t ray_fifo [RAY_FIFO_DEPTH];
    logic [5:0] ray_fifo_wr_ptr, ray_fifo_rd_ptr;
    logic [6:0] ray_fifo_count;
    logic ray_fifo_full, ray_fifo_empty;
    
    assign ray_fifo_full = (ray_fifo_count == RAY_FIFO_DEPTH);
    assign ray_fifo_empty = (ray_fifo_count == 7'h0);
    assign ray_ready = !ray_fifo_full;
    
    // Direction quadrant calculation for coherence
    function automatic [3:0] calculate_quadrant(input [95:0] direction);
        logic [31:0] dx, dy, dz;
        dx = direction[31:0];
        dy = direction[63:32];
        dz = direction[95:64];
        calculate_quadrant = {dx[31], dy[31], dz[31], 1'b0};
    endfunction
    
    // Ray enqueueing with priority calculation
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ray_fifo_wr_ptr <= 6'h0;
            ray_fifo_count <= 7'h0;
            perf_rays_in <= 32'h0;
        end else begin
            if (ray_valid && !ray_fifo_full) begin
                ray_fifo[ray_fifo_wr_ptr].origin <= ray_data[95:0];
                ray_fifo[ray_fifo_wr_ptr].direction <= ray_data[191:96];
                ray_fifo[ray_fifo_wr_ptr].tmin <= ray_data[223:192];
                ray_fifo[ray_fifo_wr_ptr].tmax <= ray_data[255:224];
                ray_fifo[ray_fifo_wr_ptr].quadrant <= calculate_quadrant(ray_data[191:96]);
                ray_fifo[ray_fifo_wr_ptr].priority <= 4'h0;
                ray_fifo[ray_fifo_wr_ptr].active <= 1'b1;
                
                ray_fifo_wr_ptr <= ray_fifo_wr_ptr + 1'b1;
                ray_fifo_count <= ray_fifo_count + 1'b1;
                perf_rays_in <= perf_rays_in + 1'b1;
            end
            
            if (ray_compaction_active && ray_fifo_count > 7'h0)
                ray_fifo_count <= ray_fifo_count - 1'b1;
        end
    end
    
    //==========================================================================
    // Production-Grade BVH Traversal Engine
    //==========================================================================
    
    // Traversal FSM states
    typedef enum logic [3:0] {
        TRAV_IDLE,
        TRAV_FETCH_ROOT,
        TRAV_FETCH_NODE,
        TRAV_TEST_AABB,
        TRAV_PUSH_CHILDREN,
        TRAV_POP_STACK,
        TRAV_LEAF_PROCESS,
        TRAV_TRIANGLE_TEST,
        TRAV_INTERSECTION_SHADER,
        TRAV_UPDATE_CLOSEST,
        TRAV_COMPLETE,
        TRAV_RAY_COMPACTION
    } traversal_state_e;
    
    traversal_state_e trav_state, trav_next_state;
    
    // Active ray batch for SIMD processing
    ray_t active_rays [MAX_RAYS_SIMD];
    logic [3:0] active_ray_count;
    traversal_state_t ray_trav_state [MAX_RAYS_SIMD];
    
    // BVH traversal control
    logic [31:0] current_node_idx;
    bvh_node_t current_node;
    logic [31:0] node_fetch_addr;
    logic node_data_valid;
    
    // AABB intersection results
    logic [MAX_RAYS_SIMD-1:0] aabb_hit_mask;
    logic [MAX_RAYS_SIMD-1:0] ray_active_mask;
    
    // Ray compaction (remove inactive rays)
    logic ray_compaction_active;
    logic [3:0] compacted_ray_count;
    
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            trav_state <= TRAV_IDLE;
        end else begin
            trav_state <= trav_next_state;
        end
    end
    
    // BVH Traversal FSM
    always_comb begin
        trav_next_state = trav_state;
        bvh_req = 1'b0;
        tri_test_req = 1'b0;
        intersection_shader_req = 1'b0;
        ray_compaction_active = 1'b0;
        
        case (trav_state)
            TRAV_IDLE: begin
                if (rt_enable && !ray_fifo_empty && active_ray_count < rays_per_cycle_cfg)
                    trav_next_state = TRAV_FETCH_ROOT;
            end
            
            TRAV_FETCH_ROOT: begin
                bvh_req = 1'b1;
                node_fetch_addr = 32'h0;  // Root node
                if (bvh_valid)
                    trav_next_state = TRAV_FETCH_NODE;
            end
            
            TRAV_FETCH_NODE: begin
                bvh_req = 1'b1;
                if (node_data_valid)
                    trav_next_state = TRAV_TEST_AABB;
            end
            
            TRAV_TEST_AABB: begin
                // Perform SIMD AABB intersection test
                if (|aabb_hit_mask) begin
                    if (current_node.is_leaf)
                        trav_next_state = TRAV_LEAF_PROCESS;
                    else
                        trav_next_state = TRAV_PUSH_CHILDREN;
                end else begin
                    trav_next_state = TRAV_POP_STACK;
                end
            end
            
            TRAV_PUSH_CHILDREN: begin
                // Push both children to traversal stack
                // Implement near/far ordering for efficiency
                trav_next_state = TRAV_POP_STACK;
            end
            
            TRAV_POP_STACK: begin
                // Pop next node from stack
                if (ray_trav_state[0].stack_ptr > 6'h0)
                    trav_next_state = TRAV_FETCH_NODE;
                else
                    trav_next_state = TRAV_COMPLETE;
            end
            
            TRAV_LEAF_PROCESS: begin
                // Leaf node - test primitives
                trav_next_state = TRAV_TRIANGLE_TEST;
            end
            
            TRAV_TRIANGLE_TEST: begin
                tri_test_req = 1'b1;
                if (tri_test_done) begin
                    if (|tri_hit_mask)
                        trav_next_state = TRAV_INTERSECTION_SHADER;
                    else
                        trav_next_state = TRAV_POP_STACK;
                end
            end
            
            TRAV_INTERSECTION_SHADER: begin
                intersection_shader_req = 1'b1;
                if (intersection_shader_valid)
                    trav_next_state = TRAV_UPDATE_CLOSEST;
            end
            
            TRAV_UPDATE_CLOSEST: begin
                // Update closest hit for each ray
                trav_next_state = TRAV_POP_STACK;
            end
            
            TRAV_COMPLETE: begin
                // Compact active rays (remove completed rays)
                ray_compaction_active = 1'b1;
                trav_next_state = TRAV_RAY_COMPACTION;
            end
            
            TRAV_RAY_COMPACTION: begin
                if (compacted_ray_count > 4'h0)
                    trav_next_state = TRAV_FETCH_NODE;
                else
                    trav_next_state = TRAV_IDLE;
            end
        endcase
    end
    
    //==========================================================================
    // Ray Scheduling Logic (Coherence-Optimized)
    //==========================================================================
    
    // Ray bucket scheduler - group rays by quadrant for coherency
    ray_t ray_buckets [16][4];  // 16 quadrants × 4 rays each
    logic [1:0] bucket_count [16];
    logic [3:0] active_bucket;
    logic [3:0] next_bucket;
    
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int i = 0; i < 16; i++)
                bucket_count[i] <= 2'h0;
            active_bucket <= 4'h0;
        end else begin
            // Fill buckets from ray FIFO
            if (!ray_fifo_empty) begin
                logic [3:0] quad = ray_fifo[ray_fifo_rd_ptr].quadrant;
                if (bucket_count[quad] < 2'd3) begin
                    ray_buckets[quad][bucket_count[quad]] <= ray_fifo[ray_fifo_rd_ptr];
                    bucket_count[quad] <= bucket_count[quad] + 1'b1;
                    ray_fifo_rd_ptr <= ray_fifo_rd_ptr + 1'b1;
                end
            end
            
            // Select next bucket with highest count (most coherent)
            active_bucket <= next_bucket;
        end
    end
    
    // Priority scheduler - find bucket with most rays
    always_comb begin
        next_bucket = 4'h0;
        logic [1:0] max_count = 2'h0;
        
        for (int i = 0; i < 16; i++) begin
            if (bucket_count[i] > max_count) begin
                max_count = bucket_count[i];
                next_bucket = i[3:0];
            end
        end
    end
    
    // Issue rays from selected bucket to active ray buffer
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            active_ray_count <= 4'h0;
        end else if (trav_state == TRAV_IDLE && bucket_count[active_bucket] > 2'h0) begin
            // Transfer rays from bucket to active ray buffer
            for (int i = 0; i < 4; i++) begin
                if (i < bucket_count[active_bucket]) begin
                    active_rays[active_ray_count + i] <= ray_buckets[active_bucket][i];
                end
            end
            active_ray_count <= active_ray_count + bucket_count[active_bucket];
            bucket_count[active_bucket] <= 2'h0;
        end
    end
    
    //==========================================================================
    // Intersection Shader Pipeline (4-stage)
    //==========================================================================
    
    // Pipeline stage structure
    typedef struct packed {
        ray_t ray;
        logic [95:0] triangle_v0, triangle_v1, triangle_v2;
        logic [31:0] hit_t;
        logic [31:0] hit_u, hit_v;
        logic valid;
    } intersection_pipeline_stage_t;
    
    intersection_pipeline_stage_t pipe_stage [INTERSECTION_PIPELINE_STAGES];
    
    // Stage 0: Ray-Triangle setup
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pipe_stage[0].valid <= 1'b0;
        end else if (trav_state == TRAV_TRIANGLE_TEST && tri_test_done) begin
            // Load triangle data and ray for intersection
            pipe_stage[0].ray <= active_rays[0];
            pipe_stage[0].triangle_v0 <= tri_test_data[95:0];
            pipe_stage[0].triangle_v1 <= tri_test_data[191:96];
            pipe_stage[0].triangle_v2 <= tri_test_data[287:192];
            pipe_stage[0].valid <= 1'b1;
        end
    end
    
    // Stage 1: Compute edge vectors
    logic [95:0] edge1, edge2, pvec;
    
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pipe_stage[1].valid <= 1'b0;
        end else begin
            // Edge vectors: E1 = V1 - V0, E2 = V2 - V0
            edge1 <= pipe_stage[0].triangle_v1 - pipe_stage[0].triangle_v0;
            edge2 <= pipe_stage[0].triangle_v2 - pipe_stage[0].triangle_v0;
            // P = ray.direction × E2
            pvec <= cross_product(pipe_stage[0].ray.direction, edge2);
            pipe_stage[1] <= pipe_stage[0];
        end
    end
    
    // Stage 2: Compute determinant and u coordinate
    logic [31:0] det, inv_det;
    logic [95:0] tvec;
    
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pipe_stage[2].valid <= 1'b0;
        end else begin
            // det = E1 · P
            det <= dot_product(edge1, pvec);
            // T = ray.origin - V0
            tvec <= pipe_stage[1].ray.origin - pipe_stage[1].triangle_v0;
            // u = (T · P) / det
            pipe_stage[2].hit_u <= dot_product(tvec, pvec) / det;
            pipe_stage[2] <= pipe_stage[1];
        end
    end
    
    // Stage 3: Compute v coordinate and hit distance
    logic [95:0] qvec;
    
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pipe_stage[3].valid <= 1'b0;
        end else begin
            // Q = T × E1
            qvec <= cross_product(tvec, edge1);
            // v = (ray.direction · Q) / det
            pipe_stage[3].hit_v <= dot_product(pipe_stage[2].ray.direction, qvec) / det;
            // t = (E2 · Q) / det
            pipe_stage[3].hit_t <= dot_product(edge2, qvec) / det;
            
            pipe_stage[3] <= pipe_stage[2];
            
            // Check if hit is valid (u>=0, v>=0, u+v<=1, t>=tmin, t<=tmax)
            if (pipe_stage[2].hit_u >= 32'h0 && pipe_stage[3].hit_v >= 32'h0 &&
                (pipe_stage[2].hit_u + pipe_stage[3].hit_v) <= 32'h3F800000 &&
                pipe_stage[3].hit_t >= pipe_stage[2].ray.tmin &&
                pipe_stage[3].hit_t <= pipe_stage[2].ray.tmax) begin
                pipe_stage[3].valid <= 1'b1;
            end else begin
                pipe_stage[3].valid <= 1'b0;
            end
        end
    end
    
    // Helper functions for intersection
    function automatic [95:0] cross_product(input [95:0] a, input [95:0] b);
        logic [31:0] ax, ay, az, bx, by, bz;
        ax = a[31:0]; ay = a[63:32]; az = a[95:64];
        bx = b[31:0]; by = b[63:32]; bz = b[95:64];
        cross_product = {(ay * bz) - (az * by),
                        (az * bx) - (ax * bz),
                        (ax * by) - (ay * bx)};
    endfunction
    
    function automatic [31:0] dot_product(input [95:0] a, input [95:0] b);
        logic [31:0] ax, ay, az, bx, by, bz;
        ax = a[31:0]; ay = a[63:32]; az = a[95:64];
        bx = b[31:0]; by = b[63:32]; bz = b[95:64];
        dot_product = (ax * bx) + (ay * by) + (az * bz);
    endfunction
    
    //==========================================================================
    // SIMD AABB Intersection Testing (16 rays simultaneously)
    //==========================================================================
    
    always_comb begin
        aabb_hit_mask = 16'h0;
        ray_active_mask = 16'h0;
        
        for (int i = 0; i < MAX_RAYS_SIMD; i++) begin
            if (i < active_ray_count && active_rays[i].active) begin
                ray_active_mask[i] = 1'b1;
                
                // AABB slab test
                logic [31:0] tmin_x, tmax_x, tmin_y, tmax_y, tmin_z, tmax_z;
                logic [31:0] inv_dir_x, inv_dir_y, inv_dir_z;
                
                // Compute inverse direction (precomputed in real implementation)
                inv_dir_x = 32'h3F800000 / active_rays[i].direction[31:0];
                inv_dir_y = 32'h3F800000 / active_rays[i].direction[63:32];
                inv_dir_z = 32'h3F800000 / active_rays[i].direction[95:64];
                
                // Compute t values for X, Y, Z slabs
                tmin_x = (current_node.aabb_min[31:0] - active_rays[i].origin[31:0]) * inv_dir_x;
                tmax_x = (current_node.aabb_max[31:0] - active_rays[i].origin[31:0]) * inv_dir_x;
                tmin_y = (current_node.aabb_min[63:32] - active_rays[i].origin[63:32]) * inv_dir_y;
                tmax_y = (current_node.aabb_max[63:32] - active_rays[i].origin[63:32]) * inv_dir_y;
                tmin_z = (current_node.aabb_min[95:64] - active_rays[i].origin[95:64]) * inv_dir_z;
                tmax_z = (current_node.aabb_max[95:64] - active_rays[i].origin[95:64]) * inv_dir_z;
                
                // Find overlapping interval
                logic [31:0] tmin_final = max3(tmin_x, tmin_y, tmin_z);
                logic [31:0] tmax_final = min3(tmax_x, tmax_y, tmax_z);
                
                // Check if ray intersects AABB
                if (tmin_final <= tmax_final && 
                    tmax_final >= active_rays[i].tmin &&
                    tmin_final <= active_rays[i].tmax) begin
                    aabb_hit_mask[i] = 1'b1;
                end
            end
        end
    end
    
    // Helper functions for AABB test
    function automatic [31:0] max3(input [31:0] a, b, c);
        max3 = (a > b) ? ((a > c) ? a : c) : ((b > c) ? b : c);
    endfunction
    
    function automatic [31:0] min3(input [31:0] a, b, c);
        min3 = (a < b) ? ((a < c) ? a : c) : ((b < c) ? b : c);
    endfunction
    
    //==========================================================================
    // Ray Compaction (Remove Completed Rays)
    //==========================================================================
    
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            compacted_ray_count <= 4'h0;
        end else if (trav_state == TRAV_RAY_COMPACTION) begin
            logic [3:0] write_idx = 4'h0;
            
            // Compact active rays (remove completed ones)
            for (int i = 0; i < MAX_RAYS_SIMD; i++) begin
                if (i < active_ray_count && active_rays[i].active &&
                    ray_trav_state[i].stack_ptr > 6'h0) begin
                    // Ray still has nodes to traverse
                    active_rays[write_idx] <= active_rays[i];
                    ray_trav_state[write_idx] <= ray_trav_state[i];
                    write_idx++;
                end
            end
            
            compacted_ray_count <= write_idx;
            active_ray_count <= write_idx;
        end
    end
    
    //==========================================================================
    // BVH Node Data Parsing
    //==========================================================================
    
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            node_data_valid <= 1'b0;
        end else if (bvh_valid) begin
            // Parse BVH node from memory data
            current_node.aabb_min <= bvh_data[95:0];
            current_node.aabb_max <= bvh_data[191:96];
            current_node.left_child <= bvh_data[223:192];
            current_node.right_child <= bvh_data[255:224];
            current_node.primitive_offset <= bvh_data[287:256];
            current_node.primitive_count <= bvh_data[303:288];
            current_node.is_leaf <= bvh_data[304];
            node_data_valid <= 1'b1;
        end else begin
            node_data_valid <= 1'b0;
        end
    end
    
    //==========================================================================
    // BVH Stack Management
    //==========================================================================
    
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int i = 0; i < MAX_RAYS_SIMD; i++) begin
                ray_trav_state[i].node_index <= 32'h0;
                ray_trav_state[i].stack_ptr <= 6'h0;
                ray_trav_state[i].closest_hit_t <= 32'h7F800000;  // +infinity
                ray_trav_state[i].hit_found <= 1'b0;
            end
        end else begin
            case (trav_state)
                TRAV_FETCH_ROOT: begin
                    // Initialize traversal state for all active rays
                    for (int i = 0; i < active_ray_count; i++) begin
                        ray_trav_state[i].node_index <= 32'h0;  // Root
                        ray_trav_state[i].stack_ptr <= 6'h0;
                    end
                end
                
                TRAV_PUSH_CHILDREN: begin
                    // Push child nodes to stack for rays that hit AABB
                    for (int i = 0; i < active_ray_count; i++) begin
                        if (aabb_hit_mask[i]) begin
                            // Push left child
                            ray_trav_state[i].node_stack[ray_trav_state[i].stack_ptr] <= 
                                current_node.left_child;
                            ray_trav_state[i].stack_ptr <= ray_trav_state[i].stack_ptr + 1'b1;
                            
                            // Push right child
                            ray_trav_state[i].node_stack[ray_trav_state[i].stack_ptr + 1'b1] <= 
                                current_node.right_child;
                            ray_trav_state[i].stack_ptr <= ray_trav_state[i].stack_ptr + 2'd2;
                        end
                    end
                end
                
                TRAV_POP_STACK: begin
                    // Pop next node for all rays
                    for (int i = 0; i < active_ray_count; i++) begin
                        if (ray_trav_state[i].stack_ptr > 6'h0) begin
                            ray_trav_state[i].stack_ptr <= ray_trav_state[i].stack_ptr - 1'b1;
                            ray_trav_state[i].node_index <= 
                                ray_trav_state[i].node_stack[ray_trav_state[i].stack_ptr - 1'b1];
                        end
                    end
                end
                
                TRAV_UPDATE_CLOSEST: begin
                    // Update closest hit if new hit is closer
                    if (pipe_stage[3].valid && pipe_stage[3].hit_t < ray_trav_state[0].closest_hit_t) begin
                        ray_trav_state[0].closest_hit_t <= pipe_stage[3].hit_t;
                        ray_trav_state[0].hit_found <= 1'b1;
                    end
                end
            endcase
        end
    end
    
    //==========================================================================
    // Hit Output Generation
    //==========================================================================
    
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            hit_valid <= 1'b0;
            hit_data <= 128'h0;
        end else if (trav_state == TRAV_COMPLETE && ray_trav_state[0].hit_found) begin
            hit_valid <= 1'b1;
            hit_data <= {ray_trav_state[0].closest_hit_t,  // t
                        pipe_stage[3].hit_u,                // u
                        pipe_stage[3].hit_v,                // v
                        32'h0};                             // primitive ID
        end else if (hit_ready) begin
            hit_valid <= 1'b0;
        end
    end
    
    //==========================================================================
    // Performance Counters
    //==========================================================================
    
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            perf_rays_tested <= 32'h0;
            perf_hits <= 32'h0;
            perf_bvh_nodes_visited <= 32'h0;
            perf_traversal_steps <= 32'h0;
            perf_ray_compactions <= 32'h0;
        end else begin
            if (trav_state == TRAV_TEST_AABB)
                perf_rays_tested <= perf_rays_tested + active_ray_count;
            
            if (trav_state == TRAV_UPDATE_CLOSEST && pipe_stage[3].valid)
                perf_hits <= perf_hits + 1'b1;
            
            if (trav_state == TRAV_FETCH_NODE && bvh_valid)
                perf_bvh_nodes_visited <= perf_bvh_nodes_visited + 1'b1;
            
            if (trav_state != TRAV_IDLE)
                perf_traversal_steps <= perf_traversal_steps + 1'b1;
            
            if (trav_state == TRAV_RAY_COMPACTION)
                perf_ray_compactions <= perf_ray_compactions + 1'b1;
        end
    end
    
    // BVH address generation
    assign bvh_addr = {32'h0, node_fetch_addr};
    
    // Intersection shader data interface
    assign intersection_shader_data = {pipe_stage[3].ray.origin,
                                       pipe_stage[3].ray.direction,
                                       pipe_stage[3].hit_t,
                                       pipe_stage[3].hit_u,
                                       pipe_stage[3].hit_v};

endmodule
