///| Write-side tests (G3): value policy, string escaping, budget
///| pre-checks, and no-IO attached/detached assembly.
///| Blackbox: only the public API is exercised.

///| Minimal 1-D header factory for write tests.
fn enc_hdr(
  t : String,
  e : String,
  n : Int,
  endian~ : String? = None,
  data_file~ : String? = None,
  content~ : String? = None,
) -> @moon-nrrd.NrrdHeader {
  @moon-nrrd.NrrdHeader::{
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
    content: content,
    line_skip: 0,
    byte_skip: 0,
  }
}

///| Encode and return the error message ("" when it succeeds).
fn enc_data_err(values : Array[Double], h : @moon-nrrd.NrrdHeader) -> String {
  try {
    let _unused = @moon-nrrd.encode_data(values, h)
    ""
  } catch {
    @moon-nrrd.NrrdError(m) => m
  }
}

///|
fn enc_data_err_budget(
  values : Array[Double],
  h : @moon-nrrd.NrrdHeader,
  budget : Int,
) -> String {
  try {
    let _unused = @moon-nrrd.encode_data(values, h, budget = budget)
    ""
  } catch {
    @moon-nrrd.NrrdError(m) => m
  }
}

///|
fn enc_hdr_err(h : @moon-nrrd.NrrdHeader) -> String {
  try {
    let _unused = @moon-nrrd.format_header(h)
    ""
  } catch {
    @moon-nrrd.NrrdError(m) => m
  }
}

///|
fn enc_kv_err(k : String, v : String) -> String {
  try {
    let _unused = @moon-nrrd.format_keyval_line(k, v)
    ""
  } catch {
    @moon-nrrd.NrrdError(m) => m
  }
}

///| Bytes vs expected byte values (Int 0..255).
fn enc_bytes_eq(b : Bytes, arr : Array[Int]) -> Bool {
  if b.length() != arr.length() {
    return false
  }
  let mut i = 0
  while i < arr.length() {
    if b[i].to_int() != arr[i] {
      return false
    }
    i = i + 1
  }
  true
}

///| String-array equality.
fn enc_str_arr_eq(a : Array[String], b : Array[String]) -> Bool {
  if a.length() != b.length() {
    return false
  }
  let mut i = 0
  while i < a.length() {
    if a[i] != b[i] {
      return false
    }
    i = i + 1
  }
  true
}

///| Semantic value equality: nan==nan, signed zeros distinct,
///| everything else exact.
fn enc_sem_eq(a : Double, b : Double) -> Bool {
  if a.is_nan() || b.is_nan() {
    a.is_nan() && b.is_nan()
  } else if a == 0.0 && b == 0.0 {
    (Float::reinterpret_as_int(Float::from_double(a)) < 0) ==
    (Float::reinterpret_as_int(Float::from_double(b)) < 0)
  } else {
    a == b
  }
}

// ---------------------------------------------------------------------------
// format_header: structure, canonical output, round-trip
// ---------------------------------------------------------------------------

///| Exact canonical text for the minimal raw header (field order is
///| part of the writer contract; it is stable, not spec-mandated).
test "format_header minimal raw text is canonical" {
  let h = enc_hdr("int8_t", "raw", 2, endian=Some("LITTLE"), content=Some("hi"))
  let s = @moon-nrrd.format_header(h)
  assert_true(
    s == "NRRD0005\ntype: int8\ndimension: 1\nsizes: 2\nencoding: raw\nendian: little\ncontent: hi\n",
    msg="got: \{s}",
  )
}

///| format_header -> parse_header preserves every field.
test "format_header round-trips through parse_header" {
  let h = @moon-nrrd.NrrdHeader::{
    dimension: 2,
    sizes: [2, 3],
    type_name: "float",
    encoding: "ascii",
    endian: None,
    data_file: None,
    space: Some("right-anterior-superior"),
    space_dimension: None,
    space_origin: Some([1.5, -0.0, 2.5]),
    space_directions: [None, Some([1.0, 0.0, 0.0])],
    space_units: Some(["mm", "mm", "mm"]),
    labels: Some(["a b", ""]),
    kinds: Some(["domain", "space"]),
    content: Some("x:y"),
    line_skip: 0,
    byte_skip: 0,
  }
  let s = @moon-nrrd.format_header(h)
  let h2 = @moon-nrrd.parse_header(s)
  assert_true(h2.dimension == 2, msg="dimension")
  assert_true(h2.sizes[0] == 2 && h2.sizes[1] == 3, msg="sizes")
  assert_true(h2.type_name == "float", msg="type")
  assert_true(h2.encoding == "ascii", msg="encoding")
  assert_true(h2.space == Some("right-anterior-superior"), msg="space")
  match h2.space_origin {
    Some(o) => {
      assert_true(o[0] == 1.5 && o[2] == 2.5, msg="origin values")
      // -0.0 must keep its sign through serialization
      assert_true(
        Float::reinterpret_as_int(Float::from_double(o[1])) < 0,
        msg="origin -0.0 sign",
      )
    }
    None => abort("origin missing")
  }
  assert_true(h2.space_directions.length() == 2, msg="directions count")
  match h2.space_directions[0] {
    None => ()
    Some(_) => abort("direction row 0 should be none")
  }
  match h2.space_units {
    Some(us) => assert_true(enc_str_arr_eq(us, ["mm", "mm", "mm"]), msg="units")
    None => abort("units missing")
  }
  match h2.labels {
    Some(ls) => assert_true(enc_str_arr_eq(ls, ["a b", ""]), msg="labels")
    None => abort("labels missing")
  }
  match h2.kinds {
    Some(ks) => assert_true(enc_str_arr_eq(ks, ["domain", "space"]), msg="kinds")
    None => abort("kinds missing")
  }
  assert_true(h2.content == Some("x:y"), msg="content")
}

