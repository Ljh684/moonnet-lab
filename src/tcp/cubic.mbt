///|
/// CUBIC (RFC 9438).
///
/// Reno's window grows linearly with time, so its rate depends on the round trip
/// time: the same number of round trips buys the same number of segments, and a
/// path with a large bandwidth-delay product needs an impractical number of them
/// before it is full. CUBIC replaces the linear growth with a cubic function of
/// the time since the last congestion event:
///
///     W(t) = C * (t - K)^3 + W_max
///
/// `W_max` is the window at the previous loss and `K` is how long the curve takes
/// to climb back to it. Just after a loss the window is far below `W_max`, so the
/// curve is steep and the connection recovers quickly. As it approaches `W_max`
/// the curve flattens, so probing for more bandwidth becomes slow and careful.
/// That shape is the whole idea: be aggressive where the path has already proved
/// it can take the traffic, and cautious where it has not.
///
/// Everything inside this algorithm is measured in segments, because that is the
/// unit RFC 9438 is written in and the constant `C` has the unit segments per
/// second cubed. Bytes appear only at the boundary, where the connection asks
/// for a window.
pub struct Cubic {
  /// Segment size this connection was configured with.
  mss : Int
  /// Congestion window in segments.
  mut cwnd : Int
  /// Slow start threshold in segments.
  mut ssthresh : Int
  /// Window just before the last congestion event, in segments.
  mut w_max : Int
  /// Window at the moment the threshold was last set, used to decide when the
  /// Reno-friendly estimate has caught up with where the connection was.
  mut cwnd_prior : Int
  /// Virtual time in picoseconds at which the current congestion avoidance epoch
  /// began. Zero means "no epoch yet".
  mut epoch_start : Int64
  /// The plateau the curve aims at, in segments.
  mut origin : Int
  /// How long the curve takes to reach the plateau, in picoseconds.
  mut k_ps : Int64
  /// The Reno-friendly window estimate, in segments. Fractional because it grows
  /// by less than a segment per acknowledgment.
  mut w_est : Double
  /// Acknowledgments counted towards the next one-segment increase.
  mut counter : Int
  /// The most recent round trip estimate, in picoseconds.
  mut rtt_ps : Int64
  mut in_recovery : Bool
  /// The multi-flow heuristic of RFC 9438 section 4.7. Off by default because
  /// every scenario in this project is a single flow, which is exactly the case
  /// the RFC says to disable it for.
  mut fast_convergence : Bool
}

///|
/// CUBIC's multiplicative decrease factor (RFC 9438 section 4.6).
///
/// This is the reason CUBIC exists. Reno halves the window on loss; CUBIC keeps
/// 70% of it. A smaller cut means less time spent climbing back to a rate the
/// path had already been shown to carry.
let cubic_beta : Double = 0.7

///|
/// The aggressiveness constant, in segments per second cubed (RFC 9438
/// section 5).
let cubic_c : Double = 0.4

///|
pub fn Cubic::new(mss : Int) -> Cubic {
  let initial_segments = initial_window(mss) / mss
  {
    mss,
    cwnd: initial_segments,
    ssthresh: 1_000_000,
    w_max: 0,
    cwnd_prior: 0,
    epoch_start: 0L,
    origin: initial_segments,
    k_ps: 0L,
    w_est: initial_segments.to_double(),
    counter: 0,
    rtt_ps: 0L,
    in_recovery: false,
    fast_convergence: false,
  }
}

///|
/// Enable the fast convergence heuristic (RFC 9438 section 4.7). It only helps
/// when several CUBIC flows share a bottleneck.
pub fn Cubic::with_fast_convergence(self : Cubic, enabled : Bool) -> Cubic {
  self.fast_convergence = enabled
  self
}

///|
impl CongestionControl for Cubic with fn window(self) {
  self.cwnd * self.mss
}

///|
impl CongestionControl for Cubic with fn ssthresh(self) {
  self.ssthresh * self.mss
}

