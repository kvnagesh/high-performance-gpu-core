// Production-Grade Geometry Pipeline with Vertex/Tessellation/Geometry Shading
module geometry_pipeline #(parameter VATTR_W=128, NUM_ATTR=16)(
  input logic clk, rst_n,
  input logic ia_valid, input logic[31:0] ia_vidx, input logic[VATTR_W-1:0] ia_attr[NUM_ATTR-1:0],
  input logic[1:0] ia_ptype, output logic ia_ready,
  input logic vs_en, tcs_en, tes_en, gs_en,
  input logic[5:0] tess_lvl_out[4], input logic[5:0] tess_lvl_in[2],
  output logic out_valid, input logic out_ready,
  output logic[127:0] out_pos, output logic[VATTR_W-1:0] out_attr[NUM_ATTR-1:0],
  output logic[1:0] out_ptype, output logic out_pend,
  output logic[31:0] perf_vin, perf_vout, perf_pin, perf_pout
);
typedef struct packed {logic v; logic[31:0] id; logic[VATTR_W-1:0] a[NUM_ATTR-1:0]; logic[127:0] p; logic[1:0] pt;} vdata_t;
vdata_t vs_o, tcs_o, tes_o, gs_o;
logic[31:0] vcache_tag[15:0]; logic[127:0] vcache_pos[15:0];
logic[VATTR_W-1:0] vcache_attr[15:0][NUM_ATTR-1:0]; logic[15:0] vcache_valid;
logic[3:0] vcache_ptr; logic vcache_hit; logic[15:0] tess_u, tess_v;
logic[7:0] tess_pcnt, gs_vcnt, gs_pcnt; logic tess_act, gs_act;

// Stage 1: Vertex Cache
always_ff @(posedge clk or negedge rst_n)
  if(!rst_n) begin vcache_valid<=0; vcache_ptr<=0; end
  else if(ia_valid && ia_ready) begin
    vcache_hit=0; for(int i=0;i<16;i++)
      if(vcache_valid[i] && vcache_tag[i]==ia_vidx) vcache_hit=1;
  end
assign ia_ready = vs_en ? !vs_o.v || out_ready : 1;

// Stage 2: Vertex Shader
always_ff @(posedge clk or negedge rst_n)
  if(!rst_n) begin vs_o.v<=0; perf_vin<=0; end
  else if(ia_valid && ia_ready && vs_en) begin
    vs_o.v<=1; vs_o.id<=ia_vidx; vs_o.p<={ia_attr[0],ia_attr[1]};
    for(int i=0;i<NUM_ATTR;i++) vs_o.a[i]<=ia_attr[i];
    vs_o.pt<=ia_ptype; perf_vin<=perf_vin+1;
    if(!vcache_hit) begin
      vcache_tag[vcache_ptr]<=ia_vidx; vcache_pos[vcache_ptr]<=vs_o.p;
      for(int i=0;i<NUM_ATTR;i++) vcache_attr[vcache_ptr][i]<=vs_o.a[i];
      vcache_valid[vcache_ptr]<=1; vcache_ptr<=vcache_ptr+1;
    end
  end else if(out_ready) vs_o.v<=0;

// Stage 3: Tessellation Control Shader
always_ff @(posedge clk or negedge rst_n)
  if(!rst_n) begin tcs_o.v<=0; tess_pcnt<=0; end
  else if(vs_o.v && tcs_en && vs_o.pt==2'b11) begin
    tcs_o.v<=1; tcs_o<=vs_o; tess_pcnt<=tess_pcnt+1;
  end else if(!tcs_en && vs_o.v) tcs_o<=vs_o;

// Stage 4: Tessellation Generator
always_ff @(posedge clk or negedge rst_n)
  if(!rst_n) begin tess_act<=0; tess_u<=0; tess_v<=0; end
  else if(tcs_o.v && tes_en) begin
    tess_act<=1;
    if(tess_u<{10'b0,tess_lvl_out[0]}) tess_u<=tess_u+1;
    else if(tess_v<{10'b0,tess_lvl_out[1]}) begin tess_u<=0; tess_v<=tess_v+1; end
    else begin tess_u<=0; tess_v<=0; tess_act<=0; end
  end

// Stage 5: Tessellation Evaluation Shader
always_ff @(posedge clk or negedge rst_n)
  if(!rst_n) tes_o.v<=0;
  else if(tess_act && tes_en) begin
    tes_o.v<=1; tes_o.p<=tcs_o.p;
    for(int i=0;i<NUM_ATTR;i++) tes_o.a[i]<=tcs_o.a[i];
    tes_o.pt<=2'b00;
  end else if(!tes_en && tcs_o.v) tes_o<=tcs_o;

// Stage 6: Geometry Shader
always_ff @(posedge clk or negedge rst_n)
  if(!rst_n) begin gs_o.v<=0; gs_vcnt<=0; gs_pcnt<=0; gs_act<=0; perf_pin<=0; perf_pout<=0; end
  else if(tes_o.v && gs_en) begin
    gs_act<=1; gs_o.v<=1; gs_o<=tes_o; gs_vcnt<=gs_vcnt+1;
    if((tes_o.pt==0 && gs_vcnt==2)||(tes_o.pt==1 && gs_vcnt==1)||tes_o.pt==2) begin
      gs_pcnt<=gs_pcnt+1; gs_vcnt<=0; perf_pin<=perf_pin+1; perf_pout<=perf_pout+1;
    end
  end else if(!gs_en && tes_o.v) begin gs_o<=tes_o; perf_pout<=perf_pout+1; end

// Stage 7: Output
always_ff @(posedge clk or negedge rst_n)
  if(!rst_n) begin out_valid<=0; perf_vout<=0; end
  else if(gs_o.v && out_ready) begin
    out_valid<=1; out_pos<=gs_o.p;
    for(int i=0;i<NUM_ATTR;i++) out_attr[i]<=gs_o.a[i];
    out_ptype<=gs_o.pt; out_pend<=(gs_vcnt==0); perf_vout<=perf_vout+1;
  end else if(out_ready) out_valid<=0;
endmodule
