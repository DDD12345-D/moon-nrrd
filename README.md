# moon-nrrd

MoonBit NRRD 读写库。解析 NRRD0005 头部并解码数据负载，也可对称地
序列化头部与编码数据负载。≤32 位值以 `Double` 载体按文件线性序
（sizes[0] = 最快轴）交换；64 位整型走原生 `Int64`/`UInt64` 全整数
路径（不经 Double）。核心层不做任何文件 IO——组装接口只返回字节/
字符串，文件名由宿主决定并与头声明保持一致。

## 当前范围

- **类型**：int8 / uint8 / int16 / uint16 / int32 / uint32 / float / double
  经 `Double` 载体；int64 / uint64 经 `decode_int64` / `decode_uint64` /
  `encode_int64` / `encode_uint64`（raw LE/BE + ascii，2^53+1、INT64_MIN/
  MAX、UINT64_MAX 逐值往返位精确已验证）。
- **编码**：raw（little/big endian）、ascii；attached / detached / LIST
  多文件数据文件。hex / gzip / bzip2 / block、格式序列、line/byte skip
  显式拒绝（阶段 B 计划）。
- **LIST 多文件读取**：`data file: LIST [subdim]`——逐片校验（raw 按字节数
  / ascii 按 token 数）、分片间空格防粘连、缺片/长度/计数错误拒绝。
- **读侧**：magic 整行严格比对（仅 `NRRD0005`）；标准字段按别名/大小写
  归一后唯一（重复即拒）；`key:=value` 按规范允许重复（后值覆盖）。
- **写侧**：`format_header` / `encode_data` / `assemble_attached` /
  `assemble_detached`（无 IO，attached/detached 对称写出）；
  `format_keyval_line` 提供 key:=value 规范转义工具。
- **数据操作**：`crop_data`（保维裁剪）、`slice_data`（降维切片），均携带
  真实值子集、同步更新空间元数据（Double 载体；64 位数据的 crop/slice
  待做）。

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
  **经读路径验证的最短往返串**（候选串用读端同款直接舍入解析器
  f32_direct_bits 逐 token 验回位型后输出）；double 写 binary64 最短
  往返串；特值 nan/inf/-inf/±0.0 单独语义测试。

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

## 已验证范围与复现命令

使用已安装的 MoonBit 工具链，从仓库根目录运行：

```sh
# 案例一：LIST 分片重组（raw + ascii，12/12）
#   覆盖默认 subdim、显式 subdim、slabs、缺片、长度/计数错误、
#   分片尾无换行、总数正确但单片错配
moon test --target js list_test.mbt

# 案例二：int64/uint64 无损读写（20/20）
#   raw LE/BE + ascii；2^53+1、INT64_MIN、INT64_MAX、UINT64_MAX 逐值往返
moon test --target js int64_test.mbt
```

全量测试：`moon test --target js`（281/281）；`moon test --target wasm`（281/281）；
`moon check --deny-warn` 零告零错。

## 已知口径边界

- **ASCII float32 正确舍入契约**：解析路径为 **decimal → binary32 直接
  正确舍入**（nearest、ties-to-even，无 binary64 中间步；大整数定点
  舍入实现，单一最终舍入）。对 **≤64 字节的任意十进制 token 全称
  正确舍入**；原 decimal → binary64 → binary32 两步解析的双重舍入
  反例（`tests/fixtures/double_rounding_case.json` 中 token）现按直接
  舍入给出 0x3f800001，行为由此改变。独立精确参考（整数/有理构造）
  与边界电池见 `tests/reference_f32.py`、`tests/f32_tokens.txt`。
  >64 字节 token 超出契约范围，读端拒绝（见下条）。
- **ASCII token 长度上限 64 字节是读端实现限制**（流式解析的单 token
  工作内存上限），不是 NRRD 格式非法判定；写侧输出 token 均远短于上限。
- **分配预算**（元素数 ≤ 2^24，可注入 `budget~`）是分配前的防御性下限，
  只约束元素个数，不是 OOM 不可能性证明——峰值内存可能超过 count×8
  字节。512 MiB 输入上限是宿主建议值，不是 wasm 安全证明。
- **写侧只生成 NRRD0005**；detached 文件名由宿主指定，核心仅回写
  `data file` 声明，路径安全与"名实一致"是宿主责任。
- **64 位整型的 crop_data/slice_data 待做**：NrrdData 当前仅携带
  `Array[Double]`；64 位数据裁剪/切片需扩展载体（读写已验证无损）。
- **LIST 写出与格式序列读写待做**（阶段 B/C）。
- 读端 `labels` 解析按规范仅识别 `\"` 转义；pynrrd 用 POSIX shlex（会把
  `\\` 折叠）——含反斜杠的 labels 在两实现间可能不一致（写侧拒绝产生
  此类输出）。

## 数据裁剪（crop_data）

```moonbit
// 创建数据集：头 + 值（文件线性序，sizes[0] 最快）
let d = NrrdData::{ header: hdr, values: vals }
// 保维裁剪：start=(1,1,0), size=(1,2,2)
// 输出 sizes=(1,2,2)，origin 同步偏移
let result = crop_data(d, [1, 1, 0], [1, 2, 2])
// result.header.space_origin = 原 origin + Σ start[i]·dir[i]
// result.values = 原值子集（first-axis-fastest 线性序）
```

- 参数为 `start + size`（非半开区间），逐轴校验边界与溢出安全。
- 完整空间信息时 origin 同步偏移；非空间轴（direction=none）不偏移。
- 无空间信息可操作；部分空间信息在数据操作层明确拒绝。
- 输入不可变；输出预算在分配前检查。
- 完整示例：`cmd/crop-example/`。

## 数据切片（slice_data）

```moonbit
// 降维切片：固定 axis=0 的 index=1，去掉该数组轴
// 输入 3D → 输出 2D，其余轴保持 sizes[0] 最快
let result = slice_data(d, 0, 1)
// result.header.sizes = 去掉 axis 0 后的尺寸
// result.header.space_origin = 原 origin + 1·direction[0]
// result.values = 原值子集（剩余轴 first-axis-fastest 线性序）
```

- 固定一个轴的 index 并去掉该数组轴，保留其余轴相对顺序。
- 完整空间信息时 `origin' = origin + index·direction[axis]`；none 轴不偏移。
- 删除 sizes/labels/kinds/directions 对应轴项；space/space_dimension/space_units 不随数组轴删除。
- 1D 切成 0D 明确拒绝；无空间信息可操作；部分空间信息拒绝。
- 完整示例：`cmd/slice-probe/`（含 pynrrd 外部读回）。

## 测试

仓库内离线可复现：`tests/`（样例生成器、golden、离线回归、pynrrd 外部
对照、写端 48 格取证流水线）与嵌入式测试（js/wasm 双后端）。用法见
`tests/README.md`。

## 许可

Apache-2.0（见 `LICENSE`）。外部对照依赖 pynrrd（MIT）/ numpy（BSD-3-Clause）
仅用于开发期校验，不参与运行时。
