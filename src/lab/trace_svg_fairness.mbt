///|
/// One flow's line in a fairness chart: what it is called, what it delivered,
/// and its congestion window over time.
priv struct FairnessLine {
  label : String
  color : String
  delivered : Int
  share : String
  samples : Array[(Int64, Int)]
}

///|
/// The colours a fairness chart cycles through. Fixed rather than generated, so
/// the same trace always produces the same picture.
fn fairness_color(index : Int) -> String {
  let palette : Array[String] = [
    "#1f77b4", "#d62728", "#2ca02c", "#ff7f0e", "#9467bd", "#8c564b", "#17becf",
    "#e377c2",
  ]
  palette[index % palette.length()]
}

///|
fn json_int_field(value : @json.Json, field : String) -> Int {
  match value.field(field) {
    Some(inner) =>
      match inner.as_number() {
        Some(number) => number.to_int()
        None => 0
      }
    None => 0
  }
}

///|
fn json_text_field(value : @json.Json, field : String) -> String {
  match value.field(field) {
    Some(inner) =>
      match inner.as_text() {
        Some(text) => text
        None => ""
      }
    None => ""
  }
}

///|
/// A numeric field, formatted the way the report writes it. Shares and the
/// Jain index are numbers, not strings, so they have to go through the same
/// fixed-point formatting the report uses or the chart and the table would
/// disagree about the last digit.
fn json_number_text(value : @json.Json, field : String, places : Int) -> String {
  match value.field(field) {
    Some(inner) =>
      match inner.as_number() {
        Some(number) => format_fixed(number, places)
        None => ""
      }
    None => ""
  }
}

///|
/// A structured field of a trace event, as an integer.
fn event_integer(fields : Array[String], key : String) -> Int? {
  match trace_field(fields, key) {
    Some(text) =>
      match trace_chart_integer(text) {
        Ok(value) => Some(value.to_int())
        Err(_) => None
      }
    None => None
  }
}

///|
/// A polyline through `samples`, scaled into a box with integer arithmetic.
fn fairness_polyline(
  samples : Array[(Int64, Int)],
  max_time : Int64,
  x0 : Int,
  width : Int,
  y0 : Int,
  height : Int,
  scale : Int,
  color : String,
) -> String {
  let points : Array[String] = []
  for sample in samples {
    let (time, value) = sample
    let x = if max_time <= 0L {
      x0
    } else {
      x0 + (time * width.to_int64() / max_time).to_int()
    }
    let y = if scale <= 0 {
      y0 + height
    } else {
      y0 + height - value * height / scale
    }
    points.push(x.to_string() + "," + y.to_string())
  }
  "<polyline fill=\"none\" stroke=\"" +
  color +
  "\" stroke-width=\"1\" points=\"" +
  points.join(" ") +
  "\"/>"
}

