///|
test "delivery stalls count only long gaps and retain observed signals" {
  let events = [
    "tcp|100|delivery|bytes=1000|total=1000|gap_ps=0", "net|120|queue|uplink|enqueue:accepted|packets=2|bytes=2000|dropped=0|early=0",
    "net|200|queue|uplink|dequeue|packets=0|bytes=0|dropped=0|early=0", "tcp|300|delivery|bytes=1000|total=2000|gap_ps=200",
    "tcp|350|timeout|state=established|cwnd=1000|inflight=1000|srtt_ps=50|rto_ps=200",
    "tcp|500|delivery|bytes=1000|total=3000|gap_ps=200", "tcp|550|send_blocked|state=established|cwnd=1000|inflight=1000|srtt_ps=50|rto_ps=200",
    "tcp|700|delivery|bytes=500|total=3500|gap_ps=200", "tcp|750|delivery|bytes=500|total=4000|gap_ps=50",
  ]
  let diagnostics = diagnose_delivery_stalls(events, @sim.Time::from_ps(100L))
  inspect(diagnostics.threshold.ps, content="100")
  inspect(diagnostics.intervals.length(), content="3")
  inspect(diagnostics.total_duration.ps, content="600")
  inspect(diagnostics.max_duration.ps, content="200")
  let queue_stall = diagnostics.intervals[0]
  inspect(queue_stall.start.ps, content="100")
  inspect(queue_stall.end.ps, content="300")
  inspect(queue_stall.next_delivery_bytes, content="1000")
  inspect(queue_stall.path_queue_seen, content="true")
  inspect(queue_stall.recovery_event_seen, content="false")
  inspect(queue_stall.sender_window_blocked_seen, content="false")
  let recovery_stall = diagnostics.intervals[1]
  inspect(recovery_stall.path_queue_seen, content="false")
  inspect(recovery_stall.recovery_event_seen, content="true")
  inspect(recovery_stall.sender_window_blocked_seen, content="false")
  let sender_stall = diagnostics.intervals[2]
  inspect(sender_stall.path_queue_seen, content="false")
  inspect(sender_stall.recovery_event_seen, content="false")
  inspect(sender_stall.sender_window_blocked_seen, content="true")
}

///|
test "delivery diagnostics remain empty without a long inter-delivery gap" {
  let events = [
    "tcp|100|delivery|bytes=1000|total=1000|gap_ps=0", "tcp|150|delivery|bytes=1000|total=2000|gap_ps=50",
  ]
  let diagnostics = diagnose_delivery_stalls(events, @sim.Time::from_ps(100L))
  inspect(diagnostics.intervals.length(), content="0")
  inspect(diagnostics.total_duration.ps, content="0")
  inspect(diagnostics.max_duration.ps, content="0")
}
