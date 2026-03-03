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

    typedef enum logic [4:0] {
        STATE_RESET,
        STATE_FETCH_REQ, STATE_FETCH_WAIT,
        STATE_DECODE_EXEC,
        STATE_FETCH_OP2_REQ, STATE_FETCH_OP2_WAIT,
        STATE_MEM_REQ, STATE_MEM_WAIT,
        // Phase 2: CALL/RET stack operations
        STATE_CALL_PUSH_H, STATE_CALL_PUSH_L,
        STATE_RET_POP_L, STATE_RET_POP_H,
        // Phase 3: Indirect load/store, LPM
        STATE_INDIRECT_LOAD, STATE_INDIRECT_STORE,
        STATE_LPM_REQ, STATE_LPM_WAIT,
        // Phase 4: I/O bit read-modify-write
        STATE_IO_BIT_READ, STATE_IO_BIT_WRITE,
        // Skip: fetch next instruction to determine if 1 or 2 words
        STATE_SKIP_FETCH_REQ, STATE_SKIP_FETCH_WAIT
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

    // Call/ret target, indirect addressing temp, I/O bit temp
    logic [15:0] call_ret_addr;
    logic [4:0]  indirect_reg;   // destination/source register for indirect ops
    logic [15:0] indirect_ptr;   // pointer value for indirect ops
    logic        indirect_post_inc; // post-increment flag
    logic        indirect_pre_dec;  // pre-decrement flag
    logic [1:0]  indirect_ptr_sel;  // 0=X, 1=Y, 2=Z
    logic [5:0]  io_bit_addr;    // I/O address for SBI/CBI
    logic [2:0]  io_bit_num;     // bit number for SBI/CBI
    logic        io_bit_val;     // set or clear
    logic [7:0]  io_bit_data;    // read data for read-modify-write

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
            call_ret_addr <= 16'h0;
            indirect_reg <= 5'h0; indirect_ptr <= 16'h0;
            indirect_post_inc <= 1'b0; indirect_pre_dec <= 1'b0; indirect_ptr_sel <= 2'h0;
            io_bit_addr <= 6'h0; io_bit_num <= 3'h0; io_bit_val <= 1'b0; io_bit_data <= 8'h0;
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
                        16'b000111??????????: begin // ADC (Add with Carry)
                            logic [8:0] adc_sum; logic adc_h, adc_v, adc_n, adc_z, adc_c, adc_s;
                            adc_sum = gpr[d_idx] + gpr[r_idx] + {8'h0, sreg[0]};
                            adc_h = (gpr[d_idx][3] & gpr[r_idx][3]) | (gpr[r_idx][3] & ~adc_sum[3]) | (~adc_sum[3] & gpr[d_idx][3]);
                            adc_v = (gpr[d_idx][7] & gpr[r_idx][7] & ~adc_sum[7]) | (~gpr[d_idx][7] & ~gpr[r_idx][7] & adc_sum[7]);
                            adc_n = adc_sum[7]; adc_z = (adc_sum[7:0] == 8'h00); adc_c = adc_sum[8]; adc_s = adc_n ^ adc_v;
                            gpr[d_idx] <= adc_sum[7:0];
                            sreg <= {sreg[7:6], adc_h, adc_s, adc_v, adc_n, adc_z, adc_c};
                            pc <= pc + 16'h2; state <= STATE_FETCH_REQ;
                        end
                        16'b10010110????????: begin // ADIW (Add Immediate to Word)
                            logic [4:0] adiw_ridx; logic [15:0] adiw_val, adiw_res; logic [5:0] adiw_k;
                            adiw_ridx = 24 + ({3'h0, inst_reg[5:4]} << 1);
                            adiw_k = {inst_reg[7:6], inst_reg[3:0]};
                            adiw_val = {gpr[adiw_ridx+1], gpr[adiw_ridx]};
                            adiw_res = adiw_val + {10'h0, adiw_k};
                            gpr[adiw_ridx] <= adiw_res[7:0]; gpr[adiw_ridx+1] <= adiw_res[15:8];
                            sreg[0] <= ~adiw_res[15] & adiw_val[15]; // C
                            sreg[1] <= (adiw_res == 16'h0);           // Z
                            sreg[2] <= adiw_res[15];                  // N
                            sreg[3] <= ~adiw_val[15] & adiw_res[15]; // V
                            sreg[4] <= adiw_res[15] ^ (~adiw_val[15] & adiw_res[15]); // S
                            pc <= pc + 16'h2; state <= STATE_FETCH_REQ;
                        end
                        16'b000110??????????: begin // SUB
                            logic [8:0] sub_res; logic sub_h, sub_v, sub_n, sub_z, sub_c, sub_s;
                            sub_res = gpr[d_idx] - gpr[r_idx];
                            sub_h = (~gpr[d_idx][3] & gpr[r_idx][3]) | (gpr[r_idx][3] & sub_res[3]) | (sub_res[3] & ~gpr[d_idx][3]);
                            sub_v = (gpr[d_idx][7] & ~gpr[r_idx][7] & ~sub_res[7]) | (~gpr[d_idx][7] & gpr[r_idx][7] & sub_res[7]);
                            sub_n = sub_res[7]; sub_z = (sub_res[7:0] == 8'h00); sub_c = sub_res[8]; sub_s = sub_n ^ sub_v;
                            gpr[d_idx] <= sub_res[7:0];
                            sreg <= {sreg[7:6], sub_h, sub_s, sub_v, sub_n, sub_z, sub_c};
                            pc <= pc + 16'h2; state <= STATE_FETCH_REQ;
                        end
                        16'b0101????????????: begin // SUBI (Subtract Immediate)
                            logic [8:0] subi_res; logic subi_h, subi_v, subi_n, subi_z, subi_c, subi_s;
                            subi_res = gpr[d_imm_idx] - k_imm_val;
                            subi_h = (~gpr[d_imm_idx][3] & k_imm_val[3]) | (k_imm_val[3] & subi_res[3]) | (subi_res[3] & ~gpr[d_imm_idx][3]);
                            subi_v = (gpr[d_imm_idx][7] & ~k_imm_val[7] & ~subi_res[7]) | (~gpr[d_imm_idx][7] & k_imm_val[7] & subi_res[7]);
                            subi_n = subi_res[7]; subi_z = (subi_res[7:0] == 8'h00); subi_c = subi_res[8]; subi_s = subi_n ^ subi_v;
                            gpr[d_imm_idx] <= subi_res[7:0];
                            sreg <= {sreg[7:6], subi_h, subi_s, subi_v, subi_n, subi_z, subi_c};
                            pc <= pc + 16'h2; state <= STATE_FETCH_REQ;
                        end
                        16'b000010??????????: begin // SBC (Subtract with Carry)
                            logic [8:0] sbc_res; logic sbc_h, sbc_v, sbc_n, sbc_z, sbc_c, sbc_s;
                            sbc_res = gpr[d_idx] - gpr[r_idx] - {8'h0, sreg[0]};
                            sbc_h = (~gpr[d_idx][3] & gpr[r_idx][3]) | (gpr[r_idx][3] & sbc_res[3]) | (sbc_res[3] & ~gpr[d_idx][3]);
                            sbc_v = (gpr[d_idx][7] & ~gpr[r_idx][7] & ~sbc_res[7]) | (~gpr[d_idx][7] & gpr[r_idx][7] & sbc_res[7]);
                            sbc_n = sbc_res[7]; sbc_z = (sbc_res[7:0] == 8'h00) & sreg[1]; sbc_c = sbc_res[8]; sbc_s = sbc_n ^ sbc_v;
                            gpr[d_idx] <= sbc_res[7:0];
                            sreg <= {sreg[7:6], sbc_h, sbc_s, sbc_v, sbc_n, sbc_z, sbc_c};
                            pc <= pc + 16'h2; state <= STATE_FETCH_REQ;
                        end
                        16'b0100????????????: begin // SBCI (Subtract Immediate with Carry)
                            logic [8:0] sbci_res; logic sbci_h, sbci_v, sbci_n, sbci_z, sbci_c, sbci_s;
                            sbci_res = gpr[d_imm_idx] - k_imm_val - {8'h0, sreg[0]};
                            sbci_h = (~gpr[d_imm_idx][3] & k_imm_val[3]) | (k_imm_val[3] & sbci_res[3]) | (sbci_res[3] & ~gpr[d_imm_idx][3]);
                            sbci_v = (gpr[d_imm_idx][7] & ~k_imm_val[7] & ~sbci_res[7]) | (~gpr[d_imm_idx][7] & k_imm_val[7] & sbci_res[7]);
                            sbci_n = sbci_res[7]; sbci_z = (sbci_res[7:0] == 8'h00) & sreg[1]; sbci_c = sbci_res[8]; sbci_s = sbci_n ^ sbci_v;
                            gpr[d_imm_idx] <= sbci_res[7:0];
                            sreg <= {sreg[7:6], sbci_h, sbci_s, sbci_v, sbci_n, sbci_z, sbci_c};
                            pc <= pc + 16'h2; state <= STATE_FETCH_REQ;
                        end
                        16'b001000??????????: begin // AND
                            logic [7:0] and_res; logic and_v, and_n, and_z, and_s;
                            and_res = gpr[d_idx] & gpr[r_idx];
                            and_v = 1'b0; and_n = and_res[7]; and_z = (and_res == 8'h00); and_s = and_n ^ and_v;
                            gpr[d_idx] <= and_res;
                            sreg <= {sreg[7:6], sreg[5], and_s, and_v, and_n, and_z, sreg[0]};
                            pc <= pc + 16'h2; state <= STATE_FETCH_REQ;
                        end
                        16'b0111????????????: begin // ANDI (AND Immediate)
                            logic [7:0] andi_res; logic andi_v, andi_n, andi_z, andi_s;
                            andi_res = gpr[d_imm_idx] & k_imm_val;
                            andi_v = 1'b0; andi_n = andi_res[7]; andi_z = (andi_res == 8'h00); andi_s = andi_n ^ andi_v;
                            gpr[d_imm_idx] <= andi_res;
                            sreg <= {sreg[7:6], sreg[5], andi_s, andi_v, andi_n, andi_z, sreg[0]};
                            pc <= pc + 16'h2; state <= STATE_FETCH_REQ;
                        end
                        16'b001010??????????: begin // OR
                            logic [7:0] or_res; logic or_v, or_n, or_z, or_s;
                            or_res = gpr[d_idx] | gpr[r_idx];
                            or_v = 1'b0; or_n = or_res[7]; or_z = (or_res == 8'h00); or_s = or_n ^ or_v;
                            gpr[d_idx] <= or_res;
                            sreg <= {sreg[7:6], sreg[5], or_s, or_v, or_n, or_z, sreg[0]};
                            pc <= pc + 16'h2; state <= STATE_FETCH_REQ;
                        end
                        16'b0110????????????: begin // ORI (OR Immediate)
                            logic [7:0] ori_res; logic ori_v, ori_n, ori_z, ori_s;
                            ori_res = gpr[d_imm_idx] | k_imm_val;
                            ori_v = 1'b0; ori_n = ori_res[7]; ori_z = (ori_res == 8'h00); ori_s = ori_n ^ ori_v;
                            gpr[d_imm_idx] <= ori_res;
                            sreg <= {sreg[7:6], sreg[5], ori_s, ori_v, ori_n, ori_z, sreg[0]};
                            pc <= pc + 16'h2; state <= STATE_FETCH_REQ;
                        end
                        16'b001001??????????: begin // EOR
                            logic [7:0] eor_res; logic eor_v, eor_n, eor_z, eor_s;
                            eor_res = gpr[d_idx] ^ gpr[r_idx];
                            eor_v = 1'b0; eor_n = eor_res[7]; eor_z = (eor_res == 8'h00); eor_s = eor_n ^ eor_v;
                            gpr[d_idx] <= eor_res;
                            sreg <= {sreg[7:6], sreg[5], eor_s, eor_v, eor_n, eor_z, sreg[0]};
                            pc <= pc + 16'h2; state <= STATE_FETCH_REQ;
                        end
                        16'b1001010?????0000: begin // COM (One's Complement)
                            logic [7:0] com_res; logic com_n, com_z, com_s;
                            com_res = ~gpr[d_idx];
                            com_n = com_res[7]; com_z = (com_res == 8'h00); com_s = com_n;
                            gpr[d_idx] <= com_res;
                            sreg <= {sreg[7:6], sreg[5], com_s, 1'b0, com_n, com_z, 1'b1};
                            pc <= pc + 16'h2; state <= STATE_FETCH_REQ;
                        end
                        16'b1001010?????0001: begin // NEG (Two's Complement)
                            logic [8:0] neg_res; logic neg_h, neg_v, neg_n, neg_z, neg_c, neg_s;
                            neg_res = 9'h000 - gpr[d_idx];
                            neg_h = neg_res[3] | gpr[d_idx][3];
                            neg_v = (neg_res[7:0] == 8'h80); neg_n = neg_res[7];
                            neg_z = (neg_res[7:0] == 8'h00); neg_c = (neg_res[7:0] != 8'h00);
                            neg_s = neg_n ^ neg_v;
                            gpr[d_idx] <= neg_res[7:0];
                            sreg <= {sreg[7:6], neg_h, neg_s, neg_v, neg_n, neg_z, neg_c};
                            pc <= pc + 16'h2; state <= STATE_FETCH_REQ;
                        end
                        16'b1001010?????0011: begin // INC
                            logic [7:0] inc_res; logic inc_v, inc_n, inc_z, inc_s;
                            inc_res = gpr[d_idx] + 8'h01;
                            inc_v = (gpr[d_idx] == 8'h7F); inc_n = inc_res[7];
                            inc_z = (inc_res == 8'h00); inc_s = inc_n ^ inc_v;
                            gpr[d_idx] <= inc_res;
                            sreg <= {sreg[7:6], sreg[5], inc_s, inc_v, inc_n, inc_z, sreg[0]};
                            pc <= pc + 16'h2; state <= STATE_FETCH_REQ;
                        end
                        16'b1001010?????1010: begin // DEC
                            logic [7:0] dec_res; logic dec_v, dec_n, dec_z, dec_s;
                            dec_res = gpr[d_idx] - 8'h01;
                            dec_v = (gpr[d_idx] == 8'h80); dec_n = dec_res[7];
                            dec_z = (dec_res == 8'h00); dec_s = dec_n ^ dec_v;
                            gpr[d_idx] <= dec_res;
                            sreg <= {sreg[7:6], sreg[5], dec_s, dec_v, dec_n, dec_z, sreg[0]};
                            pc <= pc + 16'h2; state <= STATE_FETCH_REQ;
                        end
                        16'b000101??????????: begin // CP (Compare)
                            logic [8:0] cp_res; logic cp_h, cp_v, cp_n, cp_z, cp_c, cp_s;
                            cp_res = gpr[d_idx] - gpr[r_idx];
                            cp_h = (~gpr[d_idx][3] & gpr[r_idx][3]) | (gpr[r_idx][3] & cp_res[3]) | (cp_res[3] & ~gpr[d_idx][3]);
                            cp_v = (gpr[d_idx][7] & ~gpr[r_idx][7] & ~cp_res[7]) | (~gpr[d_idx][7] & gpr[r_idx][7] & cp_res[7]);
                            cp_n = cp_res[7]; cp_z = (cp_res[7:0] == 8'h00); cp_c = cp_res[8]; cp_s = cp_n ^ cp_v;
                            sreg <= {sreg[7:6], cp_h, cp_s, cp_v, cp_n, cp_z, cp_c};
                            pc <= pc + 16'h2; state <= STATE_FETCH_REQ;
                        end
                        16'b000001??????????: begin // CPC (Compare with Carry)
                            logic [8:0] cpc_res; logic cpc_h, cpc_v, cpc_n, cpc_z, cpc_c, cpc_s;
                            cpc_res = gpr[d_idx] - gpr[r_idx] - {8'h0, sreg[0]};
                            cpc_h = (~gpr[d_idx][3] & gpr[r_idx][3]) | (gpr[r_idx][3] & cpc_res[3]) | (cpc_res[3] & ~gpr[d_idx][3]);
                            cpc_v = (gpr[d_idx][7] & ~gpr[r_idx][7] & ~cpc_res[7]) | (~gpr[d_idx][7] & gpr[r_idx][7] & cpc_res[7]);
                            cpc_n = cpc_res[7]; cpc_z = (cpc_res[7:0] == 8'h00) & sreg[1]; cpc_c = cpc_res[8]; cpc_s = cpc_n ^ cpc_v;
                            sreg <= {sreg[7:6], cpc_h, cpc_s, cpc_v, cpc_n, cpc_z, cpc_c};
                            pc <= pc + 16'h2; state <= STATE_FETCH_REQ;
                        end
                        16'b0011????????????: begin // CPI (Compare Immediate)
                            logic [8:0] cpi_res; logic cpi_h, cpi_v, cpi_n, cpi_z, cpi_c, cpi_s;
                            cpi_res = gpr[d_imm_idx] - k_imm_val;
                            cpi_h = (~gpr[d_imm_idx][3] & k_imm_val[3]) | (k_imm_val[3] & cpi_res[3]) | (cpi_res[3] & ~gpr[d_imm_idx][3]);
                            cpi_v = (gpr[d_imm_idx][7] & ~k_imm_val[7] & ~cpi_res[7]) | (~gpr[d_imm_idx][7] & k_imm_val[7] & cpi_res[7]);
                            cpi_n = cpi_res[7]; cpi_z = (cpi_res[7:0] == 8'h00); cpi_c = cpi_res[8]; cpi_s = cpi_n ^ cpi_v;
                            sreg <= {sreg[7:6], cpi_h, cpi_s, cpi_v, cpi_n, cpi_z, cpi_c};
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
                        16'b111100??????????: begin // BRBS - Branch if SREG bit set
                            if (sreg[inst_reg[2:0]])
                                pc <= pc + 16'h2 + {{8{inst_reg[9]}}, b_rel_val, 1'b0};
                            else
                                pc <= pc + 16'h2;
                            state <= STATE_FETCH_REQ;
                        end
                        16'b111101??????????: begin // BRBC - Branch if SREG bit cleared
                            if (!sreg[inst_reg[2:0]])
                                pc <= pc + 16'h2 + {{8{inst_reg[9]}}, b_rel_val, 1'b0};
                            else
                                pc <= pc + 16'h2;
                            state <= STATE_FETCH_REQ;
                        end
                        16'b1101????????????: begin // RCALL - Relative call
                            logic [15:0] rcall_ret;
                            call_ret_addr <= pc + 16'h2 + {{3{inst_reg[11]}}, inst_reg[11:0], 1'b0};
                            rcall_ret = (pc + 16'h2) >> 1; // word address of next instruction
                            mem_addr <= sp;
                            mem_wr_data <= rcall_ret[15:8]; // high byte of return word addr
                            mem_op <= 2'h2;
                            sp <= sp - 16'h1;
                            state <= STATE_CALL_PUSH_H;
                        end
                        16'b1001010100001000: begin // RET
                            sp <= sp + 16'h1;
                            mem_op <= 2'h0; // signal to INDIRECT_LOAD that this is RET
                            state <= STATE_RET_POP_L;
                        end
                        16'b1001010100011000: begin // RETI
                            sp <= sp + 16'h1;
                            sreg[7] <= 1'b1; // Re-enable interrupts
                            mem_op <= 2'h0;
                            state <= STATE_RET_POP_L;
                        end
                        16'b1001010100001001: begin // ICALL - Indirect call via Z
                            logic [15:0] icall_ret;
                            call_ret_addr <= {gpr[31], gpr[30]} << 1; // Z word addr -> byte addr
                            icall_ret = (pc + 16'h2) >> 1; // word address of return
                            mem_addr <= sp;
                            mem_wr_data <= icall_ret[15:8];
                            mem_op <= 2'h2;
                            sp <= sp - 16'h1;
                            state <= STATE_CALL_PUSH_H;
                        end
                        16'b1001010000001001: begin // IJMP - Indirect jump via Z
                            pc <= {gpr[31], gpr[30]} << 1; // Z word addr -> byte addr
                            state <= STATE_FETCH_REQ;
                        end
                        16'b000100??????????: begin // CPSE - Compare, Skip if Equal
                            if (gpr[d_idx] == gpr[r_idx]) begin
                                pc <= pc + 16'h2;
                                state <= STATE_SKIP_FETCH_REQ; // skip next instruction
                            end else begin
                                pc <= pc + 16'h2;
                                state <= STATE_FETCH_REQ;
                            end
                        end
                        16'b1111110?????0???: begin // SBRC - Skip if Bit in Register Cleared
                            if (!gpr[d_idx][inst_reg[2:0]]) begin
                                pc <= pc + 16'h2;
                                state <= STATE_SKIP_FETCH_REQ;
                            end else begin
                                pc <= pc + 16'h2;
                                state <= STATE_FETCH_REQ;
                            end
                        end
                        16'b1111111?????0???: begin // SBRS - Skip if Bit in Register Set
                            if (gpr[d_idx][inst_reg[2:0]]) begin
                                pc <= pc + 16'h2;
                                state <= STATE_SKIP_FETCH_REQ;
                            end else begin
                                pc <= pc + 16'h2;
                                state <= STATE_FETCH_REQ;
                            end
                        end
                        16'b100111??????????: begin // MUL - Unsigned Multiply
                            logic [15:0] mul_res;
                            mul_res = gpr[d_idx] * gpr[r_idx];
                            gpr[0] <= mul_res[7:0]; gpr[1] <= mul_res[15:8];
                            sreg[0] <= mul_res[15]; // C = bit 15
                            sreg[1] <= (mul_res == 16'h0); // Z
                            pc <= pc + 16'h2; state <= STATE_FETCH_REQ;
                        end
                        16'b00000010????????: begin // MULS - Signed Multiply
                            logic signed [15:0] muls_res;
                            logic [4:0] muls_d, muls_r;
                            muls_d = {1'b1, inst_reg[7:4]}; // R16-R31
                            muls_r = {1'b1, inst_reg[3:0]}; // R16-R31
                            muls_res = $signed(gpr[muls_d]) * $signed(gpr[muls_r]);
                            gpr[0] <= muls_res[7:0]; gpr[1] <= muls_res[15:8];
                            sreg[0] <= muls_res[15];
                            sreg[1] <= (muls_res == 16'h0);
                            pc <= pc + 16'h2; state <= STATE_FETCH_REQ;
                        end
                        16'b000000110???0???: begin // MULSU - Signed x Unsigned Multiply
                            logic signed [15:0] mulsu_res;
                            logic [4:0] mulsu_d, mulsu_r;
                            mulsu_d = {2'b10, inst_reg[6:4]}; // R16-R23
                            mulsu_r = {2'b10, inst_reg[2:0]}; // R16-R23
                            mulsu_res = $signed(gpr[mulsu_d]) * $signed({1'b0, gpr[mulsu_r]});
                            gpr[0] <= mulsu_res[7:0]; gpr[1] <= mulsu_res[15:8];
                            sreg[0] <= mulsu_res[15];
                            sreg[1] <= (mulsu_res == 16'h0);
                            pc <= pc + 16'h2; state <= STATE_FETCH_REQ;
                        end
                        16'b000000111???0???: begin // FMUL - Fractional Unsigned Multiply
                            logic [15:0] fmul_res;
                            logic [4:0] fmul_d, fmul_r;
                            fmul_d = {2'b10, inst_reg[6:4]}; // R16-R23
                            fmul_r = {2'b10, inst_reg[2:0]}; // R16-R23
                            fmul_res = (gpr[fmul_d] * gpr[fmul_r]) << 1;
                            gpr[0] <= fmul_res[7:0]; gpr[1] <= fmul_res[15:8];
                            sreg[0] <= (gpr[fmul_d] * gpr[fmul_r]) >> 15; // C = bit 15 before shift
                            sreg[1] <= (fmul_res == 16'h0);
                            pc <= pc + 16'h2; state <= STATE_FETCH_REQ;
                        end
                        16'b0000001110??0???: begin // FMULS - Fractional Signed Multiply
                            logic signed [15:0] fmuls_tmp;
                            logic [15:0] fmuls_res;
                            logic [4:0] fmuls_d, fmuls_r;
                            fmuls_d = {2'b10, inst_reg[6:4]};
                            fmuls_r = {2'b10, inst_reg[2:0]};
                            fmuls_tmp = $signed(gpr[fmuls_d]) * $signed(gpr[fmuls_r]);
                            fmuls_res = fmuls_tmp << 1;
                            gpr[0] <= fmuls_res[7:0]; gpr[1] <= fmuls_res[15:8];
                            sreg[0] <= fmuls_tmp[15];
                            sreg[1] <= (fmuls_res == 16'h0);
                            pc <= pc + 16'h2; state <= STATE_FETCH_REQ;
                        end
                        16'b0000001110??1???: begin // FMULSU - Fractional Signed x Unsigned
                            logic signed [15:0] fmulsu_tmp;
                            logic [15:0] fmulsu_res;
                            logic [4:0] fmulsu_d, fmulsu_r;
                            fmulsu_d = {2'b10, inst_reg[6:4]};
                            fmulsu_r = {2'b10, inst_reg[2:0]};
                            fmulsu_tmp = $signed(gpr[fmulsu_d]) * $signed({1'b0, gpr[fmulsu_r]});
                            fmulsu_res = fmulsu_tmp << 1;
                            gpr[0] <= fmulsu_res[7:0]; gpr[1] <= fmulsu_res[15:8];
                            sreg[0] <= fmulsu_tmp[15];
                            sreg[1] <= (fmulsu_res == 16'h0);
                            pc <= pc + 16'h2; state <= STATE_FETCH_REQ;
                        end
                        16'b00000001????????: begin // MOVW - Copy Register Pair
                            logic [4:0] movw_d, movw_r;
                            movw_d = {inst_reg[7:4], 1'b0};
                            movw_r = {inst_reg[3:0], 1'b0};
                            gpr[movw_d] <= gpr[movw_r];
                            gpr[movw_d + 1] <= gpr[movw_r + 1];
                            pc <= pc + 16'h2; state <= STATE_FETCH_REQ;
                        end
                        16'b1001001?????1111: begin // PUSH
                            mem_addr <= sp;
                            mem_wr_data <= gpr[d_idx];
                            mem_op <= 2'h2;
                            sp <= sp - 16'h1;
                            pc <= pc + 16'h2;
                            state <= STATE_MEM_REQ;
                        end
                        16'b1001000?????1111: begin // POP
                            sp <= sp + 16'h1;
                            mem_rd_dest <= d_idx;
                            mem_op <= 2'h1;
                            pc <= pc + 16'h2;
                            // Need to read from sp+1
                            mem_addr <= sp + 16'h1;
                            state <= STATE_MEM_REQ;
                        end
                        16'b1001000?????1100: begin // LD X
                            indirect_reg <= d_idx;
                            indirect_ptr <= {gpr[27], gpr[26]};
                            indirect_post_inc <= 1'b0; indirect_pre_dec <= 1'b0;
                            indirect_ptr_sel <= 2'd0;
                            mem_op <= 2'h1;
                            dbus_araddr <= {16'h0, gpr[27], gpr[26]}; dbus_arvalid <= 1'b1; dbus_rready <= 1'b1;
                            pc <= pc + 16'h2;
                            state <= STATE_INDIRECT_LOAD;
                        end
                        16'b1001000?????1101: begin // LD X+
                            indirect_reg <= d_idx;
                            indirect_ptr <= {gpr[27], gpr[26]};
                            indirect_post_inc <= 1'b1; indirect_pre_dec <= 1'b0;
                            indirect_ptr_sel <= 2'd0;
                            mem_op <= 2'h1;
                            dbus_araddr <= {16'h0, gpr[27], gpr[26]}; dbus_arvalid <= 1'b1; dbus_rready <= 1'b1;
                            pc <= pc + 16'h2;
                            state <= STATE_INDIRECT_LOAD;
                        end
                        16'b1001000?????1110: begin // LD -X
                            logic [15:0] ldxd_ptr;
                            indirect_reg <= d_idx;
                            ldxd_ptr = {gpr[27], gpr[26]} - 16'h1;
                            indirect_ptr <= ldxd_ptr;
                            indirect_post_inc <= 1'b0; indirect_pre_dec <= 1'b0;
                            indirect_ptr_sel <= 2'd0;
                            mem_op <= 2'h1;
                            gpr[26] <= ldxd_ptr[7:0]; gpr[27] <= ldxd_ptr[15:8];
                            dbus_araddr <= {16'h0, ldxd_ptr}; dbus_arvalid <= 1'b1; dbus_rready <= 1'b1;
                            pc <= pc + 16'h2;
                            state <= STATE_INDIRECT_LOAD;
                        end
                        16'b1001000?????1001: begin // LD Y+
                            indirect_reg <= d_idx;
                            indirect_ptr <= {gpr[29], gpr[28]};
                            indirect_post_inc <= 1'b1; indirect_pre_dec <= 1'b0;
                            indirect_ptr_sel <= 2'd1;
                            mem_op <= 2'h1;
                            dbus_araddr <= {16'h0, gpr[29], gpr[28]}; dbus_arvalid <= 1'b1; dbus_rready <= 1'b1;
                            pc <= pc + 16'h2;
                            state <= STATE_INDIRECT_LOAD;
                        end
                        16'b1001000?????1010: begin // LD -Y
                            logic [15:0] ldyd_ptr;
                            indirect_reg <= d_idx;
                            ldyd_ptr = {gpr[29], gpr[28]} - 16'h1;
                            indirect_ptr <= ldyd_ptr;
                            indirect_post_inc <= 1'b0; indirect_pre_dec <= 1'b0;
                            indirect_ptr_sel <= 2'd1;
                            mem_op <= 2'h1;
                            gpr[28] <= ldyd_ptr[7:0]; gpr[29] <= ldyd_ptr[15:8];
                            dbus_araddr <= {16'h0, ldyd_ptr}; dbus_arvalid <= 1'b1; dbus_rready <= 1'b1;
                            pc <= pc + 16'h2;
                            state <= STATE_INDIRECT_LOAD;
                        end
                        16'b1001000?????0001: begin // LD Z+
                            indirect_reg <= d_idx;
                            indirect_ptr <= {gpr[31], gpr[30]};
                            indirect_post_inc <= 1'b1; indirect_pre_dec <= 1'b0;
                            indirect_ptr_sel <= 2'd2;
                            mem_op <= 2'h1;
                            dbus_araddr <= {16'h0, gpr[31], gpr[30]}; dbus_arvalid <= 1'b1; dbus_rready <= 1'b1;
                            pc <= pc + 16'h2;
                            state <= STATE_INDIRECT_LOAD;
                        end
                        16'b1001000?????0010: begin // LD -Z
                            logic [15:0] ldzd_ptr;
                            indirect_reg <= d_idx;
                            ldzd_ptr = {gpr[31], gpr[30]} - 16'h1;
                            indirect_ptr <= ldzd_ptr;
                            indirect_post_inc <= 1'b0; indirect_pre_dec <= 1'b0;
                            indirect_ptr_sel <= 2'd2;
                            mem_op <= 2'h1;
                            gpr[30] <= ldzd_ptr[7:0]; gpr[31] <= ldzd_ptr[15:8];
                            dbus_araddr <= {16'h0, ldzd_ptr}; dbus_arvalid <= 1'b1; dbus_rready <= 1'b1;
                            pc <= pc + 16'h2;
                            state <= STATE_INDIRECT_LOAD;
                        end
                        // ST X
                        16'b1001001?????1100: begin // ST X, Rr
                            indirect_ptr <= {gpr[27], gpr[26]};
                            indirect_post_inc <= 1'b0; indirect_ptr_sel <= 2'd0;
                            dbus_awaddr <= {16'h0, gpr[27], gpr[26]}; dbus_awvalid <= 1'b1;
                            dbus_wdata <= {24'h0, gpr[d_idx]}; dbus_wvalid <= 1'b1;
                            pc <= pc + 16'h2;
                            state <= STATE_INDIRECT_STORE;
                        end
                        16'b1001001?????1101: begin // ST X+, Rr
                            indirect_ptr <= {gpr[27], gpr[26]};
                            indirect_post_inc <= 1'b1; indirect_ptr_sel <= 2'd0;
                            dbus_awaddr <= {16'h0, gpr[27], gpr[26]}; dbus_awvalid <= 1'b1;
                            dbus_wdata <= {24'h0, gpr[d_idx]}; dbus_wvalid <= 1'b1;
                            pc <= pc + 16'h2;
                            state <= STATE_INDIRECT_STORE;
                        end
                        16'b1001001?????1110: begin // ST -X, Rr
                            logic [15:0] stxd_ptr;
                            stxd_ptr = {gpr[27], gpr[26]} - 16'h1;
                            indirect_ptr <= stxd_ptr; indirect_post_inc <= 1'b0; indirect_ptr_sel <= 2'd0;
                            gpr[26] <= stxd_ptr[7:0]; gpr[27] <= stxd_ptr[15:8];
                            dbus_awaddr <= {16'h0, stxd_ptr}; dbus_awvalid <= 1'b1;
                            dbus_wdata <= {24'h0, gpr[d_idx]}; dbus_wvalid <= 1'b1;
                            pc <= pc + 16'h2;
                            state <= STATE_INDIRECT_STORE;
                        end
                        16'b1001001?????1001: begin // ST Y+, Rr
                            indirect_ptr <= {gpr[29], gpr[28]};
                            indirect_post_inc <= 1'b1; indirect_ptr_sel <= 2'd1;
                            dbus_awaddr <= {16'h0, gpr[29], gpr[28]}; dbus_awvalid <= 1'b1;
                            dbus_wdata <= {24'h0, gpr[d_idx]}; dbus_wvalid <= 1'b1;
                            pc <= pc + 16'h2;
                            state <= STATE_INDIRECT_STORE;
                        end
                        16'b1001001?????1010: begin // ST -Y, Rr
                            logic [15:0] styd_ptr;
                            styd_ptr = {gpr[29], gpr[28]} - 16'h1;
                            indirect_ptr <= styd_ptr; indirect_post_inc <= 1'b0; indirect_ptr_sel <= 2'd1;
                            gpr[28] <= styd_ptr[7:0]; gpr[29] <= styd_ptr[15:8];
                            dbus_awaddr <= {16'h0, styd_ptr}; dbus_awvalid <= 1'b1;
                            dbus_wdata <= {24'h0, gpr[d_idx]}; dbus_wvalid <= 1'b1;
                            pc <= pc + 16'h2;
                            state <= STATE_INDIRECT_STORE;
                        end
                        16'b1001001?????0001: begin // ST Z+, Rr
                            indirect_ptr <= {gpr[31], gpr[30]};
                            indirect_post_inc <= 1'b1; indirect_ptr_sel <= 2'd2;
                            dbus_awaddr <= {16'h0, gpr[31], gpr[30]}; dbus_awvalid <= 1'b1;
                            dbus_wdata <= {24'h0, gpr[d_idx]}; dbus_wvalid <= 1'b1;
                            pc <= pc + 16'h2;
                            state <= STATE_INDIRECT_STORE;
                        end
                        16'b1001001?????0010: begin // ST -Z, Rr
                            logic [15:0] stzd_ptr;
                            stzd_ptr = {gpr[31], gpr[30]} - 16'h1;
                            indirect_ptr <= stzd_ptr; indirect_post_inc <= 1'b0; indirect_ptr_sel <= 2'd2;
                            gpr[30] <= stzd_ptr[7:0]; gpr[31] <= stzd_ptr[15:8];
                            dbus_awaddr <= {16'h0, stzd_ptr}; dbus_awvalid <= 1'b1;
                            dbus_wdata <= {24'h0, gpr[d_idx]}; dbus_wvalid <= 1'b1;
                            pc <= pc + 16'h2;
                            state <= STATE_INDIRECT_STORE;
                        end
                        16'b10110???????????: begin // IN - Read I/O register
                            logic [5:0] in_addr;
                            in_addr = {inst_reg[10:9], inst_reg[3:0]};
                            mem_addr <= {10'h0, in_addr} + 16'h20;
                            mem_rd_dest <= d_idx;
                            mem_op <= 2'h1;
                            pc <= pc + 16'h2;
                            state <= STATE_MEM_REQ;
                        end
                        16'b1001010?????0100: begin // LPM Rd, Z (also handles LPM R0,Z via d_idx)
                            indirect_reg <= d_idx;
                            indirect_ptr <= {gpr[31], gpr[30]};
                            indirect_post_inc <= 1'b0;
                            pc <= pc + 16'h2;
                            state <= STATE_LPM_REQ;
                        end
                        16'b1001000?????0101: begin // LPM Rd, Z+
                            indirect_reg <= d_idx;
                            indirect_ptr <= {gpr[31], gpr[30]};
                            indirect_post_inc <= 1'b1;
                            pc <= pc + 16'h2;
                            state <= STATE_LPM_REQ;
                        end
                        16'b10?0??0?????1???: begin // LDD Y+q / STD Y+q
                            logic [5:0] ldd_q_y;
                            logic [15:0] ldd_y_addr;
                            ldd_q_y = {inst_reg[13], inst_reg[11:10], inst_reg[2:0]};
                            ldd_y_addr = {gpr[29], gpr[28]} + {10'h0, ldd_q_y};
                            indirect_ptr <= {gpr[29], gpr[28]};
                            indirect_post_inc <= 1'b0; indirect_ptr_sel <= 2'd1;
                            if (!inst_reg[9]) begin // LDD
                                indirect_reg <= d_idx;
                                mem_op <= 2'h1;
                                dbus_araddr <= {16'h0, ldd_y_addr}; dbus_arvalid <= 1'b1; dbus_rready <= 1'b1;
                                state <= STATE_INDIRECT_LOAD;
                            end else begin // STD
                                dbus_awaddr <= {16'h0, ldd_y_addr}; dbus_awvalid <= 1'b1;
                                dbus_wdata <= {24'h0, gpr[d_idx]}; dbus_wvalid <= 1'b1;
                                state <= STATE_INDIRECT_STORE;
                            end
                            pc <= pc + 16'h2;
                        end
                        16'b10?0??0?????0???: begin // LDD Z+q / STD Z+q
                            logic [5:0] ldd_q_z;
                            logic [15:0] ldd_z_addr;
                            ldd_q_z = {inst_reg[13], inst_reg[11:10], inst_reg[2:0]};
                            ldd_z_addr = {gpr[31], gpr[30]} + {10'h0, ldd_q_z};
                            indirect_ptr <= {gpr[31], gpr[30]};
                            indirect_post_inc <= 1'b0; indirect_ptr_sel <= 2'd2;
                            if (!inst_reg[9]) begin // LDD
                                indirect_reg <= d_idx;
                                mem_op <= 2'h1;
                                dbus_araddr <= {16'h0, ldd_z_addr}; dbus_arvalid <= 1'b1; dbus_rready <= 1'b1;
                                state <= STATE_INDIRECT_LOAD;
                            end else begin // STD
                                dbus_awaddr <= {16'h0, ldd_z_addr}; dbus_awvalid <= 1'b1;
                                dbus_wdata <= {24'h0, gpr[d_idx]}; dbus_wvalid <= 1'b1;
                                state <= STATE_INDIRECT_STORE;
                            end
                            pc <= pc + 16'h2;
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
                        16'b1001010?????0110: begin // LSR - Logical Shift Right
                            logic [7:0] lsr_res; logic lsr_c, lsr_n, lsr_z, lsr_v, lsr_s;
                            lsr_c = gpr[d_idx][0]; lsr_res = gpr[d_idx] >> 1;
                            lsr_n = 1'b0; lsr_z = (lsr_res == 8'h00); lsr_v = lsr_n ^ lsr_c; lsr_s = lsr_n ^ lsr_v;
                            gpr[d_idx] <= lsr_res;
                            sreg <= {sreg[7:6], sreg[5], lsr_s, lsr_v, lsr_n, lsr_z, lsr_c};
                            pc <= pc + 16'h2; state <= STATE_FETCH_REQ;
                        end
                        16'b1001010?????0111: begin // ROR - Rotate Right through Carry
                            logic [7:0] ror_res; logic ror_c, ror_n, ror_z, ror_v, ror_s;
                            ror_c = gpr[d_idx][0]; ror_res = {sreg[0], gpr[d_idx][7:1]};
                            ror_n = ror_res[7]; ror_z = (ror_res == 8'h00); ror_v = ror_n ^ ror_c; ror_s = ror_n ^ ror_v;
                            gpr[d_idx] <= ror_res;
                            sreg <= {sreg[7:6], sreg[5], ror_s, ror_v, ror_n, ror_z, ror_c};
                            pc <= pc + 16'h2; state <= STATE_FETCH_REQ;
                        end
                        16'b1001010?????0101: begin // ASR - Arithmetic Shift Right
                            logic [7:0] asr_res; logic asr_c, asr_n, asr_z, asr_v, asr_s;
                            asr_c = gpr[d_idx][0]; asr_res = {gpr[d_idx][7], gpr[d_idx][7:1]};
                            asr_n = asr_res[7]; asr_z = (asr_res == 8'h00); asr_v = asr_n ^ asr_c; asr_s = asr_n ^ asr_v;
                            gpr[d_idx] <= asr_res;
                            sreg <= {sreg[7:6], sreg[5], asr_s, asr_v, asr_n, asr_z, asr_c};
                            pc <= pc + 16'h2; state <= STATE_FETCH_REQ;
                        end
                        16'b1001010?????0010: begin // SWAP - Swap Nibbles
                            gpr[d_idx] <= {gpr[d_idx][3:0], gpr[d_idx][7:4]};
                            pc <= pc + 16'h2; state <= STATE_FETCH_REQ;
                        end
                        16'b1111101?????0???: begin // BST - Bit Store to T
                            sreg[6] <= gpr[d_idx][inst_reg[2:0]];
                            pc <= pc + 16'h2; state <= STATE_FETCH_REQ;
                        end
                        16'b1111100?????0???: begin // BLD - Bit Load from T
                            if (sreg[6])
                                gpr[d_idx] <= gpr[d_idx] | (8'h1 << inst_reg[2:0]);
                            else
                                gpr[d_idx] <= gpr[d_idx] & ~(8'h1 << inst_reg[2:0]);
                            pc <= pc + 16'h2; state <= STATE_FETCH_REQ;
                        end
                        16'b10011010????????: begin // SBI - Set Bit in I/O Register
                            io_bit_addr <= {inst_reg[7:3]};
                            io_bit_num <= inst_reg[2:0];
                            io_bit_val <= 1'b1;
                            // Read I/O register first
                            dbus_araddr <= {16'h0, 11'h0, inst_reg[7:3]} + 32'h20;
                            dbus_arvalid <= 1'b1; dbus_rready <= 1'b1;
                            pc <= pc + 16'h2;
                            state <= STATE_IO_BIT_READ;
                        end
                        16'b10011000????????: begin // CBI - Clear Bit in I/O Register
                            io_bit_addr <= {inst_reg[7:3]};
                            io_bit_num <= inst_reg[2:0];
                            io_bit_val <= 1'b0;
                            dbus_araddr <= {16'h0, 11'h0, inst_reg[7:3]} + 32'h20;
                            dbus_arvalid <= 1'b1; dbus_rready <= 1'b1;
                            pc <= pc + 16'h2;
                            state <= STATE_IO_BIT_READ;
                        end
                        16'b100101000???1000: begin // BSET - Set SREG bit
                            sreg[inst_reg[6:4]] <= 1'b1;
                            pc <= pc + 16'h2; state <= STATE_FETCH_REQ;
                        end
                        16'b100101001???1000: begin // BCLR - Clear SREG bit
                            sreg[inst_reg[6:4]] <= 1'b0;
                            pc <= pc + 16'h2; state <= STATE_FETCH_REQ;
                        end
                        16'b10011001????????: begin // SBIC - Skip if Bit in I/O Cleared
                            // Read I/O register, check bit, potentially skip
                            io_bit_addr <= {inst_reg[7:3]};
                            io_bit_num <= inst_reg[2:0];
                            io_bit_val <= 1'b0; // 0 = skip if cleared
                            dbus_araddr <= {16'h0, 11'h0, inst_reg[7:3]} + 32'h20;
                            dbus_arvalid <= 1'b1; dbus_rready <= 1'b1;
                            pc <= pc + 16'h2;
                            state <= STATE_IO_BIT_WRITE; // reuse for read-then-skip
                        end
                        16'b10011011????????: begin // SBIS - Skip if Bit in I/O Set
                            io_bit_addr <= {inst_reg[7:3]};
                            io_bit_num <= inst_reg[2:0];
                            io_bit_val <= 1'b1; // 1 = skip if set
                            dbus_araddr <= {16'h0, 11'h0, inst_reg[7:3]} + 32'h20;
                            dbus_arvalid <= 1'b1; dbus_rready <= 1'b1;
                            pc <= pc + 16'h2;
                            state <= STATE_IO_BIT_WRITE; // reuse for read-then-skip
                        end
                        16'b1001010110001000: begin // SLEEP (NOP for simulation)
                            pc <= pc + 16'h2; state <= STATE_FETCH_REQ;
                        end
                        16'b1001010110101000: begin // WDR - Watchdog Reset (NOP)
                            pc <= pc + 16'h2; state <= STATE_FETCH_REQ;
                        end
                        16'b1001010110011000: begin // BREAK - Debug Break (NOP)
                            pc <= pc + 16'h2; state <= STATE_FETCH_REQ;
                        end
                        16'b10010111????????: begin // SBIW
                            logic [4:0] ridx; logic [15:0] val, res;
                            ridx = 24 + ({3'h0, inst_reg[5:4]} << 1);
                            val = {gpr[ridx+1], gpr[ridx]};
                            res = val - {10'h0, inst_reg[7:6], inst_reg[3:0]};
                            gpr[ridx] <= res[7:0]; gpr[ridx+1] <= res[15:8];
                            sreg[0] <= res[15] & ~val[15];  // C
                            sreg[1] <= (res == 16'h0);       // Z
                            sreg[2] <= res[15];              // N
                            sreg[3] <= val[15] & ~res[15];   // V (was missing)
                            sreg[4] <= res[15] ^ (val[15] & ~res[15]); // S
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

                // === CALL: Push high byte of return address ===
                STATE_CALL_PUSH_H: begin
                    if (mem_op == 2'h2) begin
                        dbus_awaddr <= {16'h0000, mem_addr}; dbus_awvalid <= 1'b1;
                        dbus_wdata <= {24'h0, mem_wr_data}; dbus_wvalid <= 1'b1;
                    end
                    state <= STATE_CALL_PUSH_L;
                end

                // === CALL: Wait for high byte write, then push low byte ===
                STATE_CALL_PUSH_L: begin
                    if (dbus_awvalid && dbus_awready) dbus_awvalid <= 1'b0;
                    if (dbus_wvalid && dbus_wready) dbus_wvalid <= 1'b0;
                    if (dbus_bvalid && dbus_bready) begin
                        // Now push low byte of return address
                        // Return addr = (pc+2)/2 in word address, we store low byte
                        // For 16-bit PC: stack gets PC+1 (word), high byte then low byte
                        // pc is byte address, word address = pc/2
                        // We stored high byte. Now store low byte.
                        logic [15:0] ret_word;
                        ret_word = (pc + 16'h2) >> 1; // word address of return
                        dbus_awaddr <= {16'h0000, sp}; dbus_awvalid <= 1'b1;
                        dbus_wdata <= {24'h0, ret_word[7:0]}; dbus_wvalid <= 1'b1;
                        sp <= sp - 16'h1;
                        pc <= call_ret_addr;
                        state <= STATE_MEM_WAIT;
                        mem_op <= 2'h2; // so MEM_WAIT knows it's a write
                    end
                end

                // === RET: Pop low byte of return address ===
                STATE_RET_POP_L: begin
                    dbus_araddr <= {16'h0000, sp}; dbus_arvalid <= 1'b1; dbus_rready <= 1'b1;
                    state <= STATE_RET_POP_H;
                end

                // === RET: Wait for low byte, pop high byte ===
                STATE_RET_POP_H: begin
                    if (dbus_arvalid && dbus_arready) dbus_arvalid <= 1'b0;
                    if (dbus_rvalid && dbus_rready) begin
                        dbus_rready <= 1'b0;
                        call_ret_addr[7:0] <= dbus_rdata[7:0]; // low byte of word addr
                        sp <= sp + 16'h1;
                        // Now read high byte
                        dbus_araddr <= {16'h0000, sp + 16'h1}; dbus_arvalid <= 1'b1; dbus_rready <= 1'b1;
                        state <= STATE_INDIRECT_LOAD; // reuse: wait for read, then jump
                    end
                end

                // === Indirect Load state (also used by RET high-byte read and Phase 3) ===
                STATE_INDIRECT_LOAD: begin
                    if (dbus_arvalid && dbus_arready) dbus_arvalid <= 1'b0;
                    if (dbus_rvalid && dbus_rready) begin
                        dbus_rready <= 1'b0;
                        if (mem_op == 2'h0) begin
                            // RET: this is the high byte read
                            call_ret_addr[15:8] <= dbus_rdata[7:0];
                            pc <= {dbus_rdata[7:0], call_ret_addr[7:0]} << 1; // word->byte addr
                            state <= STATE_FETCH_REQ;
                        end else begin
                            // Indirect register load (Phase 3)
                            gpr[indirect_reg] <= dbus_rdata[7:0];
                            // Handle post-increment
                            if (indirect_post_inc) begin
                                case (indirect_ptr_sel)
                                    2'd0: begin gpr[26] <= (indirect_ptr + 1); gpr[27] <= (indirect_ptr + 1) >> 8; end
                                    2'd1: begin gpr[28] <= (indirect_ptr + 1); gpr[29] <= (indirect_ptr + 1) >> 8; end
                                    2'd2: begin gpr[30] <= (indirect_ptr + 1); gpr[31] <= (indirect_ptr + 1) >> 8; end
                                    default: ;
                                endcase
                            end
                            state <= STATE_FETCH_REQ;
                        end
                    end
                end

                // === Indirect Store state (Phase 3) ===
                STATE_INDIRECT_STORE: begin
                    if (dbus_awvalid && dbus_awready) dbus_awvalid <= 1'b0;
                    if (dbus_wvalid && dbus_wready) dbus_wvalid <= 1'b0;
                    if (dbus_bvalid && dbus_bready) begin
                        // Handle post-increment
                        if (indirect_post_inc) begin
                            case (indirect_ptr_sel)
                                2'd0: begin gpr[26] <= (indirect_ptr + 1); gpr[27] <= (indirect_ptr + 1) >> 8; end
                                2'd1: begin gpr[28] <= (indirect_ptr + 1); gpr[29] <= (indirect_ptr + 1) >> 8; end
                                2'd2: begin gpr[30] <= (indirect_ptr + 1); gpr[31] <= (indirect_ptr + 1) >> 8; end
                                default: ;
                            endcase
                        end
                        state <= STATE_FETCH_REQ;
                    end
                end

                // === LPM: Request read from instruction bus ===
                STATE_LPM_REQ: begin
                    ibus_araddr <= {16'h0000, indirect_ptr[15:2], 2'b00};
                    ibus_arvalid <= 1'b1; ibus_rready <= 1'b1;
                    state <= STATE_LPM_WAIT;
                end

                // === LPM: Wait for instruction bus read ===
                STATE_LPM_WAIT: begin
                    if (ibus_arvalid && ibus_arready) ibus_arvalid <= 1'b0;
                    if (ibus_rvalid && ibus_rready) begin
                        ibus_rready <= 1'b0;
                        // Select byte based on Z[0] (indirect_ptr[0])
                        if (indirect_ptr[1] == 1'b0)
                            gpr[indirect_reg] <= indirect_ptr[0] ? ibus_rdata[15:8] : ibus_rdata[7:0];
                        else
                            gpr[indirect_reg] <= indirect_ptr[0] ? ibus_rdata[31:24] : ibus_rdata[23:16];
                        // Post-increment Z if needed
                        if (indirect_post_inc) begin
                            gpr[30] <= (indirect_ptr + 1);
                            gpr[31] <= (indirect_ptr + 1) >> 8;
                        end
                        state <= STATE_FETCH_REQ;
                    end
                end

                // === I/O Bit Read (for SBI/CBI - read-modify-write) ===
                STATE_IO_BIT_READ: begin
                    if (dbus_arvalid && dbus_arready) dbus_arvalid <= 1'b0;
                    if (dbus_rvalid && dbus_rready) begin
                        dbus_rready <= 1'b0;
                        io_bit_data <= dbus_rdata[7:0];
                        // Modify the bit
                        if (io_bit_val)
                            mem_wr_data <= dbus_rdata[7:0] | (8'h1 << io_bit_num);
                        else
                            mem_wr_data <= dbus_rdata[7:0] & ~(8'h1 << io_bit_num);
                        // Write back
                        mem_addr <= {11'h0, io_bit_addr} + 16'h20;
                        mem_op <= 2'h2;
                        state <= STATE_MEM_REQ;
                    end
                end

                // === I/O Bit Read for SBIC/SBIS (read, check bit, skip or not) ===
                STATE_IO_BIT_WRITE: begin
                    if (dbus_arvalid && dbus_arready) dbus_arvalid <= 1'b0;
                    if (dbus_rvalid && dbus_rready) begin
                        dbus_rready <= 1'b0;
                        // io_bit_val: 0 = skip if cleared (SBIC), 1 = skip if set (SBIS)
                        if (io_bit_val) begin
                            if (dbus_rdata[io_bit_num])
                                state <= STATE_SKIP_FETCH_REQ;
                            else
                                state <= STATE_FETCH_REQ;
                        end else begin
                            if (!dbus_rdata[io_bit_num])
                                state <= STATE_SKIP_FETCH_REQ;
                            else
                                state <= STATE_FETCH_REQ;
                        end
                    end
                end

                // === Skip: Fetch next instruction to determine if 1 or 2 words ===
                STATE_SKIP_FETCH_REQ: begin
                    ibus_araddr <= {16'h0000, pc[15:2], 2'b00};
                    ibus_arvalid <= 1'b1; ibus_rready <= 1'b1;
                    state <= STATE_SKIP_FETCH_WAIT;
                end

                STATE_SKIP_FETCH_WAIT: begin
                    if (ibus_arvalid && ibus_arready) ibus_arvalid <= 1'b0;
                    if (ibus_rvalid && ibus_rready) begin
                        logic [15:0] skip_inst;
                        ibus_rready <= 1'b0;
                        skip_inst = (pc[1] == 1'b0) ? ibus_rdata[15:0] : ibus_rdata[31:16];
                        // Check if the skipped instruction is 2 words (LDS/STS/JMP/CALL)
                        if ((skip_inst[15:10] == 6'b100100 && skip_inst[3:0] == 4'b0000) || // LDS/STS
                            (skip_inst[15:9] == 7'b1001010 && skip_inst[3:1] == 3'b110))    // JMP/CALL
                            pc <= pc + 16'h4; // skip 2-word instruction
                        else
                            pc <= pc + 16'h2; // skip 1-word instruction
                        state <= STATE_FETCH_REQ;
                    end
                end

                default: state <= STATE_RESET;
            endcase
        end
    end

endmodule
