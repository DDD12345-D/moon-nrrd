///| Write-side evidence generator (host layer — this program MAY do
///| file IO; the core library never does).
///| Usage: moon run cmd/write-probe -- <out-dir>
///| Emits the 48-cell write matrix (8 types x {raw-le, raw-be, ascii}
///| x {attached, detached}) using @moon-nrrd.assemble_attached /
///| assemble_detached, i.e. every byte comes out of the library's
///| write path. File names follow tests/gen_fixtures.py conventions:
///|   attached  <type>_<enc>_att.nrrd
///|   detached  <type>_<enc>_det.nhdr + <type>_<enc>_det.{raw|txt}
///| Values mirror tests/gen_fixtures.py TYPES (checked against the
///| Python expectations independently in tests/check_write_reference.py).
///| CLI contract (same as the read probe): diagnostics on stderr,
///| exit 0 = all cells written, 1 = at least one failure, 2 = usage.

///|
extern "js" fn set_exit_code(code : Int) -> Unit =
  #| (code) => { globalThis.process.exitCode = code }

///| Value set per canonical type — synced with tests/gen_fixtures.py
///| TYPES and write_roundtrip_test.mbt (drift fails the external
///| comparison loudly).
fn values_for(t : String) -> Array[Double] {
  match t {
    "int8" => [-128.0, -100.0, -1.0, 0.0, 1.0, 64.0, 100.0, 127.0]
    "uint8" => [0.0, 1.0, 2.0, 64.0, 127.0, 128.0, 200.0, 255.0]
    "int16" => [-32768.0, -12345.0, -1.0, 0.0, 1.0, 256.0, 12345.0, 32767.0]
    "uint16" => [0.0, 1.0, 255.0, 256.0, 32767.0, 32768.0, 12345.0, 65535.0]
    "int32" => [-2147483648.0, -1000000000.0, -1.0, 0.0, 1.0, 65536.0, 1000000000.0, 2147483647.0]
    "uint32" => [
      0.0, 1.0, 65536.0, 2147483647.0, 2147483648.0, 3000000000.0, 4000000000.0, 4294967295.0,
    ]
    "float" => [
      0.0, -0.0, 1.0, -1.5, 0.1, 16777216.0, 3.4028234663852886e38,
      1.1754943508222875e-38, 1.401298464324817e-45, @double.not_a_number, @double.infinity,
      @double.neg_infinity,
    ]
    _ => [
      0.0, -0.0, 0.1, -1.5, -12345.6789, 16777217.0, 1.7976931348623157e308,
      2.2250738585072014e-308, 5.0e-324, @double.not_a_number, @double.infinity,
      @double.neg_infinity,
    ]
  }
}

///|
fn join_path(dir : String, name : String) -> String {
  if dir.is_empty() {
    name
  } else {
    "\{dir}/\{name}"
  }
}

///| Header factory for one grid cell.
fn cell_header(
  t : String,
  e : String,
  endian : String?,
  n : Int,
  data_file : String?,
  content : String,
) -> @nrrd.NrrdHeader {
  @nrrd.NrrdHeader::{
    dimension: 1,
    sizes: [n],
    type_name: t,
    encoding: e,
    endian: endian,
    data_file: data_file,
    space: None,
    space_dimension: None,
    space_origin: None,
    space_directions: [],
    space_units: None,
    labels: None,
    kinds: None,
    content: Some(content),
    line_skip: 0,
    byte_skip: 0,
  }
}

///| IO wrapper: file errors surface as NrrdError (single raise type).
fn write_file(path : String, data : Bytes) -> Unit raise @nrrd.NrrdError {
  try {
    @fs.write_bytes_to_file(path, data)
  } catch {
    _ => raise @nrrd.NrrdError("cannot write file: \{path}")
  }
}

///| Write one cell; raises @nrrd.NrrdError on failure.
fn write_cell(out_dir : String, t : String, enc_id : String, att : Bool) -> Unit raise @nrrd.NrrdError {
  let (e, endian, ext) = match enc_id {
    "raw-le" => ("raw", Some("little"), "raw")
    "raw-be" => ("raw", Some("big"), "raw")
    _ => ("ascii", None, "txt")
  }
  let vs = values_for(t)
  let n = vs.length()
  let combo = "\{t}/\{enc_id}/\{if att { "att" } else { "det" }}"
  let stem = "\{t}_\{enc_id.replace_all(old = "-", new = "")}_\{if att { "att" } else { "det" }}"
  if att {
    let h = cell_header(t, e, endian, n, None, combo)
    let full = @nrrd.assemble_attached(h, vs)
    write_file(join_path(out_dir, "\{stem}.nrrd"), full)
    println("\{combo}\t\{stem}.nrrd\t-")
  } else {
    let data_name = "\{stem}.\{ext}"
    let h = cell_header(t, e, endian, n, Some(data_name), combo)
    let (head, payload) = @nrrd.assemble_detached(h, vs)
    write_file(join_path(out_dir, "\{stem}.nhdr"), head)
    write_file(join_path(out_dir, data_name), payload)
    println("\{combo}\t\{stem}.nhdr\t\{data_name}")
  }
}

