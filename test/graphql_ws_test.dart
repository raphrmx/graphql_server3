import 'dart:async';

import 'package:graphql_schema3/graphql_schema3.dart';
import 'package:graphql_server3/graphql_ws.dart';
import 'package:stream_channel/stream_channel.dart';
import 'package:test/test.dart';

/// A [GraphQLWsServer] whose decisions are handed in by the test.
class _TestServer extends GraphQLWsServer {
  _TestServer(
    super.client, {
    required this.handler,
    this.accept = true,
    super.connectionInitWaitTimeout,
  });

  /// Answers the result for a `subscribe`, or throws to exercise the error
  /// path.
  final FutureOr<GraphQLResult> Function(String query) handler;

  /// What [onConnect] answers.
  final bool accept;

  /// Every close the server asked for, in order.
  final List<({int code, String reason})> closes =
      <({int code, String reason})>[];

  @override
  FutureOr<bool> onConnect(GraphQLWsClient client, [Map? connectionParams]) =>
      accept;

  @override
  FutureOr<GraphQLResult> onOperation(
    String id,
    String query, [
    Map<String, dynamic>? variables,
    String? operationName,
  ]) => handler(query);

  @override
  FutureOr<void> onClose(int code, String reason) {
    closes.add((code: code, reason: reason));
    super.onClose(code, reason);
  }
}

