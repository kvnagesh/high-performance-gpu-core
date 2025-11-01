module dvfs_controller (
    input  logic        clk,
    input  logic        rst_n,

    // Telemetry inputs
    input  logic [9:0]  temperature_c,  // deg C
    input  logic [15:0] utilization_pct, // 0..1000 -> 0..100%

    // OPP table (8 entries)
    input  logic [31:0] freq_table   [0:7],
    input  logic [15:0] volt_table   [0:7],

    // Outputs
    output logic [2:0]  opp_index,
    output logic [31:0] freq_out,
    output logic [15:0] volt_out,

    // Hints
    input  logic        boost_request,
    input  logic        power_save_request
);

    // Simple PID-like discrete controller (placeholder)
    typedef enum logic [1:0] {LOW, MID, HIGH} therm_t;
    therm_t therm;

    always_comb begin
        if (temperature_c > 10'd95)      therm = HIGH;
        else if (temperature_c > 10'd80) therm = MID;
        else                              therm = LOW;
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) opp_index<=3'd0;
        else begin
            // baseline from utilization
            if (utilization_pct > 16'd800)      opp_index <= 3'd6;
            else if (utilization_pct > 16'd600) opp_index <= 3'd5;
            else if (utilization_pct > 16'd400) opp_index <= 3'd4;
            else if (utilization_pct > 16'd200) opp_index <= 3'd3;
            else opp_index <= 3'd2;

            // thermal clamps
            if (therm==MID && opp_index>3'd4) opp_index<=3'd4;
            if (therm==HIGH && opp_index>3'd2) opp_index<=3'd2;

            // user hints
            if (boost_request && therm==LOW) opp_index <= (opp_index<3'd7)? opp_index+1 : opp_index;
            if (power_save_request) opp_index <= (opp_index>3'd1)? opp_index-1 : opp_index;
        end
    end

    assign freq_out = freq_table[opp_index];
    assign volt_out = volt_table[opp_index];

endmodule
