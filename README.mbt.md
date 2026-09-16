# moonnet-lab

**一个用 MoonBit 写的、确定性的数据包级网络仿真与 TCP 拥塞控制实验平台。**

同一个场景、同一个随机种子，无论跑多少次、在哪个后端跑，事件顺序、随机数和每一个指标都完全一致。这让"改一个参数，看吞吐变化"从经验判断变成可复现的实验。

## 它解决什么问题

调拥塞控制、评估缓冲区大小、判断链路丢包时该选哪个算法，这些问题的答案通常来自真实设备上的试错，或者来自一次无法复现的临时脚本。两者都有同一个毛病：换一台机器、换一次运行，数字就变了。

moonnet-lab 把网络行为建模成纯函数：给定拓扑、流量、参数和随机种子，输出确定的事件序列和指标。于是三件事同时变得可能——对比不同拥塞控制算法、回溯上一次实验为什么得出那个结论、把结论当成回归测试固化下来。

## 当前状态

内核与网络层已经完成并有测试覆盖；TCP 协议栈与拥塞控制算法按 [路线图](docs/roadmap.md) 推进。

| 模块 | 内容 | 状态 |
| --- | --- | --- |
| `src/sim` | 虚拟时间、确定性事件队列、可复现随机源 | 完成 |
| `src/net` | 数据包、有界队列（drop-tail）、链路（带宽/延迟/抖动/丢包） | 完成 |
| `src/tcp` | 连接状态机、三次握手、序号与累计确认、滑动窗口、乱序重组 | 完成 |
| `src/tcp` | RTO 估计（RFC 6298）、Karn 算法、超时重传与指数退避 | 完成 |
| `src/tcp` | 快速重传与快速恢复 | 下一步 |
| `src/cc` | Reno / CUBIC / Vegas 拥塞控制 | 计划中 |
| `src/aqm` | RED、CoDel 队列管理 | 计划中 |
| `src/report` | JSON 指标与 SVG 图表 | 计划中 |

## 快速开始

需要 [MoonBit 工具链](https://www.moonbitlang.com/download)，本项目不依赖任何第三方包。

```bash
moon test                        # 运行全部测试
moon run cmd/moonnet -- demo     # 跑一个内置场景并打印报告
moon run cmd/moonnet -- tcp      # 跑一次完整的 TCP 握手与批量传输
moon run cmd/moonnet -- lossy    # 同一场景，无丢包 vs 1% 丢包对比
```

demo 的输出：

```text
moonnet-lab 0.1.0 (deterministic packet-level network simulator)

scenario: 3 x 1500 B every 200 us over a 10 Mbps link, 5 ms delay
arrivals: 6.200ms, 7.400ms, 8.600ms
link:     uplink: 3 packets, 4500 bytes, 0 dropped, utilization 42.8%
```

三个 1500 字节的数据包相隔 200 微秒发出。10 Mbps 的链路上每个包要占用 1.2 毫秒，所以它们排队而不是重叠，到达时间正好相差一个发送时长。这类数字不是打印出来看看的：它们全部写进了回归测试。

`tcp` 子命令走完整的协议路径——三次握手、20000 字节应用数据、逐段确认：

```text
handshake completed at 15.048ms
transferred 20000 bytes in 34.636ms (4619.3 kbit/s)
client: ESTABLISHED
server: ESTABLISHED
segments: 24 sent, 23 received
```

34.6 毫秒这个数字可以直接验算：接收窗口 8192 字节、MSS 1000 字节，最多 8 个段同时在途，20 个段需要大约三次往返，而一次往返是 10 毫秒加上链路的串行化时间。同样地，它也是一条回归测试。

`lossy` 子命令把同一个场景跑两遍——一遍干净，一遍每条链路丢 1% 的包：

```text
clean path: 50000 bytes in 1.310s (305.1 kbit/s), 0 retransmissions
1% loss:    50000 bytes in 3.304s (121.0 kbit/s), 2 retransmissions, 2 timeouts

estimator:  46 round trip samples, RTO 1.000s
smoothed:   53.533ms round trip time
```

一成的数据改变，2.5 倍的传输时间。原因写在最后两行里：往返时间测出来是 53 毫秒，但 RTO 停在 1 秒——RFC 6298 规定连接在建立初期必须按最坏情况估计超时，所以每个丢失的包要等满一秒才被重传。这个"损失一个包就等于损失一秒"的现象，是后面做拥塞控制对比时最先要解释的东西：CUBIC 和 Vegas 的价值不在于更快发现丢包，而在于不要因为一次丢包就把速度砍半。

## 确定性是怎么保证的

1. **时间是整数。** 虚拟时间以皮秒计数，存成 `Int64`。整个仿真里没有一处用浮点数做调度决策，因此不存在两个后端舍入到不同结果的可能。
2. **事件顺序有唯一解。** 事件队列按 `(时间, 到达序号)` 排序，同一皮秒内先调度的事件先执行。没有哈希遍历、没有墙钟、没有并发。
3. **随机数是冻结的。** 自带 SplitMix64 + xoshiro256**，参考向量在测试里钉死。每条链路、每条流用 `fork(label)` 从主种子派生独立随机流，所以新增一条无关的流不会扰动其他流的随机序列。
4. **事件处理里不分配内存。** 队列用环形缓冲、容量按需增长，运行期间不分配，避免宿主内存管理影响时间行为。

违反这些约定的代码会被测试抓住：`src/sim/sim_test.mbt` 里既有随机数参考向量，也有"同一场景跑两遍逐字节一致"的断言。

## 目录结构

```text
src/sim/     虚拟时间、事件内核、随机源
src/net/     数据包、队列、链路
cmd/moonnet/ 命令行入口
docs/        设计说明与路线图
```

设计取舍写在 [docs/design.md](docs/design.md)，后续计划写在 [docs/roadmap.md](docs/roadmap.md)。

## 与生态中已有工作的关系

MoonBit 生态里已经有几款通用离散事件仿真引擎（moonsim、moondes 等），也有 pcap 与协议头解析库。moonnet-lab 不去重做这两件事：它不提供通用 DES 抽象，也不解析真实抓包文件，而是专注在**网络行为语义**这一层——链路怎样串行化、队列在什么条件下丢包、TCP 在丢包后如何调整窗口。通用仿真引擎回答"事件怎么排队"，本项目回答"排队之后网络会发生什么"。

## English summary

moonnet-lab is a deterministic packet-level network simulator and TCP congestion-control laboratory written in MoonBit, with no third-party dependencies. Given a topology, a traffic pattern and a seed, a run produces byte-identical event ordering, random draws and metrics. Virtual time is an exact integer in picoseconds, events are ordered by `(time, arrival sequence)`, and the PRNG is frozen with pinned reference vectors. The kernel and the link layer are complete and tested; the TCP stack, the congestion-control algorithms and the reporting layer are in progress.

## License

Apache-2.0
