// conv.sv  —  Top-level convolution (valid, stride=1)
// Assumes: single-lane MAC; mac_pipe outputs running sum (accumulator).
// BRAM has 1-cycle sync read latency; mac_pipe adds product to sum 1 cycle later.
// So from issuing read addresses to the sum being updated is "two cycles".

module Conv #(
  parameter INW   = 18,  // input data width
  parameter R     = 9,
  parameter C     = 8,
  parameter MAXK  = 5,
  // Safe output width: product(2*INW) + log2(K*K) + 1 guard bit
  localparam OUTW  = $clog2(MAXK*MAXK*(128'd1 << 2*INW-2) + (1<<(INW-1)))+1,
  localparam K_BITS = $clog2(MAXK+1)
)(
  input  logic                 clk,
  input  logic                 reset,

  // AXIS input (weights, bias, inputs) — forwarded into input_mems
  input  logic [INW-1:0]       INPUT_TDATA,
  input  logic                 INPUT_TVALID,
  input  logic [K_BITS:0]      INPUT_TUSER,   // per project spec: carries K & new_W
  output logic                 INPUT_TREADY,

  // AXIS output (results)
  output logic [OUTW-1:0]      OUTPUT_TDATA,
  output logic                 OUTPUT_TVALID,
  input  logic                 OUTPUT_TREADY
);

  // ------------------------------------------------------------
  // Derived widths
  // ------------------------------------------------------------
  localparam  X_ADDR_BITS     = $clog2(R*C);
  localparam  W_ADDR_BITS     = $clog2(MAXK*MAXK);
  localparam  OUT_ROW_BITS    = $clog2(R);
  localparam  OUT_COL_BITS    = $clog2(C);
  localparam  OUTPUT_FIFO_DEPTH = C*2;  // depth of input FIFO to buffer one row
  localparam  REG_ARRAY_CNT = MAXK*C;  // number of registers in line buffer array
  localparam  LOG2_REG_ARRAY_CNT = MAXK*C;  // number of registers in line buffer array
localparam FIFO_USE_ALMOST_FULL = 1; // set to 1 to use almost_full signal for backpressure
localparam FIFO_ALMOST_FULL_THRESH = OUTPUT_FIFO_DEPTH - 3;
  // ------------------------------------------------------------
  // input memories interface signals
  // ------------------------------------------------------------
// Top-level wrapper that connects input_mems, conv_control, and fifo_out

    // -------- Internal signals between blocks --------

    // From input_mems to conv_control (decoded K and bias B)
    logic [K_BITS-1:0]         K_from_mems;
    logic signed [INW-1:0]     B_from_mems;

    // Stream of input feature-map data from input_mems to conv_control
    logic [INW-1:0]            x_tdata;
    logic                      x_tvalid;
    logic                      x_tready;

    // Weight memory read interface (conv_control -> input_mems)
    logic                      w_read_en;
    logic [W_ADDR_BITS-1:0]    w_read_addr;
    logic [INW-1:0]            w_read_data;

    // Convolution result stream (conv_control -> fifo_out)
    logic [OUTW-1:0]           conv_out_tdata;
    logic                      conv_out_tvalid;
    logic                      conv_out_tready;
    logic                      conv_out_almost_full;

    // ============================================================
    //  input_mems instance
    //  - Receives AXIS input stream (weights / bias / inputs)
    //  - Stores them in internal memories
    //  - Outputs K, B, feature-map stream, and weight read data
    // ============================================================
    input_mems #(
        .INW  (INW),
        .R    (R),
        .C    (C),
        .MAXK (MAXK)
    ) u_input_mems (
        .clk          (clk),
        .reset        (reset),

        // AXIS input from upstream
        .AXIS_TDATA   (INPUT_TDATA),
        .AXIS_TVALID  (INPUT_TVALID),
        .AXIS_TUSER   (INPUT_TUSER),
        .AXIS_TREADY  (INPUT_TREADY),

        // Decoded kernel size and bias
        .K            (K_from_mems),
        .B            (B_from_mems),

        // Feature-map stream towards conv_control
        .X_OUTPUT_TDATA  (x_tdata),
        .X_OUTPUT_TVALID (x_tvalid),
        .X_OUTPUT_TREADY (x_tready),

        // Weight read interface (driven by conv_control)
        .W_rd_en      (w_read_en),
        .W_rd_addr    (w_read_addr),
        .W_rd_data    (w_read_data)
    );

    // ============================================================
    //  conv_control instance
    //  - Controls convolution computation
    //  - Reads weights via W_read_* from input_mems
    //  - Consumes feature-map stream
    //  - Produces convolution result stream
    // ============================================================
    conv_control #(
        .INW  (INW),
        .R    (R),
        .C    (C),
        .MAXK (MAXK)
 //       .FIFO_ALMOST_FULL_THRESH(OUTPUT_FIFO_DEPTH - 1 ),
 //       .FIFO_USE_ALMOST_FULL(FIFO_USE_ALMOST_FULL)
    ) u_conv_control (
        .clk          (clk),
        .reset        (reset),

        // K and B (forwarded from input_mems)
        // If your K_input width is [$clog2(MAXK):0], you can extend here.
        .K_input      (K_from_mems),  // adjust if widths differ
        .B_input      (B_from_mems),

        // Input feature-map stream from input_mems
        .INPUT_TDATA  (x_tdata),
        .INPUT_TVALID (x_tvalid),
        .INPUT_TREADY (x_tready),

        // Weight read interface to input_mems
        .W_read_en    (w_read_en),
        .W_read_addr  (w_read_addr),
        .W_read_data  (w_read_data),

        // Convolution result stream to fifo_out
        .OUTPUT_TDATA (conv_out_tdata),
        .OUTPUT_TVALID(conv_out_tvalid),
        .OUTPUT_TREADY(conv_out_tready),
        .OUTPUT_ALMOST_FULL(conv_out_almost_full) // 
    );

    // ============================================================
    //  fifo_out instance
    //  - Simple AXIS FIFO on the result stream
    //  - Provides backpressure to conv_control via OUT_AXIS_TREADY
    // ============================================================
    fifo_out #(
        .OUTW  (OUTW),
        .DEPTH (OUTPUT_FIFO_DEPTH),
        .READY_USE_ALMOST_FULL(FIFO_USE_ALMOST_FULL),
        .READY_USE_ALMOST_FULL_THRESH(FIFO_ALMOST_FULL_THRESH)
    ) u_fifo_out (
        .clk            (clk),
        .reset          (reset),

        // Input stream from conv_control
        .IN_AXIS_TDATA  (conv_out_tdata),
        .IN_AXIS_TVALID (conv_out_tvalid),
        .IN_AXIS_TREADY (conv_out_tready),
        .IN_AXIS_ALMOST_FULL (conv_out_almost_full),

        // Output stream to downstream
        .OUT_AXIS_TDATA (OUTPUT_TDATA),
        .OUT_AXIS_TVALID(OUTPUT_TVALID),
        .OUT_AXIS_TREADY(OUTPUT_TREADY)
    );

endmodule
