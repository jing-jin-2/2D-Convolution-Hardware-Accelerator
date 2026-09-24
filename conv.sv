// conv.sv  —  Top-level convolution (valid, stride=1)
// Assumes: single-lane MAC; mac_pipe outputs running sum (accumulator).
// BRAM has 1-cycle sync read latency; mac_pipe adds product to sum 1 cycle later.
// So from issuing read addresses to the sum being updated is "two cycles".

module Conv #(
  parameter INW   = 18,
  parameter R     = 9,
  parameter C     = 8,
  parameter MAXK  = 5,
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
  localparam X_ADDR_BITS     = $clog2(R*C);
  localparam W_ADDR_BITS     = $clog2(MAXK*MAXK);
  localparam OUT_ROW_BITS    = $clog2(R);
  localparam OUT_COL_BITS    = $clog2(C);

  // ------------------------------------------------------------
  // FSM
  // ------------------------------------------------------------
  typedef enum logic [1:0] {IDLE, LOAD, WAIT_MAC, OUTPUT} state_t;
  state_t fsm_cs, fsm_ns;

  // ------------------------------------------------------------
  // input_mems interface
  // ------------------------------------------------------------
  wire                  inputs_loaded;
  wire                  compute_finished; // to input_mems
  wire [K_BITS-1:0]     K;
  wire signed [INW-1:0] B;

  logic [X_ADDR_BITS-1:0] X_read_addr;
  logic [W_ADDR_BITS-1:0] W_read_addr;
  wire  signed [INW-1:0]  X_data;
  wire  signed [INW-1:0]  W_data;

  // ------------------------------------------------------------
  // Output coordinates (row-major): (oi,oj) over (R-K+1) x (C-K+1)
  // ------------------------------------------------------------
  logic [OUT_ROW_BITS-1:0] Xi;
  logic [OUT_COL_BITS-1:0] Xj;
  logic [X_ADDR_BITS:0] output_element_cnt;
  // ------------------------------------------------------------
  // Tap counter as explicit row/col within KxK window (avoids variable divide)
  // ------------------------------------------------------------
  logic [W_ADDR_BITS-1:0] W_rd_cnt;   // issues addresses 0..K*K-1
  logic [K_BITS-1:0]      tap_row_idx;
  logic [K_BITS-1:0]      tap_col_idx;

  // Drive reads continuously once inputs are available
  logic read_valid;
  wire read_en;

  // wire mac_fin_once = (fsm_cs == OUTPUT);

  // ------------------------------------------------------------
  // Per-pixel accumulation count (counts when sum actually updates)
  // ------------------------------------------------------------
  // logic [$clog2(MAXK*MAXK):0] acc_tap_cnt;

  // At the cycle when the K*K-th product is added, we have one output pixel ready
  wire read_fin_one_element;
  logic read_fin_one_element_r;
  wire read_fin_one_element_c;

  // ------------------------------------------------------------
  // Generate mac_pipe controls: init_acc pulse at the very 1st tap of each pixel
  // ------------------------------------------------------------
  logic init_acc;

  // ------------------------------------------------------------
  // Read address generation (row-major)
  //   W: tap_row_idx*K + tap_col_idx
  //   X: (oi+tap_row_idx)*C + (oj+tap_col_idx)
  // ------------------------------------------------------------
  assign W_read_addr = W_rd_cnt;

  wire [X_ADDR_BITS-1:0] oi_plus_tap = Xi + tap_row_idx;
  wire [X_ADDR_BITS-1:0] oj_plus_tap = Xj + tap_col_idx;
  assign X_read_addr = oi_plus_tap*C + oj_plus_tap;

  // ------------------------------------------------------------
  // Next-state logic
  //   - Wait for inputs_loaded
  //   - LOAD issues one tap address
  //   - WAIT_MAC waits 1 cycle (BRAM latency)
  //   - OUTPUT :
  //        * mac_fin_once -> sum updates
  //        * if last tap, push into FIFO (when FIFO can accept), then go next pixel
  // ------------------------------------------------------------
  // FIFO handshake (input side)
  wire             fifo_in_ready;
  logic            fifo_in_valid;
  logic [OUTW-1:0] fifo_in_data;

  // Can we finish this pixel now?
  wire pixel_done_and_pushed;
// assign read_valid = ((fsm_cs == LOAD)  && fifo_in_ready);
assign read_en  = inputs_loaded && ~read_fin_one_element_r && fifo_in_ready;
always_ff @(posedge clk or posedge reset) begin
  if (reset) begin
    read_valid <= 1'b0;
  end 
  else begin
    read_valid <= read_en;
  end
end

