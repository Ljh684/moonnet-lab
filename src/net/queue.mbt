///|
/// Why a queue did or did not accept a packet.
///
/// Returning a reason rather than a `Bool` is deliberate: "the packet was
/// dropped" is never enough information to explain a throughput result. "The
/// buffer was full" and "the buffer was well below full but the packet had
/// already waited too long" are different diagnoses with different fixes.
pub(all) enum Admission {
  Accepted
  DroppedPacketLimit
  DroppedByteLimit
  /// Refused before the buffer was full, by a policy that watches how long
  /// packets have been waiting rather than how many there are.
  DroppedEarly
} derive(Eq, Debug)

///|
pub fn Admission::render(self : Admission) -> String {
  match self {
    Accepted => "accepted"
    DroppedPacketLimit => "dropped: packet limit"
    DroppedByteLimit => "dropped: byte limit"
    DroppedEarly => "dropped: early (queue management)"
  }
}

///|
pub impl Show for Admission with fn to_string(self) {
  self.render()
}

///|
/// How a queue decides what to admit.
///
/// The set is closed on purpose, unlike congestion control, which is an open
/// interface: a queue discipline is tightly coupled to the buffer's own state —
/// occupancy and the arrival times of the packets in it — which an outside
/// object cannot see, so the policies live next to the queue they manage.
pub(all) enum QueueDiscipline {
  /// Admit until full, then refuse the rest. What a simple switch does, and what
  /// makes a standing queue possible.
  DropTail
  /// Random Early Detection: track an exponentially weighted mean occupancy and
  /// refuse packets with a probability that grows as that mean approaches the
  /// buffer's limit, so that drops happen before the buffer fills.
  /// The three numbers are, in order: the mean occupancy at which dropping
  /// starts (packets), the mean occupancy at which every packet is refused
  /// (packets), and the probability of refusing a packet when the mean sits at
  /// that second number.
  Red(Int, Int, Double)
  /// CoDel (RFC 8289): watch how long the packet at the head has been waiting,
  /// and once that stays above `target` for a whole `interval`, refuse one packet
  /// per interval, shrinking the interval as the drops accumulate.
  ///
  /// The parameter that matters is time, not occupancy: a long queue on a fast
  /// link is normal, and a short one on a slow link can already be too much.
  /// The two times are, in order: the sojourn above which the queue counts as
  /// standing, and how long that condition must persist before dropping starts.
  Codel(@sim.Time, @sim.Time)
} derive(Eq, Debug)

///|
/// CoDel's recommended defaults: 5 ms of standing queue is already too much, and
/// 100 ms is how often to act on it.
pub fn QueueDiscipline::codel() -> QueueDiscipline {
  Codel(@sim.Time::from_ms(5L), @sim.Time::from_ms(100L))
}

///|
/// RED configured from the buffer's own size: start dropping when the mean
/// occupancy passes a quarter of the buffer, refuse everything past three
/// quarters, and mark at most one packet in ten in between.
pub fn QueueDiscipline::red_for(max_packets : Int) -> QueueDiscipline {
  let small = max_packets <= 4
  let floor = if small { 1 } else { max_packets / 4 }
  let ceiling = if small { 2 } else { max_packets * 3 / 4 }
  Red(floor, ceiling, 0.1)
}

///|
/// Specifications of a bounded queue.
///
/// The packet limit models a switch's descriptor budget, the byte limit models
/// its buffer memory. Real devices limit both, and bufferbloat experiments
/// usually care about the byte limit, so the simulator carries both.
pub(all) struct QueueSpec {
  max_packets : Int
  max_bytes : Int
  discipline : QueueDiscipline
} derive(Eq, Debug)

///|
/// A queue with unlimited bytes, limited only by packet count.
pub fn QueueSpec::packets(max_packets : Int) -> QueueSpec {
  { max_packets, max_bytes: 0, discipline: DropTail, }
}

///|
/// A queue limited by bytes only. `max_bytes` of 0 means "no byte limit".
pub fn QueueSpec::bytes(max_bytes : Int) -> QueueSpec {
  { max_packets: 1_000_000_000, max_bytes, discipline: DropTail, }
}

