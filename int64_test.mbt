///| int64 / uint64 lossless round-trip tests.
///| Verifies that 2^53+1, INT64_MIN/MAX and UINT64_MAX survive
///| decode -> encode -> decode without any Double intermediary.
///| Covers raw LE, raw BE, and ascii for both types.
///| Blackbox: only the public API is exercised.

///| Minimal int64/uint64 header factory.
fn i64_hdr(
  type_name : String,
  encoding : String,
  n : Int,
  endian~ : String? = None,
) -> @moon-nrrd.NrrdHeader {
  @moon-nrrd.NrrdHeader::{
    dimension: 1,
    sizes: [n],
    type_name: type_name,
    encoding: encoding,
    endian: endian,
    data_file: None,
    space: None,
    space_dimension: None,
    space_origin: None,
    space_directions: [],
    space_units: None,
    labels: None,
    kinds: None,
    content: None,
    line_skip: 0,
    byte_skip: 0,
    list_filenames: None,
    data_file_subdim: None,
  }
}

// ── Key test values ──────────────────────────────────────────────
// 2^53 + 1  — the smallest integer NOT representable as Double
// INT64_MIN — signed 64-bit minimum (cannot be written as a single
//             MoonBit Int64 literal; computed as -2^63)
// INT64_MAX — signed 64-bit maximum
// UINT64_MAX — unsigned 64-bit maximum

fn val_2p53_plus_1() -> Int64 {
  9007199254740993L
}

fn val_i64_min() -> Int64 {
  -9223372036854775807L - 1L
}

fn val_i64_max() -> Int64 {
  9223372036854775807L
}

fn val_u64_max() -> UInt64 {
  (-1L).reinterpret_as_uint64()
}

// ── int64 round-trip helpers ─────────────────────────────────────

///| Encode -> decode -> compare. Returns "" on success, error otherwise.
fn i64_roundtrip_err(
  values : Array[Int64],
  h : @moon-nrrd.NrrdHeader,
) -> String {
  try {
    let encoded = @moon-nrrd.encode_int64(values, h)
    let decoded = @moon-nrrd.decode_int64(encoded, h)
    if decoded.length() != values.length() {
      return "length mismatch: \{decoded.length()} vs \{values.length()}"
    }
    for idx = 0; idx < values.length(); idx = idx + 1 {
      if decoded[idx] != values[idx] {
        return "value[\{idx}] mismatch: \{decoded[idx]} vs \{values[idx]}"
      }
    }
    ""
  } catch {
    @moon-nrrd.NrrdError(m) => m
  }
}

///| Encode -> decode -> compare for uint64.
fn u64_roundtrip_err(
  values : Array[UInt64],
  h : @moon-nrrd.NrrdHeader,
) -> String {
  try {
    let encoded = @moon-nrrd.encode_uint64(values, h)
    let decoded = @moon-nrrd.decode_uint64(encoded, h)
    if decoded.length() != values.length() {
      return "length mismatch: \{decoded.length()} vs \{values.length()}"
    }
    for idx = 0; idx < values.length(); idx = idx + 1 {
      if decoded[idx] != values[idx] {
        return "value[\{idx}] mismatch"
      }
    }
    ""
  } catch {
    @moon-nrrd.NrrdError(m) => m
  }
}

// ── int64 raw LE ─────────────────────────────────────────────────

test "int64 raw LE roundtrip: key values" {
  let values = [
    val_2p53_plus_1(),
    val_i64_min(),
    val_i64_max(),
    0L,
    -1L,
    1L,
  ]
  let h = i64_hdr("int64", "raw", values.length(), endian=Some("little"))
  let err = i64_roundtrip_err(values, h)
  assert_eq(err, "")
}

test "int64 raw LE: 2^53+1 bit-exact" {
  let v = [val_2p53_plus_1()]
  let h = i64_hdr("int64", "raw", 1, endian=Some("little"))
  try {
    let enc = @moon-nrrd.encode_int64(v, h)
    assert_eq(enc.length(), 8)
    // LE bytes of 9007199254740993 = 0x20000000000001
    // bytes LE: 01 00 00 00 00 00 20 00
    assert_eq(enc[0], b'\x01')
    assert_eq(enc[6], b'\x20')
    let dec = @moon-nrrd.decode_int64(enc, h)
    assert_eq(dec[0], val_2p53_plus_1())
  } catch {
    @moon-nrrd.NrrdError(m) => fail(m)
    _ => fail("unexpected error")
  }
}

