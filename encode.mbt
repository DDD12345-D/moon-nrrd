///| NRRD header serialization and data payload encoding (G3 write-side).
///| Contract (G2 v2 §3 / §7): `format_header` emits NRRD0005 text,
///| `encode_data` emits payload bytes, `assemble_attached` /
///| `assemble_detached` combine them WITHOUT any file IO — the core
///| returns only Bytes/String; filenames are chosen by the host and
///| must match the header's `data file` declaration.
///|
///| Value policy (G2 v2 §7.1): integer-typed values must be finite,
///| integral and inside the type range — violations raise with the
///| value and type, never silently truncate. uint32's high half is
///| carried exactly (Double -> Int64 within 2^53). Float values are
///| rounded to the nearest binary32 (ties-to-even, `Float::from_double`;
///| overflow saturates to +-inf). Double values are bit-exact,
///| including -0.0; NaN payload bits are not promised (semantic
///| comparison). ASCII integers use exact decimal Int64 formatting
///| (never a lossy float format); ASCII float32 writes the shortest
///| decimal that round-trips through the READER's two-step parse
///| (decimal -> binary64 -> binary32); ASCII double writes the
///| shortest binary64 round-trip string.
///|
///| Budget (G2 v2 §7.2): max 2^24 elements, overridable via `budget~`.
///| Checked as a defensive lower bound before building the output;
///| peak memory may exceed the naive product. The raw byte product is
///| additionally pre-checked with a division so `count * item` cannot
///| wrap Int.
///|
///| String fields (spec escaping, injection defense):
///| - v1 write contract: ALL writable strings (content, data file,
///|   labels, space units, space, kinds, key:=value key and value)
///|   are ASCII only. Non-ASCII code points are REJECTED with
///|   NrrdError before any byte conversion — never silently
///|   truncated to a low byte (U+010A -> 0x0A would inject a
///|   newline into the header) and never panicked on (a
///|   supplementary-plane UTF-16 traversal raises instead).
///| - `content` / `data file` are bare line strings: newline/CR and
///|   other C0 controls are rejected; leading/trailing whitespace is
///|   rejected (both readers trim, so it could not round-trip).
///| - `labels` / `space units` are quote-delimited: `"` is escaped as
///|   `\"` (the only escape the spec defines); backslash is REJECTED
///|   (the spec defines no backslash escape and readers disagree on
///|   `\\`, so a literal backslash cannot be round-tripped safely);
///|   newline/CR/controls are rejected.
///| - `kinds` are bare whitespace-separated tokens: whitespace,
///|   quotes and controls inside a token are rejected.
///| - key:=value pairs: see `format_keyval_line` (spec escapes
///|   `\n` and `\\`; keys that collide with standard field names are
///|   rejected so custom pairs cannot shadow known fields).
///| Unknown-field / key:=value preservation is NOT implemented:
///| `NrrdHeader` carries only standard fields and `format_header`
///| emits only those (no replay of unvalidated fields).

///| Allocation budget: refuse to encode more than 2^24 elements.
fn max_encode_elements() -> Int {
  16777216
}

///| Stringify a Double for error messages.
fn encode_value_repr(d : Double) -> String {
  if d.is_nan() {
    "nan"
  } else if d.is_pos_inf() {
    "+inf"
  } else if d.is_neg_inf() {
    "-inf"
  } else {
    d.to_string()
  }
}

///| Integer-typed value policy (G2 v2 §7.1): finite, integral, in
///| range. Returns the value as Int64 (exact for every supported
///| integer type). Raises with value and type on any violation —
///| never silently truncates.
fn integer_bits(d : Double, t : String) -> Int64 raise NrrdError {
  if d.is_nan() {
    raise NrrdError("\{t}: NaN is not a valid integer value")
  }
  if d.is_inf() {
    raise NrrdError("\{t}: infinity is not a valid integer value")
  }
  if d != d.trunc() {
    raise NrrdError("\{t}: non-integral value \{encode_value_repr(d)}")
  }
  let (lo, hi) = int_value_range(t)
  if d < lo.to_double() || d > hi.to_double() {
    raise NrrdError(
      "\{t}: value \{encode_value_repr(d)} out of range [\{lo.to_string()},\{hi.to_string()}]",
    )
  }
  d.to_int64()
}

