///| crop_data whitebox test suite (G2 §3.3 / §4).
///| Covers: asymmetric 4×5×6, non-diagonal directions, negative
///| directions, none non-spatial axes, 2D-in-3D, no-space-info,
///| partial-space rejection, boundary, budget, immutability.
///| Values verified against an independent array model (first-axis-fastest).

///| Independent linear-index model (NOT the implementation's code path).
///| Flattens coords to linear id (first-axis-fastest) and calls gen.
fn model_id(sizes : Array[Int], coords : Array[Int]) -> Int {
  let mut id = 0
  let mut stride = 1
  for i = 0; i < sizes.length(); i = i + 1 {
    id = id + coords[i] * stride
    stride = stride * sizes[i]
  }
  id
}

///| Simple generator: value = 100*id + 1.0 (easy to trace).
fn gen_linear(id : Int) -> Double {
  100.0 * id.to_double() + 1.0
}

///| Build an NrrdHeader for testing.
fn test_header(
  sizes : Array[Int],
  space~ : String? = None,
  space_dim~ : Int? = None,
  origin~ : Array[Double]? = None,
  dirs~ : Array[Array[Double]?] = [],
  units~ : Array[String]? = None,
  labels~ : Array[String]? = None,
  kinds~ : Array[String]? = None,
) -> NrrdHeader {
  NrrdHeader::{
    dimension: sizes.length(),
    sizes: sizes.copy(),
    type_name: "float64",
    encoding: "raw",
    endian: Some("little"),
    data_file: None,
    space: space,
    space_dimension: space_dim,
    space_origin: origin,
    space_directions: dirs.copy(),
    space_units: units,
    labels: labels,
    kinds: kinds,
    content: None,
    line_skip: 0,
    byte_skip: 0,
  }
}

///| Build a flat values array from sizes and generator.
fn test_values(sizes : Array[Int], gen : (Int) -> Double) -> Array[Double] raise NrrdError {
  let total = data_product(sizes)
  let arr = Array::make(total, 0.0)
  for idx = 0; idx < total; idx = idx + 1 {
    arr[idx] = gen(idx)
  }
  arr
}

///| Get value at multi-dim coordinates in an NrrdData (first-axis-fastest).
fn get_val(d : NrrdData, coords : Array[Int]) -> Double {
  let mut stride = 1
  let mut idx = 0
  for i = 0; i < d.header.dimension; i = i + 1 {
    idx = idx + coords[i] * stride
    stride = stride * d.header.sizes[i]
  }
  d.values[idx]
}

///| Attempt crop; return true on success, false on raise.
fn try_crop(d : NrrdData, start : Array[Int], size : Array[Int]) -> Bool {
  let mut ok = true
  try {
    let _r = crop_data(d, start, size)
  } catch {
    _ => ok = false
  }
  ok
}

///| Attempt crop with explicit budget; return false on raise.
fn try_crop_b(d : NrrdData, start : Array[Int], size : Array[Int], b : Int) -> Bool {
  let mut ok = true
  try {
    let _r = crop_data(d, start, size, budget = b)
  } catch {
    _ => ok = false
  }
  ok
}

///| Attempt validate_crop_params; return false on raise.
fn try_valid(h : NrrdHeader, start : Array[Int], size : Array[Int]) -> Bool {
  let mut ok = true
  try {
    validate_crop_params(h, start, size)
  } catch {
    _ => ok = false
  }
  ok
}

// ========== Test cases ==========

