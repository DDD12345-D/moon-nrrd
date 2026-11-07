///| G1 probe self-checks (header splitting/parsing on synthetic input).
test "ascii bytes helper roundtrip" {
  let text = "NRRD0005\ntype: int16\n\n"
  let data = @moon-nrrd.ascii_to_bytes(text)
  assert_true(data.length() == text.length(), msg="len \{data.length()} vs \{text.length()}")
  assert_true(data[0] == b'N', msg="data[0]=\{data[0].to_int()}")
  assert_true(data[8] == b'\n', msg="data[8]=\{data[8].to_int()}")
  assert_true(@moon-nrrd.bytes_to_ascii(data) == text, msg="roundtrip")
}

///|
test "split and parse a minimal header" {
  let text = "NRRD0005\ntype: int16\ndimension: 3\nsizes: 2 3 4\nencoding: raw\nendian: little\n\n"
  let data = @moon-nrrd.ascii_to_bytes(text)
  let (hbytes, bbytes) = @moon-nrrd.split_header_body(data)
  let htext = @moon-nrrd.bytes_to_ascii(hbytes)
  assert_true(htext.has_prefix("NRRD"), msg="header text: [\{htext}]")
  let h = @moon-nrrd.parse_header(htext)
  assert_true(h.dimension == 3, msg="dimension")
  assert_true(h.sizes[0] == 2 && h.sizes[1] == 3 && h.sizes[2] == 4, msg="sizes")
  assert_true(h.type_name == "int16", msg="type")
  assert_true(h.encoding == "raw", msg="encoding")
  assert_true(h.endian == Some("little"), msg="endian")
  assert_true(bbytes.length() == 0, msg="body should be empty")
}

///| CRLF terminators must work too.
test "split and parse a CRLF header" {
  let text = "NRRD0005\r\ntype: float\r\ndimension: 1\r\nsizes: 4\r\nencoding: ascii\r\n\r\n1 2 3 4"
  let data = @moon-nrrd.ascii_to_bytes(text)
  let (hbytes, bbytes) = @moon-nrrd.split_header_body(data)
  let h = @moon-nrrd.parse_header(@moon-nrrd.bytes_to_ascii(hbytes))
  assert_true(h.type_name == "float", msg="type")
  assert_true(h.encoding == "ascii", msg="encoding")
  assert_true(h.endian == None, msg="endian should be absent")
  assert_true(@moon-nrrd.bytes_to_ascii(bbytes) == "1 2 3 4", msg="body: [\{@moon-nrrd.bytes_to_ascii(bbytes)}]")
}

///| Detached header: blank line then nothing; key:=value pairs ignored.
test "parse header with key-value pairs and comments" {
  let text = "NRRD0005\n# a comment\nfoo:=bar\ntype: short\ndimension: 1\nsizes: 3\nencoding: ascii\n\n"
  let (hbytes, _) = @moon-nrrd.split_header_body(@moon-nrrd.ascii_to_bytes(text))
  let h = @moon-nrrd.parse_header(@moon-nrrd.bytes_to_ascii(hbytes))
  assert_true(h.type_name == "int16", msg="alias short -> int16")
  assert_true(h.encoding == "ascii", msg="encoding")
}
