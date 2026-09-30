///|
/// One TCP/queue sample placed on the shared simulation-time axis.
priv struct TraceChartSample {
  time_ps : Int64
  cwnd_bytes : Int64
  inflight_bytes : Int64
  uplink_packets : Int
  downlink_packets : Int
}

///|
/// A recovery event worth marking on the chart.
priv struct TraceChartMarker {
  time_ps : Int64
  event : String
}

///|
/// A delivery stall interval from the trace diagnostics.
priv struct TraceChartStall {
  start_ps : Double
  end_ps : Double
}

///|
/// Render a single-flow `--trace --json` document as a standalone SVG chart.
///
/// The chart contains TCP congestion-window and in-flight-byte series, both
/// directional queue depths, recovery-event markers, and highlighted delivery
/// stalls. The input document is not modified and rendering is deterministic.
pub fn trace_svg_from_json(trace_json : String) -> Result[String, String] {
  let root = match @json.parse(trace_json) {
    Ok(value) => value
    Err(message) => return Err("trace input is not valid JSON, " + message)
  }
  let report = match root.field("report") {
    Some(value) => value
    None => return Err("trace input is missing report")
  }
  let scenario = match report.field("scenario") {
    Some(value) =>
      match value.as_text() {
        Some(text) => text
        None => return Err("trace report.scenario must be text")
      }
    None => return Err("trace input is missing report.scenario")
  }
  let algorithm = match report.field("algorithm") {
    Some(value) =>
      match value.as_text() {
        Some(text) => text
        None => return Err("trace report.algorithm must be text")
      }
    None => return Err("trace input is missing report.algorithm")
  }
  let event_values = match root.field("events") {
    Some(value) =>
      match value.as_list() {
        Some(items) => items
        None => return Err("trace events must be an array")
      }
    None => return Err("trace input is missing events")
  }
  let stalls = match trace_chart_stalls(root) {
    Ok(value) => value
    Err(message) => return Err(message)
  }
  let queue_names : Array[String] = []
  let samples : Array[TraceChartSample] = []
  let markers : Array[TraceChartMarker] = []
  let mut cwnd_bytes = 0L
  let mut inflight_bytes = 0L
  let mut uplink_packets = 0
  let mut downlink_packets = 0
  for index, value in event_values {
    let event = match value.as_text() {
      Some(text) => text
      None => return Err("trace events[" + index.to_string() + "] must be text")
    }
    let fields = split_trace_fields(event, "|")
    if fields.length() >= 3 && fields[0] == "tcp" && fields[2] != "delivery" {
      let time_ps = match trace_chart_integer(fields[1]) {
        Ok(value) => value
        Err(_) =>
          return Err(
            "trace events[" + index.to_string() + "] has an invalid time",
          )
      }
      if time_ps < 0L {
        return Err(
          "trace events[" + index.to_string() + "] has a negative time",
        )
      }
      cwnd_bytes = match trace_chart_event_integer(fields, "cwnd") {
        Ok(value) => value
        Err(_) =>
          return Err(
            "trace events[" + index.to_string() + "] is missing a valid cwnd",
          )
      }
      inflight_bytes = match trace_chart_event_integer(fields, "inflight") {
        Ok(value) => value
        Err(_) =>
          return Err(
            "trace events[" +
            index.to_string() +
            "] is missing valid inflight bytes",
          )
      }
      samples.push({
        time_ps,
        cwnd_bytes,
        inflight_bytes,
        uplink_packets,
        downlink_packets,
      })
      if trace_chart_is_recovery_event(fields[2]) {
        markers.push({ time_ps, event: fields[2], })
      }
    } else if fields.length() >= 6 && fields[0] == "net" && fields[2] == "queue" {
      let time_ps = match trace_chart_integer(fields[1]) {
        Ok(value) => value
        Err(_) =>
          return Err(
            "trace events[" + index.to_string() + "] has an invalid time",
          )
      }
      if time_ps < 0L {
        return Err(
          "trace events[" + index.to_string() + "] has a negative time",
        )
      }
      let slot = trace_chart_queue_slot(queue_names, fields[3])
      if slot < 0 {
        return Err("trace input has more than two queue paths")
      }
      let packets = match trace_chart_event_integer(fields, "packets") {
        Ok(value) => value
        Err(_) =>
          return Err(
            "trace events[" +
            index.to_string() +
            "] is missing a valid packet count",
          )
      }
      if packets < 0L || packets > 2_147_483_647L {
        return Err(
          "trace events[" + index.to_string() + "] has an invalid packet count",
        )
      }
      if slot == 0 {
        uplink_packets = packets.to_int()
      } else {
        downlink_packets = packets.to_int()
      }
      samples.push({
        time_ps,
        cwnd_bytes,
        inflight_bytes,
        uplink_packets,
        downlink_packets,
      })
    }
  }
  if samples.length() == 0 {
    return Err("trace input contains no TCP or queue samples")
  }
  Ok(render_trace_chart(scenario, algorithm, samples, markers, stalls))
}

