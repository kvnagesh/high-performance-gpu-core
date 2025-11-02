// thermal_throttle.sv
// Thermal throttling logic interfacing digital/analog sensors, interpolation,
// hysteresis thresholds, and generating perf caps per domain and global.

`timescale 1ns/1ps

module thermal_throttle #(
  parameter int unsigned NUM_SENSORS = 8,
  parameter int unsigned NUM_DOMAINS = 8
) (
  input  logic                   clk,
  input  logic                   rst_n,

  // Sensor interfaces (digital codes), optional analog ready flags
  input  logic [11:0]            ts_code_i   [NUM_SENSORS],
  input  logic [NUM_SENSORS-1:0] ts_valid_i,
  input  logic [NUM_SENSORS-1:0] ts_analog_ready_i,

  // Per-domain mapping of sensors (bitmap per domain)
  input  logic [NUM_SENSORS-1:0] domain_sensor_map_i [NUM_DOMAINS],

  // Programmable thresholds (in codes), with hysteresis bands
  input  logic [11:0]            th_warn_hi_i,
  input  logic [11:0]            th_warn_lo_i,
  input  logic [11:0]            th_throt_hi_i,
  input  logic [11:0]            th_throt_lo_i,
  input  logic [11:0]            th_crit_hi_i,
  input  logic [11:0]            th_crit_lo_i,

  // Outputs
  output logic [2:0]             perf_cap_domain_o [NUM_DOMAINS], // 0..4 cap
  output logic [2:0]             perf_cap_global_o,
  output logic                   crit_shutdown_o,
  output logic [NUM_DOMAINS-1:0] throt_active_o,
  output logic [31:0]            overtemp_events_o
);

  // Interpolation/filtering: simple moving average per sensor
  logic [15:0] filt_q [NUM_SENSORS], filt_d [NUM_SENSORS];
  logic [31:0] overtemp_events_q, overtemp_events_d;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (int i=0;i<NUM_SENSORS;i++) filt_q[i] <= '0;
      overtemp_events_q <= '0;
    end else begin
      for (int i=0;i<NUM_SENSORS;i++) filt_q[i] <= filt_d[i];
      overtemp_events_q <= overtemp_events_d;
    end
  end

  always_comb begin
    for (int i=0;i<NUM_SENSORS;i++) begin
      if (ts_valid_i[i]) begin
        // EMA: filt = filt*3/4 + code/4
        filt_d[i] = (filt_q[i]*3 >> 2) + ({4'd0, ts_code_i[i]} >> 2);
      end else begin
        filt_d[i] = filt_q[i];
      end
    end
    overtemp_events_d = overtemp_events_q;
  end

  // Domain temperature aggregation: max over mapped sensors
  logic [11:0] domain_temp [NUM_DOMAINS];
  always_comb begin
    for (int d=0; d<NUM_DOMAINS; d++) begin
      logic [11:0] max_t; max_t = 12'd0;
      for (int s=0; s<NUM_SENSORS; s++) begin
        if (domain_sensor_map_i[d][s]) begin
          if (filt_q[s][11:0] > max_t) max_t = filt_q[s][11:0];
        end
      end
      domain_temp[d] = max_t;
    end
  end

  // Per-domain perf cap and throttle flags with hysteresis
  logic [2:0] perf_cap [NUM_DOMAINS];
  logic [NUM_DOMAINS-1:0] throt_q, throt_d;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) throt_q <= '0; else throt_q <= throt_d;
  end

  always_comb begin
    for (int d=0; d<NUM_DOMAINS; d++) begin
      // default: no cap
      perf_cap[d] = 3'd4;
      throt_d[d]  = throt_q[d];
      if (domain_temp[d] >= th_crit_hi_i) begin
        perf_cap[d] = 3'd0; // stop
        throt_d[d]  = 1'b1;
        overtemp_events_d++;
      end else if (domain_temp[d] >= th_throt_hi_i || (throt_q[d] && domain_temp[d] > th_throt_lo_i)) begin
        perf_cap[d] = 3'd1; // low perf cap
        throt_d[d]  = 1'b1;
      end else if (domain_temp[d] >= th_warn_hi_i || (throt_q[d] && domain_temp[d] > th_warn_lo_i)) begin
        perf_cap[d] = 3'd2; // balanced
        throt_d[d]  = 1'b1;
      } else begin
        perf_cap[d] = 3'd4; // turbo allowed
        throt_d[d]  = 1'b0;
      end
    end
  end

  // Global cap = min of domains
  logic [2:0] global_cap;
  always_comb begin
    global_cap = 3'd4;
    for (int d=0; d<NUM_DOMAINS; d++) begin
      if (perf_cap[d] < global_cap) global_cap = perf_cap[d];
    end
  end

  assign perf_cap_domain_o = perf_cap;
  assign perf_cap_global_o = global_cap;
  assign throt_active_o    = throt_q;
  assign crit_shutdown_o   = (global_cap == 3'd0);
  assign overtemp_events_o = overtemp_events_q;

endmodule
