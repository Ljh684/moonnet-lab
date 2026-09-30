# 作为依赖使用：包的职责、入口与稳定面

命令行工具只是这套库的一个使用者。使用 Mooncakes 上的 `0.1.0` 版本时，在下游项目执行 `moon add Ljh684/moonnet-lab@0.1.0`，再在需要调用库的 `moon.pkg` 中导入 `Ljh684/moonnet-lab/src/sim`、`src/net`、`src/tcp` 等包。

`moon.mod` 声明了模块名称、版本、README、许可证、仓库、关键词与依赖。每次发布前可通过 `moon package --list` 检查打包文件，再运行 `moon publish --dry-run` 校验归档。

## 包的职责与入口

| 包 | 职责 | 入口 |
| --- | --- | --- |
| `src/sim` | 虚拟时钟、事件堆、冻结的随机源 | `Sim::new` / `run` / `step_until` / `schedule_at` / `now` / `start_trace` / `start_journal`、`Time` 的全部换算、`Rng::new` / `fork`、`mix64` / `fnv1a64` |
| `src/net` | 链路与队列：带宽、传播延迟、抖动、丢包、缓冲与队列管理 | `LinkSpec::new` / `with_loss` / `with_jitter`、`QueueSpec::packets` / `bytes` / `with_discipline`、`Link::new` / `send` / `summary`、`dropped` / `lost` / `mean_queue_packets` / `max_sojourn` |
| `src/tcp` | TCP 状态机、重传与恢复、可插拔拥塞控制 | `TcpConfig::new`、`LinkPair::new_with_cc`、`TcpConnection::connect` / `send` / `close` / `cwnd` / `retransmits` / `tlp_probes`、`Reno::new` / `cubic(mss)`、`CongestionControl` 接口 |
| `src/json` | 零依赖 JSON 读写，解析错误带字节偏移 | `parse`、`Json` 取值、`object_text` / `object_of_texts` |
| `src/lab` | 场景与报告：把实验写成数据 | `Scenario::from_json`、`run`、`run_with_trace`、`trace_svg_from_json`、`SweepField::parse` / `validate_range`、`compare`、`sweep`、`summarise`、`run_fairness`、`RunReport::to_json_text` / `to_lines`、`TraceRun.delivery_diagnostics` / `to_json_text` / `to_lines` |
| `cmd/moonnet` | 命令行前端 | `run` / `plot` / `compare` / `sweep` / `list` / `version` |

## 稳定面在哪里

- **有内部状态的对象只暴露方法**：`Sim`、`Rng`、`SplitMix64`、`Link`、`PacketQueue`、`TcpConnection`、`Reno`、`Cubic` 的字段是私有的，读状态一律走方法（`sim.now()`、`link.dropped()`、`connection.cwnd()`）。字段是实现的自由，重构它不会碰到下游。
- **值是记录，字段就是契约**：`Time`、`Packet`、`Segment`、`Seq`、`Flags`、`TcpConfig`、`LinkSpec`、`QueueSpec` 以及 `src/lab` 的 `Scenario` / `RunReport` / `RunSummary` / `TraceRun` / `DeliveryDiagnostics` / `DeliveryStall` 是纯数据，字段公开、可读可构造。
- **队列扫描汇总口径**：`RunSummary.mean_queue_packets` 是跨运行的平均上行队列占用；`mean_max_sojourn` 是每次运行最大排队等待时间的均值；`worst_max_sojourn` 是跨运行观测到的最大等待时间。JSON 使用毫秒字段 `mean_max_sojourn_ms` / `worst_max_sojourn_ms`。`SweepField::validate_range` 对 `queue_packets` 要求正整数端点、包含端点的步数和不重复容量；库调用方应在调用 `sweep` 前验证范围，CLI 会自动验证。
- **停顿诊断说明**：`TraceRun::delivery_diagnostics` 只统计超过 `max(2 × SRTT, 1 ms)` 的连续交付间隔，提供次数、累计/最长时长和逐段观测信号。队列非空、恢复事件、发送窗口阻塞可能同时出现；这些字段记录证据，不保证单一因果归属。
- **轨迹图表**：`trace_svg_from_json` 接受 `run --trace --json` 生成的单流报告，返回不依赖外部资源的 SVG 字符串。图表按仿真时间绘制窗口、在途字节和双向队列，标注恢复事件与停顿区间；相同输入产生相同输出。
- **接口的机器可读版本**是每个包目录下的 `pkg.generated.mbti`，由 `moon info` 生成。它和代码一起进版本库，因此**一次接口改动在 diff 里是什么样的，任何人都能看见**；CI 会重新生成它，改动不会是意外。
- **版本与兼容**：当前 `0.1.0`。0.x 阶段按 minor 递增，破坏性改动不承诺同 minor 兼容；等接口稳定到 1.0 再给兼容承诺。这不是免责声明，是让"能不能依赖"变成一个有日期的判断。

## 库本身的保证

1. **确定性**：同一场景、同一随机种子，事件顺序、随机数与报告逐字节一致，跨后端与平台成立（CI 与本地都断言）。
2. **零依赖**：`sim` / `net` / `tcp` / `json` / `lab` 只依赖标准库；唯一的例外是命令行读文件用的 `moonbitlang/x`（因为标准库不含文件系统）。所以把库嵌进别人的 wasm 目标不需要额外依赖。
3. **没有全局状态**：每次运行是 `Sim::new(seed)` 出来的一个对象，两个仿真可以在同一个进程里并行跑，互不影响。

## 两个现成的消费者

仓库里有两个包是**用库写程序**的例子，而不是库的一部分——它们就是"下游"的样子：

- [`examples/embed_tcp`](../examples/embed_tcp/embed.mbt)：不读场景文件、不解析命令行，直接把 `LinkPair` 拼起来跑一次传输并读指标；测试断言同一 seed 两次运行结果相同，以及换算法在指标上看得见。
- [`examples/rpc_retry`](../examples/rpc_retry/rpc.mbt)：带自己的请求/响应协议（超时 + 有限重试）复用 `sim` 与 `net`，`moon test` 断言"同一路径下，重试预算把未送达的调用从 13/20 降到 4/20"。

```bash
moon run examples/embed_tcp/main    # 三个算法跑同一段传输
moon run examples/rpc_retry/main    # 丢掉不同比例的包时，一次调用要几次重试
```

这两个包不依赖 `cmd/moonnet`，`cmd/moonnet` 也不依赖它们：库位于中间，命令行和示例都是它的使用者。