assign pixel_done_and_pushed = read_fin_one_element && fifo_in_ready && (fsm_cs == OUTPUT);
assign init_acc = (read_en&& W_rd_cnt == '0);
// assign read_fin_one_element = (acc_tap_cnt == (K*K-1)) && read_valid;

  always_comb begin
    fsm_ns = fsm_cs;
    unique case (fsm_cs)
      IDLE: begin
        if (inputs_loaded && fifo_in_ready)               
          fsm_ns = LOAD;
      end

      LOAD: begin
        if(read_fin_one_element_r)
        fsm_ns = WAIT_MAC;
      end

      WAIT_MAC: begin
        // next cycle mac_pipe will add product into sum
        // If not finished this pixel yet, go issue next tap
          fsm_ns = OUTPUT;
      end

      OUTPUT: begin
        // If this is the last tap, wait until FIFO accepts the result,
        // then start next pixel or go idle if image finished.
          if (pixel_done_and_pushed) begin
            if (compute_finished) 
              fsm_ns = IDLE;
            else                                
              fsm_ns = LOAD;
          end
          // else: hold in OUTPUT until FIFO ready
        end
    endcase
  end

  // ------------------------------------------------------------
  // State register
  // ------------------------------------------------------------
  always_ff @(posedge clk) begin
    if (reset) 
      fsm_cs <= IDLE;
    else       
      fsm_cs <= fsm_ns;
  end

  // ------------------------------------------------------------
  // Tap issue counter (0..K*K-1), wraps per pixel
  // ------------------------------------------------------------
  // Tap row/col counters advance across the KxK window; derive W_rd_cnt from them
  assign W_rd_cnt = (K == 0) ? '0 : (tap_row_idx * K + tap_col_idx);

  always_ff @(posedge clk or posedge reset) begin
    if (reset) begin
      tap_row_idx <= '0;
      tap_col_idx <= '0;
    end else if (read_en) begin
      if (K == 0) begin
        tap_row_idx <= '0;
        tap_col_idx <= '0;
      end else if (tap_col_idx == (K-1)) begin
        tap_col_idx <= '0;
        if (tap_row_idx == (K-1))
          tap_row_idx <= '0;
        else
          tap_row_idx <= tap_row_idx + 1'b1;
      end else begin
        tap_col_idx <= tap_col_idx + 1'b1;
      end
    end
  end

  always_ff @(posedge clk or posedge reset) begin
    if (reset) begin
      Xi <= '0;
      Xj <= '0;
    end 
    else if (read_en && (tap_row_idx == (K-1)) && (tap_col_idx == (K-1))) begin
      if (Xj == (C-K)) begin
        Xj <= '0;
        Xi <= (Xi == (R-K)) ? '0 : (Xi+1'b1);
      end 
      else begin
        Xj <=Xj + 1'b1;
      end
    end
  end

assign read_fin_one_element_c = (tap_row_idx == (K-1)) && (tap_col_idx == (K-1)) && read_en;
always_ff @(posedge clk or posedge reset) begin
  if (reset) begin
    read_fin_one_element_r <= '0;  
  end 
  else if (read_fin_one_element_c) begin
    read_fin_one_element_r <= '1;
  end
  else if (pixel_done_and_pushed) begin
    read_fin_one_element_r <= '0;
  end
end 
assign read_fin_one_element = read_fin_one_element_r || read_fin_one_element_c ;
  // ------------------------------------------------------------
  // Output coordinates advance AFTER pushing the pixel into FIFO
  // ------------------------------------------------------------
  always_ff @(posedge clk or posedge reset) begin
    if (reset) begin
      output_element_cnt <= '0;
    end else if (pixel_done_and_pushed) begin
        output_element_cnt <= (output_element_cnt == ((R-K+1)*(C-K+1)-1'b1)) ? '0 : output_element_cnt + 1'b1;
  end
  end
  // ------------------------------------------------------------
  // mac_pipe: running sum for this output pixel
  //   - init_acc=1 at the first tap of a pixel loads bias B into the sum
  //   - each rd_valid (N+1) latches a product internally
  //   - add to sum at N+2 (reflected in out)
  // ------------------------------------------------------------
  wire signed [OUTW-1:0] mac_sum;

  mac_pipe #(
    .INW  (INW),
    .OUTW (OUTW)
  ) u_mac (
    .clk        (clk),
    .reset      (reset),
    .input0     (W_data),
    .input1     (X_data),
    .init_value (B),
    .init_acc   (init_acc),
    .input_valid(read_valid),
    .out        (mac_sum)
  );

  // ------------------------------------------------------------
  // Output FIFO (stream out one pixel when last tap is added)
  // ------------------------------------------------------------
  assign fifo_in_data  = mac_sum;
  assign fifo_in_valid = fsm_cs == OUTPUT;       // VALID precisely when sum is complete

  // Assert compute_finished on the last pixel being accepted
  assign compute_finished = pixel_done_and_pushed &&
                            (output_element_cnt == ((R-K+1)*(C-K+1)-1'b1));

  fifo_out #(
    .OUTW  (OUTW),
    .DEPTH (C-1)       // small line-depth FIFO to absorb TREADY backpressure
  ) u_out_fifo (
    .clk            (clk),
    .reset          (reset),
    .IN_AXIS_TDATA  (fifo_in_data),
    .IN_AXIS_TVALID (fifo_in_valid),
    .IN_AXIS_TREADY (fifo_in_ready),
    .OUT_AXIS_TDATA (OUTPUT_TDATA),
    .OUT_AXIS_TVALID(OUTPUT_TVALID),
    .OUT_AXIS_TREADY(OUTPUT_TREADY)
  );

  // ------------------------------------------------------------
  // input_mems: load W(K*K), B, X(R*C); expose read ports
  // ------------------------------------------------------------
  input_mems #(
    .INW (INW),
    .R   (R),
    .C   (C),
    .MAXK(MAXK)
  ) u_inmems (
    .clk            (clk),
    .reset          (reset),
    .AXIS_TDATA     (INPUT_TDATA),
    .AXIS_TVALID    (INPUT_TVALID),
    .AXIS_TUSER     (INPUT_TUSER),
    .AXIS_TREADY    (INPUT_TREADY),
    .inputs_loaded  (inputs_loaded),
    .compute_finished(compute_finished),
    .K              (K),
    .B              (B),
    .X_read_addr    (X_read_addr),
    .X_data         (X_data),
    .W_read_addr    (W_read_addr),
    .W_data         (W_data)
  );

endmodule
