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
  println("  version   print the version")
  println("  help      print this message")
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