///|
/// Parse the optional stall list while rejecting a malformed list if present.
fn trace_chart_stalls(
  root : @json.Json,
) -> Result[Array[TraceChartStall], String] {
  let stalls : Array[TraceChartStall] = []
  match root.field("delivery_diagnostics") {
    None => Ok(stalls)
    Some(diagnostics) =>
      match diagnostics.field("stall_intervals") {
        None => Ok(stalls)
        Some(value) =>
          match value.as_list() {
            None =>
              Err("trace delivery_diagnostics.stall_intervals must be an array")
            Some(items) => {
              for index, item in items {
                let start_ps = match trace_chart_json_number(item, "start_ps") {
                  Some(number) => number
                  None =>
                    return Err(
                      "trace stall_intervals[" +
                      index.to_string() +
                      "] is missing start_ps",
                    )
                }
                let end_ps = match trace_chart_json_number(item, "end_ps") {
                  Some(number) => number
                  None =>
                    return Err(
                      "trace stall_intervals[" +
                      index.to_string() +
                      "] is missing end_ps",
                    )
                }
                if start_ps < 0.0 || end_ps < start_ps {
                  return Err(
                    "trace stall_intervals[" +
                    index.to_string() +
                    "] has an invalid range",
                  )
                }
                stalls.push({ start_ps, end_ps, })
              }
              Ok(stalls)
            }
          }
      }
  }
}

///|
fn trace_chart_json_number(value : @json.Json, field : String) -> Double? {
  match value.field(field) {
    Some(item) => item.as_number()
    None => None
  }
}

///|
fn trace_chart_event_integer(
  fields : Array[String],
  key : String,
) -> Result[Int64, String] {
  match trace_field(fields, key) {
    Some(value) => trace_chart_integer(value)
    None => Err("missing field")
  }
}

///|
fn trace_chart_integer(text : String) -> Result[Int64, String] {
  if text.length() == 0 {
    return Err("empty integer")
  }
  let maximum = 9_223_372_036_854_775_807L
  let mut value = 0L
  for character in text {
    let digit = character.to_int() - 48
    if digit < 0 || digit > 9 {
      return Err("not a non-negative integer")
    }
    let digit = digit.to_int64()
    if value > (maximum - digit) / 10L {
      return Err("integer is too large")
    }
    value = value * 10L + digit
  }
  Ok(value)
}

///|
fn trace_chart_queue_slot(names : Array[String], name : String) -> Int {
  for index, previous in names {
    if previous == name {
      return index
    }
  }
  if names.length() < 2 {
    names.push(name)
    names.length() - 1
  } else {
    -1
  }
}

///|
fn trace_chart_is_recovery_event(event : String) -> Bool {
  event == "retransmit" ||
  event == "fast_retransmit" ||
  event == "timeout" ||
  event == "tail_probe"
}

