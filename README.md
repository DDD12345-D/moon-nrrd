# moon-nrrd

MoonBit NRRD 读写库（G3 里程碑：读侧 + 写侧）。解析 NRRD 头部并解码数据
负载，也可对称地序列化头部与编码数据负载；值以 `Double` 载体按文件线性序
（sizes[0] = 最快轴）交换。核心层不做任何文件 IO——组装接口只返回字节/
字符串，文件名由宿主决定并与头声明保持一致。

## 当前范围（v1）

- **类型**：int8 / uint8 / int16 / uint16 / int32 / uint32 / float / double
  （int64 / uint64 显式拒绝——超出 Double 值载体 2^53）。
- **编码**：raw（little/big endian）、ascii；attached / detached 数据文件。
  hex / gzip / bzip2 / block、LIST 式 data file、line/byte skip 显式拒绝。
- **读侧**：magic 整行严格比对（仅 `NRRD0005`）；标准字段按别名/大小写
  归一后唯一（重复即拒，内容相同也拒）；`key:=value` 自定义键按规范允许
  重复（后值覆盖）。
- **写侧**：`format_header` / `encode_data` / `assemble_attached` /
  `assemble_detached`（无 IO，attached/detached 对称写出，只生成
  NRRD0005）；`format_keyval_line` 提供 key:=value 规范转义工具。
- **未实现（不计入完成范围）**：crop/slice 携带数据、空间 API
  （world=origin+Σidx·dir 换算）；空间样例目前只覆盖头部解析。

## 写侧值策略（G2 v2 §7.1）

- 整数类型：有限、整数值、在类型范围内，违例 raise 并指明值与类型，
  绝不静默截断；uint32 高半区（≥2^31）经 Int64 精确。
- float：存储值 = 最近 binary32（ties-to-even，`Float::from_double`；
  溢出饱和 ±inf，下溢保号到 ±0.0）；ASCII 特值判定作用于**缩窄后的
  存储值**（先缩窄再判零/无穷/NaN，负下溢如 -1.0e-50 输出 "-0.0"
  而非 "0"）；double 有限值与 -0.0 位精确。
- NaN：只承诺语义（nan==nan）；payload/signaling 位不承诺（js 后端已实测
  不稳定，见 tests/logs/write-reference-run-*.txt 的如实标注）。
- ASCII：整数走精确十进制 Int64 文本（不经有损浮点格式化）；float32 写
  **经读路径验证的最短往返串**（decimal → binary64 → binary32 两步解析
  逐 token 验证后输出）；double 写 binary64 最短往返串；特值 nan/inf/
  -inf/±0.0 单独语义测试。

## 写侧字符串策略（防注入，按规范转义）

- **v1 写契约：所有可写字符串仅 ASCII**（content / data file / labels /
  space units / space / kinds / key:=value 键与值）。非 ASCII 码点一律
  raise NrrdError 拒绝——绝不静默截断到低字节（U+010A 的低字节是 0x0A，
  截断会向头部注入换行/字段），补充平面字符的 UTF-16 遍历同样 raise
  而非 panic。
- `content` / `data file`：行内裸串；换行/回车/C0 控制符拒绝；首尾空白
  拒绝（读端会 trim，无法往返）。
- `labels` / `space units`：双引号定界，仅 `\"` 转义（规范 §1.6）；反斜杠
  **拒绝**（规范无反斜杠转义、pynrrd(shlex) 对 `\\` 折叠——跨实现无法
  安全往返）；换行/控制符拒绝。
- `kinds`：裸 token；token 内空白/引号/控制符拒绝。
- key:=value（`format_keyval_line`）：按规范转义 `\n` 与 `\\`；键禁 `:`、
  禁 `#` 开头、禁与标准字段名碰撞（防回放覆盖已知字段）。
- **unknown 字段与 key:=value 保留（往返回放）未实现**：NrrdHeader 只
  携带标准字段，format_header 不回放任何未经校验的字段——按 G2 §3.5
  明确标未支持。

## 已知口径边界

- **ASCII float32 范围契约**：解析路径为 decimal → binary64 → binary32
  两次舍入，不宣称对所有十进制字面值正确舍入；极端字面值与直接
  decimal → binary32 存在双重舍入差异（案例见
  `tests/fixtures/double_rounding_case.json`）。写侧输出的 float32 ASCII
  token 均已按读路径逐个验证往返，不受此差异影响。
- **ASCII token 长度上限 64 字节是读端实现限制**（流式解析的单 token
  工作内存上限），不是 NRRD 格式非法判定；写侧输出 token 均远短于上限。
- **分配预算**（元素数 ≤ 2^24，可注入 `budget~`）是分配前的防御性下限，
  只约束元素个数，不是 OOM 不可能性证明——峰值内存可能超过 count×8
  字节。512 MiB 输入上限是宿主建议值，不是 wasm 安全证明。
- **写侧只生成 NRRD0005**；detached 文件名由宿主指定，核心仅回写
  `data file` 声明，路径安全与"名实一致"是宿主责任。
- 读端 `labels` 解析按规范仅识别 `\"` 转义；pynrrd 用 POSIX shlex（会把
  `\\` 折叠）——含反斜杠的 labels 在两实现间可能不一致（写侧拒绝产生
  此类输出）。

## 测试

仓库内离线可复现：`tests/`（样例生成器、golden、离线回归、pynrrd 外部
对照、写端 48 格取证流水线）与嵌入式测试（js/wasm 双后端）。用法见
`tests/README.md`。

## 许可

Apache-2.0（见 `LICENSE`）。外部对照依赖 pynrrd（MIT）/ numpy（BSD-3-Clause）
仅用于开发期校验，不参与运行时。
