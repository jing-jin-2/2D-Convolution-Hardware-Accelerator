module fifo_out #( 
parameter  OUTW     = 24, 
parameter  DEPTH    = 19, 
localparam LOGDEPTH = $clog2(DEPTH) 
)( 
input                   clk,  
input                   reset, 
input [OUTW-1:0]        IN_AXIS_TDATA, 
input                   IN_AXIS_TVALID, 
output logic            IN_AXIS_TREADY, 
output logic [OUTW-1:0] OUT_AXIS_TDATA, 
output logic            OUT_AXIS_TVALID, 
input                   OUT_AXIS_TREADY
);
wire wr_en, rd_en;
logic[LOGDEPTH-1:0] write_addr;
logic[LOGDEPTH-1:0] read_addr, read_addr_nxt;
logic[LOGDEPTH:0] gap;
wire fifo_empty_n, fifo_full_n;
wire [OUTW-1:0] data_in, data_out;
//bug
// since depth is not 2, so it can overflow 
// for read address, read data is not just when address changes
//---------------------memory write ----------------------------//
assign wr_en = IN_AXIS_TREADY && IN_AXIS_TVALID;
assign IN_AXIS_TREADY = fifo_full_n || (~fifo_full_n && OUT_AXIS_TREADY);
assign data_in = IN_AXIS_TDATA;
assign fifo_full_n = gap != DEPTH;
always_ff @(posedge clk) begin
    if(reset) begin
        write_addr <= '0;
        read_addr <= '0;
        gap <= 0;
    end
    else begin
        case({wr_en,rd_en})
            2'b01: begin
                read_addr <= (read_addr == (DEPTH-1)) ? 0: (read_addr + 1);
                gap <= gap - 1;
            end
            2'b10: begin
                write_addr <= (write_addr == (DEPTH-1))? 0 : (write_addr + 1);
                gap <= gap + 1;
            end
            2'b11: begin
                write_addr <= (write_addr == (DEPTH-1))? 0 :(write_addr + 1);
                read_addr <= (read_addr == (DEPTH-1)) ? 0: (read_addr + 1);
            end
            default: begin
                read_addr <= read_addr;
                write_addr <= write_addr;
            end
        endcase
    end
end

always_comb begin
read_addr_nxt = read_addr;
if(rd_en && (read_addr == (DEPTH-1)))
    read_addr_nxt = 0;
else if(rd_en)
    read_addr_nxt = read_addr + 1;
end

//---------------------memory read -----------------------------//
assign fifo_empty_n = gap != 0;
assign rd_en = OUT_AXIS_TVALID && OUT_AXIS_TREADY;
assign OUT_AXIS_TVALID = fifo_empty_n;
assign OUT_AXIS_TDATA = data_out;

//---------------------memory ----------------------------------//
memory_dual_port #(
    .WIDTH(OUTW), 
    .SIZE(DEPTH)
) x_fifo_mem(
    .data_in(data_in),
    .data_out(data_out),
    .write_addr(write_addr[LOGDEPTH-1:0]),
    .read_addr(read_addr_nxt[LOGDEPTH-1:0]),
    .clk(clk), 
    .wr_en(wr_en)
    );

endmodule