///|
fn data_packet(id : Int, size : Int) -> @net.Packet[Unit] {
  // These tests use the packet id as its identity, so that loss can be reasoned
  // about packet by packet.
  @net.Packet::new(id, 0, @net.Data, size, id.to_uint64(), ())
}

///|
/// A packet with no identity, for the tests that exercise the fallback.
fn untagged_packet(id : Int, size : Int) -> @net.Packet[Unit] {
  @net.Packet::new(id, 0, @net.Data, size, 0UL, ())
}

///|
test "queue is first in first out" {
  let queue : @net.PacketQueue[Unit] = @net.PacketQueue::new(
    @net.QueueSpec::packets(4),
  )
  inspect(queue.enqueue(data_packet(1, 100)).to_string(), content="accepted")
  inspect(queue.enqueue(data_packet(2, 100)).to_string(), content="accepted")
  inspect(queue.length(), content="2")
  inspect(queue.dequeue().unwrap().id, content="1")
  inspect(queue.dequeue().unwrap().id, content="2")
  inspect(queue.is_empty(), content="true")
}

///|
test "queue refuses packets beyond its packet limit" {
  let queue : @net.PacketQueue[Unit] = @net.PacketQueue::new(
    @net.QueueSpec::packets(2),
  )
  inspect(queue.enqueue(data_packet(1, 100)).to_string(), content="accepted")
  inspect(queue.enqueue(data_packet(2, 100)).to_string(), content="accepted")
  inspect(
    queue.enqueue(data_packet(3, 100)).to_string(),
    content="dropped: packet limit",
  )
  inspect(queue.dropped(), content="1")
  inspect(queue.length(), content="2")
}

///|
test "queue refuses packets beyond its byte limit" {
  let queue : @net.PacketQueue[Unit] = @net.PacketQueue::new(
    @net.QueueSpec::bytes(3000),
  )
  inspect(queue.enqueue(data_packet(1, 1500)).to_string(), content="accepted")
  inspect(queue.enqueue(data_packet(2, 1500)).to_string(), content="accepted")
  inspect(
    queue.enqueue(data_packet(3, 1500)).to_string(),
    content="dropped: byte limit",
  )
  inspect(queue.bytes(), content="3000")
  inspect(queue.peak().1, content="3000")
}

///|
test "ring buffer keeps working across wrap-around" {
  let queue : @net.PacketQueue[Unit] = @net.PacketQueue::new(
    @net.QueueSpec::packets(3),
  )
  let mut index = 0
  let mut order_ok = true
  while index < 50 {
    queue.enqueue(data_packet(index, 10)) |> ignore
    let taken = queue.dequeue()
    match taken {
      None => order_ok = false
      Some(packet) => if packet.id != index { order_ok = false }
    }
    index = index + 1
  }
  inspect(order_ok, content="true")
  inspect(queue.is_empty(), content="true")
  inspect(queue.peak().0, content="1")
}

///|
test "link serializes at line rate and adds propagation delay" {
  let sim = @sim.Sim::new(1UL)
  let arrivals : Array[String] = []
  let link = @net.Link::new(
    @net.LinkSpec::new(
      "uplink",
      10_000_000L,
      @sim.Time::from_ms(5L),
      @net.QueueSpec::packets(10),
    ),
    1UL,
    _packet => arrivals.push(sim.now().render()),
  )
  link.send(sim, data_packet(1, 1500)) |> ignore
  sim.run()
  // 1500 bytes at 10 Mbps is 1.2 ms on the wire, plus 5 ms of propagation.
  inspect(arrivals.length(), content="1")
  inspect(arrivals[0], content="6.200ms")
}

///|
test "back-to-back packets queue instead of overlapping" {
  let sim = @sim.Sim::new(1UL)
  let arrivals : Array[String] = []
  let link = @net.Link::new(
    @net.LinkSpec::new(
      "uplink",
      10_000_000L,
      @sim.Time::from_ms(5L),
      @net.QueueSpec::packets(10),
    ),
    1UL,
    _packet => arrivals.push(sim.now().render()),
  )
  link.send(sim, data_packet(1, 1500)) |> ignore
  link.send(sim, data_packet(2, 1500)) |> ignore
  link.send(sim, data_packet(3, 1500)) |> ignore
  sim.run()
  inspect(arrivals.join(","), content="6.200ms,7.400ms,8.600ms")
  inspect(link.transmitted(), content="3")
  inspect(link.bytes_sent(), content="4500")
}

///|
test "a full link drops the packet that does not fit" {
  let sim = @sim.Sim::new(1UL)
  let link = @net.Link::new(
    @net.LinkSpec::new(
      "narrow",
      1_000_000L,
      @sim.Time::from_ms(1L),
      @net.QueueSpec::packets(1),
    ),
    1UL,
    _packet => (),
  )
  // The first packet takes the transmitter, the second waits in the one-slot
  // queue, and everything after that is dropped at the tail.
  inspect(link.send(sim, data_packet(1, 1500)).to_string(), content="accepted")
  inspect(link.send(sim, data_packet(2, 1500)).to_string(), content="accepted")
  inspect(
    link.send(sim, data_packet(3, 1500)).to_string(),
    content="dropped: packet limit",
  )
  sim.run()
  inspect(link.transmitted(), content="2")
  inspect(link.dropped(), content="1")
}

