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
  /// RTO before the first round-trip measurement lands.
  ///
  /// RFC 6298 says one second, and one second is the default here, even though
  /// it looks enormous on a 10 ms path. That gap is the point: it is the reason
  /// a connection that has never measured its path recovers slowly from its
  /// first loss, and a scenario is free to ask for something smaller.
  rto_initial : @sim.Time
  /// Floor for the computed RTO. RFC 6298 says 1 s; real stacks lower it, and
  /// a low-latency experiment usually wants to.
  rto_min : @sim.Time
  /// Ceiling for the computed RTO, also the cap on exponential backoff.
  rto_max : @sim.Time
  /// Give up after this many consecutive timeouts.
  max_retransmits : Int
} derive(Eq, Debug)

///|
pub fn TcpConfig::new(
  mss : Int,
  receive_window : Int,
  initial_seq : UInt,
) -> TcpConfig {
  {
    mss,
    receive_window,
    initial_seq,
    two_msl: @sim.Time::from_s(60L),
    rto_initial: @sim.Time::from_s(1L),
    rto_min: @sim.Time::from_s(1L),
    rto_max: @sim.Time::from_s(60L),
    max_retransmits: 8,
  }
}

///|
/// The same configuration with a different retransmission budget, for scenarios
/// that trade realism for a shorter stall.
pub fn TcpConfig::with_rto(
  self : TcpConfig,
  initial : @sim.Time,
  min : @sim.Time,
  max : @sim.Time,
) -> TcpConfig {
  { ..self, rto_initial: initial, rto_min: min, rto_max: max, }
}