test "int64 raw LE: INT64_MIN bit-exact" {
  let v = [val_i64_min()]
  let h = i64_hdr("int64", "raw", 1, endian=Some("little"))
  try {
    let enc = @moon-nrrd.encode_int64(v, h)
    assert_eq(enc.length(), 8)
    // LE bytes of -2^63 = 0x8000000000000000
    // bytes LE: 00 00 00 00 00 00 00 80
    assert_eq(enc[7], b'\x80')
    let dec = @moon-nrrd.decode_int64(enc, h)
    assert_eq(dec[0], val_i64_min())
  } catch {
    @moon-nrrd.NrrdError(m) => fail(m)
    _ => fail("unexpected error")
  }
}

// ── int64 raw BE ─────────────────────────────────────────────────

test "int64 raw BE roundtrip: key values" {
  let values = [
    val_2p53_plus_1(),
    val_i64_min(),
    val_i64_max(),
    0L,
    -1L,
    1L,
  ]
  let h = i64_hdr("int64", "raw", values.length(), endian=Some("big"))
  let err = i64_roundtrip_err(values, h)
  assert_eq(err, "")
}

test "int64 raw BE: INT64_MAX bit-exact" {
  let v = [val_i64_max()]
  let h = i64_hdr("int64", "raw", 1, endian=Some("big"))
  try {
    let enc = @moon-nrrd.encode_int64(v, h)
    assert_eq(enc.length(), 8)
    // BE bytes of 2^63-1 = 0x7FFFFFFFFFFFFFFF
    assert_eq(enc[0], b'\x7f')
    assert_eq(enc[7], b'\xff')
    let dec = @moon-nrrd.decode_int64(enc, h)
    assert_eq(dec[0], val_i64_max())
  } catch {
    @moon-nrrd.NrrdError(m) => fail(m)
    _ => fail("unexpected error")
  }
}

// ── int64 ascii ──────────────────────────────────────────────────

test "int64 ascii roundtrip: key values" {
  let values = [
    val_2p53_plus_1(),
    val_i64_min(),
    val_i64_max(),
    0L,
    -1L,
    1L,
  ]
  let h = i64_hdr("int64", "ascii", values.length())
  let err = i64_roundtrip_err(values, h)
  assert_eq(err, "")
}

test "int64 ascii: INT64_MIN formatting" {
  let v = [val_i64_min()]
  let h = i64_hdr("int64", "ascii", 1)
  try {
    let enc = @moon-nrrd.encode_int64(v, h)
    let s = @moon-nrrd.bytes_to_ascii(enc)
    assert_eq(s, "-9223372036854775808")
    let dec = @moon-nrrd.decode_int64(enc, h)
    assert_eq(dec[0], val_i64_min())
  } catch {
    @moon-nrrd.NrrdError(m) => fail(m)
    _ => fail("unexpected error")
  }
}

test "int64 ascii: 2^53+1 is not 2^53" {
  let v = [val_2p53_plus_1()]
  let h = i64_hdr("int64", "ascii", 1)
  try {
    let enc = @moon-nrrd.encode_int64(v, h)
    let s = @moon-nrrd.bytes_to_ascii(enc)
    assert_eq(s, "9007199254740993") // not "9007199254740992"
  } catch {
    @moon-nrrd.NrrdError(m) => fail(m)
    _ => fail("unexpected error")
  }
}

// ── uint64 raw LE ────────────────────────────────────────────────

test "uint64 raw LE roundtrip: key values" {
  let values = [
    val_u64_max(),
    9007199254740993UL,
    0UL,
    1UL,
    (-1L).reinterpret_as_uint64(), // UINT64_MAX via reinterpret
  ]
  let h = i64_hdr("uint64", "raw", values.length(), endian=Some("little"))
  let err = u64_roundtrip_err(values, h)
  assert_eq(err, "")
}

test "uint64 raw LE: UINT64_MAX bit-exact" {
  let v = [val_u64_max()]
  let h = i64_hdr("uint64", "raw", 1, endian=Some("little"))
  try {
    let enc = @moon-nrrd.encode_uint64(v, h)
    assert_eq(enc.length(), 8)
    // LE bytes of 2^64-1: all 0xFF
    for idx = 0; idx < 8; idx = idx + 1 {
      assert_eq(enc[idx], b'\xff')
    }
    let dec = @moon-nrrd.decode_uint64(enc, h)
    assert_eq(dec[0], val_u64_max())
  } catch {
    @moon-nrrd.NrrdError(m) => fail(m)
    _ => fail("unexpected error")
  }
}

