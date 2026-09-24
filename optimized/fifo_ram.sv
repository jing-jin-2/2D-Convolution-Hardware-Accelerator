module fifo_ram #(
    parameter DATA_W             = 16,
    parameter DEPTH              = 16,          // number of entries
    // threshold values are in units of "number of elements currently stored"
    // almost_full  = (count >= ALMOST_FULL_THRESH)
    // almost_empty = (count <= ALMOST_EMPTY_THRESH)
    parameter ALMOST_FULL_THRESH  = DEPTH-2,
    parameter ALMOST_EMPTY_THRESH = 2
)(
    input  logic                 clk,
    input  logic                 reset,

    // write side
    input  logic                 wr_en,
    input  logic [DATA_W-1:0]    din,
    output logic                 full,
    output logic                 almost_full,

    // read side
    input  logic                 rd_en,
    output logic [DATA_W-1:0]    dout,
    output logic                 empty,
    output logic                 almost_empty
);

    // ------------------------------------------------------------
    // Local parameters / types
    // ------------------------------------------------------------
    localparam ADDR_W = $clog2(DEPTH);  // quick & safe addr width

    // memory
    logic [DATA_W-1:0] mem [0:DEPTH-1];

    // pointers & count
    logic [ADDR_W-1:0] wr_ptr;
    logic [ADDR_W-1:0] rd_ptr_cur;
    wire  [ADDR_W-1:0] rd_ptr;
    wire  [ADDR_W-1:0] rd_ptr_nxt;
    logic [ADDR_W:0]   count;  // can represent 0..DEPTH

    // ------------------------------------------------------------
    // Write logic
    // ------------------------------------------------------------
    wire do_write = wr_en && !full;

    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            wr_ptr <= '0;
        end else if (do_write) begin
            // mem[wr_ptr] <= din;
            if (wr_ptr == DEPTH-1)
                wr_ptr <= '0;
            else
                wr_ptr <= wr_ptr + 1'b1;
        end
    end

    // ------------------------------------------------------------
    // Read logic
    // ------------------------------------------------------------
    wire do_read = rd_en && !empty;

    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            rd_ptr_cur <= '0;
        end else if (do_read) begin
            if (rd_ptr_cur == DEPTH-1)
                rd_ptr_cur <= '0;
            else
                rd_ptr_cur <= rd_ptr_cur + 1'b1;
        end
    end
    assign rd_ptr_nxt = ( rd_ptr_cur== (DEPTH-1)) ? '0: (rd_ptr_cur + 1'b1);
    assign rd_ptr = do_read ? rd_ptr_nxt : rd_ptr_cur;

    // ------------------------------------------------------------
    // Memory logic
    // ------------------------------------------------------------
memory_dual_port #(
    .WIDTH(DATA_W),
    .SIZE(DEPTH)
) u_mem_fifo (
    .data_in(din),
    .data_out(dout),
    .write_addr(wr_ptr),
    .read_addr(rd_ptr),
    .clk(clk),
    .wr_en(do_write)    
);

    // ------------------------------------------------------------
    // Count / status flags
    // ------------------------------------------------------------
    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            count <= '0;
        end else begin
            case ({do_write, do_read})
                2'b10: count <= count + 1'b1;    // write only
                2'b01: count <= count - 1'b1;    // read only
                2'b11: count <= count;    // read only
                default: /* 00 or 11 */ ;        // no change
            endcase
        end
    end

    // full / empty
    always_comb begin
        full         = (count == DEPTH);
        empty        = (count == 0);
        almost_full  = (count >= ALMOST_FULL_THRESH);
        almost_empty = (count <= ALMOST_EMPTY_THRESH);
    end
    
// ==============================
// 1) underflow
// ==============================
property p_no_read_when_empty;
  @(posedge clk) disable iff (reset)
    !(rd_en && empty);   // 
endproperty

a_no_read_when_empty: assert property (p_no_read_when_empty)
  else $error("FIFO underflow: read when EMPTY at time %0t", $time);

// ==============================
// overflow
// ==============================
property p_no_write_when_full;
  @(posedge clk) disable iff (reset)
    !(wr_en && full);    // 
endproperty

a_no_write_when_full: assert property (p_no_write_when_full)
  else $error("FIFO overflow: write when FULL at time %0t", $time);
endmodule
