// `GraphQLResult` used to live here. It moved when the graphql-ws server
// arrived, because both transports answer with it; it is still exported
// from `subscriptions_transport_ws.dart`, so nothing moved for a consumer.
export '../graphql_result.dart';

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

  /// The same message types under their earlier names.
  ///
  /// Each holds the constant it is named after, character for character; the
  /// pair never carried two different values. Kept so that this version breaks
  /// nothing.
  @Deprecated('Use the gql* constant of the same name. Removed in 4.0.0.')
  static const String legacyGqlConnectionInit = gqlConnectionInit,
      legacyGqlConnectionAck = gqlConnectionAck,
      legacyGqlConnectionKeepAlive = gqlConnectionKeepAlive,
      legacyGqlConnectionError = gqlConnectionError,
      legacyGqlStart = gqlStart,
      legacyGqlStop = gqlStop,
      legacyGqlConnectionTerminate = gqlConnectionTerminate,
      legacyGqlData = gqlData,
      legacyGqlError = gqlError,
      legacyGqlComplete = gqlComplete;

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
