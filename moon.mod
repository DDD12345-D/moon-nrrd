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

name = "DDD12345-D/moon-nrrd"

version = "0.3.0"

readme = "README.mbt.md"

repository = "https://github.com/DDD12345-D/moon-nrrd.git"

license = "Apache-2.0"

keywords = ["nrrd", "nhdr", "scientific", "imaging", "voxel", "grid", "teem", "parse", "encode"]

preferred_target = "wasm"

description = "Pure MoonBit NRRD read-write library: NRRD0005 header parse, data decode, symmetric serialization (10 numeric types incl. int64/uint64 lossless, raw LE/BE + ASCII, attached/detached/LIST), crop/slice data ops with spatial metadata updates"

import {
  "moonbitlang/x@0.5.7",
}
