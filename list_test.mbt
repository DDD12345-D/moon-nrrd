///| LIST detached data file reassembly tests.
///| Covers default subdim (D-1), explicit subdim, subdim=D slabs,
///| missing file (chunk count mismatch), and wrong chunk size.
///| Blackbox: uses the public API with try/catch for raise functions.

///| Minimal LIST header factory (raw uint8, no spatial metadata).
fn list_hdr(
  sizes : Array[Int],
  filenames : Array[String],
  subdim~ : Int? = None,
  type_name~ : String = "uint8",
  encoding~ : String = "raw",
) -> @moon-nrrd.NrrdHeader {
  @moon-nrrd.NrrdHeader::{
    dimension: sizes.length(),
    sizes: sizes.copy(),
    type_name: type_name,
    encoding: encoding,
    endian: None,
    data_file: if subdim is Some(v) { Some("LIST \{v}") } else { Some("LIST") },
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
    list_filenames: Some(filenames.copy()),
    data_file_subdim: subdim,
  }
}

///| Build a raw byte array of sequential values.
fn raw_chunk(vals : Array[Int]) -> Bytes {
  let arr = Array::make(vals.length(), b'\x00')
  for i = 0; i < vals.length(); i = i + 1 {
    arr[i] = vals[i].to_byte()
  }
  Bytes::from_array(arr)
}

///| Call reassemble_list_data and return the error message ("" on success).
fn reassemble_err(
  chunks : Array[Bytes],
  h : @moon-nrrd.NrrdHeader,
) -> String {
  try {
    let _unused = @moon-nrrd.reassemble_list_data(chunks, h)
    ""
  } catch {
    @moon-nrrd.NrrdError(m) => m
    _ => "unknown error"
  }
}

///| T1: default subdim (D-1). sizes [2,3,4], 4 files × 6 values.
///| File i holds the slice at slowest-axis index i (values 6i..6i+5).
test "list default subdim reassembles in order" {
  let sizes = [2, 3, 4]
  let names = ["s0.raw", "s1.raw", "s2.raw", "s3.raw"]
  let h = list_hdr(sizes, names)
  let chunks = [
    raw_chunk([0, 1, 2, 3, 4, 5]),
    raw_chunk([6, 7, 8, 9, 10, 11]),
    raw_chunk([12, 13, 14, 15, 16, 17]),
    raw_chunk([18, 19, 20, 21, 22, 23]),
  ]
  let err = reassemble_err(chunks, h)
  assert_eq(err, "")
  try {
    let out = @moon-nrrd.reassemble_list_data(chunks, h)
    assert_eq(out.length(), 24)
    // Verify linear order: index 0..23
    let mut ok = true
    for i = 0; i < 24; i = i + 1 {
      if out[i] != i.to_byte() {
        ok = false
      }
    }
    assert_true(ok)
  } catch {
    @moon-nrrd.NrrdError(m) => fail(m)
    _ => fail("unexpected error")
  }
}

///| T2: explicit subdim = 1. sizes [2,3,4], 12 files × 2 values.
///| Each file holds one 1-D slice along the fastest axis.
test "list explicit subdim=1" {
  let sizes = [2, 3, 4]
  let names : Array[String] = []
  for idx = 0; idx < 12; idx = idx + 1 {
    names.push("f\{idx}.raw")
  }
  let h = list_hdr(sizes, names, subdim=Some(1))
  let chunks : Array[Bytes] = []
  for idx = 0; idx < 12; idx = idx + 1 {
    chunks.push(raw_chunk([idx * 2, idx * 2 + 1]))
  }
  let err = reassemble_err(chunks, h)
  assert_eq(err, "")
  try {
    let out = @moon-nrrd.reassemble_list_data(chunks, h)
    assert_eq(out.length(), 24)
    let mut ok = true
    for i = 0; i < 24; i = i + 1 {
      if out[i] != i.to_byte() {
        ok = false
      }
    }
    assert_true(ok)
  } catch {
    @moon-nrrd.NrrdError(m) => fail(m)
    _ => fail("unexpected error")
  }
}

