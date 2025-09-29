// Example demonstrating how to hijack an [HttpRequest] and upgrade it to a
// WebSocket connection using `dart:io`.

import "dart:convert";
import "dart:io";

import "package:netto/netto.dart";

Future<void> main() async {
  final app = Netto()
    ..get("/", (ctx) {
      final host = ctx.request.host ?? "localhost";
      return ctx.response.string(
        "Open a WebSocket connection to ws://$host:8080/ws",
      );
    })
    ..get("/ws", (ctx) {
      // Hijack the request to gain access to the underlying HttpRequest and
      // perform the WebSocket handshake manually.
      ctx.request.hijack((raw) async {
        final socket = await WebSocketTransformer.upgrade(raw);

        socket.add("Connected to Netto WebSocket example");

        // Echo incoming text messages as JSON and reverse binary payloads.
        await for (final message in socket) {
          switch (message) {
            case final String text:
              socket.add(jsonEncode({"echo": text}));
            case final List<int> bytes:
              socket.add(bytes.reversed.toList());
            default:
              socket.add("Unsupported message type: ${message.runtimeType}");
          }
        }
      });
    });

  await app.serve(InternetAddress.loopbackIPv4, 8080);
}
