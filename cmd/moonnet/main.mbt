///|
/// The command line front end.
///
/// The interface is deliberately boring: one subcommand per experiment, text in,
/// text out, and every number printed comes from the same library the tests
/// exercise. `run` and `compare` grow out of this skeleton as the TCP layer
/// lands; today `demo` already walks the whole stack, from a scenario to a link
/// report.
fn main {
  let args = @env.args()
  let command = if args.length() > 1 { args[1] } else { "help" }
  match command {
    "version" => println(version_line())
    "demo" => demo()
    "tcp" => tcp_demo()
    "lossy" => lossy_demo()
    "cc" => congestion_control_demo()
    "help" | "-h" | "--help" => usage()
    _ => {
      println("unknown command: " + command)
      println("")
      usage()
    }
  }
}

///|
fn version_line() -> String {
  "moonnet-lab 0.1.0 (deterministic packet-level network simulator)"
}

///|
fn usage() -> Unit {
  println(version_line())
  println("")
  println("usage: moonnet <command>")
  println("")
  println("commands:")
  println("  demo      run the built-in three-flow demo and print a report")
  println("  tcp       run a TCP handshake and bulk transfer over two links")
  println("  lossy     run the same transfer over a path that loses packets")
  println(
    "  cc        compare a lossy transfer with and without congestion control",
  )
  println("  version   print the version")
  println("  help      print this message")
}

///|
/// A bulk transfer over a real connection: three-way handshake, then 20 000
/// bytes of application data from client to server, with every segment
/// serialized by the links and acknowledged by the peer.
fn tcp_demo() -> Unit {
  let sim = @sim.Sim::new(1UL)
  let up = @net.LinkSpec::new(
    "up",
    10_000_000L,
    @sim.Time::from_ms(5L),
    @net.QueueSpec::packets(64),
  )
  let down = @net.LinkSpec::new(
    "down",
    10_000_000L,
    @sim.Time::from_ms(5L),
    @net.QueueSpec::packets(64),
  )
  let pair = @tcp.LinkPair::new(
    sim,
    @tcp.TcpConfig::new(1000, 8192, 1000U),
    @tcp.TcpConfig::new(1000, 8192, 5000U),
    up,
    down,
    1UL,
  )
  pair.connect(sim)
  sim.step_until(() => pair.client.state() == @tcp.Established) |> ignore
  let handshake_done = sim.now()
  let payload = Bytes::make(20_000, b'x')
  pair.client.send(sim, payload)
  sim.step_until(() => pair.server.delivered_bytes() == 20_000) |> ignore
  let transfer = sim.now() - handshake_done
  sim.run()
  println(version_line())
  println("")
  println("handshake completed at " + handshake_done.render())
  println(
    "transferred " +
    pair.server.delivered_bytes().to_string() +
    " bytes in " +
    transfer.render() +
    " (" +
    goodput_kbps(20_000, transfer) +
    " kbit/s)",
  )
  println("client: " + pair.client.state().render())
  println("server: " + pair.server.state().render())
  println(
    "segments: " +
    pair.client.segments_sent().to_string() +
    " sent, " +
    pair.client.segments_received().to_string() +
    " received",
  )
}