///|
/// The same buffer, managed by a different discipline.
pub fn QueueSpec::with_discipline(
  self : QueueSpec,
  discipline : QueueDiscipline,
) -> QueueSpec {
  { ..self, discipline, }
}

///|
/// A packet waiting in a queue, with the time it arrived.
///
/// The arrival time is what makes queue management possible: a policy that only
/// knows how many bytes are buffered cannot tell a long queue on a fast link from
/// a short queue on a slow one, and that distinction is the whole point of CoDel.
struct Queued[T] {
  packet : Packet[T]
  enqueued_at : @sim.Time
}

///|
/// A bounded FIFO queue with a configurable discipline.
///
/// The storage is a ring buffer: `slots` is allocated once and the queue never
/// moves elements, so enqueue and dequeue are both O(1) and no allocation
/// happens during a run. Allocation inside an event handler is the one thing
/// that could make a simulation's timing depend on the host.
pub struct PacketQueue[T] {
  spec : QueueSpec
  /// The queue's own random stream, used by probabilistic policies. Derived from
  /// the link's seed, so a run stays reproducible down to which packet RED
  /// marked.
  rng : @sim.Rng
  mut slots : Array[Queued[T]?]
  mut head : Int
  mut count : Int
  mut bytes : Int
  mut admitted : Int
  mut dropped : Int
  mut dropped_bytes : Int
  mut dropped_tail : Int
  mut dropped_early : Int
  mut peak_packets : Int
  mut peak_bytes : Int
  /// Integral of occupancy over time, in packet-picoseconds. Dividing by elapsed
  /// time gives the mean occupancy, which is the number that says whether a queue
  /// was standing rather than merely busy.
  mut occupancy_integral : Int64
  mut observed_at : @sim.Time
  mut max_sojourn : @sim.Time
  // CoDel state (RFC 8289).
  mut first_above : @sim.Time
  mut dropping : Bool
  mut drop_next : @sim.Time
  mut drop_count : Int
  // RED state.
  mut average_occupancy : Double
  /// When the previous packet arrived. RED's average is a per-packet average,
  /// and a queue that has been quiet needs that gap folded into it; without
  /// this the average keeps describing a backlog that has already drained.
  mut last_arrival_at : @sim.Time
  /// When the previous packet left, and how long a packet takes on this link,
  /// measured as the gap between consecutive departures while the link was
  /// busy. That measurement is what turns an idle gap into "packets that could
  /// have arrived", which is the form Floyd's correction is written in.
  mut last_departure_at : @sim.Time
  mut service_time : @sim.Time
}

///|
pub fn[T] PacketQueue::new(spec : QueueSpec, seed : UInt64) -> PacketQueue[T] {
  // The buffer grows on demand up to `max_packets`, so a queue that is limited
  // by bytes rather than by packet count does not allocate a slot per packet it
  // could theoretically hold.
  {
    spec,
    rng: @sim.Rng::new(seed).fork("queue"),
    slots: Array::make(64, None),
    head: 0,
    count: 0,
    bytes: 0,
    admitted: 0,
    dropped: 0,
    dropped_bytes: 0,
    dropped_tail: 0,
    dropped_early: 0,
    peak_packets: 0,
    peak_bytes: 0,
    occupancy_integral: 0L,
    observed_at: @sim.Time::zero(),
    max_sojourn: @sim.Time::zero(),
    first_above: @sim.Time::zero(),
    dropping: false,
    drop_next: @sim.Time::zero(),
    drop_count: 0,
    average_occupancy: 0.0,
    last_arrival_at: @sim.Time::zero(),
    last_departure_at: @sim.Time::zero(),
    service_time: @sim.Time::zero(),
  }
}

///|
/// Double the ring buffer, linearising the live packets at the front.
///
/// Growth stops at the configured packet limit, so `max_packets` remains the
/// authoritative bound on memory even though the buffer starts small.
fn[T] PacketQueue::grow(self : PacketQueue[T]) -> Unit {
  let old_size = self.slots.length()
  if old_size >= self.spec.max_packets {
    return
  }
  let doubled = old_size * 2
  let new_size = if doubled > self.spec.max_packets {
    self.spec.max_packets
  } else {
    doubled
  }
  let wider = Array::make(new_size, None)
  let mut index = 0
  while index < self.count {
    wider[index] = self.slots[(self.head + index) % old_size]
    index = index + 1
  }
  self.slots = wider
  self.head = 0
}

