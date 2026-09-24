# 2D Convolution Hardware Accelerator

SystemVerilog implementations of a 2D convolution accelerator, developed for **ESE 507: Advanced Digital System Design and Generation, Fall 2025** at Stony Brook University.

The project compares a serial baseline architecture with a speed-optimized architecture that uses streaming input buffering, line-buffer data reuse, and parallel arithmetic. The goal is to explore the trade-offs among latency, throughput, area, and power.

## Repository Organization

| Path | Contents |
| --- | --- |
| `baseline/` | Baseline SystemVerilog source files |
| `baseline/syn/` | Baseline synthesis reports and associated run settings |
| `optimized/` | Optimized SystemVerilog source files |
| `optimized/syn/` | Optimized synthesis reports and associated run settings |
| `docs/` | Project report and supporting documentation |

This is the intended layout; synthesis reports and baseline sources can be added as they become available.

## Computation

The accelerator processes an input feature map of size `R x C`, a kernel of size `K x K`, and a bias. For stride-one valid convolution, the output dimensions are:

```text
Output rows    = R - K + 1
Output columns = C - K + 1
```

Each output is formed from the weighted sum of the corresponding input window plus the bias. Input data is received through an AXI-Stream interface, and completed results are buffered by an output FIFO.

## Architectures

### Baseline

The baseline loads the weights, bias, and complete input feature map before starting computation. It reuses a single pipelined multiply-accumulate (MAC) datapath to process the kernel elements sequentially for each output.

- Serial input-loading and computation phases.
- Full input-feature-map storage.
- `K x K` multiply-accumulate operations per output.
- Repeated memory reads for overlapping convolution windows.
- Output FIFO for buffering completed results.

When the existing weights and bias are reused, the input stage only needs to load the new feature map.

### Optimized

The optimized architecture described in the project report improves throughput through:

- **Overlapping input and computation:** separate input handling and convolution control allow later pixels to arrive while earlier data is being processed.
- **FIFO-based input buffering:** decouples the AXI-Stream input from the compute engine.
- **Line-buffer reuse:** retains input rows needed by neighboring convolution windows.
- **Parallel arithmetic:** computes multiple products in parallel to reduce the serial work required per output.

These changes trade additional hardware resources for fewer processing cycles. Their effect on energy depends on workload size, input activity, and implementation settings.

| Aspect | Baseline | Optimized |
| --- | --- | --- |
| Input scheduling | Load first, then compute | Overlap input and computation |
| Input storage | Full feature-map memory | Input FIFO and line buffer |
| Arithmetic | Single reused pipelined MAC | Parallel arithmetic |
| Window access | Repeated memory reads | Reuse buffered rows |
| Design emphasis | Serial reference implementation | Higher throughput |

## Optimized Source Files

The optimized source set is organized around these files:

| File | Role |
| --- | --- |
| `optimized/Conv.sv` | Top-level convolution integration |
| `optimized/conv_control.sv` | Convolution sequencing and compute control |
| `optimized/input_mems.sv` | Input reception and storage/buffering |
| `optimized/fifo_out.sv` | Output FIFO logic |
| `optimized/fifo_ram.sv` | FIFO RAM support |

The architectural descriptions follow the project report. Exact module names, ports, parameters, and dependencies should be checked in the RTL.

## Simulation and Synthesis

Compile each architecture as a **separate source set**: the baseline and optimized implementations may define modules with the same names.

1. Select either `baseline/` or `optimized/`.
2. Add that version's SystemVerilog files and any required dependencies to your tool project.
3. Select the convolution top-level module declared in `Conv.sv`.
4. Configure the input width, image dimensions, and supported kernel size for the experiment.
5. Add a compatible testbench for simulation, or clock/timing constraints and a target technology for synthesis.

Tool-specific commands, testbenches, and synthesis scripts are not documented here yet. The RTL file list alone does not establish a complete reproducible build flow.

## Comparing Results

Store each version's reports in its own `syn/` directory. Useful reports include timing, area or resource utilization, and power estimates. Keep the associated parameter values, tool version, target technology, clock constraints, and activity assumptions with each run.

Compare the two versions under matching conditions using:

- Cycles per image and end-to-end latency.
- Throughput in outputs or images per second.
- Timing slack and achieved clock period.
- Area or hardware resource utilization.
- Power and energy per image.

For matching workloads, latency speedup is `baseline latency / optimized latency`. A higher requested clock frequency alone does not establish higher performance; timing closure and cycle counts also matter.

The project report covers MAC pipelining, the serial convolution architecture, the optimized architecture, and their performance and efficiency trade-offs. Numerical comparison tables can be added here once the corresponding synthesis runs are included.

## Contributors

- **Jing Jin:** RTL implementation and report writing.
- **Xiaoying Li:** Data analysis.

Contributions are listed as described in the project report.