///|
test "utilization reflects a saturated link" {
  let sim = @sim.Sim::new(1UL)
  let link = @net.Link::new(
    @net.LinkSpec::new(
      "uplink",
      10_000_000L,
      @sim.Time::from_ms(10L),
      @net.QueueSpec::packets(10),
    ),
    1UL,
    _packet => (),
  )
  // Ten 1500-byte packets occupy the link for exactly 12 ms.
  let mut index = 0
  while index < 10 {
    link.send(sim, data_packet(index, 1500)) |> ignore
    index = index + 1
  }
  sim.run()
  inspect(link.busy_time().render(), content="12.000ms")
}

///|
test "jitter is reproducible for a given seed" {
  let first = @sim.Sim::new(7UL)
  let second = @sim.Sim::new(7UL)
  let first_arrivals : Array[String] = []
  let second_arrivals : Array[String] = []
  let spec = @net.LinkSpec::new(
    "lossy",
    1_000_000L,
    @sim.Time::from_ms(10L),
    @net.QueueSpec::packets(64),
  ).with_jitter(@sim.Time::from_ms(2L))
  let first_link = @net.Link::new(spec, 7UL, _packet => {
    first_arrivals.push(first.now().render())
  })
  let second_link = @net.Link::new(spec, 7UL, _packet => {
    second_arrivals.push(second.now().render())
  })
  let mut index = 0
  while index < 20 {
    first_link.send(first, data_packet(index, 200)) |> ignore
    second_link.send(second, data_packet(index, 200)) |> ignore
    index = index + 1
  }
  first.run()
  second.run()
  inspect(first_arrivals.length(), content="20")
  inspect(first_arrivals.join(",") == second_arrivals.join(","), content="true")
}

///|
test "wire size accounts for framing" {
  inspect(@net.wire_size(1500), content="1518")
  inspect(@net.default_mtu(), content="1500")
}

///|
/// Send one tagged packet through a fresh link, optionally after some untagged
/// traffic, and report whether the link lost it.
fn tagged_loss(
  spec : @net.LinkSpec,
  seed : UInt64,
  preamble : Int,
  tag : UInt64,
) -> Bool {
  let sim = @sim.Sim::new(1UL)
  let link : @net.Link[Unit] = @net.Link::new(spec, seed, _packet => ())
  let mut index = 0
  while index < preamble {
    link.send(sim, untagged_packet(index, 100)) |> ignore
    index = index + 1
  }
  // Let the preamble drain first, so that what is counted below belongs to the
  // tagged packet alone.
  sim.run()
  let before = link.lost()
  link.send(sim, @net.Packet::new(9_999, 0, @net.Data, 100, tag, ())) |> ignore
  sim.run()
  link.lost() > before
}

///|
/// A handful of identical packets, for measuring how often a link loses them.
fn loss_count(spec : @net.LinkSpec, count : Int, tagged : Bool) -> Int {
  let sim = @sim.Sim::new(1UL)
  let link : @net.Link[Unit] = @net.Link::new(spec, 1UL, _packet => ())
  let mut index = 0
  while index < count {
    let packet = if tagged {
      @net.Packet::new(index, 0, @net.Data, 100, index.to_uint64() + 1UL, ())
    } else {
      untagged_packet(index, 100)
    }
    link.send(sim, packet) |> ignore
    index = index + 1
  }
  sim.run()
  link.lost()
}

///|
test "a packet's fate follows its identity, not its place in the stream" {
  let spec = @net.LinkSpec::new(
    "identity",
    10_000_000L,
    @sim.Time::from_ms(1L),
    // Big enough that nothing is dropped at the queue: this test is about what
    // the wire does, not about what fits in the buffer.
    @net.QueueSpec::packets(1000),
  ).with_loss(0.5)
  // The same identity meets the same fate whether it is the first packet on the
  // link or the twenty-sixth: the decision does not depend on what came before.
  let alone = tagged_loss(spec, 1UL, 0, 7UL)
  let after_others = tagged_loss(spec, 1UL, 25, 7UL)
  let much_later = tagged_loss(spec, 1UL, 400, 7UL)
  // The decision itself is a number anyone can recompute: the fraction below is
  // what the link compares against its loss rate.
  let draw = (@sim.mix64(@sim.mix64(1UL, @sim.fnv1a64("identity")), 7UL) >> 11).to_double() /
    9007199254740992.0
  // A packet is lost exactly when its draw falls below the loss rate.
  inspect((draw < 0.5) == alone, content="true")
  inspect(alone == after_others, content="true")
  inspect(alone == much_later, content="true")
  // A different link seed is a different world, so the fate may differ; what
  // must not differ is the answer for one identity on one link.
  let repeated = tagged_loss(spec, 1UL, 0, 7UL)
  inspect(repeated == alone, content="true")
}

///|
test "losing by identity still loses about the configured fraction" {
  let spec = @net.LinkSpec::new(
    "rate",
    10_000_000L,
    @sim.Time::from_ms(1L),
    @net.QueueSpec::packets(1000),
  ).with_loss(0.25)
  let tagged = loss_count(spec, 400, true)
  // Identity-driven loss is a fixed pattern, not a fresh draw, so this number is
  // pinned like a random-number vector: it is part of what makes a run
  // reproducible.
  inspect(tagged, content="100")
  inspect(tagged > 60 && tagged < 140, content="true")
}

///|
test "an untagged packet falls back to the link's own stream" {
  let spec = @net.LinkSpec::new(
    "fallback",
    10_000_000L,
    @sim.Time::from_ms(1L),
    @net.QueueSpec::packets(1000),
  ).with_loss(0.25)
  // Two links with the same configuration lose the same packets, because the
  // stream is seeded, and consume it in transmission order.
  inspect(loss_count(spec, 200, false), content="50")
  inspect(loss_count(spec, 200, false), content="50")
}
