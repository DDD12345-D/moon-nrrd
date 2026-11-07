///| Negative checks: errors must surface, never look like success.
test "truncated raw data raises" {
  let text = "NRRD0005\ntype: int16\ndimension: 1\nsizes: 4\nencoding: raw\nendian: little\n\n"
  let payload = @moon-nrrd.ascii_to_bytes("xx") // 2 bytes, need 8
  let (hbytes, _) = @moon-nrrd.split_header_body(@moon-nrrd.ascii_to_bytes(text))
  let h = @moon-nrrd.parse_header(@moon-nrrd.bytes_to_ascii(hbytes))
  let mut raised = false
  try {
    let _unused = @moon-nrrd.decode_data(payload, h)
  } catch {
    _ => raised = true
  }
  assert_true(raised, msg="truncated data must raise")
}

///| Wrong value count in ascii data raises.
test "ascii value count mismatch raises" {
  let text = "NRRD0005\ntype: int16\ndimension: 1\nsizes: 4\nencoding: ascii\n\n1 2 3"
  let data = @moon-nrrd.ascii_to_bytes(text)
  let (hbytes, body) = @moon-nrrd.split_header_body(data)
  let h = @moon-nrrd.parse_header(@moon-nrrd.bytes_to_ascii(hbytes))
  let mut raised = false
  try {
    let _unused = @moon-nrrd.decode_data(body, h)
  } catch {
    _ => raised = true
  }
  assert_true(raised, msg="short ascii data must raise")
}

///| raw without endian field raises.
test "raw multi-byte without endian raises" {
  let text = "NRRD0005\ntype: int16\ndimension: 1\nsizes: 2\nencoding: raw\n\n"
  let (hbytes, body) = @moon-nrrd.split_header_body(@moon-nrrd.ascii_to_bytes(text))
  let h = @moon-nrrd.parse_header(@moon-nrrd.bytes_to_ascii(hbytes))
  let mut raised = false
  try {
    let _unused = @moon-nrrd.decode_data(body, h)
  } catch {
    _ => raised = true
  }
  assert_true(raised, msg="missing endian must raise")
}

///| Unsupported encodings/types raise instead of guessing.
test "gzip encoding is rejected by the g1 probe" {
  let text = "NRRD0005\ntype: int16\ndimension: 1\nsizes: 2\nencoding: gzip\nendian: little\n\n"
  let (hbytes, body) = @moon-nrrd.split_header_body(@moon-nrrd.ascii_to_bytes(text))
  let h = @moon-nrrd.parse_header(@moon-nrrd.bytes_to_ascii(hbytes))
  let mut raised = false
  try {
    let _unused = @moon-nrrd.decode_data(body, h)
  } catch {
    _ => raised = true
  }
  assert_true(raised, msg="gzip must raise in g1 probe")
}

///| Dimension product overflow is refused before allocating.
test "oversized dimension product raises" {
  let text = "NRRD0005\ntype: int16\ndimension: 2\nsizes: 100000 100000\nencoding: raw\nendian: little\n\n"
  let (hbytes, body) = @moon-nrrd.split_header_body(@moon-nrrd.ascii_to_bytes(text))
  let h = @moon-nrrd.parse_header(@moon-nrrd.bytes_to_ascii(hbytes))
  let mut raised = false
  try {
    let _unused = @moon-nrrd.decode_data(body, h)
  } catch {
    _ => raised = true
  }
  assert_true(raised, msg="overflow must raise")
}

///| Oversized values in header integer fields are rejected (regression).
test "oversized header sizes and dimension raise" {
  let text1 = "NRRD0005\ntype: int16\ndimension: 1\nsizes: 99999999999\nencoding: raw\nendian: little\n\n"
  let (h1, _) = @moon-nrrd.split_header_body(@moon-nrrd.ascii_to_bytes(text1))
  let mut raised = false
  try {
    let _unused = @moon-nrrd.parse_header(@moon-nrrd.bytes_to_ascii(h1))
  } catch {
    _ => raised = true
  }
  assert_true(raised, msg="oversized sizes must raise")
  let text2 = "NRRD0005\ntype: int16\ndimension: 4294967297\nsizes: 1\nencoding: raw\nendian: little\n\n"
  let (h2, _) = @moon-nrrd.split_header_body(@moon-nrrd.ascii_to_bytes(text2))
  let mut raised2 = false
  try {
    let _unused = @moon-nrrd.parse_header(@moon-nrrd.bytes_to_ascii(h2))
  } catch {
    _ => raised2 = true
  }
  assert_true(raised2, msg="oversized dimension must raise")
}

