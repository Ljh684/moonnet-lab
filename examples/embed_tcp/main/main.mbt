///|
/// One megabyte over a path that drops one packet in a hundred, for each
/// algorithm the library ships.
///
///     moon run examples/embed_tcp/main
fn main {
  let bytes = 1_000_000
  let loss = 0.01
  println("embedded transfer, " + bytes.to_string() + " bytes at 1% loss")
  for name in ["none", "reno", "cubic"] {
    println(
      @embed_tcp.transfer(@embed_tcp.algorithm(name, 1000), bytes, loss, 9UL).to_line(),
    )
  }
}
