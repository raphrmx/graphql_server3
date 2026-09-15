import 'dart:async';

import 'package:graphql_schema3/graphql_schema3.dart';

import 'transport.dart';

/// A server speaking the `graphql-transport-ws` protocol.
///
/// Subclass it and answer [onConnect] and [onOperation], the same two
/// decisions the older `Server` asks for. How events reach a subscriber is
/// left to you, and so is the transport, which can be anything
/// `package:stream_channel` can carry.
///
/// This package does not own the socket, so it cannot close one with a code.
/// Override [onClose] on a WebSocket transport to pass the code on, which is
/// what a client reads to tell a refused connection from a malformed message.
abstract class GraphQLWsServer {
  /// The client this server is talking to.
  final GraphQLWsClient client;

  /// How long to wait for `connection_init` before closing the connection.
  ///
  /// Null waits forever. The protocol names a close code for this, which is
  /// how a client learns it was too slow rather than merely dropped.
  final Duration? connectionInitWaitTimeout;

  final Completer _done = Completer();
  final Map<String, StreamSubscription> _operations = {};
  StreamSubscription<GraphQLWsMessage>? _sub;
  Timer? _initTimer;
  bool _init = false;
  bool _closing = false;

  /// Completes when the connection has been closed on either side.
  Future get done => _done.future;

  /// Starts serving [client].
  GraphQLWsServer(this.client, {this.connectionInitWaitTimeout}) {
    _sub = client.stream.listen(
      _handle,
      // A frame the protocol cannot read arrives here rather than as an
      // exception nobody catches.
      onError: (Object e) =>
          _closeWith(GraphQLWsCloseCode.badRequest, e.toString()),
      onDone: () => _close(),
    );

    final wait = connectionInitWaitTimeout;
    if (wait != null) {
      _initTimer = Timer(wait, () {
        if (!_init) {
          _closeWith(
            GraphQLWsCloseCode.connectionInitialisationTimeout,
            'Connection initialisation timeout',
          );
        }
      });
    }
  }

  Future<void> _handle(GraphQLWsMessage msg) async {
    if (_closing) return;

    try {
      switch (msg.type) {
        case GraphQLWsMessage.connectionInit:
          await _connect(msg);

        case GraphQLWsMessage.ping:
          client.sink.add(
            GraphQLWsMessage(GraphQLWsMessage.pong, payload: msg.payload),
          );

        case GraphQLWsMessage.pong:
          break;

        case GraphQLWsMessage.subscribe:
          await _subscribe(msg);

        case GraphQLWsMessage.complete:
          await _stop(msg.id);

        default:
          await _closeWith(
            GraphQLWsCloseCode.badRequest,
            'Unknown message type: ${msg.type}',
          );
      }
    } catch (e) {
      // Everything the protocol itself refuses is closed above with the code
      // that names it, so reaching here means the server broke on a message it
      // had accepted. The callback's future is the stream's to ignore, so
      // without this the connection would go with no reason on it.
      await _closeWith(GraphQLWsCloseCode.internalServerError, e.toString());
    }
  }

  Future<void> _connect(GraphQLWsMessage msg) async {
    if (_init) {
      await _closeWith(
        GraphQLWsCloseCode.tooManyInitialisationRequests,
        'Too many initialisation requests',
      );
      return;
    }

    Map? connectionParams;
    if (msg.payload is Map) {
      connectionParams = msg.payload as Map?;
    } else if (msg.payload != null) {
      await _closeWith(
        GraphQLWsCloseCode.badRequest,
        'connection_init payload must be a map (object).',
      );
      return;
    }

    final bool accepted;
    try {
      accepted = await onConnect(client, connectionParams);
    } catch (e) {
      await _closeWith(GraphQLWsCloseCode.forbidden, e.toString());
      return;
    }

    if (!accepted) {
      await _closeWith(GraphQLWsCloseCode.forbidden, 'Forbidden');
      return;
    }

    _init = true;
    _initTimer?.cancel();
    client.sink.add(GraphQLWsMessage(GraphQLWsMessage.connectionAck));
  }