///|
impl CongestionControl for Cubic with fn name(_self) {
  "cubic"
}

///|
impl CongestionControl for Cubic with fn phase(self) {
  if self.in_recovery {
    "fast recovery"
  } else if self.cwnd < self.ssthresh {
    "slow start"
  } else {
    "cubic"
  }
}

///|
/// Acknowledge new data.
///
/// Below the threshold this is ordinary slow start. Above it CUBIC evaluates its
/// own curve and the Reno-friendly estimate and takes whichever is larger: the
/// curve for what the path has been shown to carry, the estimate so that a
/// short-delay or low-bandwidth path never fares worse than Reno would.
impl CongestionControl for Cubic with fn on_ack(
  self,
  acked_bytes,
  mss,
  rtt_ps,
  now_ps,
) {
  if self.in_recovery {
    return
  }
  if rtt_ps > 0L {
    self.rtt_ps = rtt_ps
  }
  let acknowledged = segments_acked(acked_bytes, mss)
  if self.cwnd < self.ssthresh {
    self.cwnd = self.cwnd + acknowledged
    return
  }
  if self.epoch_start == 0L && now_ps > 0L {
    self.start_epoch(now_ps)
  }
  let alpha = if self.w_est >= self.cwnd_prior.to_double() {
    // The estimate has caught up with where the connection was before the last
    // cut, so from here it grows the way Reno would.
    1.0
  } else {
    // Otherwise use the additive factor that makes the average window match
    // Reno's despite the gentler multiplicative decrease.
    3.0 * (1.0 - cubic_beta) / (1.0 + cubic_beta)
  }
  self.w_est = self.w_est +
    alpha * acknowledged.to_double() / self.cwnd.to_double()
  let target = self.cubic_target(now_ps)
  if self.w_est > self.cwnd.to_double() {
    self.cwnd = @math.ceil(self.w_est).to_int()
  } else {
    self.increase_towards(target)
  }
}

///|
/// A congestion event discovered by duplicate acknowledgments.
impl CongestionControl for Cubic with fn on_fast_retransmit(
  self,
  flight_size,
  mss,
) {
  self.remember_before_cut()
  self.ssthresh = reduced_window(flight_size, mss)
  // Fast recovery inflates the window by the three segments that have already
  // left the network, exactly as Reno does; only the reduction factor differs.
  self.cwnd = self.ssthresh + 3
  self.in_recovery = true
  self.epoch_start = 0L
}

///|
impl CongestionControl for Cubic with fn on_duplicate_ack(self, _mss) {
  if self.in_recovery {
    self.cwnd = self.cwnd + 1
  }
}

///|
/// Deflate to the reduced window. The next acknowledgment opens a new epoch, and
/// the curve starts from wherever the connection landed.
impl CongestionControl for Cubic with fn on_recovery_exit(self, _mss) {
  if self.in_recovery {
    self.cwnd = self.ssthresh
    self.in_recovery = false
    self.epoch_start = 0L
  }
}

///|
impl CongestionControl for Cubic with fn on_partial_ack(self, _mss) {
  if self.in_recovery {
    self.cwnd = self.ssthresh + 3
  }
}

///|
/// A timeout. CUBIC follows Reno here — the window collapses to a single segment
/// — and, as RFC 9438 section 4.8 requires, forgets the previous plateau so that
/// the next climb starts from where the connection actually is.
impl CongestionControl for Cubic with fn on_timeout(self, flight_size, mss) {
  self.ssthresh = reduced_window(flight_size, mss)
  self.cwnd = 1
  self.w_max = 0
  self.cwnd_prior = 0
  self.in_recovery = false
  self.epoch_start = 0L
  self.counter = 0
}

