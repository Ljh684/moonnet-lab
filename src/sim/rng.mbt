///|
/// SplitMix64, the seeding construction recommended for the xoshiro family.
///
/// A single `UInt64` seed is expanded into a well-mixed state so that seeds as
/// similar as `1` and `2` still produce unrelated streams.
pub(all) struct SplitMix64 {
  mut state : UInt64
}

///|
pub fn SplitMix64::new(seed : UInt64) -> SplitMix64 {
  { state: seed, }
}

///|
pub fn SplitMix64::next_u64(self : SplitMix64) -> UInt64 {
  self.state = self.state + 0x9E3779B97F4A7C15UL
  let mut z = self.state
  z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9UL
  z = (z ^ (z >> 27)) * 0x94D049BB133111EBUL
  z ^ (z >> 31)
}

///|
/// The simulator's random source: xoshiro256**.
///
/// Why hand-roll instead of using the standard library: a reproducible
/// experiment must produce the same numbers on every backend and every future
/// version of this package. The algorithm is frozen here, its reference vectors
/// are pinned in the test suite, and nothing about it depends on the platform's
/// word size or on how a host language seeds its own generator.
pub(all) struct Rng {
  mut s0 : UInt64
  mut s1 : UInt64
  mut s2 : UInt64
  mut s3 : UInt64
}

///|
pub fn Rng::new(seed : UInt64) -> Rng {
  let seeder = SplitMix64::new(seed)
  {
    s0: seeder.next_u64(),
    s1: seeder.next_u64(),
    s2: seeder.next_u64(),
    s3: seeder.next_u64(),
  }
}

///|
pub fn Rng::next_u64(self : Rng) -> UInt64 {
  let result = rotl64(self.s1 * 5UL, 7) * 9UL
  let t = self.s1 << 17
  self.s2 = self.s2 ^ self.s0
  self.s3 = self.s3 ^ self.s1
  self.s1 = self.s1 ^ self.s2
  self.s0 = self.s0 ^ self.s3
  self.s2 = self.s2 ^ t
  self.s3 = rotl64(self.s3, 45)
  result
}

///|
pub fn rotl64(value : UInt64, shift : Int) -> UInt64 {
  (value << shift) | (value >> (64 - shift))
}

///|
/// A uniform `Int` in `[0, bound)`, using rejection sampling so that the
/// distribution is exactly uniform rather than modulo-biased. Determinism is
/// preserved because the number of rejections depends only on the sequence.
pub fn Rng::next_int(self : Rng, bound : Int) -> Int {
  if bound <= 0 {
    abort("Rng::next_int requires a positive bound")
  }
  let limit = 4294967296UL / bound.to_uint64() * bound.to_uint64()
  let mut draw = self.next_u64() % 4294967296UL
  while draw >= limit {
    draw = self.next_u64() % 4294967296UL
  }
  (draw % bound.to_uint64()).to_int()
}

///|
/// A uniform `Int64` in `[0, bound)`.
pub fn Rng::next_int64(self : Rng, bound : Int64) -> Int64 {
  if bound <= 0L {
    abort("Rng::next_int64 requires a positive bound")
  }
  let base = bound.reinterpret_as_uint64()
  let limit = 18446744073709551615UL / base * base
  let mut draw = self.next_u64()
  while draw >= limit {
    draw = self.next_u64()
  }
  (draw % base).reinterpret_as_int64()
}

///|
/// A uniform `Double` in `[0, 1)`, built from the top 53 bits so every value is
/// exactly representable and the generator never returns 1.0.
pub fn Rng::next_double(self : Rng) -> Double {
  (self.next_u64() >> 11).to_double() / 9007199254740992.0
}

///|
/// A uniform `Double` in `[low, high)`.
pub fn Rng::next_double_between(
  self : Rng,
  low : Double,
  high : Double,
) -> Double {
  low + (high - low) * self.next_double()
}

///|
/// `true` with probability `p`. `p <= 0` never fires and `p >= 1` always does,
/// which keeps scenario files free of edge-case surprises.
pub fn Rng::next_bool(self : Rng, p : Double) -> Bool {
  if p <= 0.0 {
    false
  } else if p >= 1.0 {
    true
  } else {
    self.next_double() < p
  }
}

///|
/// An exponential sample with the given mean, from the inverse transform
/// `-mean * ln(U)`. Used for inter-arrival times and for burst gaps.
pub fn Rng::next_exponential(self : Rng, mean : Double) -> Double {
  let u = self.next_double()
  -mean * ln_approx(1.0 - u)
}

///|
/// Natural logarithm via `@math`-free series-free approximation is not good
/// enough for statistics, so this delegates to the standard library and only
/// guards the domain.
fn ln_approx(x : Double) -> Double {
  if x <= 0.0 {
    abort("ln domain error")
  }
  @math.ln(x)
}

///|
/// Derive an independent stream from this generator plus a label.
///
/// This is how the simulator gives every flow, every link and every loss
/// process its own randomness without any of them sharing draw order: renaming
/// a flow changes its stream, but adding an unrelated flow does not disturb it.
pub fn Rng::fork(self : Rng, label : String) -> Rng {
  Rng::new(self.next_u64() ^ fnv1a64(label))
}

///|
/// FNV-1a over the UTF-8 bytes of a label, used to turn names into stable
/// numbers. Any hash would do; what matters is that it never changes.
pub fn fnv1a64(text : String) -> UInt64 {
  let mut hash = 0xCBF29CE484222325UL
  for byte in @utf8.encode(text) {
    hash = (hash ^ byte.to_uint64()) * 0x100000001B3UL
  }
  hash
}
