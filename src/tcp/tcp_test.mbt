///|
/// A deterministic byte pattern: comparing what arrived against what was sent is
/// only meaningful if the sender never sends the same thing twice by accident.
fn pattern_bytes(count : Int) -> Bytes {
  let out : Array[Byte] = []
  let mut index = 0
  while index < count {
    out.push((index % 251).to_byte())
    index = index + 1
  }
  Bytes::from_array(out)
}

///|

///|
/// Which data segments the direct loopback throws away.
enum DropSpec {
  DropNone
  DropNth(Int)
  DropRange(Int, Int)
  DropAll
}

///|
/// Two connections wired straight to each other with a fixed one-way delay,
/// bypassing the link layer.
///
/// Losing a specific packet is the one thing a random loss model cannot do on
/// demand, and "the third data segment never arrives" is exactly the kind of
/// scenario a retransmission test needs. Wiring the connections directly makes
/// that decision explicit instead of seed-dependent.
fn wire_loopback(
  sim : @sim.Sim,
  client : @tcp.TcpConnection,
  server : @tcp.TcpConnection,
  one_way : @sim.Time,
  drop : DropSpec,
) -> Unit {
  // This harness compares the delivered byte stream against what was sent.
  server.capture_delivered(true)
  let mut data_count = 0
  client.set_emit(segment => {
    let is_data = segment.payload.length() > 0
    if is_data {
      data_count = data_count + 1
    }
    let drop_this = match drop {
      DropNone => false
      DropNth(index) => is_data && data_count == index
      DropRange(first, last) =>
        is_data && data_count >= first && data_count <= last
      DropAll => is_data
    }
    if !drop_this {
      sim.after(one_way, "c->s", () => server.on_segment(sim, segment))
    }
  })
  server.set_emit(segment => {
    sim.after(one_way, "s->c", () => client.on_segment(sim, segment))
  })
}

///|
/// A configuration whose retransmission timings are short enough to keep a test
/// quick, with the RFC 6298 estimator still in charge of the later values.
fn fast_rto_config(
  mss : Int,
  window : Int,
  initial_seq : UInt,
  initial_rto : @sim.Time,
) -> @tcp.TcpConfig {
  @tcp.TcpConfig::new(mss, window, initial_seq).with_rto(
    initial_rto,
    @sim.Time::from_ms(1L),
    @sim.Time::from_s(60L),
  )
}

///|
/// A 10 Mbps, 5 ms path in both directions with a 1000-byte MSS, used by most of
/// the tests below.
fn make_pair(
  sim : @sim.Sim,
  client_window : Int,
  server_window : Int,
  seed : UInt64,
) -> @tcp.LinkPair {
  let client_config = @tcp.TcpConfig::new(1000, client_window, 1000U)
  let server_config = @tcp.TcpConfig::new(1000, server_window, 5000U)
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
    sim, client_config, server_config, up, down, seed,
  )
  pair.server.capture_delivered(true)
  pair
}

///|
/// Run a bulk transfer over a long fat path with a chosen algorithm and report
/// how long it took.
fn long_fat_transfer(
  cc : &@tcp.CongestionControl,
  loss : Double,
  payload_bytes : Int,
  seed : UInt64,
) -> (@sim.Time, @tcp.LinkPair) {
  let sim = @sim.Sim::new(seed)
  let up = @net.LinkSpec::new(
    "up",
    100_000_000L,
    @sim.Time::from_ms(50L),
    @net.QueueSpec::packets(2000),
  ).with_loss(loss)
  let down = @net.LinkSpec::new(
    "down",
    100_000_000L,
    @sim.Time::from_ms(50L),
    @net.QueueSpec::packets(2000),
  ).with_loss(loss)
  let pair = @tcp.LinkPair::new_with_cc(
    sim,
    @tcp.TcpConfig::new(1000, 2_000_000, 1000U),
    @tcp.TcpConfig::new(1000, 2_000_000, 5000U),
    up,
    down,
    seed,
    cc,
  )
  pair.connect(sim)
  sim.step_until(() => pair.client.state() == @tcp.Established) |> ignore
  let start = sim.now()
  pair.client.send(sim, Bytes::make(payload_bytes, b'x'))
  sim.step_until(() => pair.server.delivered_bytes() == payload_bytes) |> ignore
  (sim.now() - start, pair)
}

