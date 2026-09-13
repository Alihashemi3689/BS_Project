// =============================================================================
// Curve25519 modular multiplication
//
// Radix = 2^17
// Number of limbs = 15
// 15 * 17 = 255
//
// Each hardware multiplication:
//      17 x 17 -> 34 bits
//
// p = 2^255 - 19
//
// datapath:
//   x mux:
//      00 -> c
//      01 -> result[16:0]
//      10 -> c[16:0]
//      11 -> result[41:17]
//
//   b1 mux:
//      00 -> c[33:17]
//      01 -> result[16:8]
//      10 -> result
//      11 -> result[41:17]
//
// Accumulator is 42 bits.
// =============================================================================


//(* use_dsp48 = "no" *)
module mul(
    input  logic [16:0] a,
    input  logic [16:0] b,
    output logic [33:0] c
);

assign c = a * b;

endmodule


// -----------------------------------------------------------------------------
// constant_mul
//
// s0 = 1:
//      y = x + (x<<4) + (x<<1)
//        = 19*x
//
// s0 = 0:
//      y = x + (x<<3) + (x<<2)
//        = 13*x
//
// Only 19*x is used by the Curve25519 folding paths.
// -----------------------------------------------------------------------------

module constant_mul(
    input  logic [35:0] x,
    input logic         s0,
    output logic [40:0] y
);

logic [39:0] z1;
logic [37:0] z2;
logic [40:0] z;

assign z1 = s0 ? (x << 4) : (x << 3);
assign z2 = s0 ? (x << 1) : (x << 2);

assign z = z1 + z2;
assign y = x + z;

endmodule


// -----------------------------------------------------------------------------
// add/sub
//
// 42-bit accumulator datapath.
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
// Shared datapath
// -----------------------------------------------------------------------------

module datapath(
    input  logic [16:0] a,
    input  logic [16:0] b,

    input logic         s0,
    input logic         s1,

    input logic [1:0]   s2,
    input logic [1:0]   s3,

    input logic         clk,
    input logic         sub,

    output logic [43:0] result
);

logic [33:0] c;
logic [35:0] x;

logic [38:0] y;

logic [42:0] a1;
logic [42:0] b1;

logic [43:0] c1;


mul u_mul(
    .a(a),
    .b(b),
    .c(c)
);

constant_mul u_constant_mul(
    .x(x),
    .s0(s0),
    .y(y)
);

addsub u_addsub(
    .a(a1),
    .b(b1),
    .sub(sub),
    .c(c1)
);


// -----------------------------------------------------------------------------
// x mux
//
// 00 : c
// 01 : low 17 bits of result
// 10 : low 17 bits of multiplication result
// 11 : carry of accumulator
//
// NEW radix-2^17 carry path:
//      result[41:17]
// -----------------------------------------------------------------------------

always_comb begin

    case (s2)

        2'b00:
            x = c;

        2'b01:
            x = result[7:0];

        2'b10:
            x = c[7:0];

        2'b11:
            x = result[43:17];

    endcase

end


// -----------------------------------------------------------------------------
// a1 mux
// -----------------------------------------------------------------------------

assign a1 = s1? y : c;


// -----------------------------------------------------------------------------
// b1 mux
//
// 00 : c[33:17]
// 01 : result[16:8]
// 10 : entire accumulator
// 11 : carry shifted down into next limb
// -----------------------------------------------------------------------------

always_comb begin

    case (s3)
        2'b00: b1 = c[23:8];
        2'b01: b1 = result[15:8];
        2'b10: b1 = result;
        2'b11: b1 = result[43:17];

    endcase

end


// -----------------------------------------------------------------------------
// accumulator register
// -----------------------------------------------------------------------------

always_ff @(posedge clk) begin
    result <= c1;
end

endmodule



// =============================================================================
// TOP LEVEL
// =============================================================================

