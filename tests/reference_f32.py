# -*- coding: utf-8 -*-
"""ASCII float32 直接正确舍入 — 独立精确参考（整数/有理构造）。

不经过 binary64：token -> Decimal(精确) -> Fraction(有理) -> 整数
定点舍入 -> binary32 位型。舍入规则 (nearest, ties-to-even) 用纯整数
余数比较实现，与 MoonBit 侧 limb 大整数实现无共享代码。

契约（与 f32_direct.mbt 一致）：
  - token <= 64 ASCII 字节，超出 -> ERROR
  - 可解析十进制（[.d]d[.d][eE[+-]d]）；nan/inf 是 NRRD 层特值，
    不在本参考/探针电池内（已有既有测试覆盖）
  - |e_val| >= 5000 的精确饱和（可证：>= 5000 -> +-inf，<= -5000 -> +-0）

用法:
  python reference_f32.py               # 打印参考结果 TSV (token<TAB>结果)
  python reference_f32.py --freeze      # 写 tests/f32_tokens.txt + f32_expected.tsv
  python reference_f32.py --gen-mbt     # 生成 f32_direct_wbtest.mbt 边界回归
  python reference_f32.py --compare P   # 与探针输出 TSV 比对，差异非零退出

结果格式: 0x%08x 或 ERROR（与 cmd/f32probe 输出一致）。
"""
import os
import sys
from decimal import Decimal
from fractions import Fraction

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
TOKENS_PATH = os.path.join(HERE, "f32_tokens.txt")
EXPECTED_PATH = os.path.join(HERE, "f32_expected.tsv")
MBT_PATH = os.path.join(ROOT, "f32_direct_wbtest.mbt")

INF_BITS = 0x7F800000
NEG_INF_BITS = 0xFF800000


# ---------------------------------------------------------------------------
# 精确参考实现
# ---------------------------------------------------------------------------

def parse_token(tok):
    """token -> (neg, Fraction value)；非法/超长抛 ValueError。"""
    if len(tok.encode("ascii", errors="replace")) > 64:
        raise ValueError("exceeds 64-byte limit")
    try:
        d = Decimal(tok)
    except Exception:
        raise ValueError("unparseable")
    if not d.is_finite():
        raise ValueError("non-finite literal")
    sign, digits, exp = d.as_tuple()
    if all(dg == 0 for dg in digits):
        return sign == 1, Fraction(0)
    n = 0
    for dg in digits:
        n = n * 10 + dg
    # value = n * 10^exp，与 parse_f32_token 的 e_val 同义
    if exp >= 5000:
        raise OverflowError("saturate-inf" if sign != 1 else "saturate-inf")
    if exp <= -5000:
        raise OverflowError("saturate-zero")
    if exp >= 0:
        val = Fraction(n * 10 ** exp, 1)
    else:
        val = Fraction(n, 10 ** (-exp))
    return sign == 1, val


def floor_log2(fr):
    """floor(log2(fr))，fr > 0 精确有理。"""
    p, q = fr.numerator, fr.denominator
    e = p.bit_length() - q.bit_length()
    while Fraction(2) ** e > fr:
        e -= 1
    while Fraction(2) ** (e + 1) <= fr:
        e += 1
    return e


def round_ties_even(scaled):
    """scaled = 正有理 -> round(scaled)，半值取偶。纯整数比较。"""
    p, q = scaled.numerator, scaled.denominator
    f = p // q
    twice_rem = 2 * (p - f * q)
    if twice_rem > q:
        return f + 1
    if twice_rem < q:
        return f
    return f + 1 if f % 2 == 1 else f


def f32_bits_from_value(neg, val):
    """精确值（Fraction）-> binary32 位型（无符号 32 位 int）。"""
    if val == 0:
        return 0x80000000 if neg else 0
    e = floor_log2(val)
    if e >= 128:
        return NEG_INF_BITS if neg else INF_BITS
    grid_exp = max(e - 23, -149)          # 正规 2^(e-23)，次正规 2^-149
    scaled = val / Fraction(2) ** grid_exp
    q = round_ties_even(scaled)
    # 编码：q < 2^23 只可能出现在次正规网格；q in [2^23, 2^24) 一律
    # 按正规编码（grid=-149 时 e2=-126 mant=0 恰为最小正规）；
    # q == 2^24 是进位到 2^(e2+1)。
    if q == 0:
        return 0x80000000 if neg else 0
    if q < (1 << 23):
        bits = q
    elif q < (1 << 24):
        e2 = grid_exp + 23
        bits = ((e2 + 127) << 23) | (q - (1 << 23))
    else:                                 # 进位 q == 2^24 -> 2^(e2+1)
        assert q == 1 << 24
        e2 = grid_exp + 23
        if e2 + 1 >= 128:
            return NEG_INF_BITS if neg else INF_BITS
        bits = (e2 + 1 + 127) << 23
    return (0x80000000 | bits) if neg else bits


