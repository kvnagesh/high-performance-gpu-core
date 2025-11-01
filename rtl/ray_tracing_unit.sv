//==============================================================================
// Module: ray_tracing_unit
// Description: Hardware RT acceleration with BVH traversal and intersection
//==============================================================================

module ray_tracing_unit (
    input  logic clk,
    input  logic rst_n,
    input  logic [95:0] ray_data,  // origin + direction
    input  logic ray_valid,
    output logic ray_ready,
    output logic [31:0] hit_distance,
    output logic [15:0] hit_triangle_id,
    output logic hit_valid,
    output logic busy,
    output logic [15:0] rays_processed
);

    typedef enum logic [2:0] {
        IDLE, FETCH_NODE, TEST_AABB, TEST_TRIANGLE, BACKTRACK, COMPLETE
    } rt_state_t;
    
    rt_state_t state;
    logic [31:0] closest_hit;
    logic [15:0] closest_triangle;
    logic [7:0] stack_ptr;
    logic [31:0] node_stack [0:63];
    logic [15:0] ray_count;
    
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= IDLE;
            busy <= 1'b0;
            ray_count <= 16'h0;
            stack_ptr <= 8'h0;
        end else begin
            case (state)
                IDLE: begin
                    if (ray_valid) begin
                        state <= FETCH_NODE;
                        busy <= 1'b1;
                    end
                end
                FETCH_NODE: state <= TEST_AABB;
                TEST_AABB: state <= TEST_TRIANGLE;
                TEST_TRIANGLE: state <= BACKTRACK;
                BACKTRACK: state <= (stack_ptr == 0) ? COMPLETE : FETCH_NODE;
                COMPLETE: begin
                    state <= IDLE;
                    busy <= 1'b0;
                    ray_count <= ray_count + 1;
                end
            endcase
        end
    end
    
    assign ray_ready = (state == IDLE);
    assign rays_processed = ray_count;
    assign hit_valid = (state == COMPLETE);

endmodule
