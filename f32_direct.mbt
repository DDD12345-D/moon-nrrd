///| Direct decimal → binary32 correct rounding (no binary64
///| intermediate).  Single rounding: each attempt rounds the
///| ORIGINAL decimal digits once onto the candidate 2^(e2-23) grid;
///| no chain of intermediate roundings is ever accumulated.
///|
///| Big unsigned integer utilities use Array[Int] with base 2^16
///| (limbs in [0, 65536)).  Every intermediate is Int-safe (task:
///| bounded integers must not overflow themselves):
///|   - bi_dec (x10):          65535*10+9       = 655359    < 2^31
///|   - bi_mul (multiplier<=5):65535*5+65535    = 393210    < 2^31
///|   - bi_div5 (rem*65536+):  4*65536+65535    = 327679    < 2^31
///|   - bi_lsh (limb<<(n%16)): 65535<<15        = 2147450880< 2^31
///|   - bi_add / bi_inc:       65535+65535+1    = 131071    < 2^31
///|   - bi_mul_big is the ONLY full-limb product (65535^2 +
///|     65535 + 65535 = 2^32-1 exceeds Int32), so it computes the
///|     product in Int64 and narrows back per limb: max 2^32-1
///|     < 2^63.  Base 2^16 therefore cannot overflow on any path.
///|
///| Resource bounds (derived, not assumed):
///|   Input contract: token <= 64 ASCII bytes, enforced in
///|   f32_direct_bits (longer tokens raise).  After normalization
///|   (leading/trailing zero stripping) nd <= 64 decimal digits,
///|   so N < 10^64 < 2^213.
///|   Step 1 (exact saturations on e_val = exp10 - nd, before any
///|   estimate):  e_val >= 5000 -> |value| >= 10^5000 -> +-inf;
///|   e_val <= -5000 -> |value| < 10^(64-5000) -> +-0.  Both hold
///|   for every N in range, so the heavy path only runs with
///|   |e_val| <= 4999 and u = nd-1+e_val with |u| <= 5062, hence
///|   raw_approx = u*33219 fits in Int32 (|raw| <= 1.68e8).
///|   Step 2 (proven estimate error): e2_guess = floor(u*3.3219)
///|   satisfies true_e2 - 4 <= e2_guess <= true_e2 + 1 where
///|   true_e2 = floor(log2|value|) (derivation in the 浮点复验
///|   report: log2(10) = 3.321928..., the 3.3219 truncation shifts
///|   u*log2(10) by < 0.143, and the true value lies in
///|   [u*log2(10), (u+1)*log2(10))).
///|   Step 3 (exact saturations from that error bound): e2_guess
///|   >= 129 -> true_e2 >= 128 -> +-inf;  e2_guess <= -155 ->
///|   true_e2 <= -151 -> |value| < 2^-150 -> +-0.  These are
///|   proven bounds, not heuristic thresholds: nothing that could
///|   round to a finite/zero result is ever discarded.
///|   Therefore the big-integer path only runs with
///|   e_val in [-110, 38], |p2| <= 225, 5^|e_val| < 2^256, and
///|   every intermediate < 2^(213+256+225) = 2^694 ~ 44 limbs.
///|   Even without step 3, step 2's +-5000 cap alone bounds
///|   intermediates by < 2^17000 ~ 1061 limbs (arrays grow; the
///|   Int64 product rule above still holds).  No fixed buffer is
///|   assumed.

// ===== Big integer utilities (base 2^16, little-endian) =====

///| Create big integer from non-negative decimal digit string.
fn bi_dec(s : String) -> Array[Int] {
  let a : Array[Int] = [0]
  let n = s.length()
  for i = 0; i < n; i = i + 1 {
    let d = char_at(s, i).to_int() - 48
    let mut carry = d
    for j = 0; j < a.length(); j = j + 1 {
      let prod = a[j] * 10 + carry
      a[j] = prod & 65535
      carry = prod >> 16
    }
    while carry > 0 {
      a.push(carry & 65535)
      carry = carry >> 16
    }
  }
  a
}