  Future<void> _subscribe(GraphQLWsMessage msg) async {
    if (!_init) {
      await _closeWith(GraphQLWsCloseCode.unauthorized, 'Unauthorized');
      return;
    }

    final id = msg.id;
    if (id == null) {
      await _closeWith(
        GraphQLWsCloseCode.badRequest,
        'subscribe id is required.',
      );
      return;
    }

    // An id already in use is a protocol fault, not an operation fault: the
    // connection goes, because the client and the server no longer agree on
    // what that id names.
    if (_operations.containsKey(id)) {
      await _closeWith(
        GraphQLWsCloseCode.subscriberAlreadyExists,
        'Subscriber for $id already exists',
      );
      return;
    }

    final payload = msg.payload;
    if (payload is! Map) {
      await _closeWith(
        GraphQLWsCloseCode.badRequest,
        'subscribe payload must be a map (object).',
      );
      return;
    }

    final query = payload['query'];
    final variables = payload['variables'];
    final operationName = payload['operationName'];

    if (query is! String) {
      await _closeWith(
        GraphQLWsCloseCode.badRequest,
        'subscribe payload must contain a string named "query".',
      );
      return;
    }
    if (variables != null && variables is! Map) {
      await _closeWith(
        GraphQLWsCloseCode.badRequest,
        'subscribe payload\'s "variables" field must be a map (object).',
      );
      return;
    }
    if (operationName != null && operationName is! String) {
      await _closeWith(
        GraphQLWsCloseCode.badRequest,
        'subscribe payload\'s "operationName" field must be a string.',
      );
      return;
    }

    final GraphQLResult result;
    try {
      result = await onOperation(
        id,
        query,
        (variables as Map?)?.cast<String, dynamic>(),
        operationName as String?,
      );
    } catch (e) {
      // The request could not be executed at all, which the protocol reports
      // as `error` rather than as a `next` carrying errors. Nothing follows
      // it: the operation is over.
      _reportOperationError(id, e);
      return;
    }

    var data = _unwrapData(result.data);

    if (data is! Stream) {
      client.sink.add(
        GraphQLWsMessage(
          GraphQLWsMessage.next,
          id: id,
          payload: _executionResult(data, result.errors),
        ),
      );
      client.sink.add(GraphQLWsMessage(GraphQLWsMessage.complete, id: id));
      return;
    }

    // Held against the operation id, because that is what a client's
    // `complete` names. A subscription nothing holds cannot be cancelled.
    _operations[id] = data.listen(
      (event) {
        client.sink.add(
          GraphQLWsMessage(
            GraphQLWsMessage.next,
            id: id,
            payload: _executionResult(_unwrapData(event), const []),
          ),
        );
      },
      onError: (Object e) {
        _operations.remove(id);
        _reportOperationError(id, e);
      },
      onDone: () {
        _operations.remove(id);
        client.sink.add(GraphQLWsMessage(GraphQLWsMessage.complete, id: id));
      },
    );
  }

  /// Stops the operation [id] names, at the client's request.
  ///
  /// Nothing is sent back: the client already knows it is over, and the
  /// protocol reserves the server's `complete` for an operation that ended on
  /// its own. An id naming nothing is left alone, because a `complete` racing
  /// an operation that has just finished is ordinary.
  Future<void> _stop(String? id) async {
    if (id == null) {
      await _closeWith(
        GraphQLWsCloseCode.badRequest,
        'complete id is required.',
      );
      return;
    }

    await _operations.remove(id)?.cancel();
  }

  Map<String, dynamic> _executionResult(dynamic data, Iterable<Object> errors) {
    final out = <String, dynamic>{'data': data};
    if (errors.isNotEmpty) out['errors'] = errors.toList();
    return out;
  }

  void _reportOperationError(String id, Object error) {
    client.sink.add(
      GraphQLWsMessage(
        GraphQLWsMessage.error,
        id: id,
        // The protocol carries a list here, because one request can fail for
        // several reasons at once, which is what validation answers.
        payload: [
          if (error is GraphQLException)
            ...error.errors.map((e) => e.toJson())
          else
            {'message': error.toString()},
        ],
      ),
    );
  }

  /// Strips a lone `data` wrapper off [value].
  dynamic _unwrapData(dynamic value) {
    if (value is Map && value.keys.length == 1 && value.containsKey('data')) {
      return value['data'];
    }
    return value;
  }

  Future<void> _closeWith(int code, String reason) async {
    if (_closing) return;
    _closing = true;

    await _close();
    await onClose(code, reason);
  }

  Future<void> _close() async {
    _initTimer?.cancel();

    for (final operation in _operations.values) {
      await operation.cancel();
    }
    _operations.clear();

    await _sub?.cancel();
    if (!_done.isCompleted) _done.complete();
  }

  /// Closes the connection, naming the protocol's [code] and [reason].
  ///
  /// The default closes the channel and loses the code, because a
  /// [StreamChannel] has nowhere to put it. Override this on a WebSocket
  /// transport and close the socket with [code]: it is how a client tells a
  /// refused connection from a malformed message from a duplicated id.
  FutureOr<void> onClose(int code, String reason) {
    client.close();
  }

  /// Whether to accept the connection, given the client's `connection_init`
  /// payload.
  ///
  /// Answer false, or throw, to refuse it; this is where authentication
  /// belongs. Either way the connection closes with
  /// [GraphQLWsCloseCode.forbidden].
  FutureOr<bool> onConnect(GraphQLWsClient client, [Map? connectionParams]);

  /// Executes one operation and answers its result.
  ///
  /// [id] identifies the operation within the connection, so that a
  /// subscription's events can be routed back to it. Throwing from here
  /// answers the client an `error` message naming [id], which is what a
  /// document the schema refuses comes back as; errors carried by the result
  /// instead travel alongside the data in a `next`.
  FutureOr<GraphQLResult> onOperation(
    String id,
    String query, [
    Map<String, dynamic>? variables,
    String? operationName,
  ]);
}
