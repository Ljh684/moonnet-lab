///|
/// The parameters a sweep can vary.
///
/// A short list on purpose: these are the knobs an experiment on this simulator
/// actually turns. A new one is a line here and a line in `apply`, not a new
/// configuration language.
pub(all) enum SweepField {
  Loss
  DelayMs
  BandwidthMbps
  QueuePackets
  Seed
}

///|
pub fn SweepField::parse(name : String) -> Result[SweepField, String] {
  match name {
    "loss" => Ok(Loss)
    "delay_ms" => Ok(DelayMs)
    "bandwidth_mbps" => Ok(BandwidthMbps)
    "queue_packets" => Ok(QueuePackets)
    "seed" => Ok(Seed)
    _ =>
      Err(
        "unknown sweep field \"" +
        name +
        "\"; expected one of: loss, delay_ms, bandwidth_mbps, queue_packets, seed",
      )
  }
}

///|
pub fn SweepField::render(self : SweepField) -> String {
  match self {
    Loss => "loss"
    DelayMs => "delay_ms"
    BandwidthMbps => "bandwidth_mbps"
    QueuePackets => "queue_packets"
    Seed => "seed"
  }
}

///|
/// Check that a requested sweep range is usable for its field.
///
/// Queue capacities are positive integers. Their inclusive range must contain
/// at least as many values as requested steps, so every row has a distinct
/// capacity and both endpoints are represented. Library callers should run
/// this check before passing a `QueuePackets` range to `sweep`.
pub fn SweepField::validate_range(
  self : SweepField,
  from : Double,
  to : Double,
  steps : Int,
) -> Result[Unit, String] {
  match self {
    QueuePackets => {
      if steps < 1 {
        return Err("queue_packets sweep steps must be at least 1")
      }
      if from < 1.0 ||
        to < 1.0 ||
        from != from ||
        to != to ||
        from > 2_147_483_647.0 ||
        to > 2_147_483_647.0 ||
        from != from.to_int().to_double() ||
        to != to.to_int().to_double() {
        return Err(
          "queue_packets sweep endpoints must be positive whole numbers within the Int range",
        )
      }
      let first = from.to_int()
      let last = to.to_int()
      let capacity_count = if first > last {
        first - last + 1
      } else {
        last - first + 1
      }
      if steps > capacity_count {
        Err(
          "queue_packets sweep steps exceed the number of distinct capacities in the inclusive range",
        )
      } else if steps == 1 && first != last {
        Err(
          "queue_packets sweep needs at least 2 steps to include both endpoints",
        )
      } else {
        Ok(())
      }
    }
    _ => Ok(())
  }
}

///|
/// The scenario with one parameter replaced. Both directions of the path move
/// together, because a sweep of asymmetric paths would need a different
/// experiment, not a different number.
pub fn SweepField::apply(
  self : SweepField,
  scenario : Scenario,
  value : Double,
) -> Scenario {
  match self {
    Loss =>
      {
        ..scenario,
        uplink: { ..scenario.uplink, loss: value, },
        downlink: { ..scenario.downlink, loss: value, },
      }
    DelayMs =>
      {
        ..scenario,
        uplink: { ..scenario.uplink, delay: @sim.Time::from_ms_f(value), },
        downlink: { ..scenario.downlink, delay: @sim.Time::from_ms_f(value), },
      }
    BandwidthMbps =>
      {
        ..scenario,
        uplink: {
          ..scenario.uplink,
          bandwidth_bps: (value * 1_000_000.0).to_int64(),
        },
        downlink: {
          ..scenario.downlink,
          bandwidth_bps: (value * 1_000_000.0).to_int64(),
        },
      }
    QueuePackets =>
      {
        ..scenario,
        uplink: { ..scenario.uplink, queue_packets: (value + 0.5).to_int(), },
        downlink: {
          ..scenario.downlink,
          queue_packets: (value + 0.5).to_int(),
        },
      }
    Seed => { ..scenario, seed: value.to_int64().reinterpret_as_uint64(), }
  }
}

