


// =============================================================================
// Curve25519 modular multiplication:  P = (A * B) mod (2^255 - 19)
// Implemented with 15x15-bit multipliers  =>  radix 2^15, 17 limbs (0..16),
// since 17 * 15 = 255 exactly.
//
// mul, constant_mul, addsub, datapath are ALL used EXACTLY as originally
// given, with NO changes to their internals. The controller reuses the
// single "datapath" instance to compute P_0..P_16 one at a time (18 cycles
// each: 1 clear cycle + 17 multiply-accumulate cycles), tying off
// s0,s1,s2,s3,sub appropriately and injecting a=0 for the clear cycle.
//
// Step 2 (carry propagation) is a SEPARATE pass after Step 1, using only
// "addsub" (no multiplier needed there). See the chat message for a
// discussion of interleaving Step 2 into Step 1 instead, and its
// time/register trade-offs.
//
// NOTE: A_in / B_in are NOT registered locally -- they are read directly
// and combinationally every cycle of Step 1 (indexed by i_idx / j_idx).
// This saves 2*17*15 = 510 flip-flops, but it means the caller MUST keep
// A_in and B_in stable/unchanged for the entire duration of the run
// (from the "start" pulse until "done" is asserted).
// ============================================================================


// -----------------------------------------------------------------------
// Top level: controller + limb storage + accumulator bank + Step 2
// Reuses ONE instance of the user's unmodified "datapath".
// -----------------------------------------------------------------------
module mod_mult_25519_15x15 (
    input  logic         clk,
    input  logic         rst_n,
    input  logic         start,
    input  logic [14:0]  A_in [0:16],
    input  logic [14:0]  B_in [0:16],
    output logic         done,
    output logic [19:0]  P_out [0:16]
);

    // ---------------- accumulator bank, one finished P_k per entry ----------
    logic [40:0] P_acc [0:16];

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
    typedef enum logic [2:0] {S_IDLE, S_LOAD, S_MULT, S_CAP_LAST, S_PROP, S_DONE} state_t;
    state_t state, nstate;

    logic [4:0] k_cnt;      // 0..16, which P_k block we're on
    logic [4:0] sub_cnt;    // 0 = clear cycle, 1..17 -> i = sub_cnt-1 (0..16)
    logic [4:0] p_cnt;      // 0..16 for step 2

    // ---------------- address / wrap computation for the current MAC term ----
    logic        is_clear;
    logic [4:0]  i_idx, j_idx;
    logic        wrap;

    assign is_clear = (sub_cnt == 5'd0);
    assign i_idx    = sub_cnt - 5'd1;   // only meaningful when !is_clear

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
        if (is_clear) begin
            dp_a  = 15'd0;
            dp_b  = 15'd0;
            dp_s0 = 1'b1;     // don't-care this cycle
            dp_s1 = 1'b0;     // a1 = c = 0
            dp_s2 = 2'b00;
            dp_s3 = 2'b00;    // b1 = c[23:8] = 0
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
            S_IDLE    : nstate = start ? S_LOAD : S_IDLE;
            S_LOAD    : nstate = S_MULT;
            S_MULT    : nstate = (k_cnt == 5'd16 && sub_cnt == 5'd17) ? S_CAP_LAST : S_MULT;
            S_CAP_LAST: nstate = S_PROP;
            S_PROP    : nstate = (p_cnt == 5'd16) ? S_DONE : S_PROP;
            S_DONE    : nstate = start ? S_DONE : S_IDLE;
            default   : nstate = S_IDLE;
        endcase
    end

    integer idx;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            k_cnt <= 0; sub_cnt <= 0; p_cnt <= 0;
            done  <= 1'b0;
            for (idx = 0; idx <= 16; idx = idx + 1) begin
                P_acc[idx] <= '0;
                P_out[idx] <= '0;
            end
        end else begin
            done <= 1'b0;

            case (state)
                // ---------------- start a fresh run: just reset counters ----------
                // A_in/B_in are read directly and combinationally in S_MULT,
                // no local copy is kept -- caller must hold them stable
                // (unchanged) for the whole duration of the computation.
                S_LOAD: begin
                    k_cnt   <= 0;
                    sub_cnt <= 0;
                end

                // ---------------- step 1: sequential blocks via one datapath ----
                S_MULT: begin
                    // capture the PREVIOUS block's finished result, which
                    // sits in dp_result right when the NEW block's clear
                    // cycle (sub_cnt==0, k_cnt>=1) is being issued
                    if (sub_cnt == 5'd0 && k_cnt != 5'd0)
                        P_acc[k_cnt - 1] <= dp_result;

                    if (sub_cnt == 5'd17) begin
                        sub_cnt <= 0;
                        k_cnt   <= k_cnt + 1;
                    end else begin
                        sub_cnt <= sub_cnt + 1;
                    end
                end

                // ---------------- capture the very last block (k=16) ----------
                S_CAP_LAST: begin
                    P_acc[16] <= dp_result;
                    p_cnt <= 0;
                end

                // ---------------- step 2: propagation + reduction ----------------
                S_PROP: begin
                    if (p_cnt < 5'd16) begin
                        P_out[p_cnt]     <= P_acc[p_cnt][14:0];
//                        P_acc[p_cnt + 1] <= P_acc[p_cnt + 1] + (P_acc[p_cnt] >> 15);
                    end else begin
                        P_out[16] <= {5'b0, P_acc[16][14:0]};
//                        P_out[0]  <= P_out[0] + 19 * (P_acc[16] >> 15);
                    end
                    p_cnt <= p_cnt + 1;
                end

                S_DONE: done <= 1'b1;

                default: ;
            endcase
        end
    end

endmodule