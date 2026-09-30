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
| `src/tcp` | RTO 估计（RFC 6298）、Karn 算法、超时重传与指数退避、NewReno 多丢包恢复、尾部丢包探测 | 完成 |
| `src/tcp` | 可插拔拥塞控制接口、Reno（RFC 5681/6928）、CUBIC（RFC 9438） | 完成 |
| `src/json` | 零依赖的 JSON 读写，供场景文件与报告使用 | 完成 |
| `src/lab` | 场景文件、运行、指标报告、对比与扫描、多流公平性 | 完成 |
| `cmd/moonnet` | 六个子命令：`run` / `plot` / `compare` / `sweep` / `list` / `version` | 完成 |
| `examples/` | 两个用库写成的消费者程序（不含命令行）：`embed_tcp`、`rpc_retry` | 完成 |

**明确不做**：通用仿真框架（用 [moonsim](https://mooncakes.io/docs/zlhahaha/moonsim)）、pcap 解析（已有实现）、与真实网络互操作（用 Mininet）、大规模并发、图形界面。理由写在下面的"与生态中已有工作的关系"。

## 快速开始

需要 [MoonBit 工具链](https://www.moonbitlang.com/download)。**仿真库本身零依赖**；只有命令行工具为了让"实验是文件"这件事成立，引入了官方扩展库 `moonbitlang/x` 来读写文件。`moon test` 会先自动拉取它。

```bash
moon test                        # 运行全部测试
moon run cmd/moonnet -- list     # 列出 scenarios 目录里的实验
moon run cmd/moonnet -- run scenarios/long-fat.json --cc cubic
moon run cmd/moonnet -- run scenarios/bufferbloat-shallow.json --cc reno --trace --json > trace.json
moon run cmd/moonnet -- plot trace.json > trace.svg
moon run cmd/moonnet -- compare scenarios/long-fat.json --cc reno,cubic
moon run cmd/moonnet -- sweep scenarios/small-buffers.json --field loss --from 0 --to 0.02 --steps 5
moon run cmd/moonnet -- sweep scenarios/bufferbloat.json --field queue_packets --from 16 --to 600 --steps 5 --cc reno,cubic --seeds 3
moon run cmd/moonnet -- run scenarios/fairness.json   # 多条流抢一条链路
moon run cmd/moonnet -- run scenarios/bufferbloat.json --discipline codel
```

命令有六个，实验命令都对应可编辑的文件。`plot` 读取已归档的 trace JSON，不会重新运行仿真。

`sweep --field queue_packets` 会把上下行缓冲区设为同一容量并扫描指定范围。`--from` 和 `--to` 必须是正整数；`--steps` 包含两端点，不能超过范围内不同容量的数量。中间点按等距插值后四舍五入到整数。结果除了吞吐和耗时，还汇总上行队列的平均占用、每次运行最大等待时间的跨种子均值，以及所有种子里的最坏等待时间；文本和 JSON 都包含这些指标。均值队列占用按每次运行实际测量时长计算，不把连接结束后的空队列时间计入。

单流场景可用 `--trace` 保留 TCP 状态与队列轨迹。与 `--json` 一起使用时，会输出普通报告、事件轨迹和 `delivery_diagnostics`：把超过 `max(2 × SRTT, 1 ms)` 的连续交付间隔列为停顿，汇总次数、累计时长和最长时长，并为每段标出期间是否观察到排队、重传/恢复事件或发送窗口阻塞。三种信号可以重叠，代表区间内出现过的证据，不把相关性冒充成单一因果。轨迹记录发送、确认、重传、尾部探测和超时时的拥塞窗口、阈值、在途字节、平滑 RTT、RTO，以及上下行队列的包数、字节数和丢弃计数。多流轨迹暂不支持。

`plot <trace.json>` 会把保存的单流轨迹转成可独立打开的 SVG：上图对比拥塞窗口与在途字节，下图对比上下行队列；重传、超时、快速重传和尾部探测用竖线标记，交付停顿用色带标记。同一份 trace JSON 总会生成字节一致的图表，不需要第三方绘图库。

Reno 在浅缓冲队尾连续丢包时，常规重复 ACK 可能不足以暴露最后几个丢失段。TCP 现在会在 RTO 前发一个尾部探测包，用它请求接收端反馈，再交给 NewReno 修复可见的缺口。用路线图中的 3 MB 浅缓冲场景复现，耗时从 10047.347 秒降到 20.242 秒，超时从 192 次降到 4 次；剩余超时仍由 RTO 兜底。

## 作为库使用：命令行只是一个使用者

要做实验的人用命令行；要写自己程序的人直接用库。两者之间没有中间层——命令行是薄薄一层包装，全部逻辑都在包里：

```moonbit
let sim = @sim.Sim::new(seed)                     // 虚拟时钟 + 冻结的随机源
let pair = @tcp.LinkPair::new_with_cc(            // 两个端点 + 两条链路
  sim,
  @tcp.TcpConfig::new(1000, 64000, 1000U),
  @tcp.TcpConfig::new(1000, 64000, 5000U),
  @net.LinkSpec::new("up", 10_000_000L, @sim.Time::from_ms(25L), @net.QueueSpec::packets(64)).with_loss(0.01),
  @net.LinkSpec::new("down", 10_000_000L, @sim.Time::from_ms(25L), @net.QueueSpec::packets(64)).with_loss(0.01),
  seed,
  @tcp.cubic(1000),
)
pair.connect(sim)
pair.client.send(sim, Bytes::make(1_000_000, b'x'))
sim.step_until(() => pair.server.delivered_bytes() == 1_000_000) |> ignore
```

仓库里有两个包专门演示这一点，它们是**库的使用者而不是库的一部分**：

- [`examples/embed_tcp`](examples/embed_tcp/embed.mbt)——不读场景文件、不解析命令行，直接调用协议模型；测试断言同一 seed 两次运行结果一致。
- [`examples/rpc_retry`](examples/rpc_retry/rpc.mbt)——带自己的协议（超时 + 有限重试）复用时钟与链路模型，`moon test` 断言重试预算把未送达的调用从 13/20 降到 4/20。

```bash
moon run examples/embed_tcp/main    # 三个算法跑同一段传输
moon run examples/rpc_retry/main    # 不同丢包率下，一次调用要几次重试
```

包的职责、稳定面与兼容承诺写在 [docs/api.md](docs/api.md)：有内部状态的对象只暴露方法，值是记录，接口清单是随代码进版本库的 `pkg.generated.mbti`。使用 Mooncakes 上的 `0.1.0` 版本时，下游执行 `moon add Ljh684/moonnet-lab@0.1.0`，并在 `moon.pkg` 中导入所需的 `Ljh684/moonnet-lab/src/*` 包。

## 一个例子：同一串丢包，代价差两百倍

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

algorithm  mean       fastest    slowest    throughput  mean queue pkts  mean max wait  worst max wait  retransmits  timeouts
none       129.048s   129.048s   129.048s        12.3              0.0       13.056ms        13.056ms          110         7
reno       662.277ms  662.277ms  662.277ms      2415.9              0.9       10.608ms        10.608ms            2         0
```

不带拥塞控制的发送端把接收端允诺的 64 KB 一次性推进去，而链路队列只能装 16 个报文。队列溢出、丢包；重传又是同样一整批、再次溢出；每次超时还按指数退避翻倍。Reno 一开始只发 10 个报文，之后慢慢加速，队列始终没见到装不下的突发。**同一场景、同一种子、同样的丢包率：195 倍的传输时间差。**

这个倍数在尾部探测落地之前是 5901 倍（无拥塞控制 3908 秒）。那一次改动补上了"成批丢包之后只能靠超时推进"的一段，把无拥塞控制的代价从小时级压到分钟级；但两个数量级的差距还在，拥塞控制该做的事一点没少。

第二个场景换一条长肥链路，先看一次运行：

```text
scenario:   long fat path (seed 9, 20000000 bytes, 1 run each)

algorithm  mean      fastest   slowest   throughput  retransmits  timeouts
reno       154.633s  154.633s  154.633s      1034.7              0.1       17.788ms        17.788ms          371         6
cubic      153.621s  153.621s  153.621s      1041.5              0.0       16.320ms        16.320ms          199         2
```

这条路径的带宽延迟积是 1.25 MB，链路每秒丢 1% 的包，两个算法都被丢包限制住了——差别不在于谁更快发现丢包，而在于**丢了之后丢掉多少**。

Reno 每次丢包把窗口砍一半，然后用一个往返一个报文的速度往回爬。CUBIC 只丢掉 30%，沿着三次曲线往回爬：刚丢包时曲线很陡（那段窗口路径已经证明过），接近丢包前的窗口时变平（再往上就是没有根据的试探）。

**单次运行给出的排序，和多次运行给出的排序并不一致。** 单看上面这一行，两个算法几乎打平（154.6 秒对 153.6 秒）。加上 `--seeds 3` 之后：

```text
algorithm  mean      fastest   slowest    throughput  mean queue pkts  mean max wait  worst max wait  retransmits  timeouts
reno       137.618s  121.599s  154.633s      1162.6              0.1       23.337ms        26.275ms         1049        19
cubic      151.520s  139.516s  161.423s      1055.9              0.0       11.832ms        16.320ms          592         7
```

**到了这一版，这条路径上已经分不出胜负：均值 137.6 对 151.5 秒，两个区间重叠（Reno 121.6–154.6，CUBIC 139.5–161.4），CUBIC 的超时次数少一半以上（7 对 19）。** 这个数字和上一版的"CUBIC 快 3.2 倍"是同一份场景、同一条命令——变化来自尾部探测：它替 Reno 补上了"最后几个丢失段只能等超时"的那一段，而 CUBIC 本来就不太受这一点影响，于是差距被抹平了。

这一轮真正学到的东西不是"谁更快"——它甚至换过一次方向——而是：**在丢包场景里，一次运行不是一个测量；而在协议还在改的时候，任何对比结论都有保质期。**

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
| RED | 600 包 | 11.826s | 2029.3 kbit/s | 978.7 ms | 292 次（41 次提前） | 1 |
| drop-tail | 64 包 | 7.403s | 3241.7 kbit/s | 104.4 ms | 134 次（全部在队尾） | 0 |

三条结论，一条比一条不好听：

1. **深缓冲区不等于更有余量，它更慢。** 同一条路径、同一份数据，缓冲区从 64 个包加到 600 个包：传输从 7.4 秒涨到 16.6 秒，最坏排队延迟从 104 毫秒涨到 979 毫秒。全程 0 次超时、614 次快速重传——代价来自 CUBIC 对"一次溢出里成批丢失"的恢复，以及被自己的队列拉到近一秒的往返时间，不是定时器。
2. **CoDel 修的正是这件事，而且吞吐更高。** 它在缓冲区还空着一大半时就开始拒绝包（34 次拒绝全部是提前丢弃），发送端随之收缩窗口，队列不再站着：最坏排队延迟降到 226 毫秒，传输快了 3.3 倍，吞吐从 1445 涨到 4758 kbit/s（同一条 5 Mbps 链路的 95%）。
3. **RED 曾经在这条路径上把连接锁死，现在不会了。** 同一份场景、同一条命令，上一版是 5.4 小时 / 326 次超时，这一版是 11.8 秒 / 1 次超时——比 drop-tail 的 16.6 秒还快，但仍然明显不如 CoDel。原因是 RED 的判定量"平均占用"只在包到达时更新：单条流停止发包后，这个平均值降不下来，于是新的重传一到就被拒绝，连接只能靠 60 秒定时器推进。修复是补上 Floyd 描述里的那一项——平均占用按**空闲了多久**衰减，而"多久"用队列自己测到的发包间隔换算成"这段时间本来能到多少包"。测试里钉了两件事：队列排空并静置一秒后，下一个包必须被接收；以及这份场景的端到端结果。

这一条也是这个项目想留下的东西：**上一版记录的"RED 锁死"不是对 RED 策略的一般结论，而是一处实现缺陷，缺陷修掉之后结论就变了。** 库里同时保留修复前后的复现方式（修复前的数字记在路线图 M10 的待查项里），避免把一段历史当成策略的性质。

这张表把算法固定在 CUBIC。换 `--cc reno` 会得到另一幅图景：深缓冲区下 drop-tail 16.303s、CoDel 36.271s（Reno 对每一次丢弃都减半窗口，零星丢弃比成批队尾丢弃更贵）。64 包缓冲区下，旧版在成批队尾丢包后靠定时器推进，曾耗时 10047.347s、超时 192 次；加入尾部探测后，同一场景为 20.242s、4 次超时。前一组数值保留为修复前的对照，不代表当前版本的运行结果。

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
examples/      用库写的两个程序（下游的样子）
scenarios/     可编辑的实验文件
docs/          设计说明、路线图、生态定位、验证方式、接口契约、申报书
```

文档分工：[docs/api.md](docs/api.md) 写包职责、稳定面与兼容承诺，[docs/design.md](docs/design.md) 写设计取舍，[docs/roadmap.md](docs/roadmap.md) 写里程碑与验收方式，[docs/positioning.md](docs/positioning.md) 写与已有生态的关系，[docs/verification.md](docs/verification.md) 写怎么验证，[docs/proposal.md](docs/proposal.md) 是提交用的申报书。

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

moonnet-lab is a deterministic packet-level network simulator and TCP congestion-control laboratory written in MoonBit, with no third-party dependencies. Given a topology, a traffic pattern and a seed, a run produces byte-identical event ordering, random draws and metrics. Virtual time is an exact integer in picoseconds, events are ordered by `(time, arrival sequence)`, and the PRNG is frozen with pinned reference vectors. The kernel, the link layer with three queue disciplines (drop-tail, RED, CoDel), the TCP stack with Reno and CUBIC, and the experiment layer (scenarios, comparison, sweep, fairness) are covered by the test suite. The command line tool is one consumer of the library: the two packages under `examples/` are consumers that never touch it, and [docs/api.md](docs/api.md) states what a downstream project may rely on and what is an implementation detail.

## License

Apache-2.0
