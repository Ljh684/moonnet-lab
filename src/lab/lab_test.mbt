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

///|
/// A scenario small enough to run several times inside one test.
let quick_document : String =
  #|{
  #|  "name": "quick",
  #|  "seed": 3,
  #|  "payload_bytes": 60000,
  #|  "algorithm": "reno",
  #|  "uplink": { "bandwidth_bps": 10000000, "delay_ms": 5, "loss": 0.01, "queue_packets": 32 },
  #|  "client": { "mss": 1000, "receive_window": 32000 }
  #|}

///|
test "comparing runs every algorithm on the same scenario" {
  let scenario = scenario_of(quick_document)
  let results = @lab.compare(scenario, ["none", "reno", "cubic"])
  inspect(results.length(), content="3")
  inspect(results[0].0, content="none")
  inspect(results[1].0, content="reno")
  inspect(results[2].0, content="cubic")
  for entry in results {
    // Every algorithm delivers the whole payload; they differ in how long they
    // take and how much they had to send again.
    inspect(entry.1.delivered_bytes, content="60000")
    inspect(entry.1.seed, content="3")
  }
  // The algorithm in the report comes from the connection, not from the request.
  inspect(results[2].1.algorithm, content="cubic")
}

///|
test "a comparison renders as a table and as a document" {
  let scenario = scenario_of(quick_document)
  let results = @lab.compare(scenario, ["reno", "cubic"])
  let lines = @lab.compare_lines(scenario, results)
  inspect(lines.contains("algorithm"), content="true")
  inspect(lines.contains("final cwnd"), content="true")
  inspect(lines.contains("quick"), content="true")
  // A lossy scenario says so rather than letting the reader assume the rows saw
  // the same lost packets.
  inspect(lines.contains("each row draws its own losses"), content="true")
  let document = match @json.parse(@lab.compare_json(scenario, results)) {
    Ok(value) => value
    Err(message) => abort("the comparison is not valid JSON: " + message)
  }
  inspect(
    document.field("results").unwrap().as_list().unwrap().length(),
    content="2",
  )
}

///|
test "a comparison is the same twice" {
  let scenario = scenario_of(quick_document)
  let first = @lab.compare(scenario, ["reno", "cubic"])
  let second = @lab.compare(scenario, ["reno", "cubic"])
  inspect(
    @lab.compare_lines(scenario, first) == @lab.compare_lines(scenario, second),
    content="true",
  )
  inspect(
    @lab.compare_json(scenario, first) == @lab.compare_json(scenario, second),
    content="true",
  )
}

///|
test "sweep values include both endpoints" {
  inspect(@lab.sweep_values(0.0, 1.0, 5).length(), content="5")
  inspect(@lab.sweep_values(0.0, 1.0, 5)[0], content="0")
  inspect(@lab.sweep_values(0.0, 1.0, 5)[2], content="0.5")
  inspect(@lab.sweep_values(0.0, 1.0, 5)[4], content="1")
  // A single step is a point, not a division by zero.
  inspect(@lab.sweep_values(0.25, 1.0, 1).length(), content="1")
  inspect(@lab.sweep_values(0.25, 1.0, 1)[0], content="0.25")
}

///|
test "a sweep field changes the parameter it names, in both directions" {
  let scenario = scenario_of(quick_document)
  let lossy = @lab.SweepField::Loss.apply(scenario, 0.05)
  inspect(lossy.uplink.loss, content="0.05")
  inspect(lossy.downlink.loss, content="0.05")
  // Only the named field moves.
  inspect(lossy.uplink.delay.render(), content="5.000ms")
  inspect(lossy.payload_bytes, content="60000")
  let slow = @lab.SweepField::DelayMs.apply(scenario, 40.0)
  inspect(slow.uplink.delay.render(), content="40.000ms")
  inspect(slow.downlink.delay.render(), content="40.000ms")
  inspect(slow.uplink.loss, content="0.01")
  let narrow = @lab.SweepField::BandwidthMbps.apply(scenario, 2.0)
  inspect(narrow.uplink.bandwidth_bps, content="2000000")
  inspect(narrow.downlink.bandwidth_bps, content="2000000")
  let reseeded = @lab.SweepField::Seed.apply(scenario, 42.0)
  inspect(reseeded.seed, content="42")
}

///|
test "a sweep runs once per value and reports the value it used" {
  let scenario = scenario_of(quick_document)
  let field = @lab.SweepField::Loss
  let rows = @lab.sweep(scenario, field, 0.0, 0.02, 3, ["reno"])
  inspect(rows.length(), content="3")
  inspect(rows[0].value, content="0")
  inspect(rows[1].value, content="0.01")
  inspect(rows[2].value, content="0.02")
  for row in rows {
    inspect(row.results.length(), content="1")
    inspect(row.results[0].1.delivered_bytes, content="60000")
  }
  // A clean path is faster than a lossy one, which is the whole point of
  // sweeping the loss rate.
  inspect(
    rows[0].results[0].1.elapsed.ps < rows[2].results[0].1.elapsed.ps,
    content="true",
  )
  let lines = @lab.sweep_lines(scenario, field, rows, ["reno"])
  inspect(lines.contains("sweeping loss"), content="true")
  let document = match
    @json.parse(@lab.sweep_json(scenario, field, rows, ["reno"])) {
    Ok(value) => value
    Err(message) => abort("the sweep is not valid JSON: " + message)
  }
  inspect(
    document.field("rows").unwrap().as_list().unwrap().length(),
    content="3",
  )
}

///|
test "tables line up their columns" {
  let table = @lab.render_table(["a", "bbbb"], [["xx", "1"], ["y", "22"]])
  inspect(table, content="a   bbbb\nxx     1\ny     22")
}

///|
test "fixed point numbers keep their decimals" {
  inspect(@lab.format_fixed(1.5, 1), content="1.5")
  inspect(@lab.format_fixed(2.0, 3), content="2.000")
  inspect(@lab.format_fixed(0.25, 4), content="0.2500")
  inspect(@lab.format_fixed(1234.567, 1), content="1234.5")
  inspect(@lab.format_fixed(9.0, 0), content="9")
}

///|
test "algorithm lists are parsed and checked" {
  let names = match @lab.algorithms_of("reno,cubic") {
    Ok(value) => value
    Err(message) => abort("expected the list to parse: " + message)
  }
  inspect(names.length(), content="2")
  inspect(names[1], content="cubic")
  // Spaces are tolerated, empty entries are dropped.
  inspect(@lab.algorithms_of(" reno , ").unwrap().length(), content="1")
  inspect(@lab.algorithms_of("reno,nonesuch") is Err(_), content="true")
  inspect(@lab.algorithms_of("") is Err(_), content="true")
}
