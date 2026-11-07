#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""G3 读侧 48 格样例生成器（纯标准库，可离线复现，不依赖 numpy/pynrrd）。

生成物（均写入本仓库）：
  tests/fixtures/                48 个唯一 T×E×A 组合样例
                                 (8 规划类型 × {raw-le, raw-be, ascii} × {attached, detached})
                                 + 2 个空间头补充样例（spatial_*）
  tests/fixtures/expected.json   golden 期望（由本脚本按 IEEE-754/整型语义独立构造）
  tests/fixtures/grid.json       48 格组合清单（combo_id / sample / 备注）
  grid_cases_test.mbt            嵌入式 48 格解码测试（moon test js/wasm 双后端逐格断言）

期望值独立性：
  - raw 样例：期望由「写入字节再按同字节布局解包」得到（自洽校验，非读取结果回填）；
  - ascii 样例：期望按解码器同款语义计算（十进制 → binary64 →（float 时）binary32 舍入），
    与探针/核心解析路径规则一致但不调用 MoonBit 代码；
  - 不从 MoonBit 探针读取结果回填，避免自证。

数值语义（与 check_semantic 同款）：
  nan 按语义（nan==nan）；±inf 分符号；零分正负（-0.0 ≠ 0.0）；其余精确相等。
  NaN 的 payload / signaling 位不在承诺范围（G2 v2 §7.1 收窄后的口径）。

