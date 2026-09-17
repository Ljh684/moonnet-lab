///|
/// The scenario used by most tests below: a small buffered link that loses a
/// little, with both ends at the defaults.
let sample_document : String =
  #|{
  #|  "name": "small buffers",
  #|  "seed": 9,
  #|  "payload_bytes": 200000,
  #|  "algorithm": "reno",
  #|  "uplink": { "bandwidth_bps": 10000000, "delay_ms": 25, "loss": 0.01, "queue_packets": 16 },
  #|  "downlink": { "bandwidth_bps": 10000000, "delay_ms": 25, "loss": 0.01, "queue_packets": 16 },
  #|  "client": { "mss": 1000, "receive_window": 64000, "initial_seq": 1000 },
  #|  "server": { "mss": 1000, "receive_window": 64000, "initial_seq": 5000 }
  #|}

///|
fn scenario_of(text : String) -> @lab.Scenario {
  let document = match @json.parse(text) {
    Ok(value) => value
    Err(message) => abort("the sample document does not parse: " + message)
  }
  match @lab.Scenario::from_json(document) {
    Ok(scenario) => scenario
    Err(message) => abort("the sample document is not a scenario: " + message)
  }
}

///|
/// The message from a document that should have been rejected.
fn scenario_error(text : String) -> String {
  let document = match @json.parse(text) {
    Ok(value) => value
    Err(message) => abort("the document does not even parse: " + message)
  }
  match @lab.Scenario::from_json(document) {
    Ok(_) => abort("expected the document to be rejected")
    Err(message) => message
  }
}

///|
test "a scenario reads every field" {
  let scenario = scenario_of(sample_document)
  inspect(scenario.name, content="small buffers")
  inspect(scenario.seed, content="9")
  inspect(scenario.payload_bytes, content="200000")
  inspect(scenario.algorithm, content="reno")
  inspect(scenario.uplink.bandwidth_bps, content="10000000")
  inspect(scenario.uplink.delay.render(), content="25.000ms")
  inspect(scenario.uplink.loss, content="0.01")
  inspect(scenario.uplink.queue_packets, content="16")
  inspect(scenario.client.receive_window, content="64000")
  inspect(scenario.server.initial_seq, content="5000")
}

///|
test "omitted fields fall back to documented defaults" {
  let scenario = scenario_of(
    "{\"name\": \"minimal\", \"payload_bytes\": 1000, \"uplink\": {\"bandwidth_bps\": 1000000}}",
  )
  inspect(scenario.algorithm, content="reno")
  inspect(scenario.seed, content="1")
  inspect(scenario.uplink.delay.render(), content="10.000ms")
  inspect(scenario.uplink.loss, content="0")
  inspect(scenario.uplink.queue_packets, content="64")
  inspect(scenario.downlink.bandwidth_bps, content="1000000")
  inspect(scenario.client.mss, content="1000")
  inspect(scenario.server.initial_seq, content="5000")
}

///|
test "a malformed scenario names the field it disliked" {
  inspect(
    scenario_error(
      "{\"payload_bytes\": 1000, \"uplink\": {\"bandwidth_bps\": 1}}",
    ),
    content="scenario.name is required",
  )
  inspect(
    scenario_error("{\"name\": \"x\", \"uplink\": {\"bandwidth_bps\": 1}}"),
    content="scenario.payload_bytes must be greater than zero",
  )
  inspect(
    scenario_error(
      "{\"name\": \"x\", \"payload_bytes\": 1, \"uplink\": {\"bandwidth_bps\": \"fast\"}}",
    ),
    content="scenario.uplink.bandwidth_bps must be a number",
  )
  inspect(
    scenario_error("{\"name\": \"x\", \"payload_bytes\": 1}"),
    content="scenario.uplink is required",
  )
  inspect(
    scenario_error(
      "{\"name\": \"x\", \"payload_bytes\": 1, \"uplink\": {\"bandwidth_bps\": 1}, \"algorithm\": \"vegas\"}",
    ),
    content="scenario.algorithm \"vegas\" is not one of: none, reno, cubic",
  )
  inspect(
    scenario_error(
      "{\"name\": \"x\", \"payload_bytes\": 1, \"uplink\": {\"bandwidth_bps\": 1, \"loss\": 1.5}}",
    ),
    content="scenario.uplink.loss must be in [0, 1)",
  )
}

///|
test "running a scenario produces the measurements it promises" {
  let report = @lab.run(scenario_of(sample_document))
  inspect(report.scenario, content="small buffers")
  inspect(report.algorithm, content="reno")
  inspect(report.delivered_bytes, content="200000")
  inspect(report.seed, content="9")
  // The transfer is lossy, so something had to be sent again.
  inspect(report.retransmits > 0, content="true")
  inspect(report.uplink_lost > 0, content="true")
  inspect(report.round_trips > 0, content="true")
  inspect(report.final_cwnd > 0, content="true")
}

///|
test "the same scenario twice produces the same report" {
  let first = @lab.run(scenario_of(sample_document))
  let second = @lab.run(scenario_of(sample_document))
  inspect(first == second, content="true")
  inspect(first.to_json_text() == second.to_json_text(), content="true")
  inspect(first.to_lines() == second.to_lines(), content="true")
}

///|
test "the report is a document with the fields it says it has" {
  let report = @lab.run(scenario_of(sample_document))
  let text = report.to_json_text()
  let parsed = match @json.parse(text) {
    Ok(value) => value
    Err(message) => abort("the report is not valid JSON: " + message)
  }
  inspect(
    parsed.field("scenario").unwrap().as_text().unwrap(),
    content="small buffers",
  )
  inspect(
    parsed.field("delivered_bytes").unwrap().as_number().unwrap(),
    content="200000",
  )
  inspect(parsed.field("timeouts") is None, content="false")
  // Throughput is derived, and the report states it rather than leaving the
  // reader to divide two other fields.
  inspect(
    parsed.field("throughput_kbps").unwrap().as_number().unwrap() > 0.0,
    content="true",
  )
}

///|
test "the three algorithms are all selectable by name" {
  inspect(@lab.known_algorithm("none") is Ok(_), content="true")
  inspect(@lab.known_algorithm("reno") is Ok(_), content="true")
  inspect(@lab.known_algorithm("cubic") is Ok(_), content="true")
  inspect(@lab.known_algorithm("vegas") is Err(_), content="true")
}
