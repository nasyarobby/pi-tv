import 'package:web_socket_channel/web_socket_channel.dart';

/// Browsers cannot set headers on a WebSocket; the session cookie is used.
WebSocketChannel connectWebSocket(Uri uri, Map<String, String> headers) => WebSocketChannel.connect(uri);
