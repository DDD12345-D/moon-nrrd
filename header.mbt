///| Minimal NRRD header parser for the G1 probe.
///| Field names are matched case-insensitively with spaces removed
///| (`data file` == `datafile`), per the NRRD format specification
///| (https://teem.sourceforge.net/nrrd/format.html).
///| Magic policy (spec §1.1): the first line must be exactly `NRRD0005`
///| (v1 supports that version only; other versions/suffixes/garbage are
///| rejected). Field-specification uniqueness (spec §1.2): every
///| `field: desc` line may appear at most once (alias/case folded);
///| `key:=value` custom pairs may repeat.

///|
pub(all) struct NrrdHeader {
  dimension : Int
  sizes : Array[Int]
  type_name : String
  encoding : String
  endian : String?
  data_file : String?
  space : String?
  space_dimension : Int?
  space_origin : Array[Double]?
  space_directions : Array[Array[Double]?]
  space_units : Array[String]?
  labels : Array[String]?
  kinds : Array[String]?
  content : String?
  line_skip : Int
  byte_skip : Int
}

///| Header text length budget (G2 v2 §7.2). Enforced both at the
///| split_header_body entry AND in parse_header itself so direct
///| callers cannot bypass it. 1 MiB is far above real headers
///| (typically < 64 KiB) and bounds malformed input.
fn max_header_bytes() -> Int {
  1048576
}

///| Dimension cap (G2 v2 §7.2).
fn max_dimension() -> Int {
  16
}

///|
fn char_at(s : String, i : Int) -> Char {
  match s.get_char(i) {
    Some(c) => c
    None => panic()
  }
}

///| Bytes -> String treating every byte as an ASCII code point.
///| (`Bytes::to_string` decodes UTF-16 on this toolchain and garbles
///| real file bytes; NRRD headers are ASCII by specification.)
pub fn bytes_to_ascii(b : Bytes) -> String {
  String::from_array(Array::makei(b.length(), i => b[i].to_int().unsafe_to_char()))
}

///| String -> Bytes taking the low byte of each code unit (ASCII only).
pub fn ascii_to_bytes(s : String) -> Bytes {
  Bytes::from_array(Array::makei(s.length(), i => char_at(s, i).to_int().to_byte()))
}

///| `s[a:b]` slice as an owned String.
fn slice_str(s : String, a : Int, b : Int) -> String {
  s[a:b].to_owned()
}

///|
fn is_ws(c : Char) -> Bool {
  c == ' ' || c == '\t' || c == '\r' || c == '\n' || c.to_int() == 11 || c.to_int() == 12
}

///| Parse a decimal integer into Int64 with overflow checks.
///| Accumulates as a non-positive Int64 so the asymmetry of the
///| range is handled naturally: -2^63 is representable while +2^63
///| is not. Rejects BEFORE wraparound; handles '+'/'-' and the
///| Int64 minimum correctly; returns None on empty input, stray
///| characters, or out-of-range values. Used for data values that
///| must cover the full uint32 range (2^32-1 does not fit Int).
fn parse_int64_str(s : String) -> Int64? {
  let n = s.length()
  let mut i = 0
  let mut neg = false
  if n == 0 {
    return None
  }
  let c0 = char_at(s, 0)
  if c0 == '-' {
    neg = true
    i = 1
  } else if c0 == '+' {
    i = 1
  }
  let min_int64 = -9223372036854775807L - 1L
  let mut acc = 0L // running magnitude, stored negated (acc <= 0)
  let mut any = false
  while i < n {
    let c = char_at(s, i)
    if c.is_ascii_digit() {
      let d = (c.to_int() - 48).to_int64()
      // need acc * 10 - d >= min_int64 (truncating division rounds
      // toward zero on a negative numerator = ceil, which is safe)
      if acc < (min_int64 + d) / 10L {
        return None
      }
      acc = acc * 10L - d
      any = true
      i = i + 1
    } else {
      return None
    }
  }
  if !any {
    return None
  }
  if neg {
    Some(acc)
  } else {
    // positive magnitude must fit in Int64 max (= |min| - 1)
    if acc < -9223372036854775807L {
      return None
    }
    Some(0L - acc)
  }
}

