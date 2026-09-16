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
  let mut data_count = 0
  client.set_emit(segment => {
    if segment.payload.length() > 0 {
      data_count = data_count + 1
    }
    let drop_this = match drop {
      DropNone => false
      DropNth(index) => segment.payload.length() > 0 && data_count == index
      DropAll => segment.payload.length() > 0
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
  @tcp.LinkPair::new(sim, client_config, server_config, up, down, seed)
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
  first_sim.run()
  second_sim.run()
  first.client.send(first_sim, pattern_bytes(10_000))
  second.client.send(second_sim, pattern_bytes(10_000))
  first_sim.run()
  second_sim.run()
  inspect(first.client.retransmits(), content="1")
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
  inspect(pair.server.delivered().length(), content="5000")
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
  inspect(pair.server.delivered().length(), content="5000")
}

///|
test "out of order segments are buffered and then delivered in order" {
  let sim = @sim.Sim::new(1UL)
  let server = @tcp.TcpConnection::new(@tcp.TcpConfig::new(1000, 4096, 5000U))
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
    ),
  )
  inspect(server.delivered().length(), content="0")
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
    ),
  )
  inspect(server.delivered().length(), content="200")
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
    ),
  )
  let payload = pattern_bytes(100)
  let segment = @tcp.Segment::new(
    @tcp.Seq::of(1001U),
    @tcp.Seq::of(1001U),
    4096,
    @tcp.Flags::ack(),
    payload,
  )
  server.on_segment(sim, segment)
  inspect(server.delivered().length(), content="100")
  let before = server.duplicate_acks()
  server.on_segment(sim, segment)
  inspect(server.delivered().length(), content="100")
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
