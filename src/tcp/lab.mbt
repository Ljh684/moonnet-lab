///|
/// Two connections wired through a pair of one-way links.
///
/// The wiring is the interesting part. A connection cannot be handed a link at
/// construction time, because the link needs the *other* connection in its
/// delivery callback, and that connection does not exist yet. Instead each
/// connection starts with a no-op sender and is connected to its link
/// afterwards, which keeps the dependency a straight line rather than a cycle
/// and leaves the wiring visible in one place.
pub(all) struct LinkPair {
  client : TcpConnection
  server : TcpConnection
  up : @net.Link[Segment]
  down : @net.Link[Segment]
}

///|
pub fn LinkPair::new(
  sim : @sim.Sim,
  client_config : TcpConfig,
  server_config : TcpConfig,
  client_to_server : @net.LinkSpec,
  server_to_client : @net.LinkSpec,
  seed : UInt64,
) -> LinkPair {
  let client = TcpConnection::new(client_config)
  let server = TcpConnection::new(server_config)
  let up = @net.Link::new(client_to_server, seed, packet => {
    server.on_segment(sim, packet.payload)
  })
  let down = @net.Link::new(server_to_client, seed, packet => {
    client.on_segment(sim, packet.payload)
  })
  let mut packet_id = 0
  client.set_emit(segment => {
    packet_id = packet_id + 1
    let packet = @net.Packet::new(
      packet_id,
      0,
      @net.Data,
      segment.wire_size(),
      segment,
    )
    up.send(sim, packet) |> ignore
  })
  server.set_emit(segment => {
    packet_id = packet_id + 1
    let packet = @net.Packet::new(
      packet_id,
      0,
      @net.Data,
      segment.wire_size(),
      segment,
    )
    down.send(sim, packet) |> ignore
  })
  { client, server, up, down, }
}

///|
/// Start the handshake from the client side.
pub fn LinkPair::connect(self : LinkPair, sim : @sim.Sim) -> Unit {
  self.server.listen()
  self.client.connect(sim)
}

///|
/// A one-line-per-end summary.
pub fn LinkPair::summary(self : LinkPair) -> String {
  "client " +
  self.client.state().render() +
  " snd_una=" +
  self.client.snd_una().to_string() +
  " rcv_nxt=" +
  self.client.rcv_nxt().to_string() +
  " | server " +
  self.server.state().render() +
  " snd_una=" +
  self.server.snd_una().to_string() +
  " rcv_nxt=" +
  self.server.rcv_nxt().to_string()
}
