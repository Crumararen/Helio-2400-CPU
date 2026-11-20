
// This is the main arithmetic logic unit module...
// I love how simple and straightforward it is. 
// Such a contrast to the shit down below...
module helio_alu			(
	input  [31:0] a,
	input  [31:0] b,
	input  [ 3:0] op,
	output reg [31:0] result,
	output reg        zero		);

	localparam ALU_ADD = 4'd0;
	localparam ALU_SUB = 4'd1;
	localparam ALU_AND = 4'd2;
	localparam ALU_OR  = 4'd3;
	localparam ALU_XOR = 4'd4;
	localparam ALU_NOT = 4'd5;
	localparam ALU_SHL = 4'd6;
	localparam ALU_SHR = 4'd7;

	always @(*) begin
		case (op)
			ALU_ADD: result = a + b;
			ALU_SUB: result = a - b;
			ALU_AND: result = a & b;
			ALU_OR:  result = a | b;
			ALU_XOR: result = a ^ b;
			ALU_NOT: result = ~a;
			ALU_SHL: result = a << b[5:0];
			ALU_SHR: result = a >> b[5:0];
			default: result = 32'h00000000;
		endcase
		zero = (result == 32'h00000000) ? 1'b1 : 1'b0;
	end

endmodule

// this thing is weird and I don't totally get it, but
// this is a multiplier that I think should only take
// like 16 clock cycles to complete using radix-4 encoding
// - basically splitting everything into two-bit blocks -
// and a sequential adder in order to avoid multiplication
// going absolutely goddamn motherfucketing wild in hardware
// some weird wizardry, this is. anyways, here's multiplier
module multiplier			(
	input clock,
	input reset,
	input start,
	input [31:0] multand,
	input [31:0] multipl,
	output reg [31:0] result,
	output reg done			);

	reg [31:0] accumulator;
	reg [31:0] shift_multi;
	reg [31:0] remain_mult;
	reg [ 4:0] iterationum;
	reg [31:0] next_accum;
	reg        busy;

	always @(*) begin
		case (remain_mult[1:0])
			2'b00:   next_accum = accumulator;
			2'b01:   next_accum = accumulator + shift_multi;
			2'b10:   next_accum = accumulator + (shift_multi << 1);
			2'b11:   next_accum = accumulator + (shift_multi << 1) + shift_multi;
			default: next_accum = accumulator;

		endcase

	end

	always @(posedge clock or posedge reset) begin
		if (reset) begin
			busy   <= 0;
			done   <= 0;
			result <= 0;

		end else if (start && !busy) begin
			accumulator <= 32'd0;
			shift_multi <= multand;
			remain_mult <= multipl;
			iterationum <= 5'd16;
			busy        <= 1;
			done        <= 0;

		end else if (busy) begin
			accumulator <= next_accum;
			shift_multi <= shift_multi << 2;
			remain_mult <= remain_mult >> 2;
			iterationum <= iterationum  - 1;

			if (iterationum == 1) begin
				busy   <= 0;
				done   <= 1;
				result <= next_accum;
			end

		end else begin
			done <= 0;
		end

	end

endmodule


// Then again, if the shit above was magic bullshit,
// this shit is kinda sorcery to me. Though like...
// I feel like it'll run slow? I'm not sure rn. 
// Ugh. Hardware design is weird.
module divider				(
	input clock,
	input reset,
	input start,
	input [31:0] dividend,
	input [31:0] divisor,
	output reg [31:0] quotient,
	output reg [31:0] remainder,
	output reg done			);

	reg [63:0] curr_shiftreg;
	reg [63:0] next_shiftreg;
	reg [31:0] saved_divisor;
	reg [ 5:0] iterationum;
	reg        busy;
	reg        divz;

	always @(*) begin
		next_shiftreg = curr_shiftreg << 1;

		if (next_shiftreg[63:32] >= saved_divisor) begin
			next_shiftreg[63:32] = next_shiftreg[63:32] - saved_divisor;
			next_shiftreg[0]     = 1'b1; // I think this is the quotient
		end
	end

	always @(posedge clock or posedge reset) begin
		if (reset) begin
			busy           <= 0;
			done           <= 0;
			divz           <= 0;
			quotient       <= 0;
			remainder      <= 0;
			iterationum    <= 0;
			curr_shiftreg  <= 0;
			saved_divisor  <= 0;
		end else if (start && !busy) begin
			if (divisor == 32'd0) begin
				// Hardware div0 sentinel
				quotient  <= 32'hFFFFFFFF;
				remainder <= 32'h00000000;
				divz      <= 1;
                                done      <= 1;
				busy      <= 0;
			end else begin
				curr_shiftreg <= {32'd0, dividend};
				saved_divisor <= divisor;
				iterationum   <= 6'd32;
				busy          <= 1;
				done          <= 0;
                                divz          <= 0;
			end

			end else if (busy) begin
				curr_shiftreg <= next_shiftreg;
				iterationum   <= iterationum - 1;

				if (iterationum == 1) begin
					busy      <= 0;
					done      <= 1;
					remainder <= next_shiftreg[63:32];
					quotient  <= next_shiftreg[31:0];

				end else begin
					done <= 0;
				end

			end else begin
				done <= 0;
		end

	end

endmodule
