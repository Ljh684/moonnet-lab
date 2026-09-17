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
  Seed
}

///|
pub fn SweepField::parse(name : String) -> Result[SweepField, String] {
  match name {
    "loss" => Ok(Loss)
    "delay_ms" => Ok(DelayMs)
    "bandwidth_mbps" => Ok(BandwidthMbps)
    "seed" => Ok(Seed)
    _ =>
      Err(
        "unknown sweep field \"" +
        name +
        "\"; expected one of: loss, delay_ms, bandwidth_mbps, seed",
      )
  }
}

///|
pub fn SweepField::render(self : SweepField) -> String {
  match self {
    Loss => "loss"
    DelayMs => "delay_ms"
    BandwidthMbps => "bandwidth_mbps"
    Seed => "seed"
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
/// One row of a sweep: the parameter value, and what each algorithm did with it.
pub(all) struct SweepRow {
  value : Double
  results : Array[(String, RunReport)]
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
) -> Array[(String, RunReport)] {
  let results : Array[(String, RunReport)] = []
  for name in algorithms {
    let experiment = { ..scenario, algorithm: name, }
    results.push((name, run(experiment)))
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
) -> Array[SweepRow] {
  let rows : Array[SweepRow] = []
  for value in sweep_values(from, to, steps) {
    rows.push({
      value,
      results: compare(field.apply(scenario, value), algorithms),
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
  results : Array[(String, RunReport)],
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
  " bytes)\n\n" +
  render_table(
    [
      "algorithm", "elapsed", "throughput", "retransmits", "fast", "timeouts", "final cwnd",
    ],
    rows,
  ) +
  loss_note(scenario)
}

///|
/// Say so when the rows are not seeing the same losses.
///
/// Every link decides loss per transmission, and two algorithms transmit in
/// different orders, so the same seed does not give the same lost packets. The
/// comparison is of behaviour under the same conditions, which is worth stating
/// rather than leaving for the reader to work out.
fn loss_note(scenario : Scenario) -> String {
  if scenario.uplink.loss > 0.0 || scenario.downlink.loss > 0.0 {
    "\n\nnote:       each row draws its own losses, because a link decides per\n" +
    "            transmission and the algorithms transmit in different orders."
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
  )
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
fn report_row(name : String, report : RunReport) -> Array[String] {
  [
    name,
    report.elapsed.render(),
    format_fixed(report.throughput_kbps(), 1),
    report.retransmits.to_string(),
    report.fast_retransmits.to_string(),
    report.timeouts.to_string(),
    report.final_cwnd.to_string(),
  ]
}

///|
fn throughput_of(results : Array[(String, RunReport)], name : String) -> String {
  for entry in results {
    if entry.0 == name {
      return format_fixed(entry.1.throughput_kbps(), 1)
    }
  }
  "-"
}

///|
fn elapsed_of(results : Array[(String, RunReport)], name : String) -> String {
  for entry in results {
    if entry.0 == name {
      return entry.1.elapsed.render()
    }
  }
  "-"
}

///|
fn format_value(field : SweepField, value : Double) -> String {
  match field {
    Loss => format_fixed(value, 4)
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
  results : Array[(String, RunReport)],
) -> String {
  @json.object_of_texts([
    ("scenario", @json.quote(scenario.name)),
    ("seed", scenario.seed.to_string()),
    ("results", @json.array_of_texts(reports_json(results))),
  ])
}

///|
/// The sweep as a document: one entry per parameter value.
pub fn sweep_json(
  scenario : Scenario,
  field : SweepField,
  rows : Array[SweepRow],
  algorithms : Array[String],
) -> String {
  let entries : Array[String] = []
  for row in rows {
    entries.push(
      @json.object_of_texts([
        (field.render(), format_fixed(row.value, 6)),
        ("algorithms", @json.array_of_texts(quoted(algorithms))),
        ("results", @json.array_of_texts(reports_json(row.results))),
      ]),
    )
  }
  @json.object_of_texts([
    ("scenario", @json.quote(scenario.name)),
    ("field", @json.quote(field.render())),
    ("rows", @json.array_of_texts(entries)),
  ])
}

///|
fn reports_json(results : Array[(String, RunReport)]) -> Array[String] {
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