///|
/// The values a sweep visits, endpoints included.
pub fn sweep_values(from : Double, to : Double, steps : Int) -> Array[Double] {
  let values : Array[Double] = []
  if steps <= 1 {
    values.push(from)
    return values
  }
  let span = to - from
  let divisor = (steps - 1).to_double()
  let mut index = 0
  while index < steps {
    values.push(from + span * index.to_double() / divisor)
    index = index + 1
  }
  values
}

///|
/// What several runs of the same scenario under one algorithm add up to.
///
/// A single run is not a measurement. In a lossy scenario the outcome is
/// dominated by how many times the retransmission timer expires, and each of
/// those costs up to the sixty-second backoff ceiling: a handful of them swings
/// the total by an order of magnitude while the path, the loss rate and the
/// seed are all identical. Averaging over several seeds averages over loss
/// patterns instead, and the range says how much the answer depends on the
/// draw.
pub(all) struct RunSummary {
  algorithm : String
  runs : Int
  mean_elapsed : @sim.Time
  min_elapsed : @sim.Time
  max_elapsed : @sim.Time
  mean_throughput_kbps : Double
  /// Mean time-weighted uplink occupancy, averaged across runs.
  mean_queue_packets : Double
  /// Mean of each run's maximum uplink queue wait.
  mean_max_sojourn : @sim.Time
  /// Largest uplink queue wait observed in any run.
  worst_max_sojourn : @sim.Time
  /// Totals across the runs, not averages: these are counts of things that
  /// happened.
  retransmits : Int
  fast_retransmits : Int
  timeouts : Int
  delivered_bytes : Int
} derive(Eq, Debug)

///|
/// Run one scenario under one algorithm over a range of seeds and summarise.
pub fn summarise(
  scenario : Scenario,
  algorithm : String,
  seeds : Int,
) -> RunSummary {
  let count = if seeds < 1 { 1 } else { seeds }
  let mut total = 0L
  let mut fastest = 0L
  let mut slowest = 0L
  let mut total_queue_packets = 0.0
  let mut total_max_sojourn = 0L
  let mut worst_max_sojourn = 0L
  let mut retransmits = 0
  let mut fast_retransmits = 0
  let mut timeouts = 0
  let mut delivered = 0
  let mut index = 0
  while index < count {
    let experiment = {
      ..scenario,
      algorithm,
      seed: scenario.seed + index.to_uint64(),
    }
    let report = run(experiment)
    let elapsed = report.elapsed.ps
    total = total + elapsed
    if index == 0 || elapsed < fastest {
      fastest = elapsed
    }
    if index == 0 || elapsed > slowest {
      slowest = elapsed
    }
    total_queue_packets = total_queue_packets + report.mean_queue_packets
    total_max_sojourn = total_max_sojourn + report.max_sojourn.ps
    if report.max_sojourn.ps > worst_max_sojourn {
      worst_max_sojourn = report.max_sojourn.ps
    }
    retransmits = retransmits + report.retransmits
    fast_retransmits = fast_retransmits + report.fast_retransmits
    timeouts = timeouts + report.timeouts
    delivered = delivered + report.delivered_bytes
    index = index + 1
  }
  let mean = total / count.to_int64()
  let seconds = mean.to_double() / 1_000_000_000_000.0
  {
    algorithm,
    runs: count,
    mean_elapsed: @sim.Time::from_ps(mean),
    min_elapsed: @sim.Time::from_ps(fastest),
    max_elapsed: @sim.Time::from_ps(slowest),
    mean_throughput_kbps: if seconds <= 0.0 {
      0.0
    } else {
      scenario.payload_bytes.to_double() * 8.0 / seconds / 1000.0
    },
    mean_queue_packets: total_queue_packets / count.to_double(),
    mean_max_sojourn: @sim.Time::from_ps(total_max_sojourn / count.to_int64()),
    worst_max_sojourn: @sim.Time::from_ps(worst_max_sojourn),
    retransmits,
    fast_retransmits,
    timeouts,
    delivered_bytes: delivered,
  }
}

