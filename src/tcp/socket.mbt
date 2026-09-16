///|
/// The connection states of RFC 793.
pub(all) enum TcpState {
  Closed
  Listen
  SynSent
  SynReceived
  Established
  FinWait1
  FinWait2
  CloseWait
  Closing
  LastAck
  TimeWait
} derive(Eq, Debug)

///|
pub fn TcpState::render(self : TcpState) -> String {
  match self {
    Closed => "CLOSED"
    Listen => "LISTEN"
    SynSent => "SYN-SENT"
    SynReceived => "SYN-RECEIVED"
    Established => "ESTABLISHED"
    FinWait1 => "FIN-WAIT-1"
    FinWait2 => "FIN-WAIT-2"
    CloseWait => "CLOSE-WAIT"
    Closing => "CLOSING"
    LastAck => "LAST-ACK"
    TimeWait => "TIME-WAIT"
  }
}

///|
pub impl Show for TcpState with fn to_string(self) {
  self.render()
}

///|
/// Connection parameters. Everything a run depends on is explicit here, so a
/// scenario file can describe a connection completely.
pub(all) struct TcpConfig {
  /// Largest payload this end will put in one segment.
  mss : Int
  /// How many bytes this end is willing to buffer out of order.
  receive_window : Int
  /// Initial sequence number. Real TCP picks this from a clock; here it comes
  /// from the scenario so that every run starts from the same place.
  initial_seq : UInt
  /// How long to sit in TIME-WAIT. Twice the maximum segment lifetime.
  two_msl : @sim.Time
} derive(Eq, Debug)

///|
pub fn TcpConfig::new(
  mss : Int,
  receive_window : Int,
  initial_seq : UInt,
) -> TcpConfig {
  { mss, receive_window, initial_seq, two_msl: @sim.Time::from_s(60L), }
}

///|
/// A segment that has been sent but not yet acknowledged.
///
/// `payload_length` and `sequence_length` differ by one for a SYN or a FIN.
/// Keeping both lets acknowledgment accounting report application bytes without
/// the control bits corrupting the totals.
struct InFlight {
  seq : Seq
  payload_length : Int
  sequence_length : Int
}

///|
/// A segment that arrived before its predecessors did.
struct Buffered {
  seq : Seq
  payload : Bytes
}

///|
/// One end of a TCP connection.
///
/// The connection is deliberately passive: it never schedules anything for
/// itself. It reacts to segments handed to it, and it hands outgoing segments to
/// whatever `emit` is set to. That keeps the TCP logic testable without a
/// network, and keeps "when does this happen" in the simulator rather than
/// inside the protocol.
pub(all) struct TcpConnection {
  config : TcpConfig
  mut state : TcpState
  mut emit : (Segment) -> Unit
  mut snd_una : Seq
  mut snd_nxt : Seq
  mut rcv_nxt : Seq
  mut peer_window : Int
  mut send_queue : Bytes
  mut fin_seq : Seq?
  mut peer_fin : Bool
  inflight : Array[InFlight]
  reorder : Array[Buffered]
  mut delivered : Bytes
  mut segments_sent : Int
  mut segments_received : Int
  mut bytes_sent : Int
  mut bytes_acked : Int
  mut duplicate_acks : Int
}

///|
pub fn TcpConnection::new(config : TcpConfig) -> TcpConnection {
  let iss = Seq::of(config.initial_seq)
  {
    config,
    state: Closed,
    emit: _segment => (),
    snd_una: iss,
    snd_nxt: iss,
    rcv_nxt: iss,
    peer_window: 0,
    send_queue: Bytes::new(0),
    fin_seq: None,
    peer_fin: false,
    inflight: [],
    reorder: [],
    delivered: Bytes::new(0),
    segments_sent: 0,
    segments_received: 0,
    bytes_sent: 0,
    bytes_acked: 0,
    duplicate_acks: 0,
  }
}

///|
/// Install the outgoing path. Until this is called the connection is a black
/// hole that accepts segments and produces none.
pub fn TcpConnection::set_emit(
  self : TcpConnection,
  emit : (Segment) -> Unit,
) -> Unit {
  self.emit = emit
}

///|
/// Become the passive side: wait for someone to connect.
pub fn TcpConnection::listen(self : TcpConnection) -> Unit {
  self.state = Listen
}

///|
/// Become the active side: send a SYN.
pub fn TcpConnection::connect(self : TcpConnection, sim : @sim.Sim) -> Unit {
  if self.state != Closed {
    abort(
      "connect() requires a closed connection, state is " + self.state.render(),
    )
  }
  self.state = SynSent
  self.send_control(sim, Flags::syn(), 1)
}