///| Raw bit pattern (Int64, low `item` bytes meaningful) for one
///| value of canonical type `t`. Integers are validated first;
///| float rounds to binary32; double keeps its exact bit pattern.
fn raw_value_bits(d : Double, t : String) -> Int64 raise NrrdError {
  match t {
    "int8" | "uint8" | "int16" | "uint16" | "int32" | "uint32" => integer_bits(d, t)
    "float" => Float::reinterpret_as_int(Float::from_double(d)).to_int64()
    _ => d.reinterpret_as_int64() // double
  }
}

///| Write the low `item` bytes of `bits` at offset `at`, little- or
///| big-endian. Byte extraction masks after an arithmetic shift, so
///| negative Int64 patterns (two's complement) yield the right bytes.
fn write_bits(out : Array[Byte], at : Int, bits : Int64, item : Int, big : Bool) -> Unit {
  let mut k = 0
  while k < item {
    let b = (bits >> (8 * k)).land(255L).to_int().to_byte()
    if big {
      out[at + item - 1 - k] = b
    } else {
      out[at + k] = b
    }
    k = k + 1
  }
}

///| Reject non-ASCII code points, invalid UTF-16 code units and
///| C0 controls in a bare line string. v1 write contract: writable
///| strings are ASCII only; a non-ASCII code point is NEVER silently
///| truncated to its low byte (U+010A would become 0x0A and inject
///| a newline) and supplementary-plane UTF-16 traversal raises
///| instead of panicking.
fn check_line_value(s : String, field : String) -> Unit raise NrrdError {
  let mut i = 0
  while i < s.length() {
    match s.get_char(i) {
      Some(c) => {
        let v = c.to_int()
        if v > 127 {
          raise NrrdError(
            "\{field}: non-ASCII code point \{v.to_string()} is not representable (write strings are ASCII only)",
          )
        }
        if v < 32 {
          raise NrrdError(
            "\{field}: control character \{v.to_string()} in string is not representable",
          )
        }
      }
      None => raise NrrdError(
        "\{field}: invalid UTF-16 code unit at index \{i.to_string()}",
      )
    }
    i = i + 1
  }
}

///| Bare line strings additionally must not rely on leading/trailing
///| whitespace: both this library's parser and pynrrd trim the field
///| value, so such whitespace could not round-trip (silent change).
fn check_line_value_trimmed(s : String, field : String) -> Unit raise NrrdError {
  check_line_value(s, field)
  if s != s.trim().to_owned() {
    raise NrrdError(
      "\{field}: leading/trailing whitespace would not round-trip (values are trimmed on read)",
    )
  }
}

///| One quote-delimited token (labels / space units). Spec §1.6:
///| `"` is escaped as `\"` and that is the ONLY escape; backslash
///| has no spec escape, so it is rejected here to stay unambiguous
///| across readers (see module doc).
fn format_quoted_token(s : String, field : String) -> String raise NrrdError {
  let out = StringBuilder()
  out.write_string("\"")
  let mut i = 0
  while i < s.length() {
    match s.get_char(i) {
      Some(c) => {
        let v = c.to_int()
        if v > 127 {
          raise NrrdError(
            "\{field}: non-ASCII code point \{v.to_string()} is not representable (write strings are ASCII only)",
          )
        }
        if c == '"' {
          out.write_string("\\\"")
        } else if c == '\\' {
          raise NrrdError(
            "\{field}: backslash in string has no spec escape and would not round-trip safely",
          )
        } else if v < 32 {
          raise NrrdError(
            "\{field}: control character \{v.to_string()} in string is not representable",
          )
        } else {
          out.write_char(c)
        }
      }
      None => raise NrrdError(
        "\{field}: invalid UTF-16 code unit at index \{i.to_string()}",
      )
    }
    i = i + 1
  }
  out.write_string("\"")
  out.to_string()
}