///|
test "cubic keeps more of its window than reno when a packet is lost" {
  let payload = pattern_bytes(8000)
  let reno = @sim.Sim::new(1UL)
  let reno_client = @tcp.TcpConnection::new(
    @tcp.TcpConfig::new(1000, 64_000, 1000U),
  )
  let reno_server = @tcp.TcpConnection::new(
    @tcp.TcpConfig::new(1000, 64_000, 5000U),
  )
  wire_loopback(
    reno,
    reno_client,
    reno_server,
    @sim.Time::from_ms(25L),
    DropNth(2),
  )
  reno_server.listen()
  reno_client.connect(reno)
  reno.run()
  reno_client.send(reno, payload)
  reno.step_until(() => reno_client.in_recovery()) |> ignore
  let cubic = @sim.Sim::new(1UL)
  let cubic_client = @tcp.TcpConnection::new_with_cc(
    @tcp.TcpConfig::new(1000, 64_000, 1000U),
    @tcp.cubic(1000),
  )
  let cubic_server = @tcp.TcpConnection::new(
    @tcp.TcpConfig::new(1000, 64_000, 5000U),
  )
  wire_loopback(
    cubic,
    cubic_client,
    cubic_server,
    @sim.Time::from_ms(25L),
    DropNth(2),
  )
  cubic_server.listen()
  cubic_client.connect(cubic)
  cubic.run()
  cubic_client.send(cubic, payload)
  cubic.step_until(() => cubic_client.in_recovery()) |> ignore
  // Both connections have seven segments in flight when the hole is found, so
  // the thresholds differ only by the multiplicative decrease factor: Reno
  // halves 7000 bytes to 3500, CUBIC keeps 70% of it, which is 4.9 segments and
  // truncates to 4 — windows are whole segments, as they are in a real stack.
  inspect(reno_client.inflight(), content="7")
  inspect(cubic_client.inflight(), content="7")
  inspect(reno_client.ssthresh(), content="3500")
  inspect(cubic_client.ssthresh(), content="4000")
  inspect(cubic_client.ssthresh() > reno_client.ssthresh(), content="true")
  inspect(cubic_client.cc_name(), content="cubic")
  inspect(cubic_client.cc_phase(), content="fast recovery")
}

///|
test "cubic collapses to one segment on timeout, like reno" {
  let sim = @sim.Sim::new(1UL)
  let client = @tcp.TcpConnection::new_with_cc(
    @tcp.TcpConfig::new(1000, 64_000, 1000U),
    @tcp.cubic(1000),
  )
  let server = @tcp.TcpConnection::new(@tcp.TcpConfig::new(1000, 64_000, 5000U))
  wire_loopback(sim, client, server, @sim.Time::from_ms(25L), DropAll)
  server.listen()
  client.connect(sim)
  sim.run()
  client.send(sim, pattern_bytes(10_000))
  sim.step_until(() => client.timeouts() > 0) |> ignore
  // Ten segments were in flight, so the threshold keeps 70% of that and the
  // window restarts from a single segment.
  inspect(client.ssthresh(), content="7000")
  inspect(client.cwnd(), content="1000")
  inspect(client.cc_phase(), content="slow start")
}

///|
test "cubic climbs back past the window it was cut to" {
  let sim = @sim.Sim::new(1UL)
  let client = @tcp.TcpConnection::new_with_cc(
    @tcp.TcpConfig::new(1000, 64_000, 1000U),
    @tcp.cubic(1000),
  )
  let server = @tcp.TcpConnection::new(@tcp.TcpConfig::new(1000, 64_000, 5000U))
  wire_loopback(sim, client, server, @sim.Time::from_ms(25L), DropNth(2))
  server.listen()
  client.connect(sim)
  sim.run()
  client.send(sim, pattern_bytes(200_000))
  sim.step_until(() => client.in_recovery()) |> ignore
  let reduced = client.ssthresh()
  inspect(reduced, content="8000")
  inspect(client.cwnd(), content="11000")
  // Once the hole is repaired the window deflates to the threshold and the cubic
  // curve starts climbing from there.
  sim.step_until(() => !client.in_recovery()) |> ignore
  inspect(client.cwnd() >= reduced, content="true")
  sim.step_until(() => client.cwnd() > reduced) |> ignore
  inspect(client.cwnd() > reduced, content="true")
  inspect(server.delivered_bytes() > 0, content="true")
}

