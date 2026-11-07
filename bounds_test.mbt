///| G3 read-side edge coverage: integer extremes, uint32 high half,
///| float/double subnormals and signed zero, NaN/inf, length anomalies,
///| budget injection, bad headers, constructed-header validation and
///| explicit type/encoding rejections.

///| Minimal valid int16 raw header text (dimension 1, n values).
fn edge_hdr(type_name : String, encoding : String, n : Int, extra~ : String = "") -> String {
  let mut s = "NRRD0005\ntype: \{type_name}\ndimension: 1\nsizes: \{n}\nencoding: \{encoding}"
  if encoding == "raw" {
    s = s + "\nendian: little"
  }
  s + extra + "\n"
}

///| Decode helper: header text + raw payload bytes.
fn edge_decode(hdr : String, payload : Bytes) -> Array[Double] raise @moon-nrrd.NrrdError {
  let h = @moon-nrrd.parse_header(hdr)
  @moon-nrrd.decode_data(payload, h)
}

///| Decode helper with allocation budget injection.
fn edge_decode_budget(
  hdr : String,
  payload : Bytes,
  budget : Int,
) -> Array[Double] raise @moon-nrrd.NrrdError {
  let h = @moon-nrrd.parse_header(hdr)
  @moon-nrrd.decode_data(payload, h, budget = budget)
}

///| Assert that a decode raises with a message containing `needle`.
fn edge_expect_fail(hdr : String, payload : Bytes, needle : String, label : String) -> Unit raise {
  let mut msg = ""
  try {
    let _unused = edge_decode(hdr, payload)
  } catch {
    @moon-nrrd.NrrdError(m) => msg = m
  }
  assert_true(msg.contains(needle), msg="\{label}: want error ~ '\{needle}', got '\{msg}'")
}

///| Assert that parse_header (constructed-header entry) raises with `needle`.
fn edge_expect_parse_fail(text : String, needle : String, label : String) -> Unit raise {
  let mut msg = ""
  try {
    let _unused = @moon-nrrd.parse_header(text)
  } catch {
    @moon-nrrd.NrrdError(m) => msg = m
  }
  assert_true(msg.contains(needle), msg="\{label}: want error ~ '\{needle}', got '\{msg}'")
}

///|
fn edge_bytes(vals : Array[Int]) -> Bytes {
  Bytes::from_array(Array::makei(vals.length(), i => vals[i].to_byte()))
}

// ---------------------------------------------------------------------------
// 整数极值 / uint32 高位
// ---------------------------------------------------------------------------

test "integer raw extremes decode exactly (int8/int16/int32 min-max)" {
  // int8: 0x80 -> -128, 0x7f -> 127
  let v8 = edge_decode(edge_hdr("int8", "raw", 2), edge_bytes([0x80, 0x7f]))
  assert_true(v8[0] == -128.0, msg="int8 min")
  assert_true(v8[1] == 127.0, msg="int8 max")
  // int16 LE: 0x8000 -> -32768, 0x7fff -> 32767
  let v16 = edge_decode(edge_hdr("int16", "raw", 2), edge_bytes([0x00, 0x80, 0xff, 0x7f]))
  assert_true(v16[0] == -32768.0, msg="int16 min")
  assert_true(v16[1] == 32767.0, msg="int16 max")
  // int32 LE: 0x80000000 -> -2147483648, 0x7fffffff -> 2147483647
  let v32 = edge_decode(
    edge_hdr("int32", "raw", 2),
    edge_bytes([0x00, 0x00, 0x00, 0x80, 0xff, 0xff, 0xff, 0x7f]),
  )
  assert_true(v32[0] == -2147483648.0, msg="int32 min")
  assert_true(v32[1] == 2147483647.0, msg="int32 max")
}

