///|
/// One call, with an explicit policy so a test can vary the retry budget.
fn one(loss : Double, seed : UInt64, attempts : Int) -> CallOutcome {
  let policy : RpcPolicy = { timeout: @sim.Time::from_ms(200L), attempts, }
  call(
    @sim.Sim::new(seed),
    policy,
    link_spec("up", loss),
    link_spec("down", loss),
    seed,
  )
}

///|
/// The same twenty seeds, run with one attempt and with four, counted.
struct BudgetComparison {
  failures_with_one : Int
  failures_with_four : Int
  rescued : Int
} derive(Eq, Debug)

///|
fn compare_budgets(loss : Double, seeds : Int) -> BudgetComparison {
  let mut failures_with_one = 0
  let mut failures_with_four = 0
  let mut rescued = 0
  let mut seed = 0
  while seed < seeds {
    let id = seed.to_uint64()
    let once = one(loss, id, 1)
    let retried = one(loss, id, 4)
    if !once.delivered {
      failures_with_one = failures_with_one + 1
    }
    if !retried.delivered {
      failures_with_four = failures_with_four + 1
    }
    if retried.delivered && retried.attempts > 1 {
      rescued = rescued + 1
    }
    seed = seed + 1
  }
  { failures_with_one, failures_with_four, rescued, }
}

///|
test "a path that loses nothing needs one attempt" {
  let outcome = one(0.0, 1UL, 4)
  inspect(outcome.delivered, content="true")
  inspect(outcome.attempts, content="1")
}

///|
test "the same seed produces the same call" {
  let first = one(0.2, 5UL, 4)
  let second = one(0.2, 5UL, 4)
  inspect(first == second, content="true")
  inspect(first.latency.render(), content=second.latency.render())
}

///|
test "a retry budget is what a lossy path needs" {
  let comparison = compare_budgets(0.5, 20)
  // Half the packets are dropped. Thirteen of twenty calls do not come back on
  // their own; a four attempt budget brings that down to four, and the rest
  // would need either a longer budget or a different path.
  inspect(comparison.failures_with_one.to_string(), content="13")
  inspect(comparison.failures_with_four.to_string(), content="4")
  inspect(
    comparison.failures_with_four < comparison.failures_with_one,
    content="true",
  )
  // Nine of the twenty needed more than one attempt and still got through.
  inspect(comparison.rescued.to_string(), content="9")
}

///|
test "loss costs the latency a retry budget implies" {
  let policy = default_policy()
  let clean = measure(0.0, policy, 60)
  let lossy = measure(0.2, policy, 60)
  inspect(clean.delivered, content="60")
  inspect(clean.mean_attempts.to_string(), content="1")
  inspect(clean.mean_latency.render(), content="20.320ms")
  inspect(lossy.delivered < clean.delivered, content="true")
  inspect(lossy.mean_attempts > clean.mean_attempts, content="true")
  inspect(lossy.mean_latency.ps > clean.mean_latency.ps, content="true")
}
