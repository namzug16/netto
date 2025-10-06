import "dart:async";
import "dart:io";

import "package:netto/netto.dart";
import "package:test/test.dart";

Future<_CtxHarness> _createCtxHarness({String method = "GET"}) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final ctxCompleter = Completer<Ctx>();
  final releaseCompleter = Completer<void>();

  late final StreamSubscription<HttpRequest> subscription;
  subscription = server.listen((request) async {
    ctxCompleter.complete(Ctx(request));
    await releaseCompleter.future;
    await subscription.cancel();
  });

  final client = HttpClient();
  final uri = Uri.parse("http://${server.address.host}:${server.port}/test");
  final req = await client.openUrl(method, uri);
  final responseFuture = req.close();

  final ctx = await ctxCompleter.future;

  return _CtxHarness(
    ctx: ctx,
    server: server,
    client: client,
    releaseCompleter: releaseCompleter,
    responseFuture: responseFuture,
  );
}

class _CtxHarness {
  _CtxHarness({
    required this.ctx,
    required this.server,
    required this.client,
    required this.releaseCompleter,
    required this.responseFuture,
  });

  final Ctx ctx;
  final HttpServer server;
  final HttpClient client;
  final Completer<void> releaseCompleter;
  final Future<HttpClientResponse> responseFuture;

  Future<void> dispose() async {
    if (!ctx.response.isCommitted) {
      await ctx.response.finalize();
    }
    if (!releaseCompleter.isCompleted) {
      releaseCompleter.complete();
    }
    await responseFuture;
    await server.close(force: true);
    client.close(force: true);
  }
}

void main() {
  group("RouteNode.invoke", () {
    test("Given a route node without a handler "
        "When invoked "
        "Then it completes without running middleware", () async {
      final harness = await _createCtxHarness();
      addTearDown(harness.dispose);

      final router = Router();
      var middlewareRan = false;
      router.use((next) async {
        middlewareRan = true;
        return next;
      });

      final node = RouteNode(null, router);

      await node.invoke(harness.ctx, const <String, String>{});

      expect(middlewareRan, isFalse);
    });

    test("Given a route node without middleware "
        "When invoked "
        "Then it executes the handler", () async {
      final harness = await _createCtxHarness();
      addTearDown(harness.dispose);

      final router = Router();
      var handlerCalled = false;

      final node = RouteNode((ctx) {
        handlerCalled = true;
      }, router);

      await node.invoke(harness.ctx, const <String, String>{});

      expect(handlerCalled, isTrue);
    });

    test("Given a route node with middleware "
        "When invoked "
        "Then it wraps the handler in the middleware chain", () async {
      final harness = await _createCtxHarness();
      addTearDown(harness.dispose);

      final router = Router();
      final calls = <String>[];
      router.use((next) async {
        return (Ctx ctx) async {
          calls.add("middleware-before");
          await Future.sync(() => next(ctx));
          calls.add("middleware-after");
        };
      });

      final node = RouteNode((ctx) {
        calls.add("handler");
      }, router);

      await node.invoke(harness.ctx, const <String, String>{});

      expect(calls, ["middleware-before", "handler", "middleware-after"]);
    });

    test("Given a HEAD request with middleware "
        "When invoked "
        "Then it suppresses the response body after execution", () async {
      final harness = await _createCtxHarness(method: "HEAD");
      addTearDown(harness.dispose);

      final router = Router();
      final calls = <String>[];
      router.use((next) async {
        return (Ctx ctx) async {
          calls.add("middleware-before");
          await Future.sync(() => next(ctx));
          calls.add("middleware-after");
        };
      });

      final node = RouteNode((ctx) {
        calls.add("handler");
        ctx.response.string("body");
      }, router);

      await node.invoke(harness.ctx, const <String, String>{});

      expect(calls, ["middleware-before", "handler", "middleware-after"]);
      expect(harness.ctx.response.isBodySuppressed, isTrue);
    });
  });
}
