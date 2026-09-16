///|
/// Classical Reno congestion control (RFC 5681, with the NewReno recovery of
/// RFC 6582).
///
/// Reno makes one judgement: a lost packet means the path is congested, and the
/// response is to halve the sending rate and then creep back up. It has no
/// memory of what the path has delivered before, which is why it gives ground to
/// CUBIC on long fat links and why it is still the reference every other
/// algorithm is measured against.
pub(all) struct Reno {
  mut cwnd : Int
  mut ssthresh : Int
  mut in_recovery : Bool
}

///|
/// The initial window of RFC 6928: at most ten segments, at least two, and at
/// least 14 600 bytes once the segments are large enough to make that the
/// smaller number.
///
/// Ten segments is a deliberate compromise. Two segments take too long to reach
/// a useful rate on a short path, and a larger window would put more than a
/// comfortable burst into a network that has not been measured yet.
pub fn initial_window(mss : Int) -> Int {
  let ten_segments = 10 * mss
  let two_segments = 2 * mss
  let minimum = if two_segments > 14_600 { two_segments } else { 14_600 }
  if ten_segments < minimum {
    ten_segments
  } else {
    minimum
  }
}

///|
pub fn Reno::new(mss : Int) -> Reno {
  // The threshold starts out of the way, so a connection with no loss stays in
  // slow start until the receiver's window or the path stops it.
  { cwnd: initial_window(mss), ssthresh: 1_000_000_000, in_recovery: false, }
}

///|
impl CongestionControl for Reno with fn window(self) {
  self.cwnd
}

///|
impl CongestionControl for Reno with fn ssthresh(self) {
  self.ssthresh
}

///|
impl CongestionControl for Reno with fn name(_self) {
  "reno"
}

///|
impl CongestionControl for Reno with fn phase(self) {
  if self.in_recovery {
    "fast recovery"
  } else if self.cwnd < self.ssthresh {
    "slow start"
  } else {
    "congestion avoidance"
  }
}

///|
/// Grow the window, doubling it every round trip while below the threshold and
/// adding roughly one segment per round trip above it.
///
/// Slow start adds one segment per acknowledged segment; congestion avoidance
/// adds one segment per acknowledged *window*. The difference is the whole
/// difference between probing a path and being polite to it.
impl CongestionControl for Reno with fn on_ack(self, acked_bytes, mss, _rtt_ps) {
  if self.in_recovery {
    return
  }
  if self.cwnd < self.ssthresh {
    let growth = if acked_bytes < mss { acked_bytes } else { mss }
    self.cwnd = self.cwnd + growth
  } else {
    let growth = mss * acked_bytes / self.cwnd
    self.cwnd = self.cwnd + (if growth < 1 { 1 } else { growth })
  }
}

///|
/// Halve the window, and inflate it by the three segments that already left the
/// network — those three are the ones whose acknowledgments are stuck behind the
/// hole, so the path is not actually carrying them any more.
impl CongestionControl for Reno with fn on_fast_retransmit(
  self,
  flight_size,
  mss,
) {
  let half = flight_size / 2
  let floor = 2 * mss
  self.ssthresh = if half > floor { half } else { floor }
  self.cwnd = self.ssthresh + 3 * mss
  self.in_recovery = true
}

///|
/// Each further duplicate acknowledgment reports one more segment that has left
/// the network, so the window grows by one segment for each of them.
impl CongestionControl for Reno with fn on_duplicate_ack(self, mss) {
  if self.in_recovery {
    self.cwnd = self.cwnd + mss
  }
}

///|
/// Deflate back to the halved window once the hole is repaired.
impl CongestionControl for Reno with fn on_recovery_exit(self, _mss) {
  if self.in_recovery {
    self.cwnd = self.ssthresh
    self.in_recovery = false
  }
}

///|
/// One hole repaired, another one revealed. The threshold was set when recovery
/// began and stands for the whole window, so the window goes back to the
/// inflated value it had at the start of recovery rather than being cut again.
impl CongestionControl for Reno with fn on_partial_ack(self, mss) {
  if self.in_recovery {
    self.cwnd = self.ssthresh + 3 * mss
  }
}

///|
/// A timeout is worse news than a fast retransmit: it means the path is so
/// congested that not even the retransmission arrived, so the window goes back
/// to a single segment and the connection has to earn its rate again.
impl CongestionControl for Reno with fn on_timeout(self, flight_size, mss) {
  let half = flight_size / 2
  let floor = 2 * mss
  self.ssthresh = if half > floor { half } else { floor }
  self.cwnd = mss
  self.in_recovery = false
}
