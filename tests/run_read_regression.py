#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""仓库内离线读取回归：探针输出 vs tests/fixtures/expected.json golden。

纯标准库，不需要 numpy/pynrrd —— 只需要达标 MoonBit 工具链（跑探针）。
判定口径（与 check_semantic 同款，两级判定里的数值语义级）：
  nan==nan 语义比较；±inf 分符号；零分正负（-0.0 != 0.0）；其余精确 ==，无容差。

用法（在 moon-nrrd/ 或任意目录）：
  python tests/run_read_regression.py
环境变量：
  MOON_BIN   moon 可执行文件（默认 "moon"；建议指向达标工具链 bin/moon.exe）
  MOON_HOME  工具链 HOME（zvm 基线需显式设置）
退出码：0 全部通过；1 任一差异；2 环境/用法错误。
"""
import json
import math
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
FIXTURES = os.path.join(HERE, "fixtures")
EXPECTED = os.path.join(FIXTURES, "expected.json")
MOON_BIN = os.environ.get("MOON_BIN", "moon")


def vals_equal(a, b):
    if math.isnan(a) or math.isnan(b):
        return math.isnan(a) and math.isnan(b)
    if a == 0.0 and b == 0.0:
        return math.copysign(1.0, a) == math.copysign(1.0, b)
    return a == b


def parse_probe_dump(text):
    """-> {fixture: {'header': [(k, v)...], 'values': {coord: token}}}"""
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
            if not _:
                raise SystemExit(f"unparsable value line: {line!r}")
            blocks[cur]["values"][coord] = tok
        else:
            k, _, v = line.partition(": ")
            blocks[cur]["header"].append((k, v))
    return blocks


def linear_coords(sizes):
    """NRRD 线性顺序（sizes[0] 最快）的坐标字符串序列。"""
    idx = [0] * len(sizes)
    out = []
    total = 1
    for s in sizes:
        total *= s
    n = 0
    while n < total:
        out.append(",".join(str(i) for i in idx))
        a = 0
        carry = True
        while carry and a < len(sizes):
            idx[a] += 1
            if idx[a] < sizes[a]:
                carry = False
            else:
                idx[a] = 0
                a += 1
        n += 1
    return out


def main():
    if not os.path.exists(EXPECTED):
        print("missing", EXPECTED, "— run tests/gen_fixtures.py first", file=sys.stderr)
        return 2
    with open(EXPECTED, encoding="utf-8") as f:
        golden = json.load(f)["fixtures"]

    # 探针只吃 attached .nrrd 与 detached .nhdr；data file 由探针解析
    paths = []
    for name in sorted(golden):
        if name.endswith((".nrrd", ".nhdr")):
            paths.append(os.path.join(FIXTURES, name))
    cmd = [MOON_BIN, "run", "--target", "js", "cmd/probe", "--"] + paths
    print("+", " ".join(cmd))
    r = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True)
    if r.returncode != 0:
        sys.stderr.write(r.stdout)
        sys.stderr.write(r.stderr)
        print(f"probe exited {r.returncode}", file=sys.stderr)
        return 1

    got = parse_probe_dump(r.stdout)
    bad = 0
    for name in sorted(golden):
        g = golden[name]
        if name not in got:
            print(f"FAIL {name}: missing from probe output")
            bad += 1
            continue
        blk = got[name]
        # 头字段（期望侧存结构化字段；探针侧存 dump 行）
        hdr = dict(blk["header"])
        checks = [
            ("type", g["type"]),
            ("dimension", str(len(g["sizes"]))),
            ("sizes", " ".join(str(s) for s in g["sizes"])),
            ("encoding", g["encoding"]),
            ("endian", g["endian"] if g["endian"] else "<none>"),
            ("data file", g["data_file"] if g["data_file"] else "<none>"),
        ]
        mism = []
        for k, want in checks:
            if hdr.get(k) != want:
                mism.append(f"{k}: got {hdr.get(k)!r} want {want!r}")
        vals = blk["values"]
        if len(vals) != len(g["values"]):
            mism.append(f"value count: got {len(vals)} want {len(g['values'])}")
        else:
            for i, (coord, want_tok) in enumerate(zip(linear_coords(g["sizes"]), g["values"])):
                got_tok = vals.get(coord)
                if got_tok is None:
                    mism.append(f"value {i} ({coord}): missing")
                    continue
                if not vals_equal(float(got_tok), float(want_tok)):
                    mism.append(f"value {i} ({coord}): got {got_tok!r} want {want_tok!r}")
        if mism:
            bad += 1
            print(f"FAIL {g['combo_id']} ({name})")
            for m in mism:
                print("   ", m)
        else:
            n = len(g["values"])
            print(f"PASS {g['combo_id']} ({name}): {n} values + header match golden")
    print()
    print("==== run_read_regression summary ====")
    print(f"fixtures: {len(golden)}, failures: {bad}")
    if bad:
        return 1
    print("run_read_regression: ALL PASS (probe vs golden, offline)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
