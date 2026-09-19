///|
/// What one flow got out of a shared path.
pub(all) struct FlowResult {
  index : Int
  algorithm : String
  delivered_bytes : Int
  /// Rate over the measurement window, in kilobits per second.
  throughput_kbps : Double
  /// False when the flow ran out of offered data before the window closed, in
  /// which case its share is a statement about the offered load rather than
  /// about the path.
  finished : Bool
  retransmits : Int
  timeouts : Int
} derive(Eq, Debug)

///|
/// What several flows sharing one bottleneck add up to.
pub(all) struct FairnessReport {
  scenario : String
  seed : UInt64
  flows : Array[FlowResult]
  /// Jain's fairness index over the bytes each flow delivered: one when every
  /// flow got the same share, `1/n` when one flow took everything. It says
  /// nothing about how much was delivered in total, which is why the totals are
  /// reported next to it.
  jain_index : Double
  total_delivered_bytes : Int
  window : @sim.Time
  /// True when every flow still had data to send at the end of the window.
  saturated : Bool
  /// Whether the clock reached the end of the window before the event queue ran
  /// dry. If it did not, the numbers describe a shorter interval than asked for.
  window_closed : Bool
  uplink_dropped : Int
  uplink_lost : Int
} derive(Eq, Debug)

///|
/// Jain's fairness index of a set of shares.
///
///     (sum x)^2 / (n * sum x^2)
///
/// Applying a function rather than reading it off a table makes it testable at
/// its endpoints: identical shares give exactly one, and a single flow taking
/// everything gives exactly `1/n`.
pub fn jain_index(values : Array[Double]) -> Double {
  let count = values.length()
  if count == 0 {
    return 0.0
  }
  let mut total = 0.0
  let mut squares = 0.0
  for value in values {
    total = total + value
    squares = squares + value * value
  }
  if total <= 0.0 {
    return 0.0
  }
  total * total / (count.to_double() * squares)
}

///|
/// Run every flow in the scenario over one shared path.
///
/// The topology is a single bottleneck in each direction: every sender queues
/// into the same upload link and every acknowledgment into the same download
/// link, so the flows compete for one queue and one rate rather than each having
/// a private path. That is the smallest arrangement in which "fairness" means
/// anything.
///
/// The flows start together and are given their payload once all handshakes have
/// completed, so no flow gets a head start by luck of scheduling.
pub fn run_fairness(scenario : Scenario) -> FairnessReport {
  let names = scenario.flow_algorithms()
  let count = names.length()
  let sim = @sim.Sim::new(scenario.seed)
  let clients : Array[@tcp.TcpConnection] = []
  let servers : Array[@tcp.TcpConnection] = []
  let mut index = 0
  while index < count {
    let client = @tcp.TcpConnection::new_with_cc(
      @tcp.TcpConfig::new(
        scenario.client.mss,
        scenario.client.receive_window,
        scenario.client.initial_seq,
      ),
      algorithm_of(names[index], scenario.client.mss),
    )
    let server = @tcp.TcpConnection::new(
      @tcp.TcpConfig::new(
        scenario.server.mss,
        scenario.server.receive_window,
        scenario.server.initial_seq,
      ),
    )
    client.set_flow(index.to_uint64() + 1UL)
    server.set_flow(index.to_uint64() + 1UL)
    clients.push(client)
    servers.push(server)
    index = index + 1
  }
  let downlink_spec = link_of(scenario.downlink)
  let uplink = @net.Link::new(link_of(scenario.uplink), scenario.seed, packet => {
    servers[packet.flow].on_segment(sim, packet.payload)
  })
  let downlink = @net.Link::new(downlink_spec, scenario.seed, packet => {
    clients[packet.flow].on_segment(sim, packet.payload)
  })
  let mut packet_id = 0
  let mut index = 0
  while index < count {
    let client = clients[index]
    let flow = index
    client.set_emit(segment => {
      packet_id = packet_id + 1
      uplink.send(
        sim,
        @net.Packet::new(
          packet_id,
          flow,
          @net.Data,
          segment.wire_size(),
          segment.tag,
          segment,
        ),
      )
      |> ignore
    })
    let server = servers[index]
    server.set_emit(segment => {
      packet_id = packet_id + 1
      downlink.send(
        sim,
        @net.Packet::new(
          packet_id,
          flow,
          @net.Data,
          segment.wire_size(),
          segment.tag,
          segment,
        ),
      )
      |> ignore
    })
    index = index + 1
  }
  let connected = () => {
    let mut ready = true
    for client in clients {
      if client.state() != @tcp.Established {
        ready = false
      }
    }
    ready
  }
  for server in servers {
    server.listen()
  }
  for client in clients {
    client.connect(sim)
  }
  sim.step_until(connected) |> ignore
  // From here every flow is offered more data than it can send in the window,
  // so what each one delivers is a measurement of how the path was shared and
  // not of how much it was asked for.
  let start = sim.now()
  for client in clients {
    client.send(sim, Bytes::make(scenario.payload_bytes, b'x'))
  }
  let deadline = start.ps + scenario.duration.ps
  // Measure at the deadline and stop there. Draining the queue afterwards would
  // let the connections keep sending: acknowledgments arriving after the window
  // release more data, and the totals would describe a much longer interval than
  // the one being reported.
  let window_closed = sim.step_until(() => sim.now().ps >= deadline)
  let results : Array[FlowResult] = []
  let shares : Array[Double] = []
  let mut index = 0
  let mut saturated = true
  while index < count {
    let delivered = servers[index].delivered_bytes()
    if delivered >= scenario.payload_bytes {
      saturated = false
    }
    results.push({
      index,
      algorithm: clients[index].cc_name(),
      delivered_bytes: delivered,
      throughput_kbps: rate_kbps(delivered, scenario.duration),
      finished: delivered >= scenario.payload_bytes,
      retransmits: clients[index].retransmits(),
      timeouts: clients[index].timeouts(),
    })
    shares.push(delivered.to_double())
    index = index + 1
  }
  {
    scenario: scenario.name,
    seed: scenario.seed,
    flows: results,
    jain_index: jain_index(shares),
    total_delivered_bytes: delivered_total(shares),
    window: scenario.duration,
    saturated,
    window_closed,
    uplink_dropped: uplink.dropped(),
    uplink_lost: uplink.lost(),
  }
}