///|
/// Fold the occupancy since the last observation into the running integral.
fn[T] PacketQueue::observe(self : PacketQueue[T], now : @sim.Time) -> Unit {
  let elapsed = now.ps - self.observed_at.ps
  if elapsed > 0L {
    self.occupancy_integral = self.occupancy_integral +
      self.count.to_int64() * elapsed
    self.observed_at = now
  }
}

///|
pub fn[T] PacketQueue::length(self : PacketQueue[T]) -> Int {
  self.count
}

///|
pub fn[T] PacketQueue::bytes(self : PacketQueue[T]) -> Int {
  self.bytes
}

///|
pub fn[T] PacketQueue::is_empty(self : PacketQueue[T]) -> Bool {
  self.count == 0
}

///|
/// How many packets were refused by this queue since the run began.
pub fn[T] PacketQueue::dropped(self : PacketQueue[T]) -> Int {
  self.dropped
}

///|
/// Packets refused because the buffer was full.
pub fn[T] PacketQueue::dropped_at_tail(self : PacketQueue[T]) -> Int {
  self.dropped_tail
}

///|
/// Packets refused by queue management before the buffer was full.
pub fn[T] PacketQueue::dropped_early(self : PacketQueue[T]) -> Int {
  self.dropped_early
}

///|
pub fn[T] PacketQueue::admitted(self : PacketQueue[T]) -> Int {
  self.admitted
}

///|
/// The average occupancy RED is currently deciding from, in packets.
///
/// Exposed because it is the number the policy acts on: a report that shows
/// drops without it cannot say whether the queue was standing or the average
/// was stale. Zero for disciplines that do not keep an average.
pub fn[T] PacketQueue::average_occupancy(self : PacketQueue[T]) -> Double {
  self.average_occupancy
}

///|
/// The largest occupancy seen so far, in packets and in bytes.
pub fn[T] PacketQueue::peak(self : PacketQueue[T]) -> (Int, Int) {
  (self.peak_packets, self.peak_bytes)
}

///|
/// The longest a packet waited in this queue.
///
/// Measured on departure, so it is the worst wait of a packet that was actually
/// sent and it is comparable between disciplines. The wait of a packet that a
/// discipline refused belongs to that packet's story rather than to the delay
/// this queue adds to the traffic that gets through.
pub fn[T] PacketQueue::max_sojourn(self : PacketQueue[T]) -> @sim.Time {
  self.max_sojourn
}

///|
/// Mean occupancy over the interval since the run began, in packets.
///
/// A queue that is frequently full but empties between bursts and one that holds
/// a permanent backlog can have the same peak; only the mean tells them apart.
pub fn[T] PacketQueue::mean_occupancy(
  self : PacketQueue[T],
  now : @sim.Time,
) -> Double {
  self.observe(now)
  if now.ps <= 0L {
    0.0
  } else {
    self.occupancy_integral.to_double() / now.ps.to_double()
  }
}

///|
/// Append a packet, or explain why it does not fit.
pub fn[T] PacketQueue::enqueue(
  self : PacketQueue[T],
  packet : Packet[T],
  now : @sim.Time,
) -> Admission {
  self.observe(now)
  self.note_arrival(now)
  if self.count >= self.spec.max_packets {
    return self.refuse(packet, DroppedPacketLimit, false)
  }
  if self.spec.max_bytes > 0 && self.bytes + packet.size > self.spec.max_bytes {
    return self.refuse(packet, DroppedByteLimit, false)
  }
  // Queue management decides before the buffer is full.
  if self.should_drop_early(now) {
    return self.refuse(packet, DroppedEarly, true)
  }
  if self.count >= self.slots.length() {
    self.grow()
  }
  let index = (self.head + self.count) % self.slots.length()
  self.slots[index] = Some({ packet, enqueued_at: now, })
  self.count = self.count + 1
  self.bytes = self.bytes + packet.size
  self.admitted = self.admitted + 1
  if self.count > self.peak_packets {
    self.peak_packets = self.count
  }
  if self.bytes > self.peak_bytes {
    self.peak_bytes = self.bytes
  }
  Accepted
}