///| Multiply big integer by small positive integer (<= 5).
fn bi_mul(a : Array[Int], b : Int) -> Array[Int] {
  let n = a.length()
  let out = Array::make(n + 2, 0)
  let mut carry = 0
  for i = 0; i < n; i = i + 1 {
    let prod = a[i] * b + carry
    out[i] = prod & 65535
    carry = prod >> 16
  }
  let mut i = n
  while carry > 0 {
    out[i] = carry & 65535
    carry = carry >> 16
    i = i + 1
  }
  // trim leading zeros
  let mut len = i
  while len > 1 && out[len - 1] == 0 {
    len = len - 1
  }
  let result = Array::make(len, 0)
  for j = 0; j < len; j = j + 1 {
    result[j] = out[j]
  }
  result
}

///| Divide big integer by 5.  Returns (quotient, remainder).
fn bi_div5(a : Array[Int]) -> (Array[Int], Int) {
  let n = a.length()
  let q = Array::make(n, 0)
  let mut rem = 0
  for i = n - 1; i >= 0; i = i - 1 {
    let cur = rem * 65536 + a[i]
    q[i] = cur / 5
    rem = cur % 5
  }
  // trim leading zeros
  let mut len = n
  while len > 1 && q[len - 1] == 0 {
    len = len - 1
  }
  if len == n {
    (q, rem)
  } else {
    let q2 = Array::make(len, 0)
    for j = 0; j < len; j = j + 1 {
      q2[j] = q[j]
    }
    (q2, rem)
  }
}

///| Left shift by n bits (n >= 0).
fn bi_lsh(a : Array[Int], n : Int) -> Array[Int] {
  if n == 0 {
    return a.copy()
  }
  let words = n / 16
  let bits = n % 16
  let len = a.length()
  let out = Array::make(len + words + 2, 0)
  for i = 0; i < len; i = i + 1 {
    let v = a[i] << bits
    out[i + words] = out[i + words] | (v & 65535)
    out[i + words + 1] = out[i + words + 1] | ((v >> 16) & 65535)
  }
  // trim
  let mut tlen = len + words + 2
  while tlen > 1 && out[tlen - 1] == 0 {
    tlen = tlen - 1
  }
  let result = Array::make(tlen, 0)
  for j = 0; j < tlen; j = j + 1 {
    result[j] = out[j]
  }
  result
}

///| Compare two big integers.  Returns -1, 0, or 1.
fn bi_cmp(a : Array[Int], b : Array[Int]) -> Int {
  let la = bi_eff_len(a)
  let lb = bi_eff_len(b)
  if la > lb {
    return 1
  }
  if la < lb {
    return -1
  }
  for i = la - 1; i >= 0; i = i - 1 {
    if a[i] > b[i] {
      return 1
    }
    if a[i] < b[i] {
      return -1
    }
  }
  0
}

///| Effective length (strip leading zero limbs).
fn bi_eff_len(a : Array[Int]) -> Int {
  let mut len = a.length()
  while len > 1 && a[len - 1] == 0 {
    len = len - 1
  }
  len
}

///| Get least significant bit (0 or 1).
fn bi_lsb(a : Array[Int]) -> Int {
  if a.length() > 0 { a[0] & 1 } else { 0 }
}

///| Increment big integer by 1.
fn bi_inc(a : Array[Int]) -> Array[Int] {
  let len = a.length()
  let out = Array::make(len + 1, 0)
  let mut carry = 1
  for i = 0; i < len; i = i + 1 {
    let s = a[i] + carry
    out[i] = s & 65535
    carry = s >> 16
  }
  if carry > 0 {
    out[len] = carry
    out
  } else {
    let result = Array::make(len, 0)
    for j = 0; j < len; j = j + 1 {
      result[j] = out[j]
    }
    result
  }
}

///| Compute 5^k as big integer (k >= 0).
fn bi_pow5(k : Int) -> Array[Int] {
  let mut a : Array[Int] = [1]
  for i = 0; i < k; i = i + 1 {
    a = bi_mul(a, 5)
  }
  a
}

///| Get bit length of big integer (0 for zero).
fn bi_bitlen(a : Array[Int]) -> Int {
  let len = bi_eff_len(a)
  if len <= 1 && a[0] == 0 {
    return 0
  }
  let hi = a[len - 1]
  let mut bits = (len - 1) * 16
  let mut v = hi
  while v > 0 {
    bits = bits + 1
    v = v >> 1
  }
  bits
}

