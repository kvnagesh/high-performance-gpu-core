// dvfs_algorithms.sv
// DVFS algorithms supporting per-domain programmable targets/events and hardware reactions.

`timescale 1ns/1ps

import psm_pkg::*;

module dvfs_algorithms #(
  parameter int unsigned NUM_DOMAINS = 8
) (
  input  logic                   clk,
  input  logic                   rst_n,

  // Inputs: workload indicators and events per domain
  input  logic [15:0]            util_pct_i       [NUM_DOMAINS], // 0..10000 (0.01%)
  input  logic [31:0]            ipc_i            [NUM_DOMAINS],
  input  logic [31:0]            bw_bytes_ps_i    [NUM_DOMAINS],
  input  logic [2:0]             thermal_cap_i    [NUM_DOMAINS],
  input  logic                   irq_latency_req_i[NUM_DOMAINS],

  // Policy knobs (programmable)
  input  logic [15:0]            up_thresh_pct_i,
  input  logic [15:0]            down_thresh_pct_i,
  input  logic [15:0]            hysteresis_pct_i,
  input  logic [7:0]             min_hold_ms_i,
  input  logic [7:0]             max_boost_ms_i,

  // Outputs: requested performance levels per domain (0..4)
  output logic [2:0]             perf_req_o       [NUM_DOMAINS],
  output logic [NUM_DOMAINS-1:0] boost_active_o
);

  typedef struct packed {
    logic [2:0] perf;
    logic       boost;
    logic [15:0] hold_ms;
  } dvfs_state_t;

  dvfs_state_t st_q [NUM_DOMAINS], st_d [NUM_DOMAINS];

  // simple ms tick counter (assume 1kHz tick provided externally; here we just decrement when nonzero)
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (int d=0; d<NUM_DOMAINS; d++) begin
        st_q[d].perf <= 3'd2;
        st_q[d].boost <= 1'b0;
        st_q[d].hold_ms <= '0;
      end
    end else begin
      for (int d=0; d<NUM_DOMAINS; d++) st_q[d] <= st_d[d];
    end
  end

  function automatic [2:0] clamp_perf(input [2:0] req, input [2:0] cap);
    clamp_perf = (req > cap) ? cap : req;
  endfunction

  // policy per domain
  always_comb begin
    for (int d=0; d<NUM_DOMAINS; d++) begin
      st_d[d] = st_q[d];
      // default perf request based on utilization
      logic [2:0] perf_next;
      if (util_pct_i[d] >= up_thresh_pct_i) perf_next = 3'd4;
      else if (util_pct_i[d] >= (up_thresh_pct_i - hysteresis_pct_i)) perf_next = 3'd3;
      else if (util_pct_i[d] >= down_thresh_pct_i) perf_next = 3'd2;
      else perf_next = 3'd1;

      // urgent latency request triggers boost window
      if (irq_latency_req_i[d]) begin
        st_d[d].boost = 1'b1;
        st_d[d].hold_ms = max_boost_ms_i;
        perf_next = 3'd4;
      end

      // Hold window management
      if (st_q[d].hold_ms != 16'd0) begin
        st_d[d].hold_ms = st_q[d].hold_ms - 1'b1;
        // Keep at least current perf during hold
        if (perf_next < st_q[d].perf) perf_next = st_q[d].perf;
      end else begin
        // enforce minimum residency after a change
        st_d[d].hold_ms = min_hold_ms_i;
      end

      // Apply thermal cap
      st_d[d].perf = clamp_perf(perf_next, thermal_cap_i[d]);
    end
  end

  // Outputs
  for (genvar d=0; d<NUM_DOMAINS; d++) begin : OUTS
    assign perf_req_o[d] = st_q[d].perf;
    assign boost_active_o[d] = st_q[d].boost;
  end

endmodule