// ── uint64 raw BE ────────────────────────────────────────────────

test "uint64 raw BE roundtrip: key values" {
  let values = [
    val_u64_max(),
    9007199254740993UL,
    0UL,
    1UL,
  ]
  let h = i64_hdr("uint64", "raw", values.length(), endian=Some("big"))
  let err = u64_roundtrip_err(values, h)
  assert_eq(err, "")
}

// ── uint64 ascii ─────────────────────────────────────────────────

test "uint64 ascii roundtrip: key values" {
  let values = [
    val_u64_max(),
    9007199254740993UL,
    0UL,
    1UL,
  ]
  let h = i64_hdr("uint64", "ascii", values.length())
  let err = u64_roundtrip_err(values, h)
  assert_eq(err, "")
}

test "uint64 ascii: UINT64_MAX formatting" {
  let v = [val_u64_max()]
  let h = i64_hdr("uint64", "ascii", 1)
  try {
    let enc = @moon-nrrd.encode_uint64(v, h)
    let s = @moon-nrrd.bytes_to_ascii(enc)
    assert_eq(s, "18446744073709551615")
  } catch {
    @moon-nrrd.NrrdError(m) => fail(m)
    _ => fail("unexpected error")
  }
}

test "uint64 ascii: 2^53+1 preserved" {
  let v = [9007199254740993UL]
  let h = i64_hdr("uint64", "ascii", 1)
  try {
    let enc = @moon-nrrd.encode_uint64(v, h)
    let s = @moon-nrrd.bytes_to_ascii(enc)
    assert_eq(s, "9007199254740993")
    let dec = @moon-nrrd.decode_uint64(enc, h)
    assert_eq(dec[0], 9007199254740993UL)
  } catch {
    @moon-nrrd.NrrdError(m) => fail(m)
    _ => fail("unexpected error")
  }
}

// ── parse_uint64_str unit tests ──────────────────────────────────

test "parse_uint64_str: normal values" {
  assert_eq(@moon-nrrd.parse_uint64_str("0"), Some(0UL))
  assert_eq(@moon-nrrd.parse_uint64_str("1"), Some(1UL))
  assert_eq(
    @moon-nrrd.parse_uint64_str("9007199254740993"),
    Some(9007199254740993UL),
  )
  assert_eq(
    @moon-nrrd.parse_uint64_str("18446744073709551615"),
    Some(val_u64_max()),
  )
}

test "parse_uint64_str: rejects negative" {
  assert_eq(@moon-nrrd.parse_uint64_str("-1"), None)
}

test "parse_uint64_str: rejects overflow" {
  assert_eq(@moon-nrrd.parse_uint64_str("18446744073709551616"), None)
}

test "parse_uint64_str: rejects empty and garbage" {
  assert_eq(@moon-nrrd.parse_uint64_str(""), None)
  assert_eq(@moon-nrrd.parse_uint64_str("abc"), None)
  assert_eq(@moon-nrrd.parse_uint64_str("12a"), None)
  assert_eq(@moon-nrrd.parse_uint64_str("+"), None)
}

// ── Cross-type rejection ─────────────────────────────────────────

test "decode_int64 rejects uint64 header" {
  let h = i64_hdr("uint64", "raw", 1, endian=Some("little"))
  try {
    let _unused = @moon-nrrd.decode_int64(@moon-nrrd.ascii_to_bytes(""), h)
    fail("should have rejected")
  } catch {
    @moon-nrrd.NrrdError(m) => assert_true(m.contains("int64"))
    _ => fail("unexpected error")
  }
}

test "decode_uint64 rejects int64 header" {
  let h = i64_hdr("int64", "raw", 1, endian=Some("little"))
  try {
    let _unused = @moon-nrrd.decode_uint64(@moon-nrrd.ascii_to_bytes(""), h)
    fail("should have rejected")
  } catch {
    @moon-nrrd.NrrdError(m) => assert_true(m.contains("uint64"))
    _ => fail("unexpected error")
  }
}
