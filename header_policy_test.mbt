///| Header policy negative tests (2026-11-08 审核必修项):
///| 1) magic 整行严格比对 —— v1 只支持 NRRD0005；未知版本/后缀/垃圾行拒绝；
///| 2) 标准字段唯一性 —— 每个 `field: desc` 行至多出现一次（大小写/空格/
///|    别名归一后判定，内容相同也拒绝）；
///| 3) key:=value 自定义键规则不同 —— 重复允许（规范 §1.2 后值覆盖），
///|    不适用标准字段唯一性规则。
///| 规范依据：https://teem.sourceforge.net/nrrd/format.html §1.1、§1.2。

///| Assert parse_header raises with a message containing `needle`.
fn hp_expect_fail(text : String, needle : String, label : String) -> Unit raise {
  let mut msg = ""
  try {
    let _unused = @moon-nrrd.parse_header(text)
  } catch {
    @moon-nrrd.NrrdError(m) => msg = m
  }
  assert_true(msg.contains(needle), msg="\{label}: want error ~ '\{needle}', got '\{msg}'")
}

// ---------------------------------------------------------------------------
// 1) magic 整行严格比对
// ---------------------------------------------------------------------------

test "magic: NRRDgarbage is rejected (audit-badmagic case)" {
  // garbage first line (the audit sample's shape)
  hp_expect_fail(
    "NRRDgarbage\ntype: int16\ndimension: 1\nsizes: 1\nencoding: ascii\n",
    "unsupported NRRD magic",
    "NRRDgarbage first line",
  )
}

test "magic: unknown versions and suffix junk are rejected" {
  hp_expect_fail(
    "NRRD0004\ntype: int16\ndimension: 1\nsizes: 1\nencoding: ascii\n",
    "unsupported NRRD magic",
    "NRRD0004 version",
  )
  hp_expect_fail(
    "NRRD0001\ntype: int16\ndimension: 1\nsizes: 1\nencoding: ascii\n",
    "unsupported NRRD magic",
    "NRRD0001 version",
  )
  hp_expect_fail(
    "NRRD00.01\ntype: int16\ndimension: 1\nsizes: 1\nencoding: ascii\n",
    "unsupported NRRD magic",
    "historical NRRD00.01",
  )
  hp_expect_fail(
    "NRRD0005x\ntype: int16\ndimension: 1\nsizes: 1\nencoding: ascii\n",
    "unsupported NRRD magic",
    "suffix junk NRRD0005x",
  )
  hp_expect_fail(
    "NRRD0005 extra\ntype: int16\ndimension: 1\nsizes: 1\nencoding: ascii\n",
    "unsupported NRRD magic",
    "trailing junk on magic line",
  )
}

test "magic: non-magic first lines are rejected" {
  hp_expect_fail(
    "nrrd0005\ntype: int16\ndimension: 1\nsizes: 1\nencoding: ascii\n",
    "invalid NRRD magic",
    "lowercase magic",
  )
  hp_expect_fail(
    "\ntype: int16\ndimension: 1\nsizes: 1\nencoding: ascii\n",
    "invalid NRRD magic",
    "empty first line",
  )
  hp_expect_fail(
    "NRRD5\ntype: int16\ndimension: 1\nsizes: 1\nencoding: ascii\n",
    "unsupported NRRD magic",
    "short version junk",
  )
}

test "magic: exact NRRD0005 still parses" {
  let h = @moon-nrrd.parse_header(
    "NRRD0005\ntype: int16\ndimension: 1\nsizes: 1\nencoding: ascii\n",
  )
  assert_true(h.type_name == "int16", msg="valid magic parses")
}

// ---------------------------------------------------------------------------
// 2) 标准字段唯一性（含大小写/别名同义重复；内容相同也拒绝）
// ---------------------------------------------------------------------------