///| Parse a decimal integer with overflow checks into Int (32-bit).
///| Accumulates in Int64 and rejects BEFORE wraparound
///| (regression: ASCII "4294967297" used to wrap to 1 and be
///| silently accepted — audit-overflow-int16.nrrd). Handles sign
///| and the Int minimum -2147483648 correctly; returns None on
///| empty input, stray characters, or values outside Int range.
fn parse_int_str(s : String) -> Int? {
  match parse_int64_str(s) {
    Some(v) =>
      if v >= -2147483648L && v <= 2147483647L {
        Some(v.to_int())
      } else {
        None
      }
    None => None
  }
}

///| Parse a decimal double using the core conversion (correctly
///| rounded, bounded work). The hand-rolled parser was replaced
///| after review: its exponent accumulated in Int without bounds
///| and scaled by a linear loop. Returns None on malformed input.
fn parse_double_str(s : String) -> Double? {
  try {
    Some(@string.parse_double(s))
  } catch {
    _ => None
  }
}

///|
fn split_ws_tokens(s : String) -> Array[String] {
  let out : Array[String] = []
  let n = s.length()
  let mut i = 0
  while i < n {
    while i < n && is_ws(char_at(s, i)) {
      i = i + 1
    }
    let start = i
    while i < n && !is_ws(char_at(s, i)) {
      i = i + 1
    }
    if i > start {
      out.push(slice_str(s, start, i))
    }
  }
  out
}

///| Tokens of quoted strings (`"a" "b"`) or bare words (kinds).
fn parse_quoted_tokens(s : String) -> Array[String] {
  let out : Array[String] = []
  let n = s.length()
  let mut i = 0
  while i < n {
    while i < n && is_ws(char_at(s, i)) {
      i = i + 1
    }
    if i >= n {
      break
    }
    if char_at(s, i) == '"' {
      i = i + 1
      let start = i
      while i < n && char_at(s, i) != '"' {
        i = i + 1
      }
      out.push(slice_str(s, start, i))
      if i < n {
        i = i + 1
      }
    } else {
      let start = i
      while i < n && !is_ws(char_at(s, i)) {
        i = i + 1
      }
      out.push(slice_str(s, start, i))
    }
  }
  out
}

///| Parse `(1.5,0,0)` style vector.
fn parse_paren_vec(s : String, field : String) -> Array[Double] raise NrrdError {
  let n = s.length()
  let mut l = -1
  let mut r = -1
  let mut i = 0
  while i < n {
    if char_at(s, i) == '(' && l < 0 {
      l = i
    }
    if char_at(s, i) == ')' {
      r = i
    }
    i = i + 1
  }
  if l < 0 || r <= l {
    raise NrrdError("\{field}: cannot parse vector '\{s}'")
  }
  let inner = slice_str(s, l + 1, r)
  let parts = split_ws_tokens(inner.replace_all(old=",", new=" "))
  let out : Array[Double] = []
  for p in parts {
    match parse_double_str(p) {
      Some(v) => out.push(v)
      None => raise NrrdError("\{field}: cannot parse number '\{p}'")
    }
  }
  out
}

///| Parse `space directions` value: `none (1,0,0) (0,2,0)` etc.
fn parse_directions(s : String) -> Array[Array[Double]?] raise NrrdError {
  let compact = s.replace_all(old=" ", new="").replace_all(old="\t", new="")
  let out : Array[Array[Double]?] = []
  let n = compact.length()
  let mut i = 0
  while i < n {
    let c = char_at(compact, i)
    if c == 'n' {
      out.push(None) // "none"
      i = i + 4
    } else if c == '(' {
      let mut r = i
      while r < n && char_at(compact, r) != ')' {
        r = r + 1
      }
      if r >= n {
        raise NrrdError("space directions: unbalanced paren")
      }
      out.push(Some(parse_paren_vec(slice_str(compact, i, r + 1), "space directions")))
      i = r + 1
    } else {
      raise NrrdError("space directions: unexpected char '\{c}'")
    }
  }
  out
}

///| Field name normalization: lowercase with spaces removed.
fn normalize_field_name(s : String) -> String {
  let sb = StringBuilder()
  let n = s.length()
  let mut i = 0
  while i < n {
    let c = char_at(s, i)
    if c != ' ' && c != '\t' {
      sb.write_char(if c.to_int() >= 65 && c.to_int() <= 90 {
        (c.to_int() + 32).unsafe_to_char()
      } else {
        c
      })
    }
    i = i + 1
  }
  sb.to_string()
}