///| C1: 4×5×6 asymmetric, diagonal directions, full space info.
test "crop: 4x5x6 asymmetric diagonal directions" {
  let sizes = [4, 5, 6]
  let hdr = test_header(
    sizes,
    space=Some("right-anterior-superior"),
    origin=Some([10.0, -5.0, 2.5]),
    dirs=[
      Some([1.5, 0.0, 0.0]),
      Some([0.0, 2.0, 0.0]),
      Some([0.0, 0.0, 2.5]),
    ],
    units=Some(["mm", "mm", "mm"]),
    labels=Some(["i", "j", "k"]),
    kinds=Some(["domain", "domain", "domain"]),
  )
  let vals = test_values(sizes, gen_linear)
  let d = NrrdData::{ header: hdr, values: vals }
  let start = [1, 2, 3]
  let crop_sz = [2, 2, 3]
  let result = crop_data(d, start, crop_sz)
  // shape
  assert_eq(result.header.sizes[0], 2, msg="sizes[0]")
  assert_eq(result.header.sizes[1], 2, msg="sizes[1]")
  assert_eq(result.header.sizes[2], 3, msg="sizes[2]")
  assert_eq(result.values.length(), 12, msg="value count")
  // values against independent model
  for a = 0; a < 2; a = a + 1 {
    for b = 0; b < 2; b = b + 1 {
      for c = 0; c < 3; c = c + 1 {
        let in_id = model_id(sizes, [a + 1, b + 2, c + 3])
        let expected = gen_linear(in_id)
        let actual = get_val(result, [a, b, c])
        assert_eq(actual, expected, msg="v[\{a},\{b},\{c}]")
      }
    }
  }
  // origin: (10,-5,2.5) + 1*(1.5,0,0) + 2*(0,2,0) + 3*(0,0,2.5) = (11.5,-1,10)
  let o = result.header.space_origin.unwrap()
  assert_eq(o[0], 11.5, msg="origin[0]")
  assert_eq(o[1], -1.0, msg="origin[1]")
  assert_eq(o[2], 10.0, msg="origin[2]")
  // per-axis fields unchanged in count
  assert_eq(result.header.labels.unwrap().length(), 3, msg="labels count")
  assert_eq(result.header.kinds.unwrap().length(), 3, msg="kinds count")
  assert_eq(result.header.space_directions.length(), 3, msg="dirs count")
  assert_eq(result.header.space_units.unwrap().length(), 3, msg="units count")
}

///| C2: non-diagonal + negative directions.
test "crop: non-diagonal negative directions" {
  let sizes = [3, 3]
  let hdr = test_header(
    sizes,
    space=Some("left-posterior-superior"),
    origin=Some([0.0, 0.0, 0.0]),
    dirs=[
      Some([1.0, -1.0, 0.0]),
      Some([0.5, 2.0, -1.0]),
    ],
    units=Some(["mm", "mm", "mm"]),
  )
  let vals = test_values(sizes, gen_linear)
  let d = NrrdData::{ header: hdr, values: vals }
  let result = crop_data(d, [1, 1], [2, 2])
  // origin' = 0 + 1*(1,-1,0) + 1*(0.5,2,-1) = (1.5, 1.0, -1.0)
  let o = result.header.space_origin.unwrap()
  assert_eq(o[0], 1.5, msg="origin[0]")
  assert_eq(o[1], 1.0, msg="origin[1]")
  assert_eq(o[2], -1.0, msg="origin[2]")
}

///| C3: none non-spatial axis does not offset origin.
test "crop: none axis does not offset origin" {
  let sizes = [3, 3, 4]
  let hdr = test_header(
    sizes,
    space=Some("right-anterior-superior"),
    origin=Some([5.0, 5.0, 5.0]),
    dirs=[
      Some([1.0, 0.0, 0.0]),
      Some([0.0, 1.0, 0.0]),
      None,
    ],
    units=Some(["mm", "mm", "mm"]),
  )
  let vals = test_values(sizes, gen_linear)
  let d = NrrdData::{ header: hdr, values: vals }
  let result = crop_data(d, [1, 2, 1], [2, 1, 3])
  // origin' = (5,5,5) + 1*(1,0,0) + 2*(0,1,0) + 1*none = (6,7,5)
  let o = result.header.space_origin.unwrap()
  assert_eq(o[0], 6.0, msg="origin[0]")
  assert_eq(o[1], 7.0, msg="origin[1]")
  assert_eq(o[2], 5.0, msg="origin[2]")
}