///|
test "cubic retransmits less than reno on a lossy path" {
  // Two megabytes, not twenty: on a lossy path the total is dominated by how
  // many times the retransmission timer expires, and each expiry costs up to the
  // sixty-second backoff ceiling. A large transfer is therefore decided by a
  // handful of expiries and swings by an order of magnitude between seeds, so
  // this measures the average over three.
  //
  // What it asserts is the retransmission count, not the elapsed time. Under
  // controlled loss CUBIC does *not* finish sooner on this path — see the note
  // in docs/roadmap.md — but it sends noticeably fewer copies of the same data,
  // which is the part of the behaviour that follows directly from keeping 70% of
  // the window instead of half.
  let payload_bytes = 2_000_000
  let mut reno_timeouts = 0
  let mut cubic_timeouts = 0
  let mut reno_retransmits = 0
  let mut cubic_retransmits = 0
  let mut offset = 0UL
  while offset < 3UL {
    let (reno_elapsed, _reno_pair) = long_fat_transfer(
      @tcp.reno(1000),
      0.01,
      payload_bytes,
      9UL + offset,
    )
    let (cubic_elapsed, cubic_pair) = long_fat_transfer(
      @tcp.cubic(1000),
      0.01,
      payload_bytes,
      9UL + offset,
    )
    // Both transfers take a measurable amount of time; the numbers themselves
    // are checked by the reports, not here.
    inspect(reno_elapsed.ps > 0L, content="true")
    inspect(cubic_elapsed.ps > 0L, content="true")
    reno_timeouts = reno_timeouts + _reno_pair.client.timeouts()
    cubic_timeouts = cubic_timeouts + cubic_pair.client.timeouts()
    reno_retransmits = reno_retransmits + _reno_pair.client.retransmits()
    cubic_retransmits = cubic_retransmits + cubic_pair.client.retransmits()
    inspect(cubic_pair.server.delivered_bytes(), content="2000000")
    inspect(_reno_pair.server.delivered_bytes(), content="2000000")
    offset = offset + 1UL
  }
  inspect(cubic_retransmits < reno_retransmits, content="true")
  inspect(cubic_timeouts <= reno_timeouts, content="true")
}

///|
test "the initial window follows RFC 6928" {
  // Ten segments, never fewer than two, and never fewer than 14 600 bytes.
  inspect(@tcp.initial_window(1000), content="10000")
  inspect(@tcp.initial_window(536), content="5360")
  inspect(@tcp.initial_window(1460), content="14600")
  inspect(@tcp.initial_window(2000), content="14600")
  // Ten tiny segments is still under the 14 600 byte floor, so ten wins.
  inspect(@tcp.initial_window(100), content="1000")
}

///|
test "the congestion window limits the first burst, not the receive window" {
  let sim = @sim.Sim::new(1UL)
  let client = @tcp.TcpConnection::new(@tcp.TcpConfig::new(1000, 64_000, 1000U))
  let server = @tcp.TcpConnection::new(@tcp.TcpConfig::new(1000, 64_000, 5000U))
  wire_loopback(sim, client, server, @sim.Time::from_ms(25L), DropNone)
  server.listen()
  client.connect(sim)
  sim.run()
  // The receiver offered 64 000 bytes. Reno's initial window is ten segments,
  // so ten segments is what leaves the sender.
  inspect(client.peer_window(), content="64000")
  inspect(client.cwnd(), content="10000")
  client.send(sim, pattern_bytes(64_000))
  inspect(client.bytes_sent(), content="10000")
  inspect(client.inflight(), content="10")
  sim.run()
  inspect(server.delivered_bytes(), content="64000")
}

///|
test "no congestion control leaves the receive window as the only limit" {
  let sim = @sim.Sim::new(1UL)
  let client = @tcp.TcpConnection::new_with_cc(
    @tcp.TcpConfig::new(1000, 64_000, 1000U),
    @tcp.without_congestion_control(),
  )
  let server = @tcp.TcpConnection::new(@tcp.TcpConfig::new(1000, 64_000, 5000U))
  wire_loopback(sim, client, server, @sim.Time::from_ms(25L), DropNone)
  server.listen()
  client.connect(sim)
  sim.run()
  client.send(sim, pattern_bytes(64_000))
  // Every byte the receiver offered goes out in one burst.
  inspect(client.bytes_sent(), content="64000")
  sim.run()
  inspect(server.delivered_bytes(), content="64000")
  inspect(client.cc_name(), content="none")
}

