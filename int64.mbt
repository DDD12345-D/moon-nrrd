///| 64-bit integer (int64 / uint64) lossless read and write path.
///| Values are carried as native Int64 / UInt64 throughout — never
///| routed through Double — so the full range (including 2^53+1,
///| INT64_MIN/MAX, UINT64_MAX) round-trips bit-exactly.
///|
///| Supported encodings: raw (little/big endian) and ascii.
///| line/byte skip are rejected (same policy as decode_data).
///| Budget: max 2^24 elements (same as decode_data).

///| Verify the header declares the expected 64-bit type and a
///| supported encoding. Returns the element count.
fn check_i64_header(h : NrrdHeader, want : String) -> Int raise NrrdError {
  validate_header(h)
  if h.line_skip != 0 || h.byte_skip != 0 {
    raise NrrdError(
      "line skip/byte skip are not supported (got \{h.line_skip}/\{h.byte_skip})",
    )
  }
  let t = normalize_type(h.type_name)
  if t != want {
    raise NrrdError("expected type '\{want}', got '\{t}'")
  }
  let e = normalize_encoding(h.encoding)
  check_supported_encoding(e)
  product_count(h.sizes)
}

///| Byte-order flag from the header's endian field. 64-bit types are
///| multi-byte so endian must be present for raw encoding.
fn i64_endian(h : NrrdHeader) -> Bool raise NrrdError {
  match h.endian {
    Some(en) => match en.to_lower() {
      "big" => true
      "little" => false
      _ => raise NrrdError("endian must be little|big, got '\{en}'")
    }
    None => raise NrrdError("raw 64-bit data missing endian field")
  }
}

///| Parse a decimal digit character to its value (0-9); -1 otherwise.
fn digit_val(c : Char) -> Int {
  let v = c.to_int() - 48
  if v >= 0 && v <= 9 {
    v
  } else {
    -1
  }
}

///| Parse a non-negative decimal string into UInt64. Rejects
///| negative signs and overflow past 2^64-1. Accepts an optional
///| leading '+'. Returns None for empty/invalid input.
pub fn parse_uint64_str(s : String) -> UInt64? {
  let n = s.length()
  if n == 0 {
    return None
  }
  let mut i = 0
  if char_at(s, 0) == '+' {
    i = 1
    if n == 1 {
      return None
    }
  } else if char_at(s, 0) == '-' {
    return None // unsigned type rejects negative
  }
  let max_u64 : UInt64 = (-1L).reinterpret_as_uint64()
  let mut acc = 0UL
  while i < n {
    let d = digit_val(char_at(s, i))
    if d < 0 {
      return None
    }
    let du = d.to_int64().reinterpret_as_uint64()
    // overflow guard: acc * 10 + du <= max
    if acc > (max_u64 - du) / 10UL {
      return None
    }
    acc = acc * 10UL + du
    i = i + 1
  }
  Some(acc)
}

///| Streaming ASCII decode into Int64 tokens.
fn decode_ascii_i64(
  data : Bytes,
  count : Int,
) -> Array[Int64] raise NrrdError {
  let out : Array[Int64] = []
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
    match parse_int64_str(tok) {
      Some(v) => out.push(v)
      None => raise NrrdError("ascii: cannot parse int64 '\{tok}'")
    }
    k = k + 1
  }
  if k != count {
    raise NrrdError("ascii: expected \{count} values, found \{k}")
  }
  out
}

///| Streaming ASCII decode into UInt64 tokens.
fn decode_ascii_u64(
  data : Bytes,
  count : Int,
) -> Array[UInt64] raise NrrdError {
  let out : Array[UInt64] = []
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
    match parse_uint64_str(tok) {
      Some(v) => out.push(v)
      None => raise NrrdError("ascii: cannot parse uint64 '\{tok}'")
    }
    k = k + 1
  }
  if k != count {
    raise NrrdError("ascii: expected \{count} values, found \{k}")
  }
  out
}