///|
fn render_trace_chart(
  scenario : String,
  algorithm : String,
  samples : Array[TraceChartSample],
  markers : Array[TraceChartMarker],
  stalls : Array[TraceChartStall],
) -> String {
  let mut max_time_ps = 0L
  let mut max_bytes = 1L
  let mut max_queue = 1
  for sample in samples {
    if sample.time_ps > max_time_ps {
      max_time_ps = sample.time_ps
    }
    if sample.cwnd_bytes > max_bytes {
      max_bytes = sample.cwnd_bytes
    }
    if sample.inflight_bytes > max_bytes {
      max_bytes = sample.inflight_bytes
    }
    if sample.uplink_packets > max_queue {
      max_queue = sample.uplink_packets
    }
    if sample.downlink_packets > max_queue {
      max_queue = sample.downlink_packets
    }
  }
  for stall in stalls {
    if stall.end_ps > max_time_ps.to_double() {
      max_time_ps = stall.end_ps.to_int64()
    }
  }
  if max_time_ps <= 0L {
    max_time_ps = 1L
  }
  let width = 1280.0
  let height = 820.0
  let plot_x = 90.0
  let plot_width = 1158.0
  let top_y = 112.0
  let panel_height = 240.0
  let bottom_y = 438.0
  let bytes_scale = max_bytes.to_double()
  let queue_scale = max_queue.to_double()
  let chart_bottom = bottom_y + panel_height
  let out : Array[String] = []
  out.push(
    "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 " +
    width.to_string() +
    " " +
    height.to_string() +
    "\" role=\"img\" aria-labelledby=\"chart-title chart-description\">",
  )
  out.push(
    "<title id=\"chart-title\">" +
    svg_xml_escape(scenario) +
    " TCP trace</title>",
  )
  out.push(
    "<desc id=\"chart-description\">Deterministic packet-level trace for " +
    svg_xml_escape(algorithm) +
    ". TCP bytes and directional queue depth are plotted against simulation time.</desc>",
  )
  out.push(
    "<style>text{font-family:Inter,Segoe UI,sans-serif;fill:#1e293b}" +
    ".background{fill:#f8fafc}.panel{fill:#fff;stroke:#cbd5e1;stroke-width:1}" +
    ".grid{stroke:#e2e8f0;stroke-width:1}.axis{stroke:#64748b;stroke-width:1.2}" +
    ".panel-title{font-size:18px;font-weight:650}.label{font-size:13px;fill:#475569}" +
    ".tick{font-size:12px;fill:#64748b}.series{fill:none;stroke-width:2.5;stroke-linejoin:round;stroke-linecap:round}" +
    ".cwnd{stroke:#2563eb}.inflight{stroke:#0891b2}.uplink{stroke:#d97706}.downlink{stroke:#8b5cf6}" +
    ".stall{fill:#fb923c;fill-opacity:.16}.event{stroke-width:1.4;stroke-dasharray:4 4;opacity:.8}" +
    ".event-timeout{stroke:#dc2626}.event-retransmit{stroke:#ea580c}.event-fast{stroke:#7c3aed}.event-probe{stroke:#0f766e}" +
    ".legend{font-size:13px}.legend-line{stroke-width:3}.event-key{stroke-width:2;stroke-dasharray:4 3}</style>",
  )
  out.push(
    "<rect class=\"background\" width=\"" +
    width.to_string() +
    "\" height=\"" +
    height.to_string() +
    "\"/>",
  )
  out.push(
    "<text x=\"90\" y=\"38\" font-size=\"22\" font-weight=\"700\">" +
    svg_xml_escape(scenario) +
    "</text><text x=\"90\" y=\"64\" class=\"label\">algorithm: " +
    svg_xml_escape(algorithm) +
    "</text>",
  )
  out.push(
    "<rect class=\"panel\" x=\"" +
    plot_x.to_string() +
    "\" y=\"" +
    top_y.to_string() +
    "\" width=\"" +
    plot_width.to_string() +
    "\" height=\"" +
    panel_height.to_string() +
    "\"/><rect class=\"panel\" x=\"" +
    plot_x.to_string() +
    "\" y=\"" +
    bottom_y.to_string() +
    "\" width=\"" +
    plot_width.to_string() +
    "\" height=\"" +
    panel_height.to_string() +
    "\"/>",
  )
  for stall in stalls {
    let x1 = chart_x(stall.start_ps, max_time_ps, plot_x, plot_width)
    let x2 = chart_x(stall.end_ps, max_time_ps, plot_x, plot_width)
    out.push(
      "<rect class=\"stall\" x=\"" +
      x1.to_string() +
      "\" y=\"" +
      top_y.to_string() +
      "\" width=\"" +
      (x2 - x1).max(1.0).to_string() +
      "\" height=\"" +
      (chart_bottom - top_y).to_string() +
      "\"><title>delivery stall</title></rect>",
    )
  }
  append_trace_panel_grid(
    out, "TCP state", "bytes", plot_x, top_y, plot_width, panel_height, max_bytes,
  )
  append_trace_panel_grid(
    out,
    "Queue occupancy",
    "packets",
    plot_x,
    bottom_y,
    plot_width,
    panel_height,
    max_queue.to_int64(),
  )
  for tick in 0..<=4 {
    let fraction = tick.to_double() / 4.0
    let x = plot_x + plot_width * fraction
    let time_ms = max_time_ps.to_double() * fraction / 1_000_000_000.0
    out.push(
      "<line class=\"grid\" x1=\"" +
      x.to_string() +
      "\" y1=\"" +
      top_y.to_string() +
      "\" x2=\"" +
      x.to_string() +
      "\" y2=\"" +
      chart_bottom.to_string() +
      "\"/><text class=\"tick\" text-anchor=\"middle\" x=\"" +
      x.to_string() +
      "\" y=\"710\">" +
      time_ms.to_string() +
      "</text>",
    )
  }
  out.push(
    trace_chart_polyline(
      samples, "cwnd", max_time_ps, plot_x, plot_width, top_y, panel_height, bytes_scale,
    ),
  )
  out.push(
    trace_chart_polyline(
      samples, "inflight", max_time_ps, plot_x, plot_width, top_y, panel_height,
      bytes_scale,
    ),
  )
  out.push(
    trace_chart_polyline(
      samples, "uplink", max_time_ps, plot_x, plot_width, bottom_y, panel_height,
      queue_scale,
    ),
  )
  out.push(
    trace_chart_polyline(
      samples, "downlink", max_time_ps, plot_x, plot_width, bottom_y, panel_height,
      queue_scale,
    ),
  )
  for marker in markers {
    let x = chart_x(marker.time_ps.to_double(), max_time_ps, plot_x, plot_width)
    let class_name = match marker.event {
      "timeout" => "event-timeout"
      "retransmit" => "event-retransmit"
      "fast_retransmit" => "event-fast"
      _ => "event-probe"
    }
    out.push(
      "<line class=\"event " +
      class_name +
      "\" x1=\"" +
      x.to_string() +
      "\" y1=\"" +
      top_y.to_string() +
      "\" x2=\"" +
      x.to_string() +
      "\" y2=\"" +
      chart_bottom.to_string() +
      "\"><title>" +
      svg_xml_escape(marker.event) +
      " at " +
      (marker.time_ps.to_double() / 1_000_000_000.0).to_string() +
      " ms</title></line>",
    )
  }
  out.push(
    "<text class=\"label\" text-anchor=\"middle\" x=\"669\" y=\"738\">Simulation time (ms)</text>",
  )
  append_trace_legend(out)
  out.push("</svg>")
  out.join("\n")
}

