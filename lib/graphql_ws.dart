/// An implementation of the `graphql-transport-ws` protocol in Dart.
///
/// The protocol the `graphql-ws` library defines, which is what a current
/// Apollo Client or urql speaks by default. For the older Apollo protocol, see
/// `subscriptions_transport_ws.dart`; the two can be served side by side, and
/// the `Sec-WebSocket-Protocol` header of the handshake says which one a
/// client is asking for.
///
/// See:
/// https://github.com/enisdenjo/graphql-ws/blob/master/PROTOCOL.md
library;

export 'src/graphql_ws/server.dart';
export 'src/graphql_ws/transport.dart';