///| Quote-delimited string list: `"a" "b"` (tokens delimited by a
///| single space, per spec §4/§6).
fn format_quoted_list(ss : Array[String], field : String) -> String raise NrrdError {
  let out = StringBuilder()
  let mut first = true
  for s in ss {
    if !first {
      out.write_string(" ")
    }
    out.write_string(format_quoted_token(s, field))
    first = false
  }
  out.to_string()
}

///| Bare whitespace-separated tokens (kinds). A token containing
///| whitespace would split in two; a token containing `"` would be
///| re-read as a quoted string — both are rejected to keep the
///| round-trip exact.
fn format_bare_list(ss : Array[String], field : String) -> String raise NrrdError {
  let out = StringBuilder()
  let mut first = true
  for s in ss {
    if s.is_empty() {
      raise NrrdError("\{field}: empty token")
    }
    check_line_value_trimmed(s, field)
    // interior whitespace would split one token into several on read
    if s.contains(" ") || s.contains("\t") {
      raise NrrdError("\{field}: whitespace in bare token is not representable")
    }
    if s.contains("\"") {
      raise NrrdError("\{field}: double quote in bare token is not representable")
    }
    if !first {
      out.write_string(" ")
    }
    out.write_string(s)
    first = false
  }
  out.to_string()
}

///| One spatial vector: `(a,b,c)` with comma-separated components and
///| NO whitespace inside the vector (pynrrd splits vector lists on
///| whitespace, so an inner space would break the row). Components
///| must be finite: `parse_paren_vec` has no nan/inf literal path.
fn format_spatial_vec(v : Array[Double], field : String) -> String raise NrrdError {
  if v.is_empty() {
    raise NrrdError("\{field}: empty vector")
  }
  let out = StringBuilder()
  out.write_string("(")
  let mut first = true
  for c in v {
    if c.is_nan() || c.is_inf() {
      raise NrrdError("\{field}: spatial vector components must be finite")
    }
    if !first {
      out.write_string(",")
    }
    out.write_string(format_float(c))
    first = false
  }
  out.write_string(")")
  out.to_string()
}

///| `space directions` descriptor: rows delimited by whitespace
///| (spec §6: per-axis descriptors are delimited by spaces/tabs) with
///| `none` for non-spatial axes. NOTE: the probe's canonical dump
///| format uses " | " separators (format.mbt `format_directions`) for
///| diffing against pynrrd-reads.txt — that is a dump convention, not
///| a file format; file output follows the spec here.
fn format_directions_value(rows : Array[Array[Double]?]) -> String raise NrrdError {
  let out = StringBuilder()
  let mut first = true
  for row in rows {
    if !first {
      out.write_string(" ")
    }
    match row {
      Some(v) => out.write_string(format_spatial_vec(v, "space directions"))
      None => out.write_string("none")
    }
    first = false
  }
  out.to_string()
}

///| Known standard field identifiers (normalized: lowercased, spaces
///| stripped, alias-collapsed). Used to stop custom key:=value pairs
///| from shadowing standard fields in readers with last-wins
///| semantics ("unknown fields must not override known fields").
fn is_standard_field_id(norm : String) -> Bool {
  match canonical_field_id(norm) {
    "dimension" | "sizes" | "type" | "encoding" | "endian" | "datafile" | "space" |
    "spacedimension" | "spaceorigin" | "spacedirections" | "spaceunits" | "labels" |
    "kinds" | "content" | "lineskip" | "byteskip" | "min" | "max" | "oldmin" | "oldmax" |
    "sampleunits" | "units" | "centerings" | "spacings" | "thicknesses" | "axismins" |
    "axismaxs" | "measurementframe" | "blocksize" => true
    _ => false
  }
}

