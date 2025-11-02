// power_sequencer.sv
// Power-up/power-down sequencing FSMs with soft/hard domain ramp, cross-domain handshake,
// and fail-safe lockouts.

`timescale 1ns/1ps

module power_sequencer #(
  parameter int unsigned NUM_DOMAINS = 8
) (
  input  logic                   clk,
  input  logic                   rst_n,

  // Requests from host/PM
  input  logic [NUM_DOMAINS-1:0] pwrup_req_i,
  input  logic [NUM_DOMAINS-1:0] pwrdn_req_i,

  // Handshakes with domains
  output logic [NUM_DOMAINS-1:0] iso_en_o,
  output logic [NUM_DOMAINS-1:0] rst_assert_o,
  output logic [NUM_DOMAINS-1:0] pwr_sw_en_o,
  output logic [NUM_DOMAINS-1:0] clk_en_o,
  input  logic [NUM_DOMAINS-1:0] domain_idle_i,

  // Dependencies
  input  logic [NUM_DOMAINS-1:0] dep_matrix_i [NUM_DOMAINS],

  // Status
  output logic [NUM_DOMAINS-1:0] seq_busy_o,
  output logic [NUM_DOMAINS-1:0] seq_fault_o
);

  typedef enum logic [2:0] {S_OFF, S_PWR_ON, S_WAIT_STABLE, S_RELEASE, S_ON, S_PWR_OFF, S_FAULT} s_e;
  s_e s_q [NUM_DOMAINS], s_d [NUM_DOMAINS];
  logic [15:0] timer_q [NUM_DOMAINS], timer_d [NUM_DOMAINS];

  // Parameters for timing (programmable via CSR in integration)
  localparam int unsigned T_PWR_RAMP = 100; // us
  localparam int unsigned T_CLK_STABLE = 4; // us
  localparam int unsigned T_ISO_SETUP = 2; // us
  localparam int unsigned T_TIMEOUT   = 10000; // us

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (int d=0; d<NUM_DOMAINS; d++) begin
        s_q[d] <= S_OFF;
        timer_q[d] <= '0;
      end
    end else begin
      for (int d=0; d<NUM_DOMAINS; d++) begin
        s_q[d] <= s_d[d];
        timer_q[d] <= timer_d[d];
      end
    end
  end

  always_comb begin
    iso_en_o = '1; // default isolated
    rst_assert_o = '1;
    pwr_sw_en_o = '0;
    clk_en_o = '0;
    seq_busy_o = '0;
    seq_fault_o = '0;

    for (int d=0; d<NUM_DOMAINS; d++) begin
      s_d[d] = s_q[d];
      timer_d[d] = timer_q[d];

      case (s_q[d])
        S_OFF: begin
          if (pwrup_req_i[d]) begin
            // Check dependencies ready (providers on)
            logic deps_ready; deps_ready = 1'b1;
            for (int j=0; j<NUM_DOMAINS; j++) if (dep_matrix_i[d][j]) if (s_q[j] == S_OFF || s_q[j] == S_PWR_OFF || s_q[j] == S_FAULT) deps_ready = 1'b0;
            if (deps_ready) begin
              pwr_sw_en_o[d] = 1'b1;
              s_d[d] = S_PWR_ON; timer_d[d] = '0; seq_busy_o[d] = 1'b1;
            end
          end
        end
        S_PWR_ON: begin
          pwr_sw_en_o[d] = 1'b1;
          if (timer_q[d] < T_PWR_RAMP) timer_d[d] = timer_q[d] + 1;
          else s_d[d] = S_WAIT_STABLE;
          seq_busy_o[d] = 1'b1;
        end
        S_WAIT_STABLE: begin
          pwr_sw_en_o[d] = 1'b1;
          if (timer_q[d] < T_ISO_SETUP) timer_d[d] = timer_q[d] + 1; else begin
            clk_en_o[d] = 1'b1;
            if (timer_q[d] < (T_ISO_SETUP + T_CLK_STABLE)) timer_d[d] = timer_q[d] + 1;
            else s_d[d] = S_RELEASE;
          end
          seq_busy_o[d] = 1'b1;
        end
        S_RELEASE: begin
          pwr_sw_en_o[d] = 1'b1;
          clk_en_o[d] = 1'b1;
          iso_en_o[d] = 1'b0;
          rst_assert_o[d] = 1'b0;
          s_d[d] = S_ON;
        end
        S_ON: begin
          pwr_sw_en_o[d] = 1'b1; clk_en_o[d] = 1'b1; iso_en_o[d] = 1'b0; rst_assert_o[d] = 1'b0;
          if (pwrdn_req_i[d]) begin
            // graceful shutdown: assert reset, isolate, wait idle, then power off
            rst_assert_o[d] = 1'b1; iso_en_o[d] = 1'b1; clk_en_o[d] = 1'b0;
            if (domain_idle_i[d]) begin
              s_d[d] = S_PWR_OFF; timer_d[d] = '0; seq_busy_o[d] = 1'b1;
            end else if (timer_q[d] >= T_TIMEOUT) begin
              s_d[d] = S_FAULT; seq_fault_o[d] = 1'b1;
            end else begin
              timer_d[d] = timer_q[d] + 1; seq_busy_o[d] = 1'b1;
            end
          end
        end
        S_PWR_OFF: begin
          // Hard power cut after isolation
          pwr_sw_en_o[d] = 1'b0; iso_en_o[d] = 1'b1; rst_assert_o[d] = 1'b1; clk_en_o[d] = 1'b0;
          s_d[d] = S_OFF;
        end
        S_FAULT: begin
          seq_fault_o[d] = 1'b1;
          // lockout until external reset
        end
      endcase
    end
  end

endmodule