/// One connected client, driven from the far end of the channel.
class _Harness {
  _Harness({
    required FutureOr<GraphQLResult> Function(String query) handler,
    bool accept = true,
    Duration? connectionInitWaitTimeout,
  }) {
    final StreamChannelController<Map> controller =
        StreamChannelController<Map>(allowForeignErrors: false);
    _peer = controller.foreign;
    _peer.stream.listen(sent.add);
    server = _TestServer(
      GraphQLWsClient.withoutJson(controller.local),
      handler: handler,
      accept: accept,
      connectionInitWaitTimeout: connectionInitWaitTimeout,
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

  Future<void> subscribe(String id, String query) async {
    send(<String, dynamic>{
      'type': 'subscribe',
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
      expect(harness.server.closes, isEmpty);
    });

    test('closes with 4403 when it refuses', () async {
      final _Harness harness = _Harness(
        handler: (_) => GraphQLResult(<String, dynamic>{}),
        accept: false,
      );

      await harness.init();

      expect(harness.ofType('connection_ack'), isEmpty);
      expect(harness.server.closes.single.code, 4403);
    });

    test('closes with 4429 on a second connection_init', () async {
      final _Harness harness = _Harness(
        handler: (_) => GraphQLResult(<String, dynamic>{}),
      );

      await harness.init();
      await harness.init();

      expect(harness.server.closes.single.code, 4429);
    });

    test('closes with 4401 when an operation arrives first', () async {
      final _Harness harness = _Harness(
        handler: (_) => GraphQLResult(<String, dynamic>{}),
      );

      await harness.subscribe('1', '{ user }');

      expect(harness.server.closes.single.code, 4401);
    });

    test('closes with 4408 when connection_init never comes', () async {
      final _Harness harness = _Harness(
        handler: (_) => GraphQLResult(<String, dynamic>{}),
        connectionInitWaitTimeout: const Duration(milliseconds: 20),
      );

      await Future<void>.delayed(const Duration(milliseconds: 60));

      expect(harness.server.closes.single.code, 4408);
      await expectLater(harness.server.done, completes);
    });
  });

  group('ping', () {
    test('answers a pong carrying the same payload', () async {
      final _Harness harness = _Harness(
        handler: (_) => GraphQLResult(<String, dynamic>{}),
      );

      harness.send(<String, dynamic>{
        'type': 'ping',
        'payload': <String, dynamic>{'n': 1},
      });
      await pumpEventQueue();

      expect(harness.ofType('pong').single['payload'], <String, dynamic>{
        'n': 1,
      });
    });

    test('is answered before the connection is accepted', () async {
      final _Harness harness = _Harness(
        handler: (_) => GraphQLResult(<String, dynamic>{}),
      );

      harness.send(<String, dynamic>{'type': 'ping'});
      await pumpEventQueue();

      expect(harness.ofType('pong'), hasLength(1));
      expect(harness.server.closes, isEmpty);
    });

    test('accepts a pong without answering it', () async {
      final _Harness harness = _Harness(
        handler: (_) => GraphQLResult(<String, dynamic>{}),
      );

      harness.send(<String, dynamic>{'type': 'pong'});
      await pumpEventQueue();

      expect(harness.sent, isEmpty);
      expect(harness.server.closes, isEmpty);
    });
  });

  group('operations', () {
    test('answers next then complete for a plain result', () async {
      final _Harness harness = _Harness(
        handler: (_) => GraphQLResult(<String, dynamic>{'user': 'anna'}),
      );

      await harness.init();
      await harness.subscribe('1', '{ user }');

      expect(harness.ofType('next').single['payload'], <String, dynamic>{
        'data': <String, dynamic>{'user': 'anna'},
      });
      expect(harness.ofType('complete').single['id'], '1');
    });

    test('carries field errors alongside the data in next', () async {
      final _Harness harness = _Harness(
        handler: (_) => GraphQLResult(
          <String, dynamic>{'user': null},
          errors: <GraphQLExceptionError>[GraphQLExceptionError('nope')],
        ),
      );

      await harness.init();
      await harness.subscribe('1', '{ user }');

      final Map payload = harness.ofType('next').single['payload'] as Map;
      expect(payload['data'], <String, dynamic>{'user': null});
      expect(payload['errors'], hasLength(1));
      expect(harness.ofType('complete'), hasLength(1));
    });

    test('answers error, and nothing after, when the request fails', () async {
      final _Harness harness = _Harness(
        handler: (_) => throw GraphQLException(<GraphQLExceptionError>[
          GraphQLExceptionError('Cannot query field "nickname".'),
          GraphQLExceptionError('Unknown fragment "f".'),
        ]),
      );

      await harness.init();
      await harness.subscribe('1', '{ user { nickname } }');

      final Map error = harness.ofType('error').single;
      expect(error['id'], '1');
      // A list, because one request can fail for several reasons at once.
      expect(error['payload'], hasLength(2));
      expect(harness.ofType('complete'), isEmpty);
      expect(harness.ofType('next'), isEmpty);
    });

    test('streams events as next and ends with complete', () async {
      final StreamController<Map<String, dynamic>> events =
          StreamController<Map<String, dynamic>>();
      final _Harness harness = _Harness(
        handler: (_) => GraphQLResult(events.stream),
      );

      await harness.init();
      await harness.subscribe('1', 'subscription { ticks }');

      events.add(<String, dynamic>{'ticks': 1});
      events.add(<String, dynamic>{'ticks': 2});
      await pumpEventQueue();
      await events.close();
      await pumpEventQueue();

      expect(harness.ofType('next'), hasLength(2));
      expect(harness.ofType('complete').single['id'], '1');
    });

    test('closes with 4409 when an id is subscribed twice', () async {
      final StreamController<Map<String, dynamic>> events =
          StreamController<Map<String, dynamic>>();
      final _Harness harness = _Harness(
        handler: (_) => GraphQLResult(events.stream),
      );

      await harness.init();
      await harness.subscribe('1', 'subscription { ticks }');
      await harness.subscribe('1', 'subscription { ticks }');

      expect(harness.server.closes.single.code, 4409);
      expect(harness.server.closes.single.reason, contains('already exists'));

      await events.close();
    });
  });

  group('client complete', () {
    test('cancels the subscription and answers nothing', () async {
      final StreamController<Map<String, dynamic>> events =
          StreamController<Map<String, dynamic>>();
      final _Harness harness = _Harness(
        handler: (_) => GraphQLResult(events.stream),
      );

      await harness.init();
      await harness.subscribe('1', 'subscription { ticks }');

      events.add(<String, dynamic>{'ticks': 1});
      await pumpEventQueue();

      harness.send(<String, dynamic>{'type': 'complete', 'id': '1'});
      await pumpEventQueue();

      events.add(<String, dynamic>{'ticks': 2});
      await pumpEventQueue();

      expect(harness.ofType('next'), hasLength(1));
      // The server's `complete` is reserved for an operation that ended on its
      // own; the client already knows about the one it stopped.
      expect(harness.ofType('complete'), isEmpty);
      expect(events.hasListener, isFalse);

      await events.close();
    });

    test('lets a complete naming nothing pass', () async {
      final _Harness harness = _Harness(
        handler: (_) => GraphQLResult(<String, dynamic>{}),
      );

      await harness.init();
      harness.send(<String, dynamic>{'type': 'complete', 'id': 'unknown'});
      await pumpEventQueue();

      expect(harness.server.closes, isEmpty);
    });

    test('frees the id for a new subscription', () async {
      // One controller per call: a single-subscription stream handed out twice
      // would fail in the test rather than in the server.
      final List<StreamController<Map<String, dynamic>>> opened =
          <StreamController<Map<String, dynamic>>>[];
      final _Harness harness = _Harness(
        handler: (_) {
          final StreamController<Map<String, dynamic>> events =
              StreamController<Map<String, dynamic>>();
          opened.add(events);
          return GraphQLResult(events.stream);
        },
      );

      await harness.init();
      await harness.subscribe('1', 'subscription { ticks }');
      harness.send(<String, dynamic>{'type': 'complete', 'id': '1'});
      await pumpEventQueue();
      await harness.subscribe('1', 'subscription { ticks }');

      expect(harness.server.closes, isEmpty);
      expect(opened, hasLength(2));

      for (final StreamController<Map<String, dynamic>> events in opened) {
        await events.close();
      }
    });
  });

  group('malformed messages', () {
    test('closes with 4400 on an unknown message type', () async {
      final _Harness harness = _Harness(
        handler: (_) => GraphQLResult(<String, dynamic>{}),
      );

      await harness.init();
      harness.send(<String, dynamic>{'type': 'start', 'id': '1'});
      await pumpEventQueue();

      expect(harness.server.closes.single.code, 4400);
      expect(harness.server.closes.single.reason, contains('start'));
    });

    test('closes with 4400 on a subscribe with no payload', () async {
      final _Harness harness = _Harness(
        handler: (_) => GraphQLResult(<String, dynamic>{}),
      );

      await harness.init();
      harness.send(<String, dynamic>{'type': 'subscribe', 'id': '1'});
      await pumpEventQueue();

      expect(harness.server.closes.single.code, 4400);
    });

    test('closes with 4400 on a frame the protocol cannot read', () async {
      final _Harness harness = _Harness(
        handler: (_) => GraphQLResult(<String, dynamic>{}),
      );

      await harness.init();
      harness.send(<String, dynamic>{'id': '1'});
      await pumpEventQueue();

      expect(harness.server.closes.single.code, 4400);
      expect(harness.server.closes.single.reason, contains('type'));
    });

    test('closes once, however many faults follow', () async {
      final _Harness harness = _Harness(
        handler: (_) => GraphQLResult(<String, dynamic>{}),
      );

      await harness.init();
      harness.send(<String, dynamic>{'type': 'nope'});
      harness.send(<String, dynamic>{'type': 'nope'});
      await pumpEventQueue();

      expect(harness.server.closes, hasLength(1));
    });
  });
}