///| Right shift by n bits.  Returns (quotient, remainder_as_bigint).
fn bi_rsh(a : Array[Int], n : Int) -> (Array[Int], Array[Int]) {
  if n == 0 {
    return (a.copy(), [0])
  }
  let words = n / 16
  let bits = n % 16
  let len = bi_eff_len(a)
  // remainder = low n bits
  let rem_bits = Array::make(words + 2, 0)
  for i = 0; i < words && i < len; i = i + 1 {
    rem_bits[i] = a[i]
  }
  if bits > 0 && words < len {
    rem_bits[words] = a[words] & ((1 << bits) - 1)
  }
  // quotient = high part
  let qlen = if len > words { len - words } else { 1 }
  let q = Array::make(qlen, 0)
  for i = 0; i < qlen; i = i + 1 {
    let src = i + words
    if src < len {
      q[i] = a[src] >> bits
    }
    if bits > 0 && src + 1 < len {
      q[i] = q[i] | ((a[src + 1] << (16 - bits)) & 65535)
    }
  }
  // trim quotient
  let mut tlen = qlen
  while tlen > 1 && q[tlen - 1] == 0 {
    tlen = tlen - 1
  }
  let q2 = Array::make(tlen, 0)
  for j = 0; j < tlen; j = j + 1 {
    q2[j] = q[j]
  }
  // trim remainder
  let mut rlen = words + 2
  while rlen > 1 && rem_bits[rlen - 1] == 0 {
    rlen = rlen - 1
  }
  let r2 = Array::make(rlen, 0)
  for j = 0; j < rlen; j = j + 1 {
    r2[j] = rem_bits[j]
  }
  (q2, r2)
}

///| Multiply two big integers.  The inner product a[i]*b[j] can
///| reach 65535^2 = 2^32-131071 which overflows Int32, so the
///| running sum is computed in Int64 (max 2^32-1 < 2^63) and
///| narrowed back per limb.
fn bi_mul_big(a : Array[Int], b : Array[Int]) -> Array[Int] {
  let la = a.length()
  let lb = b.length()
  let out = Array::make(la + lb + 1, 0)
  for i = 0; i < la; i = i + 1 {
    let mut carry = 0L
    for j = 0; j < lb; j = j + 1 {
      let prod = out[i + j].to_int64() + a[i].to_int64() * b[j].to_int64() + carry
      out[i + j] = prod.land(65535L).to_int()
      carry = prod >> 16
    }
    let mut k = i + lb
    while carry != 0L {
      let s = out[k].to_int64() + carry
      out[k] = s.land(65535L).to_int()
      carry = s >> 16
      k = k + 1
    }
  }
  let mut len = la + lb + 1
  while len > 1 && out[len - 1] == 0 {
    len = len - 1
  }
  let result = Array::make(len, 0)
  for j = 0; j < len; j = j + 1 {
    result[j] = out[j]
  }
  result
}

///| Add two big integers.
fn bi_add(a : Array[Int], b : Array[Int]) -> Array[Int] {
  let la = a.length()
  let lb = b.length()
  let maxlen = if la > lb { la } else { lb }
  let out = Array::make(maxlen + 1, 0)
  let mut carry = 0
  for i = 0; i < maxlen; i = i + 1 {
    let av = if i < la { a[i] } else { 0 }
    let bv = if i < lb { b[i] } else { 0 }
    let s = av + bv + carry
    out[i] = s & 65535
    carry = s >> 16
  }
  if carry > 0 {
    out[maxlen] = carry
    out
  } else {
    let result = Array::make(maxlen, 0)
    for j = 0; j < maxlen; j = j + 1 {
      result[j] = out[j]
    }
    result
  }
}

// ===== Decimal token -> (neg, digits, exp10) =====

