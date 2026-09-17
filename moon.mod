// Learn more about moon.mod configuration:
// https://docs.moonbitlang.com/en/latest/toolchain/moon/module.html
//
// To add a dependency, run this command in your terminal:
//   moon add moonbitlang/x
//
// Or manually declare it in `import`, for example:
// import {
//   "moonbitlang/x@0.4.6",
// }

name = "Ljh684/moonnet-lab"

version = "0.1.0"

readme = "README.mbt.md"

repository = "https://github.com/Ljh684/moonnet-lab"

license = "Apache-2.0"

keywords = [
  "simulation",
  "network",
  "tcp",
  "congestion-control",
  "deterministic",
  "discrete-event",
]

preferred_target = "wasm"

description = "Deterministic packet-level network simulator and TCP congestion-control lab for MoonBit"

import {
  "moonbitlang/x@0.5.5",
}
