import "dart:async";
import "dart:io";

import "package:hotreloader/hotreloader.dart";
import "package:netto/netto.dart";

// To enable hot reload, start the server with the Dart VM service enabled:
// dart run --enable-vm-service bin/server.dart
Future<void> main() async {
  final app = Netto()
    ..get("/", handler);

  await withHotreload(() => app.serve(InternetAddress.loopbackIPv4, 8080, suppressBanner: true));
}

void handler(Ctx ctx) => ctx.response.string("Hello world");

Future<void> withHotreload(FutureOr<HttpServer> Function() serverFactory) async {
  HttpServer? runningServer;

  Future<void> obtainNewServer(FutureOr<HttpServer> Function() create) async {
    final willReplaceServer = runningServer != null;
    await runningServer?.close(force: true);
    if (willReplaceServer) {
      print("[Netto server hotrealoded]");
    }
    runningServer = await create();
  }

  try {
    await HotReloader.create(
      onAfterReload: (ctx) {
        obtainNewServer(serverFactory);
      },
    );

    //
    // ignore: avoid_catching_errors
  } on StateError catch (e) {
    if (e.message.contains("VM service not available")) {
      /// Hot-reload is not available
      print("Hotreload not available");
    } else {
      rethrow;
    }
  }

  await obtainNewServer(serverFactory);

  print("Netto server started on ${runningServer?.port}");
}
