import 'package:graphql_schema3/graphql_schema3.dart';

/// A basic message in the Apollo WebSocket protocol.
class OperationMessage {
  /// Message types a server and a client exchange, as named by the Apollo
  /// `subscriptions-transport-ws` protocol.
  static const String gqlConnectionInit = 'connection_init',
      gqlConnectionAck = 'connection_ack',
      gqlConnectionKeepAlive = 'ka',
      gqlConnectionError = 'connection_error',
      gqlStart = 'start',
      gqlStop = 'stop',
      gqlConnectionTerminate = 'connection_terminate',
      gqlData = 'data',
      gqlError = 'error',
      gqlComplete = 'complete';

  /// The same message types under their earlier names, kept so that an older
  /// client still interoperates.
  static const String legacyGqlConnectionInit = 'connection_init',
      legacyGqlConnectionAck = 'connection_ack',
      legacyGqlConnectionKeepAlive = 'ka',
      legacyGqlConnectionError = 'connection_error',
      legacyGqlStart = 'start',
      legacyGqlStop = 'stop',
      legacyGqlConnectionTerminate = 'connection_terminate',
      legacyGqlData = 'data',
      legacyGqlError = 'error',
      legacyGqlComplete = 'complete';

  // static const String gqlConnectionInit = 'GQL_CONNECTION_INIT',
  //     gqlConnectionAck = 'GQL_CONNECTION_ACK',
  //     gqlConnectionKeepAlive = 'GQL_CONNECTION_KEEP_ALIVE',
  //     gqlConnectionError = 'GQL_CONNECTION_ERROR',
  //     gqlStart = 'GQL_START',
  //     gqlStop = 'GQL_STOP',
  //     gqlConnectionTerminate = 'GQL_CONNECTION_TERMINATE',
  //     gqlData = 'GQL_DATA',
  //     gqlError = 'GQL_ERROR',
  //     gqlComplete = 'GQL_COMPLETE';
  /// The message body, whose shape depends on [type].
  final dynamic payload;

  /// The operation this message belongs to, absent on connection-level ones.
  final String? id;

  /// One of the protocol's message types, such as [gqlStart].
  final String type;

  /// Builds a message of [type].
  OperationMessage(this.type, {this.payload, this.id});

  /// Reads a message off the wire.
  ///
  /// A numeric `id` is accepted and turned into a string. Throws
  /// [ArgumentError] for a missing or non-string `type`, and for an `id` that
  /// is neither a string nor a number.
  factory OperationMessage.fromJson(Map map) {
    var type = map['type'];
    var payload = map['payload'];
    var id = map['id'];

    if (type == null) {
      throw ArgumentError.notNull('type');
    } else if (type is! String) {
      throw ArgumentError.value(type, 'type', 'must be a string');
    } else if (id is num) {
      id = id.toString();
    } else if (id != null && id is! String) {
      throw ArgumentError.value(id, 'id', 'must be a string or number');
    }

    // TODO: This is technically a violation of the spec.
    // https://github.com/apollographql/subscriptions-transport-ws/issues/551
    if (map.containsKey('query') ||
        map.containsKey('operationName') ||
        map.containsKey('variables')) {
      payload = Map.from(map);
    }
    return OperationMessage(type, id: id as String?, payload: payload);
  }

  /// The wire form of this message, with absent fields left out.
  Map<String, dynamic> toJson() {
    var out = <String, dynamic>{'type': type};
    if (id != null) out['id'] = id;
    if (payload != null) out['payload'] = payload;
    return out;
  }
}

/// What a [Server] answers for one operation: the data, and any errors.
class GraphQLResult {
  /// The `data` of the response, null when the operation failed outright.
  final dynamic data;

  /// The errors to report alongside [data], empty when there were none.
  final Iterable<GraphQLExceptionError> errors;

  /// Pairs [data] with the [errors] to report.
  GraphQLResult(this.data, {this.errors = const []});
}