///| One spec-escaped custom key:=value line (without trailing
///| newline). Spec §1.7 minimal escaping — writers MUST generate it:
///| `\n` (backslash-n) for newline, `\\` for backslash. `\r` and
///| other controls are rejected (no escape exists and they break
///| line structure). The key must not contain `:` (readers split at
///| the first colon, so `a:b:=v` would be misread), must not contain
///| `:=`, must not start with `#` (comment), must not collide with a
///| standard field name, and must not carry edge whitespace.
///| NOTE: NrrdHeader does not carry key:=value pairs — this helper is
///| for hosts that append custom pairs; preservation through this
///| library is unsupported (see module doc).
pub fn format_keyval_line(key : String, value : String) -> String raise NrrdError {
  if key.is_empty() {
    raise NrrdError("key:=value: empty key")
  }
  check_line_value_trimmed(key, "key:=value key")
  if key.contains(":") {
    raise NrrdError("key:=value: key must not contain ':'")
  }
  if key.get_char(0) == Some('#') {
    raise NrrdError("key:=value: key must not start with '#' (would be a comment)")
  }
  if is_standard_field_id(normalize_field_name(key)) {
    raise NrrdError(
      "key:=value: key '\{key}' collides with a standard field name",
    )
  }
  let out = StringBuilder()
  out.write_string(key)
  out.write_string(":=")
  let mut i = 0
  while i < value.length() {
    match value.get_char(i) {
      Some(c) => {
        let v = c.to_int()
        if v > 127 {
          raise NrrdError(
            "key:=value: non-ASCII code point \{v.to_string()} in value is not representable (write strings are ASCII only)",
          )
        }
        if c == '\\' {
          out.write_string("\\\\")
        } else if c == '\n' {
          out.write_string("\\n")
        } else if v < 32 {
          raise NrrdError(
            "key:=value: control character \{v.to_string()} in value is not representable",
          )
        } else {
          out.write_char(c)
        }
      }
      None => raise NrrdError(
        "key:=value: invalid UTF-16 code unit at index \{i.to_string()} in value",
      )
    }
    i = i + 1
  }
  out.to_string()
}

///| Validate the pieces of a header that affect serialization
///| legality (type/encoding support, skip rejection, endian form).
fn check_writable(h : NrrdHeader) -> Unit raise NrrdError {
  if h.line_skip != 0 || h.byte_skip != 0 {
    raise NrrdError(
      "line skip/byte skip are not supported (got \{h.line_skip}/\{h.byte_skip})",
    )
  }
  let t = normalize_type(h.type_name)
  let e = normalize_encoding(h.encoding)
  check_supported_type(t)
  check_supported_encoding(e)
  match h.endian {
    Some(en) => {
      let low = en.to_lower()
      if low != "little" && low != "big" {
        raise NrrdError("endian must be little|big, got '\{en}'")
      }
    }
    None => ()
  }
}

