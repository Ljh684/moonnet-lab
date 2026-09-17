///|
/// The static description of a link.
///
/// Everything here is a property of the medium, not of a particular packet:
/// bandwidth is bits per second on the wire, `delay` is one-way propagation
/// time, and `jitter` is the width of a uniform spread around it.
pub(all) struct LinkSpec {
  name : String
  bandwidth_bps : Int64
  delay : @sim.Time
  jitter : @sim.Time
  /// Probability that a packet is lost on the wire, in `[0, 1]`.
  ///
  /// Loss happens after serialization: a lost packet still occupies the link for
  /// its full transmission time, the way a corrupted frame does on a real wire.
  loss_rate : Double
  queue : QueueSpec
} derive(Eq, Debug)

///|
/// A link with no jitter and a drop-tail queue.
pub fn LinkSpec::new(
  name : String,
  bandwidth_bps : Int64,
  delay : @sim.Time,
  queue : QueueSpec,
) -> LinkSpec {
  {
    name,
    bandwidth_bps,
    delay,
    jitter: @sim.Time::zero(),
    loss_rate: 0.0,
    queue,
  }
}

///|
/// The same link, with a uniform jitter of plus or minus `jitter` around the
/// propagation delay. Jitter is drawn from the link's own random stream, so it
/// is reproducible and independent of every other link.
pub fn LinkSpec::with_jitter(self : LinkSpec, jitter : @sim.Time) -> LinkSpec {
  { ..self, jitter, }
}

///|
/// The same link, now losing the given fraction of the packets it transmits.
///
/// The decision comes from the link's own random stream, so "1% loss" is not
/// "roughly 1% today" but the exact same set of lost packets on every run.
pub fn LinkSpec::with_loss(self : LinkSpec, rate : Double) -> LinkSpec {
  { ..self, loss_rate: rate, }
}

///|
/// A one-way link: it serializes packets at its bandwidth, queues what it cannot
/// send yet, and delivers packets to a sink after the propagation delay.
///
/// The link owns no timer of its own; it asks the simulator to wake it up when
/// the current transmission finishes, which is what keeps "how long is the link
/// busy" a question about the model rather than about the host's clock.
pub(all) struct Link[T] {
  spec : LinkSpec
  rng : @sim.Rng
  /// The number that decides loss for a packet identity on this link. Derived
  /// from the seed and the link's name, so two links configured alike but named
  /// differently do not lose the same packets.
  loss_key : UInt64
  queue : PacketQueue[T]
  deliver : (Packet[T]) -> Unit
  mut busy_until : @sim.Time
  mut service_time : @sim.Time
  mut started_at : @sim.Time
  mut transmitted : Int
  mut bytes_sent : Int64
  mut lost : Int
}

///|
pub fn[T] Link::new(
  spec : LinkSpec,
  seed : UInt64,
  deliver : (Packet[T]) -> Unit,
) -> Link[T] {
  {
    spec,
    rng: @sim.Rng::new(seed).fork("link/" + spec.name),
    loss_key: @sim.mix64(seed, @sim.fnv1a64(spec.name)),
    queue: PacketQueue::new(spec.queue),
    deliver,
    busy_until: @sim.Time::zero(),
    service_time: @sim.Time::zero(),
    started_at: @sim.Time::zero(),
    transmitted: 0,
    bytes_sent: 0L,
    lost: 0,
  }
}

///|
/// The name this link was configured with.
pub fn[T] Link::name(self : Link[T]) -> String {
  self.spec.name
}

///|
/// Hand a packet to the link.
///
/// A packet that does not fit is dropped here, at the tail of the queue: that is
/// the "drop-tail" behavior every later active-queue experiment is compared
/// against.
pub fn[T] Link::send(
  self : Link[T],
  sim : @sim.Sim,
  packet : Packet[T],
) -> Admission {
  if self.queue.is_empty() {
    self.started_at = sim.now()
  }
  let admission = self.queue.enqueue(packet)
  match admission {
    Accepted => self.pump(sim)
    _ => ()
  }
  admission
}

