import "dart:async";
import "dart:convert";
import "dart:io";

import "package:http/http.dart" as http;
import "package:netto/netto.dart";
import "package:test/test.dart";

import "../test_utils.dart";

void main() {
  group("serve", () {
    test("Given banner output enabled "
        "When the server starts "
        "Then the startup banner is printed", () async {
      final captured = <String>[];

      final server = await runZoned(
        () => serve(
          (ctx) async {
            ctx.response.noContent();
            await ctx.response.finalize();
          },
          InternetAddress.loopbackIPv4,
          0,
        ),
        zoneSpecification: ZoneSpecification(
          print: (self, parent, zone, line) {
            captured.add(line);
          },
        ),
      );

      try {
        expect(
          captured.any((line) => line.contains("http server started")),
          isTrue,
        );
      } finally {
        await server.close(force: true);
      }
    });
  });

  group("catchTopLevelErrors", () {
    test("Given a synchronous error "
        "When handled "
        "Then it is rethrown", () {
      expect(
        () => catchTopLevelErrors(() {
          throw StateError("boom");
        }, (_, __) {}),
        throwsA(isA<StateError>()),
      );
    });

    test("Given an existing error zone "
        "When executing catchTopLevelErrors "
        "Then the callback runs directly", () async {
      final calls = <String>[];
      runZonedGuarded(
        () {
          catchTopLevelErrors(
            () {
              calls.add("callback");
            },
            (error, _) {
              calls.add("error");
            },
          );
        },
        (error, stackTrace) {
          calls.add("zoneError");
        },
      );
      expect(calls, ["callback"]);
    });
  });

  group("serveRequests and handleRequest", () {
    late Netto app;
    late Router router;
    HttpServer? server;
    late String baseUrl;

    Future<void> startServer() async {
      if (server != null) return;
      final result = await TestUtils.createServer(app.call);
      server = result.$1;
      baseUrl = result.$2;
    }

    Uri url(String path) => Uri.parse("$baseUrl$path");

    Future<http.Response> request(
      String method,
      String path, {
      Map<String, String>? headers,
      Object? body,
    }) async {
      await startServer();
      final req = http.Request(method, url(path));
      if (headers != null) {
        req.headers.addAll(headers);
      }
      if (body != null) {
        switch (body) {
          case final String text:
            req.body = text;
          case final List<int> bytes:
            req.bodyBytes = bytes;
          case final Map<String, String> fields:
            req.bodyFields = fields;
          default:
            throw ArgumentError("Unsupported body type: ${body.runtimeType}");
        }
      }
      final streamed = await req.send();
      return http.Response.fromStream(streamed);
    }

    Future<http.Response> get(String path) => request("GET", path);

    Future<http.Response> head(String path) => request("HEAD", path);

    setUp(() {
      app = Netto();
      router = app.router;
      server = null;
    });

    tearDown(() async {
      await server?.close(force: true);
    });

    test("Given an incoming request "
        "When served "
        "Then the router handles it", () async {
      router.get("/hello", (ctx) async {
        ctx.response.string("world");
      });

      final res = await get("/hello");
      expect(res.statusCode, HttpStatus.ok);
      expect(res.body, "world");
    });

    test("Given handleRequest "
        "When a response is produced "
        "Then it finalizes the response", () async {
      router.get("/close", (ctx) async {
        ctx.response.string("done");
      });

      final res = await get("/close");
      expect(res.statusCode, HttpStatus.ok);
      expect(res.body, "done");
      expect(res.headers[HttpHeaders.contentLengthHeader], "4");
    });

    test("Given a handler that hijacks the request "
        "When the request is processed "
        "Then the custom response is delivered", () async {
      router.get("/hijack", (ctx) {
        ctx.request.hijack((raw) async {
          final socket = await raw.response.detachSocket(writeHeaders: false);
          socket.add(
            utf8.encode(
              "HTTP/1.1 200 OK\r\nConnection: close\r\nContent-Length: 5\r\n\r\nhello",
            ),
          );
          await socket.close();
        });
      });

      await startServer();
      final client = HttpClient();
      try {
        final request = await client.getUrl(url("/hijack"));
        final response = await request.close();
        final body = await utf8.decoder.bind(response).join();

        expect(response.statusCode, HttpStatus.ok);
        expect(body, "hello");
      } finally {
        client.close(force: true);
      }
    });

    test("Given a HEAD request with async middleware "
        "When the handler completes "
        "Then the response reflects the handler without surfacing errors", () async {
      router
        ..use((next) {
          return (Ctx ctx) async {
            await Future<void>.delayed(const Duration(milliseconds: 10));
            await next(ctx);
            ctx.response.headers.set("x-async", "true");
          };
        })
        ..get("/async-head", (ctx) async {
          await Future<void>.delayed(const Duration(milliseconds: 10));
          ctx.response.string("done", status: HttpStatus.accepted);
        });

      final errors = <Object>[];

      http.Response? response;
      await runZonedGuarded(
        () async {
          response = await head("/async-head");
        },
        (error, _) {
          errors.add(error);
        },
      );

      expect(errors, isEmpty);
      expect(response, isNotNull);
      expect(response!.statusCode, HttpStatus.accepted);
      expect(response!.body, isEmpty);
      expect(response!.headers["x-async"], "true");
    });
  });
}