///|
fn[T] PacketQueue::refuse(
  self : PacketQueue[T],
  packet : Packet[T],
  reason : Admission,
  early : Bool,
) -> Admission {
  self.dropped = self.dropped + 1
  self.dropped_bytes = self.dropped_bytes + packet.size
  if early {
    self.dropped_early = self.dropped_early + 1
  } else {
    self.dropped_tail = self.dropped_tail + 1
  }
  reason
}

///|
/// Ask the configured discipline about the packet that has just arrived.
///
/// Both policies look at the *head* of the queue rather than at the arriving
/// packet: what matters is how long the oldest packet has been waiting, because
/// that is the delay the new arrival is about to join.
fn[T] PacketQueue::should_drop_early(
  self : PacketQueue[T],
  now : @sim.Time,
) -> Bool {
  match self.spec.discipline {
    DropTail => false
    Red(min_packets, max_packets, max_mark) => {
      // The average itself is maintained by `note_arrival`, which runs on every
      // arrival whether or not the packet fits: a policy that stopped watching
      // the queue as soon as the buffer filled would be blind exactly when it
      // matters. What is left here is the decision.
      let average = self.average_occupancy
      if average < min_packets.to_double() {
        false
      } else if average >= max_packets.to_double() {
        true
      } else {
        let span = (max_packets - min_packets).to_double()
        let probability = max_mark * (average - min_packets.to_double()) / span
        self.rng.next_double() < probability
      }
    }
    Codel(target, interval) => self.codel_should_drop(now, target, interval)
  }
}

///|
/// Fold the time since the previous arrival into RED's average occupancy.
///
/// The average is defined per arriving packet, so on its own it only decays
/// when packets arrive. A sender that goes quiet therefore leaves the average
/// describing a queue that no longer exists, and the next packet - arriving
/// into an *empty* buffer - is refused because of a backlog that has drained.
/// That is not a defect of the formula, it is a missing term: Floyd's
/// description decays the average by `(1-w)^m`, where `m` is how many packets
/// could have arrived during the idle gap. This computes that `m` from the
/// link's own measured packet time rather than from a configured line rate, so
/// the queue does not have to be told anything new.
fn[T] PacketQueue::note_arrival(self : PacketQueue[T], now : @sim.Time) -> Unit {
  match self.spec.discipline {
    Red(_, _, _) => {
      let gap = now.ps - self.last_arrival_at.ps
      let service = self.service_time.ps
      if service > 0L && gap > service {
        // Repeated multiplication rather than `pow`: the same expression then
        // evaluates to the same bits on every backend, which is the promise
        // the rest of the project makes. The cap bounds the work a single
        // arrival can do after an arbitrarily long quiet period.
        let periods = gap / service
        let capped = if periods > 4096L { 4096L } else { periods }
        let mut index = 0L
        while index < capped {
          self.average_occupancy = self.average_occupancy * 0.998
          index = index + 1L
        }
      }
      // Exponentially weighted mean occupancy, weight 0.002 as in the original
      // description: it reacts over roughly a round trip's worth of packets
      // rather than to a single burst. The idle decay above is the same term
      // Floyd writes as `(1-w)^m`.
      self.average_occupancy = self.average_occupancy * 0.998 +
        self.count.to_double() * 0.002
    }
    _ => ()
  }
  self.last_arrival_at = now
}

