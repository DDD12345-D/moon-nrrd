///| ASCII float32 direct-rounding evidence probe (host layer — this
///| program MAY do file IO; the core library never does).
///| Usage: moon run --target js cmd/f32probe -- <tokens-file>
///| For each token line (blank/# lines skipped) runs the REAL public
///| read path (ascii header -> split_header_body -> parse_header ->
///| decode_data) and prints `token<TAB>0x%08x` or `token<TAB>ERROR`
///| to stdout — the actual binary32 bit pattern produced by the new
///| direct-rounding parse path.  Error details go to stderr.
///| Output format matches tests/reference_f32.py so the two TSVs can
///| be compared field-by-field (tests/reference_f32.py --compare).

///|
extern "js" fn set_exit_code(code : Int) -> Unit =
  #| (code) => { globalThis.process.exitCode = code }

///| Hex rendering of a signed Int as 8 unsigned hex digits.
fn hex8(v : Int) -> String {
  let digits = "0123456789abcdef"
  let sb = StringBuilder()
  let mut i = 0
  while i < 8 {
    let nib = (v >> ((7 - i) * 4)) & 15
    match digits.get_char(nib) {
      Some(c) => sb.write_char(c)
      None => ()
    }
    i = i + 1
  }
  sb.to_string()
}

///| Decode one ASCII float token through the public read path.
///| Returns the recovered binary32 bit pattern, or raises.
fn decode_one(tok : String) -> Int raise @nrrd.NrrdError {
  let text = "NRRD0005\ntype: float\ndimension: 1\nsizes: 1\nencoding: ascii\n\n\{tok}"
  let data = @nrrd.ascii_to_bytes(text)
  let (hb, body) = @nrrd.split_header_body(data)
  let h = @nrrd.parse_header(@nrrd.bytes_to_ascii(hb))
  let vals = @nrrd.decode_data(body, h)
  Float::reinterpret_as_int(Float::from_double(vals[0]))
}

///|
fn main {
  let args = @env.args()
  if args.length() < 3 {
    eprintln("usage: f32probe <tokens-file>")
    set_exit_code(2)
    return
  }
  let path = args[2]
  let text = try {
    @fs.read_file_to_string(path)
  } catch {
    _ => {
      eprintln("cannot read token file: \{path}")
      set_exit_code(2)
      return
    }
  }
  let mut n = 0
  let mut errors = 0
  for line in text.split("\n") {
    let tok = line.trim().to_owned()
    if tok.is_empty() || tok.has_prefix("#") {
      continue
    }
    n = n + 1
    try {
      let bits = decode_one(tok)
      println("\{tok}\t0x\{hex8(bits)}")
    } catch {
      err => {
        let msg = match err {
          @nrrd.NrrdError(m) => m
        }
        println("\{tok}\tERROR")
        eprintln("error: \{tok}: \{msg}")
        errors = errors + 1
      }
    }
  }
  eprintln("f32probe: \{n} tokens processed, \{errors} rejected")
  set_exit_code(0)
}
