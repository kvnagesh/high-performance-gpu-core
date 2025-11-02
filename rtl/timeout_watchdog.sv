// timeout_watchdog.sv
// Comet Assistant: Transaction timeout detection with auto-retry and notification.

`timescale 1ns/1ps

module timeout_watchdog #(
  parameter int NUM_CH = 8,
  parameter int TIMEOUT_CYCLES = 1024,
  parameter int RETRY_MAX = 3
) (
  input  logic clk,
  input  logic rst_n,

  // Per-channel transaction interface (start/done/error)
  input  logic [NUM_CH-1:0] tr_start,
  input  logic [NUM_CH-1:0] tr_done,
  output logic [NUM_CH-1:0] tr_retry,
  output logic [NUM_CH-1:0] tr_abort,

  // Status to host/logger
  output logic              evt_valid,
  input  logic              evt_ready,
  output logic [3:0]        evt_severity,
  output logic [7:0]        evt_code,
  output logic [$clog2(NUM_CH)-1:0] evt_ch
);

  typedef struct packed {
    logic active;
    logic [$clog2(TIMEOUT_CYCLES+1)-1:0] timer;
    logic [$clog2(RETRY_MAX+1)-1:0] retries;
  } ch_t;

  ch_t ch[NUM_CH];

  // Outputs default
  always_comb begin
    tr_retry = '0; tr_abort = '0; evt_valid = 1'b0; evt_severity='0; evt_code='0; evt_ch='0;
  end

  // Event queue simple single-entry handshake
  logic pend_evt; logic [3:0] pend_sev; logic [7:0] pend_code; logic [$clog2(NUM_CH)-1:0] pend_ch;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (int i=0;i<NUM_CH;i++) begin
        ch[i].active <= 1'b0; ch[i].timer <= '0; ch[i].retries <= '0;
      end
      pend_evt <= 1'b0; pend_sev <= '0; pend_code <= '0; pend_ch <= '0;
    end else begin
      // Launch tracking
      for (int i=0;i<NUM_CH;i++) begin
        if (tr_start[i]) begin
          ch[i].active <= 1'b1;
          ch[i].timer  <= '0;
        end
        if (ch[i].active && !tr_done[i]) begin
          if (ch[i].timer == TIMEOUT_CYCLES[$bits(ch[i].timer)-1:0]) begin
            // Timeout
            if (ch[i].retries < RETRY_MAX[$bits(ch[i].retries)-1:0]) begin
              ch[i].retries <= ch[i].retries + 1'b1;
              tr_retry[i]   <= 1'b1;
              // Report recoverable timeout
              pend_evt <= 1'b1; pend_sev <= 4'd2; pend_code <= 8'hT0; pend_ch <= i[$bits(pend_ch)-1:0];
              ch[i].timer <= '0;
            end else begin
              // Abort after max retries
              tr_abort[i]  <= 1'b1;
              ch[i].active <= 1'b0;
              // Report fatal timeout
              pend_evt <= 1'b1; pend_sev <= 4'd3; pend_code <= 8'hT1; pend_ch <= i[$bits(pend_ch)-1:0];
            end
          end else begin
            ch[i].timer <= ch[i].timer + 1'b1;
          end
        end
        if (tr_done[i]) begin
          ch[i].active <= 1'b0; ch[i].timer <= '0; ch[i].retries <= '0;
        end
      end

      if (pend_evt && evt_ready) begin
        evt_valid <= 1'b1; evt_severity <= pend_sev; evt_code <= pend_code; evt_ch <= pend_ch; pend_evt <= 1'b0;
      end else begin
        evt_valid <= 1'b0;
      end
    end
  end

endmodule
