module input_mems #(
  parameter INW  = 24,
  parameter R    = 16,
  parameter C    = 17,
  parameter MAXK = 9,
  localparam K_BITS      = $clog2(MAXK+1),
  localparam X_ADDR_BITS = $clog2(R*C),
  localparam W_ADDR_BITS = $clog2(MAXK*MAXK)
)(
  input    clk, reset,
  input [INW-1:0]  AXIS_TDATA,
  input            AXIS_TVALID,
  input [K_BITS:0] AXIS_TUSER,
  output logic     AXIS_TREADY,
  output logic                  inputs_loaded,
  input                         compute_finished,
  output logic [K_BITS-1:0]     K,
  output logic signed [INW-1:0] B,
  input [X_ADDR_BITS-1:0]       X_read_addr,
  output logic signed [INW-1:0] X_data,
  input [W_ADDR_BITS-1:0]       W_read_addr,
  output logic signed [INW-1:0] W_data
);

  // FSM states
  typedef enum logic [2:0] {IDLE, INPUT_W, INPUT_B, INPUT_X, WAIT_COMPUTE} state_t;
  state_t fsm_input_ram_cs, fsm_input_ram_ns;

  // TUSER fields: only meaningful on the first beat of each transaction
  wire new_W = AXIS_TUSER[0];
  wire [K_BITS-1:0] TUSER_K = AXIS_TUSER[K_BITS:1];

  // AXI-Stream handshake
  wire fire = AXIS_TVALID & AXIS_TREADY;

  // Local write counters and total W count = K*K
  logic [W_ADDR_BITS:0] w_cnt;
  logic [X_ADDR_BITS:0] x_cnt;
  logic [W_ADDR_BITS:0] w_total;

  // Muxed addresses and write enables
  logic [W_ADDR_BITS-1:0] W_addr;
  logic [X_ADDR_BITS-1:0] X_addr;
  logic W_wr_en, X_wr_en;

  // During compute phase use read_addr; during load phase use counters
  assign W_addr = inputs_loaded ? W_read_addr : w_cnt;
  assign X_addr = inputs_loaded ? X_read_addr : x_cnt;

  // ------------------------- Memories ------------------------- //
  memory #(.WIDTH(INW), .SIZE(MAXK*MAXK)) wmem (
    .data_in (AXIS_TDATA),
    .data_out(W_data),
    .addr    (W_addr),
    .clk     (clk),
    .wr_en   (W_wr_en)
  );

  memory #(.WIDTH(INW), .SIZE(R*C)) xmem (
    .data_in (AXIS_TDATA),
    .data_out(X_data),
    .addr    (X_addr),
    .clk     (clk),
    .wr_en   (X_wr_en)
  );

  // ------------------- TREADY / inputs_loaded ----------------- //
  // Do not accept new input while waiting for compute to finish.
  always_comb begin
    AXIS_TREADY = (fsm_input_ram_cs != WAIT_COMPUTE);
  end

  // inputs_loaded is high only when we are in the compute-wait state.
  assign inputs_loaded = (fsm_input_ram_cs == WAIT_COMPUTE);

  // --------------------- Next-state logic --------------------- //
  always_comb begin
    fsm_input_ram_ns = fsm_input_ram_cs;

    unique case (fsm_input_ram_cs)
      IDLE: begin
        // First valid beat of a new transaction:
        //   new_W=1 -> start loading W (and then B, X)
        //   new_W=0 -> reuse old W/B and start loading X directly
        if (fire)
          fsm_input_ram_ns = (new_W ? INPUT_W : INPUT_X);
      end

      INPUT_W: begin
        // After receiving exactly K*K W elements, move to B
        if (fire && (w_cnt == w_total-1))
          fsm_input_ram_ns = INPUT_B;
      end

      INPUT_B: begin
        // Single B value
        if (fire)
          fsm_input_ram_ns = INPUT_X;
      end

      INPUT_X: begin
        // After receiving R*C X elements, go to compute phase
        if (fire && (x_cnt == (R*C-1)))
          fsm_input_ram_ns = WAIT_COMPUTE;
      end

      WAIT_COMPUTE: begin
        // Wait for compute_finished, then go back to IDLE.
        // Do NOT look at AXIS here (TREADY is 0).
        if (compute_finished && AXIS_TVALID)
          fsm_input_ram_ns = (new_W ? INPUT_W :INPUT_X);
        else if(compute_finished)
          fsm_input_ram_ns = IDLE;
      end

      default: fsm_input_ram_ns = IDLE;
    endcase
  end

  // --------------------- State register ----------------------- //
  always_ff @(posedge clk or posedge reset) begin
    if (reset)
      fsm_input_ram_cs <= IDLE;
    else
      fsm_input_ram_cs <= fsm_input_ram_ns;
  end

  // -------------------------- K ------------------------------- //
  // Update K only on the first beat of a "new W" transaction.
  // For new_W=0 (reuse), keep the old K.
  always_ff @(posedge clk or posedge reset) begin
    if (reset)
      K <= '0;
    else if ((fsm_input_ram_cs==IDLE || (fsm_input_ram_cs == WAIT_COMPUTE&&compute_finished)) && AXIS_TVALID&& new_W)
      K <= TUSER_K;
  end

  // ------------------------ w_total --------------------------- //
  // Store K*K for the current weights; use TUSER_K from that first beat.
  always_ff @(posedge clk or posedge reset) begin
    if (reset)
      w_total <= '0;
    else if ((fsm_input_ram_cs==IDLE || (fsm_input_ram_cs == WAIT_COMPUTE&& compute_finished)) && AXIS_TVALID && new_W)
      w_total <= TUSER_K * TUSER_K;
  end

  // -------------------------- B ------------------------------- //
  // B is written only when explicitly loading B (new_W=1 path).
  // For reuse (new_W=0), previous B is kept.
  always_ff @(posedge clk or posedge reset) begin
    if (reset)
      B <= '0;
    else if (fsm_input_ram_cs==INPUT_B && fire)
      B <= AXIS_TDATA;
  end

  // --------------------- Write enables ------------------------ //
  // First beat in IDLE:
  //   new_W=1 -> that beat is W[0]
  //   new_W=0 -> that beat is X[0]
  // Subsequent beats use INPUT_W / INPUT_X states as usual.
  assign W_wr_en = fire &&
                   ( (fsm_input_ram_cs == INPUT_W) ||
                     (fsm_input_ram_cs == IDLE && new_W) );

  assign X_wr_en = fire &&
                   ( (fsm_input_ram_cs == INPUT_X) ||
                     (fsm_input_ram_cs == IDLE && !new_W) );

  // ------------------------ W counter ------------------------- //
  // Count only beats that belong to W.
  // If we wrote W[0] in IDLE on (fire && new_W), start w_cnt at 1.
  always_ff @(posedge clk or posedge reset) begin
    if (reset) begin
      w_cnt <= '0;
    end else if (fsm_input_ram_cs == IDLE) begin
      if (fire && new_W)
        w_cnt <= 'd1;     // W[0] already written in this cycle
      else
        w_cnt <= '0;
    end else if (fsm_input_ram_cs != INPUT_W) begin
      w_cnt <= '0;
    end else if (fire) begin
      w_cnt <= w_cnt + 1'b1;
    end
  end

  // ------------------------ X counter ------------------------- //
  // Count only beats that belong to X.
  // If we wrote X[0] in IDLE on (fire && !new_W), start x_cnt at 1.
  always_ff @(posedge clk or posedge reset) begin
    if (reset) begin
      x_cnt <= '0;
    end else if (fsm_input_ram_cs == IDLE) begin
      if (fire && !new_W)
        x_cnt <= 'd1;     // X[0] already written in this cycle
      else
        x_cnt <= '0;
    end else if (fsm_input_ram_cs != INPUT_X) begin
      x_cnt <= '0;
    end else if (fire) begin
      x_cnt <= x_cnt + 1'b1;
    end
  end

endmodule