///|
test "slow start doubles the window once per round trip" {
  let sim = @sim.Sim::new(1UL)
  let client = @tcp.TcpConnection::new(
    @tcp.TcpConfig::new(1000, 1_000_000, 1000U),
  )
  let server = @tcp.TcpConnection::new(
    @tcp.TcpConfig::new(1000, 1_000_000, 5000U),
  )
  wire_loopback(sim, client, server, @sim.Time::from_ms(25L), DropNone)
  server.listen()
  client.connect(sim)
  sim.run()
  inspect(client.cc_phase(), content="slow start")
  client.send(sim, pattern_bytes(500_000))
  // One round trip after the first burst, the window has doubled: each of the
  // ten segments acknowledged adds one segment.
  sim.step_until(() => client.cwnd() >= 20_000) |> ignore
  inspect(client.cwnd(), content="20000")
  sim.step_until(() => client.cwnd() >= 40_000) |> ignore
  inspect(client.cwnd(), content="40000")
}

///|
test "a timeout collapses the window to one segment and halves the threshold" {
  let sim = @sim.Sim::new(1UL)
  // The RFC 6298 floor keeps the handshake's own timer out of the picture: with
  // a timeout as short as the round trip, the SYN timer fires spuriously.
  let client = @tcp.TcpConnection::new(@tcp.TcpConfig::new(1000, 64_000, 1000U))
  let server = @tcp.TcpConnection::new(@tcp.TcpConfig::new(1000, 64_000, 5000U))
  // Every data segment is lost, so the connection cannot make progress and
  // every repair is a timeout.
  wire_loopback(sim, client, server, @sim.Time::from_ms(25L), DropAll)
  server.listen()
  client.connect(sim)
  sim.run()
  client.send(sim, pattern_bytes(10_000))
  sim.step_until(() => client.timeouts() > 0) |> ignore
  // Ten segments were in flight; the threshold becomes half of that, and the
  // window restarts at a single segment.
  inspect(client.ssthresh(), content="5000")
  inspect(client.cwnd(), content="1000")
  inspect(client.cc_phase(), content="slow start")
}

///|
test "fast retransmit halves the window and recovery restores it" {
  let sim = @sim.Sim::new(1UL)
  let client = @tcp.TcpConnection::new(@tcp.TcpConfig::new(1000, 64_000, 1000U))
  let server = @tcp.TcpConnection::new(@tcp.TcpConfig::new(1000, 64_000, 5000U))
  wire_loopback(sim, client, server, @sim.Time::from_ms(25L), DropNth(2))
  server.listen()
  client.connect(sim)
  sim.run()
  client.send(sim, pattern_bytes(80_000))
  // Thirty segments leave in the first burst, then the second is dropped and the
  // twenty-eight behind it raise duplicate acknowledgments.
  sim.step_until(() => client.in_recovery()) |> ignore
  // Eleven thousand bytes were in flight when the hole was found: the first
  // acknowledgment grew the window, which let two more segments leave before the
  // third duplicate acknowledgment arrived. The threshold is half of that, and
  // the window is inflated by the three segments that already left the network.
  inspect(client.ssthresh(), content="5500")
  inspect(client.cwnd(), content="8500")
  inspect(client.cc_phase(), content="fast recovery")
  sim.run()
  // Recovery deflates the window back to the threshold and slow start resumes.
  inspect(client.ssthresh(), content="5500")
  inspect(client.cwnd() > 5500, content="true")
  inspect(client.in_recovery(), content="false")
}

///|
test "three duplicate acknowledgments retransmit without waiting for the timer" {
  let sim = @sim.Sim::new(1UL)
  // The default RFC 6298 timeout is a second. That is the point: the timer is
  // three orders of magnitude too slow to help here, which is why the duplicate
  // acknowledgments have to.
  let client = @tcp.TcpConnection::new(@tcp.TcpConfig::new(1000, 8192, 1000U))
  let server = @tcp.TcpConnection::new(@tcp.TcpConfig::new(1000, 8192, 5000U))
  // Eight segments go out at once, the second never arrives, and the six behind
  // it each send a duplicate acknowledgment.
  wire_loopback(sim, client, server, @sim.Time::from_ms(25L), DropNth(2))
  server.listen()
  client.connect(sim)
  sim.run()
  let payload = pattern_bytes(8000)
  client.send(sim, payload)
  let sent_at = sim.now()
  // Measure until the last byte reaches the receiver. Draining the queue would
  // advance the clock to whatever stale timer the recovery left behind.
  inspect(
    sim.step_until(() => server.delivered_bytes() == 8000),
    content="true",
  )
  // The repair costs about two round trips: 100 ms of a 50 ms path, against a
  // timeout that would have cost a full second.
  inspect((sim.now() - sent_at).ps < 200_000_000_000L, content="true")
  sim.run()
  inspect(client.fast_retransmits(), content="1")
  inspect(client.timeouts(), content="0")
  inspect(client.retransmits(), content="1")
  inspect(client.in_recovery(), content="false")
  inspect(server.delivered() == payload, content="true")
  inspect(client.rto().ps >= 1_000_000_000_000L, content="true")
}

