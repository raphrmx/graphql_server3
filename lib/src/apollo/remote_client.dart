import 'dart:async';
import 'package:stream_channel/stream_channel.dart';
import 'transport.dart';

/// One connected client, seen as a channel of [OperationMessage]s.
///
/// Wraps the transport so that a [Server] reads and writes messages rather
/// than frames.
class RemoteClient extends StreamChannelMixin<OperationMessage> {
  /// The underlying transport, carrying decoded maps.
  final StreamChannel<Map> channel;
  final StreamChannelController<OperationMessage> _ctrl =
      StreamChannelController();

  /// Wraps a channel that already decodes JSON into maps.
  RemoteClient.withoutJson(this.channel) {
    _ctrl.local.stream
        .map((m) => m.toJson())
        .cast<Map>()
        .forEach(channel.sink.add);
    channel.stream.listen((m) {
      _ctrl.local.sink.add(OperationMessage.fromJson(m));
    });
  }

  /// Wraps a channel of raw strings, decoding JSON on the way through.
  RemoteClient(StreamChannel<String> channel)
    : this.withoutJson(jsonDocument.bind(channel).cast<Map>());
  @override
  StreamSink<OperationMessage> get sink => _ctrl.foreign.sink;

  @override
  Stream<OperationMessage> get stream => _ctrl.foreign.stream;

  /// Closes the transport and stops delivering messages.
  void close() {
    channel.sink.close();
    _ctrl.local.sink.close();
  }
}
