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
  sim.run()
  let handshake_done = sim.now()
  let payload = Bytes::make(20_000, b'x')
  pair.client.send(sim, payload)
  sim.run()
  let transfer = sim.now() - handshake_done
  println(version_line())
  println("")
  println("handshake completed at " + handshake_done.render())
  println(
    "transferred " +
    pair.server.delivered().length().to_string() +
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