///|
test "a burst of losses is repaired by partial acknowledgments" {
  let sim = @sim.Sim::new(1UL)
  let client = @tcp.TcpConnection::new(@tcp.TcpConfig::new(1000, 8192, 1000U))
  let server = @tcp.TcpConnection::new(@tcp.TcpConfig::new(1000, 8192, 5000U))
  // Two segments in a row go missing inside one window, which no single fast
  // retransmit can repair on its own.
  wire_loopback(sim, client, server, @sim.Time::from_ms(25L), DropRange(2, 3))
  server.listen()
  client.connect(sim)
  sim.run()
  let payload = pattern_bytes(8000)
  client.send(sim, payload)
  sim.run()
  // The first hole is found by duplicate acknowledgments, the acknowledgment of
  // its repair stops short of the end of what was in flight, and that partial
  // acknowledgment sends the second missing segment.
  inspect(client.fast_retransmits(), content="2")
  inspect(client.timeouts(), content="0")
  inspect(client.in_recovery(), content="false")
  inspect(server.delivered() == payload, content="true")
  inspect(client.bytes_acked(), content="8000")
}

///|
test "two duplicate acknowledgments are not enough to retransmit" {
  let sim = @sim.Sim::new(1UL)
  let client = @tcp.TcpConnection::new(
    fast_rto_config(1000, 8192, 1000U, @sim.Time::from_ms(50L)),
  )
  let server = @tcp.TcpConnection::new(
    fast_rto_config(1000, 8192, 5000U, @sim.Time::from_ms(50L)),
  )
  // With only four segments in the window, one loss produces two duplicate
  // acknowledgments: not enough evidence, so the timer has to do the work.
  wire_loopback(sim, client, server, @sim.Time::from_ms(5L), DropNth(2))
  server.listen()
  client.connect(sim)
  sim.run()
  client.send(sim, pattern_bytes(4000))
  sim.run()
  inspect(client.fast_retransmits(), content="0")
  inspect(client.timeouts(), content="1")
  inspect(client.retransmits(), content="1")
}

///|
test "the round trip estimate converges on the path delay" {
  let sim = @sim.Sim::new(1UL)
  let client = @tcp.TcpConnection::new(
    fast_rto_config(1000, 8192, 1000U, @sim.Time::from_ms(50L)),
  )
  let server = @tcp.TcpConnection::new(
    fast_rto_config(1000, 8192, 5000U, @sim.Time::from_ms(50L)),
  )
  wire_loopback(sim, client, server, @sim.Time::from_ms(5L), DropNone)
  server.listen()
  client.connect(sim)
  sim.run()
  // The SYN exchange alone measures the path, so an estimate exists before any
  // data is sent.
  inspect(client.srtt().unwrap().render(), content="10.000ms")
  client.send(sim, pattern_bytes(4000))
  sim.run()
  // Every sample on this path is 10 ms, so the estimate stays there and the
  // variance shrinks towards zero.
  inspect(client.srtt().unwrap().render(), content="10.000ms")
  inspect(client.rto().ps <= 30_000_000_000L, content="true")
  inspect(client.rtt_samples() > 1, content="true")
}

///|
test "a lost data segment is retransmitted and the transfer completes" {
  let sim = @sim.Sim::new(1UL)
  let client = @tcp.TcpConnection::new(
    fast_rto_config(1000, 8192, 1000U, @sim.Time::from_ms(50L)),
  )
  let server = @tcp.TcpConnection::new(
    fast_rto_config(1000, 8192, 5000U, @sim.Time::from_ms(50L)),
  )
  // The second data segment never arrives.
  wire_loopback(sim, client, server, @sim.Time::from_ms(5L), DropNth(2))
  server.listen()
  client.connect(sim)
  sim.run()
  let payload = pattern_bytes(4000)
  client.send(sim, payload)
  sim.run()
  inspect(client.timeouts(), content="1")
  inspect(client.retransmits(), content="1")
  inspect(server.delivered() == payload, content="true")
  inspect(client.bytes_acked(), content="4000")
  // The handshake and the first data segment already measured the path, so the
  // timer was at 25 ms (10 ms smoothed, 3.75 ms variance) when the loss was
  // discovered, and backoff doubled it to 50 ms.
  inspect(client.rto().render(), content="50.000ms")
}

