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
//    input mode,
    input sub,        
    output logic [40:0] result
    );

logic [29:0] c;
logic [29:0] x;                    
logic [34:0] y;
logic [39:0] a1;
logic [39:0] b1;
logic [40:0] c1;

//logic [14:0] a_reg;         
//logic [14:0] b_reg; 
//logic sub,s0,s1;
//logic [1:0] s2,s3;

mul mul(a,b,c);   

constant_mul constant_mul(x,s0,y); 

addsub addsub(a1,b1,sub,c1);

assign x =  s2[1] ? c[7:0] : ( s2[0] ? result[7:0] : c);

assign a1 = s1 ? y : c;

//assign b1 = s3[1] ? ( s3[0] ? result[40:15] : result ) : ( s3[0] ? result[15:8] : c[23:8]);


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
////	   a_reg <= a;
////	   b_reg <= b;
	   result <= c1;
	end 
    
    
endmodule


module k2(
    input [11:0] a,           
    input [11:0] b,
    input clk,  
    input rst,         
    output logic [11:0] c    
    );
    
logic sub,s0,s1;
logic [1:0] s2,s3;
logic [40:0] result;

logic  SC;
    
datapath datapath(.a({3'b0,a}),.b({3'b0,b}),.s0(s0),.s1(s1),.s2(s2),.s3(s3),.clk(clk),.sub(sub),.result(result));



always @(*)
	begin
	
		case (SC)
		  1'b0: // Cycle0
		  begin
		      s0  = 1'b0;
		      s1  = 1'b1;
		      s2  = 2'b10;
		      s3  = 2'b00;
		      sub = 1'b1;
		  end
		  
		  1'b1: // Cycle1
          begin
              s0  = 1'b0;
              s1  = 1'b1;
              s2  = 2'b01;    
              s3  = 2'b01;
              sub = 1'b1;
          end
     default: // ELSE
                  
          begin
                      
          end
        endcase
    end


always @(posedge clk)
  begin
    if (rst == 1'b1)
      SC <= 1'b0;
    else
      SC <= SC + 1;       
  end
 
assign c = result;
    
endmodule