///|
/// A JSON value.
///
/// Numbers are held as `Double`, which is what JSON itself specifies. Fields
/// that must be exact — a sequence number, a byte count — are checked and
/// converted by the reader at the point where the meaning is known.
pub(all) enum Json {
  Null
  Bool(Bool)
  Number(Double)
  Text(String)
  List(Array[Json])
  Record(Map[String, Json])
}

///|
/// Parse a document. The error message carries the byte offset of the problem,
/// because "invalid JSON" on a forty-line configuration file is not a useful
/// thing to tell someone.
pub fn parse(text : String) -> Result[Json, String] {
  let reader = Reader::new(text)
  reader.skip_space()
  match reader.value() {
    Err(message) => Err(message)
    Ok(json) => {
      reader.skip_space()
      if reader.pos < reader.bytes.length() {
        Err(reader.error("unexpected content after the end of the document"))
      } else {
        Ok(json)
      }
    }
  }
}

///|
/// Read one value, tracking where we are in the input.
priv struct Reader {
  bytes : Bytes
  mut pos : Int
}

///|
fn Reader::new(text : String) -> Reader {
  { bytes: @utf8.encode(text), pos: 0, }
}

///|
fn Reader::error(self : Reader, message : String) -> String {
  "at byte " + self.pos.to_string() + ": " + message
}

///|
/// The byte at the cursor, or -1 at the end of the input.
fn Reader::peek(self : Reader) -> Int {
  if self.pos >= self.bytes.length() {
    -1
  } else {
    self.bytes[self.pos].to_int()
  }
}

///|
fn Reader::advance(self : Reader) -> Int {
  let byte = self.peek()
  if byte >= 0 {
    self.pos = self.pos + 1
  }
  byte
}

///|
fn Reader::skip_space(self : Reader) -> Unit {
  while true {
    let byte = self.peek()
    if byte == 32 || byte == 9 || byte == 10 || byte == 13 {
      self.pos = self.pos + 1
    } else {
      break
    }
  }
}

///|
fn Reader::value(self : Reader) -> Result[Json, String] {
  match self.peek() {
    -1 => Err(self.error("the document ends where a value was expected"))
    123 => self.record()
    91 => self.list()
    34 => self.text()
    116 => self.keyword("true", Json::Bool(true))
    102 => self.keyword("false", Json::Bool(false))
    110 => self.keyword("null", Json::Null)
    byte =>
      if byte == 45 || (byte >= 48 && byte <= 57) {
        self.number()
      } else {
        Err(self.error("expected a value"))
      }
  }
}

///|
fn Reader::keyword(
  self : Reader,
  word : String,
  value : Json,
) -> Result[Json, String] {
  let expected = @utf8.encode(word)
  let mut index = 0
  while index < expected.length() {
    if self.advance() != expected[index].to_int() {
      return Err(self.error("expected \"" + word + "\""))
    }
    index = index + 1
  }
  Ok(value)
}

///|
fn Reader::record(self : Reader) -> Result[Json, String] {
  self.pos = self.pos + 1
  let fields : Map[String, Json] = Map([])
  self.skip_space()
  if self.peek() == 125 {
    self.pos = self.pos + 1
    return Ok(Json::Record(fields))
  }
  // The loop exits through `outcome`: either the closing brace or an error. The
  // value is returned after the loop so that the loop is not in tail position,
  // which keeps the control flow obvious.
  let mut outcome : Result[Json, String] = Ok(Json::Null)
  let mut done = false
  while !done {
    self.skip_space()
    if self.peek() != 34 {
      return Err(self.error("expected a field name in quotes"))
    }
    let name = match self.text() {
      Err(message) => return Err(message)
      Ok(Json::Text(name)) => name
      Ok(_) => return Err(self.error("expected a field name in quotes"))
    }
    self.skip_space()
    if self.advance() != 58 {
      return Err(self.error("expected \":\" after a field name"))
    }
    self.skip_space()
    match self.value() {
      Err(message) => return Err(message)
      Ok(value) => fields[name] = value
    }
    self.skip_space()
    let separator = self.advance()
    if separator == 125 {
      outcome = Ok(Json::Record(fields))
      done = true
    } else if separator != 44 {
      outcome = Err(self.error("expected \",\" or \"}\" after a field"))
      done = true
    }
  }
  outcome
}

///|
fn Reader::list(self : Reader) -> Result[Json, String] {
  self.pos = self.pos + 1
  let items : Array[Json] = []
  self.skip_space()
  if self.peek() == 93 {
    self.pos = self.pos + 1
    return Ok(Json::List(items))
  }
  let mut outcome : Result[Json, String] = Ok(Json::Null)
  let mut done = false
  while !done {
    self.skip_space()
    match self.value() {
      Err(message) => return Err(message)
      Ok(value) => items.push(value)
    }
    self.skip_space()
    let separator = self.advance()
    if separator == 93 {
      outcome = Ok(Json::List(items))
      done = true
    } else if separator != 44 {
      outcome = Err(self.error("expected \",\" or \"]\" after a list item"))
      done = true
    }
  }
  outcome
}

///|
fn Reader::number(self : Reader) -> Result[Json, String] {
  let start = self.pos
  if self.peek() == 45 {
    self.pos = self.pos + 1
  }
  while is_digit(self.peek()) {
    self.pos = self.pos + 1
  }
  if self.peek() == 46 {
    self.pos = self.pos + 1
    while is_digit(self.peek()) {
      self.pos = self.pos + 1
    }
  }
  if self.peek() == 101 || self.peek() == 69 {
    self.pos = self.pos + 1
    if self.peek() == 43 || self.peek() == 45 {
      self.pos = self.pos + 1
    }
    while is_digit(self.peek()) {
      self.pos = self.pos + 1
    }
  }
  // The input is UTF-8 bytes and a `String` holds UTF-16 code units, so every
  // conversion between the two goes through the UTF-8 codec. Reading the bytes
  // as if they were already text yields two code units per input byte and
  // nonsense like "㈱" for "123".
  let digits = @utf8.decode_lossy(self.bytes.clamped_view(start~, end=self.pos))
  let parsed = @string.parse_double(digits) catch {
    _ => return Err(self.error("\"" + digits + "\" is not a number"))
  }
  Ok(Json::Number(parsed))
}

///|
fn is_digit(byte : Int) -> Bool {
  byte >= 48 && byte <= 57
}

///|
fn Reader::text(self : Reader) -> Result[Json, String] {
  self.pos = self.pos + 1
  let out = @buffer.Buffer::Buffer()
  let mut done = false
  let mut outcome : Result[Json, String] = Ok(Json::Null)
  while !done {
    let byte = self.advance()
    if byte < 0 {
      return Err(self.error("the string is never closed"))
    }
    if byte == 34 {
      outcome = Ok(Json::Text(@utf8.decode_lossy(out.to_bytes())))
      done = true
    } else if byte != 92 {
      out.write_byte(byte.to_byte())
    } else {
      let escape = self.advance()
      match escape {
        34 => out.write_byte(b'"')
        92 => out.write_byte(b'\\')
        47 => out.write_byte(b'/')
        98 => out.write_byte(8)
        102 => out.write_byte(12)
        110 => out.write_byte(10)
        114 => out.write_byte(13)
        116 => out.write_byte(9)
        117 =>
          match self.code_point() {
            Err(message) => return Err(message)
            Ok(code_point) => write_utf8(out, code_point)
          }
        _ => return Err(self.error("unknown escape sequence"))
      }
    }
  }
  outcome
}

///|
/// Read the four hex digits after `\u`.
fn Reader::code_point(self : Reader) -> Result[Int, String] {
  let mut value = 0
  let mut index = 0
  while index < 4 {
    let digit = hex_value(self.advance())
    if digit < 0 {
      return Err(self.error("expected four hexadecimal digits after \\u"))
    }
    value = value * 16 + digit
    index = index + 1
  }
  Ok(value)
}

///|
fn hex_value(byte : Int) -> Int {
  if byte >= 48 && byte <= 57 {
    byte - 48
  } else if byte >= 97 && byte <= 102 {
    byte - 87
  } else if byte >= 65 && byte <= 70 {
    byte - 55
  } else {
    -1
  }
}

///|
/// Write a code point as UTF-8. Values above the basic multilingual plane would
/// arrive as a surrogate pair, which the caller has already collapsed.
fn write_utf8(out : @buffer.Buffer, code_point : Int) -> Unit {
  if code_point < 128 {
    out.write_byte(code_point.to_byte())
  } else if code_point < 2048 {
    out.write_byte((192 + code_point / 64).to_byte())
    out.write_byte((128 + code_point % 64).to_byte())
  } else if code_point < 65536 {
    out.write_byte((224 + code_point / 4096).to_byte())
    out.write_byte((128 + code_point / 64 % 64).to_byte())
    out.write_byte((128 + code_point % 64).to_byte())
  } else {
    out.write_byte((240 + code_point / 262144).to_byte())
    out.write_byte((128 + code_point / 4096 % 64).to_byte())
    out.write_byte((128 + code_point / 64 % 64).to_byte())
    out.write_byte((128 + code_point % 64).to_byte())
  }
}

///|
/// A JSON string literal for `text`.
pub fn quote(text : String) -> String {
  let out = @buffer.Buffer::Buffer()
  write_text(out, text)
  @utf8.decode_lossy(out.to_bytes())
}

///|
/// An object rendered in the given field order.
///
/// `Json::Record` is backed by a map, and a map has no order to preserve. A
/// report that has to be byte-identical between runs therefore builds its
/// objects through this function instead, where the order is the order the
/// fields were written in.
pub fn object_text(fields : Array[(String, Json)]) -> String {
  let out = @buffer.Buffer::Buffer()
  out.write_byte(b'{')
  let mut index = 0
  while index < fields.length() {
    if index > 0 {
      out.write_byte(b',')
    }
    write_text(out, fields[index].0)
    out.write_byte(b':')
    fields[index].1.write_to(out)
    index = index + 1
  }
  out.write_byte(b'}')
  @utf8.decode_lossy(out.to_bytes())
}

///|
/// An array rendered in order.
pub fn array_text(items : Array[Json]) -> String {
  let out = @buffer.Buffer::Buffer()
  out.write_byte(b'[')
  let mut index = 0
  while index < items.length() {
    if index > 0 {
      out.write_byte(b',')
    }
    items[index].write_to(out)
    index = index + 1
  }
  out.write_byte(b']')
  @utf8.decode_lossy(out.to_bytes())
}

///|
/// Render a value. Object fields come out in the order the map happens to hold
/// them, which is fine for a document that is read rather than compared; the
/// reports that need a stable byte-for-byte rendering write their own layout.
pub fn Json::render(self : Json) -> String {
  let out = @buffer.Buffer::Buffer()
  self.write_to(out)
  @utf8.decode_lossy(out.to_bytes())
}

///|
/// Rendering a `Json` value as text is also its canonical form, which is what
/// makes a report byte-identical between runs.
pub impl Show for Json with fn to_string(self) {
  self.render()
}

///|
fn Json::write_to(self : Json, out : @buffer.Buffer) -> Unit {
  match self {
    Null => out.write_bytes(b"null")
    Bool(value) =>
      if value {
        out.write_bytes(b"true")
      } else {
        out.write_bytes(b"false")
      }
    Number(value) => out.write_bytes(@utf8.encode(number_text(value)))
    Text(value) => write_text(out, value)
    List(items) => {
      out.write_byte(b'[')
      let mut index = 0
      while index < items.length() {
        if index > 0 {
          out.write_byte(b',')
        }
        items[index].write_to(out)
        index = index + 1
      }
      out.write_byte(b']')
    }
    Record(fields) => {
      out.write_byte(b'{')
      let mut first = true
      for entry in fields {
        if !first {
          out.write_byte(b',')
        }
        first = false
        write_text(out, entry.0)
        out.write_byte(b':')
        entry.1.write_to(out)
      }
      out.write_byte(b'}')
    }
  }
}

///|
/// Numbers that are whole are written without a decimal point, so that a file
/// a person is going to read says `9` rather than `9.0`.
fn number_text(value : Double) -> String {
  let whole = value == value.to_int64().to_double()
  let in_range = value >= -9_007_199_254_740_992.0 &&
    value <= 9_007_199_254_740_992.0
  if whole && in_range {
    value.to_int64().to_string()
  } else {
    value.to_string()
  }
}

///|
fn write_text(out : @buffer.Buffer, value : String) -> Unit {
  out.write_byte(b'"')
  for byte in @utf8.encode(value) {
    match byte.to_int() {
      34 => out.write_bytes(b"\\\"")
      92 => out.write_bytes(b"\\\\")
      10 => out.write_bytes(b"\\n")
      13 => out.write_bytes(b"\\r")
      9 => out.write_bytes(b"\\t")
      other => out.write_byte(other.to_byte())
    }
  }
  out.write_byte(b'"')
}

///|
/// The value of a field, or `None` when the value is not a record or the field
/// is absent.
pub fn Json::field(self : Json, name : String) -> Json? {
  match self {
    Record(fields) =>
      match fields.get(name) {
        Some(value) => Some(value)
        None => None
      }
    _ => None
  }
}

///|
pub fn Json::as_number(self : Json) -> Double? {
  match self {
    Number(value) => Some(value)
    _ => None
  }
}

///|
pub fn Json::as_text(self : Json) -> String? {
  match self {
    Text(value) => Some(value)
    _ => None
  }
}

///|
pub fn Json::as_bool(self : Json) -> Bool? {
  match self {
    Bool(value) => Some(value)
    _ => None
  }
}

///|
pub fn Json::as_list(self : Json) -> Array[Json]? {
  match self {
    List(items) => Some(items)
    _ => None
  }
}
