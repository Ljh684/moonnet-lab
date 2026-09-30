///|
/// One unusually long interval between consecutive in-order deliveries.
///
/// The evidence fields are observations made during the interval. They may
/// overlap and do not claim that one event alone caused the stall.
pub(all) struct DeliveryStall {
  start : @sim.Time
  end : @sim.Time
  duration : @sim.Time
  next_delivery_bytes : Int
  path_queue_seen : Bool
  recovery_event_seen : Bool
  sender_window_blocked_seen : Bool
}

///|
/// Summary of inter-delivery gaps longer than max(2 * SRTT, 1 ms).
pub(all) struct DeliveryDiagnostics {
  threshold : @sim.Time
  intervals : Array[DeliveryStall]
  total_duration : @sim.Time
  max_duration : @sim.Time
}

///|
/// Render one delivery stall as JSON.
fn DeliveryStall::to_json_text(self : DeliveryStall) -> String {
  @json.object_of_texts([
    ("start_ps", self.start.ps.to_string()),
    ("end_ps", self.end.ps.to_string()),
    ("duration_ps", self.duration.ps.to_string()),
    ("duration", @json.quote(self.duration.render())),
    ("next_delivery_bytes", self.next_delivery_bytes.to_string()),
    (
      "evidence",
      @json.object_of_texts([
        ("path_queue_seen", self.path_queue_seen.to_string()),
        ("recovery_event_seen", self.recovery_event_seen.to_string()),
        (
          "sender_window_blocked_seen",
          self.sender_window_blocked_seen.to_string(),
        ),
      ]),
    ),
  ])
}

///|
/// Keep unusually long gaps and annotate the signals visible during each one.
fn diagnose_delivery_gaps(
  events : Array[String],
  srtt : @sim.Time,
) -> DeliveryDiagnostics {
  let doubled_srtt = srtt.ps * 2L
  let threshold_ps = if doubled_srtt > 1_000_000_000L {
    doubled_srtt
  } else {
    1_000_000_000L
  }
  diagnose_delivery_stalls(events, @sim.Time::from_ps(threshold_ps))
}