///|
test "only a segment sent once contributes a round trip sample" {
  // Without loss every data segment is acknowledged in turn, so the handshake
  // plus four segments produce five samples.
  let clean_sim = @sim.Sim::new(1UL)
  let clean_client = @tcp.TcpConnection::new(
    fast_rto_config(1000, 8192, 1000U, @sim.Time::from_ms(50L)),
  )
  let clean_server = @tcp.TcpConnection::new(
    fast_rto_config(1000, 8192, 5000U, @sim.Time::from_ms(50L)),
  )
  wire_loopback(
    clean_sim,
    clean_client,
    clean_server,
    @sim.Time::from_ms(5L),
    DropNone,
  )
  clean_server.listen()
  clean_client.connect(clean_sim)
  clean_sim.run()
  clean_client.send(clean_sim, pattern_bytes(4000))
  clean_sim.run()
  inspect(clean_client.rtt_samples(), content="5")
  // With one segment lost, the retransmission is acknowledged by a cumulative
  // ACK that also covers the segments behind it. Karn's algorithm throws that
  // sample away, and the cumulative ACK only ever samples one segment, so the
  // count is much lower even though the same bytes arrive.
  let lossy_sim = @sim.Sim::new(1UL)
  let lossy_client = @tcp.TcpConnection::new(
    fast_rto_config(1000, 8192, 1000U, @sim.Time::from_ms(50L)),
  )
  let lossy_server = @tcp.TcpConnection::new(
    fast_rto_config(1000, 8192, 5000U, @sim.Time::from_ms(50L)),
  )
  wire_loopback(
    lossy_sim,
    lossy_client,
    lossy_server,
    @sim.Time::from_ms(5L),
    DropNth(2),
  )
  lossy_server.listen()
  lossy_client.connect(lossy_sim)
  lossy_sim.run()
  lossy_client.send(lossy_sim, pattern_bytes(4000))
  lossy_sim.run()
  inspect(lossy_client.rtt_samples(), content="2")
}

///|
test "consecutive timeouts back off exponentially and then give up" {
  let sim = @sim.Sim::new(1UL)
  let client = @tcp.TcpConnection::new(
    fast_rto_config(1000, 8192, 1000U, @sim.Time::from_ms(20L)),
  )
  let server = @tcp.TcpConnection::new(
    fast_rto_config(1000, 8192, 5000U, @sim.Time::from_ms(20L)),
  )
  // Every data segment is dropped, so the connection can never make progress.
  wire_loopback(sim, client, server, @sim.Time::from_ms(5L), DropAll)
  server.listen()
  client.connect(sim)
  sim.run()
  client.send(sim, pattern_bytes(1000))
  sim.run()
  // Eight retransmissions, each waiting twice as long as the last, and then the
  // connection gives up rather than retrying forever.
  inspect(client.timeouts(), content="9")
  inspect(client.retransmits(), content="8")
  inspect(client.state().render(), content="CLOSED")
  // Eight doublings from the 30 ms the path measurement produced.
  inspect(client.rto().render(), content="7.680s")
}

///|
test "a lossy link still delivers every byte" {
  let sim = @sim.Sim::new(4UL)
  let up = @net.LinkSpec::new(
    "up",
    10_000_000L,
    @sim.Time::from_ms(5L),
    @net.QueueSpec::packets(64),
  ).with_loss(0.05)
  let down = @net.LinkSpec::new(
    "down",
    10_000_000L,
    @sim.Time::from_ms(5L),
    @net.QueueSpec::packets(64),
  ).with_loss(0.02)
  let pair = @tcp.LinkPair::new(
    sim,
    @tcp.TcpConfig::new(1000, 8192, 1000U),
    @tcp.TcpConfig::new(1000, 8192, 5000U),
    up,
    down,
    4UL,
  )
  pair.connect(sim)
  sim.run()
  let payload = pattern_bytes(20_000)
  pair.server.capture_delivered(true)
  pair.client.send(sim, payload)
  sim.run()
  inspect(pair.server.delivered() == payload, content="true")
  inspect(pair.client.retransmits() > 0, content="true")
  inspect(pair.client.bytes_acked(), content="20000")
  inspect(pair.up.lost() > 0, content="true")
}