///| Alias collapse for field identifiers whose equivalent spelled forms
///| differ beyond whitespace/case (spec §1.2: "centers" is the same field
///| as "centerings"). All other documented aliases unify through
///| normalize_field_name's space-stripping ("data file" == "datafile",
///| "line skip" == "lineskip", ...).
fn canonical_field_id(s : String) -> String {
  match s {
    "centers" => "centerings"
    _ => s
  }
}

///| Normalize a type descriptor to its canonical short name.
pub fn normalize_type(t : String) -> String raise NrrdError {
  let x = normalize_field_name(t)
  match x {
    "signedchar" | "int8" | "int8_t" => "int8"
    "uchar" | "unsignedchar" | "uint8" | "uint8_t" => "uint8"
    "short" | "shortint" | "signedshort" | "int16" | "int16_t" => "int16"
    "ushort" | "unsignedshort" | "uint16" | "uint16_t" => "uint16"
    "int" | "signedint" | "int32" | "int32_t" => "int32"
    "uint" | "unsignedint" | "uint32" | "uint32_t" => "uint32"
    "longlong" | "int64" | "int64_t" => "int64"
    "ulonglong" | "uint64" | "uint64_t" => "uint64"
    "float" => "float"
    "double" => "double"
    "block" => "block"
    _ => raise NrrdError("unknown type '\{t}'")
  }
}

///| Normalize an encoding descriptor to its canonical short name.
pub fn normalize_encoding(e : String) -> String raise NrrdError {
  let x = normalize_field_name(e)
  match x {
    "raw" => "raw"
    "txt" | "text" | "ascii" => "ascii"
    "hex" => "hex"
    "gz" | "gzip" => "gzip"
    "bz2" | "bzip2" => "bzip2"
    _ => raise NrrdError("unknown encoding '\{e}'")
  }
}

///| Split file bytes into header text and body (attached data) at the
///| single blank line. Handles `\n`, `\r\n` and mixed terminators.
///| Enforces the header-length budget before returning (G2 v2 §7.2).
pub fn split_header_body(data : Bytes) -> (Bytes, Bytes) raise NrrdError {
  let n = data.length()
  let mut line_start = 0
  let mut i = 0
  while i < n {
    if data[i] == b'\n' {
      let mut end = i
      if end > line_start && data[end - 1] == b'\r' {
        end = end - 1
      }
      if end == line_start {
        // blank line: header ends at line_start, body after the newline
        if line_start > max_header_bytes() {
          raise NrrdError("header too large: \{line_start} bytes")
        }
        let header = Bytes::from_array(Array::makei(line_start, k => data[k]))
        let body = Bytes::from_array(Array::makei(n - (i + 1), k => data[i + 1 + k]))
        return (header, body)
      }
      line_start = i + 1
    }
    i = i + 1
  }
  raise NrrdError("no blank line separating header and data")
}

///| Implied dimension of a named space (spec §4 table).
///| Unknown names are rejected: v1 does not pass through names
///| whose space dimension cannot be interpreted (G2 v2 decision A).
fn named_space_dimension(name : String) -> Int raise NrrdError {
  match name.to_lower() {
    "right-anterior-superior" | "ras" | "left-anterior-superior" | "las" |
    "left-posterior-superior" | "lps" | "scanner-xyz" | "3d-right-handed" |
    "3d-left-handed" => 3
    "right-anterior-superior-time" | "rast" | "left-anterior-superior-time" |
    "last" | "left-posterior-superior-time" | "lpst" | "scanner-xyz-time" |
    "3d-right-handed-time" | "3d-left-handed-time" => 4
    _ => raise NrrdError("unknown named space '\{name}'")
  }
}

