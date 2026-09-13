

// -----------------------------------------------------------------------------
// constant_mul
// -----------------------------------------------------------------------------
(* use_dsp48 = "no" *)
module constant_mul(
    input  logic [35:0] x,
    input  logic        s0,
    input  logic        s1,
    input  logic [35:0] add_in,
    input  logic        s_add,
    output logic [42:0] y
);
    logic [46:0] z1;
    logic [46:0] z2;
    logic [46:0] z3;
    logic [46:0] z;

    // 3328 = 2^11 + 2^10 + 2^8
    assign z1 = s1 ? (x << 4) : (x << 11);
    assign z2 = s1 ? (x << 1) : (x << 10);
    assign z3 = z1 + z2;
    assign y = s1 ? (x + z3) : ((x << 8) + z3);
    assign z1 = (x << 11) + (x << 10) + (x << 8);
    
    // s0=1 -> 19x, s0=0 -> 3328x
    assign z  = s0 ? (z1 + x) : z1; 
    
    // Add mode for Cycle 1
    assign y = s_add ? (x + add_in) : z[42:0];
endmodule


// -----------------------------------------------------------------------------
// addsub
// -----------------------------------------------------------------------------
module addsub(
    input  logic [42:0] a,
    input  logic [42:0] b,
    input  logic        sub,
    output logic [43:0] c
);
    assign c = sub ? (a - b) : (a + b);
endmodule


// -----------------------------------------------------------------------------
// mul (Main Multiplier)
// -----------------------------------------------------------------------------
module mul(
    input  logic [16:0] a,
    input  logic [16:0] b,
    output logic [33:0] c
);
    assign c = a * b;
endmodule