///| Serialize an NRRD0005 header. Validates the header (structure
///| and spatial legality) and every string field against injection
///| (see module doc) before emitting anything. Unknown fields and
///| key:=value pairs are not carried by NrrdHeader and are never
///| replayed here.
pub fn format_header(h : NrrdHeader) -> String raise NrrdError {
  // v1 ASCII write contract checked uniformly on every writable
  // string BEFORE semantic validation or formatting (必修 1): a
  // non-ASCII code point must always raise, regardless of which
  // field carries it or what other legality rules apply.
  match h.data_file {
    Some(name) => check_line_value_trimmed(name, "data file")
    None => ()
  }
  match h.content {
    Some(c) => check_line_value_trimmed(c, "content")
    None => ()
  }
  match h.space {
    Some(sp) => check_line_value_trimmed(sp, "space")
    None => ()
  }
  match h.labels {
    Some(ls) =>
      for s in ls {
        check_line_value(s, "labels")
      }
    None => ()
  }
  match h.space_units {
    Some(us) =>
      for s in us {
        check_line_value(s, "space units")
      }
    None => ()
  }
  match h.kinds {
    Some(ks) =>
      for s in ks {
        check_line_value(s, "kinds")
      }
    None => ()
  }
  validate_header(h)
  check_writable(h)
  let t = normalize_type(h.type_name)
  let e = normalize_encoding(h.encoding)
  let out = StringBuilder()
  out.write_string("NRRD0005\n")
  out.write_string("type: \{t}\n")
  out.write_string("dimension: \{h.dimension.to_string()}\n")
  out.write_string("sizes: \{format_int_list(h.sizes)}\n")
  out.write_string("encoding: \{e}\n")
  match h.endian {
    Some(en) => out.write_string("endian: \{en.to_lower()}\n")
    None => ()
  }
  match h.space {
    Some(sp) => {
      check_line_value_trimmed(sp, "space")
      out.write_string("space: \{sp}\n")
    }
    None => ()
  }
  match h.space_dimension {
    Some(sd) => out.write_string("space dimension: \{sd.to_string()}\n")
    None => ()
  }
  match h.space_origin {
    Some(o) => out.write_string("space origin: \{format_spatial_vec(o, "space origin")}\n")
    None => ()
  }
  if !h.space_directions.is_empty() {
    out.write_string("space directions: \{format_directions_value(h.space_directions)}\n")
  }
  match h.space_units {
    Some(us) => out.write_string("space units: \{format_quoted_list(us, "space units")}\n")
    None => ()
  }
  match h.kinds {
    Some(ks) => out.write_string("kinds: \{format_bare_list(ks, "kinds")}\n")
    None => ()
  }
  match h.labels {
    Some(ls) => out.write_string("labels: \{format_quoted_list(ls, "labels")}\n")
    None => ()
  }
  match h.content {
    Some(c) => out.write_string("content: \{c}\n")
    None => ()
  }
  match h.data_file {
    Some(name) => out.write_string("data file: \{name}\n")
    None => ()
  }
  out.to_string()
}

///| Space-separated decimal integers for `sizes` / similar lists.
fn format_int_list(xs : Array[Int]) -> String {
  let out = StringBuilder()
  let mut first = true
  for x in xs {
    if !first {
      out.write_string(" ")
    }
    out.write_string(x.to_string())
    first = false
  }
  out.to_string()
}

///| Special-value tokens shared by the ASCII float writers
///| (spec §2 substring rules write-side subset): nan / inf / -inf /
///| signed zero. Returns None for non-zero finite values.
fn ascii_special_token(d : Double) -> String? {
  if d.is_nan() {
    Some("nan")
  } else if d.is_pos_inf() {
    Some("inf")
  } else if d.is_neg_inf() {
    Some("-inf")
  } else if d == 0.0 {
    Some(if is_neg_zero(d) { "-0.0" } else { "0.0" })
  } else {
    None
  }
}