///|
/// One row of a sweep: the parameter value, and what each algorithm did with it.
pub(all) struct SweepRow {
  value : Double
  results : Array[(String, RunSummary)]
}

///|
/// Run one scenario under several algorithms.
///
/// The seed is the same in every row. That makes the runs comparable in the way
/// that matters for an algorithm comparison — same path, same offered traffic,
/// same random stream — but it does not make the *lost packets* identical: each
/// algorithm transmits in a different order, and a link draws its loss decision
/// per transmission. Two rows therefore differ in behaviour, not merely in the
/// timing of an identical loss pattern. Making the loss pattern itself a
/// property of the data rather than of the transmission order is a larger change
/// and is on the roadmap.
pub fn compare(
  scenario : Scenario,
  algorithms : Array[String],
  seeds? : Int = 1,
) -> Array[(String, RunSummary)] {
  let results : Array[(String, RunSummary)] = []
  for name in algorithms {
    results.push((name, summarise(scenario, name, seeds)))
  }
  results
}

///|
/// Run a scenario once per value of one parameter.
pub fn sweep(
  scenario : Scenario,
  field : SweepField,
  from : Double,
  to : Double,
  steps : Int,
  algorithms : Array[String],
  seeds? : Int = 1,
) -> Array[SweepRow] {
  let rows : Array[SweepRow] = []
  for raw_value in sweep_values(from, to, steps) {
    // Queue capacities are integers. The CLI validates ranges to ensure that
    // rounding still gives distinct values and keeps both endpoints.
    let value = match field {
      QueuePackets => (raw_value + 0.5).to_int().to_double()
      _ => raw_value
    }
    rows.push({
      value,
      results: compare(field.apply(scenario, value), algorithms, seeds~),
    })
  }
  rows
}

///|
/// Split a comma-separated list of algorithm names.
pub fn algorithms_of(text : String) -> Result[Array[String], String] {
  let names : Array[String] = []
  for part in text.split(",") {
    let name = part.trim().to_owned()
    if name != "" {
      match known_algorithm(name) {
        Ok(_) => names.push(name)
        Err(message) => return Err(message)
      }
    }
  }
  if names.length() == 0 {
    return Err("no algorithms given; try --cc reno,cubic")
  }
  Ok(names)
}

///|
/// A table rendered with one space between columns, right-aligned except for the
/// first column.
///
/// Rows are padded to the widest cell in their column so that a sweep can be
/// read down a column rather than one row at a time.
pub fn render_table(
  header : Array[String],
  rows : Array[Array[String]],
) -> String {
  let width : Array[Int] = []
  for label in header {
    width.push(label.length())
  }
  for row in rows {
    let mut index = 0
    while index < row.length() && index < width.length() {
      if row[index].length() > width[index] {
        width[index] = row[index].length()
      }
      index = index + 1
    }
  }
  let lines : Array[String] = []
  lines.push(pad_row(header, width, true))
  for row in rows {
    lines.push(pad_row(row, width, false))
  }
  lines.join("\n")
}

///|
fn pad_row(row : Array[String], width : Array[Int], heading : Bool) -> String {
  let out : Array[String] = []
  let mut index = 0
  while index < row.length() && index < width.length() {
    if index == 0 || heading {
      out.push(row[index].pad_end(width[index], ' '))
    } else {
      out.push(row[index].pad_start(width[index], ' '))
    }
    index = index + 1
  }
  out.join("  ")
}

