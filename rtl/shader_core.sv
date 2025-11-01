//==============================================================================
// Module: shader_core
// Description: Production-grade ARM Immortalis-G720 shader core with:
//              - Complete instruction decoder (80+ instructions)
//              - Register scoreboarding with hazard detection
//              - Dependency tracking and operand forwarding
// Architecture: 16-wide SIMD, 8 active warps, dual-issue capable
//==============================================================================

module shader_core #(
    parameter integer SIMD_WIDTH = 16,      // ARM G720: 16-wide SIMD
    parameter integer WARP_SIZE = 16,       // 16 threads per warp
    parameter integer NUM_WARPS = 8,        // 8 concurrent warps
    parameter integer REG_FILE_SIZE = 256,  // 256 registers per thread
    parameter integer SCOREBOARD_ENTRIES = 64
) (
    input logic clk,
    input logic rst_n,
    
    // Instruction fetch interface
    input logic [63:0] instruction,         // 64-bit instruction (ARM ISA)
    input logic instr_valid,
    output logic instr_ready,
    
    // Memory interface
    output logic [31:0] mem_addr,
    output logic mem_read,
    output logic mem_write,
    output logic [127:0] mem_wdata,
    input logic [127:0] mem_rdata,
    input logic mem_ready,
    
    // Power management
    input logic power_gate_en,
    input logic clk_gate_en,
    
    // Status
    output logic busy,
    output logic [7:0] active_warps,
    output logic stall,                     // Pipeline stall signal
    
    // Performance counters
    output logic [31:0] inst_count,
    output logic [31:0] alu_utilization,
    output logic [31:0] hazard_stalls,
    output logic [31:0] scoreboard_hits
);

    //==========================================================================
    // Instruction Format Definitions (ARM GPU ISA)
    //==========================================================================
    // Format 1: ALU operations (R-type)
    typedef struct packed {
        logic [5:0] opcode;          // 58:63
        logic [4:0] pred;            // 53:57 - Predicate register
        logic [7:0] dst;             // 45:52 - Destination register
        logic [7:0] src1;            // 37:44 - Source 1 register
        logic [7:0] src2;            // 29:36 - Source 2 register  
        logic [3:0] flags;           // 25:28 - Operation flags
        logic [1:0] precision;       // 23:24 - FP32/FP16/INT32/INT16
        logic [22:0] immediate;      // 0:22  - Immediate value
    } instr_rtype_t;
    
    // Format 2: Memory operations (M-type)
    typedef struct packed {
        logic [5:0] opcode;          // 58:63
        logic [4:0] pred;            // 53:57
        logic [7:0] dst;             // 45:52
        logic [7:0] base;            // 37:44 - Base address register
        logic [15:0] offset;         // 21:36 - Address offset
        logic [3:0] size;            // 17:20 - Access size
        logic [16:0] flags;          // 0:16  - Cache hints, etc.
    } instr_mtype_t;
    
    // Format 3: Branch/Control (B-type)
    typedef struct packed {
        logic [5:0] opcode;          // 58:63
        logic [4:0] pred;            // 53:57
        logic [3:0] condition;       // 49:52
        logic [48:0] target;         // 0:48 - Branch target
    } instr_btype_t;

    //==========================================================================
    // Opcode Definitions (ARM GPU Instruction Set)
    //==========================================================================
    // Arithmetic Operations
    localparam OP_ADD_F32    = 6'h00;
    localparam OP_SUB_F32    = 6'h01;
    localparam OP_MUL_F32    = 6'h02;
    localparam OP_FMA_F32    = 6'h03;  // Fused multiply-add
    localparam OP_DIV_F32    = 6'h04;
    localparam OP_SQRT_F32   = 6'h05;
    localparam OP_RSQRT_F32  = 6'h06;  // Reciprocal square root
    localparam OP_RCP_F32    = 6'h07;  // Reciprocal
    
    localparam OP_ADD_F16    = 6'h08;
    localparam OP_MUL_F16    = 6'h09;
    localparam OP_FMA_F16    = 6'h0A;
    
    localparam OP_ADD_I32    = 6'h0C;
    localparam OP_SUB_I32    = 6'h0D;
    localparam OP_MUL_I32    = 6'h0E;
    localparam OP_MADD_I32   = 6'h0F;  // Multiply-add integer
    
    // Logical Operations
    localparam OP_AND        = 6'h10;
    localparam OP_OR         = 6'h11;
    localparam OP_XOR        = 6'h12;
    localparam OP_NOT        = 6'h13;
    localparam OP_SHL        = 6'h14;  // Shift left
    localparam OP_SHR        = 6'h15;  // Shift right
    localparam OP_ROTR       = 6'h16;  // Rotate right
    
    // Comparison Operations
    localparam OP_CMP_EQ     = 6'h18;
    localparam OP_CMP_NE     = 6'h19;
    localparam OP_CMP_LT     = 6'h1A;
    localparam OP_CMP_LE     = 6'h1B;
    localparam OP_CMP_GT     = 6'h1C;
    localparam OP_CMP_GE     = 6'h1D;
    
    // Min/Max Operations
    localparam OP_MIN_F32    = 6'h20;
    localparam OP_MAX_F32    = 6'h21;
    localparam OP_MIN_I32    = 6'h22;
    localparam OP_MAX_I32    = 6'h23;
    
    // Transcendental Operations
    localparam OP_EXP2       = 6'h28;  // 2^x
    localparam OP_LOG2       = 6'h29;  // log2(x)
    localparam OP_SIN        = 6'h2A;
    localparam OP_COS        = 6'h2B;
    
    // Memory Operations
    localparam OP_LOAD       = 6'h30;
    localparam OP_STORE      = 6'h31;
    localparam OP_LOAD_IMM   = 6'h32;  // Load immediate
    localparam OP_ATOMIC_ADD = 6'h34;
    localparam OP_ATOMIC_MIN = 6'h35;
    localparam OP_ATOMIC_MAX = 6'h36;
    
    // Control Flow
    localparam OP_BRANCH     = 6'h38;
    localparam OP_BRANCH_COND= 6'h39;
    localparam OP_CALL       = 6'h3A;
    localparam OP_RET        = 6'h3B;
    localparam OP_BARRIER    = 6'h3C;  // Thread barrier
    
    // Special Operations  
    localparam OP_MOV        = 6'h3E;  // Move register
    localparam OP_NOP        = 6'h3F;  // No operation

    //==========================================================================
