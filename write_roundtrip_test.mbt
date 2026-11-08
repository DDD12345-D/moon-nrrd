///| Write-side 48-cell self round-trip (supplementary evidence):
///| 8 types x {raw-le, raw-be, ascii} x {attached, detached}.
///| Each cell WRITES with assemble_attached / assemble_detached and
///| READS BACK through the public read path (split_header_body ->
///| parse_header -> decode_data). Values are compared semantically
///| (nan==nan, signed zeros distinct); float cells compare against
///| the binary32-reduced value (storage rounding is part of the
///| contract). This is the in-process supplement to the external
///| "we write -> pynrrd reads" evidence in tests/check_write_reference.py.
///|
///| Value sets mirror tests/gen_fixtures.py TYPES (kept in sync by
///| the external checker); they are inputs here, not expectations
///| back-filled from any reader.

///| Value set per canonical type (see tests/gen_fixtures.py TYPES).
fn wr_values(t : String) -> Array[Double] {
  match t {
    "int8" => [-128.0, -100.0, -1.0, 0.0, 1.0, 64.0, 100.0, 127.0]
    "uint8" => [0.0, 1.0, 2.0, 64.0, 127.0, 128.0, 200.0, 255.0]
    "int16" => [-32768.0, -12345.0, -1.0, 0.0, 1.0, 256.0, 12345.0, 32767.0]
    "uint16" => [0.0, 1.0, 255.0, 256.0, 32767.0, 32768.0, 12345.0, 65535.0]
    "int32" => [-2147483648.0, -1000000000.0, -1.0, 0.0, 1.0, 65536.0, 1000000000.0, 2147483647.0]
    "uint32" => [
      0.0, 1.0, 65536.0, 2147483647.0, 2147483648.0, 3000000000.0, 4000000000.0, 4294967295.0,
    ]
    "float" => [
      0.0, -0.0, 1.0, -1.5, 0.1, 16777216.0, 3.4028234663852886e38,
      1.1754943508222875e-38, 1.401298464324817e-45, @double.not_a_number, @double.infinity,
      @double.neg_infinity,
    ]
    _ => [
      0.0, -0.0, 0.1, -1.5, -12345.6789, 16777217.0, 1.7976931348623157e308,
      2.2250738585072014e-308, 5.0e-324, @double.not_a_number, @double.infinity,
      @double.neg_infinity,
    ]
  }
}

///| Header factory for the round-trip grid.
fn wr_hdr(
  t : String,
  e : String,
  endian : String?,
  n : Int,
  data_file : String?,
  content : String,
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
    content: Some(content),
    line_skip: 0,
    byte_skip: 0,
  }
}

///| Compare written-then-read values against the originals
///| (float: after binary32 storage rounding). Returns "" or a
///| mismatch description (kept effect-free so it can be called
///| from anywhere).
fn wr_check(t : String, vs : Array[Double], got : Array[Double]) -> String {
  if got.length() != vs.length() {
    return "count for \{t}: want \{vs.length()} got \{got.length()}"
  }
  let mut i = 0
  while i < vs.length() {
    let want = if t == "float" {
      Float::to_double(Float::from_double(vs[i]))
    } else {
      vs[i]
    }
    if !enc_sem_eq(want, got[i]) {
      return "\{t} value \{i} mismatch"
    }
    i = i + 1
  }
  ""
}

///| The full 48-cell matrix, written and read back in-process.
test "48-cell write self round-trip" {
  let types = [
    "int8", "uint8", "int16", "uint16", "int32", "uint32", "float", "double",
  ]
  let mut cells = 0
  for t in types {
    let vs = wr_values(t)
    let n = vs.length()
    // (encoding, endian) grid: raw-le / raw-be / ascii
    let cfgs : Array[(String, String?)] = [
      ("raw", Some("little")),
      ("raw", Some("big")),
      ("ascii", None),
    ]
    let enc_ids = ["raw-le", "raw-be", "ascii"]
    let mut ci = 0
    while ci < cfgs.length() {
      let (e, endian) = cfgs[ci]
      let enc_id = enc_ids[ci]
      // attached
      let h = wr_hdr(t, e, endian, n, None, "\{t}/\{enc_id}/att")
      let full = @moon-nrrd.assemble_attached(h, vs)
      let (hb, body) = @moon-nrrd.split_header_body(full)
      let h2 = @moon-nrrd.parse_header(@moon-nrrd.bytes_to_ascii(hb))
      assert_true(h2.content == Some("\{t}/\{enc_id}/att"), msg="att content \{t}/\{enc_id}")
      let err1 = wr_check(t, vs, @moon-nrrd.decode_data(body, h2))
      assert_true(err1 == "", msg="\{t}/\{enc_id}/att: \{err1}")
      cells = cells + 1
      // detached
      let hd = wr_hdr(t, e, endian, n, Some("data.bin"), "\{t}/\{enc_id}/det")
      let (head, payload) = @moon-nrrd.assemble_detached(hd, vs)
      let h3 = @moon-nrrd.parse_header(@moon-nrrd.bytes_to_ascii(head))
      assert_true(h3.data_file == Some("data.bin"), msg="det data file \{t}/\{enc_id}")
      let err2 = wr_check(t, vs, @moon-nrrd.decode_data(payload, h3))
      assert_true(err2 == "", msg="\{t}/\{enc_id}/det: \{err2}")
      cells = cells + 1
      ci = ci + 1
    }
  }
  assert_true(cells == 48, msg="expected 48 cells, got \{cells}")
}

///| Bytes equality (byte-by-byte).
fn wr_bytes_eq(a : Bytes, b : Bytes) -> Bool {
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

///| Single-byte types: raw-le and raw-be are byte-identical (the 8
///| 同义 cells of the 48-grid) even though the endian FIELD differs.
test "single-byte raw-le/raw-be payloads are identical" {
  for t in ["int8", "uint8"] {
    let vs = wr_values(t)
    let n = vs.length()
    let hle = wr_hdr(t, "raw", Some("little"), n, None, "le")
    let hbe = wr_hdr(t, "raw", Some("big"), n, None, "be")
    let ble = @moon-nrrd.encode_data(vs, hle)
    let bbe = @moon-nrrd.encode_data(vs, hbe)
    assert_true(wr_bytes_eq(ble, bbe), msg="\{t}: single-byte payloads must match")
    // and the headers still differ in their endian field
    let sle = @moon-nrrd.format_header(hle)
    let sbe = @moon-nrrd.format_header(hbe)
    assert_true(sle.contains("endian: little"), msg="le header")
    assert_true(sbe.contains("endian: big"), msg="be header")
  }
}
