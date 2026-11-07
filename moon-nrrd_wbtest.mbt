///| Whitebox regression tests for the integer parser
///| (overflow must be rejected BEFORE wraparound).

///|
test "parse_int_str accepts normal values and boundaries" {
  assert_true(parse_int_str("0") == Some(0), msg="zero")
  assert_true(parse_int_str("-0") == Some(0), msg="neg zero")
  assert_true(parse_int_str("+7") == Some(7), msg="plus sign")
  assert_true(parse_int_str("32767") == Some(32767), msg="int16 max")
  assert_true(parse_int_str("-32768") == Some(-32768), msg="int16 min")
  assert_true(parse_int_str("2147483647") == Some(2147483647), msg="int max")
  assert_true(parse_int_str("-2147483648") == Some(-2147483648), msg="int min")
}

///| The audit defect: 4294967297 == 2^32 + 1 used to wrap to 1.
test "parse_int_str rejects wraparound and out-of-range values" {
  assert_true(parse_int_str("4294967297") == None, msg="audit: 2^32+1 must be rejected")
  assert_true(parse_int_str("4294967296") == None, msg="2^32 must be rejected")
  assert_true(parse_int_str("-4294967297") == None, msg="negative wraparound")
  assert_true(parse_int_str("2147483648") == None, msg="int max + 1")
  assert_true(parse_int_str("-2147483649") == None, msg="int min - 1")
  assert_true(parse_int_str("99999999999999999999999") == None, msg="huge positive")
  assert_true(parse_int_str("-99999999999999999999999") == None, msg="huge negative")
  assert_true(parse_int_str("32768") != None, msg="parses as Int (int16 range is checked later)")
}

///| Malformed inputs.
test "parse_int_str rejects malformed input" {
  assert_true(parse_int_str("") == None, msg="empty")
  assert_true(parse_int_str("-") == None, msg="sign only")
  assert_true(parse_int_str("12a") == None, msg="trailing garbage")
  assert_true(parse_int_str("1.5") == None, msg="not a float parser")
}

///| decode_raw byte-length product must be checked with division first:
///| count=2^30 with 2-byte items needs 2^31 bytes, whose Int product
///| wraps negative and would silently pass a naive `length < count*item`.
test "decode_raw rejects byte length overflow before wrapping" {
  let data = Bytes::from_array([b'x'])
  let mut msg = ""
  try {
    let _unused = decode_raw(data, 1073741824, "int16", false)
  } catch {
    NrrdError(m) => msg = m
  }
  assert_true(msg.contains("byte length overflow"), msg="must raise overflow, got: \{msg}")
  // negative count is refused too (defensive)
  let mut msg2 = ""
  try {
    let _unused = decode_raw(data, -1, "int16", false)
  } catch {
    NrrdError(m) => msg2 = m
  }
  assert_true(msg2.contains("byte length overflow"), msg="negative count, got: \{msg2}")
}

///| parse_double_str delegates to core parse_double (bounded work,
///| correctly rounded to binary64; note the separate binary32
///| ASCII path is a two-step range contract — see decode.mbt) —
///| regression for the hand-rolled exponent loop.
test "parse_double_str parses plain and scientific values" {
  assert_true(parse_double_str("0.1") == Some(0.1), msg="0.1")
  assert_true(parse_double_str("-2.5e3") == Some(-2500.0), msg="scientific")
  assert_true(parse_double_str("1e40") == Some(1.0e40), msg="large finite")
  assert_true(parse_double_str("") == None, msg="empty")
  assert_true(parse_double_str("abc") == None, msg="not a number")
  assert_true(parse_double_str("1.2.3") == None, msg="malformed")
}

///| parse_int64_str covers the full Int64 range including the asymmetric
///| minimum (-2^63 is representable, +2^63 is not) — G3 uint32 carrier.
test "parse_int64_str covers Int64 boundaries without wraparound" {
  assert_true(parse_int64_str("9223372036854775807") == Some(9223372036854775807L), msg="int64 max")
  assert_true(parse_int64_str("9223372036854775808") == None, msg="int64 max + 1")
  assert_true(parse_int64_str("-9223372036854775808") == Some(-9223372036854775807L - 1L), msg="int64 min")
  assert_true(parse_int64_str("-9223372036854775809") == None, msg="int64 min - 1")
  assert_true(parse_int64_str("+9223372036854775807") == Some(9223372036854775807L), msg="explicit plus")
  assert_true(parse_int64_str("4294967295") == Some(4294967295L), msg="uint32 max fits")
  assert_true(parse_int64_str("4294967296") == Some(4294967296L), msg="uint32 max + 1 fits Int64")
  assert_true(parse_int64_str("-4294967296") == Some(-4294967296L), msg="negative beyond int32")
  assert_true(parse_int64_str("99999999999999999999999") == None, msg="huge positive")
  assert_true(parse_int64_str("-99999999999999999999999") == None, msg="huge negative")
  assert_true(parse_int64_str("18446744073709551616") == None, msg="2^64 refused")
  assert_true(parse_int64_str("-0") == Some(0L), msg="neg zero")
  assert_true(parse_int64_str("") == None, msg="empty")
  assert_true(parse_int64_str("-") == None, msg="sign only")
  assert_true(parse_int64_str("12a") == None, msg="trailing garbage")
}
