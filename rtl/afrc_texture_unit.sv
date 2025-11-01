module afrc_texture_unit (
    input  logic        clk,
    input  logic        rst_n,

    // Compressed texture fetch
    input  logic        req_valid,
    input  logic [63:0] req_addr,
    output logic        req_ready,

    // Memory interface
    output logic        mem_req,
    output logic [63:0] mem_addr,
    input  logic [511:0] mem_rdata,
    input  logic        mem_valid,

    // Decoded texel block out
    output logic        tex_valid,
    output logic [511:0] tex_data,
    input  logic        tex_ready
);

    typedef enum logic [1:0] {IDLE, FETCH, DECODE, EMIT} dstate_t; dstate_t dstate;

    assign req_ready = (dstate==IDLE);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin dstate<=IDLE; mem_req<=0; tex_valid<=0; end
        else begin
            tex_valid<=0; mem_req<=0;
            case (dstate)
                IDLE: if (req_valid) begin mem_req<=1; mem_addr<=req_addr; dstate<=FETCH; end
                FETCH: if (mem_valid) begin dstate<=DECODE; end
                DECODE: begin // placeholder fixed-rate decode (AFRC)
                    dstate<=EMIT;
                end
                EMIT: begin if (tex_ready) begin tex_data<=mem_rdata; tex_valid<=1; dstate<=IDLE; end end
            endcase
        end
    end

endmodule