///| C4: 2D-in-3D (array dim < space dim).
test "crop: 2D-in-3D" {
  let sizes = [4, 6]
  let hdr = test_header(
    sizes,
    space=Some("right-anterior-superior"),
    origin=Some([0.0, 0.0, 0.0]),
    dirs=[
      Some([1.0, 0.0, 0.0]),
      Some([0.0, 0.0, 2.0]),
    ],
    units=Some(["mm", "mm", "mm"]),
  )
  let vals = test_values(sizes, gen_linear)
  let d = NrrdData::{ header: hdr, values: vals }
  let result = crop_data(d, [1, 2], [2, 3])
  // origin' = 0 + 1*(1,0,0) + 2*(0,0,2) = (1,0,4)
  let o = result.header.space_origin.unwrap()
  assert_eq(o[0], 1.0, msg="origin[0]")
  assert_eq(o[1], 0.0, msg="origin[1]")
  assert_eq(o[2], 4.0, msg="origin[2]")
  // space units remains 3 (space dimension, not array dimension)
  assert_eq(result.header.space_units.unwrap().length(), 3, msg="units count")
}

///| C5: no spatial info is allowed.
test "crop: no spatial info is allowed" {
  let sizes = [3, 4]
  let hdr = test_header(sizes)
  let vals = test_values(sizes, gen_linear)
  let d = NrrdData::{ header: hdr, values: vals }
  let result = crop_data(d, [1, 1], [2, 2])
  assert_true(result.header.space_origin is None, msg="origin should be None")
  assert_eq(result.values.length(), 4, msg="count")
  for a = 0; a < 2; a = a + 1 {
    for b = 0; b < 2; b = b + 1 {
      let expected = gen_linear(model_id(sizes, [a + 1, b + 1]))
      let actual = get_val(result, [a, b])
      assert_eq(actual, expected, msg="v[\{a},\{b}]")
    }
  }
}

///| C6: partial spatial info rejected at data operation layer.
test "crop: partial spatial info is rejected" {
  // has space_origin but no space / space_dimension
  let sizes = [3, 3]
  let hdr = test_header(
    sizes,
    origin=Some([1.0, 2.0, 3.0]),
  )
  let vals = test_values(sizes, gen_linear)
  let d = NrrdData::{ header: hdr, values: vals }
  assert_true(try_crop(d, [0, 0], [1, 1]) == false, msg="must reject partial space")
}

///| C7: boundary — full extent preserves all values.
test "crop: full extent is identity" {
  let sizes = [3, 4]
  let hdr = test_header(sizes)
  let vals = test_values(sizes, gen_linear)
  let d = NrrdData::{ header: hdr, values: vals }
  let result = crop_data(d, [0, 0], [3, 4])
  assert_eq(result.values.length(), 12, msg="count")
  for idx = 0; idx < 12; idx = idx + 1 {
    assert_eq(result.values[idx], vals[idx], msg="v[\{idx}]")
  }
}

///| C8: boundary — single element.
test "crop: single element" {
  let sizes = [3, 4]
  let hdr = test_header(sizes)
  let vals = test_values(sizes, gen_linear)
  let d = NrrdData::{ header: hdr, values: vals }
  let result = crop_data(d, [2, 3], [1, 1])
  assert_eq(result.values.length(), 1, msg="count")
  assert_eq(result.values[0], gen_linear(model_id(sizes, [2, 3])), msg="value")
}

///| C9: budget rejection — small data with small budget.
test "crop: budget rejection" {
  let sizes = [4, 4]
  let hdr = test_header(sizes)
  let vals = test_values(sizes, gen_linear)
  let d = NrrdData::{ header: hdr, values: vals }
  // crop to 4 elements with budget=2 → reject
  assert_true(
    try_crop_b(d, [0, 0], [2, 2], 2) == false,
    msg="must reject over-budget",
  )
  // budget=0 → reject (non-positive)
  assert_true(
    try_crop_b(d, [0, 0], [1, 1], 0) == false,
    msg="must reject zero budget",
  )
  // budget=-1 → reject (non-positive)
  assert_true(
    try_crop_b(d, [0, 0], [1, 1], -1) == false,
    msg="must reject negative budget",
  )
}

///| C9b: coexist check must not overflow — budget=2^30, tiny crop.
test "crop: budget coexist check overflow-safe" {
  // input has 2 values, crop to 1 value, budget=1073741824 (2^30)
  // old code: budget*2 wraps to negative → wrongly rejects
  let sizes = [2]
  let hdr = test_header(sizes)
  let vals = [10.0, 20.0]
  let d = NrrdData::{ header: hdr, values: vals }
  let big_budget = 1073741824
  // should succeed: 2+1 = 3 <= 2*2^30 = 2^31 (fits in Int64)
  let result = crop_data(d, [0], [1], budget = big_budget)
  assert_eq(result.values.length(), 1, msg="count")
  assert_eq(result.values[0], 10.0, msg="value")
}

