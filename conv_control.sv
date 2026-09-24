module conv_control #(
  parameter INW   = 18,
  parameter R     = 8,
  parameter C     = 8,
  parameter MAXK  = 5,
  // Safe output width: product(2*INW) + log2(K*K) + 1 guard bit
  localparam OUTW  = $clog2(MAXK*MAXK*(128'd1 << 2*INW-2) + (1<<(INW-1)))+1,
  localparam  K_BITS = $clog2(MAXK+1)
)(
  input  logic                 clk,
  input  logic                 reset,

  // AXIS input (weights, bias, inputs) — forwarded into input_mems
  input  logic [K_BITS-1:0]       K_input,
  input  logic [INW-1:0]       B_input,
  input  logic [INW-1:0]       INPUT_TDATA,
  input  logic                 INPUT_TVALID,

  output logic                 INPUT_TREADY,

output logic W_read_en,
output logic [$clog2(MAXK*MAXK)-1:0] W_read_addr,
  input logic [INW-1:0]      W_read_data,
  // AXIS output (results)
  output logic [OUTW-1:0]      OUTPUT_TDATA,
  output logic                 OUTPUT_TVALID,
  input  logic                 OUTPUT_TREADY,
  input  logic                 OUTPUT_ALMOST_FULL// to judge whether fifo is almost full
);

  // ------------------------------------------------------------
  // Derived widths
  // ------------------------------------------------------------

  localparam  W_ADDR_BITS     = $clog2(MAXK*MAXK);
  localparam  OUT_ROW_BITS    = $clog2(R);
  localparam  OUT_COL_BITS    = $clog2(C);
  localparam  REG_ARRAY_CNT = MAXK*C;  // number of registers in line buffer array
  localparam  LOG2_REG_ARRAY_CNT = MAXK*C;  // number of registers in line buffer array
  localparam FIFO_USE_ALMOST_FULL = 0; // set to 1 to use almost_full signal for backpressure


// ------------------------------------------------------------
  // INPUT
  // ------------------------------------------------------------
logic INPUT_TSOP; //start of packet signal for input stream
// ------------------------------------------------------------
  // FSM
  // ------------------------------------------------------------
  typedef enum logic [1:0] {S_IDLE, S_READ_WINDOW, S_CALCULATE, S_READ_NEW_LINE} state_t;
  state_t fsm_cs, fsm_ns;

  // ------------------------------------------------------------
  // read input matrix (row-major): (oi,oj) over (R-K+1) x (C-K+1)
  // ------------------------------------------------------------
  logic [OUT_ROW_BITS-1:0] ix;
  logic [OUT_COL_BITS-1:0] iy;

// ------------------------------------------------------------
// line buffers declaration 
// ------------------------------------------------------------
logic signed [INW-1:0] line_buf [MAXK-1:0][C-1:0];
logic signed [INW-1:0]  mul_input_win[MAXK-1:0][MAXK-1:0];
logic signed [2*INW-1:0] prod_reg [MAXK-1:0][MAXK-1:0];
logic signed [INW-1:0]   weight[MAXK-1:0][MAXK-1:0];
logic signed [INW-1:0]   weight_ff[MAXK-1:0][MAXK-1:0];
logic [C-1:0] K_row_data_vld_bitmap;
logic signed[INW-1:0]  B; 
logic [K_BITS-1:0] K;
logic [$clog2(MAXK*MAXK)-1:0] W_read_data_cnt;
logic [$clog2(MAXK)-1:0] W_array_row;
logic [$clog2(MAXK)-1:0] W_array_col;
 // ------------------------------------------------------------
  // Tap counter & (u,v) mapping  (0..K*K-1) -> (u = /K, v = %K)
  // ------------------------------------------------------------
  // logic [W_ADDR_BITS-1:0] W_rd_cnt;   // issues addresses 0..K*K-1
  logic weight_loaded;
  logic W_read_data_valid;
  wire K_input_in_new_row_ready;
   // ============================================================
  // multiply control signals
  // ============================================================
  logic [OUT_COL_BITS-1:0] mul_cnt;                       // Multiplication counter
  wire mul_en;                                 // valid when there is a multiplication being doing in this cycle
  logic mul_valid;                                 // valid when there is a multiplication being doing in this cycle
    logic signed [OUTW-1:0] sum_tmp;           // Temporary sum accumulator
    // ============================================================
    // window control signals
    // ============================================================
      wire first_window_ready; //first time when the window is ready
      logic first_window_loaded; //after first time when the window is ready and waiting for calculation starts
      wire first_window_load; //all time when the window is ready and haven't been used for calculation
  wire last_output_in_row; //when this is the last element in the output row
  wire last_input_pixel; //signaling for last input pixel

  // --- window computation signals (used in product calculation block)
  logic [OUT_ROW_BITS:0] base_row;
  logic [OUT_COL_BITS:0] base_col;

  // --- read line buffer signals   
  wire[OUT_ROW_BITS-1:0] read_line_buf_row_slot;
  //============================================================
  //FSM sequential logic
    //============================================================
assign first_window_ready = (iy == K-1 && ix == K-1) && INPUT_TVALID && INPUT_TREADY;        // 2C+K consumed
always_ff @(posedge clk or posedge reset) begin
    if (reset) begin
        first_window_loaded <= 1'b0;
    end
    else if(fsm_cs != S_CALCULATE && fsm_ns == S_CALCULATE) begin
        first_window_loaded <= 1'b0;
    end
    else if (first_window_ready)begin
        first_window_loaded <= 1'b1;
    end
end
assign first_window_load = first_window_loaded || first_window_ready;
  assign K_input_in_new_row_ready = (iy == K-1 ) && INPUT_TVALID && INPUT_TREADY;        // 2C+K consumed
  assign last_output_in_row = (base_col == C-1) && mul_en;    //the multiply colomn goes the the last one and multiply enables               
  assign last_input_pixel   = (base_row == R-1 && base_col == C-1);      // finished all R×C inputs

  always_comb begin
        fsm_ns = fsm_cs;
        unique case (fsm_cs)
            S_IDLE: begin
                if (INPUT_TVALID)
                    fsm_ns = S_READ_WINDOW  ;
            end

            S_READ_WINDOW: begin
                // Keep reading until the first K×K window is ready
                if (first_window_load && weight_loaded)
                    fsm_ns = S_CALCULATE;
            end

            S_CALCULATE: begin
                // When we have produced all outputs of current row
                // go to JUDGE
                if (last_output_in_row)
                    if (last_input_pixel)
                        fsm_ns = S_IDLE;
                    else
                        fsm_ns = S_READ_NEW_LINE;
                    // fsm_ns = S_JUDGE;
            end

            S_READ_NEW_LINE: begin
                // Read first K inputs in a new row,
                // when iy reaches K rows depth again, go back to CALCULATE.
                // Simplified condition: when ix == K-1 (first K columns of new row)
                if (K_input_in_new_row_ready) 
                    fsm_ns = S_CALCULATE;
            end

            default: fsm_ns = S_IDLE;
        endcase
    end
  always_ff @(posedge clk or posedge reset) begin
    if (reset) 
      fsm_cs <= S_IDLE;
    else       
      fsm_cs <= fsm_ns;
  end
// ------------------------------------------------------------
  // loading inputs logic
  // ------------------------------------------------------------
  assign INPUT_TREADY = (fsm_cs == S_READ_NEW_LINE || fsm_cs == S_READ_WINDOW  || (fsm_cs == S_CALCULATE&& iy>=K-1)); //condition to read input data, for S_cALCULATE, only read when iy>=K-1 because the iy may go back to 0 after reading C columns
  always_ff @(posedge clk or posedge reset) begin
    if (reset) begin
        INPUT_TSOP <= 1'b1;
    end
    else if(INPUT_TREADY && INPUT_TVALID) begin
        if (ix == R-1 && iy == C-1) begin
            INPUT_TSOP <= 1'b1;
        end
        else begin
            INPUT_TSOP <= 1'b0;
        end
    end
  end
always_ff @(posedge clk or posedge reset) begin
  if(reset)  begin
    B<= '0;
    K<= MAXK;
  end
  else if(INPUT_TVALID && INPUT_TREADY && INPUT_TSOP) begin
    B<= B_input;
    K<= K_input;
  end
end

always_ff @(posedge clk or posedge reset) begin
    if (reset) begin
      W_read_en <= '0;
    end 
    else if (W_read_en && W_read_addr == (K*K-1)) begin
      W_read_en <= '0;
    end 
    else if (INPUT_TSOP && INPUT_TREADY && ~weight_loaded) begin
      W_read_en <= '1;
    end
  end

  always_ff @(posedge clk or posedge reset) begin
    if (reset) begin
      W_read_data_valid <= '0;
    end 
    else 
      W_read_data_valid <= W_read_en;
  end
  always_ff @(posedge clk or posedge reset) begin
    if (reset) begin
      W_read_data_cnt <= '0;
    end 
    else if(W_read_data_valid)
      W_read_data_cnt <= (W_read_data_cnt == K*K-1)? '0 :  W_read_data_cnt + 1'b1;
  end

assign W_array_row = W_read_data_cnt / K;
assign W_array_col = W_read_data_cnt % K;
always_ff @(posedge clk or posedge reset) begin
  if(reset) begin
    for(int i=0;i<MAXK;i=i+1) 
      for(int j=0;j<MAXK;j=j+1) 
        weight[i][j] <= '0;
      end
  else if (W_read_data_valid) begin
        weight[W_array_row][W_array_col] <= W_read_data;
      end
end

always_ff @(posedge clk or posedge reset) begin
    if (reset) begin
      W_read_addr <= '0;
    end else if (W_read_en) begin
      if (W_read_addr == (K*K-1)) 
        W_read_addr <= '0;
      else                    
        W_read_addr <=W_read_addr + 1'b1;
    end
  end
always_ff @(posedge clk or posedge reset) begin
    if (reset) begin
        weight_loaded <= 1'b0;
    end
    else if(fsm_cs != S_IDLE && fsm_ns == S_IDLE) begin
        weight_loaded <= 1'b0;
    end
    else if (W_read_en && W_read_addr == (K*K-1))begin
        weight_loaded <= 1'b1;
    end
end
// ------------------------------------------------------------
  // write line buf
  // ------------------------------------------------------------
  assign read_line_buf_row_slot = ix % K; // current row in line buffer to write
  always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            ix       <= '0;
            iy       <= '0;

            for (int r = 0; r < MAXK; r++)
                for (int c = 0; c < C; c++)
                    line_buf[r][c] <= '0;
        end
        else begin
            // reset indices when entering from IDLE
            if ((fsm_cs != S_IDLE) && (fsm_ns == S_IDLE)) begin
                ix       <= '0;
                iy       <= '0;
            end
            else if (INPUT_TVALID && INPUT_TREADY) begin
                // Accept weight pixel and write into line buffer
                line_buf[read_line_buf_row_slot][iy] <= INPUT_TDATA;

                // Advance (ix, iy) in row-major order
                if (iy == C-1) begin
                    iy <= '0;
                    if (ix == R-1) 
                        ix <= '0;     
                    else
                        ix <= ix + 1'b1;
                end
                else begin
                    iy <= iy + 1'b1;
                end
            end
        end
    end
      always_ff @(posedge clk or posedge reset) begin
    if(reset)
      K_row_data_vld_bitmap[C-1:0] <= '0;
    else if((fsm_cs == S_CALCULATE) && (fsm_ns != S_CALCULATE)) 
      K_row_data_vld_bitmap[C-1:0] <= '0;
    else if(INPUT_TREADY && INPUT_TVALID && (ix>= K-1))
      K_row_data_vld_bitmap[iy] <= 1'b1;
  end
// always_ff @(posedge clk or posedge reset) begin
//   if (reset) begin
//       for (int r = 0; r < MAXK; r++)
//           for (int c = 0; c < MAXK; c++)
//               mul_input_win[r][c] <= '0;
//     win_base_row <= '0;
//     win_base_col <= '0;
//     // global_row <= '0;
//     // row_slot <= '0;
//     // global_col <= '0;
//   end
//   else if ((fsm_cs == S_IDLE ) && (fsm_ns != S_IDLE)) begin
//     win_base_row <= K-1;
//     win_base_col <= K-1;
//   end
//   else if ((fsm_cs == S_CALCULATE ) && (fsm_ns != S_CALCULATE)) begin
//     win_base_row <= win_base_row + 1'b1;
//     win_base_col <= K-1;
//   end
//   else if(INPUT_TVALID && INPUT_TREADY && ix>=K-1 && iy>=K-1) begin
//       // Window bottom-right corner is at current (iy, ix)
//          win_base_col <= (win_base_col + 1'b1);
//       for (int kr = 0; kr < MAXK; kr++) begin
//           // global_row <= win_base_row - (K-1-kr);
//           // row_slot   <= global_row % K;
//           for (int kc = 0; kc < MAXK; kc++) begin
//               // global_col <= win_base_col - (K-1-kc);
//               mul_input_win[kr][kc] <=
//                   line_buf[((win_base_row - (K-1-kr))%K)][win_base_col - (K-1-kc)];
//                   if(kr == K-1 && kc == K-1)
//                     mul_input_win[kr][kc] <= INPUT_TDATA; 
//             // $display("[%0t] kr=%0d kc=%0d base_col=%d line_buf_row=%d line_buf_col=%d to in=%0d  w=%0d  prod=%0d",
//             //  $time,
//             //  kr, kc, base_col,(base_row - (K-1-kr))%K, base_col - (K-1-kc),
//             //  $signed(line_buf[(base_row - (K-1-kr))%K][base_col - (K-1-kc)]),
//             //  $signed(weight[kr*K + kc]),
//             //  $signed(line_buf[(base_row - (K-1-kr))%K][base_col - (K-1-kc)]) *
//             //  $signed(weight[kr*K + kc]));
//           end
//       end
//   end
// end
//the above is the original version
//------------------------multiply(fix timing version)--------------------//
//the following is to fix timing 
// line_buf ----> mul_input_win; weight ----->weight_ff
// multiply
always_ff @(posedge clk or posedge reset) begin
  if (reset) begin
      for (int r = 0; r < MAXK; r++)
          for (int c = 0; c < MAXK; c++) begin
              mul_input_win[r][c] <= '0;
              weight_ff[r][c] <= '0;
          end
    base_row <= '0;
    base_col <= '0;
    // global_row <= '0;
    // row_slot <= '0;
    // global_col <= '0;
  end
  else if ((fsm_cs == S_READ_WINDOW ) && (fsm_ns == S_CALCULATE)) begin
    base_row <= K-1;
    base_col <= K-1;
  end
  else if ((fsm_cs != S_CALCULATE ) && (fsm_ns == S_CALCULATE)) begin
    base_row <= base_row + 1'b1;
    base_col <= K-1;
  end
  else if (mul_en) begin
      // Window bottom-right corner is at current (iy, ix)
      //the position of the input matrix
      base_col <= (base_col == C-1) ? base_col :(base_col + 1'b1);
      for (int kr = 0; kr < MAXK; kr++) begin
          // global_row <= base_row - (K-1-kr);
          // row_slot   <= global_row % K;
          for (int kc = 0; kc < MAXK; kc++) begin
              // global_col <= base_col - (K-1-kc);
            if(kr < K && kc < K) begin
            //   prod_reg[kr][kc] <=
            //       ($signed(line_buf[(base_row - (K-1-kr))%K][base_col - (K-1-kc)]) *
            //   $signed(weight[kr*K + kc]));
            mul_input_win[kr][kc] <=
                  line_buf[((base_row - (K-1-kr))%K)][base_col - (K-1-kc)];
            weight_ff[kr][kc]<= weight[kr][kc];
            end
            else begin
              mul_input_win[kr][kc] <= '0;
              weight_ff[kr][kc]<= '0;
            end
          end
      end
  end
end
always_ff @(posedge clk or posedge reset) begin
  if (reset) begin
      for (int r = 0; r < MAXK; r++)
          for (int c = 0; c < MAXK; c++) begin
              prod_reg[r][c] <= '0;
          end
  end
  else if(mul_valid) begin
      for (int kr = 0; kr < MAXK; kr++) begin
          for (int kc = 0; kc < MAXK; kc++) begin
              // if(kr < K && kc < K)
              prod_reg[kr][kc] <=
                  ($signed(mul_input_win[kr][kc]) *
              $signed(weight_ff[kr][kc]));
          end
      end
  end
end
// ============================================================
  assign mul_en = (fsm_cs == S_CALCULATE )&& K_row_data_vld_bitmap[base_col]&& ~OUTPUT_ALMOST_FULL;
always_ff @(posedge clk or posedge reset) begin
    if (reset) begin
        mul_valid <= 1'b0;
    end
    else begin
        mul_valid <= mul_en;
    end
end
always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            mul_cnt <= '0;
        end
        else begin
          case({mul_valid, OUTPUT_TREADY && OUTPUT_TVALID})
            2'b01: begin
                mul_cnt <= mul_cnt-1'b1;
            end
            2'b10: begin
                mul_cnt <= mul_cnt + 1'b1;
            end
            2'b11: begin
                mul_cnt <= mul_cnt;
            end
            default: begin
                mul_cnt <= mul_cnt;
            end
          endcase
        end
    end
    // Sum all K×K products into sum_reg (simple linear adder here)
    always_comb begin
        sum_tmp = '0;
        if ((|mul_cnt) && OUTPUT_TVALID) begin
            sum_tmp = B;
            for (int r = 0; r < MAXK; r++)
                for (int c = 0; c < MAXK; c++)
                    if (r < K && c < K)
                      sum_tmp += $signed(prod_reg[r][c]);
        end
    end

// ------------------------------------------------------------
  // output logic
  // ------------------------------------------------------------
  assign OUTPUT_TDATA  = sum_tmp;
  assign OUTPUT_TVALID = (|mul_cnt) ;
endmodule
