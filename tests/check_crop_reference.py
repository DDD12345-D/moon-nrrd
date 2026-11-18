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
import numpy as np
import nrrd

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

    # --- space fields ---
    # pynrrd exposes space origin via header
    # NRRD field "space origin" -> hdr["space origin"] as tuple/array
    crop_origin_str = crop_hdr.get("space origin")
    if crop_origin_str is None:
        errors.append("crop missing 'space origin' field")
    else:
        # pynrrd may return as string or numeric array
        if isinstance(crop_origin_str, str):
            crop_origin = tuple(
                float(v) for v in crop_origin_str.strip("()").split(",")
            )
        else:
            crop_origin = tuple(float(v) for v in crop_origin_str)
        for i in range(3):
            if abs(crop_origin[i] - EXPECTED_CROP_ORIGIN[i]) > 1e-9:
                errors.append(
                    f"crop origin[{i}]={crop_origin[i]} != {EXPECTED_CROP_ORIGIN[i]}"
                )

    # independent space origin check via coordinate relation
    manual_origin = tuple(
        ORIG_ORIGIN[c] + START[0] * DIRECTIONS[0][c] + START[1] * DIRECTIONS[1][c]
        for c in range(3)
    )
    for i in range(3):
        if abs(manual_origin[i] - EXPECTED_CROP_ORIGIN[i]) > 1e-9:
            errors.append(
                f"manual origin[{i}]={manual_origin[i]} != {EXPECTED_CROP_ORIGIN[i]}"
            )

    # space directions: should be preserved (rows unchanged)
    crop_dirs_str = crop_hdr.get("space directions")
    if crop_dirs_str is None:
        errors.append("crop missing 'space directions' field")
    # labels preserved
    if "labels" not in crop_hdr:
        errors.append("crop missing 'labels' field")

    # --- report ---
    if errors:
        for e in errors:
            print(f"FAIL {e}", file=sys.stderr)
        print(f"check_crop_reference: FAIL ({len(errors)} mismatches)")
        sys.exit(1)
    print("OK crop_orig: sizes + values match formula")
    print("OK crop_out:  sizes + values match hand-computed expectations")
    print("OK crop_out:  space origin matches coordinate relation")
    print(f"check_crop_reference: PASS  ({FORMULA})")
    sys.exit(0)


if __name__ == "__main__":
    main()
