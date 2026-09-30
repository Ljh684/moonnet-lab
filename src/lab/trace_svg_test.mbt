///|
let trace_chart_fixture : String =
  #|{
  #|  "report": { "scenario": "A & B <trace>", "algorithm": "cubic" },
  #|  "delivery_diagnostics": {
  #|    "stall_intervals": [{ "start_ps": 1000000000, "end_ps": 3000000000 }]
  #|  },
  #|  "events": [
  #|    "tcp|0|send|cwnd=10000|inflight=4000",
  #|    "net|500000000|queue|up|enqueue:accepted|packets=2|bytes=2000|dropped=0|early=0",
  #|    "tcp|1000000000|fast_retransmit|cwnd=8000|inflight=3000",
  #|    "net|1500000000|queue|down|enqueue:accepted|packets=1|bytes=1000|dropped=0|early=0",
  #|    "tcp|2500000000|delivery|bytes=900|total=900|gap_ps=0",
  #|    "tcp|3000000000|tail_probe|cwnd=6000|inflight=1000",
  #|    "tcp|5000000000|timeout|cwnd=1000|inflight=0"
  #|  ]
  #|}

///|
test "trace SVG is deterministic and shows TCP, queues, events and stalls" {
  let first = match @lab.trace_svg_from_json(trace_chart_fixture) {
    Ok(svg) => svg
    Err(message) => abort("cannot render fixture trace: " + message)
  }
  let second = match @lab.trace_svg_from_json(trace_chart_fixture) {
    Ok(svg) => svg
    Err(message) => abort("cannot render fixture trace twice: " + message)
  }
  inspect(first == second, content="true")
  inspect(
    first.contains("<svg xmlns=\"http://www.w3.org/2000/svg\""),
    content="true",
  )
  inspect(first.contains("A &amp; B &lt;trace&gt;"), content="true")
  inspect(first.contains("class=\"series cwnd\""), content="true")
  inspect(first.contains("class=\"series inflight\""), content="true")
  inspect(first.contains("class=\"series uplink\""), content="true")
  inspect(first.contains("class=\"series downlink\""), content="true")
  inspect(first.contains("class=\"event event-fast\""), content="true")
  inspect(first.contains("class=\"event event-probe\""), content="true")
  inspect(first.contains("class=\"event event-timeout\""), content="true")
  inspect(first.contains("<rect class=\"stall\""), content="true")
}

///|
test "trace SVG rejects malformed and empty trace documents" {
  let malformed = match @lab.trace_svg_from_json("not JSON") {
    Ok(_) => false
    Err(_) => true
  }
  inspect(malformed, content="true")
  let empty_document : String =
    #|{"report":{"scenario":"empty","algorithm":"reno"},"events":[]}
  let empty = match @lab.trace_svg_from_json(empty_document) {
    Ok(_) => false
    Err(_) => true
  }
  inspect(empty, content="true")
}