///| Parse a plain/scientific decimal string into (neg, digits, exp)
///| with value = 0.digits * 10^exp, digits without leading/trailing
///| zeros ("0" for zero). Handles the forms Double::to_string emits.
fn parse_decimal_spec(s : String) -> (Bool, String, Int)? {
  let n = s.length()
  let mut i = 0
  let mut neg = false
  if i < n && (char_at(s, i) == '-' || char_at(s, i) == '+') {
    neg = char_at(s, i) == '-'
    i = i + 1
  }
  let int_start = i
  while i < n && char_at(s, i).is_ascii_digit() {
    i = i + 1
  }
  let int_len = i - int_start
  let mut frac_start = i
  let mut frac_len = 0
  if i < n && char_at(s, i) == '.' {
    i = i + 1
    frac_start = i
    while i < n && char_at(s, i).is_ascii_digit() {
      i = i + 1
    }
    frac_len = i - frac_start
  }
  if int_len == 0 && frac_len == 0 {
    return None
  }
  let mut e_add = 0
  if i < n && (char_at(s, i) == 'e' || char_at(s, i) == 'E') {
    i = i + 1
    let mut e_neg = false
    if i < n && (char_at(s, i) == '-' || char_at(s, i) == '+') {
      e_neg = char_at(s, i) == '-'
      i = i + 1
    }
    let e_start = i
    while i < n && char_at(s, i).is_ascii_digit() {
      i = i + 1
    }
    if i == e_start {
      return None
    }
    match parse_int_str(slice_str(s, e_start, i)) {
      Some(v) => e_add = if e_neg { 0 - v } else { v }
      None => return None
    }
  }
  if i != n {
    return None
  }
  // digits = int part + frac part, then strip leading/trailing zeros
  let digits = StringBuilder()
  let mut k = int_start
  while k < int_start + int_len {
    digits.write_char(char_at(s, k))
    k = k + 1
  }
  k = frac_start
  while k < frac_start + frac_len {
    digits.write_char(char_at(s, k))
    k = k + 1
  }
  let raw = digits.to_string()
  let mut lead = 0
  while lead < raw.length() && char_at(raw, lead) == '0' {
    lead = lead + 1
  }
  if lead == raw.length() {
    // zero: KEEP the sign (必修 2 — dropping it here turned a
    // negative-zero candidate into a sign-less "0")
    return Some((neg, "0", 0))
  }
  let mut trail = raw.length()
  while trail > lead && char_at(raw, trail - 1) == '0' {
    trail = trail - 1
  }
  let core = slice_str(raw, lead, trail)
  // 0.raw * 10^(int_len + e_add); stripping `lead` zeros divides by 10^lead
  let exp = int_len + e_add - lead
  Some((neg, core, exp))
}

///| Rebuild a decimal string from (digits, exp), value =
///| 0.digits * 10^exp. Plain form for moderate exponents, otherwise
///| `d[.rest]e[+-]X`.
fn build_decimal(neg : Bool, digits : String, exp : Int) -> String {
  let out = StringBuilder()
  if neg {
    out.write_string("-")
  }
  let e1 = exp - 1 // d1.d2... * 10^e1
  if e1 >= -5 && e1 <= 20 {
    if exp >= 1 {
      if digits.length() >= exp {
        out.write_string(slice_str(digits, 0, exp))
        if digits.length() > exp {
          out.write_string(".")
          out.write_string(slice_str(digits, exp, digits.length()))
        }
      } else {
        out.write_string(digits)
        let mut z = digits.length()
        while z < exp {
          out.write_string("0")
          z = z + 1
        }
      }
    } else {
      out.write_string("0.")
      let mut z = exp
      while z < 0 {
        out.write_string("0")
        z = z + 1
      }
      out.write_string(digits)
    }
  } else {
    out.write_string(slice_str(digits, 0, 1))
    if digits.length() > 1 {
      out.write_string(".")
      out.write_string(slice_str(digits, 1, digits.length()))
    }
    out.write_string("e")
    if e1 >= 0 {
      out.write_string("+")
    }
    out.write_string(e1.to_string())
  }
  out.to_string()
}

