module mac_pipe#(
    parameter INW = 16,
    parameter OUTW = 64
) (
    input signed [INW-1:0]   input0, input1, init_value,
    output logic signed[OUTW-1:0] out,
    input clk, reset, init_acc, input_valid);

logic[2*INW-1:0] pipe;
logic pipe_vld;
always_ff @(posedge clk) begin
    if(reset) begin
        pipe[2*INW-1:0] <= {2*INW{1'b0}};
        pipe_vld <= 1'd0;
    end
    else begin 
        pipe[2*INW-1:0] <= $signed(input0[INW-1:0]) * $signed(input1[INW-1:0]); //use signed multiplication
        pipe_vld <= input_valid;
    end
end
//
//if reset, clear out
//if init, the sign also should be kept
//if input is valid(at the previous cycle), out add it
always_ff @(posedge clk) begin
    if(reset)
        out[OUTW-1:0] <= {OUTW{1'b0}};
    else if(init_acc ==1)
        out[OUTW-1:0] <= {{(OUTW-INW){init_value[INW-1]}},init_value[INW-1:0]};
    else if(pipe_vld ==1)
        out[OUTW-1:0] <= out[OUTW-1:0] +{{(OUTW-2*INW){pipe[2*INW-1]}}, pipe[2*INW-1:0]};
end

endmodule





