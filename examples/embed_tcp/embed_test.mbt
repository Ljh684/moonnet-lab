///|
test "an embedded transfer delivers what it was given" {
  let result = transfer(algorithm("cubic", 1000), 1_000_000, 0.01, 9UL)
  inspect(result.delivered_bytes, content="1000000")
  inspect(result.algorithm, content="cubic")
  // A lossy path means something had to be sent again.
  inspect(result.retransmits > 0, content="true")
  inspect(result.srtt.ps > 0L, content="true")
}

///|
test "an embedded run is reproducible" {
  let first = transfer(algorithm("reno", 1000), 500_000, 0.02, 4UL)
  let second = transfer(algorithm("reno", 1000), 500_000, 0.02, 4UL)
  inspect(first == second, content="true")
  inspect(first.elapsed.render(), content=second.elapsed.render())
}

///|
test "the choice of algorithm is visible in the measurement" {
  let reno = transfer(algorithm("reno", 1000), 4_000_000, 0.01, 11UL)
  let cubic = transfer(algorithm("cubic", 1000), 4_000_000, 0.01, 11UL)
  inspect(reno.delivered_bytes, content="4000000")
  inspect(cubic.delivered_bytes, content="4000000")
  // CUBIC keeps more of its window after a loss, so on this path it sends
  // fewer packets again than Reno does.
  inspect(cubic.retransmits < reno.retransmits, content="true")
}
