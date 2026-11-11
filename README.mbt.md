# moon-nrrd

Pure MoonBit NRRD read-write library. Parses NRRD0005 headers and decodes
data payloads, and symmetrically serializes headers with encoded payloads.
Values are exchanged as `Double` in file linear order (`sizes[0]` = fastest
axis). The core layer performs no file IO — assembly APIs return bytes and
strings only.

## Current scope (v0.1)

- **Types**: int8 / uint8 / int16 / uint16 / int32 / uint32 / float / double
  (int64 / uint64 explicitly rejected — beyond Double 2^53 value carrier)
- **Encodings**: raw (little/big endian), ascii; attached / detached data files
- **Read**: strict magic line match (NRRD0005 only); standard fields normalized
  by alias/case and unique (duplicates rejected); `key:=value` custom keys
  follow the spec (last value wins)
- **Write**: `format_header` / `encode_data` / `assemble_attached` /
  `assemble_detached` (no IO, symmetric attached/detached output, NRRD0005);
  `format_keyval_line` provides spec-escaped key:=value tooling
- **Write strings are ASCII-only** (v1 contract): non-ASCII code points are
  rejected with `NrrdError`, never silently truncated (prevents header
  injection)
- **float32 semantics**: stored value is the nearest binary32 (ties-to-even);
  ASCII special-value detection applies to the narrowed stored value (negative
  underflow like -1.0e-50 emits "-0.0", not "0")

## Planned (not yet implemented)

- crop / slice carrying real data (with space origin/directions updates)
- world-coordinate API (`world = origin + Σ idx·dir`)
- unknown-field and `key:=value` round-trip preservation

## Known limitations

- ASCII float32 decimal parsing goes decimal → binary64 → binary32 (double
  rounding); not correctly rounded for all decimal literals
- ASCII numeric token length capped at 64 bytes (implementation limit, not
  spec)
- Compression (hex/gzip/bzip2/block), LIST multi-file, line/byte skip, and
  64-bit integers are explicitly rejected in v1
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
