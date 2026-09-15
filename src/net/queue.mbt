///|
/// Why a queue did or did not accept a packet.
///
/// Returning a reason rather than a `Bool` is deliberate: "the packet was
/// dropped" is never enough information to explain a throughput result, so the
/// reason is recorded per packet and shows up in the report.
pub(all) enum Admission {
  Accepted
  DroppedPacketLimit
  DroppedByteLimit
}

///|
pub fn Admission::render(self : Admission) -> String {
  match self {
    Accepted => "accepted"
    DroppedPacketLimit => "dropped: packet limit"
    DroppedByteLimit => "dropped: byte limit"
  }
}

///|
pub impl Show for Admission with fn to_string(self) {
  self.render()
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
} derive(Eq, Debug)

///|
/// A queue with unlimited bytes, limited only by packet count.
pub fn QueueSpec::packets(max_packets : Int) -> QueueSpec {
  { max_packets, max_bytes: 0, }
}

///|
/// A queue limited by bytes only. `max_bytes` of 0 means "no byte limit".
pub fn QueueSpec::bytes(max_bytes : Int) -> QueueSpec {
  { max_packets: 1_000_000_000, max_bytes, }
}

///|
/// A drop-tail FIFO queue.
///
/// The storage is a ring buffer: `slots` is allocated once at its final size and
/// the queue never moves elements, so enqueue and dequeue are both O(1) and no
/// allocation happens during a run. Allocation inside an event handler is the
/// one thing that could make a simulation's timing depend on the host, and this
/// queue avoids it entirely.
pub(all) struct PacketQueue[T] {
  spec : QueueSpec
  mut slots : Array[Packet[T]?]
  mut head : Int
  mut count : Int
  mut bytes : Int
  mut admitted : Int
  mut dropped : Int
  mut dropped_bytes : Int
  mut peak_packets : Int
  mut peak_bytes : Int
}

///|
pub fn[T] PacketQueue::new(spec : QueueSpec) -> PacketQueue[T] {
  // The buffer grows on demand up to `max_packets`, so a queue that is limited
  // by bytes rather than by packet count does not allocate a slot per packet it
  // could theoretically hold.
  {
    spec,
    slots: Array::make(64, None),
    head: 0,
    count: 0,
    bytes: 0,
    admitted: 0,
    dropped: 0,
    dropped_bytes: 0,
    peak_packets: 0,
    peak_bytes: 0,
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
pub fn[T] PacketQueue::admitted(self : PacketQueue[T]) -> Int {
  self.admitted
}

///|
/// The largest occupancy seen so far, in packets and in bytes. These are the
/// numbers that make bufferbloat visible.
pub fn[T] PacketQueue::peak(self : PacketQueue[T]) -> (Int, Int) {
  (self.peak_packets, self.peak_bytes)
}

///|
/// Append a packet, or explain why it does not fit.
pub fn[T] PacketQueue::enqueue(
  self : PacketQueue[T],
  packet : Packet[T],
) -> Admission {
  if self.count >= self.spec.max_packets {
    self.dropped = self.dropped + 1
    self.dropped_bytes = self.dropped_bytes + packet.size
    return DroppedPacketLimit
  }
  if self.spec.max_bytes > 0 && self.bytes + packet.size > self.spec.max_bytes {
    self.dropped = self.dropped + 1
    self.dropped_bytes = self.dropped_bytes + packet.size
    return DroppedByteLimit
  }
  if self.count >= self.slots.length() {
    self.grow()
  }
  let index = (self.head + self.count) % self.slots.length()
  self.slots[index] = Some(packet)
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
/// Remove and return the oldest packet.
pub fn[T] PacketQueue::dequeue(self : PacketQueue[T]) -> Packet[T]? {
  if self.count == 0 {
    return None
  }
  let packet = self.slots[self.head]
  self.slots[self.head] = None
  self.head = (self.head + 1) % self.slots.length()
  self.count = self.count - 1
  match packet {
    None => None
    Some(value) => {
      self.bytes = self.bytes - value.size
      Some(value)
    }
  }
}

///|
/// Look at the oldest packet without removing it.
pub fn[T] PacketQueue::peek(self : PacketQueue[T]) -> Packet[T]? {
  if self.count == 0 {
    None
  } else {
    self.slots[self.head]
  }
}

///|
/// A text summary used by the report renderer and by tests.
pub fn[T] PacketQueue::summary(self : PacketQueue[T]) -> String {
  "queued=" +
  self.count.to_string() +
  " bytes=" +
  self.bytes.to_string() +
  " peak=" +
  self.peak_bytes.to_string() +
  "B admitted=" +
  self.admitted.to_string() +
  " dropped=" +
  self.dropped.to_string()
}