///| Round the decimal string `s` to `k` significant digits
///| (round-half-up on the dropped prefix; the caller verifies the
///| result by parsing back, so the tie rule is not load-bearing).
///| Returns None if `s` is not a plain/scientific decimal.
fn round_sig_str(s : String, k : Int) -> String? {
  match parse_decimal_spec(s) {
    Some((neg, digits, exp)) => {
      if digits == "0" || digits.length() <= k {
        return Some(if digits == "0" && !neg { "0" } else { build_decimal(neg, digits, exp) })
      }
      let prefix = slice_str(digits, 0, k)
      let round_up = char_at(digits, k) >= '5'
      let mut core = prefix
      let mut exp2 = exp
      if round_up {
        // increment the k-digit prefix as a decimal integer
        let chars = Array::make(k, '0')
        let mut i = 0
        while i < k {
          chars[i] = char_at(prefix, i)
          i = i + 1
        }
        let mut j = k - 1
        let mut carry = true
        while carry && j >= 0 {
          if chars[j] == '9' {
            chars[j] = '0'
            j = j - 1
          } else {
            chars[j] = (chars[j].to_int() + 1).unsafe_to_char()
            carry = false
          }
        }
        if carry {
          // 999... -> 1000... with an extra digit: normalize to 1 * 10^exp
          core = "1"
          exp2 = exp + 1
        } else {
          core = String::from_array(chars)
        }
      }
      // strip trailing zeros ("1200" -> "12"; 0.x * 10^exp is unchanged)
      let mut trail = core.length()
      while trail > 1 && char_at(core, trail - 1) == '0' {
        trail = trail - 1
      }
      core = slice_str(core, 0, trail)
      Some(build_decimal(neg, core, exp2))
    }
    None => None
  }
}

///| Shortest decimal round-trip token for one binary32 value under
///| the READER's two-step parse (decimal -> binary64 -> binary32 via
///| `Float::from_double`). The input double is first reduced to its
///| nearest binary32 (ties-to-even; overflow saturates to +-inf,
///| underflow keeps the sign of zero) — the token describes THAT
///| stored value, so zero/inf/nan are decided AFTER narrowing
///| (必修 2: deciding specials on the pre-narrow double loses the
///| sign of a negative underflow like -1.0e-50 -> -0.0). Candidate
///| strings are verified by parsing back through the exact read
///| path with sign-aware comparison (f32_step_eq), so the result
///| round-trips by construction (cross-check with
///| tests/fixtures/double_rounding_case.json).
fn ascii_float32_token(v : Double) -> String {
  let w = Float::to_double(Float::from_double(v))
  match ascii_special_token(w) {
    Some(t) => t
    None => {
      let full = w.to_string()
      let mut k = 1
      while k <= 17 {
        match round_sig_str(full, k) {
          Some(tok) => match parse_double_str(tok) {
            Some(p) =>
              if f32_step_eq(p, w) {
                return tok
              }
            None => ()
          }
          None => ()
        }
        k = k + 1
      }
      // 17 significant digits always round-trip a binary32 widened
      // to binary64; fall back to the binary64 shortest repr.
      normalize_numeric_string(full)
    }
  }
}

///| Candidate check for the float32 ASCII writer: parse the decimal
///| token back through the reader's two-step parse and compare to
///| the stored binary32 `w`. Equal as float32 AND, when both are
///| zero, the sign of zero must match (IEEE `==` alone treats
///| +0.0 == -0.0 as equal and would accept a sign-losing token).
fn f32_step_eq(parsed : Double, w : Double) -> Bool {
  let got = Float::to_double(Float::from_double(parsed))
  if got == 0.0 && w == 0.0 {
    is_neg_zero(got) == is_neg_zero(w)
  } else {
    got == w
  }
}

///| ASCII token for a binary64 value: shortest round-trip string.
fn ascii_double_token_out(d : Double) -> String {
  match ascii_special_token(d) {
    Some(t) => t
    None => normalize_numeric_string(d.to_string())
  }
}

///| One ASCII data token for canonical type `t`. Integers go through
///| exact Int64 decimal formatting (never a lossy float format).
fn ascii_encode_token(d : Double, t : String) -> String raise NrrdError {
  match t {
    "float" => ascii_float32_token(d)
    "double" => ascii_double_token_out(d)
    _ => integer_bits(d, t).to_string()
  }
}