///|
test "a lossy run is still reproducible" {
  let first_sim = @sim.Sim::new(11UL)
  let second_sim = @sim.Sim::new(11UL)
  let spec = @net.LinkSpec::new(
    "up",
    10_000_000L,
    @sim.Time::from_ms(5L),
    @net.QueueSpec::packets(64),
  ).with_loss(0.07)
  let down = @net.LinkSpec::new(
    "down",
    10_000_000L,
    @sim.Time::from_ms(5L),
    @net.QueueSpec::packets(64),
  )
  let first = @tcp.LinkPair::new(
    first_sim,
    @tcp.TcpConfig::new(1000, 8192, 1000U),
    @tcp.TcpConfig::new(1000, 8192, 5000U),
    spec,
    down,
    11UL,
  )
  let second = @tcp.LinkPair::new(
    second_sim,
    @tcp.TcpConfig::new(1000, 8192, 1000U),
    @tcp.TcpConfig::new(1000, 8192, 5000U),
    spec,
    down,
    11UL,
  )
  first.connect(first_sim)
  second.connect(second_sim)
  first.server.capture_delivered(true)
  second.server.capture_delivered(true)
  first_sim.run()
  second_sim.run()
  first.client.send(first_sim, pattern_bytes(10_000))
  second.client.send(second_sim, pattern_bytes(10_000))
  first_sim.run()
  second_sim.run()
  // Loss now follows packet identity, so with this seed none of the ten
  // kilobytes happened to hit a packet the link was going to lose. What matters
  // here is that both runs agree.
  inspect(first.client.retransmits(), content="0")
  inspect(
    first.client.retransmits() == second.client.retransmits(),
    content="true",
  )
  inspect(first.server.delivered() == second.server.delivered(), content="true")
}

///|
test "sequence numbers compare across the wrap point" {
  let just_before_wrap = @tcp.Seq::of(0xFFFFFFF0U)
  let just_after_wrap = @tcp.Seq::of(0x00000010U)
  // Numerically the wrapped number is tiny, but in sequence space it comes next.
  inspect(just_before_wrap.before(just_after_wrap), content="true")
  inspect(just_after_wrap.before(just_before_wrap), content="false")
  inspect(@tcp.Seq::of(10U).distance_to(@tcp.Seq::of(25U)), content="15")
  inspect(@tcp.Seq::of(10U).advance(5).to_string(), content="15")
}

///|
test "SYN and FIN consume one sequence number each" {
  inspect(@tcp.Flags::syn().sequence_length(0), content="1")
  inspect(@tcp.Flags::syn().sequence_length(100), content="101")
  inspect(@tcp.Flags::fin_ack().sequence_length(0), content="1")
  inspect(@tcp.Flags::data().sequence_length(100), content="100")
}

///|
test "three way handshake reaches established on both ends" {
  let sim = @sim.Sim::new(1UL)
  let pair = make_pair(sim, 4096, 4096, 1UL)
  pair.connect(sim)
  sim.run()
  inspect(pair.client.state().render(), content="ESTABLISHED")
  inspect(pair.server.state().render(), content="ESTABLISHED")
  // The SYN, the SYN+ACK and the final ACK each move the sequence space by one.
  inspect(pair.client.snd_una().to_string(), content="1001")
  inspect(pair.client.rcv_nxt().to_string(), content="5001")
  inspect(pair.server.snd_una().to_string(), content="5001")
  inspect(pair.server.rcv_nxt().to_string(), content="1001")
  // Both ends learned the peer's receive window from the handshake.
  inspect(pair.client.peer_window(), content="4096")
  inspect(pair.server.peer_window(), content="4096")
}

///|
test "a byte stream arrives complete and in order" {
  let sim = @sim.Sim::new(1UL)
  let pair = make_pair(sim, 8192, 8192, 1UL)
  pair.connect(sim)
  sim.run()
  let payload = pattern_bytes(5000)
  pair.client.send(sim, payload)
  sim.run()
  inspect(pair.server.delivered_bytes(), content="5000")
  inspect(pair.server.delivered() == payload, content="true")
  inspect(pair.client.bytes_acked(), content="5000")
  inspect(pair.client.inflight(), content="0")
}

///|
test "the receiver window caps how much can be in flight" {
  let sim = @sim.Sim::new(1UL)
  let pair = make_pair(sim, 4096, 2500, 1UL)
  pair.connect(sim)
  sim.run()
  pair.client.send(sim, pattern_bytes(5000))
  // Before any acknowledgment comes back, 2500 bytes of window means exactly
  // 2500 bytes on the wire: two full segments and a partial one.
  inspect(pair.client.bytes_sent(), content="2500")
  inspect(pair.client.bytes_acked(), content="0")
  sim.run()
  inspect(pair.client.bytes_acked(), content="5000")
  inspect(pair.server.delivered_bytes(), content="5000")
}

