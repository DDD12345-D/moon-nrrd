#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""写端 48 格外部对照取证：我们写 -> pynrrd 读（独立对照）。

流水线（全部离线，仅本地工具）：
  1. moon run cmd/write-probe -- <out-dir>   —— 48 格全部由写端 API
     (assemble_attached / assemble_detached) 生成，字节不经过 Python。
  2. 每格三路取证（互不回填）：
     a. pynrrd 读取  —— 类型 / 尺寸 / 编码 / 大小端 / content / 数据值
        语义级比较（nan==nan 语义、±inf 分符号、零分正负）；
     b. 字节级 golden —— payload 与 Python struct.pack 独立算出的
        期望字节逐字节相等（raw 格；此即 BE 真实字节序验证：期望字节
        按 big/little 显式打包，写错字节序立即不等）；
     c. ASCII token 级 —— 写出的每个 token 用 Python 数值解析规则
        独立换算，与期望值语义相等（有限值/负零往返、NaN 语义）。
  3. 附加一致性闸：与读侧 tests/fixtures/expected.json 的 value_hex
     比对（期望规格一致，非读侧通过表复用；不一致即 FAIL）。

期望值独立性：期望由 tests/gen_fixtures.py 的 TYPES 规格独立构造
（float 按 binary32 存储舍入 f32(v)；整型载体 Double 精确），
不从写端/读端任何输出回填。

用法：  python tests/check_write_reference.py
环境：  MOON_BIN / MOON_HOME 同 run_read_regression.py
输出：  tests/logs/write-reference-run-<UTC>.txt 取证日志（48 行 combo 证据）
退出码：0 全部通过；1 任一差异；2 环境/用法错误。
"""
import json
import math
import os
import platform
import shutil
import struct
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, HERE)
import gen_fixtures as gf  # noqa: E402  TYPES / f32 / write_raw —— 期望规格，非结果回填

MOON_BIN = os.environ.get("MOON_BIN", "moon")
OUT_DIR = os.path.join(HERE, "out", "write-ref")
LOG_DIR = os.path.join(HERE, "logs")
EXPECTED_JSON = os.path.join(HERE, "fixtures", "expected.json")

TYPES_ORDER = ["int8", "uint8", "int16", "uint16", "int32", "uint32", "float", "double"]
ENCS = ["raw-le", "raw-be", "ascii"]
ATTS = ["att", "det"]

NUMPY_DTYPE = {
    "int8": "int8", "uint8": "uint8", "int16": "int16", "uint16": "uint16",
    "int32": "int32", "uint32": "uint32", "float": "float32", "double": "float64",
}


def sem_eq(a, b):
    if isinstance(a, float) and isinstance(b, float):
        if math.isnan(a) or math.isnan(b):
            return math.isnan(a) and math.isnan(b)
        if a == 0.0 and b == 0.0:
            return math.copysign(1.0, a) == math.copysign(1.0, b)
    return a == b


def expected_values(type_name):
    """TYPES 规格 -> 期望载体值（Double 语义），raw/ascii 同一语义。"""
    t = gf.TYPES[type_name]
    out = []
    for v in t["values"]:
        if t["kind"] == "int":
            out.append(float(v))
        elif t["fmt"] == "f":
            out.append(gf.f32(v))  # binary32 存储舍入；nan 保持 nan
        else:
            out.append(v)
    return out


def expected_payload(type_name, enc):
    """Python struct.pack 独立打包的期望字节（raw）或期望 token 文本（ascii）。"""
    t = gf.TYPES[type_name]
    if enc != "ascii":
        return gf.write_raw(type_name, t["values"], big=(enc == "raw-be"))
    toks = []
    for v in t["values"]:
        # 与写端同语义的可解析 token（不是写端输出回填；此处仅用于
        # token -> 值 的独立换算比对，期望值仍来自 expected_values）
        toks.append(gf.ascii_token(type_name, v))
    return (" ".join(toks) + "\n").encode("ascii")


def parse_header_text(text):
    """极简头解析：field -> desc（供元数据比对，独立于写端/读端实现）。"""
    fields = {}
    lines = text.split("\n")
    if not lines or lines[0] != "NRRD0005":
        raise ValueError("first line is not NRRD0005")
    for line in lines[1:]:
        if line == "":
            break
        if ":" not in line:
            raise ValueError(f"bad header line: {line!r}")
        k, _, v = line.partition(":")
        fields[k.strip().lower().replace(" ", "")] = v.strip()
    return fields


def split_att_file(raw):
    i = raw.find(b"\n\n")
    if i < 0:
        raise ValueError("attached file has no header/body blank line")
    return raw[: i + 2], raw[i + 2:]


def hex_float(v):
    return gf.expected_bits_hex(v)


def run_write_probe(log):
    if os.path.isdir(OUT_DIR):
        shutil.rmtree(OUT_DIR)
    os.makedirs(OUT_DIR, exist_ok=True)
    cmd = [MOON_BIN, "run", "--target", "js", "cmd/write-probe", "--", OUT_DIR]
    print("+", " ".join(cmd))
    log.write("+ " + " ".join(cmd) + "\n")
    r = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True)
    log.write(r.stdout)
    if r.stderr:
        log.write("[stderr]\n" + r.stderr)
    if r.returncode != 0:
        print(f"write-probe exited {r.returncode}", file=sys.stderr)
        log.write(f"write-probe exited {r.returncode}\n")
        return False
    return True


def main():
    if not os.path.isdir(LOG_DIR):
        os.makedirs(LOG_DIR)
    ts = time.strftime("%Y%m%dT%H%M%SZ", time.gmtime())
    log_path = os.path.join(LOG_DIR, f"write-reference-run-{ts}.txt")
    failures = 0
    with open(log_path, "w", encoding="utf-8") as log:
        log.write("moon-nrrd write-side reference check (we write -> pynrrd reads)\n")
        log.write(f"utc: {ts}\n")
        log.write(f"platform: {platform.platform()}  python: {platform.python_version()}\n")
        try:
            import nrrd
            import numpy
            log.write(f"pynrrd: {nrrd.__version__}  numpy: {numpy.__version__}\n")
        except ImportError:
            print("pynrrd/numpy not available (use nrrd-research/venv)", file=sys.stderr)
            return 2
        mv = subprocess.run([MOON_BIN, "version"], capture_output=True, text=True)
        log.write("moon: " + (mv.stdout or mv.stderr).strip().splitlines()[0] + "\n")
        log.write("commands: moon run --target js cmd/write-probe -- <out>; "
                  "python tests/check_write_reference.py\n")
        log.write("semantics: nan==nan; +-inf signed; zero signed; rest exact\n")
        log.write("golden: payload == python struct.pack (byte-exact; BE proven by explicit big-endian packing)\n")
        log.write("=" * 72 + "\n")

        if not run_write_probe(log):
            return 1

        golden = json.load(open(EXPECTED_JSON, encoding="utf-8"))["fixtures"]

        rows = []
        for type_name in TYPES_ORDER:
            t = gf.TYPES[type_name]
            n = len(t["values"])
            want_vals = expected_values(type_name)
            for enc in ENCS:
                for att in ATTS:
                    combo_id = f"{type_name}/{enc}/{att}"
                    stem = f"{type_name}_{enc.replace('-', '')}_{att}"
                    ext = "txt" if enc == "ascii" else "raw"
                    data_name = f"{stem}.{ext}"
                    status = []
                    ok = True

                    # ---- files on disk ----
                    if att == "att":
                        fpath = os.path.join(OUT_DIR, stem + ".nrrd")
                        if not os.path.isfile(fpath):
                            rows.append((combo_id, "MISSING " + fpath, False))
                            failures += 1
                            continue
                        raw = open(fpath, "rb").read()
                        try:
                            head_b, payload = split_att_file(raw)
                        except ValueError as e:
                            rows.append((combo_id, f"structure: {e}", False))
                            failures += 1
                            continue
                    else:
                        fpath = os.path.join(OUT_DIR, stem + ".nhdr")
                        dpath = os.path.join(OUT_DIR, data_name)
                        if not (os.path.isfile(fpath) and os.path.isfile(dpath)):
                            rows.append((combo_id, f"MISSING {fpath} / {dpath}", False))
                            failures += 1
                            continue
                        head_b = open(fpath, "rb").read()
                        payload = open(dpath, "rb").read()

                    # ---- header text checks (independent mini-parser) ----
                    try:
                        fields = parse_header_text(head_b.decode("ascii"))
                    except ValueError as e:
                        rows.append((combo_id, f"header: {e}", False))
                        failures += 1
                        continue
                    checks = [
                        (fields.get("type") == type_name, f"type={fields.get('type')}"),
                        (fields.get("dimension") == "1", f"dimension={fields.get('dimension')}"),
                        (fields.get("sizes") == str(n), f"sizes={fields.get('sizes')}"),
                        (fields.get("encoding") == ("ascii" if enc == "ascii" else "raw"),
                         f"encoding={fields.get('encoding')}"),
                        (fields.get("content") == combo_id, f"content={fields.get('content')}"),
                    ]
                    if enc == "ascii":
                        checks.append((fields.get("endian") is None, "endian should be absent"))
                    else:
                        want_endian = "big" if enc == "raw-be" else "little"
                        checks.append((fields.get("endian") == want_endian,
                                       f"endian={fields.get('endian')}"))
                    if att == "det":
                        checks.append((fields.get("datafile") == data_name,
                                       f"data file={fields.get('datafile')}"))
                    else:
                        checks.append((fields.get("datafile") is None, "data file should be absent"))
                    if att == "det" and not head_b.endswith(b"\n\n"):
                        checks.append((False, "header must end with blank line"))
                    for good, desc in checks:
                        if not good:
                            ok = False
                            status.append("header:" + desc)

                    # ---- byte-exact golden (raw) / token-semantic (ascii) ----
                    # NaN cells are SEMANTIC-ONLY (G2 v2 §7.1: NaN payload /
                    # signaling bits are not promised): require both sides to be
                    # NaN encodings, never byte equality.
                    if enc != "ascii":
                        want_bytes = expected_payload(type_name, enc)
                        item = struct.calcsize(gf.TYPES[type_name]["fmt"])
                        big = enc == "raw-be"
                        for i in range(n):
                            w = want_vals[i]
                            got_chunk = payload[i * item:(i + 1) * item]
                            want_chunk = want_bytes[i * item:(i + 1) * item]
                            if isinstance(w, float) and math.isnan(w):
                                if not is_nan_chunk(got_chunk, gf.TYPES[type_name]["fmt"], big):
                                    ok = False
                                    status.append(f"value[{i}] expected NaN encoding, got {got_chunk.hex()}")
                                elif got_chunk != want_chunk:
                                    status.append(f"value[{i}] NaN payload differs (not promised)")
                                continue
                            if got_chunk != want_chunk:
                                ok = False
                                status.append(
                                    f"value[{i}] bytes {got_chunk.hex()} != golden {want_chunk.hex()}")
                        # BE real byte-order proof (multi-byte): LE bytes must differ
                        if enc == "raw-be" and item_gt1(type_name):
                            le_bytes = gf.write_raw(type_name, t["values"], big=False)
                            if payload == le_bytes:
                                ok = False
                                status.append("BE payload equals LE payload (byte order lost)")
                            else:
                                status.append("BE-bytes!=LE-bytes(proven)")
                        if enc in ("raw-le", "raw-be") and not item_gt1(type_name):
                            status.append("single-byte LE==BE (synonym cell)")
                    else:
                        try:
                            text = payload.decode("ascii")
                        except UnicodeDecodeError:
                            ok = False
                            text = ""
                            status.append("ascii payload not ASCII")
                        toks = text.split()
                        if len(toks) != n:
                            ok = False
                            status.append(f"ascii token count {len(toks)} != {n}")
                        else:
                            for i, tok in enumerate(toks):
                                try:
                                    got = gf.expected_from_ascii(type_name, tok)
                                except ValueError as e:
                                    ok = False
                                    status.append(f"token[{i}] {tok!r}: {e}")
                                    continue
                                if not sem_eq(got, want_vals[i]):
                                    ok = False
                                    status.append(f"token[{i}] {tok!r} -> {got} != {want_vals[i]}")

                    # ---- pynrrd external read ----
                    try:
                        data, hdr = nrrd.read(fpath)
                        if str(data.dtype.name) != NUMPY_DTYPE[type_name]:
                            ok = False
                            status.append(f"dtype {data.dtype} != {NUMPY_DTYPE[type_name]}")
                        got_vals = data.tolist()
                        if not isinstance(got_vals, list):
                            got_vals = [got_vals]
                        if len(got_vals) != n:
                            ok = False
                            status.append(f"pynrrd count {len(got_vals)} != {n}")
                        else:
                            for i, (g, w) in enumerate(zip(got_vals, want_vals)):
                                if not sem_eq(float(g), float(w)):
                                    ok = False
                                    status.append(f"pynrrd value[{i}] {g!r} != {w!r}")
                        htype = str(hdr.get("type", "")).lower()
                        if htype != type_name:
                            ok = False
                            status.append(f"pynrrd header type {htype}")
                        if int(hdr.get("dimension", -1)) != 1:
                            ok = False
                            status.append("pynrrd dimension")
                        if "content" in hdr and hdr["content"] != combo_id:
                            ok = False
                            status.append(f"pynrrd content {hdr.get('content')!r}")
                    except Exception as e:  # noqa: BLE001 — evidence must not crash
                        ok = False
                        status.append(f"pynrrd error: {e}")

                    # ---- golden consistency guard (read-side spec, not pass table) ----
                    g = golden.get(stem + (".nrrd" if att == "att" else ".nhdr"))
                    if g is None:
                        ok = False
                        status.append("missing read-side golden entry")
                    else:
                        want_hex = [hex_float(w) for w in want_vals]
                        if g["value_hex"] != want_hex:
                            ok = False
                            status.append("golden value_hex mismatch (values drift)")

                    rows.append((combo_id, "; ".join(status) if status else "ok", ok))
                    if not ok:
                        failures += 1

        for combo_id, detail, ok in rows:
            mark = "PASS" if ok else "FAIL"
            log.write(f"{mark}  {combo_id:24s}  {detail}\n")
            print(f"{mark}  {combo_id:24s}  {detail}")
        log.write("-" * 72 + "\n")
        failures += check_extra_samples(log)
        log.write("=" * 72 + "\n")
        n_ok = sum(1 for _, _, ok in rows if ok)
        summary = (f"write-reference: {n_ok}/{len(rows)} cells pass "
                   f"+ 2 extra samples (failures={failures})")
        log.write(summary + "\n")
        print(summary)
        if failures == 0:
            print("check_write_reference: ALL PASS (we write -> pynrrd reads, offline)")
    print(f"log: {log_path}")
    return 0 if failures == 0 else 1


def item_gt1(type_name):
    return type_name not in ("int8", "uint8")


def is_nan_chunk(chunk, fmt, big):
    """Chunk bytes decode to a float NaN encoding (any payload)."""
    (v,) = struct.unpack((">" if big else "<") + fmt, chunk)
    return math.isnan(v)


def check_extra_samples(log):
    """多维索引顺序 + 空间元数据外部读取验证（pynrrd 独立读）。

    1. multi2x3x2_att.nrrd — 2x3x2 int16，值 = 100*i + 10*j + k。
       pynrrd 默认 index_order='F'，shape == sizes == (2,3,2)，
       data[i,j,k] 对应 sizes[0]=i：逐格核对索引顺序（1-D 自读
       往返无法发现轴序错误）。
    2. spatial_meta_det.nhdr — 2x3 double 在 named 3-D space 中，
       带 labels / space origin / space directions / space units /
       kinds。数组维度(2) != 空间维度(3)，逐字段外部核对。
    """
    import nrrd  # noqa: PLC0415 — 与 main() 同源的本地 venv 依赖
    rows = []

    # ---- 1. multi-dim index order ----
    fpath = os.path.join(OUT_DIR, "multi2x3x2_att.nrrd")
    ok = True
    status = []
    try:
        data, hdr = nrrd.read(fpath)
        if tuple(data.shape) != (2, 3, 2):
            ok = False
            status.append(f"shape {data.shape} != (2,3,2)")
        if str(data.dtype.name) != "int16":
            ok = False
            status.append(f"dtype {data.dtype} != int16")
        if int(hdr.get("dimension", -1)) != 3:
            ok = False
            status.append(f"dimension {hdr.get('dimension')}")
        if "content" in hdr and hdr["content"] != "extra/multi2x3x2":
            ok = False
            status.append(f"content {hdr.get('content')!r}")
        for i in range(2):
            for j in range(3):
                for k in range(2):
                    want = 100 * i + 10 * j + k
                    got = int(data[i, j, k])
                    if got != want:
                        ok = False
                        status.append(f"data[{i},{j},{k}]={got} != {want}")
        status.append("index order data[i,j,k]==100i+10j+k" if ok else "index order BROKEN")
    except Exception as e:  # noqa: BLE001
        ok = False
        status.append(f"pynrrd error: {e}")
    rows.append(("multi2x3x2/index-order", "; ".join(status), ok))

    # ---- 2. spatial metadata external read ----
    fpath = os.path.join(OUT_DIR, "spatial_meta_det.nhdr")
    ok = True
    status = []
    want_vals = [0.0, -0.0, 1.0, -1.5, 0.1, 2.5]
    try:
        data, hdr = nrrd.read(fpath)
        if tuple(data.shape) != (2, 3):
            ok = False
            status.append(f"shape {data.shape} != (2,3)")
        got_flat = data.reshape(-1).tolist()
        # NRRD 文件序 = sizes[0] 最快轴（F 序）；reshape(-1) 是 C 序，
        # 因此按 data[i,j] 对照文件位置 i + sizes[0]*j 的期望值。
        for j in range(3):
            for i in range(2):
                g = float(data[i, j])
                w = want_vals[i + 2 * j]
                if not sem_eq(g, w):
                    ok = False
                    status.append(f"data[{i},{j}] {g!r} != {w!r}")
        del got_flat
        # labels (per array axis)
        labels = tuple(str(x) for x in hdr.get("labels", ()))
        if labels != ("row", "col"):
            ok = False
            status.append(f"labels {labels!r}")
        # kinds (per array axis)
        kinds = tuple(str(x) for x in hdr.get("kinds", ()))
        if kinds != ("domain", "domain"):
            ok = False
            status.append(f"kinds {kinds!r}")
        # space name
        space = str(hdr.get("space", "")).lower()
        if space != "right-anterior-superior":
            ok = False
            status.append(f"space {space!r}")
        # space origin (space dimension = 3)
        origin = hdr.get("space origin")
        origin_t = tuple(float(x) for x in origin) if origin is not None else ()
        if len(origin_t) != 3 or any(
            not sem_eq(o, w) for o, w in zip(origin_t, (1.5, 0.0, -2.0))
        ):
            ok = False
            status.append(f"space origin {origin_t!r}")
        # space directions (2 rows, each a 3-vector; pynrrd may give
        # masked entries / tuples — compare numerically when present)
        dirs = hdr.get("space directions")
        if dirs is None:
            ok = False
            status.append("space directions missing")
        else:
            want_dirs = [(1.5, 0.0, 0.0), (0.0, 1.5, 0.0)]
            if len(dirs) != 2:
                ok = False
                status.append(f"directions rows {len(dirs)} != 2")
            else:
                for r, (row, want_row) in enumerate(zip(dirs, want_dirs)):
                    row_t = tuple(float(x) for x in row)
                    if len(row_t) != 3 or any(
                        not sem_eq(a, b) for a, b in zip(row_t, want_row)
                    ):
                        ok = False
                        status.append(f"directions[{r}] {row_t!r} != {want_row!r}")
        # space units (space dimension = 3)
        units = tuple(str(x) for x in hdr.get("space units", ()))
        if units != ("mm", "mm", "mm"):
            ok = False
            status.append(f"space units {units!r}")
        if ok:
            status.append("labels/kinds/space/origin/directions/units all match")
    except Exception as e:  # noqa: BLE001
        ok = False
        status.append(f"pynrrd error: {e}")
    rows.append(("spatial-meta/external-read", "; ".join(status), ok))

    for combo_id, detail, ok in rows:
        mark = "PASS" if ok else "FAIL"
        log.write(f"{mark}  {combo_id:24s}  {detail}\n")
        print(f"{mark}  {combo_id:24s}  {detail}")
    return sum(1 for _, _, ok in rows if not ok)


if __name__ == "__main__":
    sys.exit(main())
