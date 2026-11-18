///| Data-level operations on NRRD datasets (header + real values).
///| crop_data: dimension-preserving crop with real value subset.
///| G2 design §3.3: NrrdData is first-class; input/output both
///| carry data and the element count is validated against shapes.
///|
///| Index convention: linear order follows the file (sizes[0] is
///| the fastest axis).  Crop parameters are `start` + `size` arrays
///| (per-axis start index and output extent), never a half-open
///| interval mixed with sizes.

///| Dataset = header + values in file linear order.
pub(all) struct NrrdData {
  header : NrrdHeader
  values : Array[Double]
}

///| Allocation budget shared by data operations (G2 v2 §7.2).
fn max_data_elements() -> Int {
  16777216
}

///| Overflow-safe product of sizes; raises on non-positive or overflow.
fn data_product(sizes : Array[Int]) -> Int raise NrrdError {
  let mut acc = 1
  for s in sizes {
    if s <= 0 {
      raise NrrdError("non-positive size \{s}")
    }
    if acc > 2147483647 / s {
      raise NrrdError("dimension product overflows; refusing to allocate")
    }
    acc = acc * s
  }
  acc
}

///| Validate crop start+size against a header without touching values.
///| Uses subtraction form (`start > sizes - size`) to avoid
///| overflow when computing `start + size`.
fn validate_crop_params(
  h : NrrdHeader,
  start : Array[Int],
  size : Array[Int],
) -> Unit raise NrrdError {
  let dim = h.dimension
  if start.length() != dim {
    raise NrrdError(
      "start length \{start.length()} does not match dimension \{dim}",
    )
  }
  if size.length() != dim {
    raise NrrdError(
      "size length \{size.length()} does not match dimension \{dim}",
    )
  }
  for i = 0; i < dim; i = i + 1 {
    let s0 = start[i]
    let sz = size[i]
    if s0 < 0 {
      raise NrrdError("start[\{i}] = \{s0} must be non-negative")
    }
    if sz <= 0 {
      raise NrrdError("size[\{i}] = \{sz} must be positive")
    }
    // overflow-safe: check start + size <= sizes[i] via subtraction
    if sz > h.sizes[i] {
      raise NrrdError(
        "size[\{i}] = \{sz} exceeds sizes[\{i}] = \{h.sizes[i]}",
      )
    }
    if s0 > h.sizes[i] - sz {
      raise NrrdError(
        "crop range [\{s0}, \{s0}+\{sz}) exceeds sizes[\{i}] = \{h.sizes[i]}",
      )
    }
  }
}

///| Resolve the effective space dimension from a header, if spatial
///| identity is present.  Returns None for headers with no spatial
///| identity at all (no space, no space dimension, no orientation
///| fields).  Raises for partial/inconsistent spatial info.
fn effective_space_dim(h : NrrdHeader) -> Int? raise NrrdError {
  match (h.space, h.space_dimension) {
    (Some(_), Some(_)) => raise NrrdError(
      "space and space dimension are mutually exclusive",
    )
    (None, None) => {
      // no identity: complete absence of spatial info is OK for data ops
      let has_orient = h.space_origin is Some(_) ||
        !h.space_directions.is_empty() ||
        h.space_units is Some(_)
      if has_orient {
        raise NrrdError(
          "incomplete spatial info: orientation fields without space or space dimension",
        )
      }
      None
    }
    _ => {
      let sd : Int = match h.space_dimension {
        Some(sd) => {
          if sd < 1 {
            raise NrrdError("space dimension must be positive")
          }
          sd
        }
        None => match h.space {
          Some(name) => named_space_dimension(name)
          None => raise NrrdError("unreachable")
        }
      }
      // now check consistency of orientation fields against sd
      match h.space_units {
        Some(us) =>
          if us.length() != sd {
            raise NrrdError(
              "space units count \{us.length()} does not match space dimension \{sd}",
            )
          }
        None => ()
      }
      match h.space_origin {
        Some(o) =>
          if o.length() != sd {
            raise NrrdError(
              "space origin count \{o.length()} does not match space dimension \{sd}",
            )
          }
        None => ()
      }
      for row in h.space_directions {
        match row {
          Some(v) =>
            if v.length() != sd {
              raise NrrdError(
                "space direction vector length \{v.length()} does not match space dimension \{sd}",
              )
            }
          None => ()
        }
      }
      Some(sd)
    }
  }
}

