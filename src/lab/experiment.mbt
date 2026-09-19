///|
/// Everything one run of a scenario measured.
///
/// The fields are the ones that answer the questions an experiment asks: how
/// long it took, how much had to be sent again, and where the window ended up.
pub(all) struct RunReport {
  scenario : String
  algorithm : String
  seed : UInt64
  payload_bytes : Int
  delivered_bytes : Int
  connect : @sim.Time
  elapsed : @sim.Time
  retransmits : Int
  fast_retransmits : Int
  timeouts : Int
  round_trips : Int
  srtt : @sim.Time
  final_cwnd : Int
  final_ssthresh : Int
  uplink_dropped : Int
  /// Of the packets the uplink refused, how many were refused by queue
  /// management rather than by a full buffer.
  uplink_dropped_early : Int
  uplink_lost : Int
  /// How the uplink buffer is managed: `drop-tail`, `red` or `codel`.
  discipline : String
  /// Mean occupancy of the uplink buffer, in packets.
  mean_queue_packets : Double
  /// The longest a packet waited in the uplink buffer.
  max_sojourn : @sim.Time
} derive(Eq, Debug)

///|
/// The congestion control algorithm a name refers to.
pub fn algorithm_of(name : String, mss : Int) -> &@tcp.CongestionControl {
  match name {
    "none" => @tcp.without_congestion_control()
    "cubic" => @tcp.cubic(mss)
    _ => @tcp.reno(mss)
  }
}

///|
/// Build the connection pair a scenario describes.
fn link_of(profile : LinkProfile) -> @net.LinkSpec {
  let base = @net.QueueSpec::packets(profile.queue_packets)
  let queue = match profile.discipline {
    "red" =>
      base.with_discipline(@net.QueueDiscipline::red_for(profile.queue_packets))
    "codel" => base.with_discipline(@net.QueueDiscipline::codel())
    _ => base
  }
  @net.LinkSpec::new(profile.name, profile.bandwidth_bps, profile.delay, queue).with_loss(
    profile.loss,
  )
}

///|
/// Run a scenario from start to finish and collect the measurements.
///
/// The clock is read at three moments rather than at the end: when the handshake
/// completes, and when the last byte reaches the receiver. Draining the event
/// queue first would move the clock past the moment of interest, because a
/// connection leaves superseded timer events behind.
pub fn run(scenario : Scenario) -> RunReport {
  let sim = @sim.Sim::new(scenario.seed)
  let pair = @tcp.LinkPair::new_with_cc(
    sim,
    @tcp.TcpConfig::new(
      scenario.client.mss,
      scenario.client.receive_window,
      scenario.client.initial_seq,
    ),
    @tcp.TcpConfig::new(
      scenario.server.mss,
      scenario.server.receive_window,
      scenario.server.initial_seq,
    ),
    link_of(scenario.uplink),
    link_of(scenario.downlink),
    scenario.seed,
    algorithm_of(scenario.algorithm, scenario.client.mss),
  )
  let start = sim.now()
  pair.connect(sim)
  sim.step_until(() => pair.client.state() == @tcp.Established) |> ignore
  let connected_at = sim.now()
  pair.client.send(sim, Bytes::make(scenario.payload_bytes, b'x'))
  sim.step_until(() => pair.server.delivered_bytes() == scenario.payload_bytes)
  |> ignore
  let delivered_at = sim.now()
  // Read the buffer's mean occupancy here rather than after the drain: the run
  // continues past the last byte until the connection is idle, and averaging
  // over that quiet tail would flatter a buffer that stood full for the whole
  // transfer.
  let mean_queue_packets = pair.up.mean_queue_packets(sim)
  // Drain the rest so that the counters describe a settled connection, then read
  // them. The two timings above were taken before this point.
  sim.run()
  {
    scenario: scenario.name,
    algorithm: pair.client.cc_name(),
    seed: scenario.seed,
    payload_bytes: scenario.payload_bytes,
    delivered_bytes: pair.server.delivered_bytes(),
    connect: connected_at - start,
    elapsed: delivered_at - start,
    retransmits: pair.client.retransmits(),
    fast_retransmits: pair.client.fast_retransmits(),
    timeouts: pair.client.timeouts(),
    round_trips: pair.client.rtt_samples(),
    srtt: match pair.client.srtt() {
      Some(value) => value
      None => @sim.Time::zero()
    },
    final_cwnd: pair.client.cwnd(),
    final_ssthresh: pair.client.ssthresh(),
    uplink_dropped: pair.up.dropped(),
    uplink_dropped_early: pair.up.dropped_early(),
    uplink_lost: pair.up.lost(),
    discipline: scenario.uplink.discipline,
    mean_queue_packets,
    max_sojourn: pair.up.max_sojourn(),
  }
}