///| Parse ASCII decimal token to (neg, digits, exp10) where
///| value = +-digits x 10^(exp10 - digits.length()).
///| Accepts: [.digits]digits[.digits][eE[+-]digits], leading zeros,
///| trailing zeros.  Rejects: empty, multiple dots, non-numeric.
///| Exponent digits beyond 5 saturate to +-99999 (any such exponent
///| is far outside binary32 range and is mapped to +-inf/+-0 by the
///| exact e_val saturations in f32_direct_bits).
fn parse_f32_token(tok : String) -> (Bool, String, Int)? {
  let n = tok.length()
  let mut i = 0
  let mut neg = false
  if i < n && (char_at(tok, i) == '-' || char_at(tok, i) == '+') {
    neg = char_at(tok, i) == '-'
    i = i + 1
  }
  let int_start = i
  while i < n && char_at(tok, i).is_ascii_digit() {
    i = i + 1
  }
  let int_len = i - int_start
  let mut frac_start = i
  let mut frac_len = 0
  if i < n && char_at(tok, i) == '.' {
    i = i + 1
    frac_start = i
    while i < n && char_at(tok, i).is_ascii_digit() {
      i = i + 1
    }
    frac_len = i - frac_start
  }
  if int_len == 0 && frac_len == 0 {
    return None
  }
  let mut e_add = 0
  if i < n && (char_at(tok, i) == 'e' || char_at(tok, i) == 'E') {
    i = i + 1
    let mut e_neg = false
    if i < n && (char_at(tok, i) == '-' || char_at(tok, i) == '+') {
      e_neg = char_at(tok, i) == '-'
      i = i + 1
    }
    let e_start = i
    while i < n && char_at(tok, i).is_ascii_digit() {
      i = i + 1
    }
    if i == e_start {
      return None
    }
    if i - e_start > 5 {
      // >= 6 exponent digits: |e_add| >= 10^5, far beyond the
      // +-5000 saturation window.  Clamp so later Int arithmetic
      // cannot overflow.
      e_add = if e_neg { -99999 } else { 99999 }
    } else {
      let mut ev = 0
      let mut ek = e_start
      while ek < i {
        ev = ev * 10 + (char_at(tok, ek).to_int() - 48)
        ek = ek + 1
      }
      e_add = if e_neg { 0 - ev } else { ev }
    }
  }
  if i != n {
    return None
  }
  // build digit string: int part + frac part
  let sb = StringBuilder()
  let mut k = int_start
  while k < int_start + int_len {
    sb.write_char(char_at(tok, k))
    k = k + 1
  }
  k = frac_start
  while k < frac_start + frac_len {
    sb.write_char(char_at(tok, k))
    k = k + 1
  }
  let raw = sb.to_string()
  // strip leading zeros
  let mut lead = 0
  while lead < raw.length() && char_at(raw, lead) == '0' {
    lead = lead + 1
  }
  if lead == raw.length() {
    // zero
    return Some((neg, "0", 0))
  }
  // strip trailing zeros
  let mut trail = raw.length()
  while trail > lead && char_at(raw, trail - 1) == '0' {
    trail = trail - 1
  }
  let core = slice_str(raw, lead, trail)
  // value = 0.core x 10^exp10 = core x 10^(exp10 - core.length())
  let exp10 = int_len + e_add - lead
  Some((neg, core, exp10))
}

// ===== Direct decimal -> binary32 correct rounding =====

