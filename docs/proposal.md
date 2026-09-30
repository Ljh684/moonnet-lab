# 2026 MoonBit 九月黑客松 · 项目申报书

| 项目名称 | moonnet-lab（月兔网络实验室） |
| --- | --- |
| 参赛者 | Ljh684 |
| 开源仓库 | https://github.com/Ljh684/moonnet-lab （公开，Apache-2.0） |
| 语言与依赖 | MoonBit；库本身零依赖，只有命令行工具用官方扩展库 `moonbitlang/x` 读写文件 |
| 规模 | 34 个 MoonBit 文件（实现 26、测试 8），源码 7757 行、测试 2523 行，113 个测试全部通过 |

## 一、项目目标与应用场景

**目标**：给 MoonBit 生态一个可以被**别的程序直接调用**的网络行为模型——给定链路参数、流量与种子，输出逐字节一致的指标；生态里没有能在自己代码里调用的 TCP 与队列模型。

**场景**：服务作者把重试、超时、退避放进模型做确定性回归；网络工程师切算法或改参数前做 A/B 对比；教学里每条结论对应一条可重跑的命令。

## 二、拟实现的功能

| 编号 | 功能 | 交付物 | 状态 |
| --- | --- | --- | --- |
| F1 | 确定性事件内核：皮秒整数时间、事件堆、冻结的随机源 | `src/sim` | 已完成 |
| F2 | 链路与队列：带宽 / 延迟 / 抖动 / 丢包、有界队列、drop-tail / RED / CoDel | `src/net` | 已完成 |
| F3 | TCP 协议栈：握手、滑动窗口、乱序重组、RTO 估计、快速重传、多丢包恢复 | `src/tcp` | 已完成 |
| F4 | 拥塞控制：可插拔接口、Reno、CUBIC | `src/tcp` | 已完成 |
| F5 | 实验与报告：场景、JSON 报告、对比、扫描、多种子平均、多流公平性 | `src/lab` | 已完成 |
| F6 | 命令行与场景：6 个子命令、7 份场景 | `cmd/moonnet` | 已完成 |
| F7 | 可复用接口与下游示例：字段私有的组件 + 两个不使用命令行的消费者 | `src/*`、`examples/` | 已完成 |

不在本次范围：Vegas 等延迟型算法、通用仿真框架、pcap 解析、与真实协议栈互操作；明细见 [README.md](../README.md)。

## 三、验收说明

本地 `moon test` 已通过 113 个测试；CI 配置逐条覆盖 F1–F7。下表里的 `moonnet` 指 `moon run cmd/moonnet --`。

| 编号 | 怎么验 | 通过标准 |
| --- | --- | --- |
| F1 | `moon test` 中的确定性断言 | 同一场景两次运行的报告逐字节相同 |
| F2 | `moonnet run scenarios/bufferbloat.json`，再试 `--discipline codel` 与 `--discipline red` | 1500 字节 @ 10 Mbps 恰好 1.2 毫秒；最坏排队延迟 978.7 → 226.4 毫秒（同场景、同算法）；RED 在该场景 11.826 秒完成、1 次超时（空闲期修正前是 49.440 秒 / 5 次） |
| F3 | `moonnet compare scenarios/long-fat.json --cc reno,cubic --seeds 3` | 1% 丢包下都完整送达 20 MB；超时 Reno 19 次、CUBIC 7 次 |
| F4 | 同上，加 `moon test` 的窗口断言 | 三种子均值 Reno 137.6 秒、CUBIC 151.5 秒（区间重叠）；同一串丢包下在途字节 3500 对 4000 |
| F5 | `moonnet run scenarios/fairness.json` | 4 条流聚合 9.75 Mbps ≤ 10 Mbps 链路容量；Jain 指数 0.77–0.93 |
| F6 | CI 在干净 runner 上跑 `moon fmt --check`、`moon check`、`moon test` 与 `list` / `compare` / `run` / `plot` | `plot` 将归档 trace JSON 生成为确定性、可解析的独立 SVG |
| F7 | `moon run examples/embed_tcp/main`、`moon run examples/rpc_retry/main` | 两条命令各自打印结果；测试断言同一 seed 两次运行一致、重试把未送达的调用从 13/20 降到 4/20 |

## 四、复用性：下游怎么依赖它

**命令行只是库的一个使用者**：`cmd/moonnet` 建在 `src/*` 之上，`examples/*` 与它并列。

- **接口与稳定面**：下游可用 `moon add Ljh684/moonnet-lab@0.1.0` 安装并调用五个库包；`Sim`、`Link`、`TcpConnection` 等有内部状态的对象字段私有、经方法读取，值是记录，`pkg.generated.mbti` 随代码进版本库（见 [api.md](api.md)）。
- **证据与价值**：`examples/embed_tcp`、`examples/rpc_retry` 是不使用命令行的消费者，CI 运行它们；把网络不确定性做成可复现的测试输入，并在部署前回答缓冲区深度与算法选择。

## 五、与已有生态的区别

与 moonsim 同为 MoonBit 里的确定性仿真，区别在研究对象：它建模服务的可靠性逻辑，本项目建模网络与传输协议的行为。它的抽象里没有拥塞窗口，也没有队头等待时间，所以"缓冲区深度 → 排队延迟 → 往返时间 → 窗口收敛"这条回路它结构上产不出来。详见 [positioning.md](positioning.md)。

## 六、边界

协议按 RFC 实现，不等于真实内核；延迟 ACK、SACK、重排序检测未实现（已知边界见 [design.md](design.md)）。

## 七、个人背景

MoonBit 开发者，已在 mooncakes.io 发布解析器组合子库 `Ljh684/MoonParse`；位级格式、状态机与错误处理的实现经验与本项目直接相关。

## 八、其他材料

[README](../README.md) · [api](api.md) · [定位](positioning.md) · [验证](verification.md) · [设计](design.md) · [路线图](roadmap.md)
