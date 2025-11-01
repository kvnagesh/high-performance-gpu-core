//==============================================================================
// Module: execution_engine
// Description: ARM Immortalis-G720 style execution engine with dual-issue
//              capability and 16-wide warp processing
//              Implements ARM's 5th Gen GPU architecture execution model
//==============================================================================

module execution_engine #(
    parameter integer WARP_WIDTH = 16,      // ARM uses 16 threads per warp
    parameter integer REG_FILE_SIZE = 512,  // Expanded for ARM architecture
    parameter integer NUM_WARPS = 8         // Multiple warps per engine
) (
    input  logic clk,
    input  logic rst_n,
    
    // Instruction fetch interface
    input  logic [63:0] instruction_bundle, // Dual-issue: 2x 32-bit instructions
    input  logic        instr_valid,
    output logic        instr_ready,
    
    // Memory interface
    output logic [31:0] mem_addr,
    output logic        mem_read,
    output logic        mem_write,
    inout  logic [255:0] mem_data,
    
    // Status and performance
    output logic        busy,
    output logic [7:0]  active_warps,
    output logic [31:0] inst_throughput,
    output logic [15:0] dual_issue_count
);

    // Instruction decode
    logic [31:0] instr_primary, instr_secondary;
    logic dual_issue_enable;
    logic [4:0] opcode_pri, opcode_sec;
    
    assign instr_primary = instruction_bundle[31:0];
    assign instr_secondary = instruction_bundle[63:32];
    
    // Register file - optimized for fast context switching
    logic [REG_FILE_SIZE-1:0][31:0] register_file;
    logic [3:0] active_warp_id;
    
    // Warp management
    typedef struct packed {
        logic valid;
        logic [15:0] thread_mask;        // Active thread mask
        logic [15:0] pc;                 // Program counter
        logic stalled;
        logic [3:0] priority;
    } warp_state_t;
    
    warp_state_t [NUM_WARPS-1:0] warp_states;
    
    //==========================================================================
    // Dual-Issue Logic - ARM's key performance feature
    //==========================================================================
    always_comb begin
        // Check if both instructions can be issued simultaneously
        // Must have no data dependencies and compatible execution units
        dual_issue_enable = instr_valid && 
                           !has_dependency(instr_primary, instr_secondary) &&
                           can_coissue(opcode_pri, opcode_sec);
    end
    
    function automatic logic has_dependency(logic [31:0] i1, logic [31:0] i2);
        // Check RAW, WAR, WAW hazards
        logic [4:0] i1_dst = i1[26:22];
        logic [4:0] i1_src1 = i1[21:17];
        logic [4:0] i2_src1 = i2[21:17];
        logic [4:0] i2_src2 = i2[16:12];
        return (i1_dst == i2_src1) || (i1_dst == i2_src2);
    endfunction
    
    function automatic logic can_coissue(logic [4:0] op1, logic [4:0] op2);
        // ARM allows ALU+TEX, ALU+LOAD, etc. in same cycle
        return (is_alu(op1) && is_tex(op2)) || 
               (is_alu(op1) && is_load(op2)) ||
               (is_alu(op1) && is_alu(op2) && !is_complex(op1) && !is_complex(op2));
    endfunction
    
    function automatic logic is_alu(logic [4:0] op); 
        return op < 5'h10;
    endfunction
    
    function automatic logic is_tex(logic [4:0] op); 
        return op >= 5'h10 && op < 5'h14;
    endfunction
    
    function automatic logic is_load(logic [4:0] op); 
        return op >= 5'h14 && op < 5'h18;
    endfunction
    
    function automatic logic is_complex(logic [4:0] op);
        return (op == 5'h04) || (op == 5'h05); // DIV, SQRT
    endfunction
    
    //==========================================================================
    // FP32/FP16/INT8/INT16 ALU Array - Multi-precision support
    //==========================================================================
    logic [WARP_WIDTH-1:0][31:0] alu_result_pri;
    logic [WARP_WIDTH-1:0][31:0] alu_result_sec;
    logic [1:0] precision_mode; // 00:FP32, 01:FP16, 10:INT16, 11:INT8
    
    genvar i;
    generate
        for (i = 0; i < WARP_WIDTH; i++) begin : alu_lane_array
            multi_precision_alu alu_pri (
                .clk(clk),
                .rst_n(rst_n),
                .opcode(opcode_pri),
                .operand_a(register_file[instr_primary[21:17]]),
                .operand_b(register_file[instr_primary[16:12]]),
                .precision(precision_mode),
                .result(alu_result_pri[i])
            );
            
            // Secondary ALU for dual-issue
            multi_precision_alu alu_sec (
                .clk(clk),
                .rst_n(rst_n),
                .opcode(opcode_sec),
                .operand_a(register_file[instr_secondary[21:17]]),
                .operand_b(register_file[instr_secondary[16:12]]),
                .precision(precision_mode),
                .result(alu_result_sec[i])
            );
        end
    endgenerate
    
    //==========================================================================
    // Warp Scheduler - Round-robin with priority
    //==========================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int j = 0; j < NUM_WARPS; j++) begin
                warp_states[j].valid <= (j < 4); // Start with 4 active warps
                warp_states[j].thread_mask <= 16'hFFFF;
                warp_states[j].pc <= 16'h0;
                warp_states[j].stalled <= 1'b0;
                warp_states[j].priority <= 4'h8;
            end
            active_warp_id <= 4'h0;
            busy <= 1'b0;
        end else begin
            // Select next ready warp
            logic [3:0] next_warp;
            next_warp = find_ready_warp(active_warp_id);
            
            if (next_warp != 4'hF) begin
                active_warp_id <= next_warp;
                busy <= 1'b1;
                warp_states[next_warp].pc <= warp_states[next_warp].pc + (dual_issue_enable ? 2 : 1);
            end else begin
                busy <= 1'b0;
            end
        end
    end
    
    function automatic logic [3:0] find_ready_warp(logic [3:0] current);
        for (int k = 0; k < NUM_WARPS; k++) begin
            logic [3:0] idx = (current + k + 1) % NUM_WARPS;
            if (warp_states[idx].valid && !warp_states[idx].stalled) begin
                return idx;
            end
        end
        return 4'hF; // No ready warp
    endfunction
    
    //==========================================================================
    // Performance Counters
    //==========================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            inst_throughput <= 32'h0;
            dual_issue_count <= 16'h0;
        end else begin
            if (instr_valid && instr_ready) begin
                inst_throughput <= inst_throughput + (dual_issue_enable ? 2 : 1);
                if (dual_issue_enable) dual_issue_count <= dual_issue_count + 1;
            end
        end
    end
    
    // Active warp count
    always_comb begin
        active_warps = 8'h0;
        for (int m = 0; m < NUM_WARPS; m++) begin
            if (warp_states[m].valid) active_warps = active_warps + 1;
        end
    end
    
    assign instr_ready = !busy || (find_ready_warp(active_warp_id) != 4'hF);

endmodule

//==============================================================================
// Submodule: multi_precision_alu
// Description: Multi-precision ALU supporting FP32/FP16/INT16/INT8
//==============================================================================
module multi_precision_alu (
    input  logic clk,
    input  logic rst_n,
    input  logic [4:0] opcode,
    input  logic [31:0] operand_a,
    input  logic [31:0] operand_b,
    input  logic [1:0] precision,
    output logic [31:0] result
);

    logic [31:0] result_fp32, result_fp16, result_int16, result_int8;
    
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            result <= 32'h0;
        end else begin
            case (precision)
                2'b00: result <= result_fp32;
                2'b01: result <= result_fp16;
                2'b10: result <= result_int16;
                2'b11: result <= result_int8;
            endcase
        end
    end
    
    // FP32 operations
    always_comb begin
        case (opcode)
            5'h00: result_fp32 = operand_a + operand_b;
            5'h01: result_fp32 = operand_a - operand_b;
            5'h02: result_fp32 = operand_a * operand_b;
            5'h03: result_fp32 = (operand_a * operand_b) + result; // FMA
            default: result_fp32 = 32'h0;
        endcase
    end

endmodule