///| Compute binary32 bit pattern from decimal token via direct
///| correct rounding (nearest, ties-to-even).  No binary64
///| intermediate.  Returns the 32-bit pattern as Int
///| (sign|exponent|mantissa).
///| Contract: token <= 64 ASCII bytes (longer raises); within that
///| bound the conversion is correctly rounded for EVERY token.
fn f32_direct_bits(tok : String) -> Int raise NrrdError {
  if tok.length() > 64 {
    raise NrrdError(
      "ascii: float token exceeds 64-byte limit: \{tok.length()} bytes",
    )
  }
  match parse_f32_token(tok) {
    None => raise NrrdError("ascii: cannot parse float '\{tok}'")
    Some((neg, digits, exp10)) => {
      if digits == "0" {
        // signed zero (exponent is irrelevant for zero)
        return if neg { -2147483648 } else { 0 }
      }
      // value = +-digits x 10^(exp10 - digits.length()) = N x 10^E
      let nd = digits.length()
      let e_val = exp10 - nd
      // exact saturations before any estimate (header bounds):
      if e_val >= 5000 {
        return if neg { -8388608 } else { 2139095040 } // +-inf
      }
      if e_val <= -5000 {
        return if neg { -2147483648 } else { 0 } // +-0
      }
      // e2_guess = floor(log2(N) + E*log2(10)); error proven in
      // [-4, +1] of the true floor(log2|value|) (header bounds).
      let u = nd - 1 + e_val
      let raw_approx = u * 33219
      let e2_guess = if raw_approx < 0 && raw_approx % 10000 != 0 {
        raw_approx / 10000 - 1 // floor for negative (Int / truncates)
      } else {
        raw_approx / 10000
      }
      // exact saturations from the proven estimate error:
      if e2_guess >= 129 {
        // true exponent >= 128 -> every such value overflows
        return if neg { -8388608 } else { 2139095040 }
      }
      if e2_guess <= -155 {
        // true exponent <= -151 -> |value| < 2^-150 -> rounds to 0
        return if neg { -2147483648 } else { 0 }
      }
      f32_round_loop(neg, digits, e_val, e2_guess)
    }
  }
}

///| Unified rounding loop (normals, subnormals and the boundary in
///| one place).  At candidate exponent e2 the grid is 2^(e2-23);
///| e2 = -126 gives grid 2^-149, which is exactly the subnormal
///| grid, so the subnormal zone needs no separate rounding path.
///| Each attempt re-rounds the ORIGINAL digits once (never a chain).
fn f32_round_loop(
  neg : Bool,
  digits : String,
  e_val : Int,
  e2_start : Int,
) -> Int raise NrrdError {
  let mut e2 = if e2_start < -126 { -126 } else { e2_start }
  let mut attempt = 0
  while attempt < 8 {
    let ulp_exp = e2 - 23
    let p5 = e_val
    let p2 = e_val - ulp_exp
    let (q_floor, round_up, is_tie) = round_quotient(digits, p5, p2)
    // ties-to-even: carry only when not a tie, or tie and Q odd
    let mut q_final = q_floor
    let mut do_round_up = false
    if round_up {
      if is_tie {
        if bi_lsb(q_floor) == 1 {
          do_round_up = true
        }
      } else {
        do_round_up = true
      }
    }
    if do_round_up {
      q_final = bi_inc(q_floor)
    }
    let bl = bi_bitlen(q_final)
    if bl == 24 {
      // Q in [2^23, 2^24): the significand fits exponent e2.
      // At e2 = -126 this yields the smallest normals (mantissa
      // 0 = 2^-126); bits = sign | Q either way.
      if e2 >= 128 {
        // true exponent >= 128 -> overflow (e2 >= 128 encodes
        // the inf/NaN field; every such value is out of range)
        return if neg { -8388608 } else { 2139095040 }
      }
      let mant = extract_mantissa(q_final)
      return assemble_f32(neg, e2, mant)
    }
    if bl > 24 {
      // Q >= 2^24.  Exact carry Q == 2^24: the correctly rounded
      // value is exactly 2^(e2+1) — safe whether e2 is the true
      // exponent or one below it (see report proof), so return it
      // directly instead of re-rounding on a coarser grid.
      if bl == 25 && bi_cmp(q_final, bi_lsh([1], 24)) == 0 {
        if e2 + 1 >= 128 {
          // 2^128 and beyond overflow to infinity
          return if neg { -8388608 } else { 2139095040 }
        }
        return assemble_f32(neg, e2 + 1, 0)
      }
      // e2 too low (or carry bigger than 2^24): finer significand
      e2 = e2 + 1
    } else {
      // Q < 2^23.
      if e2 == -126 {
        // Subnormal zone: exponent field 0, mantissa = Q (< 2^23).
        // Q == 0 is signed underflow zero.
        return subnormal_bits(neg, q_final)
      }
      // e2 too high: coarser significand
      e2 = e2 - 1
    }
    attempt = attempt + 1
  }
  raise NrrdError("f32 rounding: cannot determine exponent for '\{digits}'")
}

