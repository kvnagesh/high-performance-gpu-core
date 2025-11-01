//==============================================================================
// Module: rasterizer
// Description: Production-grade rasterizer with edge equations and attribute
//              interpolation for triangle rasterization
//==============================================================================

module rasterizer #(
    parameter COORD_W = 16,      // Coordinate width in bits
    parameter ATTR_W = 128,      // Attribute width
    parameter NUM_ATTR = 16,     // Number of vertex attributes
    parameter SUBPIX_BITS = 4    // Sub-pixel precision bits
) (
    input logic clk,
    input logic rst_n,
    
    // Triangle input interface
    input logic prim_valid,
    output logic prim_ready,
    input logic [COORD_W-1:0] v0_x, v0_y,  // Vertex 0 coordinates
    input logic [COORD_W-1:0] v1_x, v1_y,  // Vertex 1 coordinates
    input logic [COORD_W-1:0] v2_x, v2_y,  // Vertex 2 coordinates
    input logic [COORD_W-1:0] v0_z, v0_w,  // Vertex 0 depth & perspective
    input logic [COORD_W-1:0] v1_z, v1_w,
    input logic [COORD_W-1:0] v2_z, v2_w,
    input logic [ATTR_W-1:0] v0_attr[NUM_ATTR],
    input logic [ATTR_W-1:0] v1_attr[NUM_ATTR],
    input logic [ATTR_W-1:0] v2_attr[NUM_ATTR],
    
    // Fragment output interface
    output logic frag_valid,
    input logic frag_ready,
    output logic [COORD_W-1:0] frag_x, frag_y,
    output logic [COORD_W-1:0] frag_z,
    output logic [ATTR_W-1:0] frag_attr[NUM_ATTR],
    
    // Viewport and scissor configuration
    input logic [COORD_W-1:0] vp_x, vp_y, vp_w, vp_h,
    input logic [COORD_W-1:0] sc_x, sc_y, sc_w, sc_h,
    
    // Performance counters
    output logic [31:0] perf_prims_in,
    output logic [31:0] perf_frags_out,
    output logic [31:0] perf_pixels_covered
);

    // State machine
    typedef enum logic [2:0] {
        IDLE,
        SETUP,
        SCAN_START,
        SCAN_PIXEL,
        INTERP,
        OUTPUT
    } state_t;
    
    state_t state;
    
    // Edge equation parameters: E(x,y) = a*x + b*y + c
    logic signed [COORD_W*2-1:0] edge0_a, edge0_b, edge0_c;
    logic signed [COORD_W*2-1:0] edge1_a, edge1_b, edge1_c;
    logic signed [COORD_W*2-1:0] edge2_a, edge2_b, edge2_c;
    
    // Bounding box
    logic [COORD_W-1:0] bb_min_x, bb_min_y, bb_max_x, bb_max_y;
    
    // Scan variables
    logic [COORD_W-1:0] scan_x, scan_y;
    logic scanning;
    
    // Barycentric coordinates
    logic signed [COORD_W*2-1:0] w0, w1, w2;
    logic signed [COORD_W*2-1:0] wsum;
    
    // Interpolation temporaries
    logic [COORD_W*2-1:0] bary_w0_u, bary_w1_u, bary_w2_u;  // 1/w weighted
    logic [ATTR_W*2-1:0] interp_temp[NUM_ATTR];
    
    // Latched triangle data
    logic [COORD_W-1:0] tri_v0_x, tri_v0_y, tri_v0_z, tri_v0_w;
    logic [COORD_W-1:0] tri_v1_x, tri_v1_y, tri_v1_z, tri_v1_w;
    logic [COORD_W-1:0] tri_v2_x, tri_v2_y, tri_v2_z, tri_v2_w;
    logic [ATTR_W-1:0] tri_v0_attr[NUM_ATTR];
    logic [ATTR_W-1:0] tri_v1_attr[NUM_ATTR];
    logic [ATTR_W-1:0] tri_v2_attr[NUM_ATTR];
    
    // Main state machine
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= IDLE;
            prim_ready <= 1;
            frag_valid <= 0;
            scanning <= 0;
            perf_prims_in <= 0;
            perf_frags_out <= 0;
            perf_pixels_covered <= 0;
        end else begin
            case (state)
                IDLE: begin
                    prim_ready <= 1;
                    if (prim_valid) begin
                        // Latch triangle data
                        tri_v0_x <= v0_x; tri_v0_y <= v0_y; tri_v0_z <= v0_z; tri_v0_w <= v0_w;
                        tri_v1_x <= v1_x; tri_v1_y <= v1_y; tri_v1_z <= v1_z; tri_v1_w <= v1_w;
                        tri_v2_x <= v2_x; tri_v2_y <= v2_y; tri_v2_z <= v2_z; tri_v2_w <= v2_w;
                        for (int i = 0; i < NUM_ATTR; i++) begin
                            tri_v0_attr[i] <= v0_attr[i];
                            tri_v1_attr[i] <= v1_attr[i];
                            tri_v2_attr[i] <= v2_attr[i];
                        end
                        prim_ready <= 0;
                        state <= SETUP;
                        perf_prims_in <= perf_prims_in + 1;
                    end
                end
                
                SETUP: begin
                    // Compute edge equations
                    // Edge 0: v1->v2
                    edge0_a <= tri_v1_y - tri_v2_y;
                    edge0_b <= tri_v2_x - tri_v1_x;
                    edge0_c <= (tri_v1_x * tri_v2_y) - (tri_v2_x * tri_v1_y);
                    
                    // Edge 1: v2->v0
                    edge1_a <= tri_v2_y - tri_v0_y;
                    edge1_b <= tri_v0_x - tri_v2_x;
                    edge1_c <= (tri_v2_x * tri_v0_y) - (tri_v0_x * tri_v2_y);
                    
                    // Edge 2: v0->v1
                    edge2_a <= tri_v0_y - tri_v1_y;
                    edge2_b <= tri_v1_x - tri_v0_x;
                    edge2_c <= (tri_v0_x * tri_v1_y) - (tri_v1_x * tri_v0_y);
                    
                    // Compute bounding box
                    bb_min_x <= (tri_v0_x < tri_v1_x) ? ((tri_v0_x < tri_v2_x) ? tri_v0_x : tri_v2_x) : ((tri_v1_x < tri_v2_x) ? tri_v1_x : tri_v2_x);
                    bb_min_y <= (tri_v0_y < tri_v1_y) ? ((tri_v0_y < tri_v2_y) ? tri_v0_y : tri_v2_y) : ((tri_v1_y < tri_v2_y) ? tri_v1_y : tri_v2_y);
                    bb_max_x <= (tri_v0_x > tri_v1_x) ? ((tri_v0_x > tri_v2_x) ? tri_v0_x : tri_v2_x) : ((tri_v1_x > tri_v2_x) ? tri_v1_x : tri_v2_x);
                    bb_max_y <= (tri_v0_y > tri_v1_y) ? ((tri_v0_y > tri_v2_y) ? tri_v0_y : tri_v2_y) : ((tri_v1_y > tri_v2_y) ? tri_v1_y : tri_v2_y);
                    
                    // Clip to scissor
                    if (bb_min_x < sc_x) bb_min_x <= sc_x;
                    if (bb_min_y < sc_y) bb_min_y <= sc_y;
                    if (bb_max_x > (sc_x + sc_w)) bb_max_x <= sc_x + sc_w;
                    if (bb_max_y > (sc_y + sc_h)) bb_max_y <= sc_y + sc_h;
                    
                    scan_x <= bb_min_x;
                    scan_y <= bb_min_y;
                    scanning <= 1;
                    state <= SCAN_START;
                end
                
                SCAN_START: begin
                    // Evaluate edge equations at current pixel
                    w0 <= edge0_a * scan_x + edge0_b * scan_y + edge0_c;
                    w1 <= edge1_a * scan_x + edge1_b * scan_y + edge1_c;
                    w2 <= edge2_a * scan_x + edge2_b * scan_y + edge2_c;
                    state <= SCAN_PIXEL;
                end
                
                SCAN_PIXEL: begin
                    // Check if pixel is inside triangle (all edge functions >= 0)
                    if (w0 >= 0 && w1 >= 0 && w2 >= 0) begin
                        perf_pixels_covered <= perf_pixels_covered + 1;
                        wsum <= w0 + w1 + w2;
                        state <= INTERP;
                    end else begin
                        // Continue scanning
                        if (scan_x < bb_max_x) scan_x <= scan_x + 1;
                        else if (scan_y < bb_max_y) begin
                            scan_x <= bb_min_x; scan_y <= scan_y + 1;
                        end else begin
                            scanning <= 0; state <= IDLE;  // Done
                        end
                        state <= SCAN_START;
                    end
                end
                
                INTERP: begin
                    // Perspective-correct barycentric coordinates
                    // bary = w / (w0/w0 + w1/w1 + w2/w2)
                    bary_w0_u <= (w0 * tri_v0_w);
                    bary_w1_u <= (w1 * tri_v1_w);
                    bary_w2_u <= (w2 * tri_v2_w);
                    
                    // Interpolate depth
                    frag_z <= ((bary_w0_u * tri_v0_z) + (bary_w1_u * tri_v1_z) + (bary_w2_u * tri_v2_z)) / wsum;
                    
                    // Interpolate attributes
                    for (int i = 0; i < NUM_ATTR; i++) begin
                        interp_temp[i] <= (bary_w0_u * v0_attr[i]) + (bary_w1_u * v1_attr[i]) + (bary_w2_u * v2_attr[i]);
                        frag_attr[i] <= interp_temp[i][ATTR_W+1:16];  // Normalize
                    end
                    
                    frag_x <= scan_x; frag_y <= scan_y;
                    state <= OUTPUT;
                end
                
                OUTPUT: begin
                    frag_valid <= 1;
                    if(frag_ready) begin
                        frag_valid <= 0; perf_frags_out <= perf_frags_out + 1;
                        
                        // Continue scanning
                        if(scan_x < bb_max_x) scan_x <= scan_x + 1;
                        else if(scan_y < bb_max_y) begin    
                            scan_x <= bb_min_x; scan_y <= scan_y + 1;
                        end else begin
                            scanning <= 0; state <= IDLE;  // Done
                        end
                        state <= SCAN_START;
                    end
                end
            endcase
        end
    end
    
    assign prim_ready = (state == IDLE);

endmodule
