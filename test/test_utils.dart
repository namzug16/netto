import "dart:io";

import "package:netto/netto.dart";

class TestUtils {
  static Future<(HttpServer, String)> createServer(Handler handler) async {
    final server = await serve(handler, InternetAddress.loopbackIPv4, 0, suppressBanner: true);

    return (server, "http://${server.address.host}:${server.port}");
  }
}
