//==============================================================================
// Module: memory_controller
// Description: Full memory controller for LPDDR5/HBM interface
// Features: Request queue, arbiter, ECC, refresh controller, QoS
//==============================================================================

module memory_controller (
    input logic clk,
    input logic rst_n,
    
    // Cache request interface
    input logic req_valid,
    input logic req_write,           // 1=write, 0=read
    input logic [31:0] req_addr,
    input logic [255:0] req_wdata,
    input logic [2:0] req_qos,       // QoS priority (0-7)
    output logic req_ready,
    
    // Response interface
    output logic rsp_valid,
    output logic [255:0] rsp_data,
    output logic rsp_error,          // ECC uncorrectable error
    input logic rsp_ready,
    
    // Memory interface (LPDDR5/HBM)
    output logic [31:0] mem_addr,
    output logic mem_read_req,
    output logic mem_write_req,
    output logic [255:0] mem_wdata,
    input logic [255:0] mem_rdata,
    input logic mem_ready,
    
    // Control/status
    input logic refresh_req,
    input logic powerdown_en,
    output logic [31:0] perf_bandwidth,
    output logic [31:0] perf_latency
);

    //==========================================================================
    // Parameters
    //==========================================================================
    localparam QUEUE_DEPTH = 16;
    localparam ADDR_WIDTH = 32;
    localparam DATA_WIDTH = 256;
    localparam ECC_WIDTH = 16;       // 16-bit ECC for 256-bit data
    
    //==========================================================================
    // Request Queue (FIFO)
    //==========================================================================
    typedef struct packed {
        logic write;
        logic [31:0] addr;
        logic [255:0] wdata;
        logic [2:0] qos;
    } request_t;
    
    request_t req_queue [QUEUE_DEPTH];
    logic [3:0] req_wr_ptr, req_rd_ptr;
    logic [4:0] req_count;           // 5 bits to detect full
    logic queue_full, queue_empty;
    
    assign queue_full = (req_count == QUEUE_DEPTH);
    assign queue_empty = (req_count == 0);
    assign req_ready = !queue_full;
    
    // Enqueue requests
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            req_wr_ptr <= 4'h0;
            req_count <= 5'h0;
        end else begin
            if (req_valid && req_ready) begin
                req_queue[req_wr_ptr] <= '{write: req_write, addr: req_addr, wdata: req_wdata, qos: req_qos};
                req_wr_ptr <= req_wr_ptr + 1'b1;
                req_count <= req_count + 1'b1;
            end else if (!queue_empty && mem_ready) begin
                req_count <= req_count - 1'b1;
            end
        end
    end
    
    //==========================================================================
    // Memory Arbiter (Priority-based QoS scheduling)
    //==========================================================================
    logic [3:0] selected_idx;
    logic [2:0] max_qos;
    
    // Find highest priority request
    always_comb begin
        selected_idx = req_rd_ptr;
        max_qos = req_queue[req_rd_ptr].qos;
        
        for (int i = 0; i < QUEUE_DEPTH; i++) begin
            if (i < req_count && req_queue[(req_rd_ptr + i) % QUEUE_DEPTH].qos > max_qos) begin
                max_qos = req_queue[(req_rd_ptr + i) % QUEUE_DEPTH].qos;
                selected_idx = (req_rd_ptr + i) % QUEUE_DEPTH;
            end
        end
    end
    
    //==========================================================================
    // Address Mapping (Row/Bank/Column)
    //==========================================================================
    logic [14:0] row_addr;
    logic [3:0] bank_addr;
    logic [9:0] col_addr;
    
    assign col_addr = req_queue[selected_idx].addr[9:0];
    assign bank_addr = req_queue[selected_idx].addr[13:10];
    assign row_addr = req_queue[selected_idx].addr[28:14];
    
    //==========================================================================
    // ECC Encoder/Decoder
    //==========================================================================
    logic [ECC_WIDTH-1:0] ecc_encoded;
    logic [ECC_WIDTH-1:0] ecc_received;
    logic ecc_error_detected;
    logic ecc_error_corrected;
    
    // Simplified ECC: XOR-based syndrome calculation
    function automatic [ECC_WIDTH-1:0] calculate_ecc(input [DATA_WIDTH-1:0] data);
        logic [ECC_WIDTH-1:0] syndrome;
        for (int i = 0; i < ECC_WIDTH; i++) begin
            syndrome[i] = ^(data & (256'h1 << (i * 16)));
        end
        return syndrome;
    endfunction
    
    assign ecc_encoded = calculate_ecc(req_queue[selected_idx].wdata);
    assign ecc_received = calculate_ecc(mem_rdata);
    assign ecc_error_detected = (ecc_received != ecc_encoded);
    assign ecc_error_corrected = ecc_error_detected && (^ecc_received == 1'b0); // Single-bit error
    
    //==========================================================================
    // Refresh Controller
    //==========================================================================
    logic [15:0] refresh_timer;
    logic refresh_active;
    
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            refresh_timer <= 16'h0;
            refresh_active <= 1'b0;
        end else begin
            if (refresh_req || refresh_timer >= 16'd7800) begin  // Auto-refresh every 7.8us
                refresh_active <= 1'b1;
                refresh_timer <= 16'h0;
            end else if (refresh_active && mem_ready) begin
                refresh_active <= 1'b0;
            end else begin
                refresh_timer <= refresh_timer + 1'b1;
            end
        end
    end
    
    //==========================================================================
    // Memory Command Generation
    //==========================================================================
    typedef enum logic [2:0] {
        IDLE,
        ACTIVATE,
        READ,
        WRITE,
        PRECHARGE,
        REFRESH
    } mem_state_t;
    
    mem_state_t state, next_state;
    
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            state <= IDLE;
        else
            state <= next_state;
    end
    
    always_comb begin
        next_state = state;
        mem_read_req = 1'b0;
        mem_write_req = 1'b0;
        mem_addr = 32'h0;
        mem_wdata = 256'h0;
        
        case (state)
            IDLE: begin
                if (refresh_active) begin
                    next_state = REFRESH;
                end else if (!queue_empty && mem_ready) begin
                    next_state = ACTIVATE;
                end
            end
            
            ACTIVATE: begin
                mem_addr = {row_addr, bank_addr, col_addr, 3'b000};
                if (mem_ready) begin
                    next_state = req_queue[selected_idx].write ? WRITE : READ;
                end
            end
            
            READ: begin
                mem_read_req = 1'b1;
                mem_addr = {row_addr, bank_addr, col_addr, 3'b000};
                if (mem_ready) begin
                    next_state = PRECHARGE;
                end
            end
            
            WRITE: begin
                mem_write_req = 1'b1;
                mem_addr = {row_addr, bank_addr, col_addr, 3'b000};
                mem_wdata = req_queue[selected_idx].wdata;
                if (mem_ready) begin
                    next_state = PRECHARGE;
                end
            end
            
            PRECHARGE: begin
                if (mem_ready) begin
                    next_state = IDLE;
                end
            end
            
            REFRESH: begin
                if (mem_ready && !refresh_active) begin
                    next_state = IDLE;
                end
            end
        endcase
    end
    
    // Dequeue requests
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            req_rd_ptr <= 4'h0;
        end else begin
            if (state == PRECHARGE && next_state == IDLE) begin
                req_rd_ptr <= req_rd_ptr + 1'b1;
            end
        end
    end
    
    //==========================================================================
    // Response Buffer
    //==========================================================================
    logic [255:0] rsp_buffer;
    logic rsp_buffer_valid;
    
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rsp_buffer_valid <= 1'b0;
            rsp_buffer <= 256'h0;
        end else begin
            if (state == READ && mem_ready) begin
                rsp_buffer <= mem_rdata;
                rsp_buffer_valid <= 1'b1;
            end else if (rsp_valid && rsp_ready) begin
                rsp_buffer_valid <= 1'b0;
            end
        end
    end
    
    assign rsp_valid = rsp_buffer_valid;
    assign rsp_data = rsp_buffer;
    assign rsp_error = ecc_error_detected && !ecc_error_corrected;
    
    //==========================================================================
    // Performance Counters
    //==========================================================================
    logic [31:0] total_requests;
    logic [31:0] total_cycles;
    logic [31:0] active_cycles;
    
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            total_requests <= 32'h0;
            total_cycles <= 32'h0;
            active_cycles <= 32'h0;
        end else begin
            total_cycles <= total_cycles + 1'b1;
            if (req_valid && req_ready) begin
                total_requests <= total_requests + 1'b1;
            end
            if (mem_read_req || mem_write_req) begin
                active_cycles <= active_cycles + 1'b1;
            end
        end
    end
    
    // Bandwidth utilization (percentage)
    assign perf_bandwidth = (total_cycles > 0) ? (active_cycles * 100) / total_cycles : 32'h0;
    
    // Average latency (cycles per request)
    assign perf_latency = (total_requests > 0) ? total_cycles / total_requests : 32'h0;
    
endmodule