///|
/// Start a congestion avoidance epoch: fix the plateau and the time the curve
/// takes to reach it.
///
/// When the window is already at or above the last plateau there is nothing to
/// climb back to, so the curve starts flat at the current window. That is the
/// case RFC 9438 section 4.8 describes for the first avoidance stage after a
/// timeout.
fn Cubic::start_epoch(self : Cubic, now_ps : Int64) -> Unit {
  self.epoch_start = now_ps
  if self.w_max <= self.cwnd {
    self.origin = self.cwnd
    self.k_ps = 0L
  } else {
    self.origin = self.w_max
    let seconds = @math.cbrt((self.w_max - self.cwnd).to_double() / cubic_c)
    self.k_ps = (seconds * 1_000_000_000_000.0).to_int64()
  }
  self.w_est = self.cwnd.to_double()
  self.counter = 0
}

///|
/// The window the cubic curve asks for one round trip from now.
///
/// The result is bounded below by the current window and above by one and a half
/// times it. The upper bound keeps CUBIC from outrunning slow start, which the
/// RFC states as a requirement rather than a suggestion.
fn Cubic::cubic_target(self : Cubic, now_ps : Int64) -> Double {
  if self.epoch_start == 0L {
    return self.cwnd.to_double()
  }
  let ahead = now_ps - self.epoch_start + self.rtt_ps - self.k_ps
  let seconds = ahead.to_double() / 1_000_000_000_000.0
  let curve = cubic_c * seconds * seconds * seconds + self.origin.to_double()
  let floor = self.cwnd.to_double()
  let ceiling = floor * 1.5
  if curve < floor {
    floor
  } else if curve > ceiling {
    ceiling
  } else {
    curve
  }
}

///|
/// Move the window one step towards `target`.
///
/// The RFC expresses the increase as `(target - cwnd) / cwnd` per
/// acknowledgment, which is a fraction of a segment most of the time. Rather than
/// carry a fractional window, this counts acknowledgments and adds a whole
/// segment every `cwnd / (target - cwnd)` of them — which is how deployed CUBIC
/// implementations do it, and keeps the window an exact multiple of the segment
/// size.
fn Cubic::increase_towards(self : Cubic, target : Double) -> Unit {
  let headroom = target - self.cwnd.to_double()
  if headroom <= 0.0 {
    return
  }
  let per_segment = (self.cwnd.to_double() / headroom).to_int()
  let needed = if per_segment < 1 { 1 } else { per_segment }
  self.counter = self.counter + 1
  if self.counter >= needed {
    self.counter = 0
    self.cwnd = self.cwnd + 1
  }
}

///|
/// Record what the window was before it is cut, applying the fast convergence
/// heuristic when it is enabled.
fn Cubic::remember_before_cut(self : Cubic) -> Unit {
  self.cwnd_prior = self.cwnd
  if self.fast_convergence && self.cwnd < self.w_max {
    // The path is delivering less than it did last time, so give up more of the
    // window than usual and leave a new flow room to grow.
    self.w_max = (self.cwnd.to_double() * (1.0 + cubic_beta) / 2.0).to_int()
  } else {
    self.w_max = self.cwnd
  }
}

///|
/// The window after a congestion event: the flight size scaled by CUBIC's
/// decrease factor, never less than two segments.
///
/// The reduction is taken from the flight size rather than from the window
/// value, because an application-limited sender can be holding a window much
/// larger than anything it actually had in the network.
fn reduced_window(flight_size : Int, mss : Int) -> Int {
  if mss <= 0 {
    return 2
  }
  let segments = (flight_size.to_double() * cubic_beta / mss.to_double()).to_int()
  if segments > 2 {
    segments
  } else {
    2
  }
}

///|
/// A byte count in whole segments, never zero: an acknowledgment of anything at
/// all is worth at least part of a segment, and a growth rule that can be
/// multiplied by zero stops growing entirely.
fn segments_acked(bytes : Int, mss : Int) -> Int {
  if mss <= 0 {
    return 1
  }
  let count = bytes / mss
  if count < 1 {
    1
  } else {
    count
  }
}
