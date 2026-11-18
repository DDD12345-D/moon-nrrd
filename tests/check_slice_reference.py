#!/usr/bin/env python
"""Slice external read-back check (pynrrd).

Reads slice_orig_att.nrrd, slice_ax0_att.nrrd, slice_ax1_att.nrrd
written by cmd/slice-probe.  Verifies:
  - real values against formula value(x,y,z)=100*x+10*y+z
  - sizes (including dimension reduction)
  - space origin via coordinate relation origin'=origin+index*direction[axis]
  - space directions ACTUAL VALUES (not just existence)
  - labels ACTUAL VALUES
  - space units ACTUAL VALUES

Usage: python tests/check_slice_reference.py <dir>
Exit: 0 = all pass, 1 = mismatch, 2 = usage.
"""
import sys
import os
import numpy as np
import nrrd

FORMULA = "value(x,y,z) = 100*x + 10*y + z"
ORIG_SIZES = (3, 4, 5)
ORIG_ORIGIN = (1.5, -2.0, 3.25)
ORIG_DIRS = ((1.5, 0.5, 0.0), (0.0, 2.0, -0.5), (0.25, 0.0, 2.5))
ORIG_LABELS = ("x", "y", "z")
ORIG_UNITS = ("mm", "mm", "mm")


def parse_nrrd_vector(s):
    """Parse NRRD vector field like '(1.5,0.5,0.0)' or '(1.5, 0.5, 0.0)'."""
    s = s.strip()
    if s.startswith("(") and s.endswith(")"):
        s = s[1:-1]
    return tuple(float(v.strip()) for v in s.split(","))


def get_nrrd_dirs(hdr):
    """Return space directions as tuple of tuples of floats."""
    val = hdr.get("space directions")
    if val is None:
        return None
    if hasattr(val, "tolist"):  # numpy ndarray
        val = val.tolist()
    if isinstance(val, (list, tuple)):
        out = []
        for row in val:
            if hasattr(row, "tolist"):
                row = row.tolist()
            if isinstance(row, (list, tuple)):
                out.append(tuple(float(v) for v in row))
            else:
                out.append((float(row),))
        return tuple(out)
    return val


def get_nrrd_origin(hdr):
    """Return space origin as tuple of floats."""
    val = hdr.get("space origin")
    if val is None:
        return None
    if hasattr(val, "tolist"):
        val = val.tolist()
    if isinstance(val, (list, tuple)):
        return tuple(float(v) for v in val)
    return val


def get_nrrd_str_list(hdr, key):
    """Return a list-of-strings header field as tuple of strings."""
    val = hdr.get(key)
    if val is None:
        return None
    if hasattr(val, "tolist"):
        val = val.tolist()
    if isinstance(val, (list, tuple)):
        return tuple(str(v) for v in val)
    if isinstance(val, str):
        import re
        parts = re.findall(r'"([^"]*)"', val)
        if parts:
            return tuple(parts)
        return tuple(val.split())
    return val


def check_values_3d(data, name, errors):
    """Verify data[x,y,z] = 100*x + 10*y + z for 3D array."""
    for x in range(3):
        for y in range(4):
            for z in range(5):
                expected = 100 * x + 10 * y + z
                actual = data[x, y, z]
                if actual != expected:
                    errors.append(
                        f"{name}[{x},{y},{z}]={actual} != {expected}"
                    )


