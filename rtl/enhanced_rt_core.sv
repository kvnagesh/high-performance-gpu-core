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

endmodule