单字节 LE/BE 同义案例：int8 / uint8 的 raw-le 与 raw-be 样例字节相同，
仅 endian 字段不同 —— grid.json 中显式标注，48 格表中单列说明。
"""
import json
import math
import os
import struct
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
FIX = os.path.join(HERE, "fixtures")
ROOT = os.path.dirname(HERE)

# ---------------------------------------------------------------------------
# 类型表：kind=int 时 values 为 Python int；kind=float 时为 Python float。
# float 的 values 以 binary64 形式给出，写入/期望均按 binary32 往返。
# ---------------------------------------------------------------------------

TYPES = {
    "int8": {
        "kind": "int", "fmt": "b", "lo": -128, "hi": 127,
        "values": [-128, -100, -1, 0, 1, 64, 100, 127],
    },
    "uint8": {
        "kind": "int", "fmt": "B", "lo": 0, "hi": 255,
        "values": [0, 1, 2, 64, 127, 128, 200, 255],
    },
    "int16": {
        "kind": "int", "fmt": "h", "lo": -32768, "hi": 32767,
        "values": [-32768, -12345, -1, 0, 1, 256, 12345, 32767],
    },
    "uint16": {
        "kind": "int", "fmt": "H", "lo": 0, "hi": 65535,
        "values": [0, 1, 255, 256, 32767, 32768, 12345, 65535],
    },
    "int32": {
        "kind": "int", "fmt": "i", "lo": -2147483648, "hi": 2147483647,
        "values": [-2147483648, -1000000000, -1, 0, 1, 65536, 1000000000, 2147483647],
    },
    "uint32": {
        "kind": "int", "fmt": "I", "lo": 0, "hi": 4294967295,
        # 高半区 (>= 2^31) 覆盖：2147483648 / 3000000000 / 4000000000 / 4294967295
        "values": [0, 1, 65536, 2147483647, 2147483648, 3000000000, 4000000000, 4294967295],
    },
    "float": {
        "kind": "float", "fmt": "f",
        # 正负零 / 常规 / 舍入边界 / 最大值 / 最小正规 / 最小次正规 / nan / ±inf
        "values": [
            0.0, -0.0, 1.0, -1.5, 0.1, 16777216.0,
            3.4028234663852886e38, 1.1754943508222875e-38, 1.401298464324817e-45,
            float("nan"), float("inf"), float("-inf"),
        ],
    },
    "double": {
        "kind": "float", "fmt": "d",
        "values": [
            0.0, -0.0, 0.1, -1.5, -12345.6789, 16777217.0,
            1.7976931348623157e308, 2.2250738585072014e-308, 5e-324,
            float("nan"), float("inf"), float("-inf"),
        ],
    },
}

ENCS = ["raw-le", "raw-be", "ascii"]
ATTS = ["att", "det"]


# ---------------------------------------------------------------------------
# 值 <-> 字节 / 期望 计算
# ---------------------------------------------------------------------------

def f32(v):
    """binary64 -> binary32 往返（round-to-nearest-even，与 Float::from_double 同规则）。"""
    return struct.unpack("<f", struct.pack("<f", v))[0]


def write_raw(type_name, values, big):
    t = TYPES[type_name]
    prefix = ">" if big else "<"
    out = b""
    for v in values:
        if t["kind"] == "int":
            out += struct.pack(prefix + t["fmt"], int(v))
        else:
            out += struct.pack(prefix + t["fmt"], float(v))
    return out


def unpack_raw(type_name, data, big):
    """从字节解包得到期望值 —— raw 样例的 golden 来自字节本身。"""
    t = TYPES[type_name]
    prefix = ">" if big else "<"
    size = struct.calcsize(t["fmt"])
    vals = []
    for i in range(0, len(data), size):
        (v,) = struct.unpack(prefix + t["fmt"], data[i:i + size])
        vals.append(v)
    return vals


def ascii_token(type_name, v):
    """解码器可读的 ASCII token（NRRD §2 特值用 nan/inf 子串规则）。"""
    t = TYPES[type_name]
    if t["kind"] == "int":
        return str(int(v))
    if math.isnan(v):
        return "nan"
    if v == float("inf"):
        return "inf"
    if v == float("-inf"):
        return "-inf"
    if v == 0.0:
        return "-0.0" if math.copysign(1.0, v) < 0 else "0.0"
    if t["fmt"] == "f":
        # 取 widening 后 binary32 值的最短往返 repr：
        # 十进制 -> binary64 精确（round-trip），-> binary32 精确（已在值上），无双重舍入。
        return repr(f32(v))
    return repr(v)


def expected_from_ascii(type_name, token):
    """与解码器同款语义：整型 Int64 解析+范围；float 时十进制->binary64->binary32。"""
    t = TYPES[type_name]
    if t["kind"] == "int":
        v = int(token)
        if not (t["lo"] <= v <= t["hi"]):
            raise ValueError(f"ascii token out of range for {type_name}: {token}")
        return float(v)  # 期望载体是 Double；整型值在 2^53 内精确
    low = token.lower()
    if "nan" in low:
        return float("nan")
    if "-inf" in low:
        return float("-inf")
    if "inf" in low:
        return float("inf")
    f64 = float(token)
    return f32(f64) if t["fmt"] == "f" else f64


def expected_bits_hex(v):
    """期望 Double 的 IEEE-754 binary64 位型（nan 归一到 canonical nan）。"""
    if math.isnan(v):
        v = float("nan")
    return struct.pack(">d", v).hex()


def canon_token(type_name, v):
    """golden / 报告用的规范化 token（与探针 format_* 输出语义一致）。"""
    if TYPES[type_name]["kind"] == "int":
        return str(int(v))
    if math.isnan(v):
        return "nan"
    if v == float("inf"):
        return "+inf"
    if v == float("-inf"):
        return "-inf"
    if v == 0.0:
        return "-0.0" if math.copysign(1.0, v) < 0 else "0.0"
    return repr(v)


# ---------------------------------------------------------------------------
# 头构造
# ---------------------------------------------------------------------------

def header_lines(type_name, enc, att, n, data_name=None, content=None, extra=None):
    lines = [
        "NRRD0005",
        f"type: {type_name}",
        "dimension: 1",
        f"sizes: {n}",
    ]
    if enc == "ascii":
        lines.append("encoding: ascii")
    else:
        lines.append("encoding: raw")
        lines.append(f"endian: {'big' if enc == 'raw-be' else 'little'}")
    if att == "det":
        lines.append(f"data file: {data_name}")
    if content:
        lines.append(f"content: {content}")
    if extra:
        lines.extend(extra)
    return "\n".join(lines)


# ---------------------------------------------------------------------------
# 48 格生成
# ---------------------------------------------------------------------------

def build_grid_cases():
    cases = []
    for type_name in TYPES:
        for enc in ENCS:
            for att in ATTS:
                combo_id = f"{type_name}/{enc}/{att}"
                stem = f"{type_name}_{enc.replace('-', '')}_{att}"
                t = TYPES[type_name]
                n = len(t["values"])
                note = ""
                if type_name in ("int8", "uint8") and enc in ("raw-le", "raw-be"):
                    note = "单字节 LE/BE 同义：数据字节与期望值相同，仅 endian 字段不同"

                if att == "att":
                    sample = stem + ".nrrd"
                    data_name = None
                else:
                    sample = stem + ".nhdr"
                    ext = "txt" if enc == "ascii" else "raw"
                    data_name = stem + "." + ext

                content = combo_id
                hdr = header_lines(type_name, enc, att, n, data_name, content)

                # 载荷 + 期望
                if enc == "ascii":
                    tokens = [ascii_token(type_name, v) for v in t["values"]]
                    payload = (" ".join(tokens) + "\n").encode("ascii")
                    expected = [expected_from_ascii(type_name, tok) for tok in tokens]
                else:
                    big = enc == "raw-be"
                    payload = write_raw(type_name, t["values"], big)
                    expected = unpack_raw(type_name, payload, big)
                    expected = [
                        (f32(v) if (t["kind"] == "float" and t["fmt"] == "f" and not math.isnan(v))
                         else v) for v in expected
                    ]

                cases.append({
                    "combo_id": combo_id,
                    "sample": sample,
                    "data_file": data_name,
                    "type": type_name,
                    "encoding": "ascii" if enc == "ascii" else "raw",
                    "endian": (None if enc == "ascii" else ("big" if enc == "raw-be" else "little")),
                    "attached": att == "att",
                    "sizes": [n],
                    "header": hdr,
                    "payload": payload,
                    "expected": expected,
                    "note": note,
                })
    return cases


def build_spatial_extras():
    """空间头补充样例（纯自建）：命名空间 + space dimension 两种身份各一。"""
    extras = []
    values = [1000, 1010, 1020, 1030]
    payload = write_raw("int16", values, big=False)
    expected = unpack_raw("int16", payload, big=False)

    # 1) 命名空间 right-anterior-superior（空间维度 3），维度 2 的 per-axis 向量
    # 向量用紧凑格式 "(1.5,0.0,0.0)"（逗号后无空格）——pynrrd 解析器按空白切分向量，
    # 逗号后带空格会被切断；本仓库解析器两种都接受，fixture 取兼容面更广的紧凑形式。
    hdr = "\n".join([
        "NRRD0005",
        "type: int16",
        "dimension: 2",
        "sizes: 2 2",
        "encoding: raw",
        "endian: little",
        "content: spatial/ras-att",
        "space: right-anterior-superior",
        "space origin: (10.0,-5.0,2.5)",
        "space directions: (1.5,0.0,0.0) (0.0,2.0,0.0)",
        "space units: mm mm mm",
        "labels: axis-i axis-j",
        "kinds: domain domain",
    ])
    extras.append({
        "combo_id": "int16/raw-le/att+spatial-ras",
        "sample": "spatial_ras_att.nrrd",
        "data_file": None,
        "type": "int16",
        "encoding": "raw",
        "endian": "little",
        "attached": True,
        "sizes": [2, 2],
        "header": hdr,
        "payload": payload,
        "expected": expected,
        "note": "命名空间 RAS（空间维度3）+ 维度2；labels/kinds 项数=维度，向量分量数=空间维度",
    })

    # 2) space dimension 身份（与 space 互斥，单独出现）
    hdr2 = "\n".join([
        "NRRD0005",
        "type: int16",
        "dimension: 2",
        "sizes: 2 2",
        "encoding: raw",
        "endian: little",
        "content: spatial/dim3-att",
        "space dimension: 3",
        "space origin: (0.0,0.0,0.0)",
        "space directions: (1.0,0.0,0.0) (0.0,1.0,0.0)",
        "space units: mm mm mm",
    ])
    extras.append({
        "combo_id": "int16/raw-le/att+spatial-dim3",
        "sample": "spatial_dim3_att.nrrd",
        "data_file": None,
        "type": "int16",
        "encoding": "raw",
        "endian": "little",
        "attached": True,
        "sizes": [2, 2],
        "header": hdr2,
        "payload": payload,
        "expected": expected,
        "note": "space dimension: 3 身份（不与 space 同时出现）",
    })
    return extras


# ---------------------------------------------------------------------------
# 写 fixtures / expected.json / grid.json
# ---------------------------------------------------------------------------

def write_fixtures(cases):
    os.makedirs(FIX, exist_ok=True)
    expected_doc = {
        "note": "期望值由 tests/gen_fixtures.py 独立构造（写入字节自洽解包 / 解码同款语义），非探针读取回填",
        "semantics": "nan==nan 语义比较；±inf 分符号；零分正负；其余精确相等；NaN payload 不承诺",
        "fixtures": {},
    }
    grid_rows = []
    for c in cases:
        if c["attached"]:
            with open(os.path.join(FIX, c["sample"]), "wb") as f:
                f.write(c["header"].encode("ascii") + b"\n\n" + c["payload"])
        else:
            with open(os.path.join(FIX, c["sample"]), "wb") as f:
                f.write(c["header"].encode("ascii") + b"\n\n")
            with open(os.path.join(FIX, c["data_file"]), "wb") as f:
                f.write(c["payload"])

        toks = [canon_token(c["type"], v) for v in c["expected"]]
        expected_doc["fixtures"][c["sample"]] = {
            "combo_id": c["combo_id"],
            "type": c["type"],
            "encoding": c["encoding"],
            "endian": c["endian"],
            "attached": c["attached"],
            "data_file": c["data_file"],
            "sizes": c["sizes"],
            "values": toks,
            "value_hex": [expected_bits_hex(v) for v in c["expected"]],
            "note": c["note"],
        }
        if c["note"] == "" or "同义" in c["note"]:
            grid_rows.append({
                "combo_id": c["combo_id"],
                "sample": c["sample"],
                "note": c["note"],
            })

    with open(os.path.join(FIX, "expected.json"), "w", encoding="utf-8") as f:
        json.dump(expected_doc, f, indent=1, ensure_ascii=False)
    with open(os.path.join(FIX, "grid.json"), "w", encoding="utf-8") as f:
        json.dump({"rows": grid_rows}, f, indent=1, ensure_ascii=False)


# ---------------------------------------------------------------------------
# grid_cases_test.mbt 生成
# ---------------------------------------------------------------------------

MBT_HELPERS = r'''///| GENERATED by tests/gen_fixtures.py — DO NOT EDIT BY HAND.
///| 48-cell read-side grid: 8 types x {raw-le, raw-be, ascii} x {attached, detached}.
///| Each cell decodes its real fixture payload (embedded as hex) and compares
///| IEEE-754 bit-exactly (NaN semantically) against independently constructed
///| expectations (see tests/gen_fixtures.py for the construction rules).

///| Hex pairs -> Bytes.
fn grid_hex(s : String) -> Bytes {
  let n = s.length()
  let out : Array[Byte] = []
  let mut i = 0
  while i + 1 < n {
    let hi = grid_nibble(s.get_char(i).unwrap())
    let lo = grid_nibble(s.get_char(i + 1).unwrap())
    out.push((hi * 16 + lo).to_byte())
    i = i + 2
  }
  Bytes::from_array(out)
}

///|
fn grid_nibble(c : Char) -> Int {
  if c >= '0' && c <= '9' {
    c.to_int() - 48
  } else if c >= 'a' && c <= 'f' {
    c.to_int() - 87
  } else {
    abort("bad hex in generated grid test")
  }
}

///| Expected value from two 32-bit halves of the binary64 bit pattern
///| (avoids out-of-range Int64 literals for patterns >= 2^63).
fn grid_bits(hi : Int64, lo : Int64) -> Double {
  Int64::reinterpret_as_double((hi << 32).lor(lo))
}

///| Bit-exact compare except NaN (semantic: any NaN equals any NaN).
///| NaN payload/signaling bits are explicitly NOT part of the contract.
fn grid_same(a : Double, b : Double) -> Bool {
  if a.is_nan() || b.is_nan() {
    a.is_nan() && b.is_nan()
  } else {
    a.reinterpret_as_int64() == b.reinterpret_as_int64()
  }
}

///| Decode one grid cell and assert all values.
fn grid_check(
  cell : String,
  header_text : String,
  body_hex : String,
  expected : Array[Double],
) -> Unit raise @moon-nrrd.NrrdError {
  let h = @moon-nrrd.parse_header(header_text)
  let body = grid_hex(body_hex)
  let got = @moon-nrrd.decode_data(body, h)
  if got.length() != expected.length() {
    abort("\{cell}: length \{got.length()} != \{expected.length()}")
  }
  let mut i = 0
  while i < expected.length() {
    if !grid_same(got[i], expected[i]) {
      abort("\{cell}: value \{i} mismatch: got \{@moon-nrrd.format_float(got[i])}")
    }
    i = i + 1
  }
}
'''

MBT_CASE_TEMPLATE = '''
test "grid {cell}" {{
  grid_check(
    "{cell}",
    "{header}",
    "{body_hex}",
    [{expected}],
  )
}}
'''


def mbt_escape(s):
    return s.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")


def gen_mbt(cases):
    parts = [MBT_HELPERS]
    for c in cases:
        cell = c["combo_id"]
        body_hex = c["payload"].hex()
        exp = []
        for v in c["expected"]:
            if math.isnan(v):
                # canonical quiet NaN
                exp.append("grid_bits(0x7ff80000L, 0x00000000L)")
            else:
                h = struct.pack(">d", v).hex()
                hi = int(h[:8], 16)
                lo = int(h[8:], 16)
                exp.append(f"grid_bits(0x{hi:08x}L, 0x{lo:08x}L)")
        parts.append(MBT_CASE_TEMPLATE.format(
            cell=cell,
            header=mbt_escape(c["header"] + "\n"),
            body_hex=body_hex,
            expected=", ".join(exp),
        ))
    path = os.path.join(ROOT, "grid_cases_test.mbt")
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        f.write("".join(parts))
    return path


# ---------------------------------------------------------------------------
# 自检：双重舍入边界案例（不进入 48 格 —— 只在 README/报告记录口径）
# ---------------------------------------------------------------------------

def double_rounding_demo():
    """给出一个十进制 token：decimal->binary64->binary32 与直接 decimal->binary32 不同。"""
    from decimal import Decimal, getcontext
    getcontext().prec = 60
    # float32 相邻值 1.0 与 1+2^-23 的中点 = 1 + 2^-24（binary64 精确可表示）
    mid = 1.0 + 2.0 ** -24
    token = "1.00000005960464477539062500001"  # 略高于中点，但小于半个 binary64 ulp (2^-53)
    d = Decimal(token)
    assert Decimal(mid) < d < Decimal(mid) + Decimal(2.0 ** -53), "token must sit in the double-rounding window"
    via64 = f32(float(token))            # decimal -> binary64 (=mid) -> binary32 (tie-to-even -> 1.0)
    direct = f32(1.0 + 2.0 ** -23)       # 直接 decimal->binary32：高于中点 -> 上舍入到 1+2^-23
    assert via64 != direct, "demo must actually diverge"
    return {
        "token": token,
        "via_binary64_then_binary32": expected_bits_hex(via64),
        "direct_binary32": expected_bits_hex(direct),
        "note": "decimal->binary64->binary32 与直接 decimal->binary32 在此 token 上不同；"
                "本实现走前者（与 Float::from_double 一致），不宣称所有十进制正确舍入",
    }


def main():
    cases = build_grid_cases()
    extras = build_spatial_extras()
    all_cases = cases + extras
    write_fixtures(all_cases)
    mbt = gen_mbt(all_cases)

    combo_ids = [c["combo_id"] for c in cases]
    assert len(combo_ids) == 48, len(combo_ids)
    assert len(set(combo_ids)) == 48, "combo ids must be unique"

    demo = double_rounding_demo()
    with open(os.path.join(FIX, "double_rounding_case.json"), "w", encoding="utf-8") as f:
        json.dump(demo, f, indent=1, ensure_ascii=False)

    print(f"grid cases: {len(cases)} (expect 48), extras: {len(extras)}")
    print(f"fixtures written to {FIX}")
    print(f"generated test: {mbt}")
    print(f"double-rounding demo: {demo['token']} -> via64={demo['via_binary64_then_binary32']}"
          f" direct={demo['direct_binary32']}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
