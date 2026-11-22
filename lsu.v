
// Man, this thing is a mess. I think it will work now, but like,
// Update: hahahahahhaha. No. Stale data. I fixed it now I think...
module lsu	                       (   // do not trust me on that.
	input             clock,           // Clock signal
	input             reset,           // Reset signal
	input             memready,        // Tied direct to the memready pin, goes high when memory controller is ready
	input             lsu_start,       // The CLU raises this to tell us to do something
	input      [23:0] memaddr_in,      // Memory address in, for any operation that uses external memory
	input      [31:0] outdata_in,      // Data in from the external data bus
	input      [31:0] intdata_in,      // Data in from the internal data bus; also used for second regaddr in rchr
	input      [ 7:0] auxdata_in,      // Bottom 8 bits from data bus 2 so we can fetch two separate bytes at once for WCHR.
	input      [ 3:0] regaddr_in,      // Register address in, for pop, load
	input      [ 3:0] lsu_op,          // Load-store unit operation code; push, pop, call, ret, load, store
	output reg [23:0] memaddr_out,     // Memory address out, for push, pop, call, ret, load, store
	output reg [31:0] intdata_out,     // Internal databus, for transferring data between registers
	output reg [15:0] outdata_out,     // External databus, for push, call, store operations
	output reg [ 3:0] regaddr_out,     // Register address out for regwrite, pop, load instructions
	output reg [ 1:0] stackpnt_op,  // 00 == do nothing, 01 == advance downward by 1, 10 == decrement upward by 1. it's so ugly TvT
	output reg        regwrite,        // Raise high to tell the register file to write to address 
	output reg        writeword,       // Goes direct to the FULLWORD pin on the CPU, for the memory controller's reference
	output reg        mem_write,       // Tell the memory controller to write
	output reg        mem_req,         // Ask the memory controller to do something
	output reg        lsu_done     );  // The CLU should not advance the PC on a clock signal if this is raised high

	localparam LSU_NOP   = 4'd0;   // Don't touch anything!! Gonna get yerself killed. Jaeaysus
        localparam LSU_LOAD  = 4'd1;   // Read  a single 8-bit byte at memory address in memaddr_in
        localparam LSU_STORE = 4'd2;   // Write a single 8-bit byte at memory address in memaddr_in
	localparam LSU_LOAD2 = 4'd3;   // Read  a full 16-bit-word at memory address in memaddr_in
	localparam LSU_STOR2 = 4'd4;   // Write a full 16-bit-word at memory address in memaddr_in
        localparam LSU_PUSH  = 4'd5;   // Push value of intdata_in to stack
        localparam LSU_POP   = 4'd6;   // Pop from stack into specified register in regaddr_in
        localparam LSU_CALL  = 4'd7;   // Push program counter to stack in two passes
        localparam LSU_RET   = 4'd8;   // Pop from stack twice, reconstruct the program pointer
	localparam LSU_WCHR  = 4'd9;   // Write low sixteen bits of intdata_in to memaddr
	localparam LSU_RCHR  = 4'd10;  // Read sixteen bits from address

	localparam S_IDLE    = 3'd0;   // Waiting for an instruction
	localparam S_MEMWAIT = 3'd1;   // Waiting on memory controller
	localparam S_NEXT    = 3'd2;   // Run second step of multicycle instructions
	localparam S_WB1     = 3'd3;   // Writeback 1
	localparam S_WB2     = 3'd4;   // Writeback 2 
	localparam S_DONE    = 3'd5;   // We're done, signal the CLU and go back to idle

	reg        half_select;        // if low, first half (high) - if high, second half (low)
	reg        membusyseen;        // Remains low until memready first goes low after a new memory request
	reg [15:0] first_half;         // Holds the first half of a 32-bit load from memory of any sort
	reg [15:0] rchr_data;          // Holds the 16-bit-word for the RCHR instruction
	reg [ 2:0] state;              // Tracks stage of the state machine we're in
	reg [ 3:0] operlatch;          // Protect operation across state machine
	reg [23:0] addrlatch;          // Protect address across state machine
	reg [31:0] datalatch;          // Protect data across state machine
	reg [ 7:0] auxilatch;          // Protect auxiliary data
	reg [ 3:0] destlatch;          // Protect destination 1 
	reg [ 3:0] des2latch;          // Protect destination 2
	reg [31:0] restlatch;          // Protect result
	
	// This is the state machine.. It tracks all our multicycle instructions so we know what to do on each clock cycle.
	always @(posedge clock or posedge reset) begin // You are correct, this is probably convoluted, but, i mean... fuck it.
		if (reset) begin                       // You try to teach yourself how to do this shit in a week man.
			half_select <= 0;              // Anyways, back to the program. I won't be using too many comments here
			membusyseen <= 0;              // Because this part is pretty simple, and I can't make em pretty here TvT
			lsu_done    <= 0;
			first_half  <= 16'h0000;
			state       <= S_IDLE;
			operlatch   <= LSU_NOP;
			addrlatch   <= 24'd0;
			datalatch   <= 32'd0;
			auxilatch   <= 8'd0;
			destlatch   <= 4'd0;
			des2latch   <= 4'd0;
			restlatch   <= 32'd0;
			rchr_data   <= 16'd0;

		end else begin

			case (state)

				S_IDLE: begin

					if (lsu_start) begin
						membusyseen <= 0
						half_select <= 0;
						operlatch   <= lsu_op;
						addrlatch   <= memaddr_in;
						datalatch   <= intdata_in;
						auxilatch   <= auxdata_in;
						destlatch   <= regaddr_in;
						des2latch   <= intdata_in[3:0];
						state       <= S_MEMWAIT;
					end
				end

				S_MEMWAIT: begin

					if (!membusyseen && !memready) begin
						membusyseen <= 1;
					end
					if (membusyseen && memready) begin

						case (operlatch)

							LSU_POP, LSU_RET: begin

								if(half_select == 0)
									first_half    <= outdata_in;
									state         <= S_NEXT;
								end else begin
									restlatch     <= {first_half, outdata_in};
									if (operlatch == LSU_POP)
										state <= S_WB1;
									else
										state <= S_DONE;
								end
							end

							LSU_PUSH, LSU_CALL: begin

								if (half_select == 0)
									state <= S_NEXT;
								else
									state <= S_DONE;
							end

							LSU_LOAD: begin
								restlatch <= {24'h000000, outdata_in[15:8]};
								state     <= S_WB1;
							end

							LSU_LOAD2: begin
								restlatch <= {16'h0000, outdata_in[15:0]};
								state     <= S_WB1;
							end

							LSU_RCHR: begin
								rchr_data <= outdata_in;
								state     <= S_WB1;
							end

							LSU_WCHR, LSU_STORE, LSU_STOR2: begin
								state     <= S_DONE;
							end

							default: begin
								state     <= S_DONE;
							end
						endcase
					end

				end

				S_NEXT: begin

					half_select   <= 1;
					addrlatch     <= memaddr_in;
					state         <= S_MEMWAIT;

				end

				S_WB1: begin

					if (operlatch == LSU_RCHR)
						state <= S_WB2;
					else
						state <= S_DONE;
				end

				S_WB2: begin
					state    <= S_DONE;
				end

				S_DONE: begin
					lsu_done <= 1;
					state    <= S_IDLE;
				end

				default: begin
					state    <= S_IDLE;
				end

			endcase

		end
	end

	always @(*) begin

		mem_req     = 0;
		mem_write   = 0;
		memaddr_out = addrlatch;
		outdata_out = 16'h0000;
		writeword   = 0;
		intdata_out = 32'h00000000;
		regaddr_out = destlatch;
		regwrite    = 0;
		stackpnt_op = 2'b00;

		// Alright, let's start on the combinational logic now.
		case (operlatch)
			LSU_LOAD, LSU_STORE:
				writeword = 0;
			default:
				writeword = 1;
		endcase

		case (operlatch)
			LSU_STORE: outdata_out = {datalatch[7:0], 8'h00};
			LSU_STOR2: outdata_out = datalatch[15:0];
			LSU_WCHR:  outdata_out = {datalatch[7:0], auxilatch[7:0]};
			LSU_PUSH:  outdata_out = half_select ? datalatch[15:0] : datalatch[31:16];
			LSU_CALL:  outdata_out = half_select ? datalatch[15:0] : {8'h00, datalatch[23:16]};
			default:   outdata_out = 16'h0000;
		endcase

		if (memready) begin
			case(operlatch)
				LSU_PUSH, LSU_CALL: stackpnt_op = 2'b01;
				LSU_POP, LSU_RET:   stackpnt_op = 2'b10;
				default:            stackpnt_op = 2'b00;
			endcase
		end



		// Register writeback
		case (state)

			S_WB1: begin
				case (operlatch)
					LSU_LOAD, LSU_LOAD2, LSU_POP: begin
						regwrite    = 1;
						regaddr_out = destlatch;
						intdata_out = restlatch;
					end
	
					LSU_RCHR: begin
						regwrite    = 1;
						regaddr_out = destlatch;
						intdata_out = {24'h000000, rchr_data[7:0]};
					end
				endcase
			end

			S_WB2: begin
				if (operlatch == LSU_RCHR) begin
					regwrite    = 1;
					regaddr_out = des2latch;
					intdata_out = {24'h000000, rchr_data[7:0]};
				end
			end

			S_DONE: begin
				if(operlatch == LSU_RET)
					intdata_out = restlatch;
			end

		endcase

	end

endmodule