test "integer raw extremes decode exactly (uint8/uint16/uint32 min-max)" {
  let u8 = edge_decode(edge_hdr("uint8", "raw", 2), edge_bytes([0x00, 0xff]))
  assert_true(u8[0] == 0.0, msg="uint8 min")
  assert_true(u8[1] == 255.0, msg="uint8 max")
  let u16 = edge_decode(edge_hdr("uint16", "raw", 2), edge_bytes([0x00, 0x00, 0xff, 0xff]))
  assert_true(u16[0] == 0.0, msg="uint16 min")
  assert_true(u16[1] == 65535.0, msg="uint16 max")
  // uint32 LE high half: 0x80000000 -> 2147483648, 0xffffffff -> 4294967295
  let u32 = edge_decode(
    edge_hdr("uint32", "raw", 2),
    edge_bytes([0x00, 0x00, 0x00, 0x80, 0xff, 0xff, 0xff, 0xff]),
  )
  assert_true(u32[0] == 2147483648.0, msg="uint32 2^31")
  assert_true(u32[1] == 4294967295.0, msg="uint32 max")
}

test "int32 BE min decodes exactly (endian switch)" {
  // BE 0x80000000 -> -2147483648
  let hdr = "NRRD0005\ntype: int32\ndimension: 1\nsizes: 1\nencoding: raw\nendian: big\n"
  let v = edge_decode(hdr, edge_bytes([0x80, 0x00, 0x00, 0x00]))
  assert_true(v[0] == -2147483648.0, msg="int32 BE min")
}

test "uint32 high half via ascii decodes exactly" {
  let v = edge_decode(
    edge_hdr("uint32", "ascii", 3),
    @moon-nrrd.ascii_to_bytes("2147483648 3000000000 4294967295"),
  )
  assert_true(v[0] == 2147483648.0, msg="ascii 2^31")
  assert_true(v[1] == 3000000000.0, msg="ascii 3e9")
  assert_true(v[2] == 4294967295.0, msg="ascii uint32 max")
}

test "ascii integers out of type range are rejected, never truncated" {
  edge_expect_fail(
    edge_hdr("int8", "ascii", 1),
    @moon-nrrd.ascii_to_bytes("128"),
    "out of range",
    "int8 128",
  )
  edge_expect_fail(
    edge_hdr("int8", "ascii", 1),
    @moon-nrrd.ascii_to_bytes("-129"),
    "out of range",
    "int8 -129",
  )
  edge_expect_fail(
    edge_hdr("uint8", "ascii", 1),
    @moon-nrrd.ascii_to_bytes("-1"),
    "out of range",
    "uint8 -1",
  )
  edge_expect_fail(
    edge_hdr("uint16", "ascii", 1),
    @moon-nrrd.ascii_to_bytes("65536"),
    "out of range",
    "uint16 65536",
  )
  edge_expect_fail(
    edge_hdr("int32", "ascii", 1),
    @moon-nrrd.ascii_to_bytes("2147483648"),
    "out of range",
    "int32 2^31",
  )
  edge_expect_fail(
    edge_hdr("uint32", "ascii", 1),
    @moon-nrrd.ascii_to_bytes("4294967296"),
    "out of range",
    "uint32 2^32",
  )
  edge_expect_fail(
    edge_hdr("uint32", "ascii", 1),
    @moon-nrrd.ascii_to_bytes("-1"),
    "out of range",
    "uint32 -1",
  )
}

// ---------------------------------------------------------------------------
// float/double 次正规、负零、NaN、inf
// ---------------------------------------------------------------------------

test "float raw subnormal, signed zero, max, nan, inf decode as documented" {
  // -0.0 / +0.0 / min subnormal / max / nan / +inf / -inf / 1.0
  let payload = edge_bytes([
    0x00, 0x00, 0x00, 0x80,
    0x00, 0x00, 0x00, 0x00,
    0x01, 0x00, 0x00, 0x00,
    0xff, 0xff, 0x7f, 0x7f,
    0x00, 0x00, 0xc0, 0x7f,
    0x00, 0x00, 0x80, 0x7f,
    0x00, 0x00, 0x80, 0xff,
    0x00, 0x00, 0x80, 0x3f,
  ])
  let v = edge_decode(edge_hdr("float", "raw", 8), payload)
  assert_true(@moon-nrrd.format_float(v[0]) == "-0.0", msg="-0.0 keeps sign")
  assert_true(@moon-nrrd.format_float(v[1]) == "0.0", msg="+0.0")
  assert_true(v[2] == 1.401298464324817e-45, msg="float32 min subnormal")
  assert_true(v[3] == 3.4028234663852886e38, msg="float32 max")
  assert_true(v[4].is_nan(), msg="nan")
  assert_true(v[5].is_pos_inf(), msg="+inf")
  assert_true(v[6].is_neg_inf(), msg="-inf")
  assert_true(v[7] == 1.0, msg="1.0")
}

