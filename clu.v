
// So, for our CPU, I didn't want to deal with the weird ternary buffers
// or whatever they're called, but a 22-to-1 MUX seemed outside the realm
// of reasonable feasibility for my fantasy CPU's historical context.
// As a compromise, I thought it might be a good idea to chain 8-to-1
// MUXes into a 3-to-1 MUX in order to reduce complexity. We only need
// 22 inputs though, so the third MUX has two pins tied to ground.
module mux8							(
	input [31:0] in0, in1, in2, in3, in4, in5, in6, in7,
	input [ 2:0] sel,
	output reg [31:0] out					);

	always @(*) begin
		case (sel)
			3'd0: out = in0;
			3'd1: out = in1;
			3'd2: out = in2;
			3'd3: out = in3;
			3'd4: out = in4;
			3'd5: out = in5;
			3'd6: out = in6;
			3'd7: out = in7;
		endcase
	end

endmodule

// I have no idea if there's any point to doing any of this on
// a modern FPGA whatsoever and I may well be deluded to think
// that this would be an even remotely period-appropriate approach,
// but, idk. Just didn't feel right to do a full horrid 22-to-1 mux.
// 0 - 15 : R0-R15
// 16     : ALU result
// 17     : LSU intdata_out
// 18     : Multiplier result
// 19     : Divider quotient
// 20     : Divider remainder
// 21     : RNG randnum
// 22     : Immediate (memdata_in, zero extend)
// 23     : PC
module internaldatamux			(
	input  [31:0] sources [0:21],
	input  [ 4:0] select,
	output [31:0] out		);

	wire [31:0] outa, outb, outc;

	mux8 muxa (.in0(sources[0]), .in1(sources[1]), .in2(sources[2]), .in3(sources[3]), .in4(sources[4]), 
	.in5(sources[5]), .in6(sources[6]), .in7(sources[7]), .sel(select[2:0]), .out(outa));

	mux8 muxb (.in0(sources[8]), .in1(sources[9]), .in2(sources[10]), .in3(sources[11]), .in4(sources[12]), 
	.in5(sources[13]), .in6(sources[14]), .in7(sources[15]), .sel(select[2:0]), .out(outb));

	mux8 muxc (.in0(sources[16]), .in1(sources[17]), .in2(sources[18]), .in3(sources[19]), .in4(sources[20]), 
	.in5(sources[21]), .in6(sources[22]), .in7(sources[23]), .sel(select[2:0]), .out(outc));

	assign out = (select[4:3] == 2'b00) ? outa :
	             (select[4:3] == 2'b01) ? outb :
	             (select[4:3] == 2'b10) ? outc : 32'd0;
endmodule

// I'm not totally sure why I decided to put this, like, here,
// but regardless, this is the comparator module that the CLU
// uses for JZ, JNZ, JLT and JGT.
module comparator        (
	input [31:0] a,
	input [31:0] b,
	output       eq,
	output       lt,
	output       gt  );

	assign eq = (a == b);
	assign lt = (a < b);
	assign gt = (a > b);
endmodule

// The registers are here. Surprisingly simple.
module register_file				(
	input  clock,
	input  reset,
	input  write_enable,
	input  [ 3:0] read_addra,
	input  [ 3:0] read_addrb,
	input  [ 3:0] read_addrc,
	input  [ 3:0] write_addr,
	input  [31:0] write_data,
	output [31:0] read_dataa,
	output [31:0] read_datab,
	output [31:0] read_datac		);

	reg[31:0] regs [0:15];
	integer i;

	assign read_dataa = regs[read_addra];
	assign read_datab = regs[read_addrb];
	assign read_datac = regs[read_addrc];

	always @(posedge clock or posedge reset) begin
		if (reset) begin
			for (i = 0; i <16; i = i + 1) begin
				regs[i] <= 32'h00000000;
			end
		end else if (write_enable) begin
			regs[write_addr] <= write_data;
		end
	end

endmodule

// Random number generator
// God, this is so much more efficient than the old one...
// It used to have a state machine that ran every clock cycle.
module rngen                      (
	input       clock,
	input       reset,
	input       out_enable,
	input [6:0] output_length,
	output reg [31:0] randnum );

	reg [31:0] randreg;

	wire [31:0] x1 = randreg ^ (randreg << 13);
	wire [31:0] x2 = x1      ^ (x1      >> 17);
	wire [31:0] x3 = x2      ^ (x2      << 5);

	wire [31:0] mask = (output_length >= 7'd32) ? 32'hFFFFFFFF : ((32'd1 << output_length) - 32'd1);

	always @(posedge clock or posedge reset) begin
		if (reset) begin
			randreg <= 32'hDEADBEEF;
			randnum <= 32'd0;
		end else begin
			randreg <= (randreg == 32'd0) ? 32'hDEADBEEF : x3;

			if (out_enable)
				randnum <= randreg & mask; // my dumb ass typed this as "randname" and didn' know why it didn' work...
			else
				randnum <= 32'd0;
			end
		end
	end

endmodule
	
// Oh sweet lord above heaven and earth, please save me from what i'm about to do.
// I'll actually write comments this time because this shit confuses tf outta me..
module CLU                           (
	input wire        clock,        // Clock
	input wire        reset,        // Reset
	input wire        interrupt,    // IRQ pin on the CPU must feed into this
	input wire [15:0] memdata_in,   // Memory data in
	input wire        waitfordata,  // Waiting on the LSU
	input wire        mul_done,     // Waiting on the Multiplier
	input wire        div_done,     // Waiting on the Divider
	input wire        alu_zero,     // Use ALU to see if zero for JZ/JNZ
	input wire [31:0] bus_a,        // Internal data bus A
	input wire [31:0] bus_b,        // Internal data bus B
	input wire [31:0] bus_c,        // Internal data bus C
	output reg [23:0] memaddr_out,  // Memory address out
	output reg        mem_read,     // Tells the memory manager to read
	output reg        mem_write,    // Tells the memory manager to write
	output reg [ 3:0] alu_op,       // ALU is pretty damn simple I do believe
	output reg [ 3:0] lsu_op,       // LSU is also pretty simple from the CLU's perspective. Not on the inside, lemme tell ya
	output reg [ 3:0] reg_opera,    // Read register A on internal bus 1
	output reg [ 3:0] reg_operb,    // Read register B on internal bus 2
	output reg [ 3:0] reg_operc,    // Read register C on internal bus 3
	output reg [ 3:0] reg_waddr,    // Address of register to write to, always uses bus 3
	output reg        reg_write,    // Tells the register file to write
	output reg [ 4:0] busmuxsel,    // Tells the internal data MUX who gets the bus
	output reg        multiply,     // Tell the multiplier to act
	output reg        divide,       // Tell the divider to divide
	output reg        modulo,       // Tell the LSU to store the remainder instead of the divider in target register
	output reg        rnd_enable ); // Tell the random number generator to give us somethin

	// Dedicated registers
	reg [31:0] instruction;
	reg [23:0] pc, rpc;
	reg [24:0] it;
	reg        jump_en;
	reg [23:0] jump_addr;

	// Internal opcode extraction
	wire [ 3:0] opcode  = instruction[31:28]; // This is always either an opcode or the subcode prefix (0)
	wire [ 3:0] opera   = instruction[27:24]; // This is often used as the subcode, but is otherwise an operand
	wire [ 3:0] operb   = instruction[23:20]; // This is always an operand
	wire [ 3:0] operc   = instruction[19:16]; // This is also always an operand
	wire [23:0] imm24   = instruction[23:0];  // This is only used on a handful of instructions
	wire        memflag = instruction[0];     // This isn't related to opcode extraction, but is used by load/store as a flag

	// State machine
	localparam S_FETCH1  = 3'd0;
	localparam S_DECODE  = 3'd1;
	localparam S_FETCH2  = 3'd2;
	localparam S_EXECUTE = 3'd3;
	localparam S_WAIT    = 3'd4;
	localparam S_IRQ     = 3'd5;

	reg [2:0] state, next_state;

	// Bring innnnn the comparator!
	// Can you tell how long I've
	// been coding at this point?
	// Goin a bit crazy o'er here..
	wire comp_eq, comp_lt, comp_gt;
	comparator comp_inst (
		.a(bus_a),   
		.b(bus_b),   
		.eq(comp_eq),
		.lt(comp_lt),
		.gt(comp_gt) );

	always @(posedge clock or posedge reset) begin
		if (reset) begin
			state <= S_FETCH1;
			pc    <= 24'h000000;
			it    <= 25'h0000000;
		end else begin
			state <= next_state;
		end
	end

	always @(*) begin
		next_state = state;
		case (state)
			S_FETCH1: next_state = S_DECODE;
			S_DECODE: begin
				if (memdata_in[15:12] >= 4'h1 && memdata_in[15:12] <= 4'h5)
					next_state = S_FETCH2;
				else
					next_state = S_EXECUTE;
			end
			S_FETCH2: next_state = S_EXECUTE;
			S_EXECUTE: begin
				if (lsu_op != 4'd0 || multiply || divide)
					next_state = S_WAIT;
				else
					next_state = S_FETCH1;
			end
			S_WAIT: begin
				if (waitfordata || mul_done || div_done)
					next_state = S_FETCH1;
			end
			S_IRQ: next_state = S_FETCH1;
		endcase
	end

	always @(posedge clock or posedge reset) begin
		if (reset) begin
			instruction <= 32'h00000000;
			rpc         <= 24'h000000;

		end else begin
			if (interrupt && it[24] == 0 && state != S_IRQ) begin
				rpc    <= pc;
				it[24] <= 1'b1;
				pc     <= it[23:0];
			end

			case (state)
				S_DECODE: begin
					instruction[31:16] <= memdata_in;
					pc                 <= pc + 2;
				end

				S_EXECUTE: begin
					if (jump_en) begin
						pc <= jump_addr;
					end else if (opcode >= 4'h1 && opcode <= 4'h5) begin
						instruction[15:0] <= memdata_in;
						pc                <= pc + 2;
					end
					end else if (opcode == 4'h0 && opera == 4'hF) begin // I know, it's weird, but IRET is here.
						pc     <= rpc;
						rpc    <= 24'h000000;
						it[24] <= 1'b0;
					end
				end

				S_WAIT: begin
					if (lsu_op == 4'd8 && waitfordata) begin
						pc <=bus_c[23:0];
					end
				end

			endcase
		end
	end

	// Datapath contr
	always @(*) begin
		// Default control signal defaults
		mem_read    = 0;
		mem_write   = 1'b0;
		reg_write   = 1'b0;		
		alu_op      = 4'b0000;
		lsu_op      = 4'b0000;
		reg_opera   = 4'b0000;
		reg_operb   = 4'b0000;
		reg_operc   = 4'b0000;
		reg_waddr   = 4'b0000;
		busmuxsel   = 5'b00000;
		memaddr_out = 24'b00;
		multiply    = 0;
		divide      = 0;
		modulo      = 0;
		rnd_enable  = 0;
		jump_en     = 0;
		jump_addr   = 24'h0;

		if (state == S_FETCH1 || state == S_FETCH2) begin
			memaddr_out = pc;
			mem_read    = 1;
		end

		case (opcode)
			// First, let's deal with the subcodes.
			4'h0: begin
				case (opera)
					4'h0:      ; // NOP
					4'h1:      ; // HALT
					4'h2: begin // PUSH
						reg_opera = operb;
						busmuxsel = 5'd17;
						lsu_op    = 4'd5;
					end

					4'h3: begin; // POP
						reg_waddr = operb;
						busmuxsel = 5'd17;
						lsu_op    = 4'd6;
					end

					4'h4: begin // ADD
						busmuxsel = 5'd16;
						reg_opera = operb;
						reg_operb = operc;
						reg_waddr = operb;
						reg_write = 1;
						alu_op    = 4'd0;
					end

					4'h5: begin // MUL
						busmuxsel = 5'd18;
						reg_opera = operb;
						reg_operb = operc;
						reg_waddr = operb;
						reg_write = 1;
						multiply  = 1;
					end

					4'h6: begin // SUB
						busmuxsel = 5'd17;
						reg_opera = operb;
						reg_operb = operc;
						reg_waddr = operb;
						reg_write = 1;
						alu_op    = 4'd1;
					end

					4'h7: begin // DIV
						busmuxsel = 5'd19;
						reg_opera = operb;
						reg_operb = operc;
						reg_waddr = operb;
						reg_write = 1;
						divide    = 1;
						modulo    = 0;
					end

					4'h8: begin // MOD
						busmuxsel = 5'd20;
						reg_opera = operb;
						reg_operb = operc;
						reg_waddr = operb;
						reg_write = 1;
						divide    = 1;
						modulo    = 1;
					end

					4'h9: begin // AND
						busmuxsel = 5'd16;
						reg_opera = operb;
						reg_operb = operc;
						reg_waddr = operb;
						reg_write = 1;
						alu_op    = 4'd2;
					end

					4'hA: begin // OR
						busmuxsel = 5'd16;
						reg_opera = operb;
						reg_operb = operc;
						reg_waddr = operb;
						reg_write = 1;
						alu_op    = 4'd3;
					end

					4'hB: begin // XOR
						busmuxsel = 5'd16;
						reg_opera = operb;
						reg_operb = operc;
						reg_waddr = operb;
						reg_write = 1;
						alu_op    = 4'd4;
					end

					4'hC: begin // NOT
						busmuxsel = 5'd16;
						reg_opera = operb;
						reg_operb = operc;
						reg_waddr = operb;
						reg_write = 1;
						alu_op    = 4'd5;
					end

					4'hD: begin // MOV
						busmuxsel = 5'd17;
						reg_opera = operb;
						reg_waddr = operc;
						reg_write = 1;
					end

					4'hE: begin // MOVPC
						busmuxsel = 5'd17;
						reg_waddr = operb;
						reg_write = 1;
					end

					4'hF: ; // IRET is driven in a different block

					default: ;

				endcase

			end
			// Alright, let's handle our main codes now.
			4'h1: begin // LOADI
				if (state == S_EXECUTE) begin
					busmuxsel = 5'd22;
					reg_waddr = opera;
					reg_write = 1;
				end
			end

			4'h2: begin // JMP
				jump_en   = 1;
				jump_addr = imm24;
			end

			4'h3: begin // JZ
				reg_opera = opera;
				if (comp_eq) begin
					jump_en   = 1;
					jump_addr = imm24;
				end
			end

			4'h4: begin // JNZ
				reg_opera = opera;
				if (!comp_eq) begin
					jump_en   = 1;
					jump_addr = imm24;
				end
			end

			4'h5: begin // CALL
				busmuxsel = 5'd24;
				lsu_op    = 4'd7;
			end

			4'h6: begin // RET
				lsu_op    = 4'd8;
			end

			4'h7: begin // SHL
				reg_opera = opera;
				reg_operb = operb;
				reg_waddr = opera;
				alu_op    = 4'd6;
			end

			4'h8: begin // SHR
				reg_opera = opera;
				reg_operb = operb;
				reg_waddr = opera;
				alu_op    = 4'd7;
			end

			4'h9: begin // JLT
				reg_opera = opera;
				reg_operb = operb;
				reg_operc = operc;
				if (comp_lt) begin
					jump_en   = 1;
					jump_addr = bus_c[23:0];
				end
			end

			4'hA: begin // JGT
				reg_opera = opera;
				reg_operb = operb;
				reg_operc = operc;
				if (comp_gt) begin
					jump_en   = 1;
					jump_addr = bus_c[23:0];
				end
			end

			4'hB: begin // RND
				if (state == S_EXECUTE) begin
					rnd_enable = 1'b1;
					busmuxsel  = 5'd22;
					reg_waddr  = opera;
					reg_write  = 1'b1;
				end
			end

			4'hC: begin // LOAD
				reg_opera = operb;
				reg_waddr = opera;
				lsu_op    = memflag ? 4'd3 : 4'd1;
			end

			4'hD: begin // STORE
				reg_opera = opera;
				reg_operb = operb;
				lsu_op    = memflag ? 4'd4 : 4'd2;
			end

			4'hE: ; // WCHR
				reg_opera = opera;   // Address in first operand
				reg_operb = operb;   // Palette data in second operand
				reg_operc = operc;   // Character in first
				lsu_op    = 4'd9;
			end

			4'hF: ; // RCHR
				reg_opera = operc;
				reg_waddr = operb;
				lsu_op    = 4'd10;
			end

			default: ;

		endcase

	end

endmodule
