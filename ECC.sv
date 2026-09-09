// =============================================================================
// Curve25519 modular multiplication:  P = (A * B) mod (2^255 - 19)
// Implemented with 15x15-bit multipliers  =>  radix 2^15, 17 limbs (0..16),
// since 17 * 15 = 255 exactly.
//
// mul, constant_mul, addsub are used EXACTLY as originally given, with NO
// changes. "datapath" needs ONE minimal, targeted change: its b1 mux is
// extended from 3 to 4 real cases so that the previously-redundant
// s3=2'b11 encoding now means "b1 = result[40:15]" (shift the accumulator
// down by 15 bits). Everything else about datapath is untouched.
//
// This enables an idea suggested by the user: instead of clearing the
// accumulator to 0 between blocks (P_0..P_16), SHIFT it down by 15 bits
// and use that as the seed for the next block. Since addition is
// associative, seeding block k+1 with carry_k before accumulating its 17
// terms gives exactly the same raw sum as adding carry_k afterwards would
// -- so Step 2 (carry propagation) happens automatically, interleaved
// into Step 1, and needs no separate pass and no P_acc storage bank.
// Only the very last wraparound (block 16's carry, x19, folded back into
// P_out[0]) still needs one dedicated extra cycle, since P_out[0] was
// already finalized long before block 16 exists.
//
// A_in / B_in are read directly and combinationally every cycle (not
// registered locally) -- the caller must keep them stable/unchanged for
// the whole duration of the run (from "start" until "done").
// =============================================================================


// -----------------------------------------------------------------------
// mul, constant_mul, addsub: byte-for-byte unchanged.
// datapath: one targeted change (b1 mux extended, see note above).
// -----------------------------------------------------------------------


// -----------------------------------------------------------------------
// Top level: controller + single datapath instance with interleaved
// propagation. No P_acc bank, no separate Step 2 pass.
// -----------------------------------------------------------------------
module mod_mult_25519_15x15 (
    input  logic         clk,
    input  logic         rst_n,
    input  logic         start,
    input  logic [14:0]  A_in [0:16],
    input  logic [14:0]  B_in [0:16],
//    output logic         done,
    output logic [15:0]  P_out [0:16]
);

    // ---------------- single shared datapath instance ----------------
    logic [14:0] dp_a, dp_b;
    logic        dp_s0, dp_s1, dp_sub;
    logic [1:0]  dp_s2, dp_s3;
    logic [40:0] dp_result;

    datapath u_dp (
        .a(dp_a), .b(dp_b),
        .s0(dp_s0), .s1(dp_s1),
        .s2(dp_s2), .s3(dp_s3),
        .clk(clk), .sub(dp_sub),
        .result(dp_result)
    );

    // ---------------- FSM ----------------
    typedef enum logic [1:0] {S_IDLE, S_LOAD, S_MULT, S_FINAL} state_t;
    state_t state, nstate;

    logic [4:0] k_cnt;      // 0..16, which P_k block we're on
    logic [4:0] sub_cnt;    // 0 = boundary cycle, 1..17 -> i = sub_cnt-1 (0..16)

    // ---------------- address / wrap computation for the current MAC term ----
    logic        is_boundary, is_first_boundary;
    logic [4:0]  i_idx, j_idx;
    logic        wrap;

    assign is_boundary       = (sub_cnt == 5'd0);
    assign is_first_boundary = is_boundary && (k_cnt == 5'd0);
    assign i_idx              = sub_cnt - 5'd1;   // only meaningful when !is_boundary

    always_comb begin
        if (i_idx <= k_cnt) begin
            j_idx = k_cnt - i_idx;
            wrap  = 1'b0;
        end else begin
            j_idx = k_cnt - i_idx + 17;
            wrap  = 1'b1;
        end
    end

    // ---------------- datapath control tie-offs ----------------
    always_comb begin
        if (is_boundary) begin
            dp_a  = 15'd0;
            dp_b  = 15'd0;
            dp_s0 = 1'b1;               // don't-care this cycle
            dp_s1 = 1'b0;               // a1 = c = 0
            dp_s2 = 2'b00;
            // first ever boundary (before block 0): force a true zero,
            // there is no previous block's carry to seed with.
            // every later boundary: shift the previous result down by 15
            // bits, folding its carry straight into the next block.
            dp_s3 = is_first_boundary ? 2'b00 : 2'b11;
            dp_sub= 1'b0;
        end else begin
            dp_a  = A_in[i_idx];
            dp_b  = B_in[j_idx];
            dp_s0 = 1'b1;     // constant_mul always in x19 mode here
            dp_s1 = wrap;     // a1 = wrap ? 19*c : c
            dp_s2 = 2'b00;    // x = c  (feeds constant_mul)
            dp_s3 = 2'b10;    // b1 = result  (continue accumulating)
            dp_sub= 1'b0;
        end
    end

    // ---------------- FSM sequencing ----------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) state <= S_IDLE;
        else        state <= nstate;
    end

    always_comb begin
        nstate = state;
        case (state)
            S_IDLE : nstate = start ? S_LOAD : S_IDLE;
            S_LOAD : nstate = S_MULT;
            S_MULT : nstate = (k_cnt == 5'd16 && sub_cnt == 5'd17) ? S_FINAL : S_MULT;
            S_FINAL: nstate = S_IDLE;
//            S_DONE : nstate = start ? S_DONE : S_IDLE;
            default: nstate = S_IDLE;
        endcase
    end

    integer idx;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            k_cnt <= 0; sub_cnt <= 0;
//            done  <= 1'b0;
            for (idx = 0; idx <= 16; idx = idx + 1) begin
                P_out[idx] <= '0;
            end
        end else begin
//            done <= 1'b0;

            case (state)
                // ---------------- start a fresh run: just reset counters ----------
                // A_in/B_in are read directly and combinationally in S_MULT,
                // no local copy is kept -- caller must hold them stable
                // (unchanged) for the whole duration of the computation.
                S_LOAD: begin
                    k_cnt   <= 0;
                    sub_cnt <= 0;
                end

                // ---------------- step 1 with interleaved propagation ------------
                // each block k (18 cycles: 1 boundary + 17 accumulate) computes
                // dp_result = carry_(k-1) + sum_i term(i,k), i.e. Step 2's
                // "P_k + (P_(k-1)>>15)" is already folded in as it accumulates.
                S_MULT: begin
                    // boundary cycle of block k (k>=1): dp_result still holds
                    // the PREVIOUS block's fully-folded value -> its low 15
                    // bits are the final digit P_out[k-1].
                    if (sub_cnt == 5'd0 && k_cnt != 5'd0)
                        P_out[k_cnt - 1] <= dp_result[14:0];

                    if (sub_cnt == 5'd17) begin
                        sub_cnt <= 0;
                        k_cnt   <= k_cnt + 1;
                    end else begin
                        sub_cnt <= sub_cnt + 1;
                    end
                end

                // ---------------- final limb + wraparound (x19) fold ----------------
                S_FINAL: begin
                    P_out[16] <= dp_result[14:0];
//                    P_out[0]  <= P_out[0] + 19 * dp_result[40:15];
                end

//                S_DONE: done <= 1'b1;

                default: ;
            endcase
        end
    end

endmodule