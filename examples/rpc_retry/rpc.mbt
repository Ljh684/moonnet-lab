///| A request/response protocol with a timeout and a bounded number of retries.
///
/// This package is a *consumer* of moonnet-lab, not part of it. It brings its
/// own protocol - one request in flight, a timer, at most a few retries - and
/// reuses the library for the three things that are hard to get right by hand:
/// a virtual clock that advances only when something happens, a seeded random
/// source so a loss pattern can be repeated, and a link model that queues,
/// serialises and drops packets.
///
/// That is the intended downstream use: a project that already has a protocol
/// (a health check, a cache fill, a lock acquisition) can get deterministic,
/// reproducible runs of it in `moon test` instead of hoping a flaky network
/// shows up in CI.

///|
/// What travels on the wire. The payload type is chosen by the caller; the
/// link does not care what is inside a packet.
pub(all) enum Frame {
  Request
  Reply
} derive(Eq, Debug)

///|
/// The retry policy under test.
pub(all) struct RpcPolicy {
  timeout : @sim.Time
  attempts : Int
} derive(Eq, Debug)

///|
/// What one call did.
pub(all) struct CallOutcome {
  attempts : Int
  delivered : Bool
  latency : @sim.Time
} derive(Eq, Debug)

///|
/// The size of a request and of a reply, in bytes. Small enough that the
/// runs stay fast, large enough to be visible on the wire.
fn request_bytes() -> Int {
  200
}

///|
fn reply_bytes() -> Int {
  200
}

///|
/// Run one call to completion and report what it cost.
///
/// The two links are built from the same seed but carry different names, and
/// the loss decision is mixed with the name - so the request and the reply see
/// unrelated loss patterns, which is what two directions of a real path do.
pub fn call(
  sim : @sim.Sim,
  policy : RpcPolicy,
  uplink : @net.LinkSpec,
  downlink : @net.LinkSpec,
  seed : UInt64,
) -> CallOutcome {
  let mut delivered = false
  let mut latency = @sim.Time::zero()
  let start = sim.now()
  let reply_link : @net.Link[Frame] = @net.Link::new(downlink, seed, _reply => {
    // The first reply wins. A duplicate reply arrives when a retry overtook a
    // slow copy of the request, and a real client would ignore it.
    if !delivered {
      delivered = true
      latency = sim.now() - start
    }
  })
  let request_link : @net.Link[Frame] = @net.Link::new(uplink, seed, _request => {
    // The server answers every copy it sees, which is what makes a duplicate
    // request harmless and a lost reply the only thing a retry has to fix.
    reply_link.send(
      sim,
      @net.Packet::new(2, 0, @net.Data, reply_bytes(), 0UL, Reply),
    )
    |> ignore
  })
  let mut attempts = 0
  while attempts < policy.attempts && !delivered {
    attempts = attempts + 1
    // Every attempt gets its own identity, so a retry is not doomed to meet the
    // same fate as the packet it replaces. This is the rule the TCP layer uses
    // too, and it is the difference between one lost packet and a lost call.
    let tag = @sim.mix64(seed, attempts.to_uint64())
    request_link.send(
      sim,
      @net.Packet::new(1, 0, @net.Data, request_bytes(), tag, Request),
    )
    |> ignore
    let mut timed_out = false
    sim.schedule_at(
      @sim.Time::from_ps(sim.now().ps + policy.timeout.ps),
      "rpc-timeout",
      () => timed_out = true,
    )
    // Whichever comes first: the reply, or this attempt's deadline. The timer
    // is an event like any other, so the virtual clock never has to be polled.
    sim.step_until(() => delivered || timed_out) |> ignore
  }
  { attempts, delivered, latency, }
}

///|
/// The link a call runs over, so the table below and the tests describe the
/// same path.
pub fn link_spec(name : String, loss : Double) -> @net.LinkSpec {
  @net.LinkSpec::new(
    name,
    10_000_000L,
    @sim.Time::from_ms(10L),
    @net.QueueSpec::packets(32),
  ).with_loss(loss)
}

///|
/// The policy the table below uses: a 200 ms deadline, at most four attempts.
pub fn default_policy() -> RpcPolicy {
  { timeout: @sim.Time::from_ms(200L), attempts: 4, }
}

///|
/// How a policy fares on a path that drops `loss` of the packets, over
/// `seeds` independent calls. This is the table the entry point prints, kept
/// here so it can be asserted by a test rather than only looked at.
pub fn measure(loss : Double, policy : RpcPolicy, seeds : Int) -> Measurement {
  let uplink = link_spec("up", loss)
  let downlink = link_spec("down", loss)
  let mut delivered = 0
  let mut attempts_total = 0
  let mut latency_total = 0L
  let mut seed = 0
  while seed < seeds {
    let id = seed.to_uint64()
    let outcome = call(@sim.Sim::new(id), policy, uplink, downlink, id)
    if outcome.delivered {
      delivered = delivered + 1
      attempts_total = attempts_total + outcome.attempts
      latency_total = latency_total + outcome.latency.ps
    }
    seed = seed + 1
  }
  let attempts = if delivered == 0 {
    0.0
  } else {
    attempts_total.to_double() / delivered.to_double()
  }
  let latency = if delivered == 0 {
    @sim.Time::zero()
  } else {
    @sim.Time::from_ps(latency_total / delivered.to_int64())
  }
  { calls: seeds, delivered, mean_attempts: attempts, mean_latency: latency, }
}

///|
/// What a row of the table says.
pub(all) struct Measurement {
  calls : Int
  delivered : Int
  mean_attempts : Double
  mean_latency : @sim.Time
} derive(Eq, Debug)

///|
/// One line of the table.
pub fn Measurement::to_line(self : Measurement, loss : Double) -> String {
  (loss * 100.0).to_int().to_string() +
  "%   " +
  self.delivered.to_string() +
  "/" +
  self.calls.to_string() +
  "   " +
  @net.format_one_decimal(self.mean_attempts) +
  "   " +
  self.mean_latency.render()
}
