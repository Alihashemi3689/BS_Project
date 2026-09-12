// =============================================================================
// Curve25519 modular multiplication:  P = (A * B) mod (2^255 - 19)
// Implemented with 15x15-bit multipliers  =>  radix 2^15, 17 limbs (0..16),
// since 17 * 15 = 255 exactly.
//
// datapath needs TWO minimal, targeted changes (both reuse previously
// redundant mux encodings, nothing removed):
//   - x  mux (feeds constant_mul): new case s2=2'b11 -> x = result[40:15]
//     (lets constant_mul compute 19 * carry directly from datapath's own
//     accumulator, no external multiplier needed)
//   - b1 mux: new case s3=2'b11 -> b1 = result[40:15]  (already added in
//     an earlier revision, reused here for every "shift the carry into
//     the next limb" step)
//
// ALL carry propagation (not just the multiply) is now done through the
// datapath itself: each limb is fed in via mul (a=Preg[k], b=1 => c=Preg[k]),
// added to the running carry held in "result", and the low 15 bits are
// read back out of "result" one cycle later into Preg[].
//
// Overall flow, exactly as specified by the user:
//   Pass 1 (S_LOAD/S_MULT)      : interleaved schoolbook multiply, same as
//                                  before.
//   Pass A (S_PASSA_*)          : fold block 16's carry (x19, via the new
//                                  x-mux case) as the seed, then ONE full
//                                  17-limb propagation through datapath.
//                                  Its own carry-out (<=1 bit, S_PASSA_CAP)
//                                  is checked.
//   Pass B (S_PASSB_*)          : only runs if Pass A produced a carry.
//                                  Folds 19*carry as the seed and
//                                  propagates through just limb0, limb1,
//                                  limb2 (per the user's own bound), then
//                                  stops -- no further limbs touched.
//   Pass C (S_PASSC_*)          : inserts the constant 19 and does a full
//                                  17-limb TRIAL propagation (no writes).
//                                  If that produces a final carry-out
//                                  (meaning the value was >= p), the same
//                                  pass is redone committing the writes.
//                                  Otherwise Preg (from Pass A/B) is left
//                                  untouched and is the final answer.
// =============================================================================

(* use_dsp48 = "no" *)
module mul(
    input [14:0] a,           
    input [14:0] b,           
    output [29:0] c    
    );
    
assign c = a * b;
    
endmodule

module constant_mul(
    input [29:0] x,
    input s0,                    
    output [34:0] y  
    );

logic [33:0] z1;
logic [31:0] z2;
logic [34:0] z;
    
assign z1 = s0 ? (x << 4) : (x << 3);
assign z2 = s0 ? (x << 1) : (x << 2);
assign z = z1 + z2;

assign y = x + z;
    
endmodule

module addsub(
    input [39:0] a,           
    input [39:0] b, 
    input sub,          
    output [40:0] c    
    );
    
assign c = sub ? (a - b) : (a + b);
    
endmodule


module datapath(
    input [14:0] a,           
    input [14:0] b, 
    input s0,s1,
    input [1:0] s2,s3,
    input clk,
    input sub,        
    output logic [40:0] result
    );

logic [29:0] c;
logic [29:0] x;                    
logic [34:0] y;
logic [39:0] a1;
logic [39:0] b1;
logic [40:0] c1;

mul mul(a,b,c);   

constant_mul constant_mul(x,s0,y); 

addsub addsub(a1,b1,sub,c1);

// x mux: extended from the original 3-way ternary to a real 4-way case.
// s2=00 -> c        (unchanged)
// s2=01 -> result[7:0]  (unchanged)
// s2=10 -> c[7:0]   (unchanged)
// s2=11 -> result[40:15]  (NEW: feed the datapath's own carry straight
//          into constant_mul, so 19*carry can be computed with no
//          external multiplier)
always_comb begin
    case (s2)
        2'b00: x = c;
        2'b01: x = result[7:0];
        2'b10: x = c[7:0];
        2'b11: x = {4'b0, result[40:15]};
    endcase
end

assign a1 = s1 ? y : c;

// b1 mux: extended the same way.
// s3=00 -> c[23:8]       (unchanged)
// s3=01 -> result[15:8]  (unchanged)
// s3=10 -> result        (unchanged: add the full previous value, used
//          both for pass-1 accumulation and for a fresh seed value)
// s3=11 -> result[40:15] (shift the carry into the next limb)
always_comb begin
    case (s3)
        2'b00: b1 = c[23:8];
        2'b01: b1 = result[15:8];
        2'b10: b1 = result;
        2'b11: b1 = result[40:15];
    endcase
end

always @(posedge clk)
	begin
	   result <= c1;
	end 
    
    
endmodule