///| Structural + spatial legality validation for a (possibly
///| constructed) header. Called by parse_header and, independently,
///| by decode_data — callers cannot assume parse was ever involved.
///
///| Spatial conditions (unambiguous, G2 v2 §4.3 decision A):
///| - illegal: `space` and `space dimension` both present -> reject
///| - illegal: orientation fields (origin/directions/space units)
///|   present but neither `space` nor `space dimension` -> reject
///| - illegal: unknown named space -> reject
///| - consistency OF PRESENT optional fields only:
///|   labels/kinds count == dimension; directions rows == dimension;
///|   space units count == space dimension; origin length == space
///|   dimension; non-none direction vectors length == space dimension.
///| - NOT errors: missing space units / origin / directions / labels /
///|   kinds; absent spatial fields entirely (data ops have their own
///|   policy for incomplete spatial info — decision C).
pub fn validate_header(h : NrrdHeader) -> Unit raise NrrdError {
  if h.dimension < 1 {
    raise NrrdError("missing or invalid dimension")
  }
  if h.dimension > max_dimension() {
    raise NrrdError("dimension \{h.dimension} exceeds limit \{max_dimension()}")
  }
  if h.sizes.length() != h.dimension {
    raise NrrdError(
      "sizes count \{h.sizes.length()} does not match dimension \{h.dimension}",
    )
  }
  for s in h.sizes {
    if s <= 0 {
      raise NrrdError("sizes must be positive")
    }
  }
  // per-axis field counts (only validated when present)
  match h.labels {
    Some(ls) =>
      if ls.length() != h.dimension {
        raise NrrdError("labels count \{ls.length()} does not match dimension")
      }
    None => ()
  }
  match h.kinds {
    Some(ks) =>
      if ks.length() != h.dimension {
        raise NrrdError("kinds count \{ks.length()} does not match dimension")
      }
    None => ()
  }
  if !h.space_directions.is_empty() && h.space_directions.length() != h.dimension {
    raise NrrdError(
      "space directions count \{h.space_directions.length()} does not match dimension",
    )
  }
  // spatial identity (decision A)
  match (h.space, h.space_dimension) {
    (Some(_), Some(_)) => raise NrrdError(
      "space and space dimension are mutually exclusive",
    )
    (None, None) => {
      let has_orient = h.space_origin is Some(_) ||
        !h.space_directions.is_empty() ||
        h.space_units is Some(_)
      if has_orient {
        raise NrrdError(
          "orientation fields require space or space dimension",
        )
      }
    }
    _ => ()
  }
  // effective space dimension (identity present in exactly one form)
  let sd_opt : Int? = match h.space_dimension {
    Some(sd) => {
      if sd < 1 {
        raise NrrdError("space dimension must be positive")
      }
      Some(sd)
    }
    None => match h.space {
      Some(name) => Some(named_space_dimension(name))
      None => None
    }
  }
  match sd_opt {
    Some(sd) => {
      match h.space_units {
        Some(us) =>
          if us.length() != sd {
            raise NrrdError(
              "space units count \{us.length()} does not match space dimension \{sd}",
            )
          }
        None => ()
      }
      match h.space_origin {
        Some(o) =>
          if o.length() != sd {
            raise NrrdError(
              "space origin length \{o.length()} does not match space dimension \{sd}",
            )
          }
        None => ()
      }
      for row in h.space_directions {
        match row {
          Some(v) =>
            if v.length() != sd {
              raise NrrdError(
                "space direction vector length \{v.length()} does not match space dimension \{sd}",
              )
            }
          None => ()
        }
      }
    }
    None => ()
  }
}