def reference_result(tok):
    """token -> '0x%08x' 或 'ERROR'。"""
    try:
        neg, val = parse_token(tok)
    except OverflowError as ex:
        if "inf" in str(ex):
            return "0x%08x" % (NEG_INF_BITS if tok.strip().startswith("-") else INF_BITS)
        return "0x80000000" if tok.strip().startswith("-") else "0x00000000"
    except ValueError:
        return "ERROR"
    return "0x%08x" % f32_bits_from_value(neg, val)


# ---------------------------------------------------------------------------
# 边界电池（任务四件套）
# ---------------------------------------------------------------------------

# 电池条目：(标签, token)。token 是真实输入字节串。
def battery():
    entries = []

    def add(label, tok):
        entries.append((label, tok))

    # --- 1. 原双重舍入反例、精确中点与两侧（e2=0，1.0 邻域）---
    add("counterexample-above-mid(+1e-29)", "1.00000005960464477539062500001")
    add("exact-midpoint-1+2^-24", "1.000000059604644775390625")
    add("above-midpoint-wide", "1.0000000596046447753906250001")
    add("below-midpoint", "1.0000000596046447753906249")
    add("neg-counterexample", "-1.00000005960464477539062500001")
    add("neg-exact-midpoint", "-1.000000059604644775390625")
    add("neg-below-midpoint", "-1.0000000596046447753906249")
    add("neg-above-midpoint-wide", "-1.0000000596046447753906250001")

    # --- 2. 普通次正规 / 最大次正规 / 最小正规及相邻值 ---
    add("min-subnormal", "1.401298464324817e-45")
    add("subnormal-2ulp", "2.802596928649634e-45")
    add("subnormal-3ulp", "4.203895392974451e-45")
    add("subnormal-256ulp", "3.587280270362436e-43")
    add("subnormal-2^-127", "5.877471754111438e-39")
    add("max-subnormal", "1.1754942106924411e-38")
    add("min-normal", "1.1754943508222875e-38")
    add("min-normal-short-writer", "1.1754944e-38")
    add("min-normal-plus-1ulp", "1.1754944913521338e-38")
    add("above-maxsub-minnorm-mid", "1.1754942807573643e-38")
    add("below-maxsub-minnorm-mid", "1.1754942807573642e-38")
    add("below-zero-minsub-mid", "7.006492321624085e-46")
    add("above-zero-minsub-mid", "7.006492321624086e-46")
    add("above-zero-minsub-mid-18", "7.0064923216240854e-46")
    add("neg-min-subnormal", "-1.401298464324817e-45")
    add("neg-max-subnormal", "-1.1754942106924411e-38")
    add("neg-min-normal", "-1.1754943508222875e-38")
    add("neg-below-zero-minsub-mid", "-7.006492321624085e-46")
    add("neg-above-zero-minsub-mid", "-7.006492321624086e-46")

    # --- 3. e2=-125 邻域与正负镜像（旧 bl==24 误映射区）---
    # 0x00FFFFFF | 0x01000000 中点 = 2^-125-2^-150 = 2.35098863157965179970e-38
    # 0x01000000 | 0x01000001 中点 = 2^-125+2^-149 = 2.35098884177442144842e-38
    add("e2m125-power", "2.350988701644575e-38")
    add("e2m125-zone-max-00ffffff", "2.3509885615147287e-38")
    add("e2m125-plus-1ulp", "2.350988981904268e-38")
    add("e2m125-above-00ffffff-01000000-mid", "2.3509886315796518e-38")
    add("e2m125-below-00ffffff-01000000-mid", "2.3509886315796517e-38")
    add("e2m125-below-01000000-01000001-mid", "2.3509888417744214e-38")
    add("e2m125-above-01000000-01000001-mid", "2.3509888417744215e-38")
    add("neg-e2m125-power", "-2.350988701644575e-38")
    add("neg-e2m125-zone-max", "-2.3509885615147287e-38")
    add("neg-e2m125-plus-1ulp", "-2.350988981904268e-38")
    add("neg-e2m125-above-mid", "-2.3509886315796518e-38")
    add("neg-e2m125-below-mid", "-2.3509886315796517e-38")

    # --- 4. ties-to-even 奇偶 / 进位 / 溢出边界 ---
    # 精确中点（≤64 字节可表达的 tie 点）：
    #   2^24+1   = 2^24|2^24+2 中点       -> 偶 -> 2^24
    #   2^24+3   = 2^24+2|2^24+4 中点     -> 偶 -> 2^24+4
    #   2^24-0.5 = 2^24-1|2^24 中点       -> 偶 -> 2^24
    #   2^128-2^103 = 最大有限|2^128 中点 -> 偶 -> 2^128 = inf
    add("tie-2^24+1-even", "16777217")
    add("tie-2^24+3-odd", "16777219")
    add("exact-2^24+2", "16777218")
    add("tie-below-2^24", "16777215.5")
    add("neg-tie-2^24+1", "-16777217")
    add("neg-tie-2^24+3", "-16777219")
    add("max-finite", "3.4028234663852886e+38")
    add("max-finite-short", "3.4028235e38")
    add("overflow-mid-tie-exact", "340282356779733661637539395458142568448")
    add("overflow-below-mid", "340282356779733661637539395458142568447")
    add("overflow-above-mid", "340282356779733661637539395458142568449")
    add("neg-overflow-mid-tie", "-340282356779733661637539395458142568448")

    # --- 5. 极端指数 / 零 / 前后零 ---
    add("huge-exp-pos", "1e99999")
    add("huge-exp-neg", "-1e99999")
    add("tiny-exp-pos", "1e-99999")
    add("tiny-exp-neg", "-1e-99999")
    add("exp-4999-inf", "1e4999")
    add("exp--4999-zero", "1e-4999")
    add("neg-zero", "-0.0")
    add("pos-zero", "0.0")
    add("neg-zero-exp", "-0e99")
    add("leading-trailing-zeros", "000.1000")
    add("leading-zeros-int", "00016777217")
    add("trailing-zeros-exp", "1.2300e2")

    # --- 6. 写端最短串验回样本 ---
    add("writer-0.1", "0.1")
    add("writer-1.5", "1.5")
    add("writer-16777216", "16777216")
    add("writer-max-finite", "3.4028235e+38")

    # --- 7. 非法 / 超长 -> ERROR ---
    add("illegal-abc", "abc")
    add("illegal-2dots", "1.2.3")
    add("illegal-doublesign", "--1")
    add("illegal-e-only", "1e")
    add("illegal-no-int", "e3")
    add("illegal-3dots", "1.5.5")
    add("toolong-65bytes", "0." + "0" * 62 + "1")
    add("toolong-65digits", "1" * 65)
    return entries


# ---------------------------------------------------------------------------
# 输出/冻结/生成
# ---------------------------------------------------------------------------

def fmt_line(tok, res):
    return "%s\t%s" % (tok, res)


def print_tsv():
    for label, tok in battery():
        print(fmt_line(tok, reference_result(tok)))


def freeze():
    entries = battery()
    with open(TOKENS_PATH, "w", encoding="utf-8", newline="\n") as f:
        f.write("# ASCII float32 direct-rounding boundary battery "
                "(generated by reference_f32.py --freeze)\n")
        f.write("# one token per line; '#' lines are comments\n")
        for label, tok in entries:
            f.write("%s\n" % tok)
    with open(EXPECTED_PATH, "w", encoding="utf-8", newline="\n") as f:
        f.write("# token<TAB>expected  (independent exact reference)\n")
        for label, tok in entries:
            f.write("%s\t%s\n" % (tok, reference_result(tok)))
    print("wrote %s (%d tokens)" % (TOKENS_PATH, len(entries)))
    print("wrote %s" % EXPECTED_PATH)


def gen_mbt():
    entries = battery()
    out = []
    out.append("///| GENERATED by tests/reference_f32.py --gen-mbt — DO NOT EDIT.\n")
    out.append("///| Boundary regression for the direct decimal -> binary32\n")
    out.append("///| correct-rounding parser (f32_direct_bits).  Expected bit\n")
    out.append("///| patterns come from the independent exact reference\n")
    out.append("///| (tests/reference_f32.py, integer/rational construction).\n")
    out.append("///| Bits are compared as signed Int32 (the parser's return type).\n")
    out.append("///| f32_bits_quiet is the encode.mbt non-raising wrapper over\n")
    out.append("///| f32_direct_bits (write-side verification also uses it).\n\n")

    def lit(hex8):
        """'0x%08x' -> MoonBit Int 字面量（有符号十进制）。"""
        v = int(hex8, 16)
        if v >= 2 ** 31:
            v -= 2 ** 32
        return str(v)

    idx = 0
    for label, tok in entries:
        res = reference_result(tok)
        safe = tok.replace("\\", "\\\\").replace('"', '\\"')
        if res == "ERROR":
            out.append('test "f32 boundary %02d %s" {\n' % (idx, label))
            out.append('  assert_true(f32_bits_quiet("%s") == None, msg="must reject")\n' % safe)
            out.append("}\n\n")
        else:
            out.append('test "f32 boundary %02d %s" {\n' % (idx, label))
            out.append("  assert_true(\n")
            out.append('    f32_bits_quiet("%s") == Some(%s),\n' % (safe, lit(res)))
            out.append('    msg="%s",\n' % label)
            out.append("  )\n")
            out.append("}\n\n")
        idx += 1
    # 公共读路径（decode_data）关键位型抽查：原反例 + 最小正规 + 镜像
    out.append("///| 公共读路径抽查：同一位型经 decode_data 全链路复现。\n")
    out.append('test "f32 boundary public decode path" {\n')
    for tok, expect in [
        ("1.00000005960464477539062500001", "0x3f800001"),
        ("1.000000059604644775390625", "0x3f800000"),
        ("1.1754943508222875e-38", "0x00800000"),
        ("-1.1754943508222875e-38", "0x80800000"),
        ("2.350988701644575e-38", "0x01000000"),
        ("-2.3509885615147287e-38", "0x80ffffff"),
    ]:
        out.append(
            "  assert_true(\n"
            "    decode_one_ascii_bits(\"%s\") == Some(%s),\n"
            '    msg="decode path %s",\n'
            "  )\n" % (tok, lit(expect), tok)
        )
    out.append("}\n\n")
    out.append("///| Helper: decode a single ASCII float token via the public\n")
    out.append("///| read path (header parse + decode_data), returning the\n")
    out.append("///| recovered binary32 bits.\n")
    out.append("fn decode_one_ascii_bits(tok : String) -> Int? {\n")
    out.append("  try {\n")
    out.append('    let text = "NRRD0005\\ntype: float\\ndimension: 1\\n'
              'sizes: 1\\nencoding: ascii\\n\\n" + tok\n')
    out.append("    let data = ascii_to_bytes(text)\n")
    out.append("    let (hb, body) = split_header_body(data)\n")
    out.append("    let h = parse_header(bytes_to_ascii(hb))\n")
    out.append("    let vals = decode_data(body, h)\n")
    out.append("    Some(Float::reinterpret_as_int(Float::from_double(vals[0])))\n")
    out.append("  } catch {\n")
    out.append("    NrrdError(_) => None\n")
    out.append("  }\n")
    out.append("}\n")
    with open(MBT_PATH, "w", encoding="utf-8", newline="\n") as f:
        f.write("".join(out))
    print("wrote %s (%d cases)" % (MBT_PATH, len(entries)))


def compare(probe_path):
    bad = 0
    n = 0
    with open(probe_path, encoding="utf-8") as f:
        probe = {}
        for ln in f:
            ln = ln.rstrip("\n")
            if not ln or ln.startswith("#"):
                continue
            parts = ln.split("\t")
            if len(parts) >= 2:
                probe[parts[0]] = parts[1]
    for label, tok in battery():
        want = reference_result(tok)
        got = probe.get(tok, "<missing>")
        n += 1
        if want != got:
            bad += 1
            print("MISMATCH %s: token=%r reference=%s probe=%s" % (label, tok, want, got))
    print("compare: %d tokens, %d mismatches" % (n, bad))
    return 1 if bad else 0


def main(argv):
    if "--freeze" in argv:
        freeze()
        return 0
    if "--gen-mbt" in argv:
        gen_mbt()
        return 0
    if "--compare" in argv:
        i = argv.index("--compare")
        return compare(argv[i + 1])
    print_tsv()
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