///|
/// Analyze delivery gaps with a supplied threshold. Kept separate so the
/// interval accounting can be tested with small virtual times.
fn diagnose_delivery_stalls(
  events : Array[String],
  threshold : @sim.Time,
) -> DeliveryDiagnostics {
  let threshold_ps = threshold.ps
  let deliveries : Array[(Int64, Int)] = []
  for event in events {
    let fields = split_trace_fields(event, "|")
    if fields.length() >= 4 && fields[0] == "tcp" && fields[2] == "delivery" {
      let bytes = match trace_field(fields, "bytes") {
        Some(value) => decimal_int64(value).to_int()
        None => 0
      }
      deliveries.push((decimal_int64(fields[1]), bytes))
    }
  }

  let queue_names : Array[String] = []
  let queue_counts : Array[Int] = []
  let mut event_index = 0
  let intervals : Array[DeliveryStall] = []
  let mut total_duration_ps = 0L
  let mut max_duration_ps = 0L
  if deliveries.length() >= 2 {
    for delivery_index in 0..<(deliveries.length() - 1) {
      let start_ps = deliveries[delivery_index].0
      let next = deliveries[delivery_index + 1]
      let end_ps = next.0
      let duration_ps = end_ps - start_ps
      let is_stall = duration_ps > threshold_ps
      // Bring queue state forward to the left edge before inspecting the gap.
      while event_index < events.length() {
        let fields = split_trace_fields(events[event_index], "|")
        if fields.length() < 3 {
          event_index = event_index + 1
        } else {
          let event_ps = decimal_int64(fields[1])
          if event_ps >= start_ps {
            break
          }
          if fields[0] == "net" && fields[2] == "queue" && fields.length() >= 6 {
            let packets = match trace_field(fields, "packets") {
              Some(value) => decimal_int64(value).to_int()
              None => 0
            }
            update_queue_count(queue_names, queue_counts, fields[3], packets)
          }
          event_index = event_index + 1
        }
      }
      let mut path_queue_seen = is_stall && queue_is_nonempty(queue_counts)
      let mut recovery_event_seen = false
      let mut sender_window_blocked_seen = false

      // Events are journaled in simulation order. Keep the interval closed on
      // both ends so signals at the delivery timestamp are included.
      while event_index < events.length() {
        let fields = split_trace_fields(events[event_index], "|")
        if fields.length() < 3 {
          event_index = event_index + 1
        } else {
          let event_ps = decimal_int64(fields[1])
          if event_ps > end_ps {
            break
          }
          if fields[0] == "net" && fields[2] == "queue" && fields.length() >= 6 {
            let packets = match trace_field(fields, "packets") {
              Some(value) => decimal_int64(value).to_int()
              None => 0
            }
            update_queue_count(queue_names, queue_counts, fields[3], packets)
            if is_stall && event_ps >= start_ps && packets > 0 {
              path_queue_seen = true
            }
          }
          if is_stall && event_ps >= start_ps && fields[0] == "tcp" {
            if fields[2] == "timeout" ||
              fields[2] == "retransmit" ||
              fields[2] == "fast_retransmit" ||
              fields[2] == "tail_probe" {
              recovery_event_seen = true
            }
            if fields[2] == "send_blocked" {
              sender_window_blocked_seen = true
            }
          }
          if is_stall && event_ps >= start_ps && queue_is_nonempty(queue_counts) {
            path_queue_seen = true
          }
          event_index = event_index + 1
        }
      }

      if is_stall {
        let duration = @sim.Time::from_ps(duration_ps)
        intervals.push({
          start: @sim.Time::from_ps(start_ps),
          end: @sim.Time::from_ps(end_ps),
          duration,
          next_delivery_bytes: next.1,
          path_queue_seen,
          recovery_event_seen,
          sender_window_blocked_seen,
        })
        total_duration_ps = total_duration_ps + duration_ps
        if duration_ps > max_duration_ps {
          max_duration_ps = duration_ps
        }
      }
    }
  }
  {
    threshold,
    intervals,
    total_duration: @sim.Time::from_ps(total_duration_ps),
    max_duration: @sim.Time::from_ps(max_duration_ps),
  }
}

///|
/// Find a key=value field in a pipe-delimited trace event.
fn trace_field(fields : Array[String], key : String) -> String? {
  for field in fields {
    let pair = split_trace_fields(field, "=")
    if pair.length() == 2 && pair[0] == key {
      return Some(pair[1])
    }
  }
  None
}

///|
/// Materialize a split iterator for indexed access to structured trace fields.
fn split_trace_fields(value : String, separator : String) -> Array[String] {
  let fields : Array[String] = []
  for field in value.split(separator) {
    fields.push(field.to_owned())
  }
  fields
}

///|
/// Parse the unsigned decimal integers used by the trace format.
fn decimal_int64(value : String) -> Int64 {
  let mut number = 0L
  for char in value {
    let digit = char.to_int() - 48
    if digit < 0 || digit > 9 {
      return 0L
    }
    number = number * 10L + digit.to_int64()
  }
  number
}

///|
/// Remember the most recent occupancy sample for one traced link.
fn update_queue_count(
  names : Array[String],
  counts : Array[Int],
  name : String,
  packets : Int,
) -> Unit {
  let mut index = 0
  while index < names.length() && names[index] != name {
    index = index + 1
  }
  if index == names.length() {
    names.push(name)
    counts.push(packets)
  } else {
    counts[index] = packets
  }
}

///|
/// Whether any observed link queue has packets waiting.
fn queue_is_nonempty(counts : Array[Int]) -> Bool {
  for count in counts {
    if count > 0 {
      return true
    }
  }
  false
}