///|
/// The comparison as a table plus a line naming the scenario.
pub fn compare_lines(
  scenario : Scenario,
  results : Array[(String, RunSummary)],
  seeds? : Int = 1,
) -> String {
  let rows : Array[Array[String]] = []
  for entry in results {
    rows.push(report_row(entry.0, entry.1))
  }
  "scenario:   " +
  scenario.name +
  " (seed " +
  scenario.seed.to_string() +
  ", " +
  scenario.payload_bytes.to_string() +
  " bytes, " +
  seeds.to_string() +
  (if seeds == 1 { " run each" } else { " runs each" }) +
  ")\n\n" +
  render_table(
    [
      "algorithm", "mean", "fastest", "slowest", "throughput", "mean queue pkts",
      "mean max wait", "worst max wait", "retransmits", "timeouts",
    ],
    rows,
  ) +
  loss_note(scenario)
}

///|
/// Say what the comparison controls and what it does not.
fn loss_note(scenario : Scenario) -> String {
  if scenario.uplink.loss > 0.0 || scenario.downlink.loss > 0.0 {
    "\n\nnote:       loss follows packet identity, so every row meets the same lost\n" +
    "            packets on a given seed. Acknowledgments carry no identity and\n" +
    "            fall back to transmission order, so their losses still differ.\n" +
    "            In a lossy scenario a few sixty-second timeouts dominate the\n" +
    "            total; more than one run is what makes the mean meaningful."
  } else {
    ""
  }
}

///|
/// The sweep as a table with one row per parameter value and one column per
/// algorithm.
pub fn sweep_lines(
  scenario : Scenario,
  field : SweepField,
  rows : Array[SweepRow],
  algorithms : Array[String],
) -> String {
  let table : Array[Array[String]] = []
  for row in rows {
    let cells : Array[String] = [format_value(field, row.value)]
    for name in algorithms {
      cells.push(throughput_of(row.results, name))
    }
    table.push(cells)
  }
  let header : Array[String] = [field.render()]
  for name in algorithms {
    header.push(name + " kbit/s")
  }
  "scenario:   " +
  scenario.name +
  ", sweeping " +
  field.render() +
  "\n\n" +
  render_table(header, table) +
  "\n\ntimes:\n" +
  render_table(
    time_header(field, algorithms),
    sweep_time_rows(rows, field, algorithms),
  ) +
  "\n\nqueue metrics (uplink; mean max wait averages each run's maximum):\n" +
  render_table(
    queue_header(field, algorithms),
    sweep_queue_rows(rows, field, algorithms),
  )
}

///|
fn queue_header(
  field : SweepField,
  algorithms : Array[String],
) -> Array[String] {
  let header : Array[String] = [field.render()]
  for name in algorithms {
    header.push(name + " mean pkts")
    header.push(name + " mean max ms")
    header.push(name + " worst max ms")
  }
  header
}

///|
fn sweep_queue_rows(
  rows : Array[SweepRow],
  field : SweepField,
  algorithms : Array[String],
) -> Array[Array[String]] {
  let table : Array[Array[String]] = []
  for row in rows {
    let cells : Array[String] = [format_value(field, row.value)]
    for name in algorithms {
      let mut found = false
      for entry in row.results {
        if entry.0 == name {
          cells.push(format_fixed(entry.1.mean_queue_packets, 1))
          cells.push(format_fixed(entry.1.mean_max_sojourn.to_ms_f(), 3))
          cells.push(format_fixed(entry.1.worst_max_sojourn.to_ms_f(), 3))
          found = true
          break
        }
      }
      if !found {
        cells.push("-")
        cells.push("-")
        cells.push("-")
      }
    }
    table.push(cells)
  }
  table
}

///|
fn time_header(field : SweepField, algorithms : Array[String]) -> Array[String] {
  let header : Array[String] = [field.render()]
  for name in algorithms {
    header.push(name)
  }
  header
}