///| line/byte skip are rejected by the probe (regression: claimed in the
///| matrix without a negative test before; now tested).
test "line skip and byte skip are rejected" {
  let text = "NRRD0005\ntype: int16\ndimension: 1\nsizes: 2\nencoding: raw\nendian: little\nline skip: 1\n\nxxxx"
  let (hbytes, body) = @moon-nrrd.split_header_body(@moon-nrrd.ascii_to_bytes(text))
  let h = @moon-nrrd.parse_header(@moon-nrrd.bytes_to_ascii(hbytes))
  let mut raised = false
  try {
    let _unused = @moon-nrrd.decode_data(body, h)
  } catch {
    _ => raised = true
  }
  assert_true(raised, msg="line skip must raise")
  let text2 = "NRRD0005\ntype: int16\ndimension: 1\nsizes: 2\nencoding: raw\nendian: little\nbyte skip: 2\n\nxxxxxx"
  let (h2bytes, body2) = @moon-nrrd.split_header_body(@moon-nrrd.ascii_to_bytes(text2))
  let h2 = @moon-nrrd.parse_header(@moon-nrrd.bytes_to_ascii(h2bytes))
  let mut raised2 = false
  try {
    let _unused = @moon-nrrd.decode_data(body2, h2)
  } catch {
    _ => raised2 = true
  }
  assert_true(raised2, msg="byte skip must raise")
}

///| Allocation budget: element count above 2^24 is refused BEFORE
///| any allocation (wasm OOM is an uncatchable trap; the guard must
///| be upfront). No large payload is materialized in this test.
test "allocation budget refuses huge element counts" {
  let text = "NRRD0005\ntype: float\ndimension: 1\nsizes: 16777217\nencoding: raw\nendian: little\n\n"
  let (hbytes, body) = @moon-nrrd.split_header_body(@moon-nrrd.ascii_to_bytes(text))
  let h = @moon-nrrd.parse_header(@moon-nrrd.bytes_to_ascii(hbytes))
  let mut msg = ""
  try {
    let _unused = @moon-nrrd.decode_data(body, h)
  } catch {
    e => {
      msg = match e {
        @moon-nrrd.NrrdError(m) => m
      }
    }
  }
  assert_true(msg.contains("allocation budget"), msg="must hit budget, got: \{msg}")
  // exactly at the budget is still accepted structurally (fails later on
  // truncation instead — tiny payload, so it must be a truncation error)
  let text2 = "NRRD0005\ntype: float\ndimension: 1\nsizes: 16777216\nencoding: raw\nendian: little\n\n"
  let (h2bytes, body2) = @moon-nrrd.split_header_body(@moon-nrrd.ascii_to_bytes(text2))
  let h2 = @moon-nrrd.parse_header(@moon-nrrd.bytes_to_ascii(h2bytes))
  let mut msg2 = ""
  try {
    let _unused = @moon-nrrd.decode_data(body2, h2)
  } catch {
    e => {
      msg2 = match e {
        @moon-nrrd.NrrdError(m) => m
      }
    }
  }
  assert_true(
    msg2.contains("truncated"),
    msg="at budget the error must be truncation, got: \{msg2}",
  )
}

///| ASCII float values are rounded to binary32 (NRRD "float"), matching
///| pynrrd/numpy: 0.1 -> 0.10000000149011612, 16777217 -> 16777216
///| (ties-to-even), 1e40 overflows to +inf, 1e-45 rounds to one subnormal
///| ulp, 3.4028235e38 rounds to binary32 max.
test "ascii float is rounded to binary32" {
  let text = "NRRD0005\ntype: float\ndimension: 1\nsizes: 5\nencoding: ascii\n\n0.1 16777217 1e40 1e-45 3.4028235e38"
  let data = @moon-nrrd.ascii_to_bytes(text)
  let (hbytes, body) = @moon-nrrd.split_header_body(data)
  let h = @moon-nrrd.parse_header(@moon-nrrd.bytes_to_ascii(hbytes))
  let v = @moon-nrrd.decode_data(body, h)
  assert_true(v[0] == 0.10000000149011612, msg="0.1 -> float32")
  assert_true(v[1] == 16777216.0, msg="16777217 ties-to-even -> 2^24")
  assert_true(v[2].is_pos_inf(), msg="1e40 overflows float32 -> +inf")
  assert_true(v[3] == 1.401298464324817e-45, msg="1e-45 -> one subnormal ulp")
  assert_true(v[4] == 3.4028234663852886e38, msg="3.4028235e38 -> binary32 max")
}

///| ASCII -0.0 must keep its sign through decode and format (regression:
///| print used to collapse it to 0.0).
test "ascii negative zero keeps its sign" {
  let text = "NRRD0005\ntype: float\ndimension: 1\nsizes: 2\nencoding: ascii\n\n-0.0 0.0"
  let data = @moon-nrrd.ascii_to_bytes(text)
  let (hbytes, body) = @moon-nrrd.split_header_body(data)
  let h = @moon-nrrd.parse_header(@moon-nrrd.bytes_to_ascii(hbytes))
  let v = @moon-nrrd.decode_data(body, h)
  assert_true(@moon-nrrd.format_float(v[0]) == "-0.0", msg="-0.0 prints as -0.0")
  assert_true(@moon-nrrd.format_float(v[1]) == "0.0", msg="+0.0 prints as 0.0")
}