///| T3: subdim = D (slabs). sizes [2,2,4], subdim=3, 2 slabs × 8 values.
///| 2 divides slowest axis 4. Slab j covers slowest indices j*2..j*2+1.
test "list subdim=D slabs" {
  let sizes = [2, 2, 4]
  let names = ["slab0.raw", "slab1.raw"]
  let h = list_hdr(sizes, names, subdim=Some(3))
  let chunks = [
    raw_chunk([0, 1, 2, 3, 4, 5, 6, 7]),
    raw_chunk([8, 9, 10, 11, 12, 13, 14, 15]),
  ]
  let err = reassemble_err(chunks, h)
  assert_eq(err, "")
  try {
    let out = @moon-nrrd.reassemble_list_data(chunks, h)
    assert_eq(out.length(), 16)
    let mut ok = true
    for i = 0; i < 16; i = i + 1 {
      if out[i] != i.to_byte() {
        ok = false
      }
    }
    assert_true(ok)
  } catch {
    @moon-nrrd.NrrdError(m) => fail(m)
    _ => fail("unexpected error")
  }
}

///| T4: missing file — 3 chunks where 4 are expected.
test "list missing file rejected" {
  let sizes = [2, 3, 4]
  let names = ["s0.raw", "s1.raw", "s2.raw", "s3.raw"]
  let h = list_hdr(sizes, names)
  let chunks = [
    raw_chunk([0, 1, 2, 3, 4, 5]),
    raw_chunk([6, 7, 8, 9, 10, 11]),
    raw_chunk([12, 13, 14, 15, 16, 17]),
    // missing 4th chunk
  ]
  let err = reassemble_err(chunks, h)
  assert_true(err.contains("expected 4 data files"))
  assert_true(err.contains("got 3"))
}

///| T5: wrong chunk size — one file has 5 bytes instead of 6.
test "list wrong chunk size rejected" {
  let sizes = [2, 3, 4]
  let names = ["s0.raw", "s1.raw", "s2.raw", "s3.raw"]
  let h = list_hdr(sizes, names)
  let chunks = [
    raw_chunk([0, 1, 2, 3, 4, 5]),
    raw_chunk([6, 7, 8, 9, 10]), // 5 bytes, should be 6
    raw_chunk([12, 13, 14, 15, 16, 17]),
    raw_chunk([18, 19, 20, 21, 22, 23]),
  ]
  let err = reassemble_err(chunks, h)
  assert_true(err.contains("s1.raw"))
  assert_true(err.contains("expected 6 bytes"))
  assert_true(err.contains("got 5"))
}

///| T6: subdim out of range.
test "list subdim out of range rejected" {
  let sizes = [2, 3, 4]
  let names = ["a.raw"]
  let h = list_hdr(sizes, names, subdim=Some(5)) // D=3, max subdim=3
  let chunks = [raw_chunk([0])]
  let err = reassemble_err(chunks, h)
  assert_true(err.contains("subdim"))
}

///| T7: slabs that do not divide the slowest axis.
test "list slab count not dividing slowest axis rejected" {
  let sizes = [2, 2, 4]
  let names = ["a.raw", "b.raw", "c.raw"] // 3 slabs, 3 does not divide 4
  let h = list_hdr(sizes, names, subdim=Some(3))
  let chunks = [
    raw_chunk([0, 1, 2, 3]),
    raw_chunk([4, 5, 6, 7]),
    raw_chunk([8, 9, 10, 11]),
  ]
  let err = reassemble_err(chunks, h)
  assert_true(err.contains("3 slabs do not divide"))
}

///| T8: is_list_header and list_subdim helpers.
test "list header detection and subdim helpers" {
  let sizes = [2, 3, 4]
  let names = ["a.raw"]
  let h_def = list_hdr(sizes, names)
  assert_true(@moon-nrrd.is_list_header(h_def))
  assert_eq(@moon-nrrd.list_subdim(h_def), 2) // default D-1 = 2
  let h_exp = list_hdr(sizes, names, subdim=Some(1))
  assert_eq(@moon-nrrd.list_subdim(h_exp), 1)
  // Non-LIST header
  let h_plain = @moon-nrrd.NrrdHeader::{ list_filenames: None, data_file_subdim: None,
    dimension: 1,
    sizes: [1],
    type_name: "uint8",
    encoding: "raw",
    endian: None,
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
  assert_false(@moon-nrrd.is_list_header(h_plain))
}