///|
/// CoDel's control law, evaluated at arrival.
///
/// The reference implementation evaluates this on dequeue; here it runs on
/// arrival against the head's sojourn. Both the signal (the sojourn time of the
/// oldest packet) and the response (one drop per interval while that stays above
/// target, with the interval shrinking as `interval / sqrt(count)`) are the ones
/// RFC 8289 specifies, and evaluating at arrival avoids making the link take a
/// packet and then abandon it.
fn[T] PacketQueue::codel_should_drop(
  self : PacketQueue[T],
  now : @sim.Time,
  target : @sim.Time,
  interval : @sim.Time,
) -> Bool {
  if self.count == 0 {
    return false
  }
  let sojourn = self.head_sojourn(now)
  if sojourn.ps < target.ps {
    // Below target: the queue is not standing. Leave the dropping state once an
    // interval has passed without the condition recurring.
    if self.dropping && now.ps >= self.drop_next.ps {
      self.dropping = false
      self.first_above = @sim.Time::zero()
    }
    return false
  }
  if self.first_above.ps == 0L {
    // First packet to find the queue standing: give the condition one interval
    // to prove it is persistent rather than a burst.
    self.first_above = @sim.Time::from_ps(now.ps + interval.ps)
    return false
  }
  if now.ps < self.first_above.ps {
    return false
  }
  if !self.dropping {
    self.dropping = true
    self.drop_count = 1
    self.drop_next = @sim.Time::from_ps(now.ps + interval.ps)
    return true
  }
  if now.ps < self.drop_next.ps {
    return false
  }
  self.drop_count = self.drop_count + 1
  // The interval between drops shrinks as the square root of the number of drops:
  // a backlog that persists is pushed back on harder the longer it lasts.
  self.drop_next = @sim.Time::from_ps(
    now.ps +
    (interval.ps.to_double() / sqrt_approx(self.drop_count.to_double())).to_int64(),
  )
  true
}

///|
fn sqrt_approx(value : Double) -> Double {
  if value <= 0.0 {
    1.0
  } else {
    @math.pow(value, 0.5)
  }
}

///|
fn[T] PacketQueue::head_sojourn(
  self : PacketQueue[T],
  now : @sim.Time,
) -> @sim.Time {
  if self.count == 0 {
    return @sim.Time::zero()
  }
  match self.slots[self.head] {
    None => @sim.Time::zero()
    Some(entry) => @sim.Time::from_ps(now.ps - entry.enqueued_at.ps)
  }
}

///|
/// Remove and return the oldest packet.
pub fn[T] PacketQueue::dequeue(
  self : PacketQueue[T],
  now : @sim.Time,
) -> Packet[T]? {
  self.observe(now)
  if self.count == 0 {
    return None
  }
  let entry = self.slots[self.head]
  self.slots[self.head] = None
  self.head = (self.head + 1) % self.slots.length()
  self.count = self.count - 1
  // While packets are still waiting behind this one, the link is saturated and
  // the gap between two departures is exactly one packet's serialisation time.
  // Measuring it here is what lets RED's idle correction speak in packets
  // without anyone configuring a bandwidth.
  let departure_gap = now.ps - self.last_departure_at.ps
  if self.count > 0 && self.last_departure_at.ps > 0L && departure_gap > 0L {
    self.service_time = if self.service_time.ps == 0L {
      @sim.Time::from_ps(departure_gap)
    } else {
      @sim.Time::from_ps((self.service_time.ps * 3L + departure_gap) / 4L)
    }
  }
  self.last_departure_at = now
  match entry {
    None => None
    Some(value) => {
      self.bytes = self.bytes - value.packet.size
      let sojourn = now.ps - value.enqueued_at.ps
      if sojourn > self.max_sojourn.ps {
        self.max_sojourn = @sim.Time::from_ps(sojourn)
      }
      Some(value.packet)
    }
  }
}

///|
/// Look at the oldest packet without removing it.
pub fn[T] PacketQueue::peek(self : PacketQueue[T]) -> Packet[T]? {
  if self.count == 0 {
    None
  } else {
    match self.slots[self.head] {
      None => None
      Some(entry) => Some(entry.packet)
    }
  }
}

///|
/// A text summary used by the report renderer and by tests.
pub fn[T] PacketQueue::summary(
  self : PacketQueue[T],
  now : @sim.Time,
) -> String {
  "queued=" +
  self.count.to_string() +
  " mean=" +
  format_one_decimal(self.mean_occupancy(now)) +
  " peak=" +
  self.peak_packets.to_string() +
  " admitted=" +
  self.admitted.to_string() +
  " dropped=" +
  self.dropped.to_string() +
  " (tail " +
  self.dropped_tail.to_string() +
  ", early " +
  self.dropped_early.to_string() +
  ")"
}

///|
/// A number with one decimal, formatted through integers so that two runs produce
/// the same text.
pub fn format_one_decimal(value : Double) -> String {
  let tenths = (value * 10.0).to_int64()
  (tenths / 10L).to_string() + "." + (tenths % 10L).to_string()
}
