
// Man, this thing is a mess. I think it will work now, but like,
// Update: hahahahahhaha. No. Stale data. I fixed it now I think...
module lsu	                       (   // do not trust me on that.
	input             clock,           // Clock signal
	input             reset,           // Reset signal
	input      [23:0] memaddr_in,      // Memory address in, for any operation that uses external memory
	input      [31:0] data_in,         // Data in as will be used for operation; also used for second regaddr in rchr
	input      [ 3:0] regaddr_in,      // Register address in, for pop, load
	input      [ 3:0] lsu_op,          // Load-store unit operation code; push, pop, call, ret, load, store
	output reg [23:0] memaddr_out,     // Memory address out, for push, pop, call, ret, load, store
	output reg [31:0] intdata_out,     // Internal databus, for transferring data between registers
	output reg [15:0] outdata_out,     // External databus, for push, call, store operations
	output reg [ 3:0] regaddr_out,     // Register address out for regwrite, pop, load instructions
	output reg [ 1:0] stackpnt_op,  // 00 == do nothing, 01 == advance downward by 1, 10 == decrement upward by 1. it's so ugly TvT
	output reg        regwrite,        // Raise high to tell the register file to write to address 
	output reg        writeword,       // Goes direct to the FULLWORD pin on the CPU, for the memory controller's reference
	output reg        mem_read,        // Tell the memory controller to read
	output reg        mem_write,       // Tell the memory controller to write
	output reg        mem_enable,      // Tell the memory controller to do something
	output reg        lsu_done     );  // The CLU should not advance the PC on a clock signal if this is raised high

	localparam LSU_NOP   = 4'd0;   // Don't touch anything!! Gonna get yerself killed. Jaeaysus
        localparam LSU_LOAD  = 4'd1;   // Read  a single 8-bit byte at memory address in memaddr_in
        localparam LSU_STORE = 4'd2;   // Write a single 8-bit byte at memory address in memaddr_in
	localparam LSU_LOAD2 = 4'd3;   // Read  a full 16-bit-word at memory address in memaddr_in
	localparam LSU_STOR2 = 4'd4;   // Write a full 16-bit-word at memory address in memaddr_in
        localparam LSU_PUSH  = 4'd5;   // Push value in data_in to stack
        localparam LSU_POP   = 4'd6;   // Pop from stack into specified register in regaddr_in
        localparam LSU_CALL  = 4'd7;   // Push program counter to stack in two passes
        localparam LSU_RET   = 4'd8;   // Pop from stack twice, reconstruct the program pointer
	localparam LSU_WCHR  = 4'd9;   // Write low sixteen bits of data_in to memaddr
	localparam LSU_RCHR  = 4'd10;  // Read sixteen bits from address

	reg        half_select;        // if low, first half (high) - if high, second half (low)
	reg [ 1:0] cycle_count;        // Tracks which cycle of a PUSH/POP we're on
	reg [15:0] first_half;         // Holds the first half of a 32-bit load from memory of any sort
	reg [15:0] rchr_data;          // Holds the 16-bit-word for the RCHR instruction

	// This is the state machine.. It tracks all our multicycle instructions so we know what to do on each clock cycle.
	always @(posedge clock or posedge reset) begin // You are correct, this is probably convoluted, but, i mean... fuck it.
		if (reset) begin                       // You try to teach yourself how to do this shit in a week man.
			half_select <= 0;              // Anyways, back to the program. I won't be using too many comments here
			cycle_count <= 0;              // Because this part is pretty simple, and I can't make em pretty here TvT
			lsu_done    <= 0;
			first_half  <= 16'h0000;

		end else begin
			case (lsu_op)
				LSU_PUSH, LSU_CALL, LSU_POP, LSU_RET: begin
					lsu_done <= 0;
					if (cycle_count == 0) begin
						half_select <= 0;
						cycle_count <= 1;
					end else if (cycle_count == 1) begin
						half_select <= 1;
						cycle_count <= 2;
						if (lsu_op == LSU_POP || lsu_op == LSU_RET)
							first_half <= data_in[15:0];
					end else if (cycle_count == 2) begin 
						intdata_out = {first_half, data_in};
						regwrite    = 1;
						lsu_done    = 1;
						cycle_count = 3;
					end else begin
						half_select <= 0;
						cycle_count <= 0;
						lsu_done    <= 1;
					end
				end

				LSU_RCHR: begin
					lsu_done <= 0;
					if (cycle_count == 0) begin
						cycle_count <=1;
					end else if (cycle_count == 1) begin
						rchr_data   <= data_in[15:0];
						cycle_count <= 2;
					end else if (cycle_count == 2) begin
						cycle_count <= 0;
						lsu_done    <= 1;
					end
				end

				default: begin
					half_select <= 0;
					cycle_count <= 0;
					lsu_done    <= 1;
				end

			endcase

		end
	end

	always @(*) begin
		memaddr_out = memaddr_in;
		intdata_out = 32'h00000000;
		outdata_out = 16'h0000;
		regaddr_out = regaddr_in;
		stackpnt_op = 2'b00;
		regwrite    = 1'b0;
		writeword   = 1'b0;
		mem_read    = 1'b0;
		mem_write   = 1'b0;
		mem_enable  = 1'b0;

		case (lsu_op)
			LSU_LOAD: begin
				mem_read    = 1;
				mem_enable  = 1;
				writeword   = 0;
				regwrite    = 1;
				intdata_out = {24'h000000, data_in[15:8]};
			end

			LSU_STORE: begin
				mem_write   = 1;
				mem_enable  = 1;
				writeword   = 0;
				outdata_out = {data_in[7:0], 8'h00};
			end

			LSU_LOAD2: begin
				mem_read    = 1;
				mem_enable  = 1;
				writeword   = 1;
				regwrite    = 1;
				intdata_out = {16'h0000, data_in[15:0]};
			end

			LSU_STOR2: begin
				mem_write   = 1;
				mem_enable  = 1;
				writeword   = 1;
				outdata_out = data_in[15:0];
			end

			LSU_PUSH: begin
				if(cycle_count < 2) begin
					mem_write   = 1; 
					mem_enable  = 1; 
					writeword   = 1;
					stackpnt_op = 2'b01;
					outdata_out = half_select ? data_in[15:0] : data_in[31:16];
				end
			end

			LSU_POP: begin
				mem_read    = 1;
				mem_enable  = 1;
				writeword   = 1;
				stackpnt_op = 2'b10;
				if (half_select == 1) begin
					regwrite    = 1;
					intdata_out = {first_half[15:0], data_in[15:0]};
				end
			end

			LSU_CALL: begin
				mem_write   = 1; 
				mem_enable  = 1; 
				writeword   = 1;
				stackpnt_op = 2'b01;
				outdata_out = half_select ? data_in[15:0] : {8'h00, data_in[23:16]}; // CU must route PC to data_in
			end	

			LSU_RET: begin
				mem_read    = 1;
				mem_enable  = 1;
				writeword   = 1;
				stackpnt_op = 2'b10;
				if (half_select == 1)
					intdata_out = {first_half[15:0], data_in[15:0]};
			end

			LSU_WCHR: begin
				mem_write   = 1;
				mem_enable  = 1;
				writeword   = 1;
				outdata_out = data_in[15:0];
			end

			LSU_RCHR: begin
				if (cycle_count == 0) begin
					mem_read    = 1;
					mem_enable  = 1;
					writeword   = 1;
				end else if (cycle_count == 1) begin
					regwrite    = 1;
					regaddr_out = regaddr_in;
					intdata_out = {24'h000000, rchr_data[15:8]};
				end else if (cycle_count == 2) begin
					regwrite    = 1;
					regaddr_out = data_in[3:0];
					intdata_out = {24'h000000, rchr_data[7:0]};
				end
			end

		endcase

	end

endmodule
