# 2026 MoonBit 九月黑客松 · 项目申报书

| 项目名称 | moonnet-lab（月兔网络实验室） |
| --- | --- |
| 参赛者 | Ljh684 |
| 开源仓库 | https://github.com/Ljh684/moonnet-lab （公开，Apache-2.0，CI 绿） |
| 语言与依赖 | MoonBit；仿真库零依赖，命令行工具用官方扩展库 `moonbitlang/x` 读写文件 |
| 规模 | 23 个 MoonBit 文件，源码 6430 行、测试 2096 行；95 个测试全部通过 |

## 一、项目目标与应用场景

**目标**：为 MoonBit 生态补上验证**协议行为**的实验台——给定链路参数、流量与种子，输出逐字节一致的指标，把"网络在这组参数下会怎样"变成可复现的实验。生态里已有链接库与协议头解析，没有建模 TCP 丢包响应行为的项目。

**场景**：切算法或改参数之前的 A/B 对比；拥塞控制教学（每条结论对应一条可重跑的命令）；为将来的 MoonBit 网络栈提供回归测试台。

## 二、拟实现的功能

| 编号 | 功能 | 交付物 | 状态 |
| --- | --- | --- | --- |
| F1 | 确定性事件内核：皮秒整数虚拟时间、事件堆、冻结的随机源 | `src/sim` | 已完成 |
| F2 | 链路与队列：带宽 / 延迟 / 抖动 / 丢包；有界队列；队列管理 drop-tail / RED / CoDel | `src/net` | 已完成 |
| F3 | TCP 协议栈：握手、滑动窗口、乱序重组、RTO 估计、快速重传、多丢包恢复 | `src/tcp` | 已完成 |
| F4 | 拥塞控制：可插拔接口、Reno（RFC 5681/6928）、CUBIC（RFC 9438） | `src/tcp` | 已完成 |
| F5 | 实验与报告：场景文件、JSON 报告、多算法对比、参数扫描、多种子平均、多流公平性 | `src/lab` | 已完成 |
| F6 | 命令行与场景：`run` / `compare` / `sweep` / `list` / `version`，7 份示例场景 | `cmd/moonnet`、`scenarios/` | 已完成 |

功能明细见 [README.md](../README.md) 的"当前状态"表。不在本次范围：Vegas 等延迟型算法、图表输出、通用仿真框架、pcap 解析、与真实协议栈互操作。

## 三、验收说明

全部验收可由 `moon test`（95 个测试）与一次 CI 完成，逐条对应 F1–F6。

| 编号 | 怎么验 | 通过标准 |
| --- | --- | --- |
| F1 | `moon test` 中的确定性断言 | 同一场景两次运行的 JSON 报告逐字节相同；随机数参考向量与预期一致 |
| F2 | `moon run cmd/moonnet -- run scenarios/bufferbloat.json`，再试 `--discipline codel` | 1500 字节的报文在 10 Mbps 链路上恰好 1.2 毫秒；同一场景、同一算法下最坏排队延迟 drop-tail 978.7 毫秒、CoDel 226.4 毫秒 |
| F3 | `moon run cmd/moonnet -- compare scenarios/long-fat.json --cc reno,cubic --seeds 3` | 1% 丢包下两者都把 20 MB 完整送达；超时次数 Reno 112 次、CUBIC 23 次 |
| F4 | 同一条命令，加上 `moon test` 里的窗口断言 | 三种子均值 Reno 706.1 秒、CUBIC 218.6 秒；同一串丢包下保留的在途字节不同（Reno 3500、CUBIC 4000） |
| F5 | `moon run cmd/moonnet -- run scenarios/fairness.json` | 4 条流共用 10 Mbps 链路：聚合 9.75 Mbps（不超过链路容量），Jain 指数 0.77–0.93 |
| F6 | CI 在干净的 Linux runner 上执行 `moon fmt --check`、`moon check`、`moon test`，再跑 `list` / `compare` / `run` | 全部通过 |

## 四、与已有生态的区别

与 moonsim 同为 MoonBit 里的确定性仿真，区别在研究对象：moonsim 建模服务的可靠性逻辑（消息、任务、状态机、外部调用），本项目建模网络与传输协议的行为。它的抽象里没有拥塞窗口，也没有队头等待时间，因此"缓冲区深度 → 排队延迟 → 往返时间 → 窗口收敛"这条回路它结构上产不出来。完整对比见 [positioning.md](positioning.md)。

## 五、边界

协议按 RFC 实现，不等于真实内核；延迟 ACK、SACK、重排序检测未实现。已知边界见 [design.md](design.md)。

## 六、个人背景

MoonBit 开发者，已在 mooncakes.io 发布解析器组合子库 `Ljh684/MoonParse`；协议实现经验（位级格式、状态机、错误处理）与可复现的习惯（每个数字都能用仓库里的命令复算）与本项目直接相关。

## 七、其他材料

[README.md](../README.md) · [positioning.md](positioning.md) · [verification.md](verification.md) · [design.md](design.md) · [roadmap.md](roadmap.md)
