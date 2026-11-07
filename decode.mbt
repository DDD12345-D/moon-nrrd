///| NRRD data payload decoding (G3 read-side).
///| Supported types: int8/uint8/int16/uint16/int32/uint32/float/double
///| over raw (little/big) and ascii, attached or detached payloads.
///| Explicitly rejected: int64/uint64 (excluded from v1), block,
///| hex/gzip/bzip2 encodings, LIST-style data files, line/byte skip.
///| Values are carried as `Double` (all supported types are exactly
///| representable; 64-bit integers are not — that is why they are
///| excluded). Linear order follows the file: fastest axis = sizes[0].

///| Allocation budget: refuse to materialize more than 2^24
///| elements (16M). Checked BEFORE the value-array allocation as
///| a defensive lower bound — it bounds the element count only.
///| It is NOT an OOM-impossibility proof: peak memory may exceed
///| count×8 bytes (per-element overhead, intermediate arrays,
///| ASCII token buffers), and a wasm OOM is a trap that cannot be
///| caught, so the guard must be upfront. Overridable via
///| `budget~` for restricted hosts (G2 v2 §7.2).
fn max_decode_elements() -> Int {
  16777216
}

///| Per-token working-memory cap for streaming ASCII parsing.
///| IMPLEMENTATION LIMIT, not a format-illegality judgment: the
///| NRRD format itself does not cap token length; this reader
///| rejects tokens longer than 64 bytes as its own documented
///| boundary (see tests/README.md "已知口径边界").
fn max_token_bytes() -> Int {
  64
}

///|
fn product_count(sizes : Array[Int]) -> Int raise NrrdError {
  let mut acc = 1
  for s in sizes {
    if s <= 0 {
      raise NrrdError("non-positive size")
    }
    if acc > 2147483647 / s {
      raise NrrdError("dimension product overflows; refusing to allocate")
    }
    acc = acc * s
  }
  acc
}

///| Raw item size in bytes per canonical type name.
fn item_size(t : String) -> Int raise NrrdError {
  match t {
    "int8" | "uint8" => 1
    "int16" | "uint16" => 2
    "int32" | "uint32" | "float" => 4
    "double" => 8
    _ => raise NrrdError("no item size for type '\{t}'")
  }
}

///| Decode-side type policy (G3 read-side): the eight planned types
///| pass; int64/uint64/block are explicitly rejected, not silently
///| mangled. 64-bit integers exceed the Double value carrier (2^53).
fn check_supported_type(t : String) -> Unit raise NrrdError {
  match t {
    "int8" | "uint8" | "int16" | "uint16" | "int32" | "uint32" | "float" |
    "double" => ()
    "int64" | "uint64" => raise NrrdError(
      "type '\{t}' excluded from v1: 64-bit integers exceed the Double value carrier",
    )
    "block" => raise NrrdError("type 'block' is not supported")
    _ => raise NrrdError("unsupported type '\{t}'")
  }
}

///| Decode-side encoding policy: raw/ascii pass; everything else
///| is explicitly rejected with a clear message.
fn check_supported_encoding(e : String) -> Unit raise NrrdError {
  match e {
    "raw" | "ascii" => ()
    "hex" => raise NrrdError("encoding 'hex' is not supported (explicitly rejected)")
    "gzip" | "bzip2" => raise NrrdError(
      "encoding '\{e}' is not supported (explicitly rejected)",
    )
    _ => raise NrrdError("unsupported encoding '\{e}'")
  }
}

///|
fn is_ws_byte(b : Byte) -> Bool {
  b == b' ' || b == b'\t' || b == b'\r' || b == b'\n' || b == b'\x0b' || b == b'\x0c'
}

///| Assemble `n` (1..8) bytes at `at` into the low bytes of an
///| Int64 bit pattern (unsigned). `big` selects byte order.
fn read_bits(data : Bytes, at : Int, n : Int, big : Bool) -> Int64 {
  let mut acc = 0L
  if big {
    let mut i = 0
    while i < n {
      acc = acc * 256L + data[at + i].to_int().to_int64()
      i = i + 1
    }
  } else {
    let mut i = n - 1
    while i >= 0 {
      acc = acc * 256L + data[at + i].to_int().to_int64()
      i = i - 1
    }
  }
  acc
}

///| Two's-complement sign extension of an `nbytes`-wide pattern.
fn sign_extend(bits : Int64, nbytes : Int) -> Int64 {
  let shift = 64 - nbytes * 8
  (bits << shift) >> shift
}

///| One raw value at `at` for canonical type `t`.
///| NaN payload/signaling bits are NOT guaranteed to survive the
///| Double carrier (G2 v2 §7.1 narrowed claim): compare NaN
///| semantically; finite values and -0.0 are bit-exact.
fn raw_value(data : Bytes, at : Int, t : String, big : Bool) -> Double {
  match t {
    "int8" => sign_extend(read_bits(data, at, 1, big), 1).to_double()
    "uint8" => read_bits(data, at, 1, big).to_double()
    "int16" => sign_extend(read_bits(data, at, 2, big), 2).to_double()
    "uint16" => read_bits(data, at, 2, big).to_double()
    "int32" => sign_extend(read_bits(data, at, 4, big), 4).to_double()
    "uint32" => read_bits(data, at, 4, big).to_double()
    "float" => Float::to_double(
      Float::reinterpret_from_int(read_bits(data, at, 4, big).to_int()),
    )
    _ => Int64::reinterpret_as_double(read_bits(data, at, 8, big)) // double
  }
}