///| Encode values to an NRRD payload (file order: sizes[0] fastest).
///| Validates the header independently of parse_header (callers may
///| construct headers directly). `values.length()` must equal the
///| sizes product. Raw multi-byte data requires an explicit endian;
///| ASCII ignores endian. Integers reject non-integral / NaN / inf /
///| out-of-range values (G2 v2 §7.1).
pub fn encode_data(
  values : Array[Double],
  header : NrrdHeader,
  budget~ : Int = max_encode_elements(),
) -> Bytes raise NrrdError {
  validate_header(header)
  if header.line_skip != 0 || header.byte_skip != 0 {
    raise NrrdError(
      "line skip/byte skip are not supported (got \{header.line_skip}/\{header.byte_skip})",
    )
  }
  let t = normalize_type(header.type_name)
  let e = normalize_encoding(header.encoding)
  check_supported_type(t)
  check_supported_encoding(e)
  let count = product_count(header.sizes)
  if e == "raw" {
    let item = item_size(t)
    // division-style pre-check: `count * item` must not wrap Int
    if count < 0 || count > 2147483647 / item {
      raise NrrdError("byte length overflow: \{count} x \{item} bytes")
    }
  }
  if count > budget {
    raise NrrdError(
      "refusing to encode \{count} elements; allocation budget is \{budget}",
    )
  }
  if values.length() != count {
    raise NrrdError(
      "sizes product \{count} does not match values length \{values.length()}",
    )
  }
  match e {
    "raw" => {
      let item = item_size(t)
      let big = match header.endian {
        Some(en) => match en.to_lower() {
          "big" => true
          "little" => false
          _ => raise NrrdError("endian must be little|big, got '\{en}'")
        }
        None => {
          if item > 1 {
            raise NrrdError("raw multi-byte data missing endian field")
          }
          false
        }
      }
      let need = count * item
      let out : Array[Byte] = Array::make(need, b'\x00')
      let mut i = 0
      while i < count {
        write_bits(out, i * item, raw_value_bits(values[i], t), item, big)
        i = i + 1
      }
      Bytes::from_array(out)
    }
    "ascii" => {
      let out = StringBuilder()
      let mut i = 0
      while i < count {
        if i > 0 {
          out.write_string(" ")
        }
        out.write_string(ascii_encode_token(values[i], t))
        i = i + 1
      }
      out.write_string("\n")
      ascii_to_bytes(out.to_string())
    }
    _ => raise NrrdError("unreachable encoding")
  }
}

///| Concatenate two byte strings (header text + payload).
fn concat_bytes(a : Bytes, b : Bytes) -> Bytes {
  let n = a.length()
  let m = b.length()
  Bytes::from_array(Array::makei(n + m, i => if i < n { a[i] } else { b[i - n] }))
}

///| Attached NRRD file bytes: header text, the terminating blank
///| line, then the payload. The header must NOT declare a data file.
///| No file IO — the caller decides the file name and writes bytes.
pub fn assemble_attached(
  h : NrrdHeader,
  values : Array[Double],
  budget~ : Int = max_encode_elements(),
) -> Bytes raise NrrdError {
  match h.data_file {
    Some(_) => raise NrrdError(
      "attached output must not declare a data file (host chose attached layout)",
    )
    None => ()
  }
  let head = format_header(h)
  let payload = encode_data(values, h, budget = budget)
  concat_bytes(ascii_to_bytes(head + "\n"), payload)
}

///| Detached output: (header bytes, payload bytes). The header MUST
///| declare a data file name (host-assigned; the core just repeats it
///| — keeping the name consistent with what the host writes next to
///| the header is the host's responsibility). The header bytes end
///| with the terminating blank line, like an attached header.
pub fn assemble_detached(
  h : NrrdHeader,
  values : Array[Double],
  budget~ : Int = max_encode_elements(),
) -> (Bytes, Bytes) raise NrrdError {
  match h.data_file {
    None => raise NrrdError(
      "detached output requires a data file name (host-assigned)",
    )
    Some(_) => ()
  }
  let head = format_header(h)
  let payload = encode_data(values, h, budget = budget)
  (ascii_to_bytes(head + "\n"), payload)
}
