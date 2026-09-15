import 'dart:async';

import 'package:graphql_schema3/graphql_schema3.dart';
import 'package:graphql_server3/subscriptions_transport_ws.dart';
import 'package:stream_channel/stream_channel.dart';
import 'package:test/test.dart';

/// A [Server] whose two decisions are handed in by the test.
class _TestServer extends Server {
  _TestServer(super.client, {required this.handler, this.accept = true});

  /// Answers the result for a `start`, or throws to exercise the error path.
  final FutureOr<GraphQLResult> Function(String query) handler;

  /// What [onConnect] answers.
  final bool accept;

  @override
  FutureOr<bool> onConnect(RemoteClient client, [Map? connectionParams]) =>
      accept;

  @override
  FutureOr<GraphQLResult> onOperation(
    String? id,
    String query, [
    Map<String, dynamic>? variables,
    String? operationName,
  ]) => handler(query);
}

/// One connected client, driven from the far end of the channel.
class _Harness {
  _Harness({
    required FutureOr<GraphQLResult> Function(String query) handler,
    bool accept = true,
  }) {
    final StreamChannelController<Map> controller =
        StreamChannelController<Map>(allowForeignErrors: false);
    _peer = controller.foreign;
    _peer.stream.listen(sent.add);
    server = _TestServer(
      RemoteClient.withoutJson(controller.local),
      handler: handler,
      accept: accept,
    );
  }

  late final StreamChannel<Map> _peer;

  /// The server under test.
  late final _TestServer server;

  /// Every message the server has written, in order.
  final List<Map> sent = <Map>[];

  void send(Map<String, dynamic> message) => _peer.sink.add(message);

  Future<void> init() async {
    send(<String, dynamic>{'type': 'connection_init'});
    await pumpEventQueue();
  }

  Future<void> start(String id, String query) async {
    send(<String, dynamic>{
      'type': 'start',
      'id': id,
      'payload': <String, dynamic>{'query': query},
    });
    await pumpEventQueue();
  }

  List<Map> ofType(String type) =>
      sent.where((Map m) => m['type'] == type).toList();
}

void main() {
  group('handshake', () {
    test('acknowledges a connection it accepts', () async {
      final _Harness harness = _Harness(
        handler: (_) => GraphQLResult(<String, dynamic>{}),
      );

      await harness.init();

      expect(harness.ofType('connection_ack'), hasLength(1));
    });

    test('reports a connection it refuses', () async {
      final _Harness harness = _Harness(
        handler: (_) => GraphQLResult(<String, dynamic>{}),
        accept: false,
      );

      await harness.init();

      expect(harness.ofType('connection_ack'), isEmpty);
      expect(
        harness.ofType('connection_error').single['payload'],
        <String, dynamic>{'message': 'The connection was rejected.'},
      );
    });
  });

  group('operations', () {
    test('answers a plain result, then completes it', () async {
      final _Harness harness = _Harness(
        handler: (_) => GraphQLResult(<String, dynamic>{'user': 'anna'}),
      );

      await harness.init();
      await harness.start('1', '{ user }');

      expect(harness.ofType('data').single['payload'], <String, dynamic>{
        'data': <String, dynamic>{'user': 'anna'},
      });
      expect(harness.ofType('complete').single['id'], '1');
    });

    test('completes an operation that answered errors', () async {
      final _Harness harness = _Harness(
        handler: (_) => GraphQLResult(
          null,
          errors: <GraphQLExceptionError>[GraphQLExceptionError('nope')],
        ),
      );

      await harness.init();
      await harness.start('1', '{ user }');

      expect(harness.ofType('data').single['payload'], isA<Map>());
      expect(harness.ofType('complete').single['id'], '1');
    });
  });

  group('malformed messages', () {
    // Every check below used to throw inside the stream callback, where the
    // future is the stream's to ignore: an unhandled asynchronous error, for
    // one frame a client got wrong.
    test('answers an error for a start with no payload', () async {
      final _Harness harness = _Harness(
        handler: (_) => GraphQLResult(<String, dynamic>{'user': 'anna'}),
      );

      await harness.init();
      harness.send(<String, dynamic>{'type': 'start', 'id': '1'});
      await pumpEventQueue();

      expect(
        harness.ofType('error').single['payload']['message'],
        contains('payload is required'),
      );
    });

    test('keeps serving the connection afterwards', () async {
      final _Harness harness = _Harness(
        handler: (_) => GraphQLResult(<String, dynamic>{'user': 'anna'}),
      );

      await harness.init();
      harness.send(<String, dynamic>{'type': 'start', 'id': '1'});
      await pumpEventQueue();
      await harness.start('2', '{ user }');

      expect(harness.ofType('data').single['id'], '2');
    });

    test('answers an error when the operation itself throws', () async {
      final _Harness harness = _Harness(
        handler: (_) => throw GraphQLException.fromMessage(
          'Cannot query field "nickname" on type "User".',
        ),
      );

      await harness.init();
      await harness.start('1', '{ user { nickname } }');

      final Map error = harness.ofType('error').single;
      expect(error['id'], '1');
      expect(error['payload']['message'], contains('nickname'));
    });
  });

  group('stop', () {
    test('cancels the subscription and completes it', () async {
      final StreamController<Map<String, dynamic>> events =
          StreamController<Map<String, dynamic>>();
      final _Harness harness = _Harness(
        handler: (_) => GraphQLResult(events.stream),
      );

      await harness.init();
      await harness.start('1', 'subscription { ticks }');

      events.add(<String, dynamic>{'ticks': 1});
      await pumpEventQueue();

      harness.send(<String, dynamic>{'type': 'stop', 'id': '1'});
      await pumpEventQueue();

      events.add(<String, dynamic>{'ticks': 2});
      await pumpEventQueue();

      expect(harness.ofType('data'), hasLength(1));
      expect(harness.ofType('complete').single['id'], '1');
      expect(events.hasListener, isFalse);

      await events.close();
    });

    test('lets a stop naming nothing pass', () async {
      final _Harness harness = _Harness(
        handler: (_) => GraphQLResult(<String, dynamic>{'user': 'anna'}),
      );

      await harness.init();
      harness.send(<String, dynamic>{'type': 'stop', 'id': 'unknown'});
      await pumpEventQueue();

      expect(harness.ofType('error'), isEmpty);
    });

    test('ends a subscription whose source closes', () async {
      final StreamController<Map<String, dynamic>> events =
          StreamController<Map<String, dynamic>>();
      final _Harness harness = _Harness(
        handler: (_) => GraphQLResult(events.stream),
      );

      await harness.init();
      await harness.start('1', 'subscription { ticks }');
      await events.close();
      await pumpEventQueue();

      expect(harness.ofType('complete').single['id'], '1');
    });
  });

  group('termination', () {
    test('cancels a running subscription and completes done', () async {
      final StreamController<Map<String, dynamic>> events =
          StreamController<Map<String, dynamic>>();
      final _Harness harness = _Harness(
        handler: (_) => GraphQLResult(events.stream),
      );

      await harness.init();
      await harness.start('1', 'subscription { ticks }');

      harness.send(<String, dynamic>{'type': 'connection_terminate'});
      await pumpEventQueue();

      expect(events.hasListener, isFalse);
      await expectLater(harness.server.done, completes);

      await events.close();
    });
  });
}