///|
test "out of order segments are buffered and then delivered in order" {
  let sim = @sim.Sim::new(1UL)
  let server = @tcp.TcpConnection::new(@tcp.TcpConfig::new(1000, 4096, 5000U))
  server.capture_delivered(true)
  server.listen()
  // Complete a handshake by hand so the receiver has a known sequence base.
  server.on_segment(
    sim,
    @tcp.Segment::new(
      @tcp.Seq::of(1000U),
      @tcp.Seq::of(0U),
      4096,
      @tcp.Flags::syn(),
      Bytes::new(0),
      0UL,
    ),
  )
  inspect(server.rcv_nxt().to_string(), content="1001")
  let first = pattern_bytes(100)
  let second = pattern_bytes(100)
  // The second segment arrives first: it must not be delivered yet.
  server.on_segment(
    sim,
    @tcp.Segment::new(
      @tcp.Seq::of(1101U),
      @tcp.Seq::of(1001U),
      4096,
      @tcp.Flags::ack(),
      second,
      0UL,
    ),
  )
  inspect(server.delivered_bytes(), content="0")
  inspect(server.rcv_nxt().to_string(), content="1001")
  // Filling the gap releases both segments, in order.
  server.on_segment(
    sim,
    @tcp.Segment::new(
      @tcp.Seq::of(1001U),
      @tcp.Seq::of(1001U),
      4096,
      @tcp.Flags::ack(),
      first,
      0UL,
    ),
  )
  inspect(server.delivered_bytes(), content="200")
  inspect(server.delivered() == first.add(second), content="true")
  inspect(server.rcv_nxt().to_string(), content="1201")
}

///|
test "a retransmitted segment is acknowledged but not delivered twice" {
  let sim = @sim.Sim::new(1UL)
  let server = @tcp.TcpConnection::new(@tcp.TcpConfig::new(1000, 4096, 5000U))
  server.listen()
  server.on_segment(
    sim,
    @tcp.Segment::new(
      @tcp.Seq::of(1000U),
      @tcp.Seq::of(0U),
      4096,
      @tcp.Flags::syn(),
      Bytes::new(0),
      0UL,
    ),
  )
  let payload = pattern_bytes(100)
  let segment = @tcp.Segment::new(
    @tcp.Seq::of(1001U),
    @tcp.Seq::of(1001U),
    4096,
    @tcp.Flags::ack(),
    payload,
    0UL,
  )
  server.on_segment(sim, segment)
  inspect(server.delivered_bytes(), content="100")
  let before = server.duplicate_acks()
  server.on_segment(sim, segment)
  inspect(server.delivered_bytes(), content="100")
  inspect(server.duplicate_acks() > before, content="true")
}

///|
test "closing walks both ends to CLOSED through TIME-WAIT" {
  let sim = @sim.Sim::new(1UL)
  let pair = make_pair(sim, 8192, 8192, 1UL)
  pair.connect(sim)
  sim.run()
  pair.client.close(sim)
  sim.run()
  // The server sees the FIN first, so it owes a close of its own.
  inspect(pair.server.state().render(), content="CLOSE-WAIT")
  pair.server.close(sim)
  sim.run()
  inspect(pair.server.state().render(), content="CLOSED")
  // The client waits out twice the maximum segment lifetime before closing.
  inspect(pair.client.state().render(), content="CLOSED")
  // TIME-WAIT starts when the peer's FIN arrives, so the clock ends up a little
  // past the 60 s timer itself.
  inspect(sim.now().ps > 60_000_000_000_000L, content="true")
}

///|
test "a connection run is reproducible" {
  let first_sim = @sim.Sim::new(99UL)
  let second_sim = @sim.Sim::new(99UL)
  let first = make_pair(first_sim, 4096, 4096, 99UL)
  let second = make_pair(second_sim, 4096, 4096, 99UL)
  first.connect(first_sim)
  second.connect(second_sim)
  first_sim.run()
  second_sim.run()
  first.client.send(first_sim, pattern_bytes(4000))
  second.client.send(second_sim, pattern_bytes(4000))
  first_sim.start_journal()
  second_sim.start_journal()
  first_sim.run()
  second_sim.run()
  inspect(
    first_sim.journal().join("\n") == second_sim.journal().join("\n"),
    content="true",
  )
  inspect(first_sim.journal().length() > 0, content="true")
  inspect(
    first.client.bytes_acked() == second.client.bytes_acked(),
    content="true",
  )
}
