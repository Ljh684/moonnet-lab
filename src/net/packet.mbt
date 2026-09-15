///|
/// What a packet is carrying. The network layer only needs to know enough to
/// model it; whatever protocol produced the packet keeps its own richer payload
/// in `Packet::payload`.
pub(all) enum PacketKind {
  Data
  Ack
  Syn
  SynAck
  Fin
}

///|
pub fn PacketKind::render(self : PacketKind) -> String {
  match self {
    Data => "data"
    Ack => "ack"
    Syn => "syn"
    SynAck => "syn-ack"
    Fin => "fin"
  }
}

///|
pub impl Show for PacketKind with fn to_string(self) {
  self.render()
}

///|
/// A packet as the network layer sees it.
///
/// `size` is the number of bytes that actually occupy the wire, including
/// headers: that is the quantity that costs serialization time, and getting it
/// right is what makes throughput numbers meaningful.
///
/// The payload type is a parameter so that the TCP layer can hang its segment
/// state off the same packet the link layer schedules, without the link layer
/// depending on TCP.
pub(all) struct Packet[T] {
  id : Int
  flow : Int
  kind : PacketKind
  size : Int
  payload : T
}

///|
pub fn[T] Packet::new(
  id : Int,
  flow : Int,
  kind : PacketKind,
  size : Int,
  payload : T,
) -> Packet[T] {
  { id, flow, kind, size, payload, }
}

///|
/// A short, stable label used in journals and reports.
pub fn[T] Packet::label(self : Packet[T]) -> String {
  "flow" +
  self.flow.to_string() +
  "/" +
  self.kind.render() +
  "#" +
  self.id.to_string()
}

///|
/// The MTU the simulator assumes unless a scenario says otherwise. This is the
/// payload size of a standard Ethernet frame; the 14-byte Ethernet header and
/// 4-byte FCS are accounted for separately in `frame_overhead`.
pub fn default_mtu() -> Int {
  1500
}

///|
/// Bytes a payload picks up from link-layer framing.
pub fn frame_overhead() -> Int {
  18
}

///|
/// The wire size of a payload of `bytes` bytes, including framing.
pub fn wire_size(bytes : Int) -> Int {
  bytes + frame_overhead()
}
