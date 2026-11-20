# moon-nrrd

Pure MoonBit NRRD read-write library. Parses NRRD0005 headers and decodes
data payloads, and symmetrically serializes headers with encoded payloads.
Values ≤32-bit are exchanged as `Double` in file linear order (`sizes[0]` =
fastest axis); 64-bit integers use native `Int64` / `UInt64` (no Double
intermediary). The core layer performs no file IO — assembly APIs return
bytes and strings only.

## Current scope (v0.2)

- **Types**: int8 / uint8 / int16 / uint16 / int32 / uint32 / float / double
  via `Double` carrier; int64 / uint64 via native `decode_int64` /
  `decode_uint64` / `encode_int64` / `encode_uint64` (raw LE/BE + ascii,
  lossless round-trip verified for 2^53+1, INT64_MIN/MAX, UINT64_MAX)
- **Encodings**: raw (little/big endian), ascii; attached / detached / LIST
  multi-file data files
- **Read**: strict magic line match (NRRD0005 only); standard fields normalized
  by alias/case and unique (duplicates rejected); `key:=value` custom keys
  follow the spec (last value wins)
- **LIST multi-file**: `data file: LIST [subdim]` — per-chunk validation
  (raw byte count / ascii token count), boundary-safe concatenation, missing
  file and size mismatch rejection
- **Write**: `format_header` / `encode_data` / `assemble_attached` /
  `assemble_detached` (no IO, symmetric attached/detached output, NRRD0005);
  `format_keyval_line` provides spec-escaped key:=value tooling
- **Data ops**: `crop_data` / `crop_meta` (dimension-preserving crop with real
  value subset, space origin shifted) and `slice_data` / `slice_meta`
  (dimension-reducing slice with real value subset), both updating spatial
  metadata consistently (Double-carrier values; 64-bit data ops planned)
- **Write strings are ASCII-only** (v1 contract): non-ASCII code points are
  rejected with `NrrdError`, never silently truncated (prevents header
  injection)
- **float32 semantics**: stored value is the nearest binary32 (ties-to-even);
  ASCII special-value detection applies to the narrowed stored value (negative
  underflow like -1.0e-50 emits "-0.0", not "0")

## Verified scope quick reference

Use the installed MoonBit toolchain. Run from the repository root:

```sh
# 1. LIST sharding reassembly (raw + ascii, 12/12)
#    default subdim, explicit subdim, slabs, missing file,
#    wrong chunk size/count, no-trailing-newline boundary
moon test --target js list_test.mbt

# 2. int64/uint64 lossless round-trip (20/20)
#    raw LE/BE + ascii; 2^53+1, INT64_MIN, INT64_MAX, UINT64_MAX
moon test --target js int64_test.mbt
```

Full suite: `moon test --target js` (281/281);
`moon test --target wasm` (281/281); `moon check --deny-warn` clean.

## Planned (not yet implemented)

- world-coordinate API (`world = origin + Σ idx·dir`)
- 64-bit integer data ops (`crop_data` / `slice_data` on Int64/UInt64 arrays)
- LIST / format-sequence multi-file writing
- unknown-field and `key:=value` round-trip preservation

## Known limitations

- ASCII float32 decimal parsing is **decimal → binary32 direct correct
  rounding** (nearest, ties-to-even, single final rounding — no binary64
  intermediate step); correctly rounded for all decimal tokens up to 64 bytes
- ASCII numeric token length capped at 64 bytes (implementation limit, not
  spec)
- Compression (hex/gzip/bzip2/block), format-sequence multi-file, and
  line/byte skip are explicitly rejected (planned for stage B)
- NaN payload/signaling bits are not preserved (semantic nan==nan only)

## Usage

```moonbit
// Parse a header + data from bytes
let hdr = @moon-nrrd.parse_header(buf)?
let data = @moon-nrrd.decode_data(buf, hdr)?

// Serialize
let header_str = @moon-nrrd.format_header(hdr)?
let payload = @moon-nrrd.encode_data(data, hdr)?
let attached = @moon-nrrd.assemble_attached(hdr, payload)?
```

## License

Apache-2.0

## Reference

Format spec: <https://teem.sourceforge.net/nrrd/format.html> (NRRD0005)