def main():
    if len(sys.argv) < 2:
        print("usage: check_slice_reference.py <dir>", file=sys.stderr)
        sys.exit(2)
    d = sys.argv[1]
    errors = []

    # --- read original ---
    orig_path = os.path.join(d, "slice_orig_att.nrrd")
    orig_data, orig_hdr = nrrd.read(orig_path)
    if orig_data.shape != ORIG_SIZES:
        errors.append(f"orig sizes: {orig_data.shape} != {ORIG_SIZES}")
    check_values_3d(orig_data, "orig", errors)

    # --- read slice ax=0 idx=1 ---
    ax0_path = os.path.join(d, "slice_ax0_att.nrrd")
    ax0_data, ax0_hdr = nrrd.read(ax0_path)
    # output sizes [4, 5] — numpy shape (4, 5)
    if ax0_data.shape != (4, 5):
        errors.append(f"ax0 sizes: {ax0_data.shape} != (4, 5)")
    # values: output(y,z) = input(1,y,z) = 100*1 + 10*y + z
    for y in range(4):
        for z in range(5):
            expected = 100 * 1 + 10 * y + z
            actual = ax0_data[y, z]
            if actual != expected:
                errors.append(f"ax0[{y},{z}]={actual} != {expected}")

    # origin' = origin + 1*dir[0] = (1.5+1.5, -2+0.5, 3.25+0) = (3, -1.5, 3.25)
    expected_ax0_origin = (
        ORIG_ORIGIN[0] + 1 * ORIG_DIRS[0][0],
        ORIG_ORIGIN[1] + 1 * ORIG_DIRS[0][1],
        ORIG_ORIGIN[2] + 1 * ORIG_DIRS[0][2],
    )
    ax0_origin = get_nrrd_origin(ax0_hdr)
    if ax0_origin is None:
        errors.append("ax0 missing 'space origin'")
    else:
        for i in range(3):
            if abs(ax0_origin[i] - expected_ax0_origin[i]) > 1e-9:
                errors.append(
                    f"ax0 origin[{i}]={ax0_origin[i]} != {expected_ax0_origin[i]}"
                )

    # directions: axis 0 removed → (dir[1], dir[2])
    ax0_dirs = get_nrrd_dirs(ax0_hdr)
    if ax0_dirs is None:
        errors.append("ax0 missing 'space directions'")
    else:
        if len(ax0_dirs) != 2:
            errors.append(f"ax0 dirs count={len(ax0_dirs)} != 2")
        else:
            for row_idx, (actual_row, expected_row) in enumerate(
                zip(ax0_dirs, (ORIG_DIRS[1], ORIG_DIRS[2]))
            ):
                for i in range(3):
                    if abs(actual_row[i] - expected_row[i]) > 1e-9:
                        errors.append(
                            f"ax0 dirs[{row_idx}][{i}]={actual_row[i]} != {expected_row[i]}"
                        )

    # labels: axis 0 removed → ("y", "z")
    ax0_labels = get_nrrd_str_list(ax0_hdr, "labels")
    if ax0_labels is None:
        errors.append("ax0 missing 'labels'")
    else:
        expected_labels = (ORIG_LABELS[1], ORIG_LABELS[2])
        if ax0_labels != expected_labels:
            errors.append(f"ax0 labels={ax0_labels} != {expected_labels}")

    # units: unchanged (world dimension) → ("mm","mm","mm")
    ax0_units = get_nrrd_str_list(ax0_hdr, "space units")
    if ax0_units is None:
        errors.append("ax0 missing 'space units'")
    else:
        if ax0_units != ORIG_UNITS:
            errors.append(f"ax0 units={ax0_units} != {ORIG_UNITS}")

    # --- read slice ax=1 idx=2 ---
    ax1_path = os.path.join(d, "slice_ax1_att.nrrd")
    ax1_data, ax1_hdr = nrrd.read(ax1_path)
    # output sizes [3, 5] — numpy shape (3, 5)
    if ax1_data.shape != (3, 5):
        errors.append(f"ax1 sizes: {ax1_data.shape} != (3, 5)")
    # values: output(x,z) = input(x,2,z) = 100*x + 10*2 + z
    for x in range(3):
        for z in range(5):
            expected = 100 * x + 10 * 2 + z
            actual = ax1_data[x, z]
            if actual != expected:
                errors.append(f"ax1[{x},{z}]={actual} != {expected}")

    # origin' = origin + 2*dir[1] = (1.5+0, -2+4, 3.25-1) = (1.5, 2, 2.25)
    expected_ax1_origin = (
        ORIG_ORIGIN[0] + 2 * ORIG_DIRS[1][0],
        ORIG_ORIGIN[1] + 2 * ORIG_DIRS[1][1],
        ORIG_ORIGIN[2] + 2 * ORIG_DIRS[1][2],
    )
    ax1_origin = get_nrrd_origin(ax1_hdr)
    if ax1_origin is None:
        errors.append("ax1 missing 'space origin'")
    else:
        for i in range(3):
            if abs(ax1_origin[i] - expected_ax1_origin[i]) > 1e-9:
                errors.append(
                    f"ax1 origin[{i}]={ax1_origin[i]} != {expected_ax1_origin[i]}"
                )

    # directions: axis 1 removed → (dir[0], dir[2])
    ax1_dirs = get_nrrd_dirs(ax1_hdr)
    if ax1_dirs is None:
        errors.append("ax1 missing 'space directions'")
    else:
        if len(ax1_dirs) != 2:
            errors.append(f"ax1 dirs count={len(ax1_dirs)} != 2")
        else:
            for row_idx, (actual_row, expected_row) in enumerate(
                zip(ax1_dirs, (ORIG_DIRS[0], ORIG_DIRS[2]))
            ):
                for i in range(3):
                    if abs(actual_row[i] - expected_row[i]) > 1e-9:
                        errors.append(
                            f"ax1 dirs[{row_idx}][{i}]={actual_row[i]} != {expected_row[i]}"
                        )

    # labels: axis 1 removed → ("x", "z")
    ax1_labels = get_nrrd_str_list(ax1_hdr, "labels")
    if ax1_labels is None:
        errors.append("ax1 missing 'labels'")
    else:
        expected_labels = (ORIG_LABELS[0], ORIG_LABELS[2])
        if ax1_labels != expected_labels:
            errors.append(f"ax1 labels={ax1_labels} != {expected_labels}")

    # units: unchanged → ("mm","mm","mm")
    ax1_units = get_nrrd_str_list(ax1_hdr, "space units")
    if ax1_units is None:
        errors.append("ax1 missing 'space units'")
    else:
        if ax1_units != ORIG_UNITS:
            errors.append(f"ax1 units={ax1_units} != {ORIG_UNITS}")

    # --- report ---
    if errors:
        for e in errors:
            print(f"FAIL {e}", file=sys.stderr)
        print(f"check_slice_reference: FAIL ({len(errors)} mismatches)")
        sys.exit(1)
    print("OK slice_orig:  sizes + values match formula")
    print("OK slice_ax0:   sizes + values + origin + directions + labels + units all match")
    print("OK slice_ax1:   sizes + values + origin + directions + labels + units all match")
    print(f"check_slice_reference: PASS  ({FORMULA})")
    sys.exit(0)


if __name__ == "__main__":
    main()