///|
fn sweep_time_rows(
  rows : Array[SweepRow],
  field : SweepField,
  algorithms : Array[String],
) -> Array[Array[String]] {
  let table : Array[Array[String]] = []
  for row in rows {
    let cells : Array[String] = [format_value(field, row.value)]
    for name in algorithms {
      cells.push(elapsed_of(row.results, name))
    }
    table.push(cells)
  }
  table
}

///|
fn report_row(name : String, summary : RunSummary) -> Array[String] {
  [
    name,
    summary.mean_elapsed.render(),
    summary.min_elapsed.render(),
    summary.max_elapsed.render(),
    format_fixed(summary.mean_throughput_kbps, 1),
    format_fixed(summary.mean_queue_packets, 1),
    summary.mean_max_sojourn.render(),
    summary.worst_max_sojourn.render(),
    summary.retransmits.to_string(),
    summary.timeouts.to_string(),
  ]
}

///|
fn throughput_of(
  results : Array[(String, RunSummary)],
  name : String,
) -> String {
  for entry in results {
    if entry.0 == name {
      return format_fixed(entry.1.mean_throughput_kbps, 1)
    }
  }
  "-"
}

///|
fn elapsed_of(results : Array[(String, RunSummary)], name : String) -> String {
  for entry in results {
    if entry.0 == name {
      return entry.1.mean_elapsed.render()
    }
  }
  "-"
}

///|
fn format_value(field : SweepField, value : Double) -> String {
  match field {
    Loss => format_fixed(value, 4)
    QueuePackets => value.to_int().to_string()
    Seed => value.to_int64().to_string()
    _ => format_fixed(value, 1)
  }
}

///|
/// A number with a fixed number of decimals, formatted through integers so that
/// two runs produce the same text.
pub fn format_fixed(value : Double, decimals : Int) -> String {
  let mut scale = 1L
  let mut index = 0
  while index < decimals {
    scale = scale * 10L
    index = index + 1
  }
  let scaled = (value * scale.to_double()).to_int64()
  let whole = scaled / scale
  if decimals == 0 {
    return whole.to_string()
  }
  let fraction = scaled % scale
  let digits = fraction.to_string()
  let padding = decimals - digits.length()
  let mut text = whole.to_string() + "."
  let mut pad = 0
  while pad < padding {
    text = text + "0"
    pad = pad + 1
  }
  text + digits
}

///|
/// The comparison as a document.
pub fn compare_json(
  scenario : Scenario,
  results : Array[(String, RunSummary)],
  seeds? : Int = 1,
) -> String {
  @json.object_of_texts([
    ("scenario", @json.quote(scenario.name)),
    ("seed", scenario.seed.to_string()),
    ("runs", seeds.to_string()),
    ("results", @json.array_of_texts(summaries_json(results))),
  ])
}

///|
/// The sweep as a document: one entry per parameter value.
pub fn sweep_json(
  scenario : Scenario,
  field : SweepField,
  rows : Array[SweepRow],
  algorithms : Array[String],
  seeds? : Int = 1,
) -> String {
  let entries : Array[String] = []
  for row in rows {
    let value_text = match field {
      QueuePackets => format_value(field, row.value)
      _ => format_fixed(row.value, 6)
    }
    entries.push(
      @json.object_of_texts([
        (field.render(), value_text),
        ("algorithms", @json.array_of_texts(quoted(algorithms))),
        ("results", @json.array_of_texts(summaries_json(row.results))),
      ]),
    )
  }
  @json.object_of_texts([
    ("scenario", @json.quote(scenario.name)),
    ("field", @json.quote(field.render())),
    ("runs", seeds.to_string()),
    ("rows", @json.array_of_texts(entries)),
  ])
}

///|
fn summaries_json(results : Array[(String, RunSummary)]) -> Array[String] {
  let parts : Array[String] = []
  for entry in results {
    parts.push(entry.1.to_json_text())
  }
  parts
}

///|
fn quoted(names : Array[String]) -> Array[String] {
  let parts : Array[String] = []
  for name in names {
    parts.push(@json.quote(name))
  }
  parts
}