///|
/// A segment that has been sent but not yet acknowledged.
///
/// The whole segment is kept, not just its sequence range, because a lost
/// segment has to be sent again and there is nowhere else to get the bytes from.
/// `sequence_length` differs from `payload_length` by one for a SYN or a FIN, so
/// acknowledgment accounting can report application bytes without the control
/// bits corrupting the totals.
struct InFlight {
  seq : Seq
  flags : Flags
  payload : Bytes
  sequence_length : Int
  sent_at : @sim.Time
  /// Karn's algorithm: a segment that has been sent twice tells us nothing
  /// about the round-trip time, because the acknowledgment does not say which
  /// copy it is acknowledging.
  retransmitted : Bool
  /// How many times this segment has been sent, including the first. It is part
  /// of the segment's identity for loss, so that a retransmission is judged
  /// afresh instead of inheriting the fate of the transmission it repeats.
  transmissions : Int
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
pub struct TcpConnection {
  config : TcpConfig
  cc : &CongestionControl
  /// Which flow this connection is, when several share a bottleneck.
  ///
  /// It is part of each segment's identity for loss, so that two flows opening
  /// at the same sequence number do not inherit each other's lost packets. Flow
  /// zero is the single-flow case and leaves the identity untouched, so adding
  /// this concept did not change any existing result.
  mut flow : UInt64
  mut state : TcpState
  mut emit : (Segment) -> Unit
  mut snd_una : Seq
  mut snd_nxt : Seq
  mut rcv_nxt : Seq
  mut peer_window : Int
  mut send_queue : Bytes
  /// How much of `send_queue` has already been sent. The unsent bytes are
  /// `send_queue[send_offset..]`.
  ///
  /// Copying the remaining bytes after every segment would be correct and
  /// catastrophically slow: a four megabyte transfer becomes eight gigabytes of
  /// memcpy, and the cost only appears once windows grow, which is exactly what
  /// a long fat path does.
  mut send_offset : Int
  mut fin_seq : Seq?
  mut peer_fin : Bool
  mut inflight : Array[InFlight]
  /// Index of the oldest segment still waiting for an acknowledgment. Entries
  /// before it are retired but still occupy array slots until the next
  /// compaction.
  mut inflight_head : Int
  reorder : Array[Buffered]
  /// Bytes currently held out of order. Kept as a running total rather than
  /// summed on demand: the advertised window is computed for every segment the
  /// connection sends, and summing a two-thousand entry buffer each time turns a
  /// long fat path into a quadratic workload.
  mut reorder_bytes : Int
  /// Everything delivered to the application so far, but only if the caller
  /// asked for it.
  ///
  /// Retaining every byte unconditionally is both a memory leak and a quadratic
  /// copy: appending to a growing buffer copies it, so a four megabyte transfer
  /// becomes eight gigabytes of memcpy. Tests and demos that need to inspect the
  /// byte stream opt in; everything else only pays for a counter.
  mut capture : Bool
  /// Bytes delivered to the application, always counted.
  mut delivered_bytes : Int
  mut delivered : Bytes
  mut segments_sent : Int
  mut segments_received : Int
  mut bytes_sent : Int
  mut bytes_acked : Int
  mut duplicate_acks : Int
  mut retransmits : Int
  mut fast_retransmits : Int
  mut timeouts : Int
  mut consecutive_timeouts : Int
  /// Duplicate acknowledgments seen since the last acknowledgment that made
  /// progress. Three of them are the signal that a segment is missing while the
  /// segments behind it are arriving.
  mut dup_ack_count : Int
  /// True between a fast retransmit and the acknowledgment that closes the gap.
  mut in_recovery : Bool
  /// The highest sequence number that had been sent when recovery began. An
  /// acknowledgment that reaches this point means every hole is filled.
  mut recover_until : Seq
  mut rtt_samples : Int
  mut srtt_ps : Double
  mut rttvar_ps : Double
  mut has_rtt_sample : Bool
  mut rto : @sim.Time
  mut timer_running : Bool
  /// Every timer event carries the generation it was armed in. Re-arming bumps
  /// the generation, so a stale event that is already in the queue when the
  /// timer is restarted can tell that it has been superseded and do nothing.
  /// Without this, a timer that fires after an acknowledgment would retransmit
  /// data that has already arrived.
  mut timer_generation : Int
}

///|

///|
/// A connection controlled by Reno, which is what a TCP connection normally is.
pub fn TcpConnection::new(config : TcpConfig) -> TcpConnection {
  TcpConnection::new_with_cc(
    config,
    Reno::new(config.mss) as &CongestionControl,
  )
}

///|
/// A connection with a specific congestion control algorithm, including
/// `NoCongestionControl` for experiments that want the peer's window to be the
/// only limit.
pub fn TcpConnection::new_with_cc(
  config : TcpConfig,
  cc : &CongestionControl,
) -> TcpConnection {
  let iss = Seq::of(config.initial_seq)
  {
    config,
    cc,
    flow: 0UL,
    state: Closed,
    emit: _segment => (),
    snd_una: iss,
    snd_nxt: iss,
    rcv_nxt: iss,
    peer_window: 0,
    send_queue: Bytes::new(0),
    send_offset: 0,
    fin_seq: None,
    peer_fin: false,
    inflight: [],
    inflight_head: 0,
    reorder: [],
    reorder_bytes: 0,
    capture: false,
    delivered_bytes: 0,
    delivered: Bytes::new(0),
    segments_sent: 0,
    segments_received: 0,
    bytes_sent: 0,
    bytes_acked: 0,
    duplicate_acks: 0,
    retransmits: 0,
    fast_retransmits: 0,
    timeouts: 0,
    consecutive_timeouts: 0,
    dup_ack_count: 0,
    in_recovery: false,
    recover_until: iss,
    rtt_samples: 0,
    srtt_ps: 0.0,
    rttvar_ps: 0.0,
    has_rtt_sample: false,
    rto: config.rto_initial,
    timer_running: false,
    timer_generation: 0,
  }
}

///|
/// Give this connection an identity, so that several connections sharing a link
/// lose different packets. Flows are numbered from one; zero means "the only
/// connection", and leaves packets judged on their sequence number alone.
pub fn TcpConnection::set_flow(self : TcpConnection, id : UInt64) -> Unit {
  self.flow = id
}

///|
/// The identity of a segment for the purpose of loss: what it is, not when it
/// was sent. `transmissions` is part of it so that a retransmission is judged
/// afresh, and the flow is part of it so that flows sharing a link do not share
/// a fate.
fn TcpConnection::tag_for(
  self : TcpConnection,
  seq : Seq,
  transmissions : Int,
) -> UInt64 {
  let identity = @sim.mix64(seq.value.to_uint64(), transmissions.to_uint64())
  if self.flow == 0UL {
    identity
  } else {
    @sim.mix64(self.flow, identity)
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
  self.enqueue_data(data)
  self.pump(sim)
}

///|
/// Append application data to the send buffer.
///
/// The buffer is only compacted when it is either fully consumed or about to be
/// appended to with a stale prefix in front of it, so the common cases — send
/// once and drain, or send repeatedly into an empty buffer — do not copy the
/// bytes still waiting to go out.
fn TcpConnection::enqueue_data(self : TcpConnection, data : Bytes) -> Unit {
  if data.length() == 0 {
    return
  }
  if self.send_offset >= self.send_queue.length() {
    self.send_queue = data
    self.send_offset = 0
    return
  }
  if self.send_offset > 0 {
    self.send_queue = bytes_drop(self.send_queue, self.send_offset)
    self.send_offset = 0
  }
  self.send_queue = self.send_queue.add(data)
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
  if sim.is_recording() {
    sim.note("recv  " + segment.label())
  }
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
    SynReceived =>
      // A repeated SYN means our SYN+ACK did not arrive. Answer it directly
      // instead of making the peer wait out the retransmission timer.
      self.retransmit_oldest(sim)
    _ => self.emit_ack(sim)
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
    self.dup_ack_count = self.dup_ack_count + 1
    self.on_duplicate_ack(sim)
    return
  }
  let old_una = self.snd_una
  self.snd_una = ack
  // Karn's algorithm: the acknowledgment covers the byte range, not a copy of
  // it, so a segment that had to be sent twice yields no usable round-trip
  // sample.
  //
  // Only the head of the queue is examined, and only entries that are now fully
  // acknowledged are retired. Scanning the whole in-flight queue for every
  // acknowledgment would be correct and quadratic: on a path whose window grows
  // into the thousands of segments, most of the run would be spent walking a
  // list whose length grows with the transfer.
  let mut sample : Int64? = None
  let mut acknowledged_bytes = 0
  while self.inflight_head < self.inflight.length() {
    let entry = self.inflight[self.inflight_head]
    if entry.seq.advance(entry.sequence_length).after(ack) {
      break
    }
    if !entry.retransmitted && entry.seq == old_una {
      sample = Some(sim.now().ps - entry.sent_at.ps)
    }
    self.bytes_acked = self.bytes_acked + entry.payload.length()
    acknowledged_bytes = acknowledged_bytes + entry.payload.length()
    self.inflight_head = self.inflight_head + 1
  }
  self.compact_inflight()
  let mut round_trip = 0L
  match sample {
    Some(measured) => {
      round_trip = measured
      self.update_rtt(measured)
    }
    None => ()
  }
  self.cc.on_ack(acknowledged_bytes, self.config.mss, round_trip, sim.now().ps)
  self.dup_ack_count = 0
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
  // Recovery ends when an acknowledgment reaches everything that was in flight
  // when it started. An acknowledgment that stops short means the retransmission
  // filled one hole and there is another one behind it.
  if self.in_recovery {
    if !ack.before(self.recover_until) {
      self.in_recovery = false
      self.cc.on_recovery_exit(self.config.mss)
    } else {
      self.cc.on_partial_ack(self.config.mss)
      self.retransmit_oldest(sim)
      self.fast_retransmits = self.fast_retransmits + 1
    }
  }
  // Acknowledged progress clears the retransmission streak, and the timer now
  // either covers what is left in flight or stops entirely.
  self.consecutive_timeouts = 0
  if self.inflight_is_empty() {
    self.disarm_timer()
  } else {
    self.arm_timer(sim)
  }
  self.pump(sim)
}

///|
/// True once the acknowledgment has passed the SYN we sent.
fn TcpConnection::syn_acked(self : TcpConnection) -> Bool {
  self.snd_una.after(Seq::of(self.config.initial_seq))
}

///|
/// React to an acknowledgment that repeats what the peer already said.
///
/// One or two repeats are ordinary reordering. Three means a segment is missing
/// and at least three segments behind it have arrived, which is exactly the
/// information the sender needs to repair the hole now instead of waiting out a
/// retransmission timer that may be three orders of magnitude too long.
///
/// The window adjustments that RFC 5681 pairs with this — halving the
/// congestion window and inflating it by the duplicate acknowledgments — belong
/// to congestion control and land with it. What happens here is the
/// retransmission itself, which is useful on its own.
fn TcpConnection::on_duplicate_ack(
  self : TcpConnection,
  sim : @sim.Sim,
) -> Unit {
  if self.dup_ack_count < 3 || self.inflight_is_empty() {
    return
  }
  if self.in_recovery {
    // Another segment has left the network, so the algorithm may let one more
    // in. This is the only signal that distinguishes "the peer is still
    // receiving" from "the connection is stalled".
    self.cc.on_duplicate_ack(self.config.mss)
    self.pump(sim)
    return
  }
  let flight_size = self.snd_una.distance_to(self.snd_nxt)
  self.in_recovery = true
  self.recover_until = self.snd_nxt
  self.cc.on_fast_retransmit(flight_size, self.config.mss)
  self.retransmit_oldest(sim)
  self.fast_retransmits = self.fast_retransmits + 1
  // The timer restarts so that a retransmission that is itself lost is still
  // caught, but at the un-backed-off timeout: this is not a timeout yet.
  self.arm_timer(sim)
  self.pump(sim)
}

///|
/// Fold one round-trip measurement into the smoothed estimate (RFC 6298).
///
/// With one eighth of each sample going into the estimate and one quarter of
/// each deviation going into the variance, a single unlucky measurement moves
/// the timeout a little and a sustained change moves it a lot. The variance term
/// is what makes the timeout follow a path whose delay is genuinely unstable
/// rather than merely large.
fn TcpConnection::update_rtt(self : TcpConnection, sample_ps : Int64) -> Unit {
  let sample = sample_ps.to_double()
  if self.has_rtt_sample {
    let delta = self.srtt_ps - sample
    let deviation = if delta < 0.0 { -delta } else { delta }
    self.rttvar_ps = self.rttvar_ps * 0.75 + deviation * 0.25
    self.srtt_ps = self.srtt_ps * 0.875 + sample * 0.125
  } else {
    self.srtt_ps = sample
    self.rttvar_ps = sample / 2.0
    self.has_rtt_sample = true
  }
  self.rtt_samples = self.rtt_samples + 1
  self.recompute_rto()
}

///|
/// RTO = SRTT + 4 x RTTVAR, clamped to the configured range.
fn TcpConnection::recompute_rto(self : TcpConnection) -> Unit {
  let computed = self.srtt_ps + 4.0 * self.rttvar_ps
  let floor = self.config.rto_min.ps.to_double()
  let ceiling = self.config.rto_max.ps.to_double()
  let clamped = if computed < floor {
    floor
  } else if computed > ceiling {
    ceiling
  } else {
    computed
  }
  self.rto = @sim.Time::from_ps(clamped.to_int64())
}

///|
/// Arm the retransmission timer for the current RTO.
///
/// Every armed timer carries a generation number. Re-arming invalidates
/// whatever is already in the event queue, so a timer that was about to fire
/// cannot retransmit data that an acknowledgment has just cleared.
fn TcpConnection::arm_timer(self : TcpConnection, sim : @sim.Sim) -> Unit {
  self.timer_generation = self.timer_generation + 1
  let generation = self.timer_generation
  self.timer_running = true
  let connection = self
  sim.after(self.rto, "RTO", () => connection.on_timeout(sim, generation))
}

///|
/// Stop the timer without retransmitting anything.
fn TcpConnection::disarm_timer(self : TcpConnection) -> Unit {
  self.timer_running = false
  self.timer_generation = self.timer_generation + 1
}

///|
/// The retransmission timer fired.
fn TcpConnection::on_timeout(
  self : TcpConnection,
  sim : @sim.Sim,
  generation : Int,
) -> Unit {
  if generation != self.timer_generation {
    return
  }
  if self.state == Closed || self.inflight_is_empty() {
    self.timer_running = false
    return
  }
  let flight_size = self.snd_una.distance_to(self.snd_nxt)
  self.cc.on_timeout(flight_size, self.config.mss)
  self.timeouts = self.timeouts + 1
  self.consecutive_timeouts = self.consecutive_timeouts + 1
  // A timeout means the fast retransmit did not repair the hole, so recovery is
  // over and normal timer-driven retransmission takes over.
  self.in_recovery = false
  self.dup_ack_count = 0
  if self.consecutive_timeouts > self.config.max_retransmits {
    sim.note(
      "giving up after " + self.consecutive_timeouts.to_string() + " timeouts",
    )
    self.state = Closed
    self.timer_running = false
    return
  }
  // Exponential backoff: each consecutive timeout doubles the wait, up to the
  // configured ceiling. This is what keeps a congested or dead path from being
  // flooded with retransmissions.
  let doubled = self.rto.ps * 2L
  self.rto = if doubled > self.config.rto_max.ps {
    self.config.rto_max
  } else {
    @sim.Time::from_ps(doubled)
  }
  self.retransmit_oldest(sim)
  self.arm_timer(sim)
}

///|
/// Send the oldest unacknowledged segment again.
///
/// Only the oldest one goes out. Retransmitting everything in flight would be
/// simpler, but it would also multiply the load on a path that has already
/// demonstrated it is dropping packets, which is the opposite of what a
/// congestion-controlled transport should do.
fn TcpConnection::retransmit_oldest(
  self : TcpConnection,
  sim : @sim.Sim,
) -> Unit {
  if self.inflight_is_empty() {
    return
  }
  let entry = self.inflight[self.inflight_head]
  let transmissions = entry.transmissions + 1
  let segment = Segment::new(
    entry.seq,
    self.rcv_nxt,
    self.advertised_window(),
    entry.flags,
    entry.payload,
    self.tag_for(entry.seq, transmissions),
  )
  self.inflight[self.inflight_head] = {
    ..entry,
    sent_at: sim.now(),
    retransmitted: true,
    transmissions,
  }
  self.retransmits = self.retransmits + 1
  self.segments_sent = self.segments_sent + 1
  if sim.is_recording() {
    sim.note("retx  " + segment.label())
  }
  (self.emit)(segment)
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
    let queued = self.send_queue.length() - self.send_offset
    if queued == 0 {
      break
    }
    // Bytes in flight is how far `snd_nxt` has run ahead of `snd_una`, so the
    // distance is measured from the acknowledged end towards the sent end.
    let in_flight = self.snd_una.distance_to(self.snd_nxt)
    // Two independent limits: what the receiver is willing to buffer, and what
    // the path has been shown to carry. Neither one alone is TCP.
    let sender_window = if self.peer_window < self.cc.window() {
      self.peer_window
    } else {
      self.cc.window()
    }
    let allowance = sender_window - in_flight
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
    let payload = bytes_slice(self.send_queue, self.send_offset, take)
    self.send_data(sim, payload)
    self.send_offset = self.send_offset + take
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
    self.tag_for(self.snd_nxt, 1),
  )
  self.inflight.push({
    seq: self.snd_nxt,
    flags,
    payload,
    sequence_length: flags.sequence_length(payload.length()),
    sent_at: sim.now(),
    retransmitted: false,
    transmissions: 1,
  })
  self.snd_nxt = self.snd_nxt.advance(payload.length())
  self.bytes_sent = self.bytes_sent + payload.length()
  self.segments_sent = self.segments_sent + 1
  if sim.is_recording() {
    sim.note("send  " + segment.label())
  }
  (self.emit)(segment)
  self.arm_timer(sim)
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
    self.tag_for(seq, 1),
  )
  self.inflight.push({
    seq,
    flags,
    payload: Bytes::new(0),
    sequence_length,
    sent_at: sim.now(),
    retransmitted: false,
    transmissions: 1,
  })
  self.snd_nxt = self.snd_nxt.advance(sequence_length)
  if flags.fin {
    self.fin_seq = Some(seq)
  }
  self.segments_sent = self.segments_sent + 1
  if sim.is_recording() {
    sim.note("send  " + segment.label())
  }
  (self.emit)(segment)
  self.arm_timer(sim)
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
    // Acknowledgments carry no identity: the same acknowledgment is sent again
    // and again, so the link judges them by transmission order instead.
    0UL,
  )
  self.segments_sent = self.segments_sent + 1
  if sim.is_recording() {
    sim.note("send  " + segment.label())
  }
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
  let free = self.config.receive_window - self.reorder_bytes
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
  self.delivered_bytes = self.delivered_bytes + payload.length()
  if self.capture {
    self.delivered = self.delivered.add(payload)
  }
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
  self.reorder_bytes = self.reorder_bytes + payload.length()
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
        self.reorder_bytes = self.reorder_bytes - entry.payload.length()
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
/// Ask the connection to retain the byte stream it delivers, so that a test can
/// compare it against what was sent. Off by default; see the field comment.
pub fn TcpConnection::capture_delivered(
  self : TcpConnection,
  enabled : Bool,
) -> Unit {
  self.capture = enabled
}