///|
/// The congestion control comparison: the same lossy path, the same seed, one
/// difference — whether the sender is allowed to ignore congestion.
///
/// The interesting column is not the transfer time. Uncontrolled, the sender
/// pushes into a queue that has already dropped a packet, and the retransmission
/// races the packets behind it. Controlled, it halves its window on the first
/// evidence of loss, which costs throughput here and is the entire reason the
/// network does not collapse when everyone does it at once.
fn congestion_control_demo() -> Unit {
  let seed = 9UL
  println(version_line())
  println("")
  let small_buffer : Scenario = {
    label: "small buffers: 10 Mbps, 25 ms one way, 1% loss, 64 KB window, 16-packet queue",
    bandwidth_bps: 10_000_000L,
    one_way: @sim.Time::from_ms(25L),
    loss: 0.01,
    receive_window: 64_000,
    queue_packets: 16,
    payload_bytes: 200_000,
  }
  let long_fat : Scenario = {
    label: "long fat path: 100 Mbps, 50 ms one way, 1% loss, 2 MB window, 2000-packet queue",
    bandwidth_bps: 100_000_000L,
    one_way: @sim.Time::from_ms(50L),
    loss: 0.01,
    receive_window: 2_000_000,
    // The queue has to be able to hold the bandwidth-delay product, otherwise
    // the sender can never fill the path and the experiment measures the queue
    // rather than the algorithm.
    queue_packets: 2000,
    payload_bytes: 20_000_000,
  }
  println("A. " + small_buffer.label)
  println("   payload " + small_buffer.payload_bytes.to_string() + " bytes")
  println("")
  let collapse = compare(small_buffer, seed, [
    ("none", @tcp.without_congestion_control()),
    ("reno", @tcp.reno(1000)),
  ])
  print_rows(collapse, small_buffer.payload_bytes)
  println("")
  println("   Uncontrolled, the sender pushes the whole 64 KB window into a")
  println(
    "   16-packet queue. It overflows, every retransmission is another full",
  )
  println(
    "   burst that overflows it again, and the connection spends its life",
  )
  println("   waiting out timeouts that back off to a minute each.")
  println("")
  println("   Reno starts with ten segments and grows from there, so the queue")
  println("   never sees a burst it cannot hold.")
  println("")
  println(
    "   Same path, same seed, same loss: " +
    (collapse[0].1.elapsed.ps / collapse[1].1.elapsed.ps).to_string() +
    " times the transfer time.",
  )
  println("")
  println("B. " + long_fat.label)
  println("   payload " + long_fat.payload_bytes.to_string() + " bytes")
  println("")
  let long_path = compare(long_fat, seed, [
    ("reno", @tcp.reno(1000)),
    ("cubic", @tcp.cubic(1000)),
  ])
  print_rows(long_path, long_fat.payload_bytes)
  println("")
  println(
    "   The bandwidth-delay product is 1.25 MB, so every loss costs a lot",
  )
  println(
    "   of window. Reno halves on every loss and then grows by one segment",
  )
  println("   per round trip, so on a path that keeps losing packets it spends")
  println(
    "   most of its time climbing back from a small window — and when a",
  )
  println(
    "   loss is bad enough to time out, it restarts from a single segment.",
  )
  println("")
  println(
    "   CUBIC keeps 70% of the window and climbs back along a cubic curve:",
  )
  println(
    "   steeply at first, because it has already proved the path can carry",
  )
  println("   that traffic, then flattening as it approaches the window it had")
  println("   before the loss.")
}

///|
/// One experimental setup: a path, a loss rate, and how much to send.
struct Scenario {
  label : String
  bandwidth_bps : Int64
  one_way : @sim.Time
  loss : Double
  receive_window : Int
  queue_packets : Int
  payload_bytes : Int
}

///|
/// Run every algorithm through one scenario and return what each produced.
fn compare(
  scenario : Scenario,
  seed : UInt64,
  algorithms : Array[(String, &@tcp.CongestionControl)],
) -> Array[(String, TransferResult)] {
  let results : Array[(String, TransferResult)] = []
  for algorithm in algorithms {
    results.push((algorithm.0, run_transfer_in(scenario, seed, algorithm.1)))
  }
  results
}

///|
/// Print one result per algorithm, aligned.
fn print_rows(
  results : Array[(String, TransferResult)],
  payload_bytes : Int,
) -> Unit {
  for entry in results {
    let result = entry.1
    println(
      "   " +
      entry.0.pad_end(6, ' ') +
      "  " +
      result.elapsed.render().pad_start(10, ' ') +
      "  " +
      goodput_kbps(payload_bytes, result.elapsed).pad_start(8, ' ') +
      " kbit/s  " +
      result.retransmits.to_string().pad_start(4, ' ') +
      " retransmits  " +
      result.timeouts.to_string().pad_start(2, ' ') +
      " timeouts",
    )
  }
}

///|
/// What one run of the bulk transfer produced.
struct TransferResult {
  delivered : Int
  connect_elapsed : @sim.Time
  elapsed : @sim.Time
  retransmits : Int
  fast_retransmits : Int
  timeouts : Int
  rto : @sim.Time
  srtt : @sim.Time?
  samples : Int
  uplink : String
  downlink : String
}

///|
/// Run one bulk transfer in a scenario with a chosen congestion control
/// algorithm.
fn run_transfer_in(
  scenario : Scenario,
  seed : UInt64,
  cc : &@tcp.CongestionControl,
) -> TransferResult {
  let sim = @sim.Sim::new(seed)
  let payload_bytes = scenario.payload_bytes
  let up = @net.LinkSpec::new(
    "up",
    scenario.bandwidth_bps,
    scenario.one_way,
    @net.QueueSpec::packets(scenario.queue_packets),
  ).with_loss(scenario.loss)
  let down = @net.LinkSpec::new(
    "down",
    scenario.bandwidth_bps,
    scenario.one_way,
    @net.QueueSpec::packets(scenario.queue_packets),
  ).with_loss(scenario.loss)
  let pair = @tcp.LinkPair::new_with_cc(
    sim,
    @tcp.TcpConfig::new(1000, scenario.receive_window, 1000U),
    @tcp.TcpConfig::new(1000, scenario.receive_window, 5000U),
    up,
    down,
    seed,
    cc,
  )
  pair.connect(sim)
  let start = sim.now()
  sim.step_until(() => pair.client.state() == @tcp.Established) |> ignore
  let connected_at = sim.now()
  pair.client.send(sim, Bytes::make(payload_bytes, b'x'))
  sim.step_until(() => pair.server.delivered_bytes() == payload_bytes) |> ignore
  let delivered_at = sim.now()
  sim.run()
  {
    delivered: pair.server.delivered_bytes(),
    connect_elapsed: connected_at - start,
    elapsed: delivered_at - start,
    retransmits: pair.client.retransmits(),
    fast_retransmits: pair.client.fast_retransmits(),
    timeouts: pair.client.timeouts(),
    rto: pair.client.rto(),
    srtt: pair.client.srtt(),
    samples: pair.client.rtt_samples(),
    uplink: pair.up.summary(sim),
    downlink: pair.down.summary(sim),
  }
}

///|
/// Run one bulk transfer over a pair of links and collect the numbers.
fn run_transfer(
  seed : UInt64,
  up : @net.LinkSpec,
  down : @net.LinkSpec,
  payload_bytes : Int,
) -> TransferResult {
  let sim = @sim.Sim::new(seed)
  let pair = @tcp.LinkPair::new(
    sim,
    @tcp.TcpConfig::new(1000, 8192, 1000U),
    @tcp.TcpConfig::new(1000, 8192, 5000U),
    up,
    down,
    seed,
  )
  pair.connect(sim)
  let start = sim.now()
  // Stop as soon as the handshake is done, then as soon as the last byte lands.
  // Draining the queue at each step would run the clock out to whatever
  // superseded timer the connection left behind.
  sim.step_until(() => pair.client.state() == @tcp.Established) |> ignore
  let connected_at = sim.now()
  pair.client.send(sim, Bytes::make(payload_bytes, b'x'))
  sim.step_until(() => pair.server.delivered_bytes() == payload_bytes) |> ignore
  let delivered_at = sim.now()
  sim.run()
  {
    delivered: pair.server.delivered_bytes(),
    connect_elapsed: connected_at - start,
    elapsed: delivered_at - start,
    retransmits: pair.client.retransmits(),
    fast_retransmits: pair.client.fast_retransmits(),
    timeouts: pair.client.timeouts(),
    rto: pair.client.rto(),
    srtt: pair.client.srtt(),
    samples: pair.client.rtt_samples(),
    uplink: pair.up.summary(sim),
    downlink: pair.down.summary(sim),
  }
}

