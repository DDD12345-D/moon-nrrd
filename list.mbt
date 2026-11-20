///| NRRD LIST detached data file reassembly (spec §3).
///| The LIST form (`data file: LIST [<subdim>]`) lists one filename
///| per line after the field specification. Each file holds a chunk
///| of the full array in linear order (sizes[0] fastest). This module
///| validates the chunk layout and concatenates them into the full
///| payload. No file IO — the host reads the bytes and passes them in.
///|
///| subdim semantics (spec §3):
///| - default: each file holds one slice along the slowest axis
///|   (per-file dimension D-1);
///| - subdim = k in [1, D): each file holds the k fastest axes;
///|   file count = product of the D-k slowest axes;
///| - subdim = D: equal-sized slabs along the slowest axis; the
///|   number of slabs must divide the slowest-axis sample count.

///| Overflow-safe product of a slice of sizes[lo..hi).
fn product_range(sizes : Array[Int], lo : Int, hi : Int) -> Int raise NrrdError {
  let mut acc = 1
  for idx = lo; idx < hi; idx = idx + 1 {
    let s = sizes[idx]
    if s <= 0 {
      raise NrrdError("non-positive size \{s}")
    }
    if acc > 2147483647 / s {
      raise NrrdError("dimension product overflows")
    }
    acc = acc * s
  }
  acc
}

///| Raw item size in bytes for a canonical type name (including
///| 64-bit integer types). Mirrors decode.item_size but is public
///| so the reassembly layer can pre-check chunk sizes.
pub fn nrrd_item_size(t : String) -> Int raise NrrdError {
  match t {
    "int8" | "uint8" => 1
    "int16" | "uint16" => 2
    "int32" | "uint32" | "float" => 4
    "int64" | "uint64" | "double" => 8
    _ => raise NrrdError("no item size for type '\{t}'")
  }
}

///| True when the header uses the LIST form of `data file`.
pub fn is_list_header(h : NrrdHeader) -> Bool {
  h.list_filenames is Some(_)
}

///| Effective subdim: explicit `data_file_subdim` or default D-1.
pub fn list_subdim(h : NrrdHeader) -> Int {
  match h.data_file_subdim {
    Some(v) => v
    None => h.dimension - 1
  }
}

///| Validate the LIST layout for `nfiles` data chunks and return the
///| number of values each chunk must contain.
///| - subdim = k < D: file count must equal product(sizes[k..D]);
///|   values per file = product(sizes[0..k]).
///| - subdim = D: nfiles must be positive and divide sizes[D-1];
///|   values per file = total / nfiles.
pub fn list_values_per_file(h : NrrdHeader, nfiles : Int) -> Int raise NrrdError {
  let d = h.dimension
  if d < 1 {
    raise NrrdError("invalid dimension \{d}")
  }
  if h.sizes.length() != d {
    raise NrrdError("sizes count mismatch")
  }
  let subdim = list_subdim(h)
  if subdim < 1 || subdim > d {
    raise NrrdError("subdim \{subdim} out of range [1, \{d}]")
  }
  if nfiles <= 0 {
    raise NrrdError("no data files")
  }
  if subdim < d {
    let expected = product_range(h.sizes, subdim, d)
    if nfiles != expected {
      raise NrrdError(
        "expected \{expected} data files for subdim \{subdim}, got \{nfiles}",
      )
    }
    product_range(h.sizes, 0, subdim)
  } else {
    // subdim == D: equal slabs along the slowest axis.
    let slowest = h.sizes[d - 1]
    if slowest % nfiles != 0 {
      raise NrrdError(
        "\{nfiles} slabs do not divide slowest axis \{slowest}",
      )
    }
    let total = product_range(h.sizes, 0, d)
    if total % nfiles != 0 {
      raise NrrdError("\{nfiles} does not divide total \{total}")
    }
    total / nfiles
  }
}

///| Validate and concatenate LIST data chunks into the full payload.
///| For raw encoding each chunk's byte length must equal
///| values_per_file × item_size exactly. For ascii encoding chunks
///| are concatenated and the downstream decoder enforces the value
///| count. Raises on chunk-count mismatch, size mismatch, or any
///| layout error.
pub fn reassemble_list_data(
  chunks : Array[Bytes],
  h : NrrdHeader,
) -> Bytes raise NrrdError {
  if !is_list_header(h) {
    raise NrrdError("header is not in LIST form")
  }
  let vpf = list_values_per_file(h, chunks.length())
  let is_raw = h.encoding == "raw"
  if is_raw {
    let item = nrrd_item_size(h.type_name)
    if vpf > 2147483647 / item {
      raise NrrdError("per-file byte size overflow")
    }
    let need = vpf * item
    for idx = 0; idx < chunks.length(); idx = idx + 1 {
      let got = chunks[idx].length()
      if got != need {
        let name = match h.list_filenames {
          Some(names) =>
            if idx < names.length() {
              names[idx]
            } else {
              "<chunk \{idx}>"
            }
          None => "<chunk \{idx}>"
        }
        raise NrrdError(
          "data file '\{name}': expected \{need} bytes, got \{got}",
        )
      }
    }
  }
  // Concatenate
  let mut total = 0
  for chunk in chunks {
    total = total + chunk.length()
    if total < 0 {
      raise NrrdError("total byte size overflow")
    }
  }
  let arr : Array[Byte] = Array::make(total, b'\x00')
  let mut at = 0
  for chunk in chunks {
    for i = 0; i < chunk.length(); i = i + 1 {
      arr[at] = chunk[i]
      at = at + 1
    }
  }
  Bytes::from_array(arr)
}
