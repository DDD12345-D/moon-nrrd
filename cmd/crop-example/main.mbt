///| crop_data complete example: 2×3×2 int16 array with 3D space metadata.
///| Demonstrates input sizes, crop parameters, output values, and
///| updated space origin.  All values traceable by hand.
fn main raise {
  // Input: 2×3×2 int16 array with full 3D space metadata.
  // Values are in file linear order (sizes[0]=x is fastest).
  // value(x,y,z) = 100*x + 10*y + z  → easy to trace.

  let hdr = @nrrd.NrrdHeader::{ list_filenames: None, data_file_subdim: None,
    dimension: 3,
    sizes: [2, 3, 2],
    type_name: "int16",
    encoding: "raw",
    endian: Some("little"),
    data_file: None,
    space: Some("right-anterior-superior"),
    space_dimension: None,
    space_origin: Some([10.0, -5.0, 2.5]),
    space_directions: [
      Some([1.5, 0.0, 0.0]),
      Some([0.0, 2.0, 0.0]),
      Some([0.0, 0.0, 2.5]),
    ],
    space_units: Some(["mm", "mm", "mm"]),
    labels: Some(["x", "y", "z"]),
    kinds: Some(["domain", "domain", "domain"]),
    content: None,
    line_skip: 0,
    byte_skip: 0,
  }
  // Build 12 values: for (x,y,z) in [0,2)×[0,3)×[0,2):
  //   linear_idx = x + 2*y + 6*z  (first-axis-fastest)
  //   value = 100*x + 10*y + z  (same formula as comment above)
  let vals = [
    0.0, 100.0,    // (0,0,0) (1,0,0)  = 0, 100
    10.0, 110.0,   // (0,1,0) (1,1,0)  = 10, 110
    20.0, 120.0,   // (0,2,0) (1,2,0)  = 20, 120
    1.0, 101.0,    // (0,0,1) (1,0,1)  = 1, 101
    11.0, 111.0,   // (0,1,1) (1,1,1)  = 11, 111
    21.0, 121.0,   // (0,2,1) (1,2,1)  = 21, 121
  ]
  let d = @nrrd.NrrdData::{ header: hdr, values: vals }
  println("=== Input ===")
  println("sizes: \{d.header.sizes[0]} \{d.header.sizes[1]} \{d.header.sizes[2]}")
  println("origin: \{d.header.space_origin.unwrap()[0]} \{d.header.space_origin.unwrap()[1]} \{d.header.space_origin.unwrap()[2]}")
  println("values: \{d.values.length()} elements")
  // Crop: start=(1,1,0), size=(1,2,2)
  //   → output sizes = (1,2,2), 4 elements
  //   → output(x',y',z') = input(x'+1, y'+1, z'+0)
  //   → values: (1,1,0)=110, (1,2,0)=120, (1,1,1)=111, (1,2,1)=121
  //   → origin' = (10,-5,2.5) + 1*(1.5,0,0) + 1*(0,2,0) + 0*(0,0,2.5)
  //             = (11.5, -3.0, 2.5)
  let start = [1, 1, 0]
  let crop_sz = [1, 2, 2]
  let result = @nrrd.crop_data(d, start, crop_sz)
  println("\n=== Crop: start=(\{start[0]},\{start[1]},\{start[2]})  size=(\{crop_sz[0]},\{crop_sz[1]},\{crop_sz[2]}) ===")
  println("sizes: \{result.header.sizes[0]} \{result.header.sizes[1]} \{result.header.sizes[2]}")
  let o = result.header.space_origin.unwrap()
  println("origin: \{o[0]} \{o[1]} \{o[2]}")
  println("values: \{result.values.length()} elements")
  println("values: \{result.values[0]} \{result.values[1]} \{result.values[2]} \{result.values[3]}")
  // Expected output (hand-computed):
  //   values = [110, 120, 111, 121]  (file linear order: x fastest)
  //   sizes  = (1, 2, 2)
  //   origin = (11.5, -3.0, 2.5)
}