test "duplicate standard fields are rejected (type/dimension/sizes/encoding)" {
  hp_expect_fail(
    "NRRD0005\ntype: int16\ntype: int16\ndimension: 1\nsizes: 1\nencoding: ascii\n",
    "duplicate field 'type'",
    "type twice (identical)",
  )
  hp_expect_fail(
    "NRRD0005\ntype: int16\ndimension: 1\ndimension: 1\nsizes: 1\nencoding: ascii\n",
    "duplicate field 'dimension'",
    "dimension twice",
  )
  hp_expect_fail(
    "NRRD0005\ntype: int16\ndimension: 1\nsizes: 1\nencoding: ascii\nsizes: 1\n",
    "duplicate field 'sizes'",
    "sizes twice (audit-duplicate case, identical content)",
  )
  hp_expect_fail(
    "NRRD0005\ntype: int16\ndimension: 1\nsizes: 1\nencoding: ascii\nencoding: raw\n",
    "duplicate field 'encoding'",
    "encoding twice (different content)",
  )
}

test "duplicate field detection is case-insensitive and alias-folded" {
  hp_expect_fail(
    "NRRD0005\ntype: int16\ndimension: 1\nSizes: 1\nSIZES: 1\nencoding: ascii\n",
    "duplicate field 'sizes'",
    "Sizes: + SIZES: (case fold)",
  )
  hp_expect_fail(
    "NRRD0005\ntype: int16\ndimension: 1\nsizes: 1\nencoding: ascii\n" +
    "data file: a.raw\ndatafile: a.raw\n",
    "duplicate field 'datafile'",
    "data file + datafile (alias)",
  )
  hp_expect_fail(
    "NRRD0005\ntype: int16\ndimension: 1\nsizes: 1\nencoding: ascii\n" +
    "line skip: 0\nlineskip: 0\n",
    "duplicate field 'lineskip'",
    "line skip + lineskip (alias)",
  )
  hp_expect_fail(
    "NRRD0005\ntype: int16\ndimension: 1\nsizes: 1\nencoding: ascii\n" +
    "space dimension: 3\nspacedimension: 3\n",
    "duplicate field 'spacedimension'",
    "space dimension + spacedimension (alias)",
  )
  hp_expect_fail(
    "NRRD0005\ntype: int16\ndimension: 1\nsizes: 1\nencoding: ascii\n" +
    "centers: cell\ncenterings: cell\n",
    "duplicate field 'centerings'",
    "centers + centerings (named alias pair)",
  )
}

test "unknown field identifiers are also unique field specs" {
  // 规范 §1.2 的唯一性针对任何 field specification；unknown 字段虽被忽略值，
  // 但标识符重复仍拒绝（与 key:=value 自定义键规则区分）。
  hp_expect_fail(
    "NRRD0005\ntype: int16\ndimension: 1\nsizes: 1\nencoding: ascii\nfoo: 1\nfoo: 2\n",
    "duplicate field 'foo'",
    "unknown plain field twice",
  )
}

// ---------------------------------------------------------------------------
// 3) key:=value 自定义键：重复允许（后值覆盖），不适用标准字段规则
// ---------------------------------------------------------------------------

test "key:=value custom keys may repeat (standard uniqueness does not apply)" {
  let h = @moon-nrrd.parse_header(
    "NRRD0005\ntype: int16\ndimension: 1\nsizes: 1\nencoding: ascii\n" +
    "foo:=1\nfoo:=2\nbar:=x\n",
  )
  assert_true(h.type_name == "int16", msg="repeated key:=value must parse")
}

test "key:=value does not collide with standard field names" {
  // "sizes:=..." 是自定义键（:= 形式），不是 sizes 字段规范；重复不触发
  // 标准字段唯一性，也不覆盖真正的 sizes 字段。
  let h = @moon-nrrd.parse_header(
    "NRRD0005\ntype: int16\ndimension: 1\nsizes: 1\nencoding: ascii\n" +
    "sizes:=a\nsizes:=b\n",
  )
  assert_true(h.sizes.length() == 1 && h.sizes[0] == 1, msg="sizes field intact")
}