///| Compute round(N x 5^p5 x 2^p2) where N = decimal digits string.
///| Returns (quotient_bigint, should_round_up, is_exact_tie).
///| The quotient is floor(q); round_up indicates whether to add 1.
fn round_quotient(
  digits : String,
  p5 : Int,
  p2 : Int,
) -> (Array[Int], Bool, Bool) {
  let n_val = bi_dec(digits)
  // q = N x 5^p5 x 2^p2
  // Separate into numerator and denominator
  // num = N x 5^max(0,p5) x 2^max(0,p2)
  // den = 5^max(0,-p5) x 2^max(0,-p2)
  let num5 = if p5 > 0 { p5 } else { 0 }
  let den5 = if p5 < 0 { -p5 } else { 0 }
  let num2 = if p2 > 0 { p2 } else { 0 }
  let den2 = if p2 < 0 { -p2 } else { 0 }
  // build numerator
  let mut num = n_val
  if num5 > 0 {
    let f5 = bi_pow5(num5)
    num = bi_mul_big(num, f5)
  }
  if num2 > 0 {
    num = bi_lsh(num, num2)
  }
  if den5 == 0 && den2 == 0 {
    // q is integer
    return (num, false, false)
  }
  // divide by denominator
  // step 1: divide by 5^den5 (repeated div by 5)
  let mut n_cur = num
  let mut r5_acc : Array[Int] = [0]
  let mut mult : Array[Int] = [1]
  for i = 0; i < den5; i = i + 1 {
    let (q5, r5) = bi_div5(n_cur)
    n_cur = q5
    // acc = acc + r5 * mult
    let addend = bi_mul(mult, r5)
    r5_acc = bi_add(r5_acc, addend)
    mult = bi_mul(mult, 5)
  }
  // step 2: divide by 2^den2 (bit shift)
  let (q2, r2) = bi_rsh(n_cur, den2)
  // remainder = r2 x 5^den5 + r5_acc
  let r2_scaled = if den5 > 0 {
    let d5 = bi_pow5(den5)
    bi_mul_big(r2, d5)
  } else {
    r2
  }
  let r_val = bi_add(r2_scaled, r5_acc)
  let d_val = if den5 > 0 {
    let d5 = bi_pow5(den5)
    if den2 > 0 { bi_lsh(d5, den2) } else { d5 }
  } else {
    bi_lsh([1], den2)
  }
  // compare 2R with D
  let two_r = bi_mul(r_val, 2)
  let cmp = bi_cmp(two_r, d_val)
  if cmp > 0 {
    (q2, true, false) // round up
  } else if cmp < 0 {
    (q2, false, false) // round down
  } else {
    (q2, true, true) // exact tie: caller checks even/odd of Q
  }
}

///| Extract mantissa (Q - 2^23) from 24-bit significand Q.
fn extract_mantissa(q : Array[Int]) -> Int {
  let q0 = if q.length() > 0 { q[0] & 65535 } else { 0 }
  let q1 = if q.length() > 1 { q[1] & 65535 } else { 0 }
  // bl == 24 -> Q < 2^24 -> q1 < 2^8: Int-safe
  let val = q0 + q1 * 65536
  val - 8388608
}

///| Subnormal encoding: exponent field 0, mantissa = Q (Q < 2^23).
///| Includes signed underflow zero (Q == 0).
fn subnormal_bits(neg : Bool, q : Array[Int]) -> Int {
  let q0 = if q.length() > 0 { q[0] & 65535 } else { 0 }
  let q1 = if q.length() > 1 { q[1] & 65535 } else { 0 }
  // Q < 2^23 -> q1 < 2^7: Int-safe
  let val = q0 + q1 * 65536
  if neg {
    -2147483648 | val // 0x80000000 | Q
  } else {
    val
  }
}

///| Assemble binary32 bits from sign, binary exponent e2, and
///| mantissa.  For normal: e2 in [-126, 127], mantissa in [0, 2^23).
///| Bits = sign | (e2+127) << 23 | mantissa
fn assemble_f32(neg : Bool, e2 : Int, mant : Int) -> Int {
  let biased_exp = e2 + 127
  let mut bits = 0
  if neg {
    bits = -2147483648 // 0x80000000
  }
  bits = bits | (biased_exp << 23)
  bits = bits | mant
  bits
}
