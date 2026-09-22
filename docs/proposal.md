# 2026 MoonBit 九月黑客松 · 项目申报书

| 项目名称 | moonnet-lab（月兔网络实验室） |
| --- | --- |
| 参赛者 | Ljh684 |
| 开源仓库 | https://github.com/Ljh684/moonnet-lab （公开，Apache-2.0，CI 绿） |
| 语言与依赖 | MoonBit；仿真库零依赖，命令行工具用官方扩展库 `moonbitlang/x` 读写文件 |
| 规模 | 23 个 MoonBit 文件，源码 6430 行、测试 2096 行；95 个测试全部通过 |

**一句话**：给定链路参数、流量与随机种子，输出逐字节一致的指标——把"网络在这组参数下会怎样"变成可复现的实验。

## 一、项目目标与应用场景

**目标**：为 MoonBit 生态补上一个验证**协议行为**的实验台——生态里已有链接库与协议头解析，没有建模 TCP 丢包响应行为的项目。

**场景**：改参数或切算法之前的 A/B 对比（1% 丢包下 Reno 与 CUBIC 差多少、缓冲区开多大排队延迟还能接受）；拥塞控制教学；为将来的 MoonBit 网络栈提供回归测试台。

## 二、拟实现的功能

| 功能 | 内容 | 状态 |
| --- | --- | --- |
| 确定性事件内核 | 皮秒整数虚拟时间、按 `(时间, 调度序号)` 排序的事件堆、冻结的 SplitMix64 + xoshiro256** 随机源 | 已完成 |
| 链路与队列 | 带宽、传播延迟、抖动、丢包；有界队列（按包数与字节双限制）；三种队列管理策略 drop-tail / RED / CoDel | 已完成 |
| TCP 协议栈 | 状态机与三次握手、序号与累计确认、滑动窗口、乱序重组、RFC 6298 的 RTO 估计、Karn 算法、超时退避、快速重传、多丢包恢复 | 已完成 |
| 拥塞控制 | 可插拔接口（7 个方法）；Reno（RFC 5681/6928）、CUBIC（RFC 9438） | 已完成 |
| 实验与报告 | 场景文件、运行、固定字段顺序的 JSON 报告、多算法对比、参数扫描、多种子平均、多流公平性 | 已完成 |
| 命令行与场景 | 五个子命令 `run` / `compare` / `sweep` / `list` / `version`；7 份示例场景 | 已完成 |
| 不在本次范围 | Vegas（延迟型拥塞控制）、自渲染 SVG 图表；通用仿真框架、pcap 解析、与真实协议栈互操作 | — |

本次提交以六项"已完成"功能为准。

## 三、验收说明

下表是本次提交的验收标准，每条都能用仓库里的命令复核。

| 功能 | 怎么验 | 通过标准 |
| --- | --- | --- |
| 确定性 | `moon test`：同一场景跑两次，报告逐字节比较；随机数有钉死的参考向量 | 两次 `to_json_text()` 完全相同 |
| 物理量 | 链路串行化与吞吐上限断言 | 1500 字节的报文在 10 Mbps 链路上恰好 1.2 毫秒；聚合吞吐不超过"带宽 × 时间窗" |
| 队列管理 | `moon run cmd/moonnet -- run scenarios/bufferbloat.json`，再加 `--discipline codel` | 同一场景、同一算法：drop-tail 最坏排队延迟 978.7 毫秒，CoDel 226.4 毫秒；测试另断言 drop-tail 从不提前丢弃、CoDel 在缓冲区未满时就丢弃 |
| 拥塞控制 | `moon run cmd/moonnet -- compare scenarios/long-fat.json --cc reno,cubic --seeds 3` | CUBIC 均值 218.6 秒、Reno 706.1 秒，超时 23 次对 112 次；测试断言同一串丢包下两者保留的在途字节不同（4000 对 3500） |
| 多流公平性 | `moon run cmd/moonnet -- run scenarios/fairness.json` | 4 条流聚合 9.75 Mbps（不超过 10 Mbps 链路容量），Jain 指数 0.77–0.93 |
| 工程可用性 | CI 在干净的 Linux runner 上执行 `moon fmt --check`、`moon check`、`moon test`，再跑 `list` / `compare` / `run` | 全部通过 |

测试覆盖明细见 [verification.md](verification.md)，数据与复现命令见 [README.md](../README.md)。

## 四、与已有生态的区别

与 moonsim 同为 MoonBit 里的确定性仿真，区别在研究对象：moonsim 建模服务的可靠性逻辑（消息、任务、状态机、外部调用），本项目建模网络与传输协议的行为。它的抽象里没有拥塞窗口，也没有队头等待时间，所以"缓冲区深度 → 排队延迟 → 往返时间 → 窗口收敛"这条回路它结构上产不出来。完整对比见 [positioning.md](positioning.md)。

## 五、风险与边界

协议按 RFC 实现，不等于真实内核，真实硬件上的问题应该用 Mininet；尚未实现延迟 ACK、SACK、重排序检测。一个未查清的问题（成批丢失后恢复有时退化成靠 60 秒定时器推进）只记数据与复现命令，写在 [roadmap.md](roadmap.md)。

## 六、个人背景

MoonBit 开发者，已在 mooncakes.io 发布解析器组合子库 `Ljh684/MoonParse`；匹配度是协议实现经验（位级格式、状态机、错误处理）与可复现的习惯（每个数字都能用仓库里的命令复算）。

## 七、其他材料

[README.md](../README.md) · [positioning.md](positioning.md) · [verification.md](verification.md) · [design.md](design.md) · [roadmap.md](roadmap.md)