///| Crop metadata only (no value operation).  Per-axis fields
///| (labels/kinds/directions) keep the same count; only sizes and
///| space_origin change.  space/space_dimension/space_units are
///| basic fields and are NOT modified by crop.
pub fn crop_meta(
  h : NrrdHeader,
  start : Array[Int],
  size : Array[Int],
) -> NrrdHeader raise NrrdError {
  validate_header(h)
  validate_crop_params(h, start, size)
  // recompute effective space dim (also validates consistency)
  let sd_opt = effective_space_dim(h)
  // new space origin = origin + Σ start_i · dir_i
  let new_origin : Array[Double]? = match (sd_opt, h.space_origin) {
    (Some(_), Some(orig)) => {
      let o = orig.copy()
      for i = 0; i < h.dimension; i = i + 1 {
        match h.space_directions[i] {
          Some(dir_vec) => {
            // only offset for non-none directions
            if start[i] != 0 {
              for c = 0; c < o.length(); c = c + 1 {
                o[c] = o[c] + start[i].to_double() * dir_vec[c]
              }
            }
          }
          None => () // none direction: no offset for this axis
        }
      }
      Some(o)
    }
    _ => h.space_origin
  }
  // build output header: labels/kinds/directions unchanged in count
  let new_labels : Array[String]? = match h.labels {
    Some(ls) => Some(ls.copy())
    None => None
  }
  let new_kinds : Array[String]? = match h.kinds {
    Some(ks) => Some(ks.copy())
    None => None
  }
  let new_dirs : Array[Array[Double]?] = h.space_directions.map(fn(d) {
    match d {
      Some(v) => Some(v.copy())
      None => None
    }
  })
  let new_units : Array[String]? = match h.space_units {
    Some(us) => Some(us.copy())
    None => None
  }
  NrrdHeader::{
    dimension: h.dimension,
    sizes: size.copy(),
    type_name: h.type_name,
    encoding: h.encoding,
    endian: h.endian,
    data_file: h.data_file,
    space: h.space,
    space_dimension: h.space_dimension,
    space_origin: new_origin,
    space_directions: new_dirs,
    space_units: new_units,
    labels: new_labels,
    kinds: new_kinds,
    content: h.content,
    line_skip: h.line_skip,
    byte_skip: h.byte_skip,
  }
}

///| Crop a dataset (dimension-preserving): extract a value subset
///| with the given per-axis start and size, updating the header
///| sizes and space_origin accordingly.
///|
///| Value subset uses first-axis-fastest linear indexing:
///| in_stride[0] = 1, in_stride[i] = in_stride[i-1] * sizes[i-1].
///| For each output linear position, decode to output coordinates,
///| add start, then compute the input linear index via strides.
///|
///| The input NrrdData and its arrays are never mutated.
pub fn crop_data(
  d : NrrdData,
  start : Array[Int],
  size : Array[Int],
  budget~ : Int = max_data_elements(),
) -> NrrdData raise NrrdError {
  // 1. validate header independently
  validate_header(d.header)
  // 2. entry shape check: values count must match product of sizes
  let expected = data_product(d.header.sizes)
  if d.values.length() != expected {
    raise NrrdError(
      "values count \{d.values.length()} does not match product of sizes \{expected}",
    )
  }
  // 3. validate crop params (overflow-safe)
  validate_crop_params(d.header, start, size)
  // 4. validate space consistency (raises on partial/inconsistent)
  let _sd = effective_space_dim(d.header)
  // 5. compute output element count with overflow-safe product
  let out_count = data_product(size)
  // 6. budget check before allocation
  if out_count > budget {
    raise NrrdError(
      "refusing to crop to \{out_count} elements; budget is \{budget}",
    )
  }
  // also check input+output coexist within a generous bound (2x)
  if d.values.length() + out_count > budget * 2 {
    raise NrrdError(
      "input(\{d.values.length()}) + output(\{out_count}) exceeds 2x budget(\{budget * 2})",
    )
  }
  // 7. compute input strides (first-axis-fastest)
  let dim = d.header.dimension
  let in_stride = Array::make(dim, 1)
  for i = 1; i < dim; i = i + 1 {
    in_stride[i] = in_stride[i - 1] * d.header.sizes[i - 1]
  }
  // 8. extract value subset
  let out_values = Array::make(out_count, 0.0)
  // decode each output linear index to coordinates, offset by start
  for out_idx = 0; out_idx < out_count; out_idx = out_idx + 1 {
    let mut rem = out_idx
    let mut in_idx = 0
    for ax = 0; ax < dim; ax = ax + 1 {
      let coord = rem % size[ax]
      rem = rem / size[ax]
      in_idx = in_idx + (coord + start[ax]) * in_stride[ax]
    }
    out_values[out_idx] = d.values[in_idx]
  }
  // 9. compute new header (reuses crop_meta)
  let new_header = crop_meta(d.header, start, size)
  // 10. verify output shape invariant
  let verify = data_product(new_header.sizes)
  if out_values.length() != verify {
    raise NrrdError(
      "output values \{out_values.length()} does not match new sizes product \{verify}",
    )
  }
  NrrdData::{ header: new_header, values: out_values }
}
