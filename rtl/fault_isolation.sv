// fault_isolation.sv
// Comet Assistant: Fault isolation/containment with configurable fences and region masks.

`timescale 1ns/1ps

module fault_isolation #(
  parameter int NUM_SEG = 8
) (
  input  logic clk,
  input  logic rst_n,

  // Segment health inputs
  input  logic [NUM_SEG-1:0] seg_fault,
  input  logic [NUM_SEG-1:0] seg_recoverable,

  // Control registers (to be memory-mapped elsewhere)
  input  logic [NUM_SEG-1:0] fence_enable,
  input  logic [NUM_SEG-1:0] mask_isolate, // 1 = isolate when faulted

  // Outputs to pipeline gating
  output logic [NUM_SEG-1:0] seg_allow,
  output logic [NUM_SEG-1:0] seg_soft_reset,

  // Event to logger
  output logic               evt_valid,
  input  logic               evt_ready,
  output logic [3:0]         evt_severity,
  output logic [7:0]         evt_code,
  output logic [$clog2(NUM_SEG)-1:0] evt_seg
);

  typedef enum logic [1:0] {S_OK, S_FAULT, S_ISO} seg_state_e;
  seg_state_e state[NUM_SEG];

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (int i=0;i<NUM_SEG;i++) state[i] <= S_OK;
      evt_valid <= 1'b0; evt_severity<='0; evt_code<='0; evt_seg<='0;
      seg_allow <='1; seg_soft_reset<='0;
    end else begin
      seg_allow <='1; seg_soft_reset<='0; evt_valid<=1'b0;
      for (int i=0;i<NUM_SEG;i++) begin
        unique case (state[i])
          S_OK: begin
            if (seg_fault[i]) begin
              state[i] <= mask_isolate[i] ? S_ISO : S_FAULT;
              evt_valid <= 1'b1; evt_severity <= 4'd2; evt_code <= 8'hF1; evt_seg <= i[$bits(evt_seg)-1:0];
              if (fence_enable[i]) seg_allow[i] <= 1'b0; // fence immediately
            end
          end
          S_FAULT: begin
            seg_allow[i] <= ~fence_enable[i];
            if (seg_recoverable[i]) begin
              seg_soft_reset[i] <= 1'b1; state[i] <= S_OK;
              evt_valid <= 1'b1; evt_severity <= 4'd1; evt_code <= 8'hF2; evt_seg <= i[$bits(evt_seg)-1:0];
            end
          end
          S_ISO: begin
            seg_allow[i] <= 1'b0; // isolated
            if (seg_recoverable[i]) begin
              state[i] <= S_OK; evt_valid<=1'b1; evt_severity<=4'd1; evt_code<=8'hF3; evt_seg<=i[$bits(evt_seg)-1:0];
            end
          end
        endcase
      end
    end
  end

endmodule
