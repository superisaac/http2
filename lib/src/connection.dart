// Copyright (c) 2015, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

library http2.src.conn;

import 'dart:async';
import 'dart:math';
import 'dart:convert';

import '../transport.dart';
import 'flowcontrol/connection_queues.dart';
import 'flowcontrol/window.dart';
import 'flowcontrol/window_handler.dart';
import 'frames/frame_defragmenter.dart';
import 'frames/frames.dart';
import 'hpack/hpack.dart';
import 'ping/ping_handler.dart';
import 'settings/settings.dart';
import 'streams/stream_handler.dart';
import 'sync_errors.dart';

import 'connection_preface.dart';

enum ConnectionState {
  /// The connection has been established, we're waiting for the settings frame
  /// of the remote end.
  Initialized,

  /// The connection has been established and is fully operational.
  Operational,

  /// The connection is no longer accepting new streams or creating new streams.
  Finishing,

  /// The connection has been terminated and cannot be used anymore.
  Terminated,
}

abstract class Connection {
  /// The settings the other end has acknowledged to use when communicating with
  /// us.
  final Settings acknowledgedSettings = new Settings();

  /// The settings we have to obey communicating with the other side.
  final Settings peerSettings = new Settings();

  /// Whether this connection is a client connection.
  final bool isClientConnection;

  /// Whether server side pushes are allowed.
  final bool pushEnabled;

  /// The HPack context for this connection.
  final HPackContext _hpackContext = new HPackContext();

  /// The flow window for this connection of the peer.
  final Window _peerWindow = new Window();

  /// The flow window for this connection of this end.
  final Window _localWindow = new Window();

  /// Used for defragmenting PushPromise/Header frames.
  final FrameDefragmenter _defragmenter = new FrameDefragmenter();

  /// The outgoing frames of this connection;
  FrameWriter _frameWriter;

  /// A subscription of incoming [Frame]s.
  StreamSubscription<Frame> _frameReaderSubscription;

  /// The incoming connection-level message queue.
  ConnectionMessageQueueIn _incomingQueue;

  /// The outgoing connection-level message queue.
  ConnectionMessageQueueOut _outgoingQueue;

  /// The ping handler used for making pings & handling remote pings.
  PingHandler _pingHandler;

  /// The settings handler used for changing settings & for handling remote
  /// setting changes.
  SettingsHandler _settingsHandler;

  /// The set of active streams this connection has.
  StreamHandler _streams;

  /// The connection-level flow control window handler for outgoing messages.
  OutgoingConnectionWindowHandler _connectionWindowHandler;

  /// The state of this connection.
  ConnectionState _state;

  Connection(Stream<List<int>> incoming,
             StreamSink<List<int>> outgoing,
             {this.isClientConnection: true,
              this.pushEnabled}) {
    _setupConnection(incoming, outgoing);
  }

  /// Runs all setup necessary before new streams can be created with the remote
  /// peer.
  void _setupConnection(Stream<List<int>> incoming,
                        StreamSink<List<int>> outgoing) {
    // Setup frame reading.
    var incomingFrames = new FrameReader(
        incoming, acknowledgedSettings).startDecoding();
    _frameReaderSubscription = incomingFrames.listen(
        _handleFrame,
        onError: (stack, error) {
          _terminate(ErrorCode.CONNECT_ERROR, causedByTransportError: true);
        }, onDone: () {
          _terminate(ErrorCode.CONNECT_ERROR, causedByTransportError: true);
        });

    // Setup frame writing.
    _frameWriter = new FrameWriter(
        _hpackContext.encoder, outgoing, peerSettings);
    _frameWriter.doneFuture.then((_) {
      _terminate(ErrorCode.CONNECT_ERROR, causedByTransportError: true);
    }).catchError((error, stack) {
      _terminate(ErrorCode.CONNECT_ERROR, causedByTransportError: true);
    });

    // Setup handlers.
    _settingsHandler = new SettingsHandler(
        _frameWriter, acknowledgedSettings, peerSettings);
    _pingHandler = new PingHandler(_frameWriter);

    // Do the initial settings handshake (possibly with pushes disabled).
    var settings = [];
    if (isClientConnection && !pushEnabled) {
      // By default the server is allowed to do server pushes.
      settings.add(new Setting(Setting.SETTINGS_ENABLE_PUSH, 0));
    }
    _settingsHandler.changeSettings(settings).catchError((error) {
      // TODO: The [error] can contain sensitive information we now expose via
      // a [Goaway] frame. We should somehow ensure we're only sending useful
      // but non-sensitive information.
      _terminate(ErrorCode.PROTOCOL_ERROR,
                 message: 'Failed to set initial settings (error: $error).');
    });

    _settingsHandler.onInitialWindowSizeChange.listen((size) {
      // TODO: Apply change to [StreamHandler]
    });


    // Setup the connection window handler, which keeps track of the
    // size of the outgoing connection window.
    _connectionWindowHandler =
        new OutgoingConnectionWindowHandler(_peerWindow);

    var connectionWindowUpdater = new IncomingWindowHandler.connection(
        _frameWriter, _localWindow);

    // Setup queues for outgoing/incoming messages on the connection level.
    _outgoingQueue = new ConnectionMessageQueueOut(
        _connectionWindowHandler, _frameWriter);
    _incomingQueue = new ConnectionMessageQueueIn(
        connectionWindowUpdater);

    if (isClientConnection) {
      _streams = new StreamHandler.client(
          _frameWriter, _incomingQueue, _outgoingQueue,
          _settingsHandler.peerSettings, _settingsHandler.acknowledgedSettings);
    } else {
      _streams = new StreamHandler.server(
          _frameWriter, _incomingQueue, _outgoingQueue,
          _settingsHandler.peerSettings, _settingsHandler.acknowledgedSettings);
    }

    // NOTE: We're not waiting until initial settings have been exchanged
    // before we start using the connection (i.e. we don't wait for half a
    // round-trip-time).
    _state = ConnectionState.Initialized;
  }

  /// Pings the remote peer (can e.g. be used for measuring latency).
  Future ping() {
    return _pingHandler.ping().catchError((e, s) {
      return new Future.error(
          new TransportException('The connection has been terminated.'));
    }, test: (e) => e is TerminatedException);
  }

  /// Finishes this connection.
  void finish() {
    _finishing(active: true);
  }

  /// Terminates this connection forcefully.
  Future terminate() {
    return _terminate(ErrorCode.NO_ERROR);
  }

  /// Handles an incoming [Frame] from the underlying [FrameReader].
  void _handleFrame(Frame frame) {
    try {
      _handleFrameImpl(frame);
    } on ProtocolException catch (error) {
      _terminate(ErrorCode.PROTOCOL_ERROR, message: '$error');
    } on FlowControlException catch (error) {
      _terminate(ErrorCode.FLOW_CONTROL_ERROR, message: '$error');
    } on FrameSizeException catch (error) {
      _terminate(ErrorCode.FRAME_SIZE_ERROR, message: '$error');
    } on HPackDecodingException catch (error) {
      _terminate(ErrorCode.PROTOCOL_ERROR, message: '$error');
    } on TerminatedException catch (error) {
      // We tried to perform an action even though the connection was already
      // terminated.
      // TODO: Can this even happen and if so, how should we propagate this
      // error?
    } catch (error) {
      _terminate(ErrorCode.INTERNAL_ERROR, message: '$error');
    }
  }

  void _handleFrameImpl(Frame frame) {
    // The first frame from the other side must be a [SettingsFrame], otherwise
    // we terminate the connection.
    if (_state == ConnectionState.Initialized) {
      if (frame is! SettingsFrame) {
        _terminate(ErrorCode.PROTOCOL_ERROR,
                   message: 'Expected to first receive a settings frame.');
        return;
      }
      _state = ConnectionState.Operational;
    }

    // Try to defragment [frame] if it is a Headers/PushPromise frame.
    frame = _defragmenter.tryDefragmentFrame(frame);
    if (frame == null) return;

    // Try to decode headers if it's a Headers/PushPromise frame.
    // [This needs to be done even if the frames get ignored, since the entire
    //  connection shares one HPack compression context.]
    if (frame is HeadersFrame) {
      frame.decodedHeaders =
          _hpackContext.decoder.decode(frame.headerBlockFragment);
    } else if (frame is PushPromiseFrame) {
      frame.decodedHeaders =
          _hpackContext.decoder.decode(frame.headerBlockFragment);
    }

    // Handle the frame as either a connection or a stream frame.
    if (frame.header.streamId == 0) {
      if (frame is SettingsFrame) {
        _settingsHandler.handleSettingsFrame(frame);
      } else if (frame is PingFrame) {
        _pingHandler.processPingFrame(frame);
      } else if (frame is WindowUpdateFrame) {
        _connectionWindowHandler.processWindowUpdate(frame);
      } else if (frame is GoawayFrame) {
        // TODO: What to do about [frame.lastStreamIdReceived] ?
        _finishing(active: false);
      } else if (frame is UnknownFrame) {
        // We can safely ignore these.
      } else {
        throw new ProtocolException(
            'Cannot handle frame type ${frame.runtimeType} with stream-id 0.');
      }
    } else {
      _streams.processStreamFrame(_state, frame);
    }
  }

  void _finishing({bool active: true, String message}) {
    // If this connection is already finishing or dead, we return.
    if (_state == ConnectionState.Terminated ||
        _state == ConnectionState.Finishing) {
      return;
    }

    if (_state == ConnectionState.Initialized ||
        _state == ConnectionState.Operational) {
      _state = ConnectionState.Finishing;

      // If we are actively finishing this connection, we'll send a
      // GoawayFrame otherwise we'll just propagate the message.
      if (active) {
        _frameWriter.writeGoawayFrame(
            _streams.highestPeerInitiatedStream,
            ErrorCode.NO_ERROR,
            message != null ? UTF8.encode(message) : []);
      }

      // TODO: Propagate to the [StreamSet] that we no longer process new
      // streams. And make it return a Future which we can listen to until
      // all streams are done.
    }
  }

  /// Terminates this connection (if it is not already terminated).
  ///
  /// The returned future will never complete with an error.
  Future _terminate(int errorCode,
                    {bool causedByTransportError: false, String message}) {
    // TODO: When do we complete here?
    if (_state != ConnectionState.Terminated) {
      _state = ConnectionState.Terminated;

      var cancelFuture = new Future.sync(_frameReaderSubscription.cancel);
      if (!causedByTransportError) {
        _frameWriter.writeGoawayFrame(
            _streams.highestPeerInitiatedStream,
            errorCode,
            message != null ? UTF8.encode(message) : []);
      }
      var closeFuture = _frameWriter.close().catchError((e, s) {
        // We ignore any errors after writing to [GoawayFrame]
      });

      // Close all lower level handlers with an error message.
      // (e.g. if there is a pending connection.ping(), it's returned
      //  Future will complete with this error).
      var exception = new TransportConnectionException(
          errorCode, 'Connection is being forcefully terminated.');

      // Close all streams & stream queues
      _streams.terminate(exception);

      // Close the connection queues
      _incomingQueue.terminate(exception);
      _outgoingQueue.terminate(exception);

      _pingHandler.terminate(exception);
      _settingsHandler.terminate(exception);

      return Future.wait([cancelFuture, closeFuture]).catchError((_) {});
    }
    return new Future.value();
  }
}


class ClientConnection extends Connection implements ClientTransportConnection {
  ClientConnection._(Stream<List<int>> incoming,
                     StreamSink<List<int>> outgoing,
                     bool pushEnabled)
      : super(incoming,
              outgoing,
              isClientConnection: true,
              pushEnabled: pushEnabled);

  factory ClientConnection(Stream<List<int>> incoming,
                           StreamSink<List<int>> outgoing,
                           {bool allowServerPushes: true})  {
    outgoing.add(CONNECTION_PREFACE);
    return new ClientConnection._(incoming, outgoing, allowServerPushes);
  }

  TransportStream makeRequest(List<Header> headers, {bool endStream: false}) {
    TransportStream hStream = _streams.newStream(headers, endStream: endStream);
    return hStream;
  }
}

class ServerConnection extends Connection implements ServerTransportConnection {
  ServerConnection._(Stream<List<int>> incoming,
                     StreamSink<List<int>> outgoing)
      : super(
          incoming, outgoing, isClientConnection: false, pushEnabled: false);

  factory ServerConnection(Stream<List<int>> incoming,
                           StreamSink<List<int>> outgoing)  {
    var frameBytes = readConnectionPreface(incoming);
    return new ServerConnection._(frameBytes, outgoing);
  }

  Stream<TransportStream> get incomingStreams => _streams.incomingStreams;
}