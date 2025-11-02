// redundant_compute_wrapper.sv
// Comet Assistant: Optional redundant computation with cross-check and failover/handshake.

`timescale 1ns/1ps

module redundant_compute_wrapper #(
  parameter int WIDTH = 64,
  parameter bit ENABLE_RDC = 1'b1
) (
  input  logic clk,
  input  logic rst_n,

  input  logic         in_valid,
  output logic         in_ready,
  input  logic [WIDTH-1:0] in_data,

  output logic         out_valid,
  input  logic         out_ready,
  output logic [WIDTH-1:0] out_data,
  output logic         out_mismatch,

  // connection to two compute instances (A and B)
  output logic         comp_valid,
  input  logic         comp_ready_a,
  input  logic         comp_ready_b,
  output logic [WIDTH-1:0] comp_data,
  input  logic         comp_done_a,
  input  logic         comp_done_b,
  input  logic [WIDTH-1:0] comp_out_a,
  input  logic [WIDTH-1:0] comp_out_b
);

  assign in_ready = out_ready & (~out_valid);

  typedef enum logic [1:0] {S_IDLE, S_RUN, S_CHECK, S_OUT} st_e;
  st_e st;
  logic [WIDTH-1:0] a_q, b_q;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      st <= S_IDLE; out_valid<=1'b0; out_data<='0; out_mismatch<=1'b0; comp_valid<=1'b0; comp_data<='0;
    end else begin
      out_valid <= 1'b0; out_mismatch <= 1'b0; comp_valid<=1'b0;
      case (st)
        S_IDLE: begin
          if (in_valid && in_ready) begin
            comp_data <= in_data; comp_valid <= 1'b1; st <= S_RUN;
          end
        end
        S_RUN: begin
          // Wait for both engines (if enabled) or only A otherwise
          if (ENABLE_RDC) begin
            if (comp_done_a && comp_done_b) begin
              a_q <= comp_out_a; b_q <= comp_out_b; st <= S_CHECK;
            end
          end else begin
            if (comp_done_a) begin
              a_q <= comp_out_a; st <= S_OUT;
            end
          end
        end
        S_CHECK: begin
          if (a_q === b_q) begin
            out_data <= a_q; out_valid <= 1'b1; st <= S_IDLE;
          end else begin
            // Mismatch -> flag and still choose A by policy
            out_mismatch <= 1'b1; out_data <= a_q; out_valid <= 1'b1; st <= S_IDLE;
          end
        end
        S_OUT: begin
          out_data <= a_q; out_valid <= 1'b1; st <= S_IDLE;
        end
      endcase
    end
  end

endmodule
