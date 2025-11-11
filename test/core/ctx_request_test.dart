import "dart:convert";
import "dart:io";

import "package:http/http.dart" as http;
import "package:netto/netto.dart";
import "package:test/test.dart";

import "../test_utils.dart";

void main() {
  group("CtxRequest", () {
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

    Future<http.Response> get(String path, {Map<String, String>? headers}) => request("GET", path, headers: headers);

    setUp(() {
      app = Netto();
      router = app.router;
      server = null;
    });

    tearDown(() async {
      await server?.close(force: true);
    });

    test("Given a request with metadata "
        "When inspected "
        "Then headers length and content info are available", () async {
      router
        ..post("/info", (ctx) {
          ctx.response.json({
            "https": ctx.request.isHttps,
            "contentLength": ctx.request.contentLength,
            "contentType": ctx.request.contentType?.mimeType,
            "header": ctx.request.header("X-CUSTOM"),
          });
        })
        ..post("/chunked", (ctx) {
          ctx.response.json({"contentLength": ctx.request.contentLength});
        });

      const body = '{"foo":"bar"}';
      final res = await request(
        "POST",
        "/info",
        headers: {
          HttpHeaders.contentTypeHeader: ContentType.json.mimeType,
          "X-Custom": "value",
          "x-forwarded-proto": "https",
        },
        body: body,
      );

      final json = jsonDecode(res.body) as Map<String, dynamic>;
      expect(json["https"], isTrue);
      expect(json["contentLength"], body.codeUnits.length);
      expect(json["contentType"], ContentType.json.mimeType);
      expect(json["header"], "value");

      await startServer();
      final client = HttpClient();
      try {
        final req = await client.postUrl(url("/chunked"));
        req.headers.chunkedTransferEncoding = true;
        req.headers.contentType = ContentType.json;
        req.write("{}");
        final response = await req.close();
        final responseBody = await utf8.decodeStream(response);
        final chunkedJson = jsonDecode(responseBody) as Map<String, dynamic>;
        expect(chunkedJson["contentLength"], isNull);
      } finally {
        client.close(force: true);
      }
    });

    test("Given wildcard accept headers "
        "When negotiated "
        "Then the best match is resolved", () async {
      router
        ..get("/accept/wildcard", (ctx) {
          ctx.response.json({
            "acceptsJson": ctx.request.accepts("application/json"),
          });
        })
        ..get("/accept/default", (ctx) {
          ctx.response.json({
            "best": ctx.request.bestMatch(["application/json", "text/html"]),
            "empty": ctx.request.bestMatch(const <String>[]),
          });
        });

      final wildcard = await get(
        "/accept/wildcard",
        headers: {"accept": "text/*;q=0.5, */*;q=0.1"},
      );
      final wildcardJson = jsonDecode(wildcard.body) as Map<String, dynamic>;
      expect(wildcardJson["acceptsJson"], isTrue);

      final defaultRes = await get("/accept/default");
      final defaultJson = jsonDecode(defaultRes.body) as Map<String, dynamic>;
      expect(defaultJson["best"], "application/json");
      expect(defaultJson["empty"], isNull);
    });

    test("Given malformed offered media types "
        "When bestMatch evaluates them "
        "Then invalid entries are ignored", () async {
      router.get("/accept/invalid", (ctx) {
        final best = ctx.request.bestMatch(["invalid", "text/plain"]);
        ctx.response.json({"best": best});
      });

      final res = await get(
        "/accept/invalid",
        headers: {"accept": "text/plain"},
      );

      final json = jsonDecode(res.body) as Map<String, dynamic>;
      expect(json["best"], "text/plain");
    });

    test("Given an incoming request "
        "When inspected "
        "Then method path query and headers are exposed", () async {
      router.get("/info", (ctx) async {
        final first = ctx.request.headers;
        final second = ctx.request.headers;
        ctx.response.json({
          "method": ctx.request.method,
          "path": ctx.request.path,
          "query": ctx.request.queryParametersAll,
          "host": ctx.request.host,
          "userAgent": ctx.request.userAgent,
          "headerLower": first.containsKey("x-test"),
          "cachedHeaders": identical(first, second),
        });
      });

      final res = await request(
        "GET",
        "/info?foo=bar&foo=baz",
        headers: {
          HttpHeaders.hostHeader: "example.com",
          HttpHeaders.userAgentHeader: "TestAgent",
          "X-Test": "value",
        },
      );

      final json = jsonDecode(res.body) as Map<String, dynamic>;
      expect(json["method"], "GET");
      expect(json["path"], "/info");
      expect(json["query"], {
        "foo": ["bar", "baz"],
      });
      expect(json["host"], "example.com");
      expect(json["userAgent"], "TestAgent");
      expect(json["headerLower"], isTrue);
      expect(json["cachedHeaders"], isTrue);
    });

    test("Given request cookies "
        "When accessed "
        "Then helper methods return their values", () async {
      router.get("/cookies", (ctx) {
        ctx.response.json({
          "all": ctx.request.cookies,
          "single": ctx.request.cookie("token"),
        });
      });

      final res = await get(
        "/cookies",
        headers: {
          HttpHeaders.cookieHeader: "token=abc; other=value; token=override",
        },
      );

      final json = jsonDecode(res.body) as Map<String, dynamic>;
      expect(json["all"], {"token": "abc", "other": "value"});
      expect(json["single"], "abc");
    });

    test("Given forwarded https headers "
        "When inspected "
        "Then https flag and remote address are reported", () async {
      router.get("/meta", (ctx) {
        ctx.response.json({
          "https": ctx.request.isHttps,
          "remote": ctx.request.remoteAddress?.address,
        });
      });

      final res = await get("/meta", headers: {"x-forwarded-proto": "https"});

      final json = jsonDecode(res.body) as Map<String, dynamic>;
      expect(json["https"], isTrue);
      expect(json["remote"], anyOf("127.0.0.1", "::1"));
    });

    test("Given accept headers "
        "When negotiating content "
        "Then helper results reflect preferences", () async {
      router.get("/negotiate", (ctx) {
        ctx.response.json({
          "acceptJson": ctx.request.accepts("application/json"),
          "acceptText": ctx.request.accepts("text/plain"),
          "best": ctx.request.bestMatch(["application/json", "text/html"]),
        });
      });

      final res = await get(
        "/negotiate",
        headers: {"accept": "application/json;q=0.9,text/*;q=0.5"},
      );

      final json = jsonDecode(res.body) as Map<String, dynamic>;
      expect(json["acceptJson"], isTrue);
      expect(json["acceptText"], isTrue);
      expect(json["best"], "application/json");
    });

    test("Given a json body "
        "When checked "
        "Then body type helpers detect json", () async {
      router.post("/types/json", (ctx) {
        ctx.response.json({
          "json": ctx.request.isJson,
          "form": ctx.request.isFormUrlencoded,
          "multipart": ctx.request.isMultipart,
        });
      });

      final res = await request(
        "POST",
        "/types/json",
        headers: {HttpHeaders.contentTypeHeader: ContentType.json.mimeType},
        body: "{}",
      );

      final json = jsonDecode(res.body) as Map<String, dynamic>;
      expect(json, {"json": true, "form": false, "multipart": false});
    });

    test("Given a multipart body "
        "When checked "
        "Then body type helpers detect multipart", () async {
      router.post("/types/form", (ctx) {
        ctx.response.json({
          "json": ctx.request.isJson,
          "form": ctx.request.isFormUrlencoded,
          "multipart": ctx.request.isMultipart,
        });
      });

      final res = await request(
        "POST",
        "/types/form",
        headers: {
          HttpHeaders.contentTypeHeader: "multipart/form-data; boundary=123",
        },
        body: "--123--",
      );

      final json = jsonDecode(res.body) as Map<String, dynamic>;
      expect(json, {"json": false, "form": false, "multipart": true});
    });

    test("Given path parameters "
        "When requesting a missing key "
        "Then an empty string is returned", () async {
      router.get("/users/:id", (ctx) {
        ctx.response.json({
          "id": ctx.request.pathParameter("id"),
          "missing": ctx.request.pathParameter("missing"),
        });
      });

      final res = await get("/users/123");
      final json = jsonDecode(res.body) as Map<String, dynamic>;

      expect(json["id"], "123");
      expect(json["missing"], "");
    });
  });
}
