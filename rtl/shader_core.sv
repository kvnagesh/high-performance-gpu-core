//==============================================================================
// Module: shader_core
// Description: Programmable shader execution unit supporting vertex, pixel,
//              and compute shaders with FP32/FP16 precision
//              SIMD architecture for parallel thread execution
//==============================================================================

module shader_core #(
    parameter integer SIMD_WIDTH = 32,      // Number of parallel ALUs
    parameter integer REG_FILE_SIZE = 256,  // Register file entries
    parameter integer WARP_SIZE = 32        // Threads per warp
) (
    input  logic clk,
    input  logic rst_n,
    
    // Instruction fetch interface
    input  logic [31:0] instruction,
    input  logic        instr_valid,
    output logic        instr_ready,
    
    // Memory interface
    output logic [31:0] mem_addr,
    output logic        mem_read,
    output logic        mem_write,
    inout  logic [127:0] mem_data,
    
    // Status
    output logic busy,
    output logic [15:0] active_warps,
    
    // Performance counters
    output logic [31:0] inst_count,
    output logic [31:0] alu_utilization
);

    // Internal signals
    logic [SIMD_WIDTH-1:0][31:0] alu_result;
    logic [SIMD_WIDTH-1:0] alu_valid;
    logic [REG_FILE_SIZE-1:0][31:0] register_file;
    logic [4:0] opcode;
    logic [4:0] src1_reg, src2_reg, dst_reg;
    logic fp16_mode;  // 0: FP32, 1: FP16
    
    // Instruction decode
    assign opcode = instruction[31:27];
    assign dst_reg = instruction[26:22];
    assign src1_reg = instruction[21:17];
    assign src2_reg = instruction[16:12];
    assign fp16_mode = instruction[11];
    
    //==========================================================================
    // SIMD ALU Array - Parallel execution units
    //==========================================================================
    genvar i;
    generate
        for (i = 0; i < SIMD_WIDTH; i++) begin : simd_alu_array
            alu_unit #(
                .SUPPORT_FP16(1),
                .SUPPORT_FP32(1)
            ) alu_inst (
                .clk(clk),
                .rst_n(rst_n),
                .opcode(opcode),
                .operand_a(register_file[src1_reg]),
                .operand_b(register_file[src2_reg]),
                .fp16_mode(fp16_mode),
                .result(alu_result[i]),
                .valid(alu_valid[i])
            );
        end
    endgenerate
    
    //==========================================================================
    // Register File - Fast access storage
    //==========================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            register_file <= '{default: 32'h0};
        end else if (instr_valid && instr_ready) begin
            // Write back results to destination register
            if (alu_valid[0]) begin
                register_file[dst_reg] <= alu_result[0];
            end
        end
    end
    
    //==========================================================================
    // Warp Scheduler - Thread group management
    //==========================================================================
    logic [15:0] warp_ready;
    logic [4:0] current_warp;
    
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            current_warp <= 5'h0;
            warp_ready <= 16'hFFFF;  // All warps initially ready
            busy <= 1'b0;
        end else begin
            // Round-robin warp scheduling
            if (warp_ready != 16'h0) begin
                busy <= 1'b1;
                // Find next ready warp
                for (int j = 0; j < 16; j++) begin
                    if (warp_ready[j]) begin
                        current_warp <= j[4:0];
                        break;
                    end
                end
            end else begin
                busy <= 1'b0;
            end
        end
    end
    
    assign active_warps = {8'h0, warp_ready[15:8]} + {8'h0, warp_ready[7:0]};
    assign instr_ready = !busy || (warp_ready != 16'h0);
    
    //==========================================================================
    // Performance Monitoring
    //==========================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            inst_count <= 32'h0;
            alu_utilization <= 32'h0;
        end else begin
            if (instr_valid && instr_ready) begin
                inst_count <= inst_count + 1;
            end
            // Track ALU usage
            alu_utilization <= {24'h0, alu_valid[7:0]};
        end
    end

endmodule


//==============================================================================
// Submodule: alu_unit
// Description: Arithmetic Logic Unit with FP32/FP16 support
//==============================================================================
module alu_unit #(
    parameter SUPPORT_FP16 = 1,
    parameter SUPPORT_FP32 = 1
) (
    input  logic clk,
    input  logic rst_n,
    input  logic [4:0] opcode,
    input  logic [31:0] operand_a,
    input  logic [31:0] operand_b,
    input  logic fp16_mode,
    output logic [31:0] result,
    output logic valid
);

    // Opcode definitions
    localparam OP_ADD    = 5'b00000;
    localparam OP_SUB    = 5'b00001;
    localparam OP_MUL    = 5'b00010;
    localparam OP_FMA    = 5'b00011;  // Fused multiply-add
    localparam OP_DIV    = 5'b00100;
    localparam OP_SQRT   = 5'b00101;
    localparam OP_MIN    = 5'b00110;
    localparam OP_MAX    = 5'b00111;
    
    logic [31:0] alu_out;
    logic [2:0] pipeline_valid;
    
    //==========================================================================
    // ALU Operations - Multi-cycle for complex ops
    //==========================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            alu_out <= 32'h0;
            pipeline_valid <= 3'b000;
        end else begin
            case (opcode)
                OP_ADD: alu_out <= operand_a + operand_b;
                OP_SUB: alu_out <= operand_a - operand_b;
                OP_MUL: alu_out <= operand_a * operand_b;
                OP_MIN: alu_out <= (operand_a < operand_b) ? operand_a : operand_b;
                OP_MAX: alu_out <= (operand_a > operand_b) ? operand_a : operand_b;
                default: alu_out <= 32'h0;
            endcase
            
            // Pipeline control
            pipeline_valid <= {pipeline_valid[1:0], 1'b1};
        end
    end
    
    assign result = alu_out;
    assign valid = pipeline_valid[2];  // 3-cycle latency

endmodule
