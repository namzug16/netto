import "dart:async";
import "dart:io";

import "package:netto/src/core/ctx.dart";
import "package:netto/src/core/hijack_exception.dart";
import "package:netto/src/core/types.dart";

/// ASCII art banner printed when the server starts.
const _banner = r"""
    _   __     __  __      
   / | / /__  / /_/ /_____ 
  /  |/ / _ \/ __/ __/ __ \
 / /|  /  __/ /_/ /_/ /_/ /
/_/ |_/\___/\__/\__/\____/ 

""";

/// Starts an [HttpServer] wired to the provided [handler].
///
/// Set [suppressBanner] to `true` to skip printing the startup banner (useful
/// for tests or embedded deployments).
Future<HttpServer> serve(
  Handler handler,
  Object address,
  int port, {
  SecurityContext? securityContext,
  int backlog = 0,
  bool shared = false,
  bool suppressBanner = false,
}) async {
  final server = await (securityContext == null
      ? HttpServer.bind(address, port, backlog: backlog, shared: shared)
      : HttpServer.bindSecure(
          address,
          port,
          securityContext,
          backlog: backlog,
          shared: shared,
        ));

  serveRequests(server, handler);

  if (!suppressBanner) {
    //
    // ignore: avoid_print
    print(_banner);
    //
    // ignore: avoid_print
    print("=> http server started on :$port");
  }

  return server;
}

/// Consumes the stream of [requests] and forwards each to [handler].
void serveRequests(Stream<HttpRequest> requests, Handler handler) {
  catchTopLevelErrors(
    () {
      requests.listen((request) => handleRequest(request, handler));
    },
    (error, stackTrace) {
      _logTopLevelError("Asynchronous error\n$error", stackTrace);
    },
  );
}

/// Writes zone-level errors to [stderr].
void _logTopLevelError(String message, StackTrace stackTrace) {
  stderr.writeln(message);
  if (stackTrace != StackTrace.empty) {
    stderr.writeln(stackTrace);
  }
}

/// Runs [callback] while ensuring asynchronous errors are reported via [onError].
///
/// If invoked outside the root error zone the callback executes immediately.
/// Otherwise the work is wrapped in [runZonedGuarded] so unhandled errors are
/// forwarded to [onError].
void catchTopLevelErrors(
  void Function() callback,
  void Function(dynamic error, StackTrace) onError,
) {
  if (Zone.current.inSameErrorZone(Zone.root)) {
    return runZonedGuarded(callback, onError);
  } else {
    return callback();
  }
}

/// Wraps an incoming [request] with [Ctx] and executes the application [handler].
Future<void> handleRequest(HttpRequest request, Handler handler) async {
  final ctx = Ctx(request);

  try {
    await handler(ctx);
  } on HijackException {
    if (!ctx.request.isHijacked) {
      throw StateError(
        "Caught HijackException, but the request wasn't hijacked.",
      );
    }
    return;
  }

  if (ctx.request.isHijacked) {
    return;
  }

  await ctx.response.finalize();
}
