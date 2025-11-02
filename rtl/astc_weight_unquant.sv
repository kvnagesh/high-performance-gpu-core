// astc_weight_unquant.sv
`ifndef ASTC_WEIGHT_UNQUANT_SV
`define ASTC_WEIGHT_UNQUANT_SV
module astc_weight_unquant #(
  parameter int MAX_TEXELS = 144
)(
  input  logic clk,
  input  logic rst_n,
  input  logic in_valid,
  output logic in_ready,
  input  logic [3:0] cfg_block_w,
  input  logic [3:0] cfg_block_h,
  input  logic [4:0] cfg_wt_quant_level, // 0..21 per ASTC
  input  logic [255:0] in_weights_q,     // packed quantized weights (max)
  input  logic [7:0]  in_weight_count,
  output logic out_valid,
  input  logic out_ready,
  output logic [MAX_TEXELS*8-1:0] out_weights_u8 // per-texel unquantized 0..255
);
  // Ready/valid
  assign in_ready = out_ready;

  // Table-driven unquant with dither cancellation per spec
  // Generated tables cover all quantization levels with canonical reps
  function automatic [7:0] unq(input [7:0] q, input [4:0] lvl);
    `include "astc/tables/weight_unquant_gen.vh"
  endfunction

  integer i;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      out_valid <= 1'b0;
      out_weights_u8 <= '0;
    end else if (in_valid && in_ready) begin
      for (i=0;i<MAX_TEXELS;i++) begin
        out_weights_u8[i*8 +: 8] <= (i < in_weight_count) ? unq(in_weights_q[i*8 +: 8], cfg_wt_quant_level) : 8'd0;
      end
      out_valid <= 1'b1;
    end else if (out_ready) begin
      out_valid <= 1'b0;
    end
  end
endmodule
`endif
