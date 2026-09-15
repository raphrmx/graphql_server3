import 'dart:async';

import 'package:stream_channel/stream_channel.dart';

export '../graphql_result.dart';

/// One message of the `graphql-transport-ws` protocol.
///
/// The protocol the `graphql-ws` library defines, which is what a current
/// Apollo Client or urql speaks by default. Its vocabulary differs from the
/// older `subscriptions-transport-ws`: an operation starts with [subscribe]
/// rather than `start`, its events arrive as [next] rather than `data`, and a
/// client ends it by sending [complete] rather than `stop`.
class GraphQLWsMessage {
  /// Opens the connection, carrying whatever the client wants to authenticate
  /// with as its payload.
  static const String connectionInit = 'connection_init';

  /// Accepts the connection.
  static const String connectionAck = 'connection_ack';

  /// Asks the other end to answer a [pong]. Either end may send it.
  static const String ping = 'ping';

  /// Answers a [ping], echoing its payload.
  static const String pong = 'pong';

  /// Starts an operation, under an id the connection has not used yet.
  static const String subscribe = 'subscribe';

  /// One result of an operation.
  static const String next = 'next';

  /// Ends an operation that could not be executed, carrying the errors.
  static const String error = 'error';

  /// Ends an operation. From the server it means the operation is over; from
  /// the client it means stop sending.
  static const String complete = 'complete';

  /// The protocol token a WebSocket handshake negotiates for this protocol.
  ///
  /// The server owning the socket is the one that reads
  /// `Sec-WebSocket-Protocol` and decides which of the two servers in this
  /// package to hand the connection to.
  static const String subprotocol = 'graphql-transport-ws';

  /// The message body, whose shape depends on [type].
  final dynamic payload;

  /// The operation this message belongs to, absent on connection-level ones.
  final String? id;

  /// One of the protocol's message types, such as [subscribe].
  final String type;

  /// Builds a message of [type].
  GraphQLWsMessage(this.type, {this.payload, this.id});

  /// Reads a message off the wire.
  ///
  /// Throws [FormatException] for a missing or non-string `type`, and for an
  /// `id` that is not a string. Unlike the older protocol, an id is a string
  /// and nothing else.
  factory GraphQLWsMessage.fromJson(Map map) {
    final type = map['type'];
    final id = map['id'];

    if (type is! String) {
      throw FormatException('"type" is required and must be a string.');
    }
    if (id != null && id is! String) {
      throw FormatException('"id" must be a string.');
    }

    return GraphQLWsMessage(type, id: id as String?, payload: map['payload']);
  }

  /// The wire form of this message, with absent fields left out.
  Map<String, dynamic> toJson() {
    final out = <String, dynamic>{'type': type};
    if (id != null) out['id'] = id;
    if (payload != null) out['payload'] = payload;
    return out;
  }
}

/// The close codes the protocol names.
///
/// A WebSocket host closes with these so that a client can tell a rejected
/// connection from a malformed message. This package does not own the socket,
/// so it hands the code to `GraphQLWsServer.onClose` rather than sending it.
abstract final class GraphQLWsCloseCode {
  /// The server could not read a message, or read one it does not expect.
  static const int badRequest = 4400;

  /// Something arrived before the connection was accepted.
  static const int unauthorized = 4401;

  /// `onConnect` refused the connection.
  static const int forbidden = 4403;

  /// No `connection_init` arrived in time.
  static const int connectionInitialisationTimeout = 4408;

  /// An operation id already in use was subscribed again.
  static const int subscriberAlreadyExists = 4409;

  /// More than one `connection_init` arrived.
  static const int tooManyInitialisationRequests = 4429;

  /// The server broke on a message it had already accepted as well formed.
  static const int internalServerError = 4500;
}

/// One connected client, seen as a channel of [GraphQLWsMessage]s.
///
/// Wraps the transport so that a server reads and writes messages rather than
/// frames.
class GraphQLWsClient extends StreamChannelMixin<GraphQLWsMessage> {
  /// The underlying transport, carrying decoded maps.
  final StreamChannel<Map> channel;
  final StreamChannelController<GraphQLWsMessage> _ctrl =
      StreamChannelController();

  /// Wraps a channel that already decodes JSON into maps.
  GraphQLWsClient.withoutJson(this.channel) {
    _ctrl.local.stream
        .map((m) => m.toJson())
        .cast<Map>()
        .forEach(channel.sink.add);

    channel.stream.listen((m) {
      // A frame the protocol cannot read travels as a stream error rather than
      // as an exception nobody catches, so that the server closes with the
      // code the protocol names instead of losing the connection.
      try {
        _ctrl.local.sink.add(GraphQLWsMessage.fromJson(m));
      } catch (e) {
        _ctrl.local.sink.addError(e);
      }
    });
  }

  /// Wraps a channel of raw strings, decoding JSON on the way through.
  GraphQLWsClient(StreamChannel<String> channel)
    : this.withoutJson(jsonDocument.bind(channel).cast<Map>());

  @override
  StreamSink<GraphQLWsMessage> get sink => _ctrl.foreign.sink;

  @override
  Stream<GraphQLWsMessage> get stream => _ctrl.foreign.stream;

  /// Closes the transport and stops delivering messages.
  void close() {
    channel.sink.close();
    _ctrl.local.sink.close();
  }
}
