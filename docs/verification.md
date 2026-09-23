# 怎么验证

一句话：`moon test` 全绿，CI 在干净的 Linux runner 上跑同一套命令；本文档里的每一个数字都来自仓库里的一份场景文件，命令写在数字旁边。

## 一、测试（102 个，`moon test`）

按覆盖的东西分组，不是按文件分组：

| 层 | 断言的东西 |
| --- | --- |
| 时间与事件 | 皮秒换算、事件按 `(时间, 到达序号)` 排序、堆行为、`step_until` 停在指定事件而不是排空队列 |
| 随机源 | SplitMix64 与 xoshiro256** 的参考向量钉死；`fork(label)` 派生独立流，新增一条流不扰动其他流 |
| 链路与队列 | 链路串行化（1500 字节 @ 10 Mbps = 1.2 毫秒）、背靠背包排队、抖动可复现；队列按包数与字节双限制、环形缓冲回绕、三种队列管理策略谁会在缓冲区未满时丢、CoDel 的控制律何时动手 |
| TCP | 握手与状态机、序号与累计确认、滑动窗口与在途字节、乱序重组与重复段裁剪、RTO 估计（RFC 6298）、Karn 算法、超时退避、快速重传触发阈值、多丢包恢复、主动/被动关闭与 TIME-WAIT |
| 拥塞控制 | Reno 的初始窗口公式、慢启动翻倍、超时后塌回单窗、快速恢复的减半与膨胀；CUBIC 的三次曲线、0.7 倍减少、Reno 友好区、超时后崩塌与回升 |
| 实验层 | 场景解析、默认值、字段拼写错误的报错消息、报告字段顺序、`compare` / `sweep` / 多种子汇总、Jain 指数端点、场景只换队列策略时排队延迟减半 |
| 消费者 | 两个示例包（`examples/embed_tcp`、`examples/rpc_retry`）断言：同一 seed 两次运行结果一致、换算法在指标上看得见、重试预算把未送达的调用从 13/20 降到 4/20 |

其中两条是**限制**而不是成果，同样被断言下来，因为它们都是量出来的：固定速率的信源下，CoDel 会把队列提前丢包，但最坏的等待几乎不变（496.5 毫秒对 500.0 毫秒）——队列策略决定丢哪些包，不决定有多少流量到达；而跨运行比较缓冲区平均占用是不成立的，drop-tail 那次运行长三倍、期间大量空闲，平均值反而更低。

## 二、物理量断言

聚合吞吐不得超过"带宽 × 时间窗"。这条断言在开发中抓出过一次真实错误：测量窗口到期后仍然排空事件队列，迟到的 ACK 释放了更多数据，于是 20 MB 数据"在 5 秒内"通过了 10 Mbps 链路——物理上不可能，却被报告写成了结论。

同类检查还有两处：**忙时等于报文长度之和除以带宽**（十个 1500 字节的包占用 10 Mbps 链路，恰好 12 毫秒，不是"大约"）；**丢弃次数与两种丢弃原因对得上**（`dropped == dropped_early + dropped_at_tail`）。

## 三、确定性

三层，缺一层结论就不可复算：

1. **随机数**：参考向量钉死在测试里，换后端得到同一串数。
2. **同一场景跑两遍**：报告逐字节一致（`first.to_json_text() == second.to_json_text()`）。
3. **丢包位置可控**：丢包跟着包的身份走（起始序号 + 第几次发送的混合），所以两行在同一个种子上遇到的是同一串丢失的数据；ACK 没有稳定身份，退回按传输顺序抽签，这一条写在输出里而不是藏起来。

## 四、端到端

CI（`.github/workflows/ci.yml`）在干净的 Linux runner 上依次执行：`moon fmt --check`、`moon check`、`moon test`，然后真正把命令行跑起来——`list` 列场景、`compare` 在长肥链路上对比两种算法、`run --discipline codel` 跑缓冲区实验。也就是说场景文件、报告格式和命令行本身都在 CI 覆盖范围内，不只是库函数。

同一份 CI 还会运行两个**不使用命令行**的消费者包（`examples/embed_tcp`、`examples/rpc_retry`）。这一条是"库可以被别的程序依赖"这句话的验证方式：如果哪天库的接口只对 `cmd/moonnet` 可用、对普通调用者不可用，这两个步骤会先失败。

## 五、复现本文档与 README 里的数字

```bash
moon run cmd/moonnet -- compare scenarios/long-fat.json --cc reno,cubic --seeds 3
moon run cmd/moonnet -- run scenarios/fairness.json
moon run cmd/moonnet -- run scenarios/bufferbloat.json
moon run cmd/moonnet -- run scenarios/bufferbloat.json --discipline codel
moon run cmd/moonnet -- run scenarios/bufferbloat.json --discipline red
moon run cmd/moonnet -- run scenarios/bufferbloat-shallow.json
moon run cmd/moonnet -- sweep scenarios/small-buffers.json --field loss --from 0 --to 0.02 --steps 5 --cc reno,cubic
```

 每个场景文件都是普通 JSON，改一个字段再跑一遍就是一次新实验；`--json` 输出的报告字段顺序固定，可以直接进版本库做回归对比。

两个消费者示例：

```bash
moon run examples/embed_tcp/main    # 三个算法跑同一段传输，直接调用协议模型
moon run examples/rpc_retry/main    # 不同丢包率下，一次调用要几次重试
```

## 六、还没验证的地方

写在这里而不是省略：延迟 ACK、SACK、重排序检测没有实现；队列只有一个出队口，没有 AQM 的多队列/加权形态；协议行为按 RFC 实现，不等于真实内核。已知边界与两个未查清的问题记在 [roadmap.md](roadmap.md)。