///| Inclusive integer range per canonical integer type (Int64 bounds).
fn int_value_range(t : String) -> (Int64, Int64) raise NrrdError {
  match t {
    "int8" => (-128L, 127L)
    "uint8" => (0L, 255L)
    "int16" => (-32768L, 32767L)
    "uint16" => (0L, 65535L)
    "int32" => (-2147483648L, 2147483647L)
    "uint32" => (0L, 4294967295L)
    _ => raise NrrdError("not an integer type: '\{t}'")
  }
}

///| Decode `count` raw values (little/big endian) into an array.
fn decode_raw(
  data : Bytes,
  count : Int,
  t : String,
  big : Bool,
) -> Array[Double] raise NrrdError {
  let item = item_size(t)
  // Division-style check first: `count * item` itself must not
  // overflow Int, otherwise a huge count could wrap the product
  // negative and silently pass the truncation check below.
  if count < 0 || count > 2147483647 / item {
    raise NrrdError("byte length overflow: \{count} x \{item} bytes")
  }
  let need = count * item
  if data.length() < need {
    raise NrrdError(
      "truncated data: need \{need} bytes, have \{data.length()}",
    )
  }
  let out : Array[Double] = []
  let mut at = 0
  let mut n = 0
  while n < count {
    out.push(raw_value(data, at, t, big))
    at = at + item
    n = n + 1
  }
  out
}

///| ASCII float32 value: spec §2 nan/-inf/inf substring rules,
///| then rounded to binary32 (NRRD "float"). Range contract: the
///| path is decimal → binary64 → binary32 (two roundings); it is
///| NOT claimed to be correctly rounded for every decimal literal
///| — extreme literals can differ from direct decimal → binary32
///| (case in tests/fixtures/double_rounding_case.json). Overflow
///| saturates to ±inf, matching numpy float32 parsing.
fn ascii_float_token(tok : String) -> Double raise NrrdError {
  let t = tok.to_lower()
  if t.contains("nan") {
    return @double.not_a_number
  }
  if t.contains("-inf") {
    return @double.neg_infinity
  }
  if t.contains("inf") {
    return @double.infinity
  }
  match parse_double_str(tok) {
    Some(v) => Float::to_double(Float::from_double(v))
    None => raise NrrdError("ascii: cannot parse float '\{tok}'")
  }
}

///| ASCII binary64 value: same special-value rules; finite values
///| are kept as parsed (the decimal literal's nearest binary64).
fn ascii_double_token(tok : String) -> Double raise NrrdError {
  let t = tok.to_lower()
  if t.contains("nan") {
    return @double.not_a_number
  }
  if t.contains("-inf") {
    return @double.neg_infinity
  }
  if t.contains("inf") {
    return @double.infinity
  }
  match parse_double_str(tok) {
    Some(v) => v
    None => raise NrrdError("ascii: cannot parse double '\{tok}'")
  }
}

///| ASCII integer value with per-type range check. Values outside
///| the type range (including uint32's high half via the Int64
///| parser) are rejected — never silently truncated.
fn ascii_int_token(tok : String, t : String) -> Double raise NrrdError {
  match parse_int64_str(tok) {
    Some(v) => {
      let (lo, hi) = int_value_range(t)
      if v < lo || v > hi {
        raise NrrdError("ascii: \{t} value out of range: '\{tok}'")
      }
      v.to_double()
    }
    None => raise NrrdError("ascii: cannot parse \{t} value '\{tok}'")
  }
}

///|
fn ascii_value_token(tok : String, t : String) -> Double raise NrrdError {
  match t {
    "float" => ascii_float_token(tok)
    "double" => ascii_double_token(tok)
    _ => ascii_int_token(tok, t)
  }
}

///| Streaming ASCII decode: scans whitespace-separated tokens one
///| at a time (no full token array is materialized; working memory
///| is one token string + the output array). Token length and value
///| count are budgeted; extra or missing values are errors.
fn decode_ascii(
  data : Bytes,
  count : Int,
  t : String,
) -> Array[Double] raise NrrdError {
  let out : Array[Double] = []
  let n = data.length()
  let mut i = 0
  let mut k = 0
  while i < n {
    while i < n && is_ws_byte(data[i]) {
      i = i + 1
    }
    if i >= n {
      break
    }
    let start = i
    while i < n && !is_ws_byte(data[i]) {
      i = i + 1
    }
    let len = i - start
    if len > max_token_bytes() {
      raise NrrdError("ascii: numeric token too long (\{len} bytes)")
    }
    if k >= count {
      raise NrrdError("ascii: expected \{count} values, found more")
    }
    let tok = bytes_to_ascii(
      Bytes::from_array(Array::makei(len, j => data[start + j])),
    )
    out.push(ascii_value_token(tok, t))
    k = k + 1
  }
  if k != count {
    raise NrrdError("ascii: expected \{count} values, found \{k}")
  }
  out
}

///| Decode an NRRD data payload into values in file (linear) order.
///| Validates the header independently of parse_header (callers may
///| construct headers directly), enforces type/encoding policy,
///| line/byte-skip rejection and the element budget before any
///| allocation. ASCII token length is capped at 64 bytes — an
///| implementation limit of this reader, not an NRRD-format
///| illegality judgment (see README.md).
pub fn decode_data(
  data : Bytes,
  header : NrrdHeader,
  budget~ : Int = max_decode_elements(),
) -> Array[Double] raise NrrdError {
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
  if count > budget {
    raise NrrdError(
      "refusing to decode \{count} elements; allocation budget is \{budget}",
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
      decode_raw(data, count, t, big)
    }
    "ascii" => decode_ascii(data, count, t)
    _ => raise NrrdError("unreachable encoding")
  }
}
