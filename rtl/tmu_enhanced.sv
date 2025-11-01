module tmu_enhanced (
    input  logic        clk,
    input  logic        rst_n,

    // Request from shader core
    input  logic        req_valid,
    input  logic [3:0]  unit_select,   // 0..15 TMU index
    input  logic [31:0] u, v, layer, lod,
    output logic        req_ready,

    // Interface to AFRC/ASTC decode unit (simplified)
    output logic        tex_req,
    output logic [63:0] tex_addr,
    input  logic        tex_valid,
    input  logic [511:0] tex_data,

    // Filtered sample out
    output logic        samp_valid,
    output logic [127:0] samp_rgba,
    input  logic        samp_ready
);

    // 16 independent request FIFOs (round-robin serviced)
    typedef struct packed {logic [31:0] u,v,layer,lod;} tmu_req_t;
    tmu_req_t fifo [0:15][0:3];
    logic [1:0] wrptr [0:15];
    logic [1:0] rdptr [0:15];
    logic [3:0] rr_sel;

    assign req_ready = 1'b1; // accept; push into selected FIFO

    integer i;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin for (i=0;i<16;i++) begin wrptr[i]<=0; rdptr[i]<=0; end rr_sel<=0; samp_valid<=0; tex_req<=0; end
        else begin
            samp_valid<=0; tex_req<=0;
            if (req_valid) begin fifo[unit_select][wrptr[unit_select]] <= '{u:u,v:v,layer:layer,lod:lod}; wrptr[unit_select] <= wrptr[unit_select]+1; end
            // Round-robin service
            rr_sel <= rr_sel + 1;
            if (wrptr[rr_sel]!=rdptr[rr_sel]) begin
                // Compute tex address placeholder and request fetch
                tex_req<=1; tex_addr <= {32'h0, fifo[rr_sel][rdptr[rr_sel]].u};
                if (tex_valid) begin // Emit a simple nearest sample
                    samp_rgba <= tex_data[127:0]; samp_valid<=1; rdptr[rr_sel]<=rdptr[rr_sel]+1; end
            end
        end
    end

endmodule
