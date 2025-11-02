// error_logger.sv
// Comet Assistant: Centralized error logging/reporting with MMIO register file and bus interface.

`timescale 1ns/1ps

module error_logger #(
  parameter int DEPTH = 32
) (
  input  logic clk,
  input  logic rst_n,

  // Event input from subsystems
  input  logic        evt_valid,
  output logic        evt_ready,
  input  logic [3:0]  evt_severity,
  input  logic [7:0]  evt_code,
  input  logic [15:0] evt_src,
  input  logic [31:0] evt_data0,
  input  logic [31:0] evt_data1,

  // Simple APB-like register interface
  input  logic        psel,
  input  logic        penable,
  input  logic        pwrite,
  input  logic [7:0]  paddr,
  input  logic [31:0] pwdata,
  output logic [31:0] prdata,
  output logic        pready,

  // Interrupts
  output logic irq_fatal,
  output logic irq_recoverable
);

  typedef struct packed {
    logic [3:0]  sev;
    logic [7:0]  code;
    logic [15:0] src;
    logic [31:0] d0;
    logic [31:0] d1;
  } log_t;

  log_t fifo   [DEPTH];
  logic [$clog2(DEPTH):0] wptr, rptr;
  logic full, empty;

  assign full  = (wptr[$bits(wptr)-1] != rptr[$bits(rptr)-1]) && (wptr[$bits(wptr)-2:0] == rptr[$bits(rptr)-2:0]);
  assign empty = (wptr == rptr);

  assign evt_ready = ~full;

  // Write on event
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      wptr <= '0; rptr <= '0; irq_fatal<=1'b0; irq_recoverable<=1'b0;
    end else begin
      if (evt_valid && evt_ready) begin
        fifo[wptr[$bits(wptr)-2:0]] <= '{sev:evt_severity, code:evt_code, src:evt_src, d0:evt_data0, d1:evt_data1};
        wptr <= wptr + 1'b1;
        if (evt_severity==4'd3) irq_fatal <= 1'b1; else if (evt_severity==4'd2 || evt_severity==4'd1) irq_recoverable <= 1'b1;
      end

      // Simple register map
      // 0x00: STATUS [empty, full]
      // 0x04: POP (read advances rptr)
      // 0x08..0x18: DATA sev/code/src/d0/d1 of head
      pready <= 1'b0; prdata <= '0;
      if (psel && penable && !pready) begin
        pready <= 1'b1;
        if (!pwrite) begin
          unique case (paddr)
            8'h00: prdata <= {30'b0, full, empty};
            8'h08: prdata <= {28'b0, fifo[rptr[$bits(rptr)-2:0]].sev};
            8'h0C: prdata <= {24'b0, fifo[rptr[$bits(rptr)-2:0]].code};
            8'h10: prdata <= {16'b0, fifo[rptr[$bits(rptr)-2:0]].src};
            8'h14: prdata <= fifo[rptr[$bits(rptr)-2:0]].d0;
            8'h18: prdata <= fifo[rptr[$bits(rptr)-2:0]].d1;
            default: prdata <= 32'h0;
          endcase
        end else begin
          if (paddr==8'h04) begin
            // POP
            if (!empty) rptr <= rptr + 1'b1;
          end else if (paddr==8'h1C) begin
            // IRQ clear bits: [1]=fatal, [0]=recoverable
            if (pwdata[1]) irq_fatal <= 1'b0;
            if (pwdata[0]) irq_recoverable <= 1'b0;
          end
        end
      end
    end
  end

endmodule