///| Extra sample 1 (multi-dim index order): 2x3x2 int16 raw-le
///| attached. File order is sizes[0] fastest, so position
///| i + 2*j + 6*k must hold value 100*i + 10*j + k. The external
///| check reads it with pynrrd and compares data[i,j,k] directly —
///| a 1-D self round-trip cannot catch an axis-order mistake.
fn write_multi_sample(out_dir : String) -> Unit raise @nrrd.NrrdError {
  let vs = [
    0.0, 100.0, 10.0, 110.0, 20.0, 120.0, // k=0
    1.0, 101.0, 11.0, 111.0, 21.0, 121.0, // k=1
  ]
  let h = @nrrd.NrrdHeader::{
    dimension: 3,
    sizes: [2, 3, 2],
    type_name: "int16",
    encoding: "raw",
    endian: Some("little"),
    data_file: None,
    space: None,
    space_dimension: None,
    space_origin: None,
    space_directions: [],
    space_units: None,
    labels: None,
    kinds: None,
    content: Some("extra/multi2x3x2"),
    line_skip: 0,
    byte_skip: 0,
  }
  let full = @nrrd.assemble_attached(h, vs)
  write_file(join_path(out_dir, "multi2x3x2_att.nrrd"), full)
  println("extra/multi2x3x2\tmulti2x3x2_att.nrrd\t-")
}

///| Extra sample 2 (spatial metadata external read): 2x3 double
///| raw-le detached in a named 3-D space with labels / space origin
///| / space directions / space units / kinds. Array dimension (2)
///| deliberately differs from space dimension (3) so per-axis and
///| per-space counts cannot mask each other.
fn write_spatial_sample(out_dir : String) -> Unit raise @nrrd.NrrdError {
  let vs = [0.0, -0.0, 1.0, -1.5, 0.1, 2.5]
  let h = @nrrd.NrrdHeader::{
    dimension: 2,
    sizes: [2, 3],
    type_name: "double",
    encoding: "raw",
    endian: Some("little"),
    data_file: Some("spatial_meta_det.raw"),
    space: Some("right-anterior-superior"),
    space_dimension: None,
    space_origin: Some([1.5, 0.0, -2.0]),
    space_directions: [Some([1.5, 0.0, 0.0]), Some([0.0, 1.5, 0.0])],
    space_units: Some(["mm", "mm", "mm"]),
    labels: Some(["row", "col"]),
    kinds: Some(["domain", "domain"]),
    content: Some("extra/spatial-meta"),
    line_skip: 0,
    byte_skip: 0,
  }
  let (head, payload) = @nrrd.assemble_detached(h, vs)
  write_file(join_path(out_dir, "spatial_meta_det.nhdr"), head)
  write_file(join_path(out_dir, "spatial_meta_det.raw"), payload)
  println("extra/spatial-meta\tspatial_meta_det.nhdr\tspatial_meta_det.raw")
}

///|
fn main {
  let args = @env.args()
  if args.length() < 3 {
    eprintln("usage: write-probe <out-dir>")
    set_exit_code(2)
    return
  }
  let out_dir = args[2]
  let types = [
    "int8", "uint8", "int16", "uint16", "int32", "uint32", "float", "double",
  ]
  let enc_ids = ["raw-le", "raw-be", "ascii"]
  let mut any_failed = false
  let mut written = 0
  for t in types {
    for enc_id in enc_ids {
      for att in [true, false] {
        try {
          write_cell(out_dir, t, enc_id, att)
          written = written + 1
        } catch {
          err => {
            let msg = match err {
              @nrrd.NrrdError(m) => m
            }
            eprintln("error: \{t}/\{enc_id}/\{if att { "att" } else { "det" }}: \{msg}")
            any_failed = true
          }
        }
      }
    }
  }
  eprintln("write-probe: \{written}/48 cells written")
  let mut extras = 0
  try {
    write_multi_sample(out_dir)
    extras = extras + 1
  } catch {
    err => {
      let msg = match err {
        @nrrd.NrrdError(m) => m
      }
      eprintln("error: multi2x3x2 sample: \{msg}")
      any_failed = true
    }
  }
  try {
    write_spatial_sample(out_dir)
    extras = extras + 1
  } catch {
    err => {
      let msg = match err {
        @nrrd.NrrdError(m) => m
      }
      eprintln("error: spatial-meta sample: \{msg}")
      any_failed = true
    }
  }
  eprintln("write-probe: \{extras}/2 extra samples written")
  if any_failed {
    set_exit_code(1)
  }
}
