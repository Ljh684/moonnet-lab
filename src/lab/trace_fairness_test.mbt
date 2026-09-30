///|
/// A four-flow fairness experiment, traced. The four flows share one path, so
/// this is the smallest case in which "which flow is which" means anything.
let fairness_trace_document : String =
  #|{
  #|  "name": "trace fairness",
  #|  "seed": 9,
  #|  "payload_bytes": 4000000,
  #|  "duration_ms": 2000,
  #|  "algorithm": "reno",
  #|  "uplink": { "bandwidth_bps": 10000000, "delay_ms": 25, "loss": 0.0005, "queue_packets": 64 },
  #|  "client": { "mss": 1000, "receive_window": 32000 },
  #|  "server": { "mss": 1000, "receive_window": 32000 },
  #|  "flows": [ { "algorithm": "reno", "count": 2 }, { "algorithm": "cubic", "count": 2 } ]
  #|}

///|
test "a fairness trace carries one identity per flow" {
  let scenario = scenario_of(fairness_trace_document)
  let traced = @lab.run_fairness_with_trace(scenario)
  // The trace and the table come from the same run, so asking for one cannot
  // change the other.
  let plain = @lab.run_fairness(scenario)
  inspect(traced.report.to_json_text() == plain.to_json_text(), content="true")
  inspect(traced.report.flows.length(), content="4")
  // Every transport event says which flow it belongs to; the queue events do
  // not, because the queue is shared by all of them.
  let journal = traced.events.join("\n")
  inspect(traced.events.length() > 0, content="true")
  for flow in [1, 2, 3, 4] {
    inspect(journal.contains("|flow=" + flow.to_string() + "|"), content="true")
  }
  inspect(traced.to_json_text().contains("\"flows\":4"), content="true")
}

///|
test "a fairness chart distinguishes the flows and agrees with the report" {
  let scenario = scenario_of(fairness_trace_document)
  let traced = @lab.run_fairness_with_trace(scenario)
  let source = traced.to_json_text()
  let first = match @lab.fairness_trace_svg_from_json(source) {
    Ok(svg) => svg
    Err(message) => abort("cannot render fairness trace: " + message)
  }
  let second = match @lab.fairness_trace_svg_from_json(source) {
    Ok(svg) => svg
    Err(message) => abort("cannot render fairness trace twice: " + message)
  }
  // The same trace always draws the same picture.
  inspect(first == second, content="true")
  inspect(
    first.contains("<svg xmlns=\"http://www.w3.org/2000/svg\""),
    content="true",
  )
  // One line per flow, and the palette keeps them apart.
  for color in ["#1f77b4", "#d62728", "#2ca02c", "#ff7f0e"] {
    inspect(first.contains("stroke=\"" + color + "\""), content="true")
  }
  // The legend carries what the report says, byte for byte: change the report
  // and the chart has to change with it.
  for flow in traced.report.flows {
    inspect(
      first.contains(flow.delivered_bytes.to_string() + " B"),
      content="true",
    )
  }
  inspect(first.contains("4 flows sharing one path"), content="true")
  // Both directions of the shared path are drawn, not just the one the data
  // happens to travel on.
  inspect(first.contains("uplink queue"), content="true")
  inspect(first.contains("downlink queue"), content="true")
  inspect(
    first.contains("packets waiting in the shared queues"),
    content="true",
  )
}

///|
test "a fairness chart refuses a document that is not one" {
  inspect(
    @lab.fairness_trace_svg_from_json("{ \"report\": { \"scenario\": \"x\" } }")
    is Err(_),
    content="true",
  )
  inspect(
    @lab.fairness_trace_svg_from_json("not json") is Err(_),
    content="true",
  )
}
