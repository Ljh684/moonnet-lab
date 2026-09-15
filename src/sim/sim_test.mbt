///|
/// The random generator is a compatibility surface, not an implementation
/// detail: published experiment results are only reproducible if the numbers
/// never change. These vectors come from an independent BigInt implementation
/// of SplitMix64 and xoshiro256**.
test "splitmix64 reference vectors" {
  let seeder = @sim.SplitMix64::new(0UL)
  inspect(seeder.next_u64(), content="16294208416658607535")
  inspect(seeder.next_u64(), content="7960286522194355700")
  inspect(seeder.next_u64(), content="487617019471545679")
  inspect(seeder.next_u64(), content="17909611376780542444")
}

///|
test "xoshiro256** reference vectors" {
  let rng = @sim.Rng::new(0UL)
  inspect(rng.next_u64(), content="11091344671253066420")
  inspect(rng.next_u64(), content="13793997310169335082")
  inspect(rng.next_u64(), content="1900383378846508768")
  inspect(rng.next_u64(), content="7684712102626143532")
}

///|
test "rng streams differ between seeds" {
  let a = @sim.Rng::new(1UL)
  let b = @sim.Rng::new(2UL)
  inspect(a.next_u64() == b.next_u64(), content="false")
}

///|
test "rng draws stay inside their bounds" {
  let rng = @sim.Rng::new(42UL)
  let mut index = 0
  let mut doubles_ok = true
  let mut ints_ok = true
  while index < 1000 {
    let value = rng.next_double()
    if value < 0.0 || value >= 1.0 {
      doubles_ok = false
    }
    let bucket = rng.next_int(10)
    if bucket < 0 || bucket >= 10 {
      ints_ok = false
    }
    index = index + 1
  }
  inspect(doubles_ok, content="true")
  inspect(ints_ok, content="true")
}

///|
test "forked streams are stable and independent" {
  let parent = @sim.Rng::new(7UL)
  let a = parent.fork("flow/0")
  let b = parent.fork("flow/1")
  let a_again = @sim.Rng::new(7UL).fork("flow/0")
  inspect(a.next_u64() == a_again.next_u64(), content="true")
  inspect(a.next_u64() == b.next_u64(), content="false")
}

///|
test "fnv1a64 hashes labels stably" {
  inspect(@sim.fnv1a64("flow/0"), content="7216053704922447130")
  inspect(@sim.fnv1a64("flow/1"), content="7216054804434075341")
  inspect(@sim.fnv1a64(""), content="14695981039346656037")
}

///|
test "time formats with three fraction digits" {
  inspect(@sim.Time::from_ps(0L).render(), content="0s")
  inspect(@sim.Time::from_ps(5120L).render(), content="5.120ns")
  inspect(@sim.Time::from_ms(12L).render(), content="12.000ms")
  inspect(
    (@sim.Time::from_ms(10L) + @sim.Time::from_us(250L)).render(),
    content="10.250ms",
  )
  inspect(@sim.Time::from_s(60L).render(), content="60.000s")
  inspect(
    (@sim.Time::from_ms(1L) - @sim.Time::from_ms(3L)).render(),
    content="-2.000ms",
  )
}

///|
test "serialization time matches hand arithmetic" {
  // A 1500-byte Ethernet frame on a 10 Mbps link takes 1.2 milliseconds.
  inspect(@sim.Time::serialize(1500L, 10_000_000L).render(), content="1.200ms")
  // The same frame at 10 Gbps takes 1.2 microseconds.
  inspect(
    @sim.Time::serialize(1500L, 10_000_000_000L).render(),
    content="1.200us",
  )
  // A 64-byte frame at 100 Gbps is 5.12 nanoseconds.
  inspect(
    @sim.Time::serialize(64L, 100_000_000_000L).render(),
    content="5.120ns",
  )
}

///|
test "propagation delay matches fibre speed" {
  // 200 km of fibre at 200_000 km/s is one millisecond.
  let delay = @sim.Time::propagation(200.0, 200_000.0)
  inspect(delay.render(), content="1.000ms")
}

///|
test "events run in time order" {
  let sim = @sim.Sim::new(1UL)
  sim.start_journal()
  sim.after(@sim.Time::from_ms(30L), "late", () => ())
  sim.after(@sim.Time::from_ms(10L), "early", () => ())
  sim.after(@sim.Time::from_ms(20L), "middle", () => ())
  sim.run()
  inspect(
    sim.journal().join("\n"),
    content="10.000ms  early\n20.000ms  middle\n30.000ms  late",
  )
}

///|
test "same-time events run in scheduling order" {
  let sim = @sim.Sim::new(1UL)
  sim.start_journal()
  sim.after(@sim.Time::from_ms(1L), "first", () => ())
  sim.after(@sim.Time::from_ms(1L), "second", () => ())
  sim.after(@sim.Time::from_ms(1L), "third", () => ())
  sim.run()
  inspect(
    sim.journal().join("\n"),
    content="1.000ms  first\n1.000ms  second\n1.000ms  third",
  )
}

///|
test "event handlers may schedule further events" {
  let sim = @sim.Sim::new(1UL)
  sim.start_journal()
  let mut ticks = 0
  sim.after(@sim.Time::from_ms(5L), "tick", () => {
    ticks = ticks + 1
    sim.after(@sim.Time::from_ms(5L), "tick", () => ticks = ticks + 1)
  })
  sim.run()
  inspect(ticks, content="2")
  inspect(sim.now().render(), content="10.000ms")
}

///|
test "run_until stops before later events" {
  let sim = @sim.Sim::new(1UL)
  sim.start_journal()
  sim.after(@sim.Time::from_ms(10L), "inside", () => ())
  sim.after(@sim.Time::from_ms(90L), "outside", () => ())
  sim.run_until(@sim.Time::from_ms(50L))
  inspect(sim.now().render(), content="50.000ms")
  inspect(sim.pending(), content="1")
  inspect(sim.journal().join("\n"), content="10.000ms  inside")
}

///|
test "the kernel is reproducible across runs" {
  let first = @sim.Sim::new(2026UL)
  let second = @sim.Sim::new(2026UL)
  let mut index = 0
  while index < 200 {
    let delay = @sim.Time::from_us(first.rng().next_int(1_000).to_int64())
    first.after(delay, "job", () => ())
    let delay2 = @sim.Time::from_us(second.rng().next_int(1_000).to_int64())
    second.after(delay2, "job", () => ())
    index = index + 1
  }
  first.start_journal()
  second.start_journal()
  first.run()
  second.run()
  inspect(first.journal() == second.journal(), content="true")
  inspect(first.now() == second.now(), content="true")
}

///|
test "the heap orders a larger batch correctly" {
  let sim = @sim.Sim::new(9UL)
  sim.start_journal()
  let mut index = 0
  // Schedule 500 events in reverse time order to exercise every sift path.
  while index < 500 {
    sim.after(@sim.Time::from_us((500 - index).to_int64()), "e", () => ())
    index = index + 1
  }
  sim.run()
  let journal = sim.journal()
  inspect(journal.length(), content="500")
  inspect(journal[0], content="1.000us  e")
  inspect(journal[499], content="500.000us  e")
}