///|
/// The summary as a document, with the same fixed field order as a single run.
pub fn RunSummary::to_json_text(self : RunSummary) -> String {
  @json.object_of_texts([
    ("algorithm", @json.quote(self.algorithm)),
    ("runs", self.runs.to_string()),
    (
      "mean_elapsed_ms",
      @json.Json::Number(self.mean_elapsed.to_ms_f()).render(),
    ),
    ("min_elapsed_ms", @json.Json::Number(self.min_elapsed.to_ms_f()).render()),
    ("max_elapsed_ms", @json.Json::Number(self.max_elapsed.to_ms_f()).render()),
    (
      "mean_throughput_kbps",
      @json.Json::Number(self.mean_throughput_kbps).render(),
    ),
    ("retransmits", self.retransmits.to_string()),
    ("fast_retransmits", self.fast_retransmits.to_string()),
    ("timeouts", self.timeouts.to_string()),
    ("delivered_bytes", self.delivered_bytes.to_string()),
  ])
}

///|
/// The report as a document with a fixed field order, so that two runs of the
/// same scenario produce byte-identical output.
pub fn RunReport::to_json_text(self : RunReport) -> String {
  @json.object_text([
    ("scenario", @json.Json::Text(self.scenario)),
    ("algorithm", @json.Json::Text(self.algorithm)),
    ("seed", @json.Json::Number(self.seed.to_double())),
    ("payload_bytes", @json.Json::Number(self.payload_bytes.to_double())),
    ("delivered_bytes", @json.Json::Number(self.delivered_bytes.to_double())),
    ("connect_ms", @json.Json::Number(self.connect.to_ms_f())),
    ("elapsed_ms", @json.Json::Number(self.elapsed.to_ms_f())),
    ("throughput_kbps", @json.Json::Number(self.throughput_kbps())),
    ("retransmits", @json.Json::Number(self.retransmits.to_double())),
    ("fast_retransmits", @json.Json::Number(self.fast_retransmits.to_double())),
    ("timeouts", @json.Json::Number(self.timeouts.to_double())),
    ("round_trips", @json.Json::Number(self.round_trips.to_double())),
    ("srtt_ms", @json.Json::Number(self.srtt.to_ms_f())),
    ("final_cwnd_bytes", @json.Json::Number(self.final_cwnd.to_double())),
    (
      "final_ssthresh_bytes",
      @json.Json::Number(self.final_ssthresh.to_double()),
    ),
    ("uplink_dropped", @json.Json::Number(self.uplink_dropped.to_double())),
    (
      "uplink_dropped_early",
      @json.Json::Number(self.uplink_dropped_early.to_double()),
    ),
    ("uplink_lost", @json.Json::Number(self.uplink_lost.to_double())),
    ("queue_discipline", @json.Json::Text(self.discipline)),
    ("mean_queue_packets", @json.Json::Number(self.mean_queue_packets)),
    ("max_sojourn_ms", @json.Json::Number(self.max_sojourn.to_ms_f())),
  ])
}

///|
/// Payload throughput in kilobits per second over the measured interval.
pub fn RunReport::throughput_kbps(self : RunReport) -> Double {
  let seconds = self.elapsed.ps.to_double() / 1_000_000_000_000.0
  if seconds <= 0.0 {
    0.0
  } else {
    self.delivered_bytes.to_double() * 8.0 / seconds / 1000.0
  }
}

///|
/// The report as aligned text, one field per line.
pub fn RunReport::to_lines(self : RunReport) -> String {
  let lines : Array[String] = []
  lines.push("scenario:   " + self.scenario)
  lines.push("algorithm:  " + self.algorithm)
  lines.push("seed:       " + self.seed.to_string())
  lines.push(
    "payload:    " +
    self.payload_bytes.to_string() +
    " bytes, " +
    self.delivered_bytes.to_string() +
    " delivered",
  )
  lines.push("connect:    " + self.connect.render())
  lines.push("elapsed:    " + self.elapsed.render())
  lines.push("throughput: " + percent_style(self.throughput_kbps()) + " kbit/s")
  lines.push(
    "segments:   " +
    self.retransmits.to_string() +
    " retransmitted (" +
    self.fast_retransmits.to_string() +
    " fast), " +
    self.timeouts.to_string() +
    " timeouts",
  )
  lines.push(
    "estimator:  " +
    self.round_trips.to_string() +
    " samples, smoothed " +
    self.srtt.render(),
  )
  lines.push(
    "window:     " +
    self.final_cwnd.to_string() +
    " bytes, threshold " +
    self.final_ssthresh.to_string(),
  )
  lines.push(
    "uplink:     " +
    self.uplink_dropped.to_string() +
    " dropped at the queue (" +
    self.uplink_dropped_early.to_string() +
    " before it was full), " +
    self.uplink_lost.to_string() +
    " lost on the wire",
  )
  lines.push(
    "queue:      " +
    self.discipline +
    ", mean " +
    @net.format_one_decimal(self.mean_queue_packets) +
    " packets occupied, " +
    @net.format_one_decimal(self.max_sojourn.to_ms_f()) +
    " ms longest wait",
  )
  lines.join("\n")
}

///|
/// A number with one fractional digit, for figures whose exact value is not the
/// point.
fn percent_style(value : Double) -> String {
  let tenths = (value * 10.0).to_int64()
  (tenths / 10L).to_string() + "." + (tenths % 10L).to_string()
}