// -----------------------------------------------------------------------
// Top level
// -----------------------------------------------------------------------
module mod_mult_25519_15x15 (
    input  logic         clk,
    input  logic         rst_n,
    input  logic         start,
    input  logic [14:0]  A_in [0:16],
    input  logic [14:0]  B_in [0:16],
    output logic         done,
    output logic [14:0]  P_out [0:16]   // fully canonical, 0 <= P < p
);

    // ---------------- working registers: always <= 15 bits now, since   --
    // ---------------- every "big" intermediate value now lives inside   --
    // ---------------- the datapath's own 41-bit "result" register.      --
    logic [14:0] Preg [0:16];
    assign P_out[0]  = Preg[0];  assign P_out[1]  = Preg[1];
    assign P_out[2]  = Preg[2];  assign P_out[3]  = Preg[3];
    assign P_out[4]  = Preg[4];  assign P_out[5]  = Preg[5];
    assign P_out[6]  = Preg[6];  assign P_out[7]  = Preg[7];
    assign P_out[8]  = Preg[8];  assign P_out[9]  = Preg[9];
    assign P_out[10] = Preg[10]; assign P_out[11] = Preg[11];
    assign P_out[12] = Preg[12]; assign P_out[13] = Preg[13];
    assign P_out[14] = Preg[14]; assign P_out[15] = Preg[15];
    assign P_out[16] = Preg[16];

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
    typedef enum logic [3:0] {
        S_IDLE, S_LOAD, S_MULT,
        S_PASSA_SEED, S_PASSA_STEP, S_PASSA_CAP,
        S_PASSB_SEED, S_PASSB_STEP, S_PASSB_CAP,
        S_PASSC_SEED, S_PASSC_STEP, S_PASSC_CHK,
        S_PASSC_COMMIT_SEED, S_PASSC_COMMIT_STEP, S_PASSC_COMMIT_CAP,
        S_DONE
    } state_t;
    state_t state, nstate;

    logic [4:0] k_cnt;      // pass 1: 0..16, which P_k block
    logic [4:0] sub_cnt;    // pass 1: 0 = boundary, 1..17 -> i = sub_cnt-1
    logic [4:0] p_cnt;      // shared limb counter for pass A/B/C ripples

    // ================== PASS 1 : interleaved schoolbook multiply ==========
    logic        is_boundary, is_first_boundary;
    logic [4:0]  i_idx, j_idx;
    logic        wrap;

    assign is_boundary       = (sub_cnt == 5'd0);
    assign is_first_boundary = is_boundary && (k_cnt == 5'd0);
    assign i_idx             = sub_cnt - 5'd1;

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
        // sensible defaults
        dp_a = 15'd0; dp_b = 15'd0; dp_s0 = 1'b1; dp_s1 = 1'b0;
        dp_s2 = 2'b00; dp_s3 = 2'b10; dp_sub = 1'b0;

        case (state)
            // ---------------- pass 1 (unchanged) ----------------
            S_MULT: begin
                if (is_boundary) begin
                    dp_a = 15'd0; dp_b = 15'd0; dp_s1 = 1'b0;
                    dp_s3 = is_first_boundary ? 2'b00 : 2'b11;
                end else begin
                    dp_a = A_in[i_idx]; dp_b = B_in[j_idx];
                    dp_s1 = wrap; dp_s3 = 2'b10;
                end
            end

            // ---------------- fold block16's carry x19 (NEW x-mux case) ----
            S_PASSA_SEED, S_PASSB_SEED: begin
                dp_a = 15'd0; dp_b = 15'd0;
                dp_s0 = 1'b1; dp_s1 = 1'b1;   // a1 = y = 19 * result[40:15]
                dp_s2 = 2'b11;                // x = result[40:15]  (NEW)
                dp_s3 = 2'b00;                // b1 = c[23:8] = 0 (c=0 since a=b=0)
            end

            // ---------------- insert the plain constant 19 ----------------
            S_PASSC_SEED, S_PASSC_COMMIT_SEED: begin
                dp_a = 15'd19; dp_b = 15'd1;   // c = 19
                dp_s1 = 1'b0;                  // a1 = c = 19
                dp_s3 = 2'b00;                 // b1 = c[23:8] = 0 (19 fits in low byte)
            end

            // ---------------- hold result steady for one cycle to settle --
            S_PASSA_CAP: begin
                dp_a = 15'd0; dp_b = 15'd0; dp_s1 = 1'b0; dp_s3 = 2'b10; // b1=result -> c1=result
            end

            // ---------------- propagate one limb (shared shape) ----------
            S_PASSA_STEP, S_PASSB_STEP, S_PASSC_STEP, S_PASSC_COMMIT_STEP: begin
                dp_a = Preg[p_cnt]; dp_b = 15'd1;   // c = Preg[p_cnt]
                dp_s1 = 1'b0;                       // a1 = c
                dp_s3 = (p_cnt == 5'd0) ? 2'b10 : 2'b11; // full seed vs shifted carry
            end

            default: ;
        endcase
    end

    // ---------------- FSM sequencing ----------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) state <= S_IDLE;
        else        state <= nstate;
    end

    always_comb begin
        nstate = state;
        case (state)
            S_IDLE              : nstate = start ? S_LOAD : S_IDLE;
            S_LOAD               : nstate = S_MULT;
            S_MULT               : nstate = (k_cnt == 5'd16 && sub_cnt == 5'd17) ? S_PASSA_SEED : S_MULT;
            S_PASSA_SEED          : nstate = S_PASSA_STEP;
            S_PASSA_STEP          : nstate = (p_cnt == 5'd16) ? S_PASSA_CAP : S_PASSA_STEP;
            // carry_reg equivalent (dp_result[40:15]) is settled here (held steady)
            S_PASSA_CAP           : nstate = (dp_result[40:15] != 0) ? S_PASSB_SEED : S_PASSC_SEED;
            S_PASSB_SEED          : nstate = S_PASSB_STEP;
            S_PASSB_STEP          : nstate = (p_cnt == 5'd2) ? S_PASSB_CAP : S_PASSB_STEP;
            S_PASSB_CAP           : nstate = S_PASSC_SEED;
            S_PASSC_SEED          : nstate = S_PASSC_STEP;
            S_PASSC_STEP          : nstate = (p_cnt == 5'd16) ? S_PASSC_CHK : S_PASSC_STEP;
            S_PASSC_CHK           : nstate = (dp_result[40:15] != 0) ? S_PASSC_COMMIT_SEED : S_DONE;
            S_PASSC_COMMIT_SEED   : nstate = S_PASSC_COMMIT_STEP;
            S_PASSC_COMMIT_STEP   : nstate = (p_cnt == 5'd16) ? S_PASSC_COMMIT_CAP : S_PASSC_COMMIT_STEP;
            S_PASSC_COMMIT_CAP    : nstate = S_DONE;
            S_DONE                : nstate = start ? S_DONE : S_IDLE;
            default               : nstate = S_IDLE;
        endcase
    end

    integer idx;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            k_cnt <= 0; sub_cnt <= 0; p_cnt <= 0;
            done  <= 1'b0;
            for (idx = 0; idx <= 16; idx = idx + 1)
                Preg[idx] <= '0;
        end else begin
            done <= 1'b0;

            case (state)
                // ---------------- start a fresh run ----------------
                S_LOAD: begin
                    k_cnt <= 0; sub_cnt <= 0; p_cnt <= 0;
                end

                // ---------------- pass 1: interleaved MAC sweep ----------------
                S_MULT: begin
                    if (sub_cnt == 5'd0 && k_cnt != 5'd0)
                        Preg[k_cnt - 1] <= dp_result[14:0];

                    if (sub_cnt == 5'd17) begin
                        sub_cnt <= 0;
                        k_cnt   <= k_cnt + 1;
                    end else begin
                        sub_cnt <= sub_cnt + 1;
                    end
                end

                // ---------------- pass A: fold block16's carry, capture Preg[16],
                //                  seed the propagation ----------------
                S_PASSA_SEED: begin
                    Preg[16] <= dp_result[14:0];  // block16's pre-propagation value
                    p_cnt    <= 0;
                end

                // ---------------- pass A: propagate limb p_cnt --------------
                S_PASSA_STEP, S_PASSB_STEP, S_PASSC_COMMIT_STEP: begin
                    if (p_cnt != 5'd0)
                        Preg[p_cnt - 1] <= dp_result[14:0];
                    p_cnt <= p_cnt + 1;
                end

                S_PASSC_STEP: begin
                    // trial pass: track the carry chain only, write nothing
                    p_cnt <= p_cnt + 1;
                end

                // ---------------- pass A done: capture final limb16, decide -----
                S_PASSA_CAP: begin
                    Preg[16] <= dp_result[14:0];  // overwrite with propagated value
                end

                S_PASSB_SEED: begin
                    p_cnt <= 0;
                end

                S_PASSB_CAP: begin
                    Preg[2] <= dp_result[14:0];
                end

                S_PASSC_SEED, S_PASSC_COMMIT_SEED: begin
                    p_cnt <= 0;
                end

                S_PASSC_COMMIT_CAP: begin
                    Preg[16] <= dp_result[14:0];
                end

                S_DONE: done <= 1'b1;

                default: ;
            endcase
        end
    end

endmodule