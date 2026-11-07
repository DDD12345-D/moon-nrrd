#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""外部参照对照（开发期可选，最终里程碑必跑）：pynrrd 读取 vs golden / vs 探针 dump。

依赖（仅本脚本，不参与离线回归）：
  pip install pynrrd==1.1.3 numpy   （pynrrd: MIT License）
两路证据：
  A. pynrrd 读取 vs expected.json golden —— 逐格外部对照（数值语义级）
  B. pynrrd dump vs 探针 dump —— 两级判定：格式一致（文本 diff）+ 数值语义一致
版本与命令行写入 tests/logs/reference-run-<UTC时间戳>.txt（放行文件纠正项 6）。

用法：
  python tests/check_reference.py            # 完整两路
  python tests/check_reference.py --no-probe # 只做 A（无工具链环境时）
环境变量：MOON_BIN / MOON_HOME 同 run_read_regression.py。
退出码：0 全部通过；1 任一差异；2 缺少 pynrrd/numpy 或用法错误。
"""
import json
import math
import os
import platform
import struct
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
FIXTURES = os.path.join(HERE, "fixtures")
EXPECTED = os.path.join(FIXTURES, "expected.json")
LOGS = os.path.join(HERE, "logs")
MOON_BIN = os.environ.get("MOON_BIN", "moon")


def vals_equal(a, b):
    if math.isnan(a) or math.isnan(b):
        return math.isnan(a) and math.isnan(b)
    if a == 0.0 and b == 0.0:
        return math.copysign(1.0, a) == math.copysign(1.0, b)
    return a == b


def fmt_scalar(v):
    """探针 format_float/format_int_value 同款语义：
    整型数组值打印无小数点；浮点打印 nan/±inf/±0.0/最短往返 repr。"""
    import numpy as np
    if isinstance(v, (np.floating, float)):
        f = float(v)
        if math.isnan(f):
            return "nan"
        if f == float("inf"):
            return "+inf"
        if f == float("-inf"):
            return "-inf"
        if f == 0.0:
            return "-0.0" if math.copysign(1.0, f) < 0 else "0.0"
        return repr(f)
    return str(int(v))


def norm_vec(x):
    import numpy as np
    if x is None:
        return "<none>"
    a = np.asarray(x, dtype=object)
    if a.ndim == 1:
        return " ".join(
            fmt_scalar(float(v)) if isinstance(v, (int, float, np.number)) else str(v)
            for v in a
        )
    if a.ndim == 2:
        return " | ".join(" ".join(fmt_scalar(float(c)) for c in row) for row in a)
    return str(x)


def read_with_pynrrd(name):
    import nrrd
    import numpy as np
    path = os.path.join(FIXTURES, name)
    data, header = nrrd.read(path, index_order="F")
    # 线性顺序 = NRRD 顺序（sizes[0] 最快）= Fortran flatten
    flat = np.asarray(data).flatten(order="F")
    raw_vals = list(flat)            # 保留 dtype（整型/浮点打印口径不同）
    values = [float(v) for v in flat]  # 语义比较用
    lines = [f"fixture: {name}"]
    js = {"values": []}

    def emit(key, val):
        lines.append(f"{key}: {val}")

    emit("type", str(header["type"]))
    emit("dimension", str(int(header["dimension"])))
    emit("sizes", " ".join(str(int(s)) for s in header["sizes"]))
    emit("encoding", str(header["encoding"]))
    endian = header.get("endian")
    emit("endian", endian if endian else "<none>")
    df = header.get("data file")
    emit("data file", df if df else "<none>")
    for fld in ["space", "space origin", "space directions", "space units",
                "labels", "kinds", "content"]:
        v = header.get(fld)
        if v is None:
            emit(fld, "<none>")
        elif isinstance(v, str):
            emit(fld, v)
        else:
            emit(fld, norm_vec(v))
    lines.append("values:")
    sizes = [int(s) for s in header["sizes"]]
    idx = [0] * len(sizes)
    n = 0
    total = 1
    for s in sizes:
        total *= s
    # 打印顺序与探针一致：最后一轴最快
    while n < total:
        coord = ",".join(str(i) for i in idx)
        # linear index: NRRD order, first axis fastest
        flat_i = 0
        stride = 1
        for a in range(len(sizes)):
            flat_i += idx[a] * stride
            stride *= sizes[a]
        lines.append(f"  {coord} = {fmt_scalar(raw_vals[flat_i])}")
        a = len(sizes) - 1
        carry = True
        while carry and a >= 0:
            idx[a] += 1
            if idx[a] < sizes[a]:
                carry = False
            else:
                idx[a] = 0
                a -= 1
        n += 1
    return "\n".join(lines) + "\n", values


def parse_dump(text):
    blocks = {}
    cur = None
    in_values = False
    for line in text.splitlines():
        if not line or line.startswith("#"):
            continue
        if line.startswith("fixture: "):
            cur = line[len("fixture: "):]
            blocks[cur] = {"header": [], "values": {}}
            in_values = False
            continue
        if cur is None:
            continue
        if line == "values:":
            in_values = True
            continue
        if in_values:
            coord, _, tok = line.strip().partition(" = ")
            blocks[cur]["values"][coord] = tok
        else:
            k, _, v = line.partition(": ")
            blocks[cur]["header"].append((k, v))
    return blocks


def run_probe(paths):
    cmd = [MOON_BIN, "run", "--target", "js", "cmd/probe", "--"] + paths
    print("+", " ".join(cmd))
    r = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True)
    return cmd, r


def main():
    args = [a for a in sys.argv[1:]]
    do_probe = "--no-probe" not in args

    try:
        import nrrd
        import numpy as np
    except ImportError as e:
        print("missing dependency:", e, file=sys.stderr)
        print("install with: pip install pynrrd==1.1.3 numpy", file=sys.stderr)
        return 2

    if not os.path.exists(EXPECTED):
        print("missing", EXPECTED, "— run tests/gen_fixtures.py first", file=sys.stderr)
        return 2
    with open(EXPECTED, encoding="utf-8") as f:
        golden = json.load(f)["fixtures"]

    os.makedirs(LOGS, exist_ok=True)
    stamp = time.strftime("%Y%m%dT%H%M%SZ", time.gmtime())
    log_path = os.path.join(LOGS, f"reference-run-{stamp}.txt")
    log_lines = [
        f"external reference run @ {stamp}",
        f"platform: {platform.platform()}",
        f"python: {sys.version.split()[0]}",
        f"pynrrd: {nrrd.__version__}",
        f"numpy: {np.__version__}",
        f"command: {sys.executable} {' '.join(sys.argv)}",
        f"moon_bin: {MOON_BIN}",
        "",
    ]

    failures = []
    ref_dump_blocks = []

    # ---- A. pynrrd vs golden（逐格外部对照） ----
    for name in sorted(golden):
        g = golden[name]
        txt, values = read_with_pynrrd(name)
        ref_dump_blocks.append(txt)
        mism = []
        want = [float(t) for t in g["values"]]
        if len(values) != len(want):
            mism.append(f"value count: pynrrd {len(values)} want {len(want)}")
        else:
            for i, (a, b) in enumerate(zip(values, want)):
                if not vals_equal(a, b):
                    mism.append(f"value {i}: pynrrd {a!r} want {b!r}")
        if mism:
            failures.append(f"pynrrd-vs-golden {g['combo_id']}")
            print(f"FAIL ext-golden {g['combo_id']} ({name})")
            for m in mism:
                print("   ", m)
        else:
            print(f"PASS ext-golden {g['combo_id']} ({name}): {len(values)} values")
        log_lines.append(f"{name}: {'FAIL' if mism else 'PASS'} "
                         f"({len(values)} values pynrrd-vs-golden)")

    ref_dump = "\n".join(ref_dump_blocks)
    ref_path = os.path.join(LOGS, "pynrrd-reads.txt")
    with open(ref_path, "w", encoding="utf-8", newline="\n") as f:
        f.write(f"# pynrrd {nrrd.__version__}, numpy {np.__version__}, index_order='F'\n")
        f.write(ref_dump)

    # ---- B. pynrrd dump vs 探针 dump（两级判定） ----
    if do_probe:
        paths = [os.path.join(FIXTURES, n) for n in sorted(golden)
                 if n.endswith((".nrrd", ".nhdr"))]
        cmd, r = run_probe(paths)
        log_lines.append(f"probe command: {' '.join(cmd)}")
        log_lines.append(f"probe exit: {r.returncode}")
        if r.returncode != 0:
            sys.stderr.write(r.stdout)
            sys.stderr.write(r.stderr)
            failures.append("probe run")
        moon_txt = os.path.join(LOGS, "moonbit-reads.txt")
        with open(moon_txt, "w", encoding="utf-8", newline="\n") as f:
            f.write(r.stdout)

        ref = parse_dump(ref_dump)
        got = parse_dump(r.stdout)

        # 格式一致：逐行文本（去掉 pynrrd 头部注释行）
        a_lines = [ln for ln in ref_dump.splitlines() if not ln.startswith("#")]
        b_lines = [ln for ln in r.stdout.splitlines() if not ln.startswith("#")]
        diff_lines = [(i + 1, x, y) for i, (x, y) in enumerate(zip(a_lines, b_lines))
                      if x != y]
        text_ok = not diff_lines and len(a_lines) == len(b_lines)
        if not text_ok:
            if len(a_lines) != len(b_lines):
                print(f"TEXT DIFF: line count pynrrd={len(a_lines)} probe={len(b_lines)}")
            for i, x, y in diff_lines[:20]:
                print(f"TEXT DIFF line {i}:\n  pynrrd: {x!r}\n  probe : {y!r}")
        print("verdict 格式一致:", "PASS" if text_ok else "FAIL")
        log_lines.append(f"verdict 格式一致: {'PASS' if text_ok else 'FAIL'} "
                         f"(diff lines: {len(diff_lines)})")
        if not text_ok:
            failures.append("text diff not empty")

        # 数值语义一致
        sem_bad = 0
        for name in sorted(set(ref) | set(got)):
            if name not in ref or name not in got:
                print("DUMP SET MISMATCH:", name)
                sem_bad += 1
                continue
            rv, gv = ref[name]["values"], got[name]["values"]
            if set(rv) != set(gv):
                print("COORD SET MISMATCH", name)
                sem_bad += 1
            for coord in sorted(set(rv) & set(gv)):
                if not vals_equal(float(rv[coord]), float(gv[coord])):
                    print(f"VALUE MISMATCH {name} {coord}: pynrrd {rv[coord]!r} probe {gv[coord]!r}")
                    sem_bad += 1
            if ref[name]["header"] != got[name]["header"]:
                print("HEADER MISMATCH", name)
                for (rk, rvl), (gk, gvl) in zip(ref[name]["header"], got[name]["header"]):
                    if (rk, rvl) != (gk, gvl):
                        print(f"  pynrrd: {rk}: {rvl}")
                        print(f"  probe : {gk}: {gvl}")
                sem_bad += 1
        sem_ok = sem_bad == 0
        print("verdict 数值语义一致:", "PASS" if sem_ok else f"FAIL ({sem_bad} mismatches)")
        log_lines.append(f"verdict 数值语义一致: {'PASS' if sem_ok else f'FAIL ({sem_bad})'}")
        if not sem_ok:
            failures.append("semantic mismatch")

    print()
    print("==== check_reference summary ====")
    if failures:
        print("FAILED:")
        for f_ in failures:
            print(" -", f_)
    else:
        print("check_reference: ALL PASS (external reference)")
    log_lines.append(f"summary: {'FAIL ' + ','.join(failures) if failures else 'ALL PASS'}")
    with open(log_path, "w", encoding="utf-8", newline="\n") as f:
        f.write("\n".join(log_lines) + "\n")
    print("log saved:", log_path)
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
