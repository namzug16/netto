import "dart:io";

import "package:http/http.dart" as http;
import "package:netto/netto.dart";
import "package:test/test.dart";

void main() {
  group("Netto", () {
    test("Given a registered route "
        "When a request is routed "
        "Then the handler response is returned", () async {
      final app = Netto()..get("/hello", (Ctx ctx) => ctx.response.string("world"));

      expect(app.middleware, isNull);

      final server = await app.serve(
        InternetAddress.loopbackIPv4,
        0,
        suppressBanner: true,
      );

      try {
        final uri = Uri.parse(
          "http://${server.address.host}:${server.port}/hello",
        );

        final response = await http.get(uri);

        expect(response.statusCode, HttpStatus.ok);

        expect(response.body, "world");
      } finally {
        await server.close(force: true);
      }
    });

    test("Given an unknown route "
        "When the default handler executes "
        "Then a not found response is returned", () async {
      final app = Netto();

      final server = await app.serve(
        InternetAddress.loopbackIPv4,
        0,
        suppressBanner: true,
      );

      try {
        final uri = Uri.parse(
          "http://${server.address.host}:${server.port}/missing",
        );

        final response = await http.get(uri);

        expect(response.statusCode, HttpStatus.notFound);
        expect(response.body, "Route not found");
      } finally {
        await server.close(force: true);
      }
    });

    test("Given a custom not found handler "
        "When a missing route is requested "
        "Then the custom response is used", () async {
      final app = Netto()
        ..notFoundHandler = (ctx) async {
          ctx.response.string("Custom", status: HttpStatus.notFound);
        };

      final server = await app.serve(
        InternetAddress.loopbackIPv4,
        0,
        suppressBanner: true,
      );

      try {
        final uri = Uri.parse(
          "http://${server.address.host}:${server.port}/missing",
        );

        final response = await http.get(uri);

        expect(response.statusCode, HttpStatus.notFound);
        expect(response.body, "Custom");
      } finally {
        await server.close(force: true);
      }
    });

    test("Given global middleware "
        "When no route matches "
        "Then the middleware still runs", () async {
      final events = <String>[];
      final app = Netto()
        ..use((next) {
          return (Ctx ctx) async {
            events.add("before");
            await next(ctx);
            events.add("after");
          };
        });

      final server = await app.serve(
        InternetAddress.loopbackIPv4,
        0,
        suppressBanner: true,
      );

      try {
        final uri = Uri.parse(
          "http://${server.address.host}:${server.port}/missing",
        );

        final response = await http.get(uri);

        expect(response.statusCode, HttpStatus.notFound);
        expect(events, equals(["before", "after"]));
      } finally {
        await server.close(force: true);
      }
    });

    test("Given an unexpected exception "
        "When it bubbles to the error handler "
        "Then the default 500 response is returned", () async {
      final app = Netto()..get("/boom", (ctx) => throw StateError("boom"));

      final server = await app.serve(
        InternetAddress.loopbackIPv4,
        0,
        suppressBanner: true,
      );

      try {
        final uri = Uri.parse(
          "http://${server.address.host}:${server.port}/boom",
        );

        final response = await http.get(uri);

        expect(response.statusCode, HttpStatus.internalServerError);
        expect(response.body, "Internal Server Error");
      } finally {
        await server.close(force: true);
      }
    });

    test("Given a route that throws HttpException "
        "When a custom error handler is registered "
        "Then the handler receives and formats the error", () async {
      final app = Netto()
        ..get("/missing", (ctx) {
          throw HttpException.notFound(message: "Not here");
        })
        ..errorHandler = (ctx, error) {
          expect(error.status, HttpStatus.notFound);
          expect(error.message, "Not here");
          return ctx.response.string("custom", status: error.status);
        };

      final server = await app.serve(
        InternetAddress.loopbackIPv4,
        0,
        suppressBanner: true,
      );

      try {
        final uri = Uri.parse(
          "http://${server.address.host}:${server.port}/missing",
        );

        final response = await http.get(uri);

        expect(response.statusCode, HttpStatus.notFound);
        expect(response.body, "custom");
      } finally {
        await server.close(force: true);
      }
    });

    test("Given a non-HTTP exception "
        "When handled by a custom error handler "
        "Then it arrives wrapped as an HttpException", () async {
      HttpException? capturedError;

      final app = Netto()
        ..get("/explode", (ctx) => throw StateError("explosion"))
        ..errorHandler = (ctx, error) {
          capturedError = error;

          expect(error.status, HttpStatus.internalServerError);
          expect(error.message, "Internal Server Error");
          expect(error.meta, containsPair("error", "Bad state: explosion"));

          return ctx.response.string(
            "handled",
            status: HttpStatus.internalServerError,
          );
        };

      final server = await app.serve(
        InternetAddress.loopbackIPv4,
        0,
        suppressBanner: true,
      );

      try {
        final uri = Uri.parse(
          "http://${server.address.host}:${server.port}/explode",
        );

        final response = await http.get(uri);

        expect(capturedError, isNotNull);
        expect(response.statusCode, HttpStatus.internalServerError);
        expect(response.body, "handled");
      } finally {
        await server.close(force: true);
      }
    });

    test("Given a custom error handler that throws "
        "When Netto falls back "
        "Then it recovers with the default 500 response", () async {
      final app = Netto()
        ..get("/kaboom", (ctx) => throw StateError("kaboom"))
        ..errorHandler = (ctx, error) {
          throw StateError("error handler failure");
        };

      final server = await app.serve(
        InternetAddress.loopbackIPv4,
        0,
        suppressBanner: true,
      );

      try {
        final uri = Uri.parse(
          "http://${server.address.host}:${server.port}/kaboom",
        );

        final response = await http.get(uri);

        expect(response.statusCode, HttpStatus.internalServerError);
        expect(response.body, "Internal Server Error");
      } finally {
        await server.close(force: true);
      }
    });

    test("Given global middleware "
        "When a handler throws "
        "Then the middleware observes the final response", () async {
      final events = <String>[];
      final app = Netto()
        ..use((next) {
          return (Ctx ctx) async {
            events.add("before");
            try {
              await next(ctx);
            } finally {
              events.add("after");
            }
          };
        })
        ..get("/boom", (Ctx ctx) {
          throw HttpException.internalServerError(message: "boom");
        });

      final server = await app.serve(
        InternetAddress.loopbackIPv4,
        0,
        suppressBanner: true,
      );

      try {
        final uri = Uri.parse(
          "http://${server.address.host}:${server.port}/boom",
        );

        final response = await http.get(uri);

        expect(response.statusCode, HttpStatus.internalServerError);
        expect(events, equals(["before", "after"]));
      } finally {
        await server.close(force: true);
      }
    });

    test("Given a verb mismatch "
        "When the router resolves allowed methods "
        "Then a 405 response lists the permitted verbs", () async {
      final app = Netto()..get("/resource", (ctx) => ctx.response.string("ok"));

      final server = await app.serve(
        InternetAddress.loopbackIPv4,
        0,
        suppressBanner: true,
      );

      try {
        final uri = Uri.parse(
          "http://${server.address.host}:${server.port}/resource",
        );

        final response = await http.post(uri);

        expect(response.statusCode, HttpStatus.methodNotAllowed);
        expect(response.body, "Method Not Allowed");
        expect(response.headers[HttpHeaders.allowHeader], "GET, HEAD");
      } finally {
        await server.close(force: true);
      }
    });

    test("Given a path registered for multiple verbs "
        "When an unsupported verb is used "
        "Then the Allow header enumerates every method", () async {
      final app = Netto()
        ..get("/multi", (ctx) => ctx.response.string("get"))
        ..post("/multi", (ctx) => ctx.response.string("post"));

      final server = await app.serve(
        InternetAddress.loopbackIPv4,
        0,
        suppressBanner: true,
      );

      try {
        final uri = Uri.parse(
          "http://${server.address.host}:${server.port}/multi",
        );

        final response = await http.put(uri);

        expect(response.statusCode, HttpStatus.methodNotAllowed);
        expect(response.body, "Method Not Allowed");
        expect(response.headers[HttpHeaders.allowHeader], "GET, HEAD, POST");
      } finally {
        await server.close(force: true);
      }
    });
  });
}
