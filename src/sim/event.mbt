///|
/// One unit of scheduled work.
///
/// An event carries a human readable `tag` next to the closure so that a trace
/// of a run can be read (and diffed) without a debugger.
pub(all) struct Scheduled {
  time : Time
  seq : Int
  tag : String
  action : () -> Unit
}

///|
/// Ordering key of the event heap: earlier time first, and for two events at the
/// same instant the one scheduled first runs first.
///
/// This one rule is what makes the whole simulator reproducible. Without the
/// `seq` tie-break, two events scheduled for the same picosecond would run in
/// whatever order the heap implementation happened to produce.
fn earlier(a : Scheduled, b : Scheduled) -> Bool {
  if a.time.ps != b.time.ps {
    a.time.ps < b.time.ps
  } else {
    a.seq < b.seq
  }
}

///|
/// Push onto a binary min-heap.
fn heap_push(heap : Array[Scheduled], item : Scheduled) -> Unit {
  heap.push(item)
  let mut index = heap.length() - 1
  while index > 0 {
    let parent = (index - 1) / 2
    if earlier(heap[index], heap[parent]) {
      heap.swap(index, parent)
      index = parent
    } else {
      break
    }
  }
}

///|
/// The earliest event without removing it.
fn heap_peek(heap : Array[Scheduled]) -> Scheduled? {
  if heap.length() == 0 {
    None
  } else {
    Some(heap[0])
  }
}

///|
/// Remove and return the earliest event.
fn heap_pop(heap : Array[Scheduled]) -> Scheduled? {
  let size = heap.length()
  if size == 0 {
    return None
  }
  let top = heap[0]
  let last = heap[size - 1]
  heap.truncate(size - 1)
  if size > 1 {
    heap[0] = last
    heap_sift_down(heap, 0)
  }
  Some(top)
}

///|
/// Restore the heap property below `start`.
fn heap_sift_down(heap : Array[Scheduled], start : Int) -> Unit {
  let size = heap.length()
  let mut index = start
  while true {
    let left = index * 2 + 1
    if left >= size {
      break
    }
    let right = left + 1
    let mut smallest = left
    if right < size && earlier(heap[right], heap[left]) {
      smallest = right
    }
    if earlier(heap[smallest], heap[index]) {
      heap.swap(index, smallest)
      index = smallest
    } else {
      break
    }
  }
}

///|
/// The deterministic simulation core.
///
/// A simulation is a pure function of its scenario and its seed. `Sim` owns
/// virtual time, the event queue and the random source; nothing reads the wall
/// clock and nothing depends on hash iteration order, so two runs of the same
/// configuration produce byte-identical journals and metrics.
pub(all) struct Sim {
  mut now : Time
  mut seq : Int
  mut processed : Int
  mut recording : Bool
  heap : Array[Scheduled]
  rng : Rng
  journal : Array[String]
}

///|
/// Create a simulator whose randomness is derived from `seed`.
pub fn Sim::new(seed : UInt64) -> Sim {
  {
    now: Time::zero(),
    seq: 0,
    processed: 0,
    recording: false,
    heap: [],
    rng: Rng::new(seed),
    journal: [],
  }
}

///|
/// The current virtual time.
pub fn Sim::now(self : Sim) -> Time {
  self.now
}

///|
/// The deterministic random source of this run.
pub fn Sim::rng(self : Sim) -> Rng {
  self.rng
}

///|
/// How many events are waiting.
pub fn Sim::pending(self : Sim) -> Int {
  self.heap.length()
}

///|
/// How many events have run so far.
pub fn Sim::processed(self : Sim) -> Int {
  self.processed
}

///|
/// Turn on the event journal. Journalling costs memory, so a long run keeps it
/// off unless the caller asks for a trace to inspect or to diff.
pub fn Sim::start_journal(self : Sim) -> Unit {
  self.recording = true
}

///|
/// Append a line to the journal, if journalling is on.
pub fn Sim::note(self : Sim, message : String) -> Unit {
  if self.recording {
    self.journal.push(message)
  }
}

///|
/// The journal collected so far.
pub fn Sim::journal(self : Sim) -> Array[String] {
  self.journal.copy()
}

///|
/// Schedule `action` to run `delay` from now.
pub fn Sim::after(
  self : Sim,
  delay : Time,
  tag : String,
  action : () -> Unit,
) -> Unit {
  self.schedule_at(self.now + delay, tag, action)
}

///|
/// Schedule `action` at an absolute virtual time.
pub fn Sim::at(
  self : Sim,
  time : Time,
  tag : String,
  action : () -> Unit,
) -> Unit {
  self.schedule_at(time, tag, action)
}

///|
/// The single scheduling entry point.
///
/// Scheduling into the past is a bug in the model, not a recoverable condition,
/// so it aborts loudly with the offending tag instead of silently producing a
/// result that looks plausible but cannot happen on a real wire.
pub fn Sim::schedule_at(
  self : Sim,
  time : Time,
  tag : String,
  action : () -> Unit,
) -> Unit {
  if time.ps < self.now.ps {
    abort(
      "event \"" +
      tag +
      "\" scheduled at " +
      time.render() +
      " is in the past; now is " +
      self.now.render(),
    )
  }
  heap_push(self.heap, { time, seq: self.seq, tag, action, })
  self.seq = self.seq + 1
}

///|
/// Run the earliest event. Returns `false` when the queue is empty.
pub fn Sim::step(self : Sim) -> Bool {
  match heap_pop(self.heap) {
    None => false
    Some(event) => {
      self.now = event.time
      self.processed = self.processed + 1
      if self.recording {
        self.journal.push(event.time.render() + "  " + event.tag)
      }
      (event.action)()
      true
    }
  }
}

///|
/// Run every event up to `deadline`, leaving later events queued, and advance
/// the clock to `deadline` so that a run of an empty period still moves time
/// forward the way a real experiment would.
pub fn Sim::run_until(self : Sim, deadline : Time) -> Unit {
  while true {
    match heap_peek(self.heap) {
      None => break
      Some(next) => if next.time.ps > deadline.ps { break }
    }
    self.step() |> ignore
  }
  if deadline.ps > self.now.ps {
    self.now = deadline
  }
}

///|
/// Run for `duration` of virtual time starting now.
pub fn Sim::run_for(self : Sim, duration : Time) -> Unit {
  self.run_until(self.now + duration)
}

///|
/// Drain the queue.
///
/// `max_events` is a safety valve: a model bug that schedules events from inside
/// an event handler could otherwise spin forever, and a hung experiment is worse
/// than a loud failure.
pub fn Sim::run(self : Sim, max_events? : Int = 1_000_000) -> Unit {
  let mut count = 0
  while count < max_events {
    if !self.step() {
      break
    }
    count = count + 1
  }
}