///|
/// Queue application data and send as much of it as the peer's window allows.
pub fn TcpConnection::send(
  self : TcpConnection,
  sim : @sim.Sim,
  data : Bytes,
) -> Unit {
  if data.length() > 0 {
    self.send_queue = self.send_queue.add(data)
  }
  self.pump(sim)
}

///|
/// Close the connection. Only the `ESTABLISHED` and `CLOSE-WAIT` transitions are
/// modeled; a FIN sent from the middle of the handshake is a case this simulator
/// does not need yet.
pub fn TcpConnection::close(self : TcpConnection, sim : @sim.Sim) -> Unit {
  match self.state {
    Established => {
      self.send_control(sim, Flags::fin_ack(), 1)
      self.state = FinWait1
    }
    CloseWait => {
      self.send_control(sim, Flags::fin_ack(), 1)
      self.state = LastAck
    }
    _ => ()
  }
}

///|
/// Handle one received segment.
pub fn TcpConnection::on_segment(
  self : TcpConnection,
  sim : @sim.Sim,
  segment : Segment,
) -> Unit {
  self.segments_received = self.segments_received + 1
  sim.note("recv  " + segment.label())
  if segment.flags.rst {
    self.state = Closed
    return
  }
  if segment.flags.ack {
    self.process_ack(sim, segment.ack, segment.window)
  }
  if segment.flags.syn {
    self.accept_syn(sim, segment)
  }
  if segment.payload.length() > 0 {
    self.accept_payload(sim, segment)
  }
  if segment.flags.fin {
    self.accept_fin(sim, segment)
  }
}

///|
/// The state machine's response to a SYN.
fn TcpConnection::accept_syn(
  self : TcpConnection,
  sim : @sim.Sim,
  segment : Segment,
) -> Unit {
  match self.state {
    Listen => {
      // The SYN consumes one sequence number before any data can arrive.
      self.rcv_nxt = segment.seq.advance(1)
      self.peer_window = segment.window
      self.send_control(sim, Flags::syn_ack(), 1)
      self.state = SynReceived
    }
    SynSent => {
      // Our SYN was acknowledged by `process_ack`; the peer's SYN is the other
      // half of the handshake.
      self.rcv_nxt = segment.seq.advance(1)
      self.state = Established
      self.emit_ack(sim)
      self.pump(sim)
    }
    _ => ()
  }
}

///|
/// Deliver in-order payload, trim duplicates, buffer what arrived early, and
/// acknowledge the result.
///
/// Every received data segment is acknowledged immediately. Delayed
/// acknowledgments are a later feature; when they land, this is the function
/// that will grow the timer.
fn TcpConnection::accept_payload(
  self : TcpConnection,
  sim : @sim.Sim,
  segment : Segment,
) -> Unit {
  let offset = self.rcv_nxt.distance_to(segment.seq)
  if offset == 0 {
    self.deliver(segment.payload)
  } else if offset < 0 {
    // Part or all of this segment was already delivered.
    let duplicate_bytes = -offset
    if duplicate_bytes < segment.payload.length() {
      self.deliver(bytes_drop(segment.payload, duplicate_bytes))
    } else {
      self.duplicate_acks = self.duplicate_acks + 1
    }
  } else {
    self.buffer_early(segment.seq, segment.payload)
  }
  self.drain_reorder()
  self.emit_ack(sim)
}

///|
/// The state machine's response to a FIN.
fn TcpConnection::accept_fin(
  self : TcpConnection,
  sim : @sim.Sim,
  segment : Segment,
) -> Unit {
  if segment.seq.advance(segment.payload.length()) == self.rcv_nxt {
    self.rcv_nxt = self.rcv_nxt.advance(1)
  }
  self.peer_fin = true
  self.emit_ack(sim)
  match self.state {
    Established => self.state = CloseWait
    FinWait1 => self.state = Closing
    FinWait2 => self.enter_time_wait(sim)
    Closing | TimeWait | LastAck => ()
    _ => ()
  }
}