test "double raw subnormal, signed zero, max, nan, inf decode as documented" {
  let payload = edge_bytes([
    0, 0, 0, 0, 0, 0, 0, 0x80, // -0.0
    0, 0, 0, 0, 0, 0, 0, 0, // +0.0
    1, 0, 0, 0, 0, 0, 0, 0, // 5e-324
    0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xef, 0x7f, // max
    0, 0, 0, 0, 0, 0, 0xf8, 0x7f, // nan
    0, 0, 0, 0, 0, 0, 0xf0, 0x7f, // +inf
    0, 0, 0, 0, 0, 0, 0xf0, 0xff, // -inf
  ])
  let v = edge_decode(edge_hdr("double", "raw", 7), payload)
  assert_true(@moon-nrrd.format_float(v[0]) == "-0.0", msg="-0.0 keeps sign")
  assert_true(@moon-nrrd.format_float(v[1]) == "0.0", msg="+0.0")
  assert_true(v[2] == 5.0e-324, msg="binary64 min subnormal")
  assert_true(v[3] == 1.7976931348623157e308, msg="binary64 max")
  assert_true(v[4].is_nan(), msg="nan")
  assert_true(v[5].is_pos_inf(), msg="+inf")
  assert_true(v[6].is_neg_inf(), msg="-inf")
}

test "ascii nan/inf tokens follow spec substring rules for float and double" {
  let v = edge_decode(
    edge_hdr("float", "ascii", 5),
    @moon-nrrd.ascii_to_bytes("nan NaN inf -inf -0.0"),
  )
  assert_true(v[0].is_nan(), msg="nan")
  assert_true(v[1].is_nan(), msg="NaN case-insensitive")
  assert_true(v[2].is_pos_inf(), msg="inf")
  assert_true(v[3].is_neg_inf(), msg="-inf")
  assert_true(@moon-nrrd.format_float(v[4]) == "-0.0", msg="-0.0")
  let d = edge_decode(
    edge_hdr("double", "ascii", 4),
    @moon-nrrd.ascii_to_bytes("nan inf -inf -0.0"),
  )
  assert_true(d[0].is_nan(), msg="double nan")
  assert_true(d[1].is_pos_inf(), msg="double inf")
  assert_true(d[2].is_neg_inf(), msg="double -inf")
  assert_true(@moon-nrrd.format_float(d[3]) == "-0.0", msg="double -0.0")
}

// ---------------------------------------------------------------------------
// 长度异常 / 超预算
// ---------------------------------------------------------------------------

test "raw trailing extra bytes beyond declared count are ignored (pinned behavior)" {
  // sizes: 2 -> 4 bytes expected; payload has 6. Current contract: the first
  // `count` values are decoded and trailing bytes are not interpreted.
  let v = edge_decode(
    edge_hdr("int16", "raw", 2),
    edge_bytes([0x01, 0x00, 0x02, 0x00, 0xff, 0xff]),
  )
  assert_true(v[0] == 1.0 && v[1] == 2.0, msg="first count values only")
}

test "budget injection refuses over-budget counts before allocation" {
  // 5 values requested with budget 4 -> refused before allocation
  let mut msg = ""
  try {
    let _unused = edge_decode_budget(
      edge_hdr("int16", "ascii", 5),
      @moon-nrrd.ascii_to_bytes("1 2 3 4 5"),
      4,
    )
  } catch {
    @moon-nrrd.NrrdError(m) => msg = m
  }
  assert_true(msg.contains("budget"), msg="budget=4 < 5 must refuse, got: \{msg}")
  // budget exactly equal to count passes (fails later only if data wrong)
  let v = edge_decode_budget(
    edge_hdr("int16", "ascii", 3),
    @moon-nrrd.ascii_to_bytes("7 8 9"),
    3,
  )
  assert_true(v[0] == 7.0 && v[2] == 9.0, msg="budget==count passes")
}

