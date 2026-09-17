///|
/// A 32-bit TCP sequence number.
///
/// Sequence numbers wrap, so they cannot be compared with `<`. Two numbers on
/// opposite sides of the wrap point are "close" to each other even though their
/// numeric distance is enormous, and an implementation that compares them as
/// plain integers works perfectly until the day it does not. All comparisons go
/// through `before`, which measures the distance in the wrapping space where
/// half the space is "ahead" and half is "behind".
pub(all) struct Seq {
  value : UInt
} derive(Eq, Debug)

///|
/// Half of the sequence space, the boundary between "ahead" and "behind".
let seq_half : UInt = 0x80000000U

///|
pub fn Seq::of(value : UInt) -> Seq {
  { value, }
}

///|
/// True when `self` comes before `other` in the wrapping sequence space.
pub fn Seq::before(self : Seq, other : Seq) -> Bool {
  let distance = other.value - self.value
  distance > 0U && distance < seq_half
}

///|
/// True when `self` comes after `other`.
pub fn Seq::after(self : Seq, other : Seq) -> Bool {
  other.before(self)
}

///|
/// Advance by `length` bytes, wrapping like real TCP.
pub fn Seq::advance(self : Seq, length : Int) -> Seq {
  { value: self.value + length.reinterpret_as_uint(), }
}

///|
/// Signed distance from `self` to `other`, in bytes.
pub fn Seq::distance_to(self : Seq, other : Seq) -> Int {
  (other.value - self.value).reinterpret_as_int()
}

///|
pub fn Seq::to_string(self : Seq) -> String {
  self.value.to_string()
}

///|
/// The control bits a segment carries.
pub(all) struct Flags {
  syn : Bool
  ack : Bool
  fin : Bool
  rst : Bool
} derive(Eq, Debug)

///|
/// A segment with no control bits set: a plain data segment.
pub fn Flags::data() -> Flags {
  { syn: false, ack: false, fin: false, rst: false, }
}

///|
pub fn Flags::syn() -> Flags {
  { syn: true, ack: false, fin: false, rst: false, }
}

///|
pub fn Flags::syn_ack() -> Flags {
  { syn: true, ack: true, fin: false, rst: false, }
}

///|
pub fn Flags::ack() -> Flags {
  { syn: false, ack: true, fin: false, rst: false, }
}

///|
pub fn Flags::fin_ack() -> Flags {
  { syn: false, ack: true, fin: true, rst: false, }
}

///|
/// How many sequence numbers this segment consumes. SYN and FIN each occupy one
/// position in the sequence space even though they carry no payload; forgetting
/// that is the classic off-by-one that makes a handshake appear to work and the
/// first data segment appear to be missing one byte.
pub fn Flags::sequence_length(self : Flags, payload : Int) -> Int {
  let mut length = payload
  if self.syn {
    length = length + 1
  }
  if self.fin {
    length = length + 1
  }
  length
}

///|
pub fn Flags::render(self : Flags) -> String {
  let parts : Array[String] = []
  if self.syn {
    parts.push("SYN")
  }
  if self.ack {
    parts.push("ACK")
  }
  if self.fin {
    parts.push("FIN")
  }
  if self.rst {
    parts.push("RST")
  }
  if parts.length() == 0 {
    "DATA"
  } else {
    parts.join("+")
  }
}

///|
/// A TCP segment.
///
/// `window` is what the sender of this segment is willing to receive from now
/// on, in bytes: flow control is carried on every segment, including pure ACKs,
/// so a receiver that frees buffer space can always tell the peer about it.
pub(all) struct Segment {
  seq : Seq
  ack : Seq
  window : Int
  flags : Flags
  payload : Bytes
  /// The identity of this segment for the purpose of loss.
  ///
  /// It is derived from what the segment is — its starting sequence number and
  /// how many times that segment has been sent — rather than from when it was
  /// sent. A link that has decided to lose a packet identity would lose every
  /// repetition of it, so the transmission count has to be part of the
  /// identity; without it a lost segment could never be recovered.
  ///
  /// Zero means "no identity", which is what acknowledgments carry: the same
  /// acknowledgment is sent many times over, so it has no stable identity and
  /// the link falls back to its own stream.
  tag : UInt64
} derive(Debug)

///|
pub fn Segment::new(
  seq : Seq,
  ack : Seq,
  window : Int,
  flags : Flags,
  payload : Bytes,
  tag : UInt64,
) -> Segment {
  { seq, ack, window, flags, payload, tag, }
}

///|
/// A TCP header is 20 bytes when it carries no options. This simulator has no
/// options yet, so the number is exact rather than approximate.
pub fn header_bytes() -> Int {
  20
}

///|
/// The number of bytes this segment occupies on the wire.
pub fn Segment::wire_size(self : Segment) -> Int {
  header_bytes() + self.payload.length()
}

///|
/// Bytes of payload in this segment.
pub fn Segment::payload_length(self : Segment) -> Int {
  self.payload.length()
}

///|
/// A compact label used in journals, for example `SYN+ACK seq=1000 ack=4001`.
pub fn Segment::label(self : Segment) -> String {
  self.flags.render() +
  " seq=" +
  self.seq.to_string() +
  " ack=" +
  self.ack.to_string() +
  " len=" +
  self.payload.length().to_string() +
  " win=" +
  self.window.to_string()
}