///|
fn append_trace_panel_grid(
  out : Array[String],
  title : String,
  unit : String,
  x : Double,
  y : Double,
  width : Double,
  height : Double,
  max_value : Int64,
) -> Unit {
  out.push(
    "<text class=\"panel-title\" x=\"" +
    x.to_string() +
    "\" y=\"" +
    (y - 18.0).to_string() +
    "\">" +
    title +
    "</text>",
  )
  for tick in 0..<=4 {
    let fraction = tick.to_double() / 4.0
    let tick_y = y + height - height * fraction
    let value = max_value * tick.to_int64() / 4L
    out.push(
      "<line class=\"grid\" x1=\"" +
      x.to_string() +
      "\" y1=\"" +
      tick_y.to_string() +
      "\" x2=\"" +
      (x + width).to_string() +
      "\" y2=\"" +
      tick_y.to_string() +
      "\"/><text class=\"tick\" text-anchor=\"end\" x=\"" +
      (x - 10.0).to_string() +
      "\" y=\"" +
      (tick_y + 4.0).to_string() +
      "\">" +
      value.to_string() +
      "</text>",
    )
  }
  out.push(
    "<text class=\"label\" text-anchor=\"middle\" transform=\"rotate(-90 " +
    (x - 58.0).to_string() +
    " " +
    (y + height / 2.0).to_string() +
    ")\" x=\"" +
    (x - 58.0).to_string() +
    "\" y=\"" +
    (y + height / 2.0).to_string() +
    "\">" +
    unit +
    "</text>",
  )
}

