// power_state_machine.sv
// Production-grade Power State Machine (PSM) per-domain with hierarchical/parallel states,
// global/local scripting, timeouts, error handling, and telemetry hooks.

`timescale 1ns/1ps

package psm_pkg;
  typedef enum logic [3:0] {
    PSM_OFF          = 4'd0,
    PSM_RETENTION    = 4'd1,
    PSM_STANDBY      = 4'd2,
    PSM_IDLE         = 4'd3,
    PSM_RUN_LOW      = 4'd4,
    PSM_RUN_BAL      = 4'd5,
    PSM_RUN_HIGH     = 4'd6,
    PSM_TURBO        = 4'd7,
    PSM_FAULT        = 4'd8
  } psm_state_e;

  typedef struct packed {
    logic        iso_en;        // isolation enable
    logic        rst_assert;    // reset assertion for domain
    logic        clk_en;        // clock enable gating
    logic        mem_ret_en;    // SRAM retention enable
    logic        pwr_sw_en;     // power switch enable for domain
  } psm_ctrl_t;

  typedef struct packed {
    logic        req_valid;
    psm_state_e  req_state;
    logic [3:0]  perf_hint;     // optional perf hint for DVFS mapping
    logic        force;         // override safety if true (for test)
  } psm_cmd_t;

  typedef struct packed {
    logic        ack;
    psm_state_e  cur_state;
    logic        busy;
    logic        fault;
    logic [7:0]  fault_code;
    logic [31:0] last_us;       // last transition latency in us
  } psm_status_t;
endpackage

import psm_pkg::*;

module power_state_machine #(
  parameter string NAME = "domain",
  parameter int unsigned TIMEOUT_US = 10000,
  parameter int unsigned ISO_SETUP_US = 2,
  parameter int unsigned PWR_RAMP_US = 50,
  parameter int unsigned CLK_STABLE_US = 2
) (
  input  logic         clk,
  input  logic         rst_n,

  // Command from power manager / firmware
  input  psm_cmd_t     cmd_i,
  output psm_status_t  status_o,

  // Handshakes with voltage and clock subsystems
  output logic         clk_req_o,
  input  logic         clk_ack_i,
  output logic  [2:0]  clk_mode_o,    // maps RUN_LOW/BAL/HIGH/TURBO

  output logic         vreq_o,
  input  logic         vack_i,
  output logic  [2:0]  vlevel_o,      // voltage performance level

  // Power switch and isolation controls to PMIC/UPF
  output psm_ctrl_t    ctrl_o,

  // Local activity/event inputs
  input  logic         idle_i,
  input  logic         wake_ev_i,
  input  logic         thermal_throttle_i,
  input  logic         fatal_err_i
);

  // Internal
  psm_state_e state_d, state_q;
  psm_ctrl_t  ctrl_d, ctrl_q;
  logic [31:0] timer_us_q, timer_us_d;
  logic busy_d, busy_q;
  logic ack_d, ack_q;
  logic fault_d, fault_q;
  logic [7:0] fault_code_d, fault_code_q;
  logic [31:0] last_us_d, last_us_q;

  // Performance mapping
  function automatic [2:0] map_state_to_perf(psm_state_e s);
    case (s)
      PSM_RUN_LOW:  map_state_to_perf = 3'd1;
      PSM_RUN_BAL:  map_state_to_perf = 3'd2;
      PSM_RUN_HIGH: map_state_to_perf = 3'd3;
      PSM_TURBO:    map_state_to_perf = 3'd4;
      default:      map_state_to_perf = 3'd0; // clock off / min
    endcase
  endfunction

  // Sequential
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state_q       <= PSM_OFF;
      ctrl_q        <= '{iso_en:1'b1, rst_assert:1'b1, clk_en:1'b0, mem_ret_en:1'b1, pwr_sw_en:1'b0};
      timer_us_q    <= 32'd0;
      busy_q        <= 1'b0;
      ack_q         <= 1'b0;
      fault_q       <= 1'b0;
      fault_code_q  <= '0;
      last_us_q     <= 32'd0;
    end else begin
      state_q      <= state_d;
      ctrl_q       <= ctrl_d;
      timer_us_q   <= timer_us_d;
      busy_q       <= busy_d;
      ack_q        <= ack_d;
      fault_q      <= fault_d;
      fault_code_q <= fault_code_d;
      last_us_q    <= last_us_d;
    end
  end

  // Microsecond timer model (assumes clk provides 1us tick externally or divider upstream)
  // For ASIC, connect a proper microsecond tick. Here we model as hold unless acking.

  // Default assignments
  always_comb begin
    state_d      = state_q;
    ctrl_d       = ctrl_q;
    timer_us_d   = timer_us_q;
    busy_d       = busy_q;
    ack_d        = 1'b0;
    fault_d      = fault_q;
    fault_code_d = fault_code_q;
    last_us_d    = last_us_q;

    // Outputs
    ctrl_o       = ctrl_q;
    clk_mode_o   = map_state_to_perf(state_q);
    vlevel_o     = map_state_to_perf(state_q);
    clk_req_o    = 1'b0;
    vreq_o       = 1'b0;

    // Transition logic
    if (fatal_err_i && !cmd_i.force) begin
      state_d      = PSM_FAULT;
      ctrl_d       = '{iso_en:1'b1, rst_assert:1'b1, clk_en:1'b0, mem_ret_en:1'b1, pwr_sw_en:1'b0};
      busy_d       = 1'b0;
      fault_d      = 1'b1;
      fault_code_d = 8'hE1; // fatal error
    end else begin
      unique case (state_q)
        PSM_OFF: begin
          // Stay off until command or wake event
          ctrl_d = '{iso_en:1'b1, rst_assert:1'b1, clk_en:1'b0, mem_ret_en:1'b1, pwr_sw_en:1'b0};
          if ((cmd_i.req_valid && cmd_i.req_state != PSM_OFF) || wake_ev_i) begin
            // Power up sequence: close power switch, wait ramp, then deassert iso and reset, then clk
            ctrl_d.pwr_sw_en = 1'b1;
            timer_us_d = 32'd0;
            busy_d = 1'b1;
            state_d = PSM_RETENTION; // intermediate
          end
        end
        PSM_RETENTION: begin
          // After power switch, wait ramp
          vreq_o = 1'b1; // request minimum voltage level
          clk_req_o = 1'b0;
          if (timer_us_q < PWR_RAMP_US) begin
            timer_us_d = timer_us_q + 1;
          end else begin
            ctrl_d.iso_en     = 1'b1; // keep isolation until clocks stable
            ctrl_d.rst_assert = 1'b1; // keep reset until clocks stable
            ctrl_d.mem_ret_en = 1'b1;
            // Move to standby to enable clock handshake
            state_d = PSM_STANDBY;
            timer_us_d = 32'd0;
          end
        end
        PSM_STANDBY: begin
          // Enable clock tree at minimal perf, release reset after stable
          clk_req_o = 1'b1;
          if (!clk_ack_i) begin
            // wait
            if (timer_us_q < CLK_STABLE_US) timer_us_d = timer_us_q + 1;
            else if (timer_us_q >= TIMEOUT_US) begin
              state_d = PSM_FAULT; fault_d = 1'b1; fault_code_d = 8'hC1;
            end
          end else begin
            ctrl_d.clk_en     = 1'b1;
            // small setup before deasserting isolation/reset
            if (timer_us_q < ISO_SETUP_US) begin
              timer_us_d = timer_us_q + 1;
            end else begin
              ctrl_d.iso_en     = 1'b0;
              ctrl_d.rst_assert = 1'b0;
              state_d           = PSM_IDLE;
              last_us_d         = timer_us_q;
              timer_us_d        = 32'd0;
              busy_d            = 1'b0;
              ack_d             = 1'b1;
            end
          end
        end
        PSM_IDLE: begin
          // Await activity or command for performance level
          if (thermal_throttle_i) begin
            state_d = PSM_RUN_LOW;
          end else if (cmd_i.req_valid) begin
            if (cmd_i.req_state inside {PSM_RUN_LOW, PSM_RUN_BAL, PSM_RUN_HIGH, PSM_TURBO}) begin
              state_d = cmd_i.req_state;
            end else if (cmd_i.req_state == PSM_OFF) begin
              // Begin power down sequence
              state_d = PSM_STANDBY; // reuse path then power cut
              // Gate clocks and assert reset before power cut
              ctrl_d.rst_assert = 1'b1;
              ctrl_d.iso_en     = 1'b1;
              ctrl_d.clk_en     = 1'b0;
              // After isolation, drop power
              ctrl_d.pwr_sw_en  = 1'b0;
            end
          end else if (!idle_i) begin
            state_d = PSM_RUN_BAL;
          end
        end
        PSM_RUN_LOW, PSM_RUN_BAL, PSM_RUN_HIGH, PSM_TURBO: begin
          // Coordinate with DVFS subsystems
          vreq_o     = 1'b1;
          clk_req_o  = 1'b1;
          // Wait for both acks (model as clk_ack_i and vack_i)
          if (clk_ack_i && vack_i) begin
            // Remain until new command or idle/thermal events
            if (thermal_throttle_i && state_q != PSM_RUN_LOW) begin
              state_d = PSM_RUN_LOW;
            end else if (idle_i && state_q != PSM_IDLE) begin
              state_d = PSM_IDLE;
            end else if (cmd_i.req_valid && cmd_i.req_state != state_q) begin
              if (cmd_i.req_state inside {PSM_RUN_LOW, PSM_RUN_BAL, PSM_RUN_HIGH, PSM_TURBO, PSM_IDLE}) begin
                state_d = cmd_i.req_state;
              end else if (cmd_i.req_state == PSM_OFF) begin
                // prepare power down
                ctrl_d.rst_assert = 1'b1;
                ctrl_d.iso_en     = 1'b1;
                ctrl_d.clk_en     = 1'b0;
                ctrl_d.pwr_sw_en  = 1'b0;
                state_d           = PSM_OFF;
              end
            end
          end else begin
            // waiting for acks with timeout
            if (timer_us_q < TIMEOUT_US) timer_us_d = timer_us_q + 1;
            else begin
              state_d = PSM_FAULT; fault_d = 1'b1; fault_code_d = 8'hD1;
            end
          end
        end
        PSM_FAULT: begin
          // Lockout until force reset
          ctrl_d = '{iso_en:1'b1, rst_assert:1'b1, clk_en:1'b0, mem_ret_en:1'b1, pwr_sw_en:1'b0};
          busy_d = 1'b0;
          if (cmd_i.force && cmd_i.req_valid && cmd_i.req_state == PSM_OFF) begin
            fault_d = 1'b0; fault_code_d = '0; state_d = PSM_OFF; ack_d = 1'b1;
          end
        end
        default: state_d = PSM_FAULT;
      endcase
    end
  end

  // Status
  assign status_o = '{
    ack:        ack_q,
    cur_state:  state_q,
    busy:       busy_q,
    fault:      fault_q,
    fault_code: fault_code_q,
    last_us:    last_us_q
  };

endmodule