///|
/// Apply an acknowledgment, then let the state machine react to it.
fn TcpConnection::process_ack(
  self : TcpConnection,
  sim : @sim.Sim,
  ack : Seq,
  window : Int,
) -> Unit {
  // A window update rides on every segment, including duplicate ACKs, and must
  // be applied even when the acknowledgment itself carries no news.
  self.peer_window = window
  if ack.before(self.snd_una) || ack.after(self.snd_nxt) {
    return
  }
  if ack == self.snd_una {
    self.duplicate_acks = self.duplicate_acks + 1
    return
  }
  self.snd_una = ack
  let mut index = self.inflight.length()
  while index > 0 {
    index = index - 1
    let entry = self.inflight[index]
    if !entry.seq.advance(entry.sequence_length).after(ack) {
      self.bytes_acked = self.bytes_acked + entry.payload_length
      self.inflight.remove(index) |> ignore
    }
  }
  match self.state {
    SynReceived =>
      if self.fin_acked() || self.syn_acked() {
        self.state = Established
        self.pump(sim)
      }
    FinWait1 =>
      if self.fin_acked() {
        if self.peer_fin {
          self.enter_time_wait(sim)
        } else {
          self.state = FinWait2
        }
      }
    Closing => if self.fin_acked() { self.enter_time_wait(sim) }
    LastAck => if self.fin_acked() { self.state = Closed }
    _ => ()
  }
  self.pump(sim)
}

///|
/// True once the acknowledgment has passed the SYN we sent.
fn TcpConnection::syn_acked(self : TcpConnection) -> Bool {
  self.snd_una.after(Seq::of(self.config.initial_seq))
}

///|
/// True once the acknowledgment has passed the FIN we sent.
fn TcpConnection::fin_acked(self : TcpConnection) -> Bool {
  match self.fin_seq {
    None => false
    Some(fin) => self.snd_una.after(fin)
  }
}

///|
/// Send as much queued data as the peer's window and our MSS allow.
///
/// The window is the only limit here: there is no congestion control yet, which
/// is exactly what makes the next milestone a measurable change rather than a
/// rewrite.
fn TcpConnection::pump(self : TcpConnection, sim : @sim.Sim) -> Unit {
  if self.state != Established {
    return
  }
  while true {
    let queued = self.send_queue.length()
    if queued == 0 {
      break
    }
    // Bytes in flight is how far `snd_nxt` has run ahead of `snd_una`, so the
    // distance is measured from the acknowledged end towards the sent end.
    let in_flight = self.snd_una.distance_to(self.snd_nxt)
    let allowance = self.peer_window - in_flight
    if allowance <= 0 {
      break
    }
    let mut take = self.config.mss
    if take > allowance {
      take = allowance
    }
    if take > queued {
      take = queued
    }
    if take <= 0 {
      break
    }
    let payload = bytes_slice(self.send_queue, 0, take)
    self.send_data(sim, payload)
    self.send_queue = bytes_drop(self.send_queue, take)
  }
}

///|
/// Send one data segment and remember it as unacknowledged.
fn TcpConnection::send_data(
  self : TcpConnection,
  sim : @sim.Sim,
  payload : Bytes,
) -> Unit {
  let flags = Flags::ack()
  let segment = Segment::new(
    self.snd_nxt,
    self.rcv_nxt,
    self.advertised_window(),
    flags,
    payload,
  )
  self.inflight.push({
    seq: self.snd_nxt,
    payload_length: payload.length(),
    sequence_length: flags.sequence_length(payload.length()),
  })
  self.snd_nxt = self.snd_nxt.advance(payload.length())
  self.bytes_sent = self.bytes_sent + payload.length()
  self.segments_sent = self.segments_sent + 1
  sim.note("send  " + segment.label())
  (self.emit)(segment)
}

///|
/// Send a control segment (SYN or FIN), which occupies sequence space but
/// carries no payload.
fn TcpConnection::send_control(
  self : TcpConnection,
  sim : @sim.Sim,
  flags : Flags,
  sequence_length : Int,
) -> Unit {
  let seq = self.snd_nxt
  let segment = Segment::new(
    seq,
    self.rcv_nxt,
    self.advertised_window(),
    flags,
    Bytes::new(0),
  )
  self.inflight.push({ seq, payload_length: 0, sequence_length, })
  self.snd_nxt = self.snd_nxt.advance(sequence_length)
  if flags.fin {
    self.fin_seq = Some(seq)
  }
  self.segments_sent = self.segments_sent + 1
  sim.note("send  " + segment.label())
  (self.emit)(segment)
}

///|
/// Send an acknowledgment of what we have received so far. It carries no
/// sequence space of its own.
fn TcpConnection::emit_ack(self : TcpConnection, sim : @sim.Sim) -> Unit {
  if self.state == Listen || self.state == Closed {
    return
  }
  let segment = Segment::new(
    self.snd_nxt,
    self.rcv_nxt,
    self.advertised_window(),
    Flags::ack(),
    Bytes::new(0),
  )
  self.segments_sent = self.segments_sent + 1
  sim.note("send  " + segment.label())
  (self.emit)(segment)
}