///|
/// Start transmitting the next queued packet, if any.
///
/// The link may only be pumping one packet at a time. When two packets are
/// handed over in the same picosecond the second one finds the link busy and
/// waits, and it is the "link free" event that wakes the pump up again. Without
/// this guard the two transmissions would overlap and the model would silently
/// invent bandwidth that does not exist.
pub fn[T] Link::pump(self : Link[T], sim : @sim.Sim) -> Unit {
  if sim.now().ps < self.busy_until.ps {
    return
  }
  match self.queue.dequeue() {
    None => ()
    Some(packet) => {
      let service = @sim.Time::serialize(
        packet.size.to_int64(),
        self.spec.bandwidth_bps,
      )
      let departure = sim.now() + service
      let arrival = departure + self.spec.delay + self.draw_jitter(sim)
      self.busy_until = departure
      self.service_time = self.service_time + service
      self.transmitted = self.transmitted + 1
      self.bytes_sent = self.bytes_sent + packet.size.to_int64()
      let link_name = self.spec.name
      let id = packet.id
      if self.draw_loss(sim, packet.tag) {
        self.lost = self.lost + 1
        if sim.is_recording() {
          sim.note(
            link_name +
            " loses #" +
            id.to_string() +
            " tag " +
            packet.tag.to_string(),
          )
        }
      } else {
        sim.at(arrival, link_name + " delivers #" + id.to_string(), () => {
          (self.deliver)(packet)
        })
      }
      sim.at(departure, link_name + " free", () => self.pump(sim))
    }
  }
}

///|
/// Decide whether the transmission that just started is lost.
///
/// A packet that carries a tag is judged on its identity: the same tag on the
/// same link always meets the same fate, whatever else was transmitted in
/// between. That is what lets two senders be compared on the same lost packets
/// rather than merely on the same conditions.
///
/// A packet with no tag — an acknowledgment, whose identity is not stable
/// because the same acknowledgment is sent repeatedly — falls back to drawing
/// from the link's own stream. Its loss pattern is therefore still a property of
/// transmission order, which is worth knowing when reading a comparison: the
/// data loss is controlled, the acknowledgment loss is not.
///
/// The draw is skipped entirely on a loss-free link, so adding a reliable link
/// to a scenario cannot shift the random stream of the links around it.
pub fn[T] Link::draw_loss(self : Link[T], sim : @sim.Sim, tag : UInt64) -> Bool {
  if self.spec.loss_rate <= 0.0 {
    false
  } else if self.spec.loss_rate >= 1.0 {
    true
  } else if tag != 0UL {
    let draw = @sim.mix64(self.loss_key, tag)
    (draw >> 11).to_double() / 9007199254740992.0 < self.spec.loss_rate
  } else {
    sim.rng().next_double() < self.spec.loss_rate
  }
}

///|
/// One jitter sample, uniform on `[-jitter, +jitter]`.
///
/// The sample is clamped so that a packet can never arrive before it left; a
/// negative propagation delay would break every later consistency check.
pub fn[T] Link::draw_jitter(self : Link[T], sim : @sim.Sim) -> @sim.Time {
  let width = self.spec.jitter.ps
  if width <= 0L {
    return @sim.Time::zero()
  }
  let span = width * 2L
  let offset = (sim.rng().next_double() * span.to_double()).to_int64() - width
  let bounded = if offset < -self.spec.delay.ps {
    -self.spec.delay.ps
  } else if offset > self.spec.delay.ps {
    self.spec.delay.ps
  } else {
    offset
  }
  @sim.Time::from_ps(bounded)
}

///|
/// How long the link has been transmitting since the run began.
pub fn[T] Link::busy_time(self : Link[T]) -> @sim.Time {
  self.service_time
}

///|
/// Fraction of the observed interval the link spent serializing bits, in
/// `[0, 1]`. This is the number that says whether a path is saturated.
pub fn[T] Link::utilization(self : Link[T], sim : @sim.Sim) -> Double {
  let elapsed = sim.now().ps - self.started_at.ps
  if elapsed <= 0L {
    0.0
  } else {
    self.service_time.ps.to_double() / elapsed.to_double()
  }
}

///|
/// Packets that reached the far end.
pub fn[T] Link::transmitted(self : Link[T]) -> Int {
  self.transmitted
}

///|
/// Bytes that reached the far end.
pub fn[T] Link::bytes_sent(self : Link[T]) -> Int64 {
  self.bytes_sent
}

///|
/// Packets this link refused.
pub fn[T] Link::dropped(self : Link[T]) -> Int {
  self.queue.dropped()
}

///|
/// Packets this link accepted, transmitted, and then lost on the wire.
pub fn[T] Link::lost(self : Link[T]) -> Int {
  self.lost
}

///|
/// A one-line summary for reports and tests.
pub fn[T] Link::summary(self : Link[T], sim : @sim.Sim) -> String {
  self.spec.name +
  ": " +
  self.transmitted.to_string() +
  " packets, " +
  self.bytes_sent.to_string() +
  " bytes, " +
  self.dropped().to_string() +
  " dropped, " +
  self.lost.to_string() +
  " lost, utilization " +
  percent(self.utilization(sim))
}

///|
/// A percentage with one fractional digit, formatted with integer arithmetic so
/// that reports are byte-identical across backends.
pub fn percent(fraction : Double) -> String {
  let tenths = (fraction * 1000.0).to_int64()
  (tenths / 10L).to_string() + "." + (tenths % 10L).to_string() + "%"
}
