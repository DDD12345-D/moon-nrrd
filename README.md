# moon-nrrd

MoonBit NRRD 读取库（读侧里程碑）。解析 NRRD 头部并解码数据负载，值以
`Double` 载体按文件线性序（sizes[0] = 最快轴）返回。

## 当前范围（v1 读侧）

- **类型**：int8 / uint8 / int16 / uint16 / int32 / uint32 / float / double
  （int64 / uint64 显式拒绝——超出 Double 值载体 2^53）。
- **编码**：raw（little/big endian）、ascii；attached / detached 数据文件。
  hex / gzip / bzip2 / block、LIST 式 data file、line/byte skip 显式拒绝。
- **头部**：magic 整行严格比对（仅 `NRRD0005`）；标准字段按别名/大小写
  归一后唯一（重复即拒，内容相同也拒）；`key:=value` 自定义键按规范允许
  重复（后值覆盖）。
- **未实现（不计入完成范围）**：写路径、crop/slice 携带数据、空间 API
  （world=origin+Σidx·dir 换算）；空间样例目前只覆盖头部解析。

## 已知口径边界

- **ASCII float32 范围契约**：解析路径为 decimal → binary64 → binary32
  两次舍入，不宣称对所有十进制字面值正确舍入；极端字面值与直接
  decimal → binary32 存在双重舍入差异（案例见
  `tests/fixtures/double_rounding_case.json`）。
- **ASCII token 长度上限 64 字节是实现限制**（流式解析的单 token 工作
  内存上限），不是 NRRD 格式非法判定；超长 token 被本读取器拒绝。
- **分配预算**（元素数 ≤ 2^24，可注入 `budget~`）是分配前的防御性下限，
  只约束元素个数，不是 OOM 不可能性证明——峰值内存可能超过 count×8
  字节。512 MiB 输入上限是宿主建议值，不是 wasm 安全证明。
- NaN 的 payload/signaling 位不保证穿越 Double 载体；有限值与 -0.0 在
  raw 路径位精确。

## 测试

仓库内离线可复现：`tests/`（样例生成器、golden、离线回归、pynrrd 外部
对照）与嵌入式测试（js/wasm 双后端）。用法见 `tests/README.md`。

## 许可

Apache-2.0（见 `LICENSE`）。外部对照依赖 pynrrd（MIT）/ numpy（BSD-3-Clause）
仅用于开发期校验，不参与运行时。
