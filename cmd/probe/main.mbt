///| G1 minimal NRRD read probe.
///| Usage: moon run cmd/probe -- <fixture-path> [<fixture-path> ...]
///| Prints a canonical description of each fixture (same format as
///| nrrd-research/logs/pynrrd-reads.txt) for diffing against pynrrd.
///| CLI contract (audit item 5): diagnostics go to stderr, normal
///| output to stdout; exit 0 = all fixtures ok, 1 = at least one
///| fixture failed (batch continues to the end), 2 = usage error.

///|
extern "js" fn set_exit_code(code : Int) -> Unit =
  #| (code) => { globalThis.process.exitCode = code }

///|
fn basename(path : String) -> String {
  let mut start = 0
  let mut i = 0
  while i < path.length() {
    let c = path.get_char(i).unwrap()
    if c == '/' || c == '\\' {
      start = i + 1
    }
    i = i + 1
  }
  path[start:].to_owned()
}

///|
fn dirname(path : String) -> String {
  let mut end = 0
  let mut i = 0
  while i < path.length() {
    let c = path.get_char(i).unwrap()
    if c == '/' || c == '\\' {
      end = i
    }
    i = i + 1
  }
  path[:end].to_owned()
}

///|
fn join_path(dir : String, name : String) -> String {
  if dir.is_empty() {
    name
  } else {
    "\{dir}/\{name}"
  }
}

///| Minimal path guard for detached `data file` names (audit item 4).
///| Deliberately strict: accepts only plain relative names made of
///| [A-Za-z0-9._-] and '/' separators with no empty/`..` segments.
///| Absolute paths, drive letters, backslashes, LIST and <stdin>-style
///| pseudo names are all refused here. Symlink resolution and read
///| boundaries are the HOST's responsibility — see the G2 design doc.
fn is_safe_data_file(rel : String) -> Bool {
  if rel.is_empty() {
    return false
  }
  // pseudo names from the NRRD spec are not supported by this probe
  if rel == "LIST" || rel.get_char(0) == Some('<') {
    return false
  }
  let mut seg_start = 0
  let mut i = 0
  while i <= rel.length() {
    let at_end = i == rel.length()
    let c = if at_end { '/' } else { rel.get_char(i).unwrap() }
    if c == '/' {
      let seg = rel[seg_start: i].to_owned()
      if seg.is_empty() || seg == "." || seg == ".." {
        return false
      }
      let mut j = 0
      while j < seg.length() {
        let d = seg.get_char(j).unwrap()
        let ok = (d >= 'a' && d <= 'z') || (d >= 'A' && d <= 'Z') ||
          (d >= '0' && d <= '9') || d == '.' || d == '_' || d == '-'
        if !ok {
          return false
        }
        j = j + 1
      }
      seg_start = i + 1
    }
    i = i + 1
  }
  true
}

///|
fn read_bytes(path : String) -> Bytes raise @nrrd.NrrdError {
  try {
    @fs.read_file_to_bytes(path)
  } catch {
    _ => raise @nrrd.NrrdError("cannot read file: \{path}")
  }
}

