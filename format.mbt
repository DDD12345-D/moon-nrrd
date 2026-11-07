///| Canonical text formatting for the probe output.
///| The output format is pinned to the pynrrd reference dump
///| (nrrd-research/logs/pynrrd-reads.txt) so the two can be diffed.
///| Contract: nan / +inf / -inf / signed zero preserved; integral
///| values with plain-decimal toString get exactly one ".0"
///| (e.g. 1000.0); everything else is the shortest round-trip
///| string. Outside the fixture magnitude range (>= 1e16 integral,
///| < 1e-5) Python repr and JS toString disagree on notation —
///| cross-check those numerically (see check_semantic.py), not
///| by text diff.

///| Print a float-typed value: "nan" / "+inf" / "-inf" / "1000.0" / "1.5".
pub fn format_float(d : Double) -> String {
  if d.is_nan() {
    "nan"
  } else if d.is_pos_inf() {
    "+inf"
  } else if d.is_neg_inf() {
    "-inf"
  } else if d == 0.0 {
    // preserve the sign of zero (matches f"{-0.0:.1f}" == "-0.0")
    if is_neg_zero(d) {
      "-0.0"
    } else {
      "0.0"
    }
  } else if d == d.round() {
    // integral: always one decimal, e.g. 1000.0 (matches reference dump)
    let s = normalize_numeric_string(d.to_string())
    if is_plain_int_string(s) {
      "\{s}.0"
    } else {
      s
    }
  } else {
    normalize_numeric_string(d.to_string())
  }
}

///| IEEE-754 signed zero: both zeros compare equal to 0.0, so the
///| only portable discriminator is the sign bit (via binary32).
fn is_neg_zero(d : Double) -> Bool {
  d == 0.0 && Float::reinterpret_as_int(Float::from_double(d)) < 0
}

///| True for "-123" / "456" — no dot, no exponent marker.
fn is_plain_int_string(s : String) -> Bool {
  if s.is_empty() {
    return false
  }
  let mut i = 0
  if s.get_char(0) == Some('-') {
    i = 1
  }
  if i >= s.length() {
    return false
  }
  while i < s.length() {
    let c = s.get_char(i).unwrap()
    if c < '0' || c > '9' {
      return false
    }
    i = i + 1
  }
  true
}

///| Print an integer-typed value without decimal point ("1000").
pub fn format_int_value(d : Double) -> String {
  if d.is_nan() || d.is_inf() {
    "nan" // integers never hold these; defensive
  } else {
    let s = normalize_numeric_string(d.to_string())
    if s.contains(".") {
      // e.g. "1000.0" from an unusual to_string; keep digits before '.'
      let mut i = 0
      let out = StringBuilder()
      while i < s.length() {
        let c = s.get_char(i).unwrap()
        if c == '.' {
          i = s.length()
        } else {
          out.write_char(c)
          i = i + 1
        }
      }
      out.to_string()
    } else {
      s
    }
  }
}

///| Normalize a Double::to_string result: handle "1000." and "1e+03"-style
///| scientific output for the modest magnitudes used by the probe fixtures.
fn normalize_numeric_string(s : String) -> String {
  // strip a single trailing "." ("1000." -> "1000")
  if s.length() > 0 && s.get_char(s.length() - 1) == Some('.') {
    s[: s.length() - 1].to_owned()
  } else {
    s
  }
}

///|
pub fn format_double_list(ds : Array[Double]) -> String {
  let out = StringBuilder()
  let mut first = true
  for d in ds {
    if !first {
      out.write_string(" ")
    }
    out.write_string(format_float(d))
    first = false
  }
  out.to_string()
}

///| `space directions` rows joined with " | "; `none` for non-spatial axes.
pub fn format_directions(rows : Array[Array[Double]?]) -> String {
  let out = StringBuilder()
  let mut first = true
  for row in rows {
    if !first {
      out.write_string(" | ")
    }
    match row {
      Some(v) => out.write_string(format_double_list(v))
      None => out.write_string("none")
    }
    first = false
  }
  out.to_string()
}

///|
pub fn format_string_list(ss : Array[String]) -> String {
  let out = StringBuilder()
  let mut first = true
  for s in ss {
    if !first {
      out.write_string(" ")
    }
    out.write_string(s)
    first = false
  }
  out.to_string()
}

///|
pub fn format_opt(v : String?, none_marker~ : String = "<none>") -> String {
  match v {
    Some(s) => s
    None => none_marker
  }
}
