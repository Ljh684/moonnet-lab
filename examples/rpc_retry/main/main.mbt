///|
/// The question a service author actually has: on a path that drops this
/// much, what does a call cost, and how many calls never come back?
///
///     moon run examples/rpc_retry/main
///
/// Same seeds in, same table out, on any machine - which is the whole reason
/// to model this instead of measuring it on a real network.
fn main {
  let seeds = 60
  let policy = @rpc_retry.default_policy()
  println("call outcome over " + seeds.to_string() + " calls per row")
  println("loss   delivered   mean attempts   mean latency")
  for loss in [0.0, 0.01, 0.05, 0.2, 0.5] {
    println(@rpc_retry.measure(loss, policy, seeds).to_line(loss))
  }
}
