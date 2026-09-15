import 'dart:async';
import 'remote_client.dart';
import 'transport.dart';

/// A server speaking Apollo's `subscriptions-transport-ws` protocol.
///
/// Handles the handshake, the keep-alive and the message bookkeeping. Subclass
/// it and answer [onConnect] and [onOperation]; how events reach a subscriber
/// is left to you, and so is the transport, which can be anything
/// `package:stream_channel` can carry.
abstract class Server {
  /// The client this server is talking to.
  final RemoteClient client;

  /// How often to send a keep-alive, or null to send none.
  final Duration? keepAliveInterval;
  final Completer _done = Completer();
  final Map<String, StreamSubscription> _operations = {};
  StreamSubscription<OperationMessage>? _sub;
  bool _init = false;
  Timer? _timer;

  /// Completes when the connection has been closed on either side.
  Future get done => _done.future;

  /// Starts serving [client], sending a keep-alive every
  /// [keepAliveInterval] if one is given.
  Server(this.client, {this.keepAliveInterval}) {
    _sub = client.stream.listen(
      _handle,
      onError: _done.completeError,
      onDone: () => _close(),
    );
  }

  Future<void> _handle(OperationMessage msg) async {
    try {
      if (msg.type == OperationMessage.gqlConnectionInit && !_init) {
        await _connect(msg);
      } else if (_init) {
        if (msg.type == OperationMessage.gqlStart) {
          await _start(msg);
        } else if (msg.type == OperationMessage.gqlStop) {
          await _stop(msg.id);
        } else if (msg.type == OperationMessage.gqlConnectionTerminate) {
          await _sub?.cancel();
          await _close();
        }
      }
    } catch (e) {
      // A message the server cannot read answers an error. Left alone it would
      // be an unhandled asynchronous error, since the callback's future is the
      // stream's to ignore, and one malformed frame would take the connection
      // down rather than the operation it names.
      final id = msg.id;
      if (id == null) {
        _reportError(e.toString());
      } else {
        _reportOperationError(id, e.toString());
      }
    }
  }

  Future<void> _connect(OperationMessage msg) async {
    try {
      Map? connectionParams;
      if (msg.payload is Map) {
        connectionParams = msg.payload as Map?;
      } else if (msg.payload != null) {
        throw FormatException('${msg.type} payload must be a map (object).');
      }

      var connect = await onConnect(client, connectionParams);
      if (!connect) throw false;
      _init = true;
      client.sink.add(OperationMessage(OperationMessage.gqlConnectionAck));

      if (keepAliveInterval != null) {
        client.sink.add(
          OperationMessage(OperationMessage.gqlConnectionKeepAlive),
        );
        _timer ??= Timer.periodic(keepAliveInterval!, (timer) {
          client.sink.add(
            OperationMessage(OperationMessage.gqlConnectionKeepAlive),
          );
        });
      }
    } catch (e) {
      if (e == false) {
        _reportError('The connection was rejected.');
      } else {
        _reportError(e.toString());
      }
    }
  }

  Future<void> _start(OperationMessage msg) async {
    final id = msg.id;

    if (id == null) {
      throw FormatException('${msg.type} id is required.');
    }
    if (msg.payload == null) {
      throw FormatException('${msg.type} payload is required.');
    } else if (msg.payload is! Map) {
      throw FormatException('${msg.type} payload must be a map (object).');
    }

    var payload = msg.payload as Map;
    var query = payload['query'];
    var variables = payload['variables'];
    var operationName = payload['operationName'];

    if (query == null || query is! String) {
      throw FormatException(
        '${msg.type} payload must contain a string named "query".',
      );
    }
    if (variables != null && variables is! Map) {
      throw FormatException(
        '${msg.type} payload\'s "variables" field must be a map (object).',
      );
    }
    if (operationName != null && operationName is! String) {
      throw FormatException(
        '${msg.type} payload\'s "operationName" field must be a string.',
      );
    }

    var result = await onOperation(
      id,
      query,
      (variables as Map?)?.cast<String, dynamic>(),
      operationName as String?,
    );

    if (result.errors.isNotEmpty) {
      client.sink.add(
        OperationMessage(
          OperationMessage.gqlData,
          id: id,
          payload: {'errors': result.errors.toList()},
        ),
      );
      client.sink.add(OperationMessage(OperationMessage.gqlComplete, id: id));
      return;
    }

    var data = _unwrapData(result.data);

    if (data is! Stream) {
      client.sink.add(
        OperationMessage(
          OperationMessage.gqlData,
          id: id,
          payload: {'data': data},
        ),
      );
      client.sink.add(OperationMessage(OperationMessage.gqlComplete, id: id));
      return;
    }

    // Held against the operation id, because that is what a `stop` names. A
    // subscription nothing holds cannot be cancelled, and keeps pushing events
    // until the connection itself goes.
    await _operations.remove(id)?.cancel();
    _operations[id] = data.listen(
      (event) {
        client.sink.add(
          OperationMessage(
            OperationMessage.gqlData,
            id: id,
            payload: {'data': _unwrapData(event)},
          ),
        );
      },
      onError: (Object e) {
        _operations.remove(id);
        _reportOperationError(id, e.toString());
      },
      onDone: () {
        _operations.remove(id);
        client.sink.add(OperationMessage(OperationMessage.gqlComplete, id: id));
      },
    );
  }

  /// Cancels the operation [id] names, and tells the client it is over.
  ///
  /// An id naming nothing is left alone: a `stop` racing an operation that has
  /// just completed is ordinary, not an error.
  Future<void> _stop(String? id) async {
    if (id == null) {
      throw FormatException('${OperationMessage.gqlStop} id is required.');
    }

    var operation = _operations.remove(id);
    if (operation == null) return;

    await operation.cancel();
    client.sink.add(OperationMessage(OperationMessage.gqlComplete, id: id));
  }

  /// Strips a lone `data` wrapper off [value].
  ///
  /// A result shaped like a whole response then answers its payload, rather
  /// than being nested inside a second one.
  dynamic _unwrapData(dynamic value) {
    if (value is Map && value.keys.length == 1 && value.containsKey('data')) {
      return value['data'];
    }
    return value;
  }

  Future<void> _close() async {
    _timer?.cancel();

    for (var operation in _operations.values) {
      await operation.cancel();
    }
    _operations.clear();

    if (!_done.isCompleted) _done.complete();
  }

  void _reportError(String message) {
    client.sink.add(
      OperationMessage(
        OperationMessage.gqlConnectionError,
        payload: {'message': message},
      ),
    );
  }

  void _reportOperationError(String id, String message) {
    client.sink.add(
      OperationMessage(
        OperationMessage.gqlError,
        id: id,
        payload: {'message': message},
      ),
    );
  }

  /// Whether to accept the connection, given the client's
  /// `connection_init` payload.
  ///
  /// Answer false to refuse it; this is where authentication belongs.
  FutureOr<bool> onConnect(RemoteClient client, [Map? connectionParams]);

  /// Executes one operation and answers its result.
  ///
  /// [id] identifies the operation within the connection, so that a
  /// subscription's events can be routed back to it. Throwing from here
  /// answers the client an `error` message naming [id], which is what a
  /// document the schema refuses comes back as.
  FutureOr<GraphQLResult> onOperation(
    String? id,
    String query, [
    Map<String, dynamic>? variables,
    String? operationName,
  ]);
}