///|
/// How many bytes have been delivered to the application, in order.
pub fn TcpConnection::delivered_bytes(self : TcpConnection) -> Int {
  self.delivered_bytes
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
  self.inflight.length() - self.inflight_head
}

///|
/// Whether every sent segment has been acknowledged.
fn TcpConnection::inflight_is_empty(self : TcpConnection) -> Bool {
  self.inflight_head >= self.inflight.length()
}

///|
/// Drop retired entries once they take up more than half the array.
///
/// Retiring by moving a head index keeps acknowledgment handling constant time;
/// this is what keeps the array itself from growing without bound over a long
/// transfer. Compacting only when the waste is large keeps the cost amortised.
fn TcpConnection::compact_inflight(self : TcpConnection) -> Unit {
  if self.inflight_head < 64 || self.inflight_head * 2 < self.inflight.length() {
    return
  }
  let remaining : Array[InFlight] = []
  let mut index = self.inflight_head
  while index < self.inflight.length() {
    remaining.push(self.inflight[index])
    index = index + 1
  }
  self.inflight = remaining
  self.inflight_head = 0
}

///|
/// Segments sent again because the timer expired.
pub fn TcpConnection::retransmits(self : TcpConnection) -> Int {
  self.retransmits
}

///|
/// Segments sent again because duplicate acknowledgments revealed a hole,
/// without waiting for the timer.
pub fn TcpConnection::fast_retransmits(self : TcpConnection) -> Int {
  self.fast_retransmits
}