///| Quote escaping per spec (only `\"`) round-trips, and the escape
///| sequence is really present in the emitted text.
test "labels quote is escaped and round-trips" {
  let h = @moon-nrrd.NrrdHeader::{
    dimension: 1,
    sizes: [1],
    type_name: "int8",
    encoding: "raw",
    endian: Some("little"),
    data_file: None,
    space: None,
    space_dimension: None,
    space_origin: None,
    space_directions: [],
    space_units: None,
    labels: Some(["a\"b"]),
    kinds: None,
    content: None,
    line_skip: 0,
    byte_skip: 0,
  }
  let s = @moon-nrrd.format_header(h)
  assert_true(s.contains("\\\""), msg="escape sequence must appear: \{s}")
  let h2 = @moon-nrrd.parse_header(s)
  match h2.labels {
    Some(ls) => assert_true(enc_str_arr_eq(ls, ["a\"b"]), msg="labels: \{ls[0]}")
    None => abort("labels missing")
  }
}

///| Backslash in quoted strings is rejected (no unambiguous spec
///| escape; readers disagree on `\\`).
test "labels backslash is rejected on write" {
  let h = @moon-nrrd.NrrdHeader::{
    dimension: 1,
    sizes: [1],
    type_name: "int8",
    encoding: "raw",
    endian: Some("little"),
    data_file: None,
    space: None,
    space_dimension: None,
    space_origin: None,
    space_directions: [],
    space_units: None,
    labels: Some(["a\\b"]),
    kinds: None,
    content: None,
    line_skip: 0,
    byte_skip: 0,
  }
  let m = enc_hdr_err(h)
  assert_true(m.contains("backslash"), msg="got: \{m}")
}

///| Newline in labels cannot be a single-line field -> rejected.
test "labels newline is rejected on write" {
  let h = @moon-nrrd.NrrdHeader::{
    dimension: 1,
    sizes: [1],
    type_name: "int8",
    encoding: "raw",
    endian: Some("little"),
    data_file: None,
    space: None,
    space_dimension: None,
    space_origin: None,
    space_directions: [],
    space_units: None,
    labels: Some(["a\nb"]),
    kinds: None,
    content: None,
    line_skip: 0,
    byte_skip: 0,
  }
  let m = enc_hdr_err(h)
  assert_true(m.contains("control character"), msg="got: \{m}")
}

///| content: bare line string. Newlines and edge whitespace are
///| rejected (edge whitespace would not round-trip: both parsers trim).
test "content newline and edge whitespace are rejected" {
  let mk = fn(c : String) -> @moon-nrrd.NrrdHeader {
    @moon-nrrd.NrrdHeader::{
      dimension: 1,
      sizes: [1],
      type_name: "int8",
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
      content: Some(c),
      line_skip: 0,
      byte_skip: 0,
    }
  }
  assert_true(enc_hdr_err(mk("a\nb")).contains("control"), msg="newline")
  assert_true(enc_hdr_err(mk("a\rb")).contains("control"), msg="CR")
  assert_true(enc_hdr_err(mk(" x")).contains("whitespace"), msg="leading ws")
  assert_true(enc_hdr_err(mk("x ")).contains("whitespace"), msg="trailing ws")
  assert_true(enc_hdr_err(mk("ok: still ok")) == "", msg="interior colon is fine")
}

///| kinds: bare tokens; whitespace/quote inside a token would change
///| the token count or quoting on re-read -> rejected.
test "kinds whitespace and quote are rejected" {
  let mk = fn(ks : Array[String]) -> @moon-nrrd.NrrdHeader {
    @moon-nrrd.NrrdHeader::{
      dimension: 1,
      sizes: [1],
      type_name: "int8",
      encoding: "raw",
      endian: Some("little"),
      data_file: None,
      space: None,
      space_dimension: None,
      space_origin: None,
      space_directions: [],
      space_units: None,
      labels: None,
      kinds: Some(ks),
      content: None,
      line_skip: 0,
      byte_skip: 0,
    }
  }
  assert_true(enc_hdr_err(mk(["a b"])).contains("whitespace"), msg="space in kind")
  assert_true(enc_hdr_err(mk(["a\"b"])).contains("quote"), msg="quote in kind")
  assert_true(enc_hdr_err(mk(["domain"])) == "", msg="plain kind ok")
}

