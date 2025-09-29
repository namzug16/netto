import "dart:io";

import "package:netto/netto.dart";

Future<void> main() async {
  final app = Netto()
    ..use(logger())
    ..get("/", (Ctx ctx) => ctx.response.string("Hello World!"));

  await app.serve(InternetAddress.loopbackIPv4, 8080);
}
