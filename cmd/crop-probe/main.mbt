///| Crop external read-back probe (host layer — file IO allowed).
///| Usage: moon run cmd/crop-probe -- <out-dir>
///| Writes: (1) original 2x3x2 int16 with 3D space metadata,
///|         (2) cropped result after crop_data(start=(1,1,0), size=(1,2,2)).
///| Both as raw-le attached NRRD. Python script reads both with pynrrd
///| and verifies values, sizes, and space fields.
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
    eprintln("usage: crop-probe <out-dir>")
    set_exit_code(2)
    return
  }
  let out_dir = args[2]
  // 2x3x2 int16 with full 3D space metadata.
  // value(x,y,z) = 100*x + 10*y + z (first-axis-fastest linear order).
  let hdr = @nrrd.NrrdHeader::{
    dimension: 3,
    sizes: [2, 3, 2],
    type_name: "int16",
    encoding: "raw",
    endian: Some("little"),
    data_file: None,
    space: Some("right-anterior-superior"),
    space_dimension: None,
    space_origin: Some([10.0, -5.0, 2.5]),
    space_directions: [
      Some([1.5, 0.0, 0.0]),
      Some([0.0, 2.0, 0.0]),
      Some([0.0, 0.0, 2.5]),
    ],
    space_units: Some(["mm", "mm", "mm"]),
    labels: Some(["x", "y", "z"]),
    kinds: Some(["domain", "domain", "domain"]),
    content: Some("crop-probe/original"),
    line_skip: 0,
    byte_skip: 0,
  }
  // 12 values: for (x,y,z) in [0,2)x[0,3)x[0,2):
  //   linear_idx = x + 2*y + 6*z  (first-axis-fastest)
  //   value = 100*x + 10*y + z
  let vals = [
    0.0, 100.0, 10.0, 110.0, 20.0, 120.0, // z=0
    1.0, 101.0, 11.0, 111.0, 21.0, 121.0, // z=1
  ]
  let d = @nrrd.NrrdData::{ header: hdr, values: vals }
  // Write original
  let orig_bytes = @nrrd.assemble_attached(hdr, vals)
  write_file(join_path(out_dir, "crop_orig_att.nrrd"), orig_bytes)
  println("crop-probe/original\tcrop_orig_att.nrrd\t-")
  // Crop: start=(1,1,0), size=(1,2,2)
  //   output sizes = (1,2,2), 4 elements
  //   output(x',y',z') = input(x'+1, y'+1, z'+0)
  //   values: (1,1,0)=110, (1,2,0)=120, (1,1,1)=111, (1,2,1)=121
  //   origin' = (10,-5,2.5) + 1*(1.5,0,0) + 1*(0,2,0) = (11.5,-3,2.5)
  let start = [1, 1, 0]
  let crop_sz = [1, 2, 2]
  let result = @nrrd.crop_data(d, start, crop_sz)
  // Write cropped result
  let crop_hdr = result.header
  let crop_vals = result.values
  let crop_bytes = @nrrd.assemble_attached(crop_hdr, crop_vals)
  write_file(join_path(out_dir, "crop_out_att.nrrd"), crop_bytes)
  println("crop-probe/cropped\tcrop_out_att.nrrd\t-")
  eprintln("crop-probe: wrote crop_orig_att.nrrd + crop_out_att.nrrd")
}