///| data file: bare line string; newlines and edge whitespace rejected.
test "data file newline and edge whitespace are rejected" {
  let mk = fn(name : String) -> @moon-nrrd.NrrdHeader {
    @moon-nrrd.NrrdHeader::{
      dimension: 1,
      sizes: [1],
      type_name: "int8",
      encoding: "raw",
      endian: Some("little"),
      data_file: Some(name),
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
  }
  assert_true(enc_hdr_err(mk("a\nNRRD0005")).contains("control"), msg="newline injection")
  assert_true(enc_hdr_err(mk(" a.raw")).contains("whitespace"), msg="leading ws")
  assert_true(enc_hdr_err(mk("a.raw")) == "", msg="plain name ok")
}

///| Writer policy: only supported types/encodings, no skip fields,
///| endian must be little|big, spatial identity rules still apply.
test "format_header rejects unsupported and inconsistent fields" {
  let mk = fn(
    t : String,
    e : String,
    endian : String?,
    line_skip : Int,
  ) -> @moon-nrrd.NrrdHeader {
    @moon-nrrd.NrrdHeader::{
      dimension: 1,
      sizes: [1],
      type_name: t,
      encoding: e,
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
      line_skip: line_skip,
      byte_skip: 0,
    }
  }
  assert_true(enc_hdr_err(mk("int64", "raw", Some("little"), 0)).contains("excluded"), msg="int64")
  assert_true(enc_hdr_err(mk("block", "raw", Some("little"), 0)).contains("block"), msg="block")
  assert_true(enc_hdr_err(mk("int8", "hex", None, 0)).contains("hex"), msg="hex")
  assert_true(enc_hdr_err(mk("int8", "gzip", None, 0)).contains("gzip"), msg="gzip")
  assert_true(enc_hdr_err(mk("int8", "raw", Some("middle"), 0)).contains("little|big"), msg="endian")
  assert_true(enc_hdr_err(mk("int8", "raw", Some("little"), 1)).contains("line skip"), msg="skip")
}

///| key:=value escaping (spec §1.7): `\n` and `\\` must be generated;
///| keys that could shadow standard fields are refused.
test "format_keyval_line escapes and guards keys" {
  assert_true(@moon-nrrd.format_keyval_line("k", "v") == "k:=v", msg="plain")
  assert_true(
    @moon-nrrd.format_keyval_line("k", "a\nb") == "k:=a\\nb",
    msg="newline escape",
  )
  assert_true(
    @moon-nrrd.format_keyval_line("k", "a\\b") == "k:=a\\\\b",
    msg="backslash escape",
  )
  assert_true(@moon-nrrd.format_keyval_line("k", "a:b") == "k:=a:b", msg="colon in value ok")
  // guards
  assert_true(enc_kv_err("type", "x").contains("collides"), msg="type key")
  assert_true(enc_kv_err("Type", "x").contains("collides"), msg="Type key (case fold)")
  assert_true(enc_kv_err("data file", "x").contains("collides"), msg="data file key")
  assert_true(enc_kv_err("a:b", "x").contains("':'"), msg="colon in key")
  assert_true(enc_kv_err("a:=b", "x").contains("':'"), msg=":= in key")
  assert_true(enc_kv_err("#c", "x").contains("#"), msg="comment-like key")
  assert_true(enc_kv_err(" k", "x").contains("whitespace"), msg="edge ws key")
  assert_true(enc_kv_err("", "x").contains("empty"), msg="empty key")
  assert_true(enc_kv_err("k", "a\rb").contains("control"), msg="CR in value")
}

// ---------------------------------------------------------------------------
// encode_data: value policy
// ---------------------------------------------------------------------------

///| Integer writes reject non-integral / NaN / inf / out-of-range
///| values with a message naming value and type. Never silent.
test "integer value policy rejects bad values" {
  let h = enc_hdr("int8", "raw", 1, endian=Some("little"))
  assert_true(enc_data_err([1.5], h).contains("non-integral"), msg="1.5")
  assert_true(enc_data_err([@double.not_a_number], h).contains("NaN"), msg="nan")
  assert_true(enc_data_err([@double.infinity], h).contains("infinity"), msg="+inf")
  assert_true(enc_data_err([128.0], h).contains("out of range"), msg="128")
  assert_true(enc_data_err([-129.0], h).contains("out of range"), msg="-129")
  assert_true(enc_data_err([-128.0], h) == "", msg="-128 ok")
  assert_true(enc_data_err([127.0], h) == "", msg="127 ok")
  let hu = enc_hdr("uint8", "raw", 1, endian=Some("little"))
  assert_true(enc_data_err([-1.0], hu).contains("out of range"), msg="uint8 -1")
  assert_true(enc_data_err([256.0], hu).contains("out of range"), msg="256")
  assert_true(enc_data_err([255.0], hu) == "", msg="255 ok")
}

///| uint32 high half must be exact in raw bytes (both byte orders —
///| this is also the real byte-order proof for the 48-grid).
test "uint32 high half is bit-exact in raw output" {
  let hle = enc_hdr("uint32", "raw", 3, endian=Some("little"))
  let ble = @moon-nrrd.encode_data([2147483648.0, 3000000000.0, 4294967295.0], hle)
  assert_true(
    enc_bytes_eq(ble, [
      0x00, 0x00, 0x00, 0x80,
      0x00, 0x5e, 0xd0, 0xb2, // 3000000000 = 0xB2D05E00
      0xff, 0xff, 0xff, 0xff,
    ]),
    msg="uint32 LE bytes",
  )
  let hbe = enc_hdr("uint32", "raw", 2, endian=Some("big"))
  let bbe = @moon-nrrd.encode_data([2147483648.0, 4294967295.0], hbe)
  assert_true(
    enc_bytes_eq(bbe, [0x80, 0x00, 0x00, 0x00, 0xff, 0xff, 0xff, 0xff]),
    msg="uint32 BE bytes",
  )
  let hu32 = enc_hdr("uint32", "raw", 1, endian=Some("little"))
  assert_true(enc_data_err([4294967296.0], hu32).contains("out of range"), msg="2^32")
  assert_true(enc_data_err([-1.0], hu32).contains("out of range"), msg="-1")
}

///| ASCII integers use exact decimal Int64 formatting — never a
///| lossy float format (no "4.294967295e9", no ".0" suffix).
test "ascii integers are exact decimal" {
  let h = enc_hdr("uint32", "ascii", 2)
  let b = @moon-nrrd.encode_data([2147483648.0, 4294967295.0], h)
  assert_true(
    @moon-nrrd.bytes_to_ascii(b) == "2147483648 4294967295\n",
    msg="got: \{@moon-nrrd.bytes_to_ascii(b)}",
  )
  let h2 = enc_hdr("int32", "ascii", 2)
  let b2 = @moon-nrrd.encode_data([-2147483648.0, 2147483647.0], h2)
  assert_true(
    @moon-nrrd.bytes_to_ascii(b2) == "-2147483648 2147483647\n",
    msg="got: \{@moon-nrrd.bytes_to_ascii(b2)}",
  )
}

// ---------------------------------------------------------------------------
// encode_data: float / double semantics (single-topic tests)
// ---------------------------------------------------------------------------

///| float negative zero: raw sign bit + ASCII "-0.0", both survive
///| a full read-back.
test "float -0.0 semantics" {
  let h = enc_hdr("float", "raw", 1, endian=Some("little"))
  let b = @moon-nrrd.encode_data([-0.0], h)
  assert_true(enc_bytes_eq(b, [0x00, 0x00, 0x00, 0x80]), msg="float -0.0 raw bits")
  let ha = enc_hdr("float", "ascii", 1)
  let ba = @moon-nrrd.encode_data([-0.0], ha)
  assert_true(@moon-nrrd.bytes_to_ascii(ba) == "-0.0\n", msg="float -0.0 ascii token")
  // cross-read through the reader
  let b2 = @moon-nrrd.encode_data([0.0], h)
  assert_true(enc_bytes_eq(b2, [0x00, 0x00, 0x00, 0x00]), msg="float +0.0 raw bits")
  let vals = @moon-nrrd.decode_data(b, h)
  assert_true(
    Float::reinterpret_as_int(Float::from_double(vals[0])) < 0,
    msg="round-trip keeps -0.0 sign",
  )
}

///| float subnormal: min subnormal encodes to the smallest raw bit
///| pattern and round-trips (ASCII uses the shortest token "1e-45").
test "float subnormal semantics" {
  let h = enc_hdr("float", "raw", 1, endian=Some("little"))
  let b = @moon-nrrd.encode_data([1.401298464324817e-45], h)
  assert_true(enc_bytes_eq(b, [0x01, 0x00, 0x00, 0x00]), msg="min subnormal raw")
  let ha = enc_hdr("float", "ascii", 1)
  let ba = @moon-nrrd.encode_data([1.401298464324817e-45], ha)
  assert_true(
    @moon-nrrd.bytes_to_ascii(ba) == "1e-45\n",
    msg="shortest token: \{@moon-nrrd.bytes_to_ascii(ba)}",
  )
  let vals = @moon-nrrd.decode_data(ba, ha)
  assert_true(vals[0] == Float::to_double(Float::from_double(1.401298464324817e-45)), msg="ascii subnormal round-trip")
}

///| float +-inf: raw exponent bits + ASCII tokens, signed.
test "float inf semantics" {
  let h = enc_hdr("float", "raw", 2, endian=Some("big"))
  let b = @moon-nrrd.encode_data([@double.infinity, @double.neg_infinity], h)
  assert_true(
    enc_bytes_eq(b, [0x7f, 0x80, 0x00, 0x00, 0xff, 0x80, 0x00, 0x00]),
    msg="float inf raw BE",
  )
  let ha = enc_hdr("float", "ascii", 2)
  let ba = @moon-nrrd.encode_data([@double.infinity, @double.neg_infinity], ha)
  assert_true(@moon-nrrd.bytes_to_ascii(ba) == "inf -inf\n", msg="ascii inf tokens")
  // overflow saturates to +-inf per G2 v2 §7.1
  let h1 = enc_hdr("float", "raw", 1, endian=Some("big"))
  let bo = @moon-nrrd.encode_data([1.0e39], h1)
  assert_true(enc_bytes_eq(bo, [0x7f, 0x80, 0x00, 0x00]), msg="float overflow saturates")
}

///| float NaN: semantic only (payload/signaling bits not promised).
test "float nan semantics" {
  let h = enc_hdr("float", "raw", 1, endian=Some("little"))
  let b = @moon-nrrd.encode_data([@double.not_a_number], h)
  let vals = @moon-nrrd.decode_data(b, h)
  assert_true(vals[0].is_nan(), msg="raw nan round-trip (semantic)")
  let ha = enc_hdr("float", "ascii", 1)
  let ba = @moon-nrrd.encode_data([@double.not_a_number], ha)
  assert_true(@moon-nrrd.bytes_to_ascii(ba) == "nan\n", msg="ascii nan token")
  let vals2 = @moon-nrrd.decode_data(ba, ha)
  assert_true(vals2[0].is_nan(), msg="ascii nan round-trip (semantic)")
}

///| double: bit-exact finite and -0.0, min subnormal exact.
test "double bit-exact raw values" {
  let h = enc_hdr("double", "raw", 3, endian=Some("little"))
  let b = @moon-nrrd.encode_data([-0.0, 5.0e-324, -1.5], h)
  assert_true(
    enc_bytes_eq(b, [
      0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x80, // -0.0
      0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // 5e-324
      0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xf8, 0xbf, // -1.5
    ]),
    msg="double raw bytes",
  )
  let vals = @moon-nrrd.decode_data(b, h)
  assert_true(
    Float::reinterpret_as_int(Float::from_double(vals[0])) < 0,
    msg="-0.0 sign kept",
  )
  assert_true(vals[1] == 5.0e-324, msg="min subnormal exact")
  assert_true(vals[2] == -1.5, msg="-1.5 exact")
}

///| ASCII double: shortest round-trip strings; finite and signed
///| zero round-trip exactly (read path: correctly-rounded parse).
test "double ascii round-trips exactly" {
  let h = enc_hdr("double", "ascii", 5)
  let vs = [0.1, -0.0, -12345.6789, 5.0e-324, 16777217.0]
  let b = @moon-nrrd.encode_data(vs, h)
  let text = @moon-nrrd.bytes_to_ascii(b)
  assert_true(text.contains("0.1"), msg="0.1 token: \{text}")
  assert_true(text.contains("-0.0"), msg="-0.0 token: \{text}")
  assert_true(text.contains("5e-324") || text.contains("5.0e-324"), msg="5e-324 token: \{text}")
  let vals = @moon-nrrd.decode_data(b, h)
  let mut i = 0
  while i < vs.length() {
    assert_true(enc_sem_eq(vs[i], vals[i]), msg="double ascii value \{i}")
    i = i + 1
  }
}

// ---------------------------------------------------------------------------
// float32 ASCII: shortest round-trip strings cross-read via the
// reader's two-step (decimal -> binary64 -> binary32) policy
// ---------------------------------------------------------------------------

test "float32 ascii shortest tokens and cross-read" {
  let h = enc_hdr("float", "ascii", 4)
  let b = @moon-nrrd.encode_data([0.1, 1.5, 16777216.0, 3.4028234663852886e38], h)
  assert_true(
    @moon-nrrd.bytes_to_ascii(b) == "0.1 1.5 16777216 3.4028235e+38\n",
    msg="got: \{@moon-nrrd.bytes_to_ascii(b)}",
  )
  let vals = @moon-nrrd.decode_data(b, h)
  let orig = [0.1, 1.5, 16777216.0, 3.4028234663852886e38]
  let mut i = 0
  while i < orig.length() {
    // cross-read: value after binary32 storage must round-trip
    assert_true(
      vals[i] == Float::to_double(Float::from_double(orig[i])),
      msg="f32 ascii cross-read \{i}",
    )
    i = i + 1
  }
}

///| 必修 2 regression: the float32 token must describe the STORED
///| binary32 (narrow first, then zero/inf/nan of that stored value).
///| Negative underflow keeps the sign of zero (-1.0e-50 -> -0.0),
///| positive underflow -> +0.0, overflow saturates to signed inf,
///| subnormal boundaries follow ties-to-even — verified through the
///| public encode_data on BOTH raw and ASCII paths.
test "float32 underflow overflow and subnormal boundaries" {
  let hraw = enc_hdr("float", "raw", 1, endian=Some("little"))
  let hascii = enc_hdr("float", "ascii", 1)
  // the audit counter-example: negative underflow must be "-0.0",
  // never a sign-less "0"
  let ba = @moon-nrrd.encode_data([-1.0e-50], hascii)
  assert_true(
    @moon-nrrd.bytes_to_ascii(ba) == "-0.0\n",
    msg="neg underflow ascii token: \{@moon-nrrd.bytes_to_ascii(ba)}",
  )
  let br = @moon-nrrd.encode_data([-1.0e-50], hraw)
  assert_true(enc_bytes_eq(br, [0x00, 0x00, 0x00, 0x80]), msg="neg underflow raw bits")
  // positive underflow -> +0.0
  let ba2 = @moon-nrrd.encode_data([1.0e-50], hascii)
  assert_true(
    @moon-nrrd.bytes_to_ascii(ba2) == "0.0\n",
    msg="pos underflow ascii token: \{@moon-nrrd.bytes_to_ascii(ba2)}",
  )
  let br2 = @moon-nrrd.encode_data([1.0e-50], hraw)
  assert_true(enc_bytes_eq(br2, [0x00, 0x00, 0x00, 0x00]), msg="pos underflow raw bits")
  // overflow saturates to signed infinity (raw + ascii)
  let ha2 = enc_hdr("float", "ascii", 2)
  let ba3 = @moon-nrrd.encode_data([1.0e39, -1.0e39], ha2)
  assert_true(
    @moon-nrrd.bytes_to_ascii(ba3) == "inf -inf\n",
    msg="overflow ascii tokens: \{@moon-nrrd.bytes_to_ascii(ba3)}",
  )
  let hr2 = enc_hdr("float", "raw", 2, endian=Some("big"))
  let br3 = @moon-nrrd.encode_data([1.0e39, -1.0e39], hr2)
  assert_true(
    enc_bytes_eq(br3, [0x7f, 0x80, 0x00, 0x00, 0xff, 0x80, 0x00, 0x00]),
    msg="overflow raw bits",
  )
  // boundary subnormals (ties-to-even verified against IEEE / numpy):
  // 2^-150 (half of min subnormal) -> +0.0; its negation -> -0.0
  let half = 7.006492321624085e-46
  assert_true(
    enc_bytes_eq(@moon-nrrd.encode_data([half], hraw), [0x00, 0x00, 0x00, 0x00]),
    msg="half min subnormal ties to +0.0",
  )
  assert_true(
    @moon-nrrd.bytes_to_ascii(@moon-nrrd.encode_data([half], hascii)) == "0.0\n",
    msg="half min subnormal ascii -> 0.0",
  )
  assert_true(
    enc_bytes_eq(@moon-nrrd.encode_data([0.0 - half], hraw), [0x00, 0x00, 0x00, 0x80]),
    msg="neg half min subnormal ties to -0.0",
  )
  assert_true(
    @moon-nrrd.bytes_to_ascii(@moon-nrrd.encode_data([0.0 - half], hascii)) == "-0.0\n",
    msg="neg half min subnormal ascii -> -0.0",
  )
  // min subnormal 2^-149 -> 0x00000001, ascii "1e-45"
  assert_true(
    enc_bytes_eq(
      @moon-nrrd.encode_data([1.401298464324817e-45], hraw),
      [0x01, 0x00, 0x00, 0x00],
    ),
    msg="min subnormal raw",
  )
  assert_true(
    @moon-nrrd.bytes_to_ascii(@moon-nrrd.encode_data([1.401298464324817e-45], hascii)) == "1e-45\n",
    msg="min subnormal ascii",
  )
  // 2 ulp subnormal -> 0x00000002
  assert_true(
    enc_bytes_eq(
      @moon-nrrd.encode_data([2.802596928649634e-45], hraw),
      [0x02, 0x00, 0x00, 0x00],
    ),
    msg="2-ulp subnormal raw",
  )
  // native -0.0: raw sign bit and ascii token agree
  assert_true(
    enc_bytes_eq(@moon-nrrd.encode_data([-0.0], hraw), [0x00, 0x00, 0x00, 0x80]),
    msg="native -0.0 raw",
  )
  assert_true(
    @moon-nrrd.bytes_to_ascii(@moon-nrrd.encode_data([-0.0], hascii)) == "-0.0\n",
    msg="native -0.0 ascii",
  )
  // raw/ascii cross-check on the stored value: both decode to the
  // same binary32 with the same sign of zero
  let vr = @moon-nrrd.decode_data(@moon-nrrd.encode_data([-1.0e-50], hraw), hraw)
  let va = @moon-nrrd.decode_data(@moon-nrrd.encode_data([-1.0e-50], hascii), hascii)
  assert_true(
    Float::reinterpret_as_int(Float::from_double(vr[0])) == -2147483648,
    msg="raw decode keeps -0.0",
  )
  assert_true(
    Float::reinterpret_as_int(Float::from_double(va[0])) == -2147483648,
    msg="ascii decode keeps -0.0",
  )
}

// ---------------------------------------------------------------------------
// sizes / budget / assembly
// ---------------------------------------------------------------------------

///| sizes product must match the values length exactly.
test "sizes and values length mismatch is rejected" {
  let h = enc_hdr("int16", "raw", 3, endian=Some("little"))
  let m = enc_data_err([1.0, 2.0], h)
  assert_true(m.contains("does not match values length"), msg="got: \{m}")
}

///| Budget negative: element count over budget refuses before
///| building output (budget~ is injectable).
test "encode budget refusal is real" {
  let h = enc_hdr("int16", "raw", 5, endian=Some("little"))
  let m = enc_data_err_budget([0.0, 0.0, 0.0, 0.0, 0.0], h, 4)
  assert_true(m.contains("allocation budget"), msg="got: \{m}")
  // and with the default budget the same payload succeeds
  assert_true(enc_data_err([0.0, 0.0, 0.0, 0.0, 0.0], h) == "", msg="default budget ok")
}

///| Dimension product overflow is refused before allocating (this
///| is the element-side product pre-check).
test "dimension product overflow is refused" {
  let h = @moon-nrrd.NrrdHeader::{
    dimension: 2,
    sizes: [65536, 65536],
    type_name: "double",
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
  let m = enc_data_err([0.0], h)
  assert_true(m.contains("overflow"), msg="got: \{m}")
}

///| Raw byte-product pre-check (division style): count * item must
///| not wrap Int. Reachable only with a raised budget; a tiny values
///| array is enough because the check runs before the length check.
test "raw byte product overflow is refused" {
  let h = @moon-nrrd.NrrdHeader::{
    dimension: 1,
    sizes: [536870912], // 2^29
    type_name: "double", // 8 bytes -> 2^32 total
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
  let m = enc_data_err_budget([0.0], h, 1073741824) // budget 2^30: only the byte check can fire
  assert_true(m.contains("byte length overflow"), msg="got: \{m}")
}

///| Attached assembly: refuses a data file declaration, output is
///| header + blank line + payload and re-splits through the reader.
test "assemble_attached builds a split-able file" {
  let h = enc_hdr("int8", "raw", 2, endian=Some("little"), content=Some("att"))
  let full = @moon-nrrd.assemble_attached(h, [1.0, -1.0])
  let (hbytes, body) = @moon-nrrd.split_header_body(full)
  let h2 = @moon-nrrd.parse_header(@moon-nrrd.bytes_to_ascii(hbytes))
  assert_true(h2.content == Some("att"), msg="content")
  assert_true(enc_bytes_eq(body, [0x01, 0xff]), msg="payload bytes")
  let bad = enc_hdr("int8", "raw", 1, endian=Some("little"), data_file=Some("x.raw"))
  let mut raised = false
  try {
    let _unused = @moon-nrrd.assemble_attached(bad, [1.0])
  } catch {
    @moon-nrrd.NrrdError(m) => {
      raised = true
      assert_true(m.contains("must not declare"), msg="got: \{m}")
    }
  }
  assert_true(raised, msg="attached+data file must raise")
}

///| Detached assembly: requires a data file name; the header bytes
///| end with the blank-line terminator and carry no payload.
test "assemble_detached splits header and payload" {
  let h = enc_hdr("uint16", "raw", 2, endian=Some("big"), data_file=Some("d.raw"))
  let (head, payload) = @moon-nrrd.assemble_detached(h, [1.0, 258.0])
  assert_true(
    head.length() >= 2 &&
      head[head.length() - 1].to_int() == 10 &&
      head[head.length() - 2].to_int() == 10,
    msg="header must end with blank line",
  )
  assert_true(enc_bytes_eq(payload, [0x00, 0x01, 0x01, 0x02]), msg="detached payload BE")
  let h2 = @moon-nrrd.parse_header(@moon-nrrd.bytes_to_ascii(head))
  assert_true(h2.data_file == Some("d.raw"), msg="data file kept")
  let no_name = enc_hdr("uint16", "raw", 1, endian=Some("big"))
  let mut raised = false
  try {
    let _unused = @moon-nrrd.assemble_detached(no_name, [1.0])
  } catch {
    @moon-nrrd.NrrdError(m) => {
      raised = true
      assert_true(m.contains("requires a data file"), msg="got: \{m}")
    }
  }
  assert_true(raised, msg="detached without name must raise")
}

///| Count non-overlapping occurrences of a substring.
fn enc_count_sub(hay : String, needle : String) -> Int {
  let hl = hay.length()
  let nl = needle.length()
  let mut n = 0
  let mut i = 0
  while i + nl <= hl {
    if hay[i:i+nl].to_owned() == needle {
      n = n + 1
      i = i + nl
    } else {
      i = i + 1
    }
  }
  n
}

///| 必修 1 regression: every writable string field rejects non-ASCII
///| with a catchable NrrdError — never a silent low-byte truncation
///| (U+010A Ċ -> 0x0A would inject a header line) and never a panic
///| on supplementary-plane UTF-16 (emoji surrogate pair).
test "non-ASCII is rejected in every writable string field" {
  let mk_content = fn(c : String) -> @moon-nrrd.NrrdHeader {
    @moon-nrrd.NrrdHeader::{
      dimension: 1,
      sizes: [1],
      type_name: "int8",
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
      content: Some(c),
      line_skip: 0,
      byte_skip: 0,
    }
  }
  // Ċ (U+010A): low byte is 0x0A — the exact injection反例
  assert_true(
    enc_hdr_err(mk_content("Ċtype: uint8")).contains("non-ASCII"),
    msg="C-dot content: \{enc_hdr_err(mk_content("Ċtype: uint8"))}",
  )
  // 中文 (CJK)
  assert_true(
    enc_hdr_err(mk_content("中文内容")).contains("non-ASCII"),
    msg="CJK content",
  )
  // emoji (supplementary plane, UTF-16 surrogate pair on js):
  // must raise (non-ASCII or invalid code unit), never panic
  let em = enc_hdr_err(mk_content("x😀y"))
  assert_true(
    em.contains("non-ASCII") || em.contains("invalid UTF-16"),
    msg="emoji content: \{em}",
  )
  // data file
  let h_df = @moon-nrrd.NrrdHeader::{
    dimension: 1,
    sizes: [1],
    type_name: "int8",
    encoding: "raw",
    endian: Some("little"),
    data_file: Some("Ċ.raw"),
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
  assert_true(enc_hdr_err(h_df).contains("non-ASCII"), msg="data file")
  // labels (quoted token path)
  let h_lb = @moon-nrrd.NrrdHeader::{
    dimension: 1,
    sizes: [1],
    type_name: "int8",
    encoding: "raw",
    endian: Some("little"),
    data_file: None,
    space: None,
    space_dimension: None,
    space_origin: None,
    space_directions: [],
    space_units: None,
    labels: Some(["Ċ"]),
    kinds: None,
    content: None,
    line_skip: 0,
    byte_skip: 0,
  }
  assert_true(enc_hdr_err(h_lb).contains("non-ASCII"), msg="labels")
  // space units (quoted token path)
  let h_su = @moon-nrrd.NrrdHeader::{
    dimension: 1,
    sizes: [1],
    type_name: "int8",
    encoding: "raw",
    endian: Some("little"),
    data_file: None,
    space: None,
    space_dimension: None,
    space_origin: None,
    space_directions: [],
    space_units: Some(["mmĊ"]),
    labels: None,
    kinds: None,
    content: None,
    line_skip: 0,
    byte_skip: 0,
  }
  assert_true(enc_hdr_err(h_su).contains("non-ASCII"), msg="space units")
  // space
  let h_sp = @moon-nrrd.NrrdHeader::{
    dimension: 1,
    sizes: [1],
    type_name: "int8",
    encoding: "raw",
    endian: Some("little"),
    data_file: None,
    space: Some("RAĊ"),
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
  assert_true(enc_hdr_err(h_sp).contains("non-ASCII"), msg="space")
  // kinds (bare token path)
  let h_kd = @moon-nrrd.NrrdHeader::{
    dimension: 1,
    sizes: [1],
    type_name: "int8",
    encoding: "raw",
    endian: Some("little"),
    data_file: None,
    space: None,
    space_dimension: None,
    space_origin: None,
    space_directions: [],
    space_units: None,
    labels: None,
    kinds: Some(["domainĊ"]),
    content: None,
    line_skip: 0,
    byte_skip: 0,
  }
  assert_true(enc_hdr_err(h_kd).contains("non-ASCII"), msg="kinds")
  // key:=value key and value
  assert_true(
    enc_kv_err("kĊ", "v").contains("non-ASCII"),
    msg="keyval key: \{enc_kv_err("kĊ", "v")}",
  )
  assert_true(
    enc_kv_err("k", "Ċv").contains("non-ASCII"),
    msg="keyval value: \{enc_kv_err("k", "Ċv")}",
  )
  // 转义符 policy still holds alongside the ASCII contract:
  // quote is the only escape in quoted tokens; backslash rejected
  let h_bs = @moon-nrrd.NrrdHeader::{
    dimension: 1,
    sizes: [1],
    type_name: "int8",
    encoding: "raw",
    endian: Some("little"),
    data_file: None,
    space: None,
    space_dimension: None,
    space_origin: None,
    space_directions: [],
    space_units: None,
    labels: Some(["a\\b"]),
    kinds: None,
    content: None,
    line_skip: 0,
    byte_skip: 0,
  }
  assert_true(enc_hdr_err(h_bs).contains("backslash"), msg="backslash in labels")
  // keyval value escapes backslash (does not reject) and never leaks
  // a raw newline into the line
  let kv = @moon-nrrd.format_keyval_line("k", "a\\b\nc")
  assert_true(kv.contains("a\\\\b\\nc"), msg="keyval escapes: \{kv}")
  assert_true(!kv.contains("\n"), msg="no raw newline in keyval line")
}

///| 必修 1 regression on the public assembly paths: injection
///| attempts raise catchable NrrdError (no bytes escape), and a
///| legal header's final bytes carry no injected field and exactly
///| one blank line (the header terminator) — no early blank line.
test "assembly rejects injection and emits one blank line" {
  // attached: the exact audit counter-example
  let h = enc_hdr("int8", "raw", 1, endian=Some("little"), content=Some("Ċtype: uint8"))
  let mut raised = false
  try {
    let _b = @moon-nrrd.assemble_attached(h, [1.0])
  } catch {
    @moon-nrrd.NrrdError(m) => {
      raised = true
      assert_true(m.contains("non-ASCII"), msg="attached attack: \{m}")
    }
  }
  assert_true(raised, msg="attached injection must raise")
  // attached: legal content with an interior colon must not gain
  // extra fields or an early blank line in the final bytes
  let ok = enc_hdr("int8", "raw", 1, endian=Some("little"), content=Some("ok: still ok"))
  let full = @moon-nrrd.assemble_attached(ok, [1.0])
  let text = @moon-nrrd.bytes_to_ascii(full)
  assert_true(text.contains("content: ok: still ok\n"), msg="content kept")
  assert_true(enc_count_sub(text, "type: ") == 1, msg="one type line: \{text}")
  assert_true(
    enc_count_sub(text, "\n\n") == 1,
    msg="exactly one blank line (terminator): \{text}",
  )
  // detached: injection via data file and via content both raise
  let h_df = enc_hdr("int8", "raw", 1, endian=Some("little"), data_file=Some("Ċ\nx.raw"))
  let mut raised2 = false
  try {
    let _pair = @moon-nrrd.assemble_detached(h_df, [1.0])
  } catch {
    @moon-nrrd.NrrdError(_m) => raised2 = true
  }
  assert_true(raised2, msg="detached data-file injection must raise")
  let h_ct = enc_hdr("int8", "raw", 1, endian=Some("little"), data_file=Some("d.raw"), content=Some("Ċ\nencoding: raw"))
  let mut raised3 = false
  try {
    let _pair = @moon-nrrd.assemble_detached(h_ct, [1.0])
  } catch {
    @moon-nrrd.NrrdError(_m) => raised3 = true
  }
  assert_true(raised3, msg="detached content injection must raise")
  // detached: legal output ends with exactly one blank line before
  // the (separate) payload
  let ok2 = enc_hdr("uint16", "raw", 1, endian=Some("big"), data_file=Some("d.raw"), content=Some("ok: still ok"))
  let (head, payload) = @moon-nrrd.assemble_detached(ok2, [1.0])
  let htext = @moon-nrrd.bytes_to_ascii(head)
  assert_true(enc_count_sub(htext, "\n\n") == 1, msg="detached head blank line: \{htext}")
  assert_true(
    head.length() >= 2 &&
      head[head.length() - 1].to_int() == 10 &&
      head[head.length() - 2].to_int() == 10,
    msg="detached head ends with blank line",
  )
  assert_true(enc_count_sub(htext, "type: ") == 1, msg="detached one type line")
  assert_true(enc_bytes_eq(payload, [0x00, 0x01]), msg="detached payload intact")
}
