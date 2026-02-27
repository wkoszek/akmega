`timescale 1ns/1ps

module akmega_core (
    input logic clk,
    input logic rst_n,

    // AXI4-Lite Instruction Fetch Master Interface
    output logic [31:0] ibus_awaddr, output logic [2:0] ibus_awprot, output logic ibus_awvalid, input logic ibus_awready,
    output logic [31:0] ibus_wdata, output logic [3:0] ibus_wstrb, output logic ibus_wvalid, input logic ibus_wready,
    input logic [1:0] ibus_bresp, input logic ibus_bvalid, output logic ibus_bready,
    output logic [31:0] ibus_araddr, output logic [2:0] ibus_arprot, output logic        ibus_arvalid, input  logic        ibus_arready,
    input  logic [31:0] ibus_rdata,  input logic [1:0] ibus_rresp,  input  logic        ibus_rvalid,  output logic        ibus_rready,

    // AXI4-Lite Data Memory Master Interface
    output logic [31:0] dbus_awaddr, output logic [2:0] dbus_awprot, output logic dbus_awvalid, input logic dbus_awready,
    output logic [31:0] dbus_wdata, output logic [3:0] dbus_wstrb, output logic dbus_wvalid, input logic dbus_wready,
    input logic [1:0] dbus_bresp, input logic dbus_bvalid, output logic dbus_bready,
    output logic [31:0] dbus_araddr, output logic [2:0] dbus_arprot, output logic        dbus_arvalid, input  logic        dbus_arready,
    input  logic [31:0] dbus_rdata,  input logic [1:0] dbus_rresp,  input  logic        dbus_rvalid,  output logic        dbus_rready
);

    typedef enum logic [3:0] {
        STATE_RESET,
        STATE_FETCH_REQ, STATE_FETCH_WAIT,
        STATE_DECODE_EXEC,
        STATE_FETCH_OP2_REQ, STATE_FETCH_OP2_WAIT,
        STATE_MEM_REQ, STATE_MEM_WAIT
    } state_t;

    state_t state;

    logic [15:0] pc;         
    logic [15:0] inst_reg;   
    logic [15:0] op2_reg;
    logic [7:0]  gpr [0:31]; 
    logic [7:0]  sreg;       
    logic [15:0] sp;

    logic [15:0] mem_addr;
    logic [7:0]  mem_wr_data;
    logic [4:0]  mem_rd_dest;
    logic [1:0]  mem_op; 

    // Decode helpers
    logic [4:0] d_idx;
    logic [4:0] r_idx;
    logic [4:0] d_imm_idx;
    logic [7:0] k_imm_val;
    logic [6:0] b_rel_val;

    assign d_idx     = {inst_reg[8], inst_reg[7:4]};
    assign r_idx     = {inst_reg[9], inst_reg[3:0]};
    assign d_imm_idx = {1'b1, inst_reg[7:4]};
    assign k_imm_val = {inst_reg[11:8], inst_reg[3:0]};
    assign b_rel_val = inst_reg[9:3];

    // AXI Default
    always_comb begin
        ibus_awaddr = '0; ibus_awprot = '0; ibus_awvalid = 1'b0;
        ibus_wdata = '0; ibus_wstrb = '0; ibus_wvalid = 1'b0; ibus_bready = 1'b1;
        dbus_awprot = '0; dbus_wstrb = 4'h1; dbus_arprot = '0; dbus_bready = 1'b1;
    end

    integer i;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ibus_araddr <= '0; ibus_arvalid <= 1'b0; ibus_arprot <= 3'b010; ibus_rready <= 1'b0;
            dbus_awaddr <= '0; dbus_awvalid <= 1'b0; dbus_wdata <= '0; dbus_wvalid <= 1'b0;
            dbus_araddr <= '0; dbus_arvalid <= 1'b0; dbus_rready <= 1'b0;
            state <= STATE_RESET;
            pc <= 16'h0000; inst_reg <= 16'h0000; op2_reg <= 16'h0000;
            sreg <= 8'h00; sp <= 16'h08FF; 
            mem_addr <= 16'h0; mem_wr_data <= 8'h0; mem_rd_dest <= 5'h0; mem_op <= 2'h0;
            for (i=0; i<32; i=i+1) gpr[i] <= 8'h00;
        end else begin
            case (state)
                STATE_RESET: state <= STATE_FETCH_REQ;
                
                STATE_FETCH_REQ: begin
                    ibus_araddr <= {16'h0000, pc[15:2], 2'b00}; ibus_arvalid <= 1'b1; ibus_rready <= 1'b1;
                    state <= STATE_FETCH_WAIT;
                end
                
                STATE_FETCH_WAIT: begin
                    if (ibus_arvalid && ibus_arready) ibus_arvalid <= 1'b0;
                    if (ibus_rvalid && ibus_rready) begin
                        ibus_rready <= 1'b0;
                        if (pc[1] == 1'b0) inst_reg <= ibus_rdata[15:0];
                        else inst_reg <= ibus_rdata[31:16];
                        state <= STATE_DECODE_EXEC;
                    end
                end

                STATE_FETCH_OP2_WAIT: begin
                    if (ibus_arvalid && ibus_arready) ibus_arvalid <= 1'b0;
                    if (ibus_rvalid && ibus_rready) begin
                        logic [15:0] current_op2;
                        ibus_rready <= 1'b0;
                        current_op2 = (pc[1] == 1'b0) ? ibus_rdata[15:0] : ibus_rdata[31:16];
                        op2_reg <= current_op2;
                        
                        if (inst_reg[15:12] == 4'b1001 && inst_reg[3:0] == 4'b0000) begin // LDS/STS
                            mem_addr <= current_op2;
                            mem_op <= inst_reg[9] ? 2'h2 : 2'h1;
                            if (!inst_reg[9]) mem_rd_dest <= d_idx;
                            else mem_wr_data <= gpr[d_idx];
                            pc <= pc + 16'h2;
                            state <= STATE_MEM_REQ;
                        end else begin // JMP/CALL
                            pc <= current_op2;
                            state <= STATE_FETCH_REQ;
                        end
                    end
                end

                STATE_DECODE_EXEC: begin
                    $display("Exec: PC=%h Inst=%h R24:25=%h%h R18=%h R19=%h SREG=%b", pc, inst_reg, gpr[25], gpr[24], gpr[18], gpr[19], sreg);
                    casez (inst_reg)
                        16'b0000000000000000: begin // NOP
                            pc <= pc + 16'h2; state <= STATE_FETCH_REQ;
                        end
                        16'b000011??????????: begin // ADD
                            logic [8:0] sum; logic h, v, n, z, c, s;
                            sum = gpr[d_idx] + gpr[r_idx];
                            h = (gpr[d_idx][3] & gpr[r_idx][3]) | (gpr[r_idx][3] & ~sum[3]) | (~sum[3] & gpr[d_idx][3]);
                            v = (gpr[d_idx][7] & gpr[r_idx][7] & ~sum[7]) | (~gpr[d_idx][7] & ~gpr[r_idx][7] & sum[7]);
                            n = sum[7]; z = (sum[7:0] == 8'h00); c = sum[8]; s = n ^ v;
                            gpr[d_idx] <= sum[7:0];
                            sreg <= {sreg[7:6], h, s, v, n, z, c};
                            pc <= pc + 16'h2; state <= STATE_FETCH_REQ;
                        end
                        16'b001011??????????: begin // MOV
                            gpr[d_idx] <= gpr[r_idx];
                            pc <= pc + 16'h2; state <= STATE_FETCH_REQ;
                        end
                        16'b1110????????????: begin // LDI
                            gpr[d_imm_idx] <= k_imm_val;
                            pc <= pc + 16'h2; state <= STATE_FETCH_REQ;
                        end
                        16'b1100????????????: begin // RJMP
                            pc <= pc + 16'h2 + {{3{inst_reg[11]}}, inst_reg[11:0], 1'b0}; 
                            state <= STATE_FETCH_REQ;
                        end
                        16'b111101???????001: begin // BRNE
                            if (!sreg[1]) pc <= pc + 16'h2 + {{8{inst_reg[9]}}, b_rel_val, 1'b0};
                            else pc <= pc + 16'h2;
                            state <= STATE_FETCH_REQ;
                        end
                        16'b10111???????????: begin // OUT
                            logic [5:0] addr;
                            addr = {inst_reg[10:9], inst_reg[3:0]};
                            mem_addr <= {10'h0, addr} + 16'h20;
                            mem_wr_data <= gpr[d_idx];
                            mem_op <= 2'h2;
                            pc <= pc + 16'h2;
                            state <= STATE_MEM_REQ;
                        end
                        16'b10010111????????: begin // SBIW
                            logic [4:0] ridx; logic [15:0] val, res;
                            ridx = 24 + ({3'h0, inst_reg[5:4]} << 1);
                            val = {gpr[ridx+1], gpr[ridx]};
                            res = val - {10'h0, inst_reg[7:6], inst_reg[3:0]};
                            gpr[ridx] <= res[7:0]; gpr[ridx+1] <= res[15:8];
                            sreg[1] <= (res == 16'h0);
                            pc <= pc + 16'h2; state <= STATE_FETCH_REQ;
                        end
                        16'b100100????????00: begin // LDS / STS (32-bit)
                            pc <= pc + 16'h2; state <= STATE_FETCH_OP2_REQ;
                        end
                        default: begin
                            pc <= pc + 16'h2; state <= STATE_FETCH_REQ;
                        end
                    endcase
                end

                STATE_FETCH_OP2_REQ: begin
                    ibus_araddr <= {16'h0000, pc[15:2], 2'b00}; ibus_arvalid <= 1'b1; ibus_rready <= 1'b1;
                    state <= STATE_FETCH_OP2_WAIT;
                end

                STATE_MEM_REQ: begin
                    if (mem_op == 2'h1) begin
                        dbus_araddr <= {16'h0000, mem_addr}; dbus_arvalid <= 1'b1; dbus_rready <= 1'b1;
                    end else if (mem_op == 2'h2) begin
                        dbus_awaddr <= {16'h0000, mem_addr}; dbus_awvalid <= 1'b1;
                        dbus_wdata <= {24'h0, mem_wr_data}; dbus_wvalid <= 1'b1;
                    end
                    state <= STATE_MEM_WAIT;
                end

                STATE_MEM_WAIT: begin
                    if (dbus_arvalid && dbus_arready) dbus_arvalid <= 1'b0;
                    if (dbus_awvalid && dbus_awready) dbus_awvalid <= 1'b0;
                    if (dbus_wvalid && dbus_wready) dbus_wvalid <= 1'b0;

                    if (mem_op == 2'h1 && dbus_rvalid && dbus_rready) begin
                        dbus_rready <= 1'b0; gpr[mem_rd_dest] <= dbus_rdata[7:0]; state <= STATE_FETCH_REQ;
                    end else if (mem_op == 2'h2 && dbus_bvalid && dbus_bready) begin
                        state <= STATE_FETCH_REQ;
                    end
                end

                default: state <= STATE_RESET;
            endcase
        end
    end

endmodule