// ---------------------------------------------------------------------------
// 坏头（parse_header / validate_header 条件）
// ---------------------------------------------------------------------------

test "space and space dimension are mutually exclusive" {
  edge_expect_parse_fail(
    "NRRD0005\ntype: int16\ndimension: 1\nsizes: 1\nencoding: ascii\n" +
    "space: right-anterior-superior\nspace dimension: 3\n",
    "mutually exclusive",
    "space+spacedimension",
  )
}

test "orientation fields require a spatial identity" {
  edge_expect_parse_fail(
    "NRRD0005\ntype: int16\ndimension: 1\nsizes: 1\nencoding: ascii\n" +
    "space origin: (1.0, 2.0, 3.0)\n",
    "require space or space dimension",
    "origin without identity",
  )
  edge_expect_parse_fail(
    "NRRD0005\ntype: int16\ndimension: 1\nsizes: 1\nencoding: ascii\n" +
    "space units: mm mm mm\n",
    "require space or space dimension",
    "units without identity",
  )
  edge_expect_parse_fail(
    "NRRD0005\ntype: int16\ndimension: 1\nsizes: 1\nencoding: ascii\n" +
    "space directions: (1.0, 0.0, 0.0)\n",
    "require space or space dimension",
    "directions without identity",
  )
}

test "unknown named space is rejected" {
  edge_expect_parse_fail(
    "NRRD0005\ntype: int16\ndimension: 1\nsizes: 1\nencoding: ascii\n" +
    "space: middle-earth\n",
    "unknown named space",
    "unknown space name",
  )
}

test "per-axis field counts must match dimension (labels/kinds/directions)" {
  edge_expect_parse_fail(
    "NRRD0005\ntype: int16\ndimension: 1\nsizes: 1\nencoding: ascii\nlabels: a b\n",
    "labels count",
    "labels count",
  )
  edge_expect_parse_fail(
    "NRRD0005\ntype: int16\ndimension: 1\nsizes: 1\nencoding: ascii\nkinds: domain domain\n",
    "kinds count",
    "kinds count",
  )
  edge_expect_parse_fail(
    "NRRD0005\ntype: int16\ndimension: 1\nsizes: 1\nencoding: ascii\n" +
    "space dimension: 3\nspace directions: (1.0, 0.0, 0.0) (0.0, 1.0, 0.0)\n",
    "space directions count",
    "directions rows",
  )
}

test "spatial vector lengths must match space dimension" {
  edge_expect_parse_fail(
    "NRRD0005\ntype: int16\ndimension: 1\nsizes: 1\nencoding: ascii\n" +
    "space dimension: 3\nspace origin: (1.0, 2.0)\n",
    "space origin length",
    "origin length",
  )
  edge_expect_parse_fail(
    "NRRD0005\ntype: int16\ndimension: 1\nsizes: 1\nencoding: ascii\n" +
    "space dimension: 3\nspace units: mm mm\n",
    "space units count",
    "units count",
  )
  edge_expect_parse_fail(
    "NRRD0005\ntype: int16\ndimension: 1\nsizes: 1\nencoding: ascii\n" +
    "space dimension: 3\nspace directions: (1.0, 0.0)\n",
    "space direction vector length",
    "direction vector length",
  )
}

test "0-D and dimension above 16 are rejected" {
  edge_expect_parse_fail(
    "NRRD0005\ntype: int16\ndimension: 0\nsizes: 1\nencoding: ascii\n",
    "missing or invalid dimension",
    "0-D",
  )
  let mut s = "NRRD0005\ntype: int16\ndimension: 17\nsizes:"
  let mut i = 0
  while i < 17 {
    s = s + " 1"
    i = i + 1
  }
  edge_expect_parse_fail(s + "\nencoding: ascii\n", "exceeds limit", "dim 17")
}