///|
/// Enter TIME-WAIT and arrange to leave it after twice the maximum segment
/// lifetime. This is the one place the protocol layer asks the simulator for a
/// timer, and it uses the simulator's clock rather than a real one.
fn TcpConnection::enter_time_wait(self : TcpConnection, sim : @sim.Sim) -> Unit {
  self.state = TimeWait
  let connection = self
  sim.after(self.config.two_msl, "TIME-WAIT expires", () => {
    connection.state = Closed
  })
}

///|
/// How many bytes we are willing to receive right now. Buffer already held out
/// of order is subtracted, so a peer that keeps sending out of order is
/// eventually told to stop.
fn TcpConnection::advertised_window(self : TcpConnection) -> Int {
  let mut buffered = 0
  for entry in self.reorder {
    buffered = buffered + entry.payload.length()
  }
  let free = self.config.receive_window - buffered
  if free < 0 {
    0
  } else {
    free
  }
}

///|
/// Append bytes to the delivered stream.
fn TcpConnection::deliver(self : TcpConnection, payload : Bytes) -> Unit {
  if payload.length() == 0 {
    return
  }
  self.delivered = self.delivered.add(payload)
  self.rcv_nxt = self.rcv_nxt.advance(payload.length())
}

///|
/// Hold an early segment until the gap in front of it is filled.
fn TcpConnection::buffer_early(
  self : TcpConnection,
  seq : Seq,
  payload : Bytes,
) -> Unit {
  for entry in self.reorder {
    if entry.seq == seq {
      return
    }
  }
  self.reorder.push({ seq, payload, })
}

///|
/// Deliver every buffered segment that is now contiguous, in sequence order.
///
/// The buffer is scanned for the earliest matching segment rather than sorted
/// ahead of time: with a handful of segments per connection the scan is cheaper
/// than keeping an ordered structure, and it keeps the ordering rule visible in
/// the code.
fn TcpConnection::drain_reorder(self : TcpConnection) -> Unit {
  while true {
    let mut found : Int? = None
    let mut index = 0
    while index < self.reorder.length() {
      if self.reorder[index].seq == self.rcv_nxt {
        found = Some(index)
        break
      }
      index = index + 1
    }
    match found {
      None => break
      Some(position) => {
        let entry = self.reorder[position]
        self.reorder.remove(position) |> ignore
        self.deliver(entry.payload)
      }
    }
  }
}

///|
/// The current state.
pub fn TcpConnection::state(self : TcpConnection) -> TcpState {
  self.state
}

///|
pub fn TcpConnection::snd_una(self : TcpConnection) -> Seq {
  self.snd_una
}

///|
pub fn TcpConnection::snd_nxt(self : TcpConnection) -> Seq {
  self.snd_nxt
}

///|
pub fn TcpConnection::rcv_nxt(self : TcpConnection) -> Seq {
  self.rcv_nxt
}

///|
/// The most recent window the peer advertised.
pub fn TcpConnection::peer_window(self : TcpConnection) -> Int {
  self.peer_window
}

///|
/// Everything this end has delivered to the application, in order.
pub fn TcpConnection::delivered(self : TcpConnection) -> Bytes {
  self.delivered
}

///|
/// Bytes of payload this end handed to the network.
pub fn TcpConnection::bytes_sent(self : TcpConnection) -> Int {
  self.bytes_sent
}

///|
/// Bytes of payload the peer has acknowledged.
pub fn TcpConnection::bytes_acked(self : TcpConnection) -> Int {
  self.bytes_acked
}

///|
pub fn TcpConnection::segments_sent(self : TcpConnection) -> Int {
  self.segments_sent
}

///|
pub fn TcpConnection::segments_received(self : TcpConnection) -> Int {
  self.segments_received
}

///|
/// How many times an acknowledgment arrived that carried no new information.
pub fn TcpConnection::duplicate_acks(self : TcpConnection) -> Int {
  self.duplicate_acks
}

///|
/// Segments still waiting for an acknowledgment.
pub fn TcpConnection::inflight(self : TcpConnection) -> Int {
  self.inflight.length()
}

///|
/// A copy of `count` bytes starting at `start`.
fn bytes_slice(data : Bytes, start : Int, count : Int) -> Bytes {
  let out : Array[Byte] = []
  let mut index = 0
  while index < count {
    out.push(data[start + index])
    index = index + 1
  }
  Bytes::from_array(out)
}

///|
/// Everything after the first `count` bytes.
fn bytes_drop(data : Bytes, count : Int) -> Bytes {
  bytes_slice(data, count, data.length() - count)
}
