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
| `src/tcp` | 快速重传（三次重复 ACK）、一次窗口内多丢包的部分确认恢复 | 完成 |
| `src/tcp` | 可插拔拥塞控制接口、Reno（慢启动 / 拥塞避免 / 快速恢复 / 超时崩塌） | 完成 |
| `src/tcp` | CUBIC（RFC 9438：三次增长曲线、0.7 倍乘性减少、Reno 友好区） | 完成 |
| `src/tcp` | Vegas（用延迟而不是丢包当作拥塞信号） | 计划中 |
| `src/aqm` | RED、CoDel 队列管理 | 计划中 |
| `src/json` | 零依赖的 JSON 读写，供场景文件与报告使用 | 完成 |
| `src/lab` | 实验即数据：场景文件、运行、指标报告 | 完成 |
| `src/lab` | `compare` 与 `sweep` 子命令 | 完成 |
| `src/lab` | SVG 图表、多流场景、受控丢包（按序号而不是按发送顺序） | 下一步 |

## 快速开始

需要 [MoonBit 工具链](https://www.moonbitlang.com/download)。**仿真库本身零依赖**；只有命令行工具为了让"实验是文件"这件事成立，引入了官方扩展库 `moonbitlang/x` 来读写文件。`moon test` 会先自动拉取它。

```bash
moon test                        # 运行全部测试
moon run cmd/moonnet -- demo     # 跑一个内置场景并打印报告
moon run cmd/moonnet -- tcp      # 跑一次完整的 TCP 握手与批量传输
moon run cmd/moonnet -- lossy    # 同一场景，无丢包 vs 1% 丢包对比
moon run cmd/moonnet -- cc       # 有无拥塞控制的对比
moon run cmd/moonnet -- list     # 列出 scenarios 目录里的实验
moon run cmd/moonnet -- run scenarios/long-fat.json --cc cubic
moon run cmd/moonnet -- compare scenarios/long-fat.json --cc reno,cubic
moon run cmd/moonnet -- sweep scenarios/small-buffers.json --field loss --from 0 --to 0.02 --steps 5
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
handshake completed at 10.032ms
transferred 20000 bytes in 29.636ms (5398.6 kbit/s)
client: ESTABLISHED
server: ESTABLISHED
segments: 24 sent, 23 received
```

29.6 毫秒这个数字可以直接验算：接收窗口 8192 字节、MSS 1000 字节，最多 8 个段同时在途，20 个段需要大约三次往返，而一次往返是 10 毫秒加上链路的串行化时间。同样地，它也是一条回归测试。

`lossy` 子命令把同一个场景跑两遍——一遍干净，一遍每条链路丢 1% 的包：

```text
clean path: 50000 bytes end to end in 380.734ms (1050.6 kbit/s), connect 50.032ms, 0 retransmissions
1% loss:    50000 bytes end to end in 1.385s (288.6 kbit/s), connect 50.032ms, 1 retransmissions (0 fast, 1 by timeout)

estimator:  53 round trip samples, RTO 2.000s
smoothed:   50.839ms round trip time
```

这组数字里藏着这个项目最想讲清楚的一件事：**同样一个丢包，出现在不同阶段，代价差二十倍。**

丢包出现在握手阶段时，连接要多花整整一秒。TCP 建立初期必须按最坏情况估计超时（RFC 6298 规定初始 RTO 为 1 秒），而握手报文的后面没有任何报文在飞，收不到重复 ACK，只能等定时器。

丢包出现在数据传输阶段时，代价只有大约一个往返时间。因为丢失报文后面还有六七个报文陆续到达，接收端每收到一个就重复发一次 ACK；第三次重复 ACK 一到，发送端立刻重传，不等超时。这就是快速重传。

换句话说，救回一个丢包靠的不是"更聪明地等待"，而是"手上有别的证据"。

注意这里的 `RTO 2.000s`：超时之后 RTO 会翻倍，而窗口会塌回一个报文。慢下来是刻意的——下一节的对比说明它为什么要这么慢。

## 拥塞控制：为什么必须慢下来

`cc` 子命令把同一个丢包场景跑两遍，唯一区别是发送端**是否对丢包做出反应**：

```text
A. small buffers: 10 Mbps, 25 ms one way, 1% loss, 64 KB window, 16-packet queue
   payload 200000 bytes

   none     3908.214s       0.4 kbit/s   105 retransmits  70 timeouts
   reno     662.277ms    2415.9 kbit/s     2 retransmits   0 timeouts

B. long fat path: 100 Mbps, 50 ms one way, 1% loss, 2 MB window, 2000-packet queue
   payload 20000000 bytes

   reno      214.129s     747.2 kbit/s   425 retransmits  27 timeouts
   cubic     318.218s     502.7 kbit/s   199 retransmits  12 timeouts
```

场景 A 里，不带拥塞控制的发送端把接收端允诺的 64 KB 一次性推进去，而链路队列只能装 16 个报文。队列溢出、丢包；重传又是同样一整批、再次溢出；每次超时还按指数退避翻倍，一路涨到分钟级。200 KB 的数据传了 65 分钟——这就是 1986 年让互联网差点瘫掉的拥塞崩溃，在 200 行代码里复现了一遍。Reno 一开始只发 10 个报文，之后慢慢加速，队列始终没见到装不下的突发。**同一场景、同一种子、同样的丢包率：5901 倍的传输时间差。**

场景 B 是另一种问题。这条路径的带宽延迟积是 1.25 MB，链路每秒丢 1% 的包，两个算法都被丢包限制住了——这时的差别不在于谁更快发现丢包，而在于**丢了之后丢掉多少**。

Reno 每次丢包把窗口砍一半，然后用一个往返一个报文的速度往回爬。CUBIC 只丢掉 30%，沿着三次曲线往回爬：刚丢包时曲线很陡（那段窗口路径已经证明过），接近丢包前的窗口时变平（再往上就是没有根据的试探）。

**上面这张单次运行的表差点又骗了我一次。** 它显示 CUBIC 更慢。加上 `--seeds 3` 之后：

```text
algorithm  mean      fastest   slowest    throughput  retransmits  timeouts
reno       706.083s  214.129s  1312.194s       226.6         1177       112
cubic      218.618s  166.922s   318.218s       731.8          591        23
```

**均值下 CUBIC 快 3.2 倍，超时次数是五分之一。** 单次运行得到的是相反的结论，因为丢包场景下的总时间由少数几次超时主导，而超时按指数退避封顶到 60 秒——Reno 那 112 次超时里有几次直接吃掉了十几分钟。Reno 的最快一次（214 秒）甚至和 CUBIC 的均值相当。

这一轮真正学到的东西不是"CUBIC 更快"，而是：**在丢包场景里，一次运行不是一个测量。**

而这条发现之所以能出现，是因为先修了另一个问题：同一种子只保证同样的随机源，不保证同样的丢包位置。链路原来按发送顺序抽签，两个算法发送顺序不同，遇到的根本是两串丢包；现在丢包跟着**包的身份**走，两行遇到同一串丢失的数据，比较才第一次成为受控实验。在受控之前，同一次对比显示 CUBIC 快 7.9 倍——那个数字也是不可信的，只是碰巧方向"好看"。

一个可复现实验平台的价值不在于它产出漂亮的对比图，而在于它有能力推翻自己上一版的说法。这一轮它推翻了两版：先是那个 7.9 倍，然后是这张单次运行的表。

## 实验是文件，不是代码

上面那些对比最早都写在 `main.mbt` 里。现在它们是一个个可以打开、修改、重跑的文档：

```bash
moon run cmd/moonnet -- list
moon run cmd/moonnet -- run scenarios/long-fat.json --cc reno
moon run cmd/moonnet -- run scenarios/long-fat.json --cc cubic
moon run cmd/moonnet -- run scenarios/long-fat.json --json > report.json
```

`scenarios/long-fat.json` 里的路径参数换成你自己的，结果就跟着变。一个实验长这样：

```json
{
  "name": "long fat path",
  "seed": 9,
  "payload_bytes": 20000000,
  "algorithm": "reno",
  "uplink":   { "bandwidth_bps": 100000000, "delay_ms": 50, "loss": 0.01, "queue_packets": 2000 },
  "client":   { "mss": 1000, "receive_window": 2000000 }
}
```

只需要写一个方向时，反向链路会沿用同样的参数（`downlink` 可以省略）；两个连接端的字段也都可省略，用文档里写明的默认值。字段写错了会得到带路径的报错，而不是一个静默的默认值——`scenario.uplink.loss must be in [0, 1)` 比"配置无效"有用得多。

`--json` 输出的是固定字段顺序的报告，同一场景跑两次逐字节一致，可以直接进版本库做回归对比。

## 对比与扫描

有了场景文件，比较两个算法就是把同一份文件跑两遍：

```bash
moon run cmd/moonnet -- compare scenarios/long-fat.json --cc reno,cubic
```

```text
scenario:   long fat path (seed 9, 20000000 bytes, 1 run each)

algorithm  mean        fastest     slowest     throughput  retransmits  timeouts
reno       214.129s    214.129s    214.129s         747.2          425        27
cubic      318.218s    318.218s    318.218s         502.7          199        12

note:       loss follows packet identity, so every row meets the same lost
            packets on a given seed. Acknowledgments carry no identity and
            fall back to transmission order, so their losses still differ.
            In a lossy scenario a few sixty-second timeouts dominate the
            total; more than one run is what makes the mean meaningful.
```

那几行 note 不是客套话。**丢包现在跟着包的身份走**：同一个包在同一个链路上永远遇到同样的命运，所以两行遇到的是同一串丢失的数据——这正是"受控实验"的意思。ACK 没有稳定身份（同一个 ACK 会重复发送），仍然按传输顺序抽签，这一条留在注释里而不是被藏起来。

最后一句是这一轮最实用的发现：丢包场景下总时间由少数几次超时主导，而超时按指数退避封顶到 60 秒。同一个场景换一个种子，总时间可以从 214 秒跳到 1162 秒。所以**单次运行不是一个测量**，从这一版起 `compare` 和 `sweep` 都支持 `--seeds N`，报告输出均值与最快/最慢：

```bash
moon run cmd/moonnet -- compare scenarios/long-fat.json --cc reno,cubic --seeds 4
```

扫描一个参数：

```bash
moon run cmd/moonnet -- sweep scenarios/small-buffers.json --field loss --from 0 --to 0.02 --steps 5 --cc reno,cubic
```

```text
scenario:   small buffers, sweeping loss

loss    reno kbit/s  cubic kbit/s
0.0000        919.5         744.4
0.0100        597.2         601.7
0.0200        574.4         414.1

times:
loss    reno    cubic
0.0000  1.740s  2.149s
0.0100  2.678s  2.659s
0.0200  2.785s  3.863s
```

这组数据本身很有意思，而且和前面长肥链路的结论**并不矛盾**：在这个只有 64 KB 接收窗口、64 毫秒往返的场景里，两个算法都被接收窗口限制住了，CUBIC 的保守反而让它更慢。CUBIC 的优势出现在窗口足够大、丢包成为主要限制的地方——也就是长肥链路。**同一组算法，换个场景结论就反过来**，这正是需要一个能改参数的实验平台的原因。

可扫描的字段：`loss`、`delay_ms`、`bandwidth_mbps`、`seed`。

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