///|
/// The same bulk transfer, over a longer path that loses packets in both
/// directions.
///
/// The transfer runs twice over exactly the same path: once clean, once with 1%
/// loss. The difference between the two lines is what retransmission costs, and
/// it is where the RFC 6298 floor on the initial RTO stops being a footnote: a
/// packet that goes missing costs a full second, because a connection is
/// required to assume the worst until it has measured the path.
fn lossy_demo() -> Unit {
  let seed = 9UL
  let payload_bytes = 50_000
  let one_way = @sim.Time::from_ms(25L)
  let up = @net.LinkSpec::new(
    "up",
    10_000_000L,
    one_way,
    @net.QueueSpec::packets(64),
  )
  let down = @net.LinkSpec::new(
    "down",
    10_000_000L,
    one_way,
    @net.QueueSpec::packets(64),
  )
  let clean = run_transfer(seed, up, down, payload_bytes)
  let lossy = run_transfer(
    seed,
    up.with_loss(0.01),
    down.with_loss(0.01),
    payload_bytes,
  )
  println(version_line())
  println("")
  println(
    "path:       10 Mbps, 25 ms one way (50 ms round trip), 8192 B window",
  )
  println(
    "payload:    " + payload_bytes.to_string() + " bytes, 1000-byte segments",
  )
  println("")
  println(
    "clean path: " +
    clean.delivered.to_string() +
    " bytes end to end in " +
    clean.elapsed.render() +
    " (" +
    goodput_kbps(payload_bytes, clean.elapsed) +
    " kbit/s), connect " +
    clean.connect_elapsed.render() +
    ", " +
    clean.retransmits.to_string() +
    " retransmissions",
  )
  println(
    "1% loss:    " +
    lossy.delivered.to_string() +
    " bytes end to end in " +
    lossy.elapsed.render() +
    " (" +
    goodput_kbps(payload_bytes, lossy.elapsed) +
    " kbit/s), connect " +
    lossy.connect_elapsed.render() +
    ", " +
    lossy.retransmits.to_string() +
    " retransmissions (" +
    lossy.fast_retransmits.to_string() +
    " fast, " +
    (lossy.retransmits - lossy.fast_retransmits).to_string() +
    " by timeout)",
  )
  println("")
  println(
    "            " +
    lossy.timeouts.to_string() +
    " timer" +
    (if lossy.timeouts == 1 { "" } else { "s" }) +
    " expired: a handshake packet has no successors, so no duplicate",
  )
  println("            acknowledgments can reveal the hole")
  println("")
  println(
    "estimator:  " +
    lossy.samples.to_string() +
    " round trip samples, RTO " +
    lossy.rto.render(),
  )
  match lossy.srtt {
    Some(srtt) => println("smoothed:   " + srtt.render() + " round trip time")
    None => println("smoothed:   no sample")
  }
  println("uplink:     " + lossy.uplink)
  println("downlink:   " + lossy.downlink)
}

///|
/// Payload throughput, in kilobits per second, ignoring the 60 s TIME-WAIT tail
/// by construction: the caller passes only the transfer interval.
fn goodput_kbps(bytes : Int, duration : @sim.Time) -> String {
  let seconds = duration.ps.to_double() / 1_000_000_000_000.0
  if seconds <= 0.0 {
    "0.0"
  } else {
    let rate = bytes.to_double() * 8.0 / seconds / 1000.0
    let tenths = (rate * 10.0).to_int64()
    (tenths / 10L).to_string() + "." + (tenths % 10L).to_string()
  }
}

///|
/// A worked example that exercises the kernel and the link layer together.
///
/// Three 1500-byte packets, 200 microseconds apart, cross a 10 Mbps uplink with
/// 5 ms of propagation delay. The link serializes 1.2 ms per packet, so the
/// packets queue behind each other and arrive 1.2 ms apart.
fn demo() -> Unit {
  let sim = @sim.Sim::new(1UL)
  let arrivals : Array[String] = []
  let link = @net.Link::new(
    @net.LinkSpec::new(
      "uplink",
      10_000_000L,
      @sim.Time::from_ms(5L),
      @net.QueueSpec::packets(32),
    ),
    1UL,
    _packet => arrivals.push(sim.now().render()),
  )
  let mut index = 0
  while index < 3 {
    link.send(sim, @net.Packet::new(index, 0, @net.Data, 1500, ())) |> ignore
    sim.run_for(@sim.Time::from_us(200L))
    index = index + 1
  }
  sim.run()
  println(version_line())
  println("")
  println("scenario: 3 x 1500 B every 200 us over a 10 Mbps link, 5 ms delay")
  println("arrivals: " + arrivals.join(", "))
  println("link:     " + link.summary(sim))
}