test "sizes count mismatch and non-positive sizes are rejected" {
  edge_expect_parse_fail(
    "NRRD0005\ntype: int16\ndimension: 2\nsizes: 4\nencoding: ascii\n",
    "sizes count",
    "sizes count",
  )
  edge_expect_parse_fail(
    "NRRD0005\ntype: int16\ndimension: 1\nsizes: 0\nencoding: ascii\n",
    "sizes must be positive",
    "zero size",
  )
  edge_expect_parse_fail(
    "NRRD0005\ntype: int16\ndimension: 1\nsizes: -2\nencoding: ascii\n",
    "sizes must be positive",
    "negative size",
  )
}

test "parse_header enforces the header length budget directly" {
  // > 1 MiB of comment line: direct parse_header callers cannot bypass the cap
  let sb = StringBuilder()
  sb.write_string("NRRD0005\n#")
  let mut i = 0
  while i < 1100000 {
    sb.write_char('x')
    i = i + 1
  }
  sb.write_string("\ntype: int16\ndimension: 1\nsizes: 1\nencoding: ascii\n")
  let mut msg = ""
  try {
    let _unused = @moon-nrrd.parse_header(sb.to_string())
  } catch {
    @moon-nrrd.NrrdError(m) => msg = m
  }
  assert_true(msg.contains("header too large"), msg="want header-too-large, got: \{msg}")
}

// ---------------------------------------------------------------------------
// 构造 header 的独立入口（不经过 parse_header）
// ---------------------------------------------------------------------------

test "constructed header validates and decodes without parse_header" {
  let h = @moon-nrrd.NrrdHeader::{
    dimension: 1,
    sizes: [2],
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
    content: None,
    line_skip: 0,
    byte_skip: 0,
  }
  @moon-nrrd.validate_header(h) // must accept a legal constructed header
  let v = @moon-nrrd.decode_data(edge_bytes([0xf6, 0xff, 0x0a, 0x00]), h)
  assert_true(v[0] == -10.0 && v[1] == 10.0, msg="constructed header decode")
}

test "constructed invalid header is rejected inside decode_data" {
  // labels count != dimension: decode_data must validate independently
  let h = @moon-nrrd.NrrdHeader::{
    dimension: 1,
    sizes: [1],
    type_name: "int16",
    encoding: "raw",
    endian: Some("little"),
    data_file: None,
    space: None,
    space_dimension: None,
    space_origin: None,
    space_directions: [],
    space_units: None,
    labels: Some(["a", "b"]),
    kinds: None,
    content: None,
    line_skip: 0,
    byte_skip: 0,
  }
  let mut msg = ""
  try {
    let _unused = @moon-nrrd.decode_data(edge_bytes([0x00, 0x00]), h)
  } catch {
    @moon-nrrd.NrrdError(m) => msg = m
  }
  assert_true(msg.contains("labels count"), msg="decode_data must validate, got: \{msg}")
}

// ---------------------------------------------------------------------------
// 显式拒绝：类型与编码
// ---------------------------------------------------------------------------

test "int64/uint64/block types are explicitly rejected" {
  edge_expect_fail(
    edge_hdr("int64", "raw", 1),
    edge_bytes([0, 0, 0, 0, 0, 0, 0, 0]),
    "excluded from v1",
    "int64",
  )
  edge_expect_fail(
    edge_hdr("uint64", "raw", 1),
    edge_bytes([0, 0, 0, 0, 0, 0, 0, 0]),
    "excluded from v1",
    "uint64",
  )
  edge_expect_fail(
    edge_hdr("block", "raw", 1),
    edge_bytes([0]),
    "not supported",
    "block",
  )
}

test "hex/gzip/bzip2 encodings are explicitly rejected" {
  edge_expect_fail(
    edge_hdr("int16", "hex", 1),
    @moon-nrrd.ascii_to_bytes("0000"),
    "explicitly rejected",
    "hex",
  )
  edge_expect_fail(
    edge_hdr("int16", "gzip", 1),
    edge_bytes([0x1f, 0x8b]),
    "explicitly rejected",
    "gzip",
  )
  edge_expect_fail(
    edge_hdr("int16", "bzip2", 1),
    edge_bytes([0x42, 0x5a]),
    "explicitly rejected",
    "bzip2",
  )
}
