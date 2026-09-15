///|
/// Simulation time is a signed 64-bit count of **picoseconds**.
///
/// Picoseconds are small enough to express the serialization time of a single
/// 64-byte frame on a 100 Gbps link (5_120 ps) without rounding, and large
/// enough that one `Int64` spans roughly 106 days of simulated time.
///
/// Keeping time in an integer type is what makes experiments reproducible:
/// every scheduling decision compares exact integers, never floating point
/// values that could round differently on different backends.
pub(all) struct Time {
  ps : Int64
} derive(Eq, Compare, Debug, Hash)

///|
/// Time addition is exact integer addition.
pub impl Add for Time with fn add(self, other) {
  { ps: self.ps + other.ps, }
}

///|
/// Time subtraction can produce a negative value; the simulator relies on that
/// to detect "scheduled in the past" mistakes instead of silently clamping.
pub impl Sub for Time with fn sub(self, other) {
  { ps: self.ps - other.ps, }
}

///|
/// Rendering picks the largest unit that keeps the value readable and always
/// prints three fractional digits, using integer arithmetic so that the output
/// is identical on every backend.
pub fn Time::render(self : Time) -> String {
  let negative = self.ps < 0L
  let magnitude = if negative { -self.ps } else { self.ps }
  let body = if magnitude == 0L {
    "0s"
  } else if magnitude >= 1_000_000_000_000L {
    format_unit(magnitude, 1_000_000_000_000L, "s")
  } else if magnitude >= 1_000_000_000L {
    format_unit(magnitude, 1_000_000_000L, "ms")
  } else if magnitude >= 1_000_000L {
    format_unit(magnitude, 1_000_000L, "us")
  } else if magnitude >= 1_000L {
    format_unit(magnitude, 1_000L, "ns")
  } else {
    format_unit(magnitude, 1L, "ps")
  }
  if negative {
    "-" + body
  } else {
    body
  }
}

///|
pub impl Show for Time with fn to_string(self) {
  self.render()
}

///|
fn format_unit(ps : Int64, unit : Int64, suffix : String) -> String {
  let whole = ps / unit
  let fraction = ps % unit * 1000L / unit
  whole.to_string() + "." + pad3(fraction) + suffix
}

///|
fn pad3(value : Int64) -> String {
  if value < 10L {
    "00" + value.to_string()
  } else if value < 100L {
    "0" + value.to_string()
  } else {
    value.to_string()
  }
}

///|
/// The instant a simulation starts.
pub fn Time::zero() -> Time {
  { ps: 0L, }
}

///|
pub fn Time::from_ps(ps : Int64) -> Time {
  { ps, }
}

///|
pub fn Time::from_ns(ns : Int64) -> Time {
  { ps: ns * 1_000L, }
}

///|
pub fn Time::from_us(us : Int64) -> Time {
  { ps: us * 1_000_000L, }
}

///|
pub fn Time::from_ms(ms : Int64) -> Time {
  { ps: ms * 1_000_000_000L, }
}

///|
pub fn Time::from_s(seconds : Int64) -> Time {
  { ps: seconds * 1_000_000_000_000L, }
}

///|
/// Fractional milliseconds, for scenario files where `12.5ms` reads better than
/// `12500us`. The conversion truncates towards zero.
pub fn Time::from_ms_f(ms : Double) -> Time {
  { ps: (ms * 1_000_000_000.0).to_int64(), }
}

///|
pub fn Time::to_ps(self : Time) -> Int64 {
  self.ps
}

///|
/// Milliseconds as a float, for metrics and plots only. Never feed the result
/// back into scheduling.
pub fn Time::to_ms_f(self : Time) -> Double {
  self.ps.to_double() / 1_000_000_000.0
}

///|
/// Serialization time of `bytes` bytes on a link of `bps` bits per second.
///
/// The result is rounded down to a whole picosecond, which is the only rounding
/// the simulator ever performs. `bytes * 8 * 10^12` must fit in `Int64`, so a
/// single transmission may be at most about 1.1 MB; larger transfers are modeled
/// as a series of packets.
pub fn Time::serialize(bytes : Int64, bps : Int64) -> Time {
  { ps: bytes * 8L * 1_000_000_000_000L / bps, }
}

///|
/// Propagation delay of `distance_km` kilometres over a medium where signals
/// travel at `speed_km_per_s` (light in fibre is about 200_000 km/s).
pub fn Time::propagation(distance_km : Double, speed_km_per_s : Double) -> Time {
  { ps: (distance_km / speed_km_per_s * 1_000_000_000_000.0).to_int64(), }
}

///|
/// Distance in kilometres that light travels through fibre in `t`.
pub fn Time::fibre_distance_km(self : Time) -> Double {
  self.to_ms_f() * 200.0
}
