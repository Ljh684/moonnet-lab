///|
/// The properties of one direction of a path.
pub(all) struct LinkProfile {
  name : String
  bandwidth_bps : Int64
  delay : @sim.Time
  loss : Double
  queue_packets : Int
} derive(Eq, Debug)

///|
/// The properties of one end of the connection.
pub(all) struct ConnectionProfile {
  mss : Int
  receive_window : Int
  initial_seq : UInt
} derive(Eq, Debug)

///|
/// One experiment, expressed as data rather than as code.
///
/// Everything a run depends on is here: the path in both directions, both ends
/// of the connection, how much to send, the random seed, and which congestion
/// control algorithm to use. Two runs of the same scenario produce the same
/// numbers, which is what makes a result worth writing down.
pub(all) struct Scenario {
  name : String
  seed : UInt64
  payload_bytes : Int
  algorithm : String
  uplink : LinkProfile
  downlink : LinkProfile
  client : ConnectionProfile
  server : ConnectionProfile
} derive(Eq, Debug)

///|
/// Read a scenario from a parsed document.
///
/// Every error names the path of the field it came from, because a scenario is
/// written by hand and "expected a number" without a location is a puzzle rather
/// than a message.
pub fn Scenario::from_json(document : @json.Json) -> Result[Scenario, String] {
  let name = match text_field(document, "", "name", "") {
    Ok(value) => value
    Err(message) => return Err(message)
  }
  if name == "" {
    return Err("scenario.name is required")
  }
  let seed = match number_field(document, "", "seed", 1.0) {
    Ok(value) => value
    Err(message) => return Err(message)
  }
  let payload_bytes = match number_field(document, "", "payload_bytes", 0.0) {
    Ok(value) => value
    Err(message) => return Err(message)
  }
  if payload_bytes <= 0.0 {
    return Err("scenario.payload_bytes must be greater than zero")
  }
  let algorithm = match text_field(document, "", "algorithm", "reno") {
    Ok(value) => value
    Err(message) => return Err(message)
  }
  match known_algorithm(algorithm) {
    Ok(_) => ()
    Err(message) => return Err(message)
  }
  let uplink = match link_profile(document, "uplink", "up") {
    Ok(value) => value
    Err(message) => return Err(message)
  }
  // A scenario that describes one direction gets the same path in reverse. Most
  // experiments are symmetric, and repeating the numbers invites them to drift
  // apart without anyone noticing.
  let downlink = match document.field("downlink") {
    None => { ..uplink, name: "down", }
    Some(_) =>
      match link_profile(document, "downlink", "down") {
        Ok(value) => value
        Err(message) => return Err(message)
      }
  }
  let client = match connection_profile(document, "client", 1000U) {
    Ok(value) => value
    Err(message) => return Err(message)
  }
  let server = match connection_profile(document, "server", 5000U) {
    Ok(value) => value
    Err(message) => return Err(message)
  }
  Ok({
    name,
    seed: seed.to_int64().reinterpret_as_uint64(),
    payload_bytes: payload_bytes.to_int(),
    algorithm,
    uplink,
    downlink,
    client,
    server,
  })
}

///|
/// The name of a congestion control algorithm, checked here so that a typo is
/// reported when the scenario is read rather than silently turning into Reno.
pub fn known_algorithm(name : String) -> Result[Unit, String] {
  match name {
    "none" | "reno" | "cubic" => Ok(())
    _ =>
      Err(
        "scenario.algorithm \"" + name + "\" is not one of: none, reno, cubic",
      )
  }
}

///|
fn link_profile(
  document : @json.Json,
  field : String,
  default_name : String,
) -> Result[LinkProfile, String] {
  let section = match document.field(field) {
    None => return Err("scenario." + field + " is required")
    Some(value) => value
  }
  let bandwidth = match number_field(section, field, "bandwidth_bps", 0.0) {
    Ok(value) => value
    Err(message) => return Err(message)
  }
  if bandwidth <= 0.0 {
    return Err("scenario." + field + ".bandwidth_bps must be greater than zero")
  }
  let delay_ms = match number_field(section, field, "delay_ms", 10.0) {
    Ok(value) => value
    Err(message) => return Err(message)
  }
  let loss = match number_field(section, field, "loss", 0.0) {
    Ok(value) => value
    Err(message) => return Err(message)
  }
  if loss < 0.0 || loss >= 1.0 {
    return Err("scenario." + field + ".loss must be in [0, 1)")
  }
  let queue = match number_field(section, field, "queue_packets", 64.0) {
    Ok(value) => value
    Err(message) => return Err(message)
  }
  if queue < 1.0 {
    return Err("scenario." + field + ".queue_packets must be at least 1")
  }
  Ok({
    name: default_name,
    bandwidth_bps: bandwidth.to_int64(),
    delay: @sim.Time::from_ms_f(delay_ms),
    loss,
    queue_packets: queue.to_int(),
  })
}

///|
fn connection_profile(
  document : @json.Json,
  field : String,
  default_seq : UInt,
) -> Result[ConnectionProfile, String] {
  let section = match document.field(field) {
    None =>
      // A scenario that only cares about the path can leave both ends at the
      // same defaults.
      return Ok({ mss: 1000, receive_window: 65_536, initial_seq: default_seq, })
    Some(value) => value
  }
  let mss = match number_field(section, field, "mss", 1000.0) {
    Ok(value) => value
    Err(message) => return Err(message)
  }
  if mss < 1.0 {
    return Err("scenario." + field + ".mss must be at least 1")
  }
  let window = match number_field(section, field, "receive_window", 65_536.0) {
    Ok(value) => value
    Err(message) => return Err(message)
  }
  if window < mss {
    return Err(
      "scenario." + field + ".receive_window must be at least one segment",
    )
  }
  let seq = match
    number_field(section, field, "initial_seq", default_seq.to_double()) {
    Ok(value) => value
    Err(message) => return Err(message)
  }
  Ok({
    mss: mss.to_int(),
    receive_window: window.to_int(),
    initial_seq: seq.to_int().reinterpret_as_uint(),
  })
}

///|
/// A field that must be a number, with a default when it is absent.
fn number_field(
  document : @json.Json,
  path : String,
  field : String,
  default : Double,
) -> Result[Double, String] {
  match document.field(field) {
    None => Ok(default)
    Some(value) =>
      match value.as_number() {
        Some(number) => Ok(number)
        None => Err(locate(path, field) + " must be a number")
      }
  }
}

///|
/// A field that must be text, with a default when it is absent.
fn text_field(
  document : @json.Json,
  path : String,
  field : String,
  default : String,
) -> Result[String, String] {
  match document.field(field) {
    None => Ok(default)
    Some(value) =>
      match value.as_text() {
        Some(text) => Ok(text)
        None => Err(locate(path, field) + " must be text")
      }
  }
}

///|
fn locate(path : String, field : String) -> String {
  if path == "" {
    "scenario." + field
  } else {
    "scenario." + path + "." + field
  }
}