// -----------------------------------------------------------------------------
// datapath
// -----------------------------------------------------------------------------
module datapath(
    input  logic [16:0] a,
    input  logic [16:0] b,
    input  logic        clk,
    input  logic        rst,
    
    // Control Signals (s2 and s3 are now 3 bits)
    input logic         state,   
    input logic         s0,      
    input logic         s_add,   
    input logic [2:0]   s2,      // Expanded to 3 bits
    input logic [2:0]   s3,      // Expanded to 3 bits
    input logic         s_a1,    
    input logic         sub,     
    
    output logic [11:0] final_result
);
    logic [33:0] c;
    logic [33:0] T_reg;
    logic [35:0] x;
    logic [35:0] add_in;
    logic [42:0] y;
    logic [42:0] a1;
    logic [42:0] b1;
    logic [43:0] c1;
    logic [43:0] result;
    logic [12:0] U;

    // Multiplier Input Muxes
    logic [16:0] mul_a, mul_b;
    assign mul_a = (state == 1'b0) ? a : {5'b0, result[11:0]}; // Cycle 0: a, Cycle 1: res
    assign mul_b = (state == 1'b0) ? b : 17'd3329;             // Cycle 0: b, Cycle 1: 3329

    mul u_mul(
        .a(mul_a),
        .b(mul_b),
        .c(c)
    );

    // T Register: Stores T at the end of Cycle 0
    always_ff @(posedge clk) begin
        if (state == 1'b0) 
            T_reg <= c;
    end

    // Constant Multiplier Inputs
    assign add_in = s_add ? {2'b0, c} : 36'b0;

    constant_mul u_constant_mul(
        .x(x),
        .s0(s0),
        .s1(1'b0),
        .add_in(add_in),
        .s_add(s_add),
        .y(y)
    );

    // U = y >> 12 (Division by R=4096)
    assign U = y[24:12];

    // -------------------------------------------------------------------------
    // x Mux (s2) - Keeping original first and last states, adding new ones
    // -------------------------------------------------------------------------
    always_comb begin
        case (s2)
            // --- Original States ---
            3'b000: x = c;                   // Original State 1
            3'b001: x = {28'b0, result[7:0]};// Original State 2
            3'b010: x = {28'b0, c[7:0]};     // Original State 3
            3'b011: x = {21'b0, result[43:17]}; // Original State 4
            
            // --- New Montgomery States ---
            3'b100: x = {24'b0, result[11:0]}; // New: res (for Cycle 1 multiplier)
            3'b101: x = {2'b0, T_reg};         // New: T_reg (for Cycle 1 constant_mul)
            default: x = 36'b0;
        endcase
    end

    // -------------------------------------------------------------------------
    // b1 Mux (s3) - Keeping original states 3 and 4, adding new ones
    // -------------------------------------------------------------------------
    always_comb begin
        case (s3)
            // --- Original States ---
            3'b000: b1 = {9'b0, c[23:8]};       // Original State 1
            3'b001: b1 = {27'b0, result[15:8]}; // Original State 2
            3'b010: b1 = result[42:0];          // Original State 3 (Kept)
            3'b011: b1 = {21'b0, result[43:17]};// Original State 4 (Kept)
            
            // --- New Montgomery States ---
            3'b100: b1 = {9'b0, c};             // New: T (for Cycle 0 subtraction)
            3'b101: b1 = 43'd3329;              // New: q (for Cycle 1 final subtraction)
            default: b1 = 43'b0;
        endcase
    end

    // a1 Mux
    assign a1 = s_a1 ? {30'b0, U} : y;

    addsub u_addsub(
        .a(a1),
        .b(b1),
        .sub(sub),
        .c(c1)
    );

    // Result Register and Final Subtraction Logic
    always_ff @(posedge clk) begin
        if (rst) begin
            result <= 44'b0;
        end
        else if (state == 1'b0) begin
            // Cycle 0: Store res = (T * 3327) mod 4096
            result <= {32'b0, c1[11:0]}; 
        end
        else if (state == 1'b1) begin
            // Cycle 1: Final Subtraction
            // If U >= 3329, result = U - 3329 (which is c1)
            // Else, result = U
            if (U >= 13'd3329)
                result <= {31'b0, c1[12:0]};
            else
                result <= {31'b0, U};
        end
    end

    assign final_result = result[11:0];

endmodule


// -----------------------------------------------------------------------------
// Top Module (Montgomery Multiplier)
// -----------------------------------------------------------------------------
module montgomery(
    input [11:0] a,           
    input [11:0] b,
    input clk,  
    input rst,         
    output logic [11:0] c    
);
    logic s0, s_add, s_a1, sub;
    logic [2:0] s2, s3;
    logic state;
    logic [11:0] final_result;

    datapath datapath_inst(
        .a({5'b0, a}), 
        .b({5'b0, b}),
        .clk(clk), 
        .rst(rst),
        .state(state),
        .s0(s0), 
        .s_add(s_add), 
        .s2(s2), 
        .s3(s3), 
        .s_a1(s_a1), 
        .sub(sub), 
        .final_result(final_result)
    );

    // FSM Control Logic (2 Cycles)
    always @(*) begin
        if (state == 1'b0) begin
            // Cycle 0: T = a * b, then res = T * 3327 mod R
            s0    = 1'b0;       // constant_mul: 3328x
            s_add = 1'b0;       // constant_mul: Multiplication mode
            s2    = 3'b000;     // x = T
            s3    = 3'b100;     // b1 = T
            s_a1  = 1'b0;       // a1 = y (T * 3328)
            sub   = 1'b1;       // sub = 1 -> y - T = T * 3327
        end else begin
            // Cycle 1: res1 = (T + res * 3329) / R, then Final Subtraction
            s0    = 1'b1;       // Don't care (s_add takes over)
            s_add = 1'b1;       // constant_mul: Add mode (T_reg + res*3329)
            s2    = 3'b101;     // x = T_reg
            s3    = 3'b101;     // b1 = 3329
            s_a1  = 1'b1;       // a1 = U (shifted sum)
            sub   = 1'b1;       // sub = 1 -> U - 3329
        end
    end

    // State Counter (Toggles every clock cycle)
    always @(posedge clk) begin
        if (rst == 1'b1)
            state <= 1'b0;
        else
            state <= ~state;       
    end
 
    assign c = final_result;
    
endmodule