# moonnet-lab

**一个用 MoonBit 写的、确定性的数据包级网络仿真与 TCP 拥塞控制实验平台。**

同一个场景、同一个随机种子，无论跑多少次、在哪个后端跑，事件顺序、随机数和每一个指标都完全一致。这让"改一个参数，看吞吐变化"从经验判断变成可复现的实验。

## 它解决什么问题

调拥塞控制、评估缓冲区大小、判断链路丢包时该选哪个算法，这些问题的答案通常来自真实设备上的试错，或者来自一次无法复现的临时脚本。两者都有同一个毛病：换一台机器、换一次运行，数字就变了。

moonnet-lab 把网络行为建模成纯函数：给定拓扑、流量、参数和随机种子，输出确定的事件序列和指标。于是三件事同时变得可能——对比不同拥塞控制算法、回溯上一次实验为什么得出那个结论、把结论当成回归测试固化下来。

## 给谁用

- **学与教拥塞控制的人**：把公式变成能动手的实验，不需要 Mininet，不需要 root，不需要 Linux。
- **设计与评估协议和算法的人**：写一个算法就是实现一个 7 方法的接口；库自带 RFC 标准实现作为对照基线，丢包按包身份决定，两行遇到的是同一串丢包。
- **将来做 MoonBit 网络栈的人**：把它当作回归测试台——MoonBit 目前没有网络协议栈，一旦有人开始写，最先需要的就是能在 `moon test` 里跑的确定性验证环境。

## 当前状态

这是一个 MVP：只做一件事的两端——链路物理与传输协议行为，以及跑实验的最小装置。

| 模块 | 内容 | 状态 |
| --- | --- | --- |
| `src/sim` | 虚拟时间、确定性事件队列、可复现随机源 | 完成 |
| `src/net` | 数据包、有界队列（drop-tail / RED / CoDel）、链路（带宽/延迟/抖动/丢包） | 完成 |
| `src/tcp` | 连接状态机、三次握手、序号与累计确认、滑动窗口、乱序重组 | 完成 |
| `src/tcp` | RTO 估计（RFC 6298）、Karn 算法、超时重传与指数退避、快速重传与多丢包恢复 | 完成 |
| `src/tcp` | 可插拔拥塞控制接口、Reno（RFC 5681/6928）、CUBIC（RFC 9438） | 完成 |
| `src/json` | 零依赖的 JSON 读写，供场景文件与报告使用 | 完成 |
| `src/lab` | 场景文件、运行、指标报告、对比与扫描、多流公平性 | 完成 |
| `cmd/moonnet` | 五个子命令：`run` / `compare` / `sweep` / `list` / `version` | 完成 |

**明确不做**：通用仿真框架（用 [moonsim](https://mooncakes.io/docs/zlhahaha/moonsim)）、pcap 解析（已有实现）、与真实网络互操作（用 Mininet）、大规模并发、图形界面。理由写在下面的"与生态中已有工作的关系"。

## 快速开始

需要 [MoonBit 工具链](https://www.moonbitlang.com/download)。**仿真库本身零依赖**；只有命令行工具为了让"实验是文件"这件事成立，引入了官方扩展库 `moonbitlang/x` 来读写文件。`moon test` 会先自动拉取它。

```bash
moon test                        # 运行全部测试
moon run cmd/moonnet -- list     # 列出 scenarios 目录里的实验
moon run cmd/moonnet -- run scenarios/long-fat.json --cc cubic
moon run cmd/moonnet -- compare scenarios/long-fat.json --cc reno,cubic
moon run cmd/moonnet -- sweep scenarios/small-buffers.json --field loss --from 0 --to 0.02 --steps 5
moon run cmd/moonnet -- run scenarios/fairness.json   # 多条流抢一条链路
moon run cmd/moonnet -- run scenarios/bufferbloat.json --discipline codel
```

命令只有五个，每个都对应一份可编辑的场景文件。**五个子命令就是全部接口**：一件事只有一种做法。

## 一个例子：同一个丢包，代价差二十倍

丢包出现在握手阶段时，连接要多花整整一秒。TCP 建立初期必须按最坏情况估计超时（RFC 6298 规定初始 RTO 为 1 秒），而握手报文的后面没有任何报文在飞，收不到重复 ACK，只能等定时器。

丢包出现在数据传输阶段时，代价只有大约一个往返时间。因为丢失报文后面还有六七个报文陆续到达，接收端每收到一个就重复发一次 ACK；第三次重复 ACK 一到，发送端立刻重传，不等超时。这就是快速重传。

换句话说，救回一个丢包靠的不是"更聪明地等待"，而是"手上有别的证据"。

把 `scenarios/lossy-transfer.json` 里的 `loss` 从 `0.01` 改成 `0` 再跑一次，就能看到同一个传输在两个阶段的区别。超时之后 RTO 会翻倍、窗口会塌回一个报文——慢下来是刻意的，下一节说明它为什么必须这么慢。

## 拥塞控制：为什么必须慢下来

第一个场景把同一条路跑两遍，唯一区别是发送端**是否对丢包做出反应**：

```bash
moon run cmd/moonnet -- compare scenarios/small-buffers.json --cc none,reno
```

```text
scenario:   small buffers (seed 9, 200000 bytes, 1 run each)

algorithm  mean       fastest    slowest    throughput  retransmits  timeouts
none       3908.214s  3908.214s  3908.214s         0.4          105        70
reno       662.277ms  662.277ms  662.277ms      2415.9            2         0
```

不带拥塞控制的发送端把接收端允诺的 64 KB 一次性推进去，而链路队列只能装 16 个报文。队列溢出、丢包；重传又是同样一整批、再次溢出；每次超时还按指数退避翻倍，一路涨到分钟级。200 KB 的数据传了 65 分钟——这就是 1986 年让互联网差点瘫掉的拥塞崩溃，在 200 行代码里复现了一遍。Reno 一开始只发 10 个报文，之后慢慢加速，队列始终没见到装不下的突发。**同一场景、同一种子、同样的丢包率：5901 倍的传输时间差。**

第二个场景换一条长肥链路，先看一次运行：

```text
scenario:   long fat path (seed 9, 20000000 bytes, 1 run each)

algorithm  mean      fastest   slowest   throughput  retransmits  timeouts
reno       214.129s  214.129s  214.129s       747.2          425        27
cubic      318.218s  318.218s  318.218s       502.7          199        12
```

这条路径的带宽延迟积是 1.25 MB，链路每秒丢 1% 的包，两个算法都被丢包限制住了——差别不在于谁更快发现丢包，而在于**丢了之后丢掉多少**。

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

## 多条流抢一条链路

算法在单条连接上的快慢只是问题的一半；另一半是几条流同时抢一条链路时会怎样——这正是拥塞控制最初要解决的问题。场景文件里写 `flows`，多条流就会共用同一条上行链路和同一个队列：

```json
"flows": [ { "algorithm": "reno", "count": 2 }, { "algorithm": "cubic", "count": 2 } ]
```

```bash
moon run cmd/moonnet -- run scenarios/fairness.json
```

```text
scenario:   fairness: two reno against two cubic (seed 9, 4 flows sharing one path, 10.000s window)

flow    algorithm  delivered  share %  kbit/s  retransmits  timeouts
flow 0       reno    3789000     31.0  3031.2            0         0
flow 1       reno    1062987      8.7   850.3           62         0
flow 2      cubic    3777000     30.9  3021.6            0         0
flow 3      cubic    3564000     29.2  2851.2            4         0

total:      12192987 bytes
fairness:   0.8754 (Jain index over the shares above)
uplink:     65 dropped at the queue, 1 lost on the wire
```

三点值得说明，因为每一处都容易看错：

- **测量在窗口处停止，不再排空事件队列。** 退出窗口后如果继续跑，迟到的 ACK 会释放更多数据，总量会描述一个比报告窗口长得多的区间——第一版就是这么错的：20 MB 数据"在 5 秒内"通过了 10 Mbps 链路。
- **Jain 指数只在所有流都还有数据要发时才说明问题。** 报告里有一个饱和标记：若某条流把申报的量发完了，它退出竞争，份额数字反映的是申报量而不是路径。
- **同一算法的两条流不必然均分。** 跨 9–12 四个种子，两条 CUBIC 流始终拿到两条 Reno 流约两倍的份额（合计 7.3–9.2 MB 对 3.9–4.8 MB），但同算法内部谁多谁少随种子改变，Jain 指数在 0.77–0.93 之间。也就是说"混合部署里 CUBIC 更占优"是稳定结论，"哪条流排第一"不是。

先看聚合吞吐：12.19 MB / 10 秒 ≈ 9.75 Mbps，链路利用率 97%。这个数对得上，再看份额怎么分。

## 缓冲区该多深：同一段传输，四种队列策略

拥塞控制决定发送端多快，队列决定这些包在链路上等多久。到这一版为止，队列可以按三种策略管理：`drop-tail`（满了才丢，设备默认）、`red`（按平均占用概率提前丢）、`codel`（按队头等待时间提前丢）。策略写在场景文件里，和带宽、延迟并排：

```json
"uplink": { "bandwidth_bps": 5000000, "delay_ms": 10, "queue_packets": 600, "discipline": "codel" }
```

`scenarios/bufferbloat.json` 描述的是一条典型的家用上行：5 Mbps、10 毫秒传播延迟、缓冲区 600 个包（约一秒的排队空间）、3 MB 传输。**拥塞控制固定为 CUBIC，只换队列策略**——否则比较的是两个变量：

```bash
moon run cmd/moonnet -- run scenarios/bufferbloat.json                        # drop-tail
moon run cmd/moonnet -- run scenarios/bufferbloat.json --discipline codel
moon run cmd/moonnet -- run scenarios/bufferbloat.json --discipline red
moon run cmd/moonnet -- run scenarios/bufferbloat-shallow.json                # 同一条路径，缓冲区 64 个包
```

| 队列策略 | 缓冲区 | 传输耗时 | 吞吐 | 最坏排队延迟 | 队列丢弃 | 超时 |
| --- | --- | --- | --- | --- | --- | --- |
| drop-tail | 600 包 | 16.610s | 1444.9 kbit/s | 978.7 ms | 614 次（全部在队尾） | 0 |
| CoDel | 600 包 | 5.044s | 4757.7 kbit/s | 226.4 ms | 34 次（全部提前） | 0 |
| RED | 600 包 | 19273.903s | 1.2 kbit/s | 978.7 ms | 329 次（192 次提前） | 326 |
| drop-tail | 64 包 | 7.403s | 3241.7 kbit/s | 104.4 ms | 134 次（全部在队尾） | 0 |

三条结论，一条比一条不好听：

1. **深缓冲区不等于更有余量，它更慢。** 同一条路径、同一份数据，缓冲区从 64 个包加到 600 个包：传输从 7.4 秒涨到 16.6 秒，最坏排队延迟从 104 毫秒涨到 979 毫秒。全程 0 次超时、614 次快速重传——代价来自 CUBIC 对"一次溢出里成批丢失"的恢复，以及被自己的队列拉到近一秒的往返时间，不是定时器。
2. **CoDel 修的正是这件事，而且吞吐更高。** 它在缓冲区还空着一大半时就开始拒绝包（34 次拒绝全部是提前丢弃），发送端随之收缩窗口，队列不再站着：最坏排队延迟降到 226 毫秒，传输快了 3.3 倍，吞吐从 1445 涨到 4758 kbit/s（同一条 5 Mbps 链路的 95%）。
3. **RED 在这条路径上把连接锁死了。** 3 MB 数据用了 5.4 小时，326 次超时。RED 的判定量是"到达时更新的平均占用"：单条流把平均值推过上限之后，发送端停止发包，而这个平均值只能被**到达的包**推低，于是每 60 秒一次的定时器重传刚一到就被拒绝。换个拥塞控制也一样（`--cc reno` 是 17128.905s / 294 次超时），所以这是队列策略的性质，不是某个算法的性质。

第 3 条是这一轮最想记录的结果：它不是设计出来的结论，而是跑出来的。RED 的这种锁死（以及"它为什么需要 gentle/ARED 这类改良"）在文献里有记载，但把它和 CoDel 放在同一份场景文件、同一份报告格式下对照，是文档读不出来的东西——**这正是"能改参数的实验台"和"读文档"的区别。**

这张表把算法固定在 CUBIC。换 `--cc reno` 会得到另一幅图景，而且比这张表更值得警惕：深缓冲区下 drop-tail 16.303s、CoDel 36.271s（Reno 对每一次丢弃都减半窗口，零星丢弃比成批队尾丢弃更贵）；64 包缓冲区下 drop-tail 要 10047.347s、192 次超时。后一个数字我们**没有把握解释**，它和路线图里那个尚未查清的问题（成批丢失后只能靠定时器推进）很可能是同一件事。数据留在这里，解释等查清再写。

## 确定性是怎么保证的

1. **时间是整数。** 虚拟时间以皮秒计数，存成 `Int64`。整个仿真里没有一处用浮点数做调度决策，因此不存在两个后端舍入到不同结果的可能。
2. **事件顺序有唯一解。** 事件队列按 `(时间, 到达序号)` 排序，同一皮秒内先调度的事件先执行。没有哈希遍历、没有墙钟、没有并发。
3. **随机数是冻结的。** 自带 SplitMix64 + xoshiro256**，参考向量在测试里钉死。每条链路、每条流用 `fork(label)` 从主种子派生独立随机流，所以新增一条无关的流不会扰动其他流的随机序列。
4. **事件处理里不分配内存。** 队列用环形缓冲、容量按需增长，运行期间不分配，避免宿主内存管理影响时间行为。

违反这些约定的代码会被测试抓住：`src/sim/sim_test.mbt` 里既有随机数参考向量，也有"同一场景跑两遍逐字节一致"的断言。

## 目录结构

```text
src/sim/       虚拟时间、事件内核、随机源
src/net/       数据包、队列（含队列管理策略）、链路
src/tcp/       连接状态机、重传与恢复、拥塞控制
src/json/      零依赖 JSON 读写
src/lab/       场景、报告、对比与扫描、多流公平性
cmd/moonnet/   命令行入口
scenarios/     可编辑的实验文件
docs/          设计说明、路线图、生态定位、验证方式、申报书
```

文档分工：[docs/design.md](docs/design.md) 写设计取舍，[docs/roadmap.md](docs/roadmap.md) 写里程碑与验收方式，[docs/positioning.md](docs/positioning.md) 写与已有生态的关系，[docs/verification.md](docs/verification.md) 写怎么验证，[docs/proposal.md](docs/proposal.md) 是提交用的申报书。

## 与生态中已有工作的关系

MoonBit 生态里已经有几款通用离散事件仿真引擎，也有 pcap 与协议头解析库。moonnet-lab 不去重做这两件事：它不提供通用 DES 抽象，也不解析真实抓包文件，而是专注在**网络行为语义**这一层——链路怎样串行化、队列在什么条件下丢包、TCP 在丢包后如何调整窗口。

具体的分工可以拿 [`zlhahaha/moonsim`](https://mooncakes.io/docs/zlhahaha/moonsim)（生态里最完整的确定性仿真框架）对照着看。它的定位是**软件可靠性模型测试**：用虚拟时间、故障注入、invariant、稳定 trace digest 和失败重放，测试消息、队列、任务编排、定时器、状态机与外部调用。它的网络模型是一个抽象消息层——`network_config(seed, messages, latency_min, latency_max, drop_percent, retry_delay)`，延迟是在区间里抽样的 tick 数；队列模型是排队论意义上的顾客与服务时间。这套抽象对"我的服务在乱序、重复和超时下是否还满足规则"完全够用，而且它的覆盖面比本项目宽得多。

两者的差别在建模层次，不在谁更"仿真"：

| | moonsim | moonnet-lab |
| --- | --- | --- |
| 时间单位 | 抽象 tick | 皮秒整数，可手算校验（1500 字节 @ 10 Mbps = 1.2 毫秒） |
| 网络模型 | 消息延迟区间 + 丢弃百分比 | 带宽、传播延迟、抖动、按字节与包数限制的队列 |
| 队列 | 排队论模型（顾客、服务时间、到达间隔） | 有界缓冲区 + 队列管理策略（drop-tail / RED / CoDel），排队延迟是可测量 |
| 协议内容 | 通用事件类型（消息/任务/定时器/状态转移/外部调用） | TCP 状态机、RTO 估计（RFC 6298）、快速重传与多丢包恢复 |
| 算法内容 | 重试、熔断、限流、负载均衡等可靠性模式 | Reno（RFC 5681/6928）、CUBIC（RFC 9438）等拥塞控制算法 |
| 用途 | 让服务里偶发的失败可复现，进 CI 回归 | 回答"这条路径上哪个算法更好、缓冲区该多大" |

一句话：**moonsim 让"我的服务会不会出错"变成可复现的测试，本项目让"网络在这组参数下会怎样"变成可复现的实验。** 前者的核心是 invariant 与失败证据，后者的核心是物理量（字节、比特率、微秒）与协议标准。两者共享"确定性虚拟时间 + 种子"这个基础想法——这个想法在 MoonBit 生态里被两个不同层次的项目采用，本身就说明它是对的。

队列那一条是这套差别里最锋利的地方，值得单独说清楚。moonsim 的队列是排队论意义上的"顾客与服务时间"：它回答"要排多久才轮到"，不回答"排队本身改变了网络的行为吗"。本项目的队列是链路的一部分——**包在缓冲区里等待的时间就是端到端的延迟**，而缓冲区多大、满了怎么丢，会反过来改变发送端的窗口决策。上面那节的结果就是这个回路的产物：同一条 5 Mbps 链路、同一份 3 MB 数据、同一个拥塞控制，只把"满了才丢"换成"等待超时就提前丢"，传输时间从 16.6 秒变成 5.0 秒。moonsim 的模型里既没有"拥塞窗口"也没有"队头等待时间"，这两个量都不存在，所以它结构上产不出这个结论——不是它做得不够好，是它研究的对象不同。

具体到本项目能回答、而通用仿真框架结构上回答不了的问题，有四类：

1. **物理量可核对**：时间是皮秒整数、队列按字节计量，所以"1500 字节的帧在 10 Mbps 链路上占 1.2 毫秒"是能手算验证并写成断言的，不是抽样出来的参数。
2. **协议与算法本身**：TCP 状态机、RFC 6298 的 RTO 估计、Karn 算法、快速重传与多丢包恢复、Reno 与 CUBIC。通用框架里没有"拥塞窗口"这个概念。
3. **网络工程问题**：这条路径上哪个算法更好、缓冲区该多大（深缓冲区比浅缓冲区慢一倍是这一版测出来的）、队列该用什么策略、多条流怎么分带宽。
4. **受控实验**：丢包按包身份决定（两行遇到同一串丢包）、场景文件、固定字段顺序的报告、多种子平均——结论能被复算，也能被推翻。

更完整的论证（含"为什么不把这些做成 moonsim 的补丁"、与 Mininet / ns-3 的分工、以及立项前的生态扫描）写在 [docs/positioning.md](docs/positioning.md)。

## English summary

moonnet-lab is a deterministic packet-level network simulator and TCP congestion-control laboratory written in MoonBit, with no third-party dependencies. Given a topology, a traffic pattern and a seed, a run produces byte-identical event ordering, random draws and metrics. Virtual time is an exact integer in picoseconds, events are ordered by `(time, arrival sequence)`, and the PRNG is frozen with pinned reference vectors. The kernel, the link layer with three queue disciplines (drop-tail, RED, CoDel), the TCP stack with Reno and CUBIC, and the experiment layer (scenarios, comparison, sweep, fairness) are complete and tested; 95 tests pass on a clean runner.

## License

Apache-2.0