///|
fn rate_kbps(bytes : Int, window : @sim.Time) -> Double {
  let seconds = window.ps.to_double() / 1_000_000_000_000.0
  if seconds <= 0.0 {
    0.0
  } else {
    bytes.to_double() * 8.0 / seconds / 1000.0
  }
}

///|
fn delivered_total(shares : Array[Double]) -> Int {
  let mut total = 0.0
  for share in shares {
    total = total + share
  }
  total.to_int()
}

///|
/// A flow's share of the delivered bytes, as a percentage.
fn FairnessReport::share_percent(self : FairnessReport, bytes : Int) -> Double {
  if self.total_delivered_bytes <= 0 {
    0.0
  } else {
    bytes.to_double() * 100.0 / self.total_delivered_bytes.to_double()
  }
}

///|
/// The report as a table: one row per flow, then the summary.
pub fn FairnessReport::to_lines(self : FairnessReport) -> String {
  let rows : Array[Array[String]] = []
  for flow in self.flows {
    rows.push([
      "flow " + flow.index.to_string(),
      flow.algorithm,
      flow.delivered_bytes.to_string(),
      format_fixed(self.share_percent(flow.delivered_bytes), 1),
      format_fixed(flow.throughput_kbps, 1),
      flow.retransmits.to_string(),
      flow.timeouts.to_string(),
    ])
  }
  let lines : Array[String] = []
  lines.push(
    "scenario:   " +
    self.scenario +
    " (seed " +
    self.seed.to_string() +
    ", " +
    self.flows.length().to_string() +
    " flows sharing one path, " +
    self.window.render() +
    " window)",
  )
  lines.push("")
  lines.push(
    render_table(
      [
        "flow", "algorithm", "delivered", "share %", "kbit/s", "retransmits", "timeouts",
      ],
      rows,
    ),
  )
  lines.push("")
  lines.push("total:      " + self.total_delivered_bytes.to_string() + " bytes")
  lines.push(
    "fairness:   " +
    format_fixed(self.jain_index, 4) +
    " (Jain index over the shares above)",
  )
  lines.push(
    "uplink:     " +
    self.uplink_dropped.to_string() +
    " dropped at the queue, " +
    self.uplink_lost.to_string() +
    " lost on the wire",
  )
  if !self.saturated {
    lines.push(
      "note:       at least one flow delivered its whole offered load, so the",
    )
    lines.push(
      "            shares below say as much about the offered load as the path",
    )
  }
  lines.join("\n")
}

///|
/// The report as a document.
pub fn FairnessReport::to_json_text(self : FairnessReport) -> String {
  let flows : Array[String] = []
  for flow in self.flows {
    flows.push(
      @json.object_of_texts([
        ("flow", flow.index.to_string()),
        ("algorithm", @json.quote(flow.algorithm)),
        ("delivered_bytes", flow.delivered_bytes.to_string()),
        ("throughput_kbps", format_fixed(flow.throughput_kbps, 3)),
        ("finished", flow.finished.to_string()),
        (
          "share_percent",
          format_fixed(self.share_percent(flow.delivered_bytes), 4),
        ),
        ("retransmits", flow.retransmits.to_string()),
        ("timeouts", flow.timeouts.to_string()),
      ]),
    )
  }
  @json.object_of_texts([
    ("scenario", @json.quote(self.scenario)),
    ("seed", self.seed.to_string()),
    ("flows", @json.array_of_texts(flows)),
    ("jain_index", format_fixed(self.jain_index, 6)),
    ("total_delivered_bytes", self.total_delivered_bytes.to_string()),
    ("window_ms", @json.Json::Number(self.window.to_ms_f()).render()),
    ("saturated", self.saturated.to_string()),
    ("uplink_dropped", self.uplink_dropped.to_string()),
    ("uplink_lost", self.uplink_lost.to_string()),
  ])
}
