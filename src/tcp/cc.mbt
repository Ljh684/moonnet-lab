///|
/// How a connection decides how much data it may have in flight.
///
/// The connection owns the mechanics — sequence numbers, timers, retransmission —
/// and asks this object only for a window and tells it about events. That split
/// is what makes Reno, CUBIC and Vegas interchangeable: they differ in how they
/// react to the same four events, not in how the connection works.
///
/// `flight_size` is how many bytes are sent but not yet acknowledged when the
/// event happens. Losss-based algorithms need it because the amount to cut is a
/// fraction of what is actually outstanding, not a fraction of the window the
/// algorithm previously believed it had.
pub(open) trait CongestionControl {
  /// Bytes this connection may have in flight right now.
  fn window(Self) -> Int
  /// The slow start threshold, for reports and tests.
  fn ssthresh(Self) -> Int
  /// A short name for reports.
  fn name(Self) -> String
  /// Which phase the algorithm is in, for reports.
  fn phase(Self) -> String
  /// New data was acknowledged. `rtt_ps` is zero when no usable round trip
  /// sample accompanied the acknowledgment, and `now_ps` is the virtual time at
  /// which it arrived — algorithms that grow as a function of time rather than
  /// of acknowledgments need it.
  fn on_ack(Self, acked_bytes : Int, mss : Int, rtt_ps : Int64, now_ps : Int64) -> Unit
  /// Duplicate acknowledgments revealed a hole.
  fn on_fast_retransmit(Self, flight_size : Int, mss : Int) -> Unit
  /// Another duplicate acknowledgment arrived while recovering. Acknowledging
  /// the same thing again is not progress, so this is the only signal that the
  /// packets after the hole are still arriving.
  fn on_duplicate_ack(Self, mss : Int) -> Unit
  /// The hole is repaired and everything that was in flight has been
  /// acknowledged.
  fn on_recovery_exit(Self, mss : Int) -> Unit
  /// An acknowledgment that repaired one hole and revealed another. The
  /// threshold has already been set for this window, so this must not cut it
  /// again.
  fn on_partial_ack(Self, mss : Int) -> Unit
  /// The retransmission timer expired: the most severe congestion signal,
  /// because it means not even the retransmission made it through.
  fn on_timeout(Self, flight_size : Int, mss : Int) -> Unit
}

///|
/// No congestion control at all: the window is effectively unbounded, so the
/// peer's advertised window is the only limit on the sending rate.
///
/// This is not a straw man. It is the control case that shows what congestion
/// control is buying: the same scenario run with and without it differs only in
/// how the sender behaves when a packet goes missing.
pub struct NoCongestionControl {
  limit : Int
}

///|
pub fn NoCongestionControl::new() -> NoCongestionControl {
  { limit: 1_000_000_000, }
}

///|
/// A control object that imposes no limit, ready to hand to
/// `TcpConnection::new_with_cc`.
pub fn without_congestion_control() -> &CongestionControl {
  NoCongestionControl::new() as &CongestionControl
}

///|
/// Reno, ready to hand to `TcpConnection::new_with_cc`.
pub fn reno(mss : Int) -> &CongestionControl {
  Reno::new(mss) as &CongestionControl
}

///|
/// CUBIC, ready to hand to `TcpConnection::new_with_cc`.
pub fn cubic(mss : Int) -> &CongestionControl {
  Cubic::new(mss) as &CongestionControl
}

///|
impl CongestionControl for NoCongestionControl with fn window(self) {
  self.limit
}

///|
impl CongestionControl for NoCongestionControl with fn ssthresh(_self) {
  0
}

///|
impl CongestionControl for NoCongestionControl with fn name(_self) {
  "none"
}

///|
impl CongestionControl for NoCongestionControl with fn phase(_self) {
  "unlimited"
}

///|
impl CongestionControl for NoCongestionControl with fn on_ack(
  _self,
  _acked_bytes,
  _mss,
  _rtt_ps,
  _now_ps,
) {
  ()
}

///|
impl CongestionControl for NoCongestionControl with fn on_fast_retransmit(
  _self,
  _flight_size,
  _mss,
) {
  ()
}

///|
impl CongestionControl for NoCongestionControl with fn on_duplicate_ack(
  _self,
  _mss,
) {
  ()
}

///|
impl CongestionControl for NoCongestionControl with fn on_recovery_exit(
  _self,
  _mss,
) {
  ()
}

///|
impl CongestionControl for NoCongestionControl with fn on_partial_ack(
  _self,
  _mss,
) {
  ()
}

///|
impl CongestionControl for NoCongestionControl with fn on_timeout(
  _self,
  _flight_size,
  _mss,
) {
  ()
}
