///| Format-contract tests: output strings are pinned against the
///| pynrrd reference dump formatter (see nrrd-research/pynrrd_reference.py).

///| Special values and signed zero.
test "format_float prints specials and signed zero" {
  assert_true(@moon-nrrd.format_float(0.0 / 0.0) == "nan", msg="nan")
  assert_true(@moon-nrrd.format_float(1.0 / 0.0) == "+inf", msg="+inf")
  assert_true(@moon-nrrd.format_float(-1.0 / 0.0) == "-inf", msg="-inf")
  // -0.0 must not collapse to 0.0
  let neg_zero = -1.0 * 0.0
  assert_true(@moon-nrrd.format_float(neg_zero) == "-0.0", msg="negative zero")
  assert_true(@moon-nrrd.format_float(0.0) == "0.0", msg="positive zero")
}

///| Integral values get exactly one decimal; strings that are already
///| in exponent form must NOT get ".0" glued on ("1e+21", not "1e+21.0").
test "format_float integral and exponent shapes" {
  assert_true(@moon-nrrd.format_float(1000.0) == "1000.0", msg="integral")
  assert_true(@moon-nrrd.format_float(-3.0) == "-3.0", msg="negative integral")
  assert_true(@moon-nrrd.format_float(1.5) == "1.5", msg="fractional")
  let big = 1.0e21
  let s = @moon-nrrd.format_float(big)
  assert_true(!s.has_suffix(".0"), msg="exponent form must not gain .0: \{s}")
  assert_true(s.contains("e"), msg="exponent form kept: \{s}")
}

///| Integer-typed values print without a decimal point.
test "format_int_value prints integers plainly" {
  assert_true(@moon-nrrd.format_int_value(1000.0) == "1000", msg="int style")
  assert_true(@moon-nrrd.format_int_value(-32768.0) == "-32768", msg="int min")
  assert_true(@moon-nrrd.format_int_value(0.0) == "0", msg="zero")
}
