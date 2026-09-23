# 2026 MoonBit 九月黑客松 · 项目申报书

| 项目名称 | moonnet-lab（月兔网络实验室） |
| --- | --- |
| 参赛者 | Ljh684 |
| 开源仓库 | https://github.com/Ljh684/moonnet-lab （公开，Apache-2.0，CI 绿） |
| 语言与依赖 | MoonBit；十个包中只有命令行工具用官方扩展库 `moonbitlang/x` 读文件，库本身零依赖 |
| 规模 | 22 个实现文件 + 7 个测试文件，源码 6127 行、测试 2204 行，102 个测试全部通过 |

## 一、项目目标与应用场景

**目标**：给 MoonBit 生态一个可以被**别的程序直接调用**的网络行为模型——给定链路参数、流量与种子，输出逐字节一致的指标。生态里已有链接库与协议头解析，但没有能在自己代码或测试里调用的 TCP 与队列模型。

**场景**：服务作者把重试、超时、退避放进模型做确定性回归；网络工程师在改参数或切算法之前做 A/B 对比；教学里每条结论对应一条可重跑的命令。

## 二、拟实现的功能

| 编号 | 功能 | 交付物 | 状态 |
| --- | --- | --- | --- |
| F1 | 确定性事件内核：皮秒整数虚拟时间、事件堆、冻结的随机源 | `src/sim` | 已完成 |
| F2 | 链路与队列：带宽 / 延迟 / 抖动 / 丢包；有界队列；队列管理 drop-tail / RED / CoDel | `src/net` | 已完成 |
| F3 | TCP 协议栈：握手、滑动窗口、乱序重组、RTO 估计、快速重传、多丢包恢复 | `src/tcp` | 已完成 |
| F4 | 拥塞控制：可插拔接口、Reno（RFC 5681/6928）、CUBIC（RFC 9438） | `src/tcp` | 已完成 |
| F5 | 实验与报告：场景文件、JSON 报告、多算法对比、参数扫描、多种子平均、多流公平性 | `src/lab` | 已完成 |
| F6 | 命令行与场景：`run` / `compare` / `sweep` / `list` / `version`，7 份示例场景 | `cmd/moonnet` | 已完成 |
| F7 | 可复用接口与下游示例：字段私有的组件 + 两个不依赖命令行的消费者包 | `src/*`、`examples/` | 已完成 |

功能明细见 [README.md](../README.md) 的"当前状态"表。不在本次范围：Vegas 等延迟型算法、图表输出、通用仿真框架、pcap 解析、与真实协议栈互操作。

## 三、验收说明

全部验收可由 `moon test`（102 个测试）与一次 CI 完成，逐条对应 F1–F7。

| 编号 | 怎么验 | 通过标准 |
| --- | --- | --- |
| F1 | `moon test` 中的确定性断言 | 同一场景两次运行的 JSON 报告逐字节相同；随机数参考向量与预期一致 |
| F2 | `moon run cmd/moonnet -- run scenarios/bufferbloat.json`，再试 `--discipline codel` | 1500 字节的报文在 10 Mbps 链路上恰好 1.2 毫秒；同一场景、同一算法下最坏排队延迟 drop-tail 978.7 毫秒、CoDel 226.4 毫秒 |
| F3 | `moon run cmd/moonnet -- compare scenarios/long-fat.json --cc reno,cubic --seeds 3` | 1% 丢包下两者都把 20 MB 完整送达；超时次数 Reno 112 次、CUBIC 23 次 |
| F4 | 同一条命令，加上 `moon test` 里的窗口断言 | 三种子均值 Reno 706.1 秒、CUBIC 218.6 秒；同一串丢包下保留的在途字节不同（Reno 3500、CUBIC 4000） |
| F5 | `moon run cmd/moonnet -- run scenarios/fairness.json` | 4 条流共用 10 Mbps 链路：聚合 9.75 Mbps（不超过链路容量），Jain 指数 0.77–0.93 |
| F6 | CI 在干净的 Linux runner 上执行 `moon fmt --check`、`moon check`、`moon test`，再跑 `list` / `compare` / `run` | 全部通过 |
| F7 | `moon run examples/embed_tcp/main` 与 `moon run examples/rpc_retry/main`（CI 同样执行） | 两条命令各自打印结果；测试断言同一 seed 两次运行结果一致，且重试预算把未送达的调用从 13/20 降到 4/20 |

## 四、复用性：下游怎么依赖它

**命令行只是库的一个使用者。** `cmd/moonnet` 建在 `src/*` 之上，`examples/*` 与它并列且互不依赖——库在中间，两层都是它的消费者。

- **接口**：下游在 `moon.mod` 里加本模块即可调用五个库包（`sim` / `net` / `tcp` / `json` / `lab`）；发布到 mooncakes.io 只差维护者执行一次 `moon publish`，模块元数据已就位。
- **稳定面**：有内部状态的对象（`Sim`、`Rng`、`Link`、`PacketQueue`、`TcpConnection`、`Reno`、`Cubic`）字段私有、状态一律经方法读取；值是记录、字段即契约；每个包的 `pkg.generated.mbti` 随代码进版本库，接口改动在 diff 里可见。契约与兼容承诺见 [api.md](api.md)。
- **被消费的证据**：[`examples/embed_tcp`](../examples/embed_tcp/embed.mbt) 在自己的程序里直接拼出一次传输并读指标；[`examples/rpc_retry`](../examples/rpc_retry/rpc.mbt) 带自己的超时 + 重试协议复用时钟与链路模型。两者都不读场景文件、不解析命令行，CI 在干净 runner 上运行它们。
- **应用价值**：把网络不确定性变成可复现的测试输入——服务作者可以验证自己的重试/超时策略在 1%、20%、50% 丢包下的表现，部署前可以回答"缓冲区该多深、该用哪个拥塞控制"。库零依赖、无全局状态，每个仿真是独立的 `Sim::new(seed)` 对象。

## 五、与已有生态的区别

与 moonsim 同为 MoonBit 里的确定性仿真，区别在研究对象：它建模服务的可靠性逻辑（消息、任务、状态机、外部调用），本项目建模网络与传输协议的行为。它的抽象里没有拥塞窗口，也没有队头等待时间，所以"缓冲区深度 → 排队延迟 → 往返时间 → 窗口收敛"这条回路它结构上产不出来。完整对比见 [positioning.md](positioning.md)。

## 六、边界

协议按 RFC 实现，不等于真实内核；延迟 ACK、SACK、重排序检测未实现。已知边界见 [design.md](design.md)。

## 七、个人背景

MoonBit 开发者，已在 mooncakes.io 发布解析器组合子库 `Ljh684/MoonParse`；位级格式、状态机与错误处理的实现经验，以及每个数字都能用命令复算的习惯，与本项目直接相关。

## 八、其他材料

[README.md](../README.md) · [api.md](api.md) · [positioning.md](positioning.md) · [verification.md](verification.md) · [design.md](design.md) · [roadmap.md](roadmap.md)