module mul_mod_25519_17x17 (

    input  logic         clk,
    input  logic         rst_n,
    input  logic         start,

    input  logic [16:0]  A_in [0:14],
    input  logic [16:0]  B_in [0:14],

    output logic         done,

    output logic [16:0]  P_out [0:14]
);


    // =========================================================================
    // Working registers
    // =========================================================================

    logic [16:0] Preg [0:14];


    genvar g;

    generate
        for (g = 0; g < 15; g = g + 1) begin : GEN_POUT
            assign P_out[g] = Preg[g];
        end
    endgenerate


    // =========================================================================
    // Shared datapath
    // =========================================================================

    logic [16:0] dp_a;
    logic [16:0] dp_b;

    logic        dp_s0;
    logic        dp_s1;

    logic [1:0]  dp_s2;
    logic [1:0]  dp_s3;

    logic        dp_sub;

    logic [43:0] dp_result;


    datapath u_dp (

        .a(dp_a),
        .b(dp_b),

        .s0(dp_s0),
        .s1(dp_s1),

        .s2(dp_s2),
        .s3(dp_s3),

        .clk(clk),
        .sub(dp_sub),

        .result(dp_result)

    );


    // =========================================================================
    // FSM
    // =========================================================================

    typedef enum logic [3:0] {

        S_IDLE,

        S_LOAD,

        S_MULT,

        S_PASSA_SEED,
        S_PASSA_STEP,
        S_PASSA_CAP,

        S_PASSB_SEED,
        S_PASSB_STEP,
        S_PASSB_CAP,

        S_PASSC_SEED,
        S_PASSC_STEP,
        S_PASSC_CHK,

        S_PASSC_COMMIT_SEED,
        S_PASSC_COMMIT_STEP,
        S_PASSC_COMMIT_CAP,

        S_DONE

    } state_t;


    state_t state;
    state_t nstate;


    // =========================================================================
    // Counters
    //
    // k_cnt    = 0..14
    // sub_cnt  = 0..15
    // p_cnt    = 0..14
    // =========================================================================

    logic [3:0] k_cnt;
    logic [4:0] sub_cnt;
    logic [3:0] p_cnt;


    // =========================================================================
    // Pass-1 indexing
    // =========================================================================

    logic       is_boundary;
    logic       is_first_boundary;

    logic [4:0] i_idx;
    logic [4:0] j_idx;

    logic       wrap;


    assign is_boundary =
        (sub_cnt == 5'd0);


    assign is_first_boundary =
        is_boundary &&
        (k_cnt == 4'd0);


    assign i_idx =
        sub_cnt - 5'd1;


    // -------------------------------------------------------------------------
    // j = k-i mod 15
    // -------------------------------------------------------------------------

    always_comb begin

        if (i_idx <= k_cnt) begin

            j_idx = k_cnt - i_idx;
            wrap  = 1'b0;

        end
        else begin

            j_idx = k_cnt - i_idx + 5'd15;
            wrap  = 1'b1;

        end

    end


    // =========================================================================
    // Datapath control
    // =========================================================================

    always_comb begin

        // defaults

        dp_a   = 17'd0;
        dp_b   = 17'd0;

        dp_s0  = 1'b1;
        dp_s1  = 1'b0;

        dp_s2  = 2'b00;
        dp_s3  = 2'b10;

        dp_sub = 1'b0;


        case (state)


            // =================================================================
            // PASS 1
            // =================================================================

            S_MULT: begin

                if (is_boundary) begin

                    dp_a  = 17'd0;
                    dp_b  = 17'd0;

                    dp_s1 = 1'b0;

                    // First boundary:
                    // simply clear/start accumulator.
                    //
                    // Later boundaries:
                    // shift carry from previous k into current limb.
                    //
                    dp_s3 =
                        is_first_boundary
                        ? 2'b00
                        : 2'b11;

                end

                else begin

                    dp_a = A_in[i_idx];
                    dp_b = B_in[j_idx];

                    // If i > k:
                    //
                    // contribution is multiplied by 19 because
                    //
                    // 2^255 = 19 (mod p)
                    //
                    dp_s1 = wrap;

                    dp_s3 = 2'b10;

                end

            end


            // =================================================================
            // PASS A / PASS B seed
            //
            // x = accumulator carry
            //
            // y = 19 * carry
            // =================================================================

            S_PASSA_SEED,
            S_PASSB_SEED: begin

                dp_a = 17'd0;
                dp_b = 17'd0;

                dp_s0 = 1'b1;
                dp_s1 = 1'b1;

                // x = result[41:17]
                dp_s2 = 2'b11;

                // no previous value
                dp_s3 = 2'b00;

            end


            // =================================================================
            // PASS C seed
            //
            // Add 19 to the current value.
            //
            // This is equivalent to testing/subtracting
            //
            //       p = 2^255 - 19
            //
            // because:
            //
            //       x >= p
            //
            // iff
            //
            //       x + 19 >= 2^255
            // =================================================================

            S_PASSC_SEED,
            S_PASSC_COMMIT_SEED: begin

                dp_a = 17'd19;
                dp_b = 17'd1;

                dp_s1 = 1'b0;

                dp_s3 = 2'b00;

            end


            // =================================================================
            // PASS A CAP
            //
            // Hold accumulator for one cycle so the registered datapath
            // result is stable before checking final carry.
            // =================================================================

            S_PASSA_CAP: begin

                dp_a   = 17'd0;
                dp_b   = 17'd0;

                dp_s1  = 1'b0;
                dp_s3  = 2'b10;

            end


            // =================================================================
            // Limb propagation
            // =================================================================

            S_PASSA_STEP,
            S_PASSB_STEP,
            S_PASSC_STEP,
            S_PASSC_COMMIT_STEP: begin

                dp_a = Preg[p_cnt];
                dp_b = 17'd1;

                dp_s1 = 1'b0;

                // limb 0:
                //
                // add seed/result directly
                //
                // limb > 0:
                //
                // add carry from previous limb
                //
                dp_s3 =
                    (p_cnt == 4'd0)
                    ? 2'b10
                    : 2'b11;

            end


            default: begin
            end

        endcase

    end


    // =========================================================================
    // FSM state register
    // =========================================================================

    always_ff @(posedge clk or negedge rst_n) begin

        if (!rst_n)
            state <= S_IDLE;

        else
            state <= nstate;

    end


    // =========================================================================
    // FSM next-state logic
    // =========================================================================

    always_comb begin

        nstate = state;

        case (state)


            S_IDLE:
                nstate =
                    start
                    ? S_LOAD
                    : S_IDLE;


            S_LOAD:
                nstate = S_MULT;


            // -----------------------------------------------------------------
            // 15 boundaries + 15 multiply cycles
            //
            // sub_cnt = 0       -> boundary
            // sub_cnt = 1..15   -> 15 products
            // -----------------------------------------------------------------

            S_MULT:

                nstate =
                    (k_cnt == 4'd14 &&
                     sub_cnt == 5'd15)
                    ? S_PASSA_SEED
                    : S_MULT;


            // -----------------------------------------------------------------
            // Pass A
            // -----------------------------------------------------------------

            S_PASSA_SEED:
                nstate = S_PASSA_STEP;


            S_PASSA_STEP:

                nstate =
                    (p_cnt == 4'd14)
                    ? S_PASSA_CAP
                    : S_PASSA_STEP;


            S_PASSA_CAP:

                nstate =
                    (dp_result[43:17] != 0)
                    ? S_PASSB_SEED
                    : S_PASSC_SEED;


            // -----------------------------------------------------------------
            // Pass B
            //
            // Only low limbs are touched.
            //
            // See note below regarding the 3-limb bound.
            // -----------------------------------------------------------------

            S_PASSB_SEED:
                nstate = S_PASSB_STEP;


            S_PASSB_STEP:

                nstate =
                    (p_cnt == 4'd2)
                    ? S_PASSB_CAP
                    : S_PASSB_STEP;


            S_PASSB_CAP:
                nstate = S_PASSC_SEED;


            // -----------------------------------------------------------------
            // Pass C trial
            // -----------------------------------------------------------------

            S_PASSC_SEED:
                nstate = S_PASSC_STEP;


            S_PASSC_STEP:

                nstate =
                    (p_cnt == 4'd14)
                    ? S_PASSC_CHK
                    : S_PASSC_STEP;


            S_PASSC_CHK:

                nstate =
                    (dp_result[43:17] != 0)
                    ? S_PASSC_COMMIT_SEED
                    : S_DONE;


            // -----------------------------------------------------------------
            // Pass C commit
            // -----------------------------------------------------------------

            S_PASSC_COMMIT_SEED:
                nstate = S_PASSC_COMMIT_STEP;


            S_PASSC_COMMIT_STEP:

                nstate =
                    (p_cnt == 4'd14)
                    ? S_PASSC_COMMIT_CAP
                    : S_PASSC_COMMIT_STEP;


            S_PASSC_COMMIT_CAP:
                nstate = S_DONE;


            S_DONE:

                nstate =
                    start
                    ? S_DONE
                    : S_IDLE;


            default:
                nstate = S_IDLE;

        endcase

    end


    // =========================================================================
    // Sequential datapath/FSM bookkeeping
    // =========================================================================

    integer idx;


    always_ff @(posedge clk or negedge rst_n) begin

        if (!rst_n) begin

            k_cnt   <= 4'd0;
            sub_cnt <= 5'd0;
            p_cnt   <= 4'd0;

            done <= 1'b0;

            for (idx = 0; idx < 15; idx = idx + 1)
                Preg[idx] <= '0;

        end

        else begin

            done <= 1'b0;


            case (state)


                // =============================================================
                // Start
                // =============================================================

                S_LOAD: begin

                    k_cnt   <= 4'd0;
                    sub_cnt <= 5'd0;
                    p_cnt   <= 4'd0;

                end


                // =============================================================
                // PASS 1
                // =============================================================

                S_MULT: begin

                    // At boundary of next k,
                    // store the previous limb result.
                    //
                    // For k > 0:
                    //
                    // Preg[k-1] = low 17 bits
                    // of the completed accumulator.
                    //

                    if ((sub_cnt == 5'd0) &&
                        (k_cnt != 4'd0)) begin

                        Preg[k_cnt - 1'b1]
                            <= dp_result[16:0];

                    end


                    if (sub_cnt == 5'd15) begin

                        sub_cnt <= 5'd0;
                        k_cnt   <= k_cnt + 1'b1;

                    end

                    else begin

                        sub_cnt <= sub_cnt + 1'b1;

                    end

                end


                // =============================================================
                // PASS A seed
                // =============================================================

                S_PASSA_SEED: begin

                    // top limb before propagation
                    Preg[14] <= dp_result[16:0];

                    p_cnt <= 4'd0;

                end


                // =============================================================
                // PASS A
                //
                // At p_cnt = n:
                //
                //     Preg[n] + carry
                //
                // low 17 bits -> next Preg
                // upper bits   -> next carry
                // =============================================================

                S_PASSA_STEP: begin

                    if (p_cnt != 4'd0)

                        Preg[p_cnt - 1'b1]
                            <= dp_result[16:0];

                    p_cnt <= p_cnt + 1'b1;

                end


                // =============================================================
                // Pass A final limb
                // =============================================================

                S_PASSA_CAP: begin

                    Preg[14] <= dp_result[16:0];

                end


                // =============================================================
                // PASS B
                // =============================================================

                S_PASSB_SEED: begin

                    p_cnt <= 4'd0;

                end


                S_PASSB_STEP: begin

                    if (p_cnt != 4'd0)

                        Preg[p_cnt - 1'b1]
                            <= dp_result[16:0];

                    p_cnt <= p_cnt + 1'b1;

                end


                S_PASSB_CAP: begin

                    Preg[2] <= dp_result[16:0];

                end


                // =============================================================
                // PASS C trial
                //
                // NO Preg writes.
                // =============================================================

                S_PASSC_SEED: begin

                    p_cnt <= 4'd0;

                end


                S_PASSC_STEP: begin

                    p_cnt <= p_cnt + 1'b1;

                end


                // =============================================================
                // PASS C commit
                // =============================================================

                S_PASSC_COMMIT_SEED: begin

                    p_cnt <= 4'd0;

                end


                S_PASSC_COMMIT_STEP: begin

                    if (p_cnt != 4'd0)

                        Preg[p_cnt - 1'b1]
                            <= dp_result[16:0];

                    p_cnt <= p_cnt + 1'b1;

                end


                S_PASSC_COMMIT_CAP: begin

                    Preg[14] <= dp_result[16:0];

                end


                // =============================================================
                // DONE
                // =============================================================

                S_DONE: begin

                    done <= 1'b1;

                end


                default: begin
                end

            endcase

        end

    end

endmodule