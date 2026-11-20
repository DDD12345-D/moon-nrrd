///| Slice external read-back probe (host layer — file IO allowed).
///| Usage: moon run cmd/slice-probe -- <out-dir>
///| Writes: (1) original 3x4x5 double with full 3D space metadata,
///|         (2) slice axis=0 index=1 → 2D 4x5,
///|         (3) slice axis=1 index=2 → 2D 3x5.
///| All as raw-le attached NRRD. Python script reads all with pynrrd
///| and compares actual values, sizes, origin, directions, labels, units.
///| Value formula: value(x,y,z) = 100*x + 10*y + z.
///| Exit codes: 0 = success, 1 = write failure, 2 = usage.

extern "js" fn set_exit_code(code : Int) -> Unit =
  #| (code) => { globalThis.process.exitCode = code }

fn join_path(dir : String, name : String) -> String {
  if dir.is_empty() {
    name
  } else {
    "\{dir}/\{name}"
  }
}

fn write_file(path : String, data : Bytes) -> Unit raise @nrrd.NrrdError {
  try {
    @fs.write_bytes_to_file(path, data)
  } catch {
    _ => raise @nrrd.NrrdError("cannot write file: \{path}")
  }
}

fn main raise {
  let args = @env.args()
  if args.length() < 3 {
    eprintln("usage: slice-probe <out-dir>")
    set_exit_code(2)
    return
  }
  let out_dir = args[2]
  // 3x4x5 double with full 3D space metadata.
  // value(x,y,z) = 100*x + 10*y + z (first-axis-fastest).
  let hdr = @nrrd.NrrdHeader::{ list_filenames: None, data_file_subdim: None,
    dimension: 3,
    sizes: [3, 4, 5],
    type_name: "double",
    encoding: "raw",
    endian: Some("little"),
    data_file: None,
    space: Some("right-anterior-superior"),
    space_dimension: None,
    space_origin: Some([1.5, -2.0, 3.25]),
    space_directions: [
      Some([1.5, 0.5, 0.0]),
      Some([0.0, 2.0, -0.5]),
      Some([0.25, 0.0, 2.5]),
    ],
    space_units: Some(["mm", "mm", "mm"]),
    labels: Some(["x", "y", "z"]),
    kinds: Some(["domain", "domain", "domain"]),
    content: Some("slice-probe/original"),
    line_skip: 0,
    byte_skip: 0,
  }
  // 60 values: for (x,y,z) in [0,3)x[0,4)x[0,5):
  //   linear_idx = x + 3*y + 12*z  (first-axis-fastest)
  //   value = 100*x + 10*y + z
  let vals = test_values_3d()
  let d = @nrrd.NrrdData::{ header: hdr, values: vals }
  // Write original
  let orig_bytes = @nrrd.assemble_attached(hdr, vals)
  write_file(join_path(out_dir, "slice_orig_att.nrrd"), orig_bytes)
  println("slice-probe/original\tslice_orig_att.nrrd\t-")
  // Slice axis=0 at index=1 → 2D [4,5], origin'=(1.5+1*1.5, -2+1*0.5, 3.25+1*0)=(3,-1.5,3.25)
  let r1 = @nrrd.slice_data(d, 0, 1)
  let b1 = @nrrd.assemble_attached(r1.header, r1.values)
  write_file(join_path(out_dir, "slice_ax0_att.nrrd"), b1)
  println("slice-probe/ax0idx1\tslice_ax0_att.nrrd\t-")
  // Slice axis=1 at index=2 → 2D [3,5], origin'=(1.5, -2+2*2, 3.25+2*(-0.5))=(1.5,2,2.25)
  let r2 = @nrrd.slice_data(d, 1, 2)
  let b2 = @nrrd.assemble_attached(r2.header, r2.values)
  write_file(join_path(out_dir, "slice_ax1_att.nrrd"), b2)
  println("slice-probe/ax1idx2\tslice_ax1_att.nrrd\t-")
  eprintln("slice-probe: wrote slice_orig_att.nrrd + slice_ax0_att.nrrd + slice_ax1_att.nrrd")
}

///| Build 60 values for 3x4x5: value(x,y,z) = 100*x + 10*y + z.
fn test_values_3d() -> Array[Double] {
  let arr = Array::make(60, 0.0)
  for x = 0; x < 3; x = x + 1 {
    for y = 0; y < 4; y = y + 1 {
      for z = 0; z < 5; z = z + 1 {
        let idx = x + 3 * y + 12 * z
        arr[idx] = (100 * x + 10 * y + z).to_double()
      }
    }
  }
  arr
}