///| Parse an NRRD header text (without the data payload).
///| Enforces the header-length budget directly (G2 v2 §7.2: not
///| only at the split_header_body entry).
pub fn parse_header(text : String) -> NrrdHeader raise NrrdError {
  if text.length() > max_header_bytes() {
    raise NrrdError("header too large: \{text.length()} bytes")
  }
  let mut dimension = 0
  let mut sizes : Array[Int] = []
  let mut type_name = ""
  let mut encoding = ""
  let mut endian : String? = None
  let mut data_file : String? = None
  let mut space : String? = None
  let mut space_dimension : Int? = None
  let mut space_origin : Array[Double]? = None
  let mut space_directions : Array[Array[Double]?] = []
  let mut space_units : Array[String]? = None
  let mut labels : Array[String]? = None
  let mut kinds : Array[String]? = None
  let mut content : String? = None
  let mut line_skip = 0
  let mut byte_skip = 0
  let n = text.length()
  let mut i = 0
  let mut first = true
  let seen_fields : Array[String] = []
  while i <= n {
    let mut j = i
    while j < n && char_at(text, j) != '\n' {
      j = j + 1
    }
    let mut line = slice_str(text, i, j)
    if line.length() > 0 && char_at(line, line.length() - 1) == '\r' {
      line = slice_str(line, 0, line.length() - 1)
    }
    i = j + 1
    if first {
      first = false
      // Magic (spec §1.1: "The very first line contains nothing but the
      // NRRD magic"). Strict whole-line comparison: v1 supports NRRD0005
      // only. Unknown versions (NRRD0001-0004, NRRD00.01), suffixes
      // ("NRRD0005x", "NRRD0005 extra") and garbage ("NRRDgarbage") are
      // explicitly rejected.
      if line != "NRRD0005" {
        if line.has_prefix("NRRD") {
          raise NrrdError(
            "unsupported NRRD magic '\{line}': this reader supports NRRD0005 only",
          )
        } else {
          raise NrrdError("invalid NRRD magic in first line: '\{line}'")
        }
      }
      continue
    }
    if line.is_empty() {
      break
    }
    if line.has_prefix("#") {
      continue
    }
    let mut colon = -1
    let mut k = 0
    while k < line.length() {
      if char_at(line, k) == ':' {
        colon = k
        k = line.length()
      } else {
        k = k + 1
      }
    }
    if colon < 0 {
      raise NrrdError("header line without ':': '\{line}'")
    }
    if colon + 1 < line.length() && char_at(line, colon + 1) == '=' {
      continue // custom key:=value pair: repeats ARE allowed (spec §1.2,
      // last value wins when stored); the field-specification uniqueness
      // rule below does NOT apply to key:=value lines
    }
    // Field-specification uniqueness (spec §1.2: "Each field specification
    // may appear no more than once in the nrrd header"). Enforced after
    // case-folding, space-stripping and alias normalization; a repeated
    // field is rejected even when its content is identical. Applies to
    // every `field: desc` line (standard fields and unknown fields alike);
    // `key:=value` custom pairs are exempt (handled above).
    let fname = canonical_field_id(normalize_field_name(slice_str(line, 0, colon)))
    for s in seen_fields {
      if s == fname {
        raise NrrdError(
          "duplicate field '\{fname}': field specifications may appear at most once",
        )
      }
    }
    seen_fields.push(fname)
    let desc = slice_str(line, colon + 1, line.length()).trim().to_owned()
    match fname {
      "dimension" => match parse_int_str(desc) {
        Some(v) => dimension = v
        None => raise NrrdError("dimension: cannot parse '\{desc}'")
      }
      "sizes" => {
        sizes = []
        for t in split_ws_tokens(desc) {
          match parse_int_str(t) {
            Some(v) => sizes.push(v)
            None => raise NrrdError("sizes: cannot parse '\{t}'")
          }
        }
      }
      "type" => type_name = desc
      "encoding" => encoding = desc
      "endian" => endian = Some(desc.to_lower())
      "datafile" => data_file = Some(desc)
      "space" => space = Some(desc)
      "spacedimension" => match parse_int_str(desc) {
        Some(v) => space_dimension = Some(v)
        None => raise NrrdError("space dimension: cannot parse '\{desc}'")
      }
      "spaceorigin" => space_origin = Some(parse_paren_vec(desc, "space origin"))
      "spacedirections" => space_directions = parse_directions(desc)
      "spaceunits" => space_units = Some(parse_quoted_tokens(desc))
      "labels" => labels = Some(parse_quoted_tokens(desc))
      "kinds" => kinds = Some(parse_quoted_tokens(desc))
      "content" => content = Some(desc)
      "lineskip" => match parse_int_str(desc) {
        Some(v) => line_skip = v
        None => raise NrrdError("line skip: cannot parse '\{desc}'")
      }
      "byteskip" => match parse_int_str(desc) {
        Some(v) => byte_skip = v
        None => raise NrrdError("byte skip: cannot parse '\{desc}'")
      }
      _ => continue // unknown/harmless fields are ignored
    }
  }
  if type_name.is_empty() || encoding.is_empty() {
    raise NrrdError("missing type or encoding")
  }
  let h = {
    dimension,
    sizes,
    type_name: normalize_type(type_name),
    encoding: normalize_encoding(encoding),
    endian,
    data_file,
    space,
    space_dimension,
    space_origin,
    space_directions,
    space_units,
    labels,
    kinds,
    content,
    line_skip,
    byte_skip,
  }
  validate_header(h)
  h
}
