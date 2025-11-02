// power_coordination_engine.sv
// Coordinates voltage/frequency scaling across domains, aggregates requests,
// arbitrates transitions, and manages clock muxing and cross-domain ordering.

`timescale 1ns/1ps

import psm_pkg::*;

module power_coordination_engine #(
  parameter int unsigned NUM_DOMAINS = 8
) (
  input  logic                    clk,
  input  logic                    rst_n,

  // Per-domain requests from PSMs
  input  psm_state_e              psm_state_i   [NUM_DOMAINS],
  input  logic [2:0]              perf_req_i    [NUM_DOMAINS],
  input  logic                    psm_busy_i    [NUM_DOMAINS],
  input  logic                    psm_fault_i   [NUM_DOMAINS],

  // Aggregated DVFS outputs to clock/voltage providers
  output logic [2:0]              global_perf_o,
  output logic [NUM_DOMAINS-1:0] clk_req_o,
  input  logic [NUM_DOMAINS-1:0] clk_ack_i,
  output logic [NUM_DOMAINS-1:0] vreq_o,
  input  logic [NUM_DOMAINS-1:0] vack_i,

  // Clock multiplexing controls per domain
  output logic [1:0]              clk_sel_o     [NUM_DOMAINS], // 0:off 1:pllA 2:pllB 3:osc

  // Cross-domain sequencing dependencies (bitmap: domain j depends on i)
  input  logic [NUM_DOMAINS-1:0]  dep_matrix_i  [NUM_DOMAINS],

  // Telemetry
  output logic [15:0]             active_mask_o,
  output logic [31:0]             throttles_cnt_o,
  output logic [31:0]             fault_cnt_o
);

  // Simple aggregation policy: global perf is max of domain requests, bounded by thermal governor
  logic [2:0] max_perf;
  always_comb begin
    max_perf = 3'd0;
    for (int d = 0; d < NUM_DOMAINS; d++) begin
      if (perf_req_i[d] > max_perf) max_perf = perf_req_i[d];
    end
  end
  assign global_perf_o = max_perf;

  // Example policy: choose clk source per perf level
  function automatic [1:0] perf_to_clk_sel(input [2:0] perf);
    case (perf)
      3'd0: perf_to_clk_sel = 2'd0; // off
      3'd1, 3'd2: perf_to_clk_sel = 2'd3; // osc for low/bal
      3'd3: perf_to_clk_sel = 2'd1; // pllA high
      3'd4: perf_to_clk_sel = 2'd2; // pllB turbo
      default: perf_to_clk_sel = 2'd1;
    endcase
  endfunction

  // Apply per-domain requests and handle dependencies
  typedef enum logic [1:0] {IDLE, WAIT_DEPS, WAIT_ACKS} seq_e;
  seq_e seq_q [NUM_DOMAINS], seq_d [NUM_DOMAINS];
  logic [NUM_DOMAINS-1:0] clk_req_d, clk_req_q;
  logic [NUM_DOMAINS-1:0] vreq_d, vreq_q;
  logic [31:0] throttles_cnt_q, throttles_cnt_d;
  logic [31:0] fault_cnt_q, fault_cnt_d;

  // active_mask tracks domains in RUN_* or IDLE (but powered)
  logic [15:0] active_mask_d, active_mask_q;

  // Sequential state
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      clk_req_q <= '0;
      vreq_q    <= '0;
      for (int d=0; d<NUM_DOMAINS; d++) seq_q[d] <= IDLE;
      throttles_cnt_q <= '0;
      fault_cnt_q <= '0;
      active_mask_q <= '0;
    end else begin
      clk_req_q <= clk_req_d;
      vreq_q    <= vreq_d;
      for (int d=0; d<NUM_DOMAINS; d++) seq_q[d] <= seq_d[d];
      throttles_cnt_q <= throttles_cnt_d;
      fault_cnt_q <= fault_cnt_d;
      active_mask_q <= active_mask_d;
    end
  end

  // Combinational control
  always_comb begin
    clk_req_d = clk_req_q;
    vreq_d    = vreq_q;
    throttles_cnt_d = throttles_cnt_q;
    fault_cnt_d = fault_cnt_q;
    active_mask_d = '0;

    for (int d=0; d<NUM_DOMAINS; d++) begin
      // active if not OFF/FAULT
      active_mask_d[d] = (psm_state_i[d] inside {PSM_RETENTION, PSM_STANDBY, PSM_IDLE, PSM_RUN_LOW, PSM_RUN_BAL, PSM_RUN_HIGH, PSM_TURBO});

      // default clock selection
      clk_sel_o[d] = perf_to_clk_sel(perf_req_i[d]);

      // sequencing engine
      seq_d[d] = seq_q[d];
      case (seq_q[d])
        IDLE: begin
          // Check dependencies: ensure all required providers are active (not OFF)
          logic deps_ready;
          deps_ready = 1'b1;
          for (int j=0; j<NUM_DOMAINS; j++) begin
            if (dep_matrix_i[d][j]) begin
              if (!(psm_state_i[j] inside {PSM_IDLE, PSM_RUN_LOW, PSM_RUN_BAL, PSM_RUN_HIGH, PSM_TURBO})) deps_ready = 1'b0;
            end
          end
          if (deps_ready) begin
            vreq_d[d] = 1'b1;
            clk_req_d[d] = 1'b1;
            seq_d[d] = WAIT_ACKS;
          end else begin
            seq_d[d] = WAIT_DEPS;
          end
        end
        WAIT_DEPS: begin
          // monitor until deps ready
          logic deps_ready;
          deps_ready = 1'b1;
          for (int j=0; j<NUM_DOMAINS; j++) begin
            if (dep_matrix_i[d][j]) begin
              if (!(psm_state_i[j] inside {PSM_IDLE, PSM_RUN_LOW, PSM_RUN_BAL, PSM_RUN_HIGH, PSM_TURBO})) deps_ready = 1'b0;
            end
          end
          if (deps_ready) begin
            vreq_d[d] = 1'b1;
            clk_req_d[d] = 1'b1;
            seq_d[d] = WAIT_ACKS;
          end
        end
        WAIT_ACKS: begin
          if (clk_ack_i[d] && vack_i[d]) begin
            // completed transition
            seq_d[d] = IDLE;
          end
        end
      endcase

      // fault/throttle accounting
      if (psm_fault_i[d]) fault_cnt_d++;
      if (perf_req_i[d] == 3'd1 && (psm_state_i[d] == PSM_RUN_HIGH || psm_state_i[d] == PSM_TURBO)) throttles_cnt_d++;
    end
  end

  assign clk_req_o = clk_req_q;
  assign vreq_o    = vreq_q;
  assign active_mask_o = active_mask_q;
  assign throttles_cnt_o = throttles_cnt_q;
  assign fault_cnt_o = fault_cnt_q;

endmodule
