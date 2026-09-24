module fifo_out #( 
parameter  OUTW     = 24, 
parameter  DEPTH    = 19, 
parameter  READY_USE_ALMOST_FULL= 0,
parameter  READY_USE_ALMOST_FULL_THRESH = DEPTH,
localparam LOGDEPTH = $clog2(DEPTH) 
)( 
input                   clk,  
input                   reset, 
input [OUTW-1:0]        IN_AXIS_TDATA, 
input                   IN_AXIS_TVALID, 
output logic            IN_AXIS_TREADY,
output logic            IN_AXIS_ALMOST_FULL, 
output logic [OUTW-1:0] OUT_AXIS_TDATA, 
output logic            OUT_AXIS_TVALID, 
input                   OUT_AXIS_TREADY

);
logic [OUTW-1:0] data_in;
logic [OUTW-1:0] data_out;
logic            wr_en;
logic            rd_en;
logic            fifo_empty;
logic            fifo_full;
logic            almost_full;
//---------------------memory ----------------------------------//
fifo_ram #(.DATA_W(OUTW), 
    .DEPTH(DEPTH),
    .ALMOST_FULL_THRESH(READY_USE_ALMOST_FULL_THRESH)) u_output_fifo (
    .clk       (clk),
    .reset     (reset),
    .din       (data_in),
    .wr_en     (wr_en), 
    .rd_en     (rd_en),
    .dout      (data_out),
    .empty     (fifo_empty),
    .almost_empty (),
    .full      (fifo_full),
    .almost_full(almost_full)
);

assign IN_AXIS_TREADY = ~fifo_full ;
assign IN_AXIS_ALMOST_FULL = almost_full;
assign data_in = IN_AXIS_TDATA;
assign wr_en = IN_AXIS_TVALID && IN_AXIS_TREADY;

assign OUT_AXIS_TDATA = data_out;
assign OUT_AXIS_TVALID = ~fifo_empty ;
assign rd_en = OUT_AXIS_TVALID && OUT_AXIS_TREADY;
endmodule