///|
/// Render a multi-flow fairness trace as a standalone SVG.
///
/// The single-flow chart answers "what did one sender do"; this one answers
/// "how was the path shared", so every flow's congestion window goes into one
/// panel with a colour of its own, and the queue they all share goes into the
/// panel below. The delivered totals in the legend are read from the report in
/// the same document, which makes "the chart and the table agree" a property
/// rather than a hope. Every coordinate is integer arithmetic, so the same
/// trace produces the same bytes on any backend.
pub fn fairness_trace_svg_from_json(
  trace_json : String,
) -> Result[String, String] {
  let document = match @json.parse(trace_json) {
    Ok(value) => value
    Err(message) => return Err("trace is not valid JSON: " + message)
  }
  let report = match document.field("report") {
    Some(value) => value
    None => return Err("trace has no report")
  }
  let flows = match report.field("flows") {
    Some(value) =>
      match value.as_list() {
        Some(list) => list
        None => return Err("report.flows is not a list")
      }
    None => return Err("report has no flows")
  }
  let events = match document.field("events") {
    Some(value) =>
      match value.as_list() {
        Some(list) => list
        None => return Err("trace events are not a list")
      }
    None => return Err("trace has no events")
  }
  let scenario = json_text_field(report, "scenario")
  let seed = json_int_field(report, "seed")
  let jain = json_number_text(report, "jain_index", 6)
  let total = json_int_field(report, "total_delivered_bytes")
  let window_ms = match report.field("window_ms") {
    Some(value) =>
      match value.as_number() {
        Some(number) => number
        None => 0.0
      }
    None => 0.0
  }
  let lines : Array[FairnessLine] = []
  let mut index = 0
  while index < flows.length() {
    let flow = flows[index]
    lines.push({
      label: "flow " +
      json_int_field(flow, "flow").to_string() +
      "  " +
      json_text_field(flow, "algorithm"),
      color: fairness_color(index),
      delivered: json_int_field(flow, "delivered_bytes"),
      share: json_number_text(flow, "share_percent", 4),
      samples: [],
    })
    index = index + 1
  }
  let uplink : Array[(Int64, Int)] = []
  let downlink : Array[(Int64, Int)] = []
  let mut max_time = 1L
  for event in events {
    let text = match event.as_text() {
      Some(value) => value
      None => continue
    }
    let parts = split_trace_fields(text, "|")
    if parts.length() < 3 {
      continue
    }
    let time = match trace_chart_integer(parts[1]) {
      Ok(value) => value
      Err(_) => continue
    }
    if time > max_time {
      max_time = time
    }
    if parts[2] == "queue" && parts.length() > 4 {
      // A queue event names the link it belongs to and how many packets are
      // waiting in it. Both queues belong to every flow: that is the point of
      // drawing them here rather than per flow.
      let packets = match event_integer(parts, "packets") {
        Some(value) => value
        None => 0
      }
      if parts[3] == "up" {
        uplink.push((time, packets))
      } else if parts[3] == "down" {
        downlink.push((time, packets))
      }
    } else if parts[2] != "queue" {
      let flow = match event_integer(parts, "flow") {
        Some(value) => value
        None => continue
      }
      let cwnd = match event_integer(parts, "cwnd") {
        Some(value) => value
        None => continue
      }
      // Trace flow ids are one-based (zero marks a single connection that has
      // no identity); the report numbers its flows from zero.
      let position = flow - 1
      if position >= 0 && position < lines.length() {
        lines[position].samples.push((time, cwnd))
      }
    }
  }
  let mut cwnd_max = 1
  for line in lines {
    for sample in line.samples {
      let (_, value) = sample
      if value > cwnd_max {
        cwnd_max = value
      }
    }
  }
  let mut queue_max = 1
  for sample in uplink {
    let (_, value) = sample
    if value > queue_max {
      queue_max = value
    }
  }
  for sample in downlink {
    let (_, value) = sample
    if value > queue_max {
      queue_max = value
    }
  }
  let left = 92
  let width = 1058
  let svg : Array[String] = []
  svg.push(
    "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"1200\" height=\"620\" viewBox=\"0 0 1200 620\" font-family=\"monospace\" font-size=\"12\">",
  )
  svg.push("<rect width=\"1200\" height=\"620\" fill=\"#ffffff\"/>")
  svg.push(
    "<text x=\"92\" y=\"26\" font-size=\"14\">" +
    svg_xml_escape(scenario) +
    " — " +
    lines.length().to_string() +
    " flows sharing one path, seed " +
    seed.to_string() +
    "</text>",
  )
  svg.push(
    "<text x=\"92\" y=\"44\">window " +
    format_fixed(window_ms / 1000.0, 3) +
    "s, delivered " +
    total.to_string() +
    " bytes, Jain " +
    svg_xml_escape(jain) +
    "</text>",
  )
  // One legend entry per flow, carrying the delivered total the report states.
  let mut legend_x = 92
  for line in lines {
    svg.push(
      "<line x1=\"" +
      legend_x.to_string() +
      "\" y1=\"66\" x2=\"" +
      (legend_x + 22).to_string() +
      "\" y2=\"66\" stroke=\"" +
      line.color +
      "\" stroke-width=\"2\"/>",
    )
    svg.push(
      "<text x=\"" +
      (legend_x + 28).to_string() +
      "\" y=\"70\">" +
      svg_xml_escape(line.label) +
      " · " +
      line.delivered.to_string() +
      " B · " +
      svg_xml_escape(line.share) +
      "%</text>",
    )
    legend_x = legend_x + 300
  }
  svg.push(
    "<text x=\"92\" y=\"104\">congestion window (bytes), 0 to " +
    cwnd_max.to_string() +
    ", one line per flow</text>",
  )
  svg.push(
    "<rect x=\"" +
    left.to_string() +
    "\" y=\"116\" width=\"" +
    width.to_string() +
    "\" height=\"220\" fill=\"#fafafa\" stroke=\"#dddddd\"/>",
  )
  for line in lines {
    svg.push(
      fairness_polyline(
        line.samples,
        max_time,
        left,
        width,
        116,
        220,
        cwnd_max,
        line.color,
      ),
    )
  }
  svg.push(
    "<text x=\"" +
    (left - 8).to_string() +
    "\" y=\"124\" text-anchor=\"end\">" +
    cwnd_max.to_string() +
    "</text>",
  )
  svg.push(
    "<text x=\"" +
    (left - 8).to_string() +
    "\" y=\"340\" text-anchor=\"end\">0</text>",
  )
  svg.push(
    "<text x=\"92\" y=\"372\">packets waiting in the shared queues, 0 to " +
    queue_max.to_string() +
    "</text>",
  )
  svg.push(
    "<rect x=\"" +
    left.to_string() +
    "\" y=\"384\" width=\"" +
    width.to_string() +
    "\" height=\"180\" fill=\"#fafafa\" stroke=\"#dddddd\"/>",
  )
  svg.push(
    fairness_polyline(
      uplink, max_time, left, width, 384, 180, queue_max, "#1f77b4",
    ),
  )
  svg.push(
    fairness_polyline(
      downlink, max_time, left, width, 384, 180, queue_max, "#d62728",
    ),
  )
  svg.push(
    "<text x=\"" +
    (left - 8).to_string() +
    "\" y=\"392\" text-anchor=\"end\">" +
    queue_max.to_string() +
    "</text>",
  )
  svg.push(
    "<text x=\"" +
    (left - 8).to_string() +
    "\" y=\"568\" text-anchor=\"end\">0</text>",
  )
  svg.push("<text x=\"" + left.to_string() + "\" y=\"584\">0ms</text>")
  svg.push(
    "<text x=\"" +
    (left + width).to_string() +
    "\" y=\"584\" text-anchor=\"end\">" +
    @sim.Time::from_ps(max_time).render() +
    "</text>",
  )
  svg.push(
    "<line x1=\"92\" y1=\"600\" x2=\"114\" y2=\"600\" stroke=\"#1f77b4\" stroke-width=\"2\"/><text x=\"120\" y=\"604\">uplink queue</text>" +
    "<line x1=\"260\" y1=\"600\" x2=\"282\" y2=\"600\" stroke=\"#d62728\" stroke-width=\"2\"/><text x=\"288\" y=\"604\">downlink queue</text>",
  )
  svg.push("</svg>")
  Ok(svg.join("\n"))
}
