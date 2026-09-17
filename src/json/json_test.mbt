///|
/// Parse and hand back the value, failing the test with the parser's message.
fn parsed(text : String) -> @json.Json {
  match @json.parse(text) {
    Ok(value) => value
    Err(message) => abort("expected " + text + " to parse, but " + message)
  }
}

///|
/// The error message from parsing something malformed.
fn parse_error(text : String) -> String {
  match @json.parse(text) {
    Ok(_) => abort("expected " + text + " to be rejected")
    Err(message) => message
  }
}

///|
test "scalars parse" {
  inspect(parsed("null").render(), content="null")
  inspect(parsed("true").render(), content="true")
  inspect(parsed("false").render(), content="false")
  inspect(parsed("42").render(), content="42")
  inspect(parsed("-1.5").render(), content="-1.5")
  inspect(parsed("2.5e3").render(), content="2500")
}

///|
test "records and lists parse" {
  let value = parsed("{\"a\": 1, \"b\": [true, null], \"c\": {\"d\": \"x\"}}")
  inspect(value.field("a").unwrap().as_number().unwrap(), content="1")
  inspect(value.field("b").unwrap().as_list().unwrap().length(), content="2")
  let nested = value.field("c").unwrap().field("d").unwrap().as_text().unwrap()
  inspect(nested, content="x")
  inspect(value.field("missing") is None, content="true")
  inspect(parsed("[]").as_list().unwrap().length(), content="0")
  inspect(parsed("{}").field("anything") is None, content="true")
}

///|
test "whitespace anywhere is allowed" {
  let value = parsed("  {\n  \"a\"\t:\r\n  [ 1 , 2 ]\n  }\n")
  inspect(value.field("a").unwrap().as_list().unwrap().length(), content="2")
}

///|
test "escapes are decoded" {
  inspect(parsed("\"a\\nb\"").as_text().unwrap().length(), content="3")
  inspect(parsed("\"quote: \\\"\"").as_text().unwrap(), content="quote: \"")
  inspect(parsed("\"back\\\\slash\"").as_text().unwrap(), content="back\\slash")
  inspect(parsed("\"tab\\there\"").as_text().unwrap(), content="tab\there")
}

///|
test "unicode escapes and raw utf-8 text agree" {
  // Two escapes for the two characters of "测试", and the same text written
  // directly: both forms must produce the same string.
  inspect(parsed("\"\\u6d4b\\u8bd5\"").as_text().unwrap(), content="测试")
  inspect(parsed("\"测试\"").as_text().unwrap(), content="测试")
}

///|
test "malformed documents are rejected with a location" {
  inspect(parse_error("{\"a\": }").contains("at byte"), content="true")
  inspect(parse_error("[1, 2").contains("at byte"), content="true")
  inspect(parse_error("\"unterminated").contains("at byte"), content="true")
  inspect(parse_error("{\"a\" 1}").contains("at byte"), content="true")
  inspect(parse_error("nul").contains("at byte"), content="true")
  inspect(parse_error("1 2").contains("unexpected content"), content="true")
  inspect(
    parse_error("").contains("ends where a value was expected"),
    content="true",
  )
}

///|
test "writing round trips through the parser" {
  let original = parsed(
    "{\"name\": \"small buffers\", \"seed\": 9, \"loss\": 0.01, \"links\": [1, 2, 3], \"on\": true, \"none\": null}",
  )
  let rewritten = parsed(original.render())
  inspect(
    rewritten.field("name").unwrap().as_text().unwrap(),
    content="small buffers",
  )
  inspect(rewritten.field("seed").unwrap().as_number().unwrap(), content="9")
  inspect(rewritten.field("loss").unwrap().as_number().unwrap(), content="0.01")
  inspect(
    rewritten.field("links").unwrap().as_list().unwrap().length(),
    content="3",
  )
  inspect(rewritten.field("on").unwrap().as_bool().unwrap(), content="true")
  inspect(rewritten.field("none").unwrap().render(), content="null")
}

///|
test "whole numbers are written without a decimal point" {
  inspect(parsed("10000000").render(), content="10000000")
  inspect(parsed("0.5").render(), content="0.5")
  inspect(parsed("-3").render(), content="-3")
}

///|
test "text is escaped on the way out" {
  inspect(parsed("\"a\\nb\"").render(), content="\"a\\nb\"")
  inspect(parsed("\"q\\\"q\"").render(), content="\"q\\\"q\"")
}