///|
fn trace_chart_polyline(
  samples : Array[TraceChartSample],
  series : String,
  max_time_ps : Int64,
  plot_x : Double,
  plot_width : Double,
  plot_y : Double,
  plot_height : Double,
  scale : Double,
) -> String {
  let points : Array[String] = []
  for sample in samples {
    let value = match series {
      "cwnd" => sample.cwnd_bytes.to_double()
      "inflight" => sample.inflight_bytes.to_double()
      "uplink" => sample.uplink_packets.to_double()
      _ => sample.downlink_packets.to_double()
    }
    let x = chart_x(sample.time_ps.to_double(), max_time_ps, plot_x, plot_width)
    let y = plot_y + plot_height - plot_height * value / scale
    points.push(x.to_string() + "," + y.to_string())
  }
  "<polyline class=\"series " +
  series +
  "\" points=\"" +
  points.join(" ") +
  "\"/>"
}

///|
fn chart_x(
  time_ps : Double,
  max_time_ps : Int64,
  plot_x : Double,
  plot_width : Double,
) -> Double {
  plot_x + plot_width * time_ps / max_time_ps.to_double()
}

///|
fn append_trace_legend(out : Array[String]) -> Unit {
  out.push(
    "<line class=\"legend-line cwnd\" x1=\"92\" y1=\"778\" x2=\"116\" y2=\"778\"/><text class=\"legend\" x=\"122\" y=\"783\">cwnd</text>" +
    "<line class=\"legend-line inflight\" x1=\"205\" y1=\"778\" x2=\"229\" y2=\"778\"/><text class=\"legend\" x=\"235\" y=\"783\">inflight</text>" +
    "<line class=\"legend-line uplink\" x1=\"330\" y1=\"778\" x2=\"354\" y2=\"778\"/><text class=\"legend\" x=\"360\" y=\"783\">uplink queue</text>" +
    "<line class=\"legend-line downlink\" x1=\"490\" y1=\"778\" x2=\"514\" y2=\"778\"/><text class=\"legend\" x=\"520\" y=\"783\">downlink queue</text>" +
    "<line class=\"event event-timeout event-key\" x1=\"690\" y1=\"778\" x2=\"714\" y2=\"778\"/><text class=\"legend\" x=\"720\" y=\"783\">timeout</text>" +
    "<line class=\"event event-retransmit event-key\" x1=\"815\" y1=\"778\" x2=\"839\" y2=\"778\"/><text class=\"legend\" x=\"845\" y=\"783\">retransmit</text>" +
    "<line class=\"event event-fast event-key\" x1=\"960\" y1=\"778\" x2=\"984\" y2=\"778\"/><text class=\"legend\" x=\"990\" y=\"783\">fast retransmit</text>" +
    "<line class=\"event event-probe event-key\" x1=\"1140\" y1=\"778\" x2=\"1164\" y2=\"778\"/><text class=\"legend\" x=\"1170\" y=\"783\">tail probe</text>",
  )
  out.push(
    "<rect class=\"stall\" x=\"92\" y=\"798\" width=\"20\" height=\"10\"/><text class=\"legend\" x=\"120\" y=\"808\">delivery stall</text>",
  )
}

///|
fn svg_xml_escape(value : String) -> String {
  let escaped : Array[String] = []
  for character in value {
    match character.to_int() {
      38 => escaped.push("&amp;")
      60 => escaped.push("&lt;")
      62 => escaped.push("&gt;")
      34 => escaped.push("&quot;")
      39 => escaped.push("&apos;")
      _ => escaped.push(character.to_string())
    }
  }
  escaped.join("")
}