///|
/// Whether the connection is currently repairing a hole discovered by
/// duplicate acknowledgments.
pub fn TcpConnection::in_recovery(self : TcpConnection) -> Bool {
  self.in_recovery
}

///|
/// The congestion window currently in force, in bytes.
pub fn TcpConnection::cwnd(self : TcpConnection) -> Int {
  self.cc.window()
}

///|
/// The slow start threshold of the congestion control algorithm.
pub fn TcpConnection::ssthresh(self : TcpConnection) -> Int {
  self.cc.ssthresh()
}

///|
/// The name of the congestion control algorithm.
pub fn TcpConnection::cc_name(self : TcpConnection) -> String {
  self.cc.name()
}

///|
/// Which phase the congestion control algorithm reports.
pub fn TcpConnection::cc_phase(self : TcpConnection) -> String {
  self.cc.phase()
}

///|
/// How many times the retransmission timer has expired.
pub fn TcpConnection::timeouts(self : TcpConnection) -> Int {
  self.timeouts
}

///|
/// How many round-trip samples have been folded into the estimate.
pub fn TcpConnection::rtt_samples(self : TcpConnection) -> Int {
  self.rtt_samples
}

///|
/// The smoothed round-trip time, once a sample exists.
pub fn TcpConnection::srtt(self : TcpConnection) -> @sim.Time? {
  if self.has_rtt_sample {
    Some(@sim.Time::from_ps(self.srtt_ps.to_int64()))
  } else {
    None
  }
}

///|
/// The retransmission timeout currently in force, including any backoff.
pub fn TcpConnection::rto(self : TcpConnection) -> @sim.Time {
  self.rto
}

///|
/// Whether the retransmission timer is currently armed.
pub fn TcpConnection::timer_running(self : TcpConnection) -> Bool {
  self.timer_running
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
