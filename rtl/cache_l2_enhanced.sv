module cache_l2_enhanced (
    input  logic        clk,
    input  logic        rst_n,
    input  logic [1:0]  slice_count_cfg, // 1:1 slice, 2:2 slices, 3:4 slic// 1:512KB, 2:1MB, 3:2MB (ARM G720 target)

    // CPU/GPU fabric request (simplified AXI-lite like)
    input  logic        req_valid,
    input  logic        req_write,
    input  logic [47:0] req_addr,
    input  logic [1023:0] req_wdata,
    output logic        req_ready,

    output logic        resp_valid,
    output logic [1023:0] resp_rdata,

    // L3/Memory interface
    output logic        mem_req,
    output logic [47:0] mem_addr,
    input  logic [1023:0] mem_rdata,
    input  logic        mem_valid
);

    // Parameters
    localparam LINE_BYTES = 128; // 128B lines
    localparam LINE_BITS  = LINE_BYTES*8; // 1024 bits

    // Tag structure: [tag | index | offset]
    localparam INDEX_BITS = 12; // 4K lines per slice
    localparam OFFSET_BITS= 7;  // 128B
    localparam TAG_BITS   = 48-INDEX_BITS-OFFSET_BITS;

    typedef struct packed {logic valid; logic dirty; logic [TAG_BITS-1:0] tag;} tag_t;

    // Up to 4 slices
    tag_t          tags   [0:3][0:(1<<INDEX_BITS)-1];
    logic [LINE_BITS-1:0] data   [0:3][0:(1<<INDEX_BITS)-1];

    function automatic [1:0] addr_slice(input [47:0] a);
        addr_slice = a[INDEX_BITS+OFFSET_BITS +: 2];
    endfunction
    function automatic [INDEX_BITS-1:0] addr_index(input [47:0] a);
        addr_index = a[OFFSET_BITS +: INDEX_BITS];
    endfunction
    function automatic [TAG_BITS-1:0] addr_tag(input [47:0] a);
        addr_tag = a[47 -: TAG_BITS];
    endfunction

    // Simple direct-mapped per-slice cache for brevity
    logic [1:0] slice_sel;
    logic [INDEX_BITS-1:0] idx; logic [TAG_BITS-1:0] tag;

    always_comb begin
        slice_sel = (slice_count_cfg==2'd3)? addr_slice(req_addr) :
                    (slice_count_cfg==2'd2)? addr_slice(req_addr)[0] : 2'd0;
        idx = addr_index(req_addr); tag = addr_tag(req_addr);
    end

    // Request/Response
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin req_ready<=1'b1; resp_valid<=1'b0; mem_req<=1'b0; end
        else begin
            resp_valid<=1'b0; mem_req<=1'b0; 
            if (req_valid && req_ready) begin
                if (tags[slice_sel][idx].valid && tags[slice_sel][idx].tag==tag) begin
                    // Hit
                    if (req_write) begin
                        data[slice_sel][idx] <= req_wdata; tags[slice_sel][idx].dirty<=1'b1; end
                    else begin resp_rdata <= data[slice_sel][idx]; resp_valid<=1'b1; end
                end else begin
                    // Miss -> fetch line
                    mem_req<=1'b1; mem_addr<= {req_addr[47:OFFSET_BITS], {OFFSET_BITS{1'b0}}};
                    if (mem_valid) begin
                        data[slice_sel][idx] <= mem_rdata;
                        tags[slice_sel][idx].valid<=1'b1; tags[slice_sel][idx].dirty<=1'b0; tags[slice_sel][idx].tag<=tag;
                        if (!req_write) begin resp_rdata<=mem_rdata; resp_valid<=1'b1; end
                        else begin data[slice_sel][idx] <= req_wdata; tags[slice_sel][idx].dirty<=1'b1; end
                    end
                end
            end
        end
    end

endmodule