///| C10: immutability — input is not modified.
test "crop: input is not modified" {
  let sizes = [3, 3]
  let hdr = test_header(
    sizes,
    space=Some("right-anterior-superior"),
    origin=Some([0.0, 0.0, 0.0]),
    dirs=[Some([1.0, 0.0, 0.0]), Some([0.0, 1.0, 0.0])],
    units=Some(["mm", "mm", "mm"]),
  )
  let vals = test_values(sizes, gen_linear)
  let snap_vals = vals.copy()
  let snap_origin = hdr.space_origin.unwrap().copy()
  let d = NrrdData::{ header: hdr, values: vals }
  let _r = crop_data(d, [1, 1], [2, 2])
  for idx = 0; idx < 9; idx = idx + 1 {
    assert_eq(d.values[idx], snap_vals[idx], msg="input v[\{idx}] mutated")
  }
  let o = d.header.space_origin.unwrap()
  assert_eq(o[0], snap_origin[0], msg="input origin[0] mutated")
  assert_eq(o[1], snap_origin[1], msg="input origin[1] mutated")
  assert_eq(o[2], snap_origin[2], msg="input origin[2] mutated")
}

///| C11: parameter validation — dim mismatch, negative, zero, OOB.
test "crop: parameter validation rejects bad inputs" {
  let sizes = [4, 4]
  let hdr = test_header(sizes)
  let vals = test_values(sizes, gen_linear)
  let d = NrrdData::{ header: hdr, values: vals }
  assert_true(try_crop(d, [0], [2, 2]) == false, msg="wrong start length")
  assert_true(try_crop(d, [0, 0], [2]) == false, msg="wrong size length")
  assert_true(try_crop(d, [-1, 0], [2, 2]) == false, msg="negative start")
  assert_true(try_crop(d, [0, 0], [0, 2]) == false, msg="zero size")
  assert_true(try_crop(d, [3, 0], [2, 2]) == false, msg="out of bounds")
}

///| C12: overflow-safe range check (start+size would overflow Int32).
test "crop: overflow-safe range check" {
  // start=2000000000, size=2000000000, sizes[0]=2000000001
  // start > sizes - size: 2000000000 > 2000000001 - 2000000000 = 1 → reject
  let big_hdr = test_header([2000000001, 1])
  assert_true(
    try_valid(big_hdr, [2000000000, 0], [2000000000, 1]) == false,
    msg="must reject overflow-unsafe range",
  )
}

///| C13: entry shape check — values count must match product of sizes.
test "crop: values count mismatch raises" {
  let sizes = [3, 3]
  let hdr = test_header(sizes)
  let bad_vals = Array::make(5, 1.0) // should be 9
  let d = NrrdData::{ header: hdr, values: bad_vals }
  assert_true(try_crop(d, [0, 0], [1, 1]) == false, msg="must reject bad values count")
}

///| C14: space+space_dimension mutual exclusion rejected.
test "crop: space and space_dimension mutual exclusion rejected" {
  let sizes = [3, 3]
  let hdr = test_header(
    sizes,
    space=Some("right-anterior-superior"),
    space_dim=Some(3),
  )
  let vals = test_values(sizes, gen_linear)
  let d = NrrdData::{ header: hdr, values: vals }
  assert_true(try_crop(d, [0, 0], [1, 1]) == false, msg="must reject mutual exclusion")
}

// ========== Spatial completeness counter-examples (audit fixes) ==========

///| C15: identity-only — space_dimension set but no origin/directions.
test "crop: identity-only without origin/directions is rejected" {
  let sizes = [2, 2]
  let hdr = test_header(
    sizes,
    space_dim=Some(2),
  )
  let vals = test_values(sizes, gen_linear)
  let d = NrrdData::{ header: hdr, values: vals }
  assert_true(try_crop(d, [0, 0], [1, 1]) == false, msg="must reject identity-only")
}

