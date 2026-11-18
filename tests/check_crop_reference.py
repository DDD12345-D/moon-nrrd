#!/usr/bin/env python
"""Crop external read-back check (pynrrd).

Reads crop_orig_att.nrrd and crop_out_att.nrrd written by cmd/crop-probe,
verifies real values, sizes, and space fields against hand-computed
expectations. Space origin is verified independently via coordinate
relation: origin' = origin + sum(start_i * dir_i).

Usage: python tests/check_crop_reference.py <dir>
Exit: 0 = all pass, 1 = mismatch, 2 = usage.
"""
import sys
import os
import math
import numpy as np
import nrrd


def safe_float_eq(a, b, tol=1e-9):
    """Float comparison that explicitly rejects NaN.  abs(NaN)>tol is False
    in IEEE 754, which would let NaN pass a naive check."""
    if math.isnan(a) or math.isnan(b):
        return False
    return abs(a - b) <= tol

FORMULA = "value(x,y,z) = 100*x + 10*y + z"
START = (1, 1, 0)
CROP_SIZE = (1, 2, 2)
ORIG_SIZES = (2, 3, 2)
CROP_SIZES = (1, 2, 2)
ORIG_ORIGIN = (10.0, -5.0, 2.5)
DIRECTIONS = ((1.5, 0.0, 0.0), (0.0, 2.0, 0.0), (0.0, 0.0, 2.5))
# Hand-computed: origin' = origin + 1*(1.5,0,0) + 1*(0,2,0) + 0*(0,0,2.5)
EXPECTED_CROP_ORIGIN = (11.5, -3.0, 2.5)
# Hand-computed values from formula:
# crop(x',y',z') = input(x'+1, y'+1, z'+0)
# (0,0,0)->(1,1,0)=110  (0,1,0)->(1,2,0)=120
# (0,0,1)->(1,1,1)=111  (0,1,1)->(1,2,1)=121
EXPECTED_CROP_VALUES = np.array([110.0, 120.0, 111.0, 121.0])


def main():
    if len(sys.argv) < 2:
        print("usage: check_crop_reference.py <dir>", file=sys.stderr)
        sys.exit(2)
    d = sys.argv[1]
    orig_path = os.path.join(d, "crop_orig_att.nrrd")
    crop_path = os.path.join(d, "crop_out_att.nrrd")
    errors = []

    # --- read original ---
    orig_data, orig_hdr = nrrd.read(orig_path)
    # pynrrd returns data with shape = NRRD sizes (first axis fastest in
    # file, but numpy array is C-order so last axis varies fastest).
    # For a 2x3x2 NRRD, orig_data shape should be (2,3,2) in numpy.
    if orig_data.shape != ORIG_SIZES:
        errors.append(f"orig sizes: {orig_data.shape} != {ORIG_SIZES}")
    # verify a few values from the formula
    for (x, y, z) in [(0, 0, 0), (1, 0, 0), (0, 1, 0), (1, 2, 1)]:
        expected = 100 * x + 10 * y + z
        actual = orig_data[x, y, z]
        if actual != expected:
            errors.append(f"orig[{x},{y},{z}]={actual} != {expected}")

    # --- read crop output ---
    crop_data, crop_hdr = nrrd.read(crop_path)
    if crop_data.shape != CROP_SIZES:
        errors.append(f"crop sizes: {crop_data.shape} != {CROP_SIZES}")

    # values: numpy shape (1,2,2), C-order -> crop_data[0, y', z']
    for (y2, z2) in [(0, 0), (1, 0), (0, 1), (1, 1)]:
        # linear order in file: x'=0 always, then y', then z'
        # file linear idx = y' + 2*z'  (since sizes[0]=1)
        linear_idx = y2 + 2 * z2
        expected = EXPECTED_CROP_VALUES[linear_idx]
        actual = crop_data[0, y2, z2]
        if actual != expected:
            errors.append(
                f"crop[0,{y2},{z2}]={actual} != {expected} (linear {linear_idx})"
            )

    # --- space fields (actual value comparison, not just existence) ---
    # crop preserves all per-axis fields — compare against original values
    crop_origin_raw = crop_hdr.get("space origin")
    if crop_origin_raw is None:
        errors.append("crop missing 'space origin' field")
    else:
        if hasattr(crop_origin_raw, "tolist"):
            crop_origin = tuple(float(v) for v in crop_origin_raw.tolist())
        elif isinstance(crop_origin_raw, str):
            crop_origin = tuple(
                float(v) for v in crop_origin_raw.strip("()").split(",")
            )
        else:
            crop_origin = tuple(float(v) for v in crop_origin_raw)
        for i in range(3):
            if not safe_float_eq(crop_origin[i], EXPECTED_CROP_ORIGIN[i]):
                errors.append(
                    f"crop origin[{i}]={crop_origin[i]} != {EXPECTED_CROP_ORIGIN[i]}"
                )

    # independent space origin check via coordinate relation
    manual_origin = tuple(
        ORIG_ORIGIN[c] + START[0] * DIRECTIONS[0][c] + START[1] * DIRECTIONS[1][c]
        for c in range(3)
    )
    for i in range(3):
        if not safe_float_eq(manual_origin[i], EXPECTED_CROP_ORIGIN[i]):
            errors.append(
                f"manual origin[{i}]={manual_origin[i]} != {EXPECTED_CROP_ORIGIN[i]}"
            )

    # space directions: compare ACTUAL VALUES (crop preserves all rows)
    crop_dirs_raw = crop_hdr.get("space directions")
    if crop_dirs_raw is None:
        errors.append("crop missing 'space directions' field")
    else:
        if hasattr(crop_dirs_raw, "tolist"):
            crop_dirs = [tuple(float(v) for v in row.tolist()) for row in crop_dirs_raw]
        elif isinstance(crop_dirs_raw, str):
            import re
            groups = re.findall(r"\(([^)]*)\)", crop_dirs_raw)
            crop_dirs = [
                tuple(float(v.strip()) for v in g.split(",")) for g in groups
            ]
        else:
            crop_dirs = [tuple(float(v) for v in row) for row in crop_dirs_raw]
        if len(crop_dirs) != 3:
            errors.append(f"crop dirs count={len(crop_dirs)} != 3")
        else:
            for row_idx, (actual_row, expected_row) in enumerate(
                zip(crop_dirs, DIRECTIONS)
            ):
                for i in range(3):
                    if not safe_float_eq(actual_row[i], expected_row[i]):
                        errors.append(
                            f"crop dirs[{row_idx}][{i}]={actual_row[i]} != {expected_row[i]}"
                        )

    # labels: compare ACTUAL VALUES (crop preserves all)
    crop_labels_raw = crop_hdr.get("labels")
    if crop_labels_raw is None:
        errors.append("crop missing 'labels' field")
    else:
        if hasattr(crop_labels_raw, "tolist"):
            crop_labels = tuple(str(v) for v in crop_labels_raw.tolist())
        elif isinstance(crop_labels_raw, str):
            import re
            parts = re.findall(r'"([^"]*)"', crop_labels_raw)
            crop_labels = tuple(parts) if parts else tuple(crop_labels_raw.split())
        else:
            crop_labels = tuple(str(v) for v in crop_labels_raw)
        expected_labels = ("x", "y", "z")
        if crop_labels != expected_labels:
            errors.append(f"crop labels={crop_labels} != {expected_labels}")

    # space units: compare ACTUAL VALUES (crop preserves all)
    crop_units_raw = crop_hdr.get("space units")
    if crop_units_raw is None:
        errors.append("crop missing 'space units' field")
    else:
        if hasattr(crop_units_raw, "tolist"):
            crop_units = tuple(str(v) for v in crop_units_raw.tolist())
        elif isinstance(crop_units_raw, str):
            import re
            parts = re.findall(r'"([^"]*)"', crop_units_raw)
            crop_units = tuple(parts) if parts else tuple(crop_units_raw.split())
        else:
            crop_units = tuple(str(v) for v in crop_units_raw)
        expected_units = ("mm", "mm", "mm")
        if crop_units != expected_units:
            errors.append(f"crop units={crop_units} != {expected_units}")

    # --- report ---
    if errors:
        for e in errors:
            print(f"FAIL {e}", file=sys.stderr)
        print(f"check_crop_reference: FAIL ({len(errors)} mismatches)")
        sys.exit(1)
    print("OK crop_orig: sizes + values match formula")
    print("OK crop_out:  sizes + values match hand-computed expectations")
    print("OK crop_out:  space origin matches coordinate relation")
    print("OK crop_out:  directions/labels/units values match originals")
    print(f"check_crop_reference: PASS  ({FORMULA})")
    sys.exit(0)


if __name__ == "__main__":
    main()
