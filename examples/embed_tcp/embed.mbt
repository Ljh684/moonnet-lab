///| Embedding the protocol model in your own program.
///
/// Nothing here reads a scenario file or parses an argument: the library is
/// called directly, which is what a downstream project does when it wants a
/// deterministic answer to a network question inside its own tooling or test
/// suite. Ten lines to a measurement, and the same seed always gives the same
/// answer.

///|
/// One direction of the path, in the units the library speaks.
pub fn link(name : String, loss : Double) -> @net.LinkSpec {
  @net.LinkSpec::new(
    name,
    10_000_000L,
    @sim.Time::from_ms(25L),
    @net.QueueSpec::packets(64),
  ).with_loss(loss)
}

///|
/// What one embedded run measured.
pub(all) struct Transfer {
  algorithm : String
  delivered_bytes : Int
  elapsed : @sim.Time
  retransmits : Int
  timeouts : Int
  srtt : @sim.Time
} derive(Eq, Debug)

///|
/// Transfer `bytes` with the named algorithm over a path that drops `loss` of
/// the packets, and report what it cost.
pub fn transfer(
  algorithm : &@tcp.CongestionControl,
  bytes : Int,
  loss : Double,
  seed : UInt64,
) -> Transfer {
  let sim = @sim.Sim::new(seed)
  let mss = 1000
  let pair = @tcp.LinkPair::new_with_cc(
    sim,
    @tcp.TcpConfig::new(mss, 64000, 1000U),
    @tcp.TcpConfig::new(mss, 64000, 5000U),
    link("up", loss),
    link("down", loss),
    seed,
    algorithm,
  )
  // The clock is read around the transfer rather than at the end of the run:
  // the connection keeps leaving superseded timer events behind, and draining
  // them would measure the last of those instead of the transfer.
  let start = sim.now()
  pair.connect(sim)
  sim.step_until(() => pair.client.state() == @tcp.Established) |> ignore
  pair.client.send(sim, Bytes::make(bytes, b'x'))
  sim.step_until(() => pair.server.delivered_bytes() == bytes) |> ignore
  {
    algorithm: pair.client.cc_name(),
    delivered_bytes: pair.server.delivered_bytes(),
    elapsed: sim.now() - start,
    retransmits: pair.client.retransmits(),
    timeouts: pair.client.timeouts(),
    srtt: match pair.client.srtt() {
      Some(value) => value
      None => @sim.Time::zero()
    },
  }
}

///|
/// The algorithms the library ships, by name, so a caller that has a string
/// from a config file does not have to know the constructors.
pub fn algorithm(name : String, mss : Int) -> &@tcp.CongestionControl {
  match name {
    "cubic" => @tcp.cubic(mss)
    "none" => @tcp.without_congestion_control()
    _ => @tcp.reno(mss)
  }
}

///|
/// A report line, so the entry point stays a few lines long.
pub fn Transfer::to_line(self : Transfer) -> String {
  self.algorithm +
  "  " +
  self.delivered_bytes.to_string() +
  " bytes in " +
  self.elapsed.render() +
  ", " +
  self.retransmits.to_string() +
  " retransmits, " +
  self.timeouts.to_string() +
  " timeouts, srtt " +
  self.srtt.render()
}