///| C16: missing origin (directions present, origin absent) — counter-example B.
test "crop: missing origin with directions is rejected" {
  let sizes = [2]
  let hdr = test_header(
    sizes,
    space_dim=Some(1),
    origin=None,
    dirs=[Some([1.0])],
  )
  let vals = test_values(sizes, gen_linear)
  let d = NrrdData::{ header: hdr, values: vals }
  assert_true(try_crop(d, [1], [1]) == false, msg="must reject missing origin")
}

///| C17: missing directions (origin present, directions absent) — counter-example A.
test "crop: missing directions with origin is rejected" {
  let sizes = [2]
  let hdr = test_header(
    sizes,
    space_dim=Some(1),
    origin=Some([0.0]),
    dirs=[],
  )
  let vals = test_values(sizes, gen_linear)
  let d = NrrdData::{ header: hdr, values: vals }
  assert_true(try_crop(d, [0], [1]) == false, msg="must reject missing directions")
}

///| C18: directions row count ≠ dimension.
test "crop: directions row count mismatch is rejected" {
  let sizes = [2, 3]
  let hdr = test_header(
    sizes,
    space_dim=Some(2),
    origin=Some([0.0, 0.0]),
    dirs=[Some([1.0, 0.0])], // 1 row but dimension=2
  )
  let vals = test_values(sizes, gen_linear)
  let d = NrrdData::{ header: hdr, values: vals }
  assert_true(try_crop(d, [0, 0], [1, 1]) == false, msg="must reject row count mismatch")
}

///| C19: none axis is legal when completeness holds.
test "crop: none axis accepted when origin+directions complete" {
  let sizes = [3, 3]
  let hdr = test_header(
    sizes,
    space_dim=Some(2),
    origin=Some([0.0, 0.0]),
    dirs=[Some([1.0, 0.0]), None], // none on axis 1 is legal
  )
  let vals = test_values(sizes, gen_linear)
  let d = NrrdData::{ header: hdr, values: vals }
  let result = crop_data(d, [1, 1], [2, 2])
  assert_eq(result.values.length(), 4, msg="count")
  // origin' = (0,0) + 1*(1,0,0) + 1*none = (1,0)
  let o = result.header.space_origin.unwrap()
  assert_eq(o[0], 1.0, msg="origin[0]")
  assert_eq(o[1], 0.0, msg="origin[1]")
}

///| C20: crop_meta directly — must not panic on incomplete fields.
test "crop_meta: incomplete fields raise, not panic" {
  // counter-example A shape: directions=[] with dimension=1
  let h1 = test_header(
    [2],
    space_dim=Some(1),
    origin=Some([0.0]),
    dirs=[],
  )
  let mut ok1 = false
  try {
    let _r = crop_meta(h1, [0], [1])
  } catch {
    _ => ok1 = true
  }
  assert_true(ok1, msg="crop_meta must raise on missing directions")
  // counter-example B shape: origin=None with directions
  let h2 = test_header(
    [2],
    space_dim=Some(1),
    origin=None,
    dirs=[Some([1.0])],
  )
  let mut ok2 = false
  try {
    let _r = crop_meta(h2, [1], [1])
  } catch {
    _ => ok2 = true
  }
  assert_true(ok2, msg="crop_meta must raise on missing origin")
}

///| C21: complete spatial info accepted (regression guard).
test "crop: complete spatial info accepted" {
  let sizes = [2, 3]
  let hdr = test_header(
    sizes,
    space=Some("right-anterior-superior"),
    origin=Some([1.0, 2.0, 3.0]),
    dirs=[Some([1.0, 0.0, 0.0]), Some([0.0, 1.0, 0.0])],
    units=Some(["mm", "mm", "mm"]),
  )
  let vals = test_values(sizes, gen_linear)
  let d = NrrdData::{ header: hdr, values: vals }
  let result = crop_data(d, [1, 1], [1, 2])
  assert_eq(result.values.length(), 2, msg="count")
  let o = result.header.space_origin.unwrap()
  assert_eq(o[0], 2.0, msg="origin[0]")
  assert_eq(o[1], 3.0, msg="origin[1]")
  assert_eq(o[2], 3.0, msg="origin[2]")
}
