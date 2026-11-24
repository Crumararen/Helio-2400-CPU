
// Yeah, guess what? I'm stupid. We can just do this.
// This multiplexer will only go on bus C.
// 0        : Register value
// 1        : Bus A
// 2 16     : ALU result
// 3 17     : LSU intdata_out
// 4 18     : Multiplier result
// 5 19     : Divider quotient
// 6 20     : Divider remainder
// 7 21     : RNG randnum
// 8 22     : Immediate (memdata_in, zero extend)
// 9        : PC
module mux							(
	input [31:0] REG, BUS, ALU, LSU, MUL, DIV, MOD, RNG, CLU, PC,
	input [ 3:0] sel,
	output reg [31:0] out					);

	always @(*) begin
		case (sel)
			4'd0: out = REG;
			4'd1: out = BUS;
			4'd2: out = ALU;
			4'd3: out = LSU;
			4'd4: out = MUL;
			4'd5: out = DIV;
			4'd6: out = MOD;
			4'd7: out = RNG;
			4'd8: out = CLU;
			4'd9: out = PC;
			default: out = 32'd0;
		endcase
	end

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

	assign eq = (a == 32'd0);
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

			if (out_enable) begin
				randnum <= randreg & mask; // my dumb ass typed this as "randname" and didn' know why it didn' work...
			end else begin
				randnum <= 32'd0;
			end
		end
	end

endmodule
	
// Oh sweet lord above heaven and earth, please save me from what i'm about to do.
// I'll actually write comments this time because this shit confuses tf outta me..
module clu                           (
	input wire         clock,        // Clock
	input wire         reset,        // Reset
	input wire         interrupt,    // IRQ pin on the CPU must feed into this
	input wire         lsu_done,     // Waiting on the LSU
	input wire         mul_done,     // Waiting on the Multiplier
	input wire         div_done,     // Waiting on the Divider
	input wire         alu_zero,     // Use ALU to see if zero for JZ/JNZ
	input wire  [15:0] memdata_in,   // Memory data passed to us by the LSU
	input wire  [31:0] bus_a,        // Internal data bus A
	input wire  [31:0] bus_b,        // Internal data bus B
	input wire  [31:0] bus_c,        // Internal data bus C
	output reg  [23:0] memaddr_out,  // Memory address out
	output wire [23:0] pc_out,       // Export value of program counter
	output wire [23:0] imm_out,      // And immediate value
	output reg         lsu_start,    // Tell the LSU to do something
	output reg  [ 3:0] alu_op,       // ALU is pretty damn simple I do believe
	output reg  [ 3:0] lsu_op,       // LSU is also pretty simple from the CLU's perspective. Not on the inside, lemme tell ya
	output reg  [ 3:0] busmuxsel,    // Tells the internal data MUX who gets the bus
	output reg  [ 3:0] reg_opera,    // Read register A on internal bus 1
	output reg  [ 3:0] reg_operb,    // Read register B on internal bus 2
	output reg  [ 3:0] reg_operc,    // Read register C on internal bus 3
	output reg  [ 3:0] reg_waddr,    // Address of register to write to, always uses bus 3
	output reg         reg_write,    // Tells the register file to write
	output reg         multiply,     // Tell the multiplier to act
	output reg         divide,       // Tell the divider to divide
	output reg         modulo,       // Tell the LSU to store the remainder instead of the divider in target register
	output reg         rnd_enable ); // Tell the random number generator to give us somethin

	// Dedicated registers
	reg [31:0] instruction;
	reg [23:0] pc, rpc;
	reg [24:0] it;
	reg        halt;
	reg        jump_en;
	reg [23:0] jump_addr;

	// Internal opcode extraction
	wire [23:0] imm24   = instruction[23:0];  // Yayyyyyy! We fixed that godawful fix from before!! it's so pretty now ^v^
	wire [ 3:0] opcode  = instruction[31:28]; // This is always either an opcode or the subcode prefix (0)
	wire [ 3:0] opera   = instruction[27:24]; // This is often used as the subcode, but is otherwise an operand
	wire [ 3:0] operb   = instruction[23:20]; // This is always an operand
	wire [ 3:0] operc   = instruction[19:16]; // This is also always an operand
	wire        memflag = instruction[16];    // This isn't related to opcode extraction, but is used by load/store as a flag

	// For the top module
	assign pc_out  = pc;
	assign imm_out = imm24;

	// State machine
	localparam S_FETCH1  = 3'd0;
	localparam S_DECODE  = 3'd1;
	localparam S_FETCH2  = 3'd2;
	localparam S_EXECUTE = 3'd3;
	localparam S_WAIT    = 3'd4;

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
		end else begin
			state <= next_state;
		end
	end

	always @(*) begin
		next_state = state;
		case (state)
			S_FETCH1: begin 
				if (!halt && lsu_done && !interrupt && it[24] == 0) next_state = S_DECODE;
				else if (!halt && lsu_done && it[24] == 1) next_state = S_DECODE;
			end
			S_DECODE: begin
				if (instruction[31:28] >= 4'h1 && instruction[31:28] <= 4'h5)
					next_state = S_FETCH2;
				else
					next_state = S_EXECUTE;
			end
			S_FETCH2: if (lsu_done) next_state = S_EXECUTE;
			S_EXECUTE: begin
				if (lsu_op != 4'd0 || multiply || divide || rnd_enable)
					next_state = S_WAIT;
				else
					next_state = S_FETCH1;
			end
			S_WAIT: begin
				if (lsu_done || mul_done || div_done || opcode == 4'hB)
					next_state = S_FETCH1;
			end
		endcase
	end

	always @(posedge clock or posedge reset) begin
		if (reset) begin
			instruction    <= 32'h00000000;
			rpc            <= 24'h000000;
			it             <= 25'b1000000000000000000000000;
			pc             <= 24'h000000;
			halt           <= 1'b0;
		end else begin
			if (interrupt && it[24] == 0 && state == S_FETCH1) begin
				rpc    <= pc;
				it[24] <= 1'b1;
				pc     <= it[23:0];
			end

			case (state)
				S_FETCH1: begin
					if (lsu_done && !interrupt && !halt) begin
						instruction[31:16] <= memdata_in;
						pc                 <= pc + 2;
					end
				end

				S_FETCH2: begin
					if (lsu_done) begin
						instruction[15:0] <= memdata_in;
						pc                <= pc + 2;
					end
				end

				S_EXECUTE: begin
					if (opcode == 4'h0 && opera == 4'h1) // HALT
						halt <= 1'b1;
					else if (jump_en) begin
						pc <= jump_addr;
					end else if (opcode == 4'h0 && opera == 4'hF) begin // I know, it's weird, but IRET is here.
						pc     <= rpc;
						rpc    <= 24'h000000;
						case (operb)
							4'h0:    it[24]   <=  1'b0;
							4'h1:    it[24]   <=  1'b1;
							4'h2:    it[24]   <=  1'b0;
							4'h3:    it[23:0] <=  pc + 24'd2;
							4'h4:    it[24:0] <= {1'b0, (pc + 24'd2)};
							default: it[24]   <=  1'b0;
						endcase

					end
				end

				S_WAIT: begin

					if (opcode == 4'h6 && lsu_done) begin
						pc <= bus_c[23:0];
					end

				end

			endcase
		end
	end

	// Datapath contr
	always @(*) begin
		// Default control signal defaults
		lsu_start   = 1'b0;
		reg_write   = 1'b0;		
		alu_op      = 4'b0000;
		lsu_op      = 4'b0000;
		reg_opera   = 4'b0000;
		reg_operb   = 4'b0000;
		reg_operc   = 4'b0000;
		reg_waddr   = 4'b0000;
		busmuxsel   = 4'b0000;
		memaddr_out = 24'b00;
		multiply    = 0;
		divide      = 0;
		modulo      = 0;
		rnd_enable  = 0;
		jump_en     = 0;
		jump_addr   = 24'h0;

		if (state == S_FETCH1 || state == S_FETCH2) begin
			memaddr_out = pc;
			lsu_op      = 4'd11;
			lsu_start   = 1;
		end

		if ((opcode == 4'hC || opcode == 4'hD || opcode == 4'hE || opcode == 4'hF) && (state == S_EXECUTE))
			memaddr_out = bus_a[23:0];

		if (state == S_EXECUTE || state == S_WAIT) begin
			case (opcode)
				// First, let's deal with the subcodes.
				4'h0: begin
					case (opera)
						4'h2: begin // PUSH
							reg_opera = operb;
							lsu_op    = 4'd5;
						end
	
						4'h3: begin // POP
							reg_waddr = operb;
							busmuxsel = 4'd3;
							regwrite  = 1;
							lsu_op    = 4'd6;
						end
	
						4'h4: begin // ADD
							busmuxsel = 4'd2;
							reg_opera = operb;
							reg_operb = operc;
							reg_waddr = operb;
							reg_write = 1;
							alu_op    = 4'd0;
						end
	
						4'h5: begin // MUL
							busmuxsel = 4'd4;
							reg_opera = operb;
							reg_operb = operc;
							reg_waddr = operb;
							if (state == S_EXECUTE) begin
								multiply = 1;
							end else if (state == S_WAIT) begin
								multiply = 0;
							end
						end
	
						4'h6: begin // SUB
							busmuxsel = 4'd2;
							reg_opera = operb;
							reg_operb = operc;
							reg_waddr = operb;
							reg_write = 1;
							alu_op    = 4'd1;
						end
	
						4'h7: begin // DIV
							busmuxsel = 4'd5;
							reg_opera = operb;
							reg_operb = operc;
							reg_waddr = operb;
							if (state == S_EXECUTE) begin
								divide = 1;
								modulo    = 0;
							end else if (state == S_WAIT) begin
								divide = 0;
								modulo    = 0;
							end
						end
	
						4'h8: begin // MOD
							busmuxsel = 4'd6;
							reg_opera = operb;
							reg_operb = operc;
							reg_waddr = operb;
							if (state == S_EXECUTE) begin
								divide = 1;
								modulo = 1;
							end else if (state == S_WAIT) begin
								divide = 0;
							end
						end
	
						4'h9: begin // AND
							busmuxsel = 4'd2;
							reg_opera = operb;
							reg_operb = operc;
							reg_waddr = operb;
							reg_write = 1;
							alu_op    = 4'd2;
						end
	
						4'hA: begin // OR
							busmuxsel = 4'd2;
							reg_opera = operb;
							reg_operb = operc;
							reg_waddr = operb;
							reg_write = 1;
							alu_op    = 4'd3;
						end
	
						4'hB: begin // XOR
							busmuxsel = 4'd2;
							reg_opera = operb;
							reg_operb = operc;
							reg_waddr = operb;
							reg_write = 1;
							alu_op    = 4'd4;
						end
	
						4'hC: begin // NOT
							busmuxsel = 4'd2;
							reg_opera = operb;
							reg_operb = operc;
							reg_waddr = operb;
							reg_write = 1;
							alu_op    = 4'd5;
						end
	
						4'hD: begin // MOV
							reg_opera = operc;
							reg_waddr = operb;
							busmuxsel = 4'd1;
							reg_write = 1;
						end
	
						4'hE: begin // MOVPC
							busmuxsel = 4'd9;
							reg_waddr = operb;
							reg_write = 1;
						end
	
						4'hF: ; // IRET is handled elsewhere

						default: ;
	
					endcase
	
				end
				// Alright, let's handle our main codes now.
				4'h1: begin // LOADI
					if (state == S_EXECUTE) begin
						busmuxsel = 4'd8;
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
					busmuxsel = 4'd9;
					lsu_op    = 4'd7;
					jump_en   = 1;
					jump_addr = imm24;
				end
	
				4'h6: begin // RET
					lsu_op    = 4'd8;
				end
	
				4'h7: begin // SHL
					reg_opera = opera;
					reg_operb = operb;
					reg_waddr = opera;
					busmuxsel = 4'd2;
					reg_write = 1;
					alu_op    = 4'd6;
				end
	
				4'h8: begin // SHR
					reg_opera = opera;
					reg_operb = operb;
					reg_waddr = opera;
					busmuxsel = 4'd2;
					reg_write = 1;
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
					if (state == S_EXECUTE) rnd_enable = 1'b1;
				end
	
				4'hC: begin // LOAD
					reg_operc = operb;
					reg_waddr = opera;
					busmuxsel = 4'd0;
					regwrite  = 1;
					lsu_op    = memflag ? 4'd3 : 4'd1;
				end
	
				4'hD: begin // STORE
					reg_operc = opera;
					reg_operb = operb;
					busmuxsel = 4'd0;
					lsu_op    = memflag ? 4'd4 : 4'd2;
				end
	
				4'hE: begin // WCHR
					reg_operc = opera;   // Address in first operand
					reg_opera = operb;   // Palette data in second operand
					reg_operb = operc;   // Character in first
					busmuxsel = 4'd0;
					lsu_op    = 4'd9;
				end
	
				4'hF: begin // RCHR
					reg_operc = opera;
					reg_waddr = operb;
					busmuxsel = 4'd0;
					regwrite  = 1;
					lsu_op    = 4'd10;
				end
	
				default: ;
	
			endcase
		end

		if (state == S_WAIT) begin
			lsu_start = 0;
			multiply  = 0;
			divide    = 0;
			if (mul_done) begin 
				busmuxsel = 4'd4;
				reg_write = 1;
				reg_waddr = operb;
			end
			if (div_done) begin
				busmuxsel = (opera == 4'h8) ? 6 : 5;
				reg_write = 1;
				reg_waddr = operb;
			end
		end

		if (state == S_EXECUTE && lsu_op != 0)
			lsu_start = 1;
		if (state == S_WAIT && (lsu_op != 4'd0 && lsu_done)
			busmuxsel = 4'd3;
		if (state == S_WAIT && opcode == 4'hB) begin
			busmuxsel = 4'd7;
			reg_waddr = opera;
			reg_write = 1;
		end
	end

endmodule
