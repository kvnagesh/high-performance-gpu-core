module vrs_tier2_unit (
    input  logic        clk,
    input  logic        rst_n,

    // Control
    input  logic        vrs_enable,
    input  logic [1:0]  mode_select,   // 0: per-draw, 1: per-primitive, 2: image-based, 3: foveated

    // Per-draw shading rate
    input  logic [2:0]  draw_shading_rate, // 0:1x1 .. 4:4x4

    // Per-primitive interface
    input  logic        prim_rate_valid,
    input  logic [2:0]  prim_rate_value,

    // Image-based shading rate map
    input  logic        rate_img_req,
    input  logic [15:0] rate_img_x,
    input  logic [15:0] rate_img_y,
    output logic [2:0]  rate_img_value,
    output logic        rate_img_valid,

    // Foveated parameters
    input  logic [15:0] gaze_x,
    input  logic [15:0] gaze_y,
    input  logic [15:0] inner_radius,
    input  logic [15:0] mid_radius,

    // Raster input
    input  logic        frag_in_valid,
    input  logic [15:0] frag_x,
    input  logic [15:0] frag_y,
    input  logic [31:0] prim_id,

    // Output shading decision
    output logic        shade_this_pixel,
    output logic [2:0]  applied_rate,

    // Perf counters
    output logic [31:0] perf_pixels_in,
    output logic [31:0] perf_pixels_shaded
);

    // Determine shading rate based on mode
    logic [2:0] base_rate;

    // Simple image-based LUT (stubbed interface)
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rate_img_value <= 3'd0;
            rate_img_valid <= 1'b0;
        end else begin
            rate_img_valid <= rate_img_req;
            // Trivial gradient for placeholder
            rate_img_value <= (rate_img_x[3:2] + rate_img_y[3:2]) % 5; // 0..4
        end
    end

    // Foveated calculation: inner=1x1, middle=2x2, outer=4x4
    function automatic [2:0] foveated_rate(input [15:0] x, input [15:0] y);
        logic signed [16:0] dx, dy;
        logic [31:0] d2;
        begin
            dx = $signed(x) - $signed(gaze_x);
            dy = $signed(y) - $signed(gaze_y);
            d2 = dx*dx + dy*dy;
            if (d2 <= inner_radius*inner_radius) foveated_rate = 3'd0;       // 1x1
            else if (d2 <= mid_radius*mid_radius) foveated_rate = 3'd2;      // 2x2
            else foveated_rate = 3'd4;                                       // 4x4
        end
    endfunction

    always_comb begin
        base_rate = 3'd0;
        unique case (mode_select)
            2'd0: base_rate = draw_shading_rate;                     // per-draw
            2'd1: base_rate = prim_rate_valid ? prim_rate_value : 3'd0; // per-prim
            2'd2: base_rate = rate_img_value;                        // image-based
            2'd3: base_rate = foveated_rate(frag_x, frag_y);         // foveated
        endcase
    end

    // Decide if we shade this pixel at current coordinates
    // For NxN rates, shade when (x%N==0 && y%N==0)
    function automatic logic should_shade(input [2:0] rate, input [15:0] x, input [15:0] y);
        logic [1:0] n;
        begin
            case (rate)
                3'd0: should_shade = 1'b1; // 1x1
                3'd1: should_shade = ((x[0]==0) & (y[0]==0)); // 1x2 example (unused)
                3'd2: begin n=2'd2; should_shade = ((x % n)==0) & ((y % n)==0); end // 2x2
                3'd3: begin n=2'd3; should_shade = ((x % n)==0) & ((y % n)==0); end // 3x3
                3'd4: begin n=2'd4; should_shade = ((x % n)==0) & ((y % n)==0); end // 4x4
                default: should_shade = 1'b1;
            endcase
        end
    endfunction

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            shade_this_pixel <= 1'b0;
            applied_rate <= 3'd0;
            perf_pixels_in <= 32'd0;
            perf_pixels_shaded <= 32'd0;
        end else begin
            if (frag_in_valid) begin
                perf_pixels_in <= perf_pixels_in + 1'b1;
                applied_rate <= base_rate;
                shade_this_pixel <= should_shade(base_rate, frag_x, frag_y);
                if (shade_this_pixel)
                    perf_pixels_shaded <= perf_pixels_shaded + 1'b1;
            end
        end
    end

endmodule