///|
fn process_fixture(path : String) -> Unit raise @nrrd.NrrdError {
  let raw = read_bytes(path)
  let (header_bytes, body_bytes) = @nrrd.split_header_body(raw)
  let h = @nrrd.parse_header(@nrrd.bytes_to_ascii(header_bytes))
  let data_bytes = match h.data_file {
    Some(rel) => {
      if !is_safe_data_file(rel) {
        raise @nrrd.NrrdError("detached data file path refused: \{rel}")
      }
      read_bytes(join_path(dirname(path), rel))
    }
    None => body_bytes
  }
  let values = @nrrd.decode_data(data_bytes, h)
  let out = StringBuilder()
  out.write_string("fixture: \{basename(path)}\n")
  out.write_string("type: \{h.type_name}\n")
  out.write_string("dimension: \{h.dimension}\n")
  let size_str = StringBuilder()
  let mut first = true
  for s in h.sizes {
    if !first {
      size_str.write_string(" ")
    }
    size_str.write_string(s.to_string())
    first = false
  }
  out.write_string("sizes: \{size_str.to_string()}\n")
  out.write_string("encoding: \{h.encoding}\n")
  out.write_string("endian: \{@nrrd.format_opt(h.endian)}\n")
  out.write_string("data file: \{@nrrd.format_opt(h.data_file)}\n")
  out.write_string("space: \{@nrrd.format_opt(h.space)}\n")
  let origin_str = match h.space_origin {
    Some(v) => @nrrd.format_double_list(v)
    None => "<none>"
  }
  out.write_string("space origin: \{origin_str}\n")
  let dirs_str = if h.space_directions.is_empty() {
    "<none>"
  } else {
    @nrrd.format_directions(h.space_directions)
  }
  out.write_string("space directions: \{dirs_str}\n")
  let units_str = match h.space_units {
    Some(v) => @nrrd.format_string_list(v)
    None => "<none>"
  }
  out.write_string("space units: \{units_str}\n")
  let labels_str = match h.labels {
    Some(v) => @nrrd.format_string_list(v)
    None => "<none>"
  }
  out.write_string("labels: \{labels_str}\n")
  let kinds_str = match h.kinds {
    Some(v) => @nrrd.format_string_list(v)
    None => "<none>"
  }
  out.write_string("kinds: \{kinds_str}\n")
  out.write_string("content: \{@nrrd.format_opt(h.content)}\n")
  out.write_string("values:\n")
  // Odometer with the LAST axis varying fastest (reference dump order);
  // linear index uses NRRD order (FIRST axis fastest).
  let dim = h.dimension
  let idx = Array::make(dim, 0)
  let mut total = 1
  for s in h.sizes {
    total = total * s
  }
  let is_float = h.type_name == "float" || h.type_name == "double"
  let mut n = 0
  while n < total {
    let mut flat = 0
    let mut stride = 1
    let mut a = 0
    while a < dim {
      flat = flat + idx[a] * stride
      stride = stride * h.sizes[a]
      a = a + 1
    }
    let coord = StringBuilder()
    let mut c0 = true
    for v in idx {
      if !c0 {
        coord.write_string(",")
      }
      coord.write_string(v.to_string())
      c0 = false
    }
    let v = values[flat]
    let vs = if is_float {
      @nrrd.format_float(v)
    } else {
      @nrrd.format_int_value(v)
    }
    out.write_string("  \{coord.to_string()} = \{vs}\n")
    let mut a2 = dim - 1
    let mut carry = true
    while carry && a2 >= 0 {
      idx[a2] = idx[a2] + 1
      if idx[a2] < h.sizes[a2] {
        carry = false
      } else {
        idx[a2] = 0
        a2 = a2 - 1
      }
    }
    n = n + 1
  }
  let s = out.to_string()
  if s.length() > 0 {
    println(s[: s.length() - 1].to_owned())
  }
}

///|
fn main {
  let args = @env.args()
  if args.length() < 3 {
    eprintln("usage: probe <fixture-path> [<fixture-path> ...]")
    set_exit_code(2)
    return
  }
  let mut any_failed = false
  let mut i = 2
  while i < args.length() {
    let path = args[i]
    if i > 2 {
      println("") // blank line between fixture blocks (matches reference dump)
    }
    try {
      process_fixture(path)
    } catch {
      e => {
        let msg = match e {
          @nrrd.NrrdError(m) => m
        }
        // diagnostics on stderr, not stdout (audit item 5)
        eprintln("error: \{path}: \{msg}")
        any_failed = true
      }
    }
    i = i + 1
  }
  // batch aggregates: non-zero exit if any fixture failed
  if any_failed {
    set_exit_code(1)
  }
}
