# moon-nrrd 测试与样例（G3 读侧 + 写侧）

本目录是里程碑的**仓库内可离线执行**测试资产：自建样例、golden 期望、
生成器与回归/对照/写端取证脚本全部在此，不依赖 `nrrd-research/` 研究目录的任何私有文件。

## 目录

| 路径 | 作用 |
| --- | --- |
| `gen_fixtures.py` | 纯标准库生成器：48 格样例 + 2 个空间头补充样例 + golden + 48 格嵌入测试 |
| `fixtures/` | 生成的 NRRD 样例（attached `.nrrd` / detached `.nhdr`+数据文件） |
| `fixtures/expected.json` | golden 期望（生成器独立构造，非探针读取回填） |
| `fixtures/grid.json` | 48 格唯一组合清单（combo_id / sample / 备注） |
| `fixtures/double_rounding_case.json` | float32 十进制双重舍入边界案例（口径记录） |
| `run_read_regression.py` | 离线回归：探针 vs golden（数值语义级） |
| `check_reference.py` | 外部参照对照（读侧）：pynrrd vs golden / vs 探针 dump（两级判定） |
| `check_write_reference.py` | 外部参照对照（写侧）：我们写 → pynrrd 读，48 格逐格三路取证 |
| `logs/` | 外部对照运行日志（含版本与命令行，留档） |
| `out/write-ref/` | 写端取证生成的 48 格输出（可随时由 write-probe 重建，不入仓） |

生成的 `../grid_cases_test.mbt` 是 48 格 + 2 补充样例的嵌入式解码测试
（`moon test` js/wasm 双后端逐格断言），由 `gen_fixtures.py` 生成，勿手改。

## 48 格口径

唯一组合 = **类型(8) × 编码(raw-le/raw-be/ascii) × 附件(attached/detached)**，
combo_id 形如 `int16/raw-le/att`；样例 ID（文件名）单列，不重复计格。
`grid.json` 对单字节（int8/uint8）raw-le/raw-be 显式标注 **LE/BE 同义**
（数据字节与期望值相同，仅 endian 字段不同）——该 8 格为同义案例，仍逐格取证据。

## 复现命令（在 moon-nrrd/ 目录）

```sh
# 0) 达标工具链（zvm 冻结基线；MOON_BIN 指向 bin/moon.exe）
export MOON_HOME=<path-to>/zvm-research/toolchain/runtime
export MOON_BIN="$MOON_HOME/bin/moon.exe"

# 1) 重新生成样例 + golden + 嵌入测试（幂等）
python tests/gen_fixtures.py

# 2) 单元/嵌入测试（js + wasm 双后端）
"$MOON_BIN" test --target js
"$MOON_BIN" test --target wasm

# 3) 离线回归（探针 vs golden；无第三方依赖）
python tests/run_read_regression.py

# 4) 外部参照对照（需要 pip install pynrrd==1.1.3 numpy；最终里程碑必跑并留档）
python tests/check_reference.py

# 5) 写端 48 格外部对照（我们写 -> pynrrd 读；含字节级 golden 与 BE 字节序证明）
python tests/check_write_reference.py
```

判定口径两级分开报告：
- **格式一致**：探针 dump 与 pynrrd dump 归一化换行后逐行相同；
- **数值语义一致**：nan==nan（语义）、±inf 分符号、零分正负（-0.0 ≠ 0.0）、
  其余精确相等，无容差。NaN 的 payload/signaling 位**不在承诺范围**；
  有限值与 -0.0 在 raw 路径下位精确（binary64 载体）。

## 写端 48 格取证（check_write_reference.py）

与读侧 48 格是**两套独立证据链**（不复用读侧通过表）：`cmd/write-probe`
调用写端 API（assemble_attached / assemble_detached）生成全部 48 格，随后
每格三路独立取证：
1. **pynrrd 读取**：类型/尺寸/编码/大小端/content/数据值语义级比对；
2. **字节级 golden**：payload 与 Python `struct.pack` 独立期望逐字节相等
   （BE 真实字节序验证：期望按 big/little 显式打包，且多字节 BE 格断言
   BE 字节 ≠ LE 字节；单字节格显式标注 LE/BE 同义）；
3. **ASCII token 级**：写出的每个 token 按 Python 数值语义独立换算与
   期望值比对（有限值/负零往返、NaN 语义）。
另设一致性闸：与读侧 `expected.json` 的 value_hex 比对（期望规格一致，
防值表漂移；非读侧通过表复用）。NaN 格为**语义判定**（payload 不承诺，
js 后端实测不稳定，日志如实标注）。嵌入式补充：`write_roundtrip_test.mbt`
48 格自读往返（写→parse→decode）。

## 自建样例与许可来源说明

- `tests/fixtures/` 中全部样例由 `gen_fixtures.py` **独立构造**：合成数值
  （极值/次正规/负零/NaN/inf/uint32 高位等），无任何第三方影像、医疗或隐私数据。
- 数值期望由生成器按 IEEE-754 / 整型语义计算（raw：写入字节自洽解包；
  ascii：解码同款语义），**不从 MoonBit 探针读取结果回填**，避免自证。
- **pynrrd**（<https://github.com/mhe/pynrrd>，MIT License）仅用于开发期
  外部对照（`check_reference.py`），不参与运行时，也不参与离线回归。
- **numpy**（BSD-3-Clause）是 pynrrd 的运行依赖，仅随外部对照使用。
- NRRD 格式规范来源：<https://teem.sourceforge.net/nrrd/format.html>（规范文本，
  非代码）；本仓库代码许可见根目录 `LICENSE`（Apache-2.0）。

## 已知口径边界（不宣称的能力）

- `float`（binary32）ASCII 十进制解析走 **decimal → binary64 → binary32**，
  是**范围契约**而非全称正确舍入：该两次舍入路径与直接 decimal → binary32
  在极端十进制字面值上存在双重舍入差异（案例见
  `fixtures/double_rounding_case.json`）；不宣称所有十进制正确舍入。
- ASCII 数值 token 长度上限 **64 字节是实现限制**（流式解析的单 token
  工作内存上限），不是 NRRD 格式非法判定；超长 token 被本读取器拒绝
  并报错，不代表该文件在规范意义上非法。
- 分配预算（元素数 ≤ 2^24，可注入 `budget~`）是分配前的**防御性下限**，
  只约束元素个数，不是 OOM 不可能性证明——峰值内存可能超过
  count×8 字节（逐元素开销、中间数组、ASCII token 缓冲）；
  512 MiB 输入上限是宿主读取前的限制建议，**不是 wasm 安全证明**。
- 2 个空间头补充样例只覆盖**头部解析**（space/space directions 等字段
  的解析与校验）；空间 API（crop/slice 伴随数据、world 坐标换算
  world=origin+Σidx·dir）**尚未实现**，不得提前计入完成范围。
- int64/uint64/block 与 hex/gzip/bzip2 编码显式拒绝（不在 v1 范围）。
- 写侧只生成 **NRRD0005**；labels/space units 中的反斜杠**拒绝写出**
  （规范无 `\\` 转义、pynrrd shlex 会折叠 `\\`——跨实现无法安全往返）；
  content/data file 首尾空白与控制符拒绝。
- **unknown 字段与 key:=value 保留（往返回放）未实现**（G2 §3.5 标未支持）；
  `format_keyval_line` 仅提供规范转义工具，且拒绝与标准字段名碰撞的键。