///| Decode an NRRD payload of type `int64` into native Int64 values.
///| Supports raw (little/big endian) and ascii encodings.
pub fn decode_int64(
  data : Bytes,
  header : NrrdHeader,
  budget~ : Int = max_decode_elements(),
) -> Array[Int64] raise NrrdError {
  let count = check_i64_header(header, "int64")
  if count > budget {
    raise NrrdError(
      "refusing to decode \{count} elements; allocation budget is \{budget}",
    )
  }
  let e = normalize_encoding(header.encoding)
  match e {
    "raw" => {
      let big = i64_endian(header)
      if count > 2147483647 / 8 {
        raise NrrdError("byte length overflow: \{count} x 8 bytes")
      }
      let need = count * 8
      if data.length() < need {
        raise NrrdError(
          "truncated data: need \{need} bytes, have \{data.length()}",
        )
      }
      let out : Array[Int64] = []
      let mut at = 0
      let mut n = 0
      while n < count {
        // read_bits assembles 8 bytes into the Int64 bit pattern
        // (two's complement) — exactly the signed value we want.
        out.push(read_bits(data, at, 8, big))
        at = at + 8
        n = n + 1
      }
      out
    }
    "ascii" => decode_ascii_i64(data, count)
    _ => raise NrrdError("unreachable encoding")
  }
}

///| Decode an NRRD payload of type `uint64` into native UInt64 values.
///| Supports raw (little/big endian) and ascii encodings.
pub fn decode_uint64(
  data : Bytes,
  header : NrrdHeader,
  budget~ : Int = max_decode_elements(),
) -> Array[UInt64] raise NrrdError {
  let count = check_i64_header(header, "uint64")
  if count > budget {
    raise NrrdError(
      "refusing to decode \{count} elements; allocation budget is \{budget}",
    )
  }
  let e = normalize_encoding(header.encoding)
  match e {
    "raw" => {
      let big = i64_endian(header)
      if count > 2147483647 / 8 {
        raise NrrdError("byte length overflow: \{count} x 8 bytes")
      }
      let need = count * 8
      if data.length() < need {
        raise NrrdError(
          "truncated data: need \{need} bytes, have \{data.length()}",
        )
      }
      let out : Array[UInt64] = []
      let mut at = 0
      let mut n = 0
      while n < count {
        out.push(read_bits(data, at, 8, big).reinterpret_as_uint64())
        at = at + 8
        n = n + 1
      }
      out
    }
    "ascii" => decode_ascii_u64(data, count)
    _ => raise NrrdError("unreachable encoding")
  }
}

///| Encode Int64 values as an NRRD payload for type `int64`.
///| Supports raw (little/big endian) and ascii.
pub fn encode_int64(
  values : Array[Int64],
  header : NrrdHeader,
  budget~ : Int = max_encode_elements(),
) -> Bytes raise NrrdError {
  let count = check_i64_header(header, "int64")
  if values.length() != count {
    raise NrrdError(
      "value count \{values.length()} does not match header product \{count}",
    )
  }
  if count > budget {
    raise NrrdError(
      "refusing to encode \{count} elements; allocation budget is \{budget}",
    )
  }
  let e = normalize_encoding(header.encoding)
  match e {
    "raw" => {
      let big = i64_endian(header)
      if count > 2147483647 / 8 {
        raise NrrdError("byte length overflow: \{count} x 8 bytes")
      }
      let out = Array::make(count * 8, b'\x00')
      let mut at = 0
      for v in values {
        write_bits(out, at, v, 8, big)
        at = at + 8
      }
      Bytes::from_array(out)
    }
    "ascii" => {
      let mut s = ""
      let mut first = true
      for v in values {
        if !first {
          s = s + " "
        }
        first = false
        s = s + v.to_string()
      }
      ascii_to_bytes(s)
    }
    _ => raise NrrdError("unreachable encoding")
  }
}

///| Encode UInt64 values as an NRRD payload for type `uint64`.
///| Supports raw (little/big endian) and ascii.
pub fn encode_uint64(
  values : Array[UInt64],
  header : NrrdHeader,
  budget~ : Int = max_encode_elements(),
) -> Bytes raise NrrdError {
  let count = check_i64_header(header, "uint64")
  if values.length() != count {
    raise NrrdError(
      "value count \{values.length()} does not match header product \{count}",
    )
  }
  if count > budget {
    raise NrrdError(
      "refusing to encode \{count} elements; allocation budget is \{budget}",
    )
  }
  let e = normalize_encoding(header.encoding)
  match e {
    "raw" => {
      let big = i64_endian(header)
      if count > 2147483647 / 8 {
        raise NrrdError("byte length overflow: \{count} x 8 bytes")
      }
      let out = Array::make(count * 8, b'\x00')
      let mut at = 0
      for v in values {
        write_bits(out, at, v.reinterpret_as_int64(), 8, big)
        at = at + 8
      }
      Bytes::from_array(out)
    }
    "ascii" => {
      let mut s = ""
      let mut first = true
      for v in values {
        if !first {
          s = s + " "
        }
        first = false
        s = s + v.to_string()
      }
      ascii_to_bytes(s)
    }
    _ => raise NrrdError("unreachable encoding")
  }
}
