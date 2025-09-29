import "dart:async";
import "dart:convert";
import "dart:io";

import "package:http/http.dart" as http;
import "package:netto/netto.dart";
import "package:test/fake.dart";
import "package:test/test.dart";

import "../test_utils.dart";

class _FakeHttpHeaders extends Fake implements HttpHeaders {
  final Map<String, List<String>> _headers = {};
  ContentType? _contentType;
  bool _chunkedTransferEncoding = false;

  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) {
    _headers[name.toLowerCase()] = [value.toString()];
  }

  @override
  void add(String name, Object value, {bool preserveHeaderCase = false}) {
    final key = name.toLowerCase();
    (_headers[key] ??= <String>[]).add(value.toString());
  }

  @override
  String? value(String name) {
    final values = _headers[name.toLowerCase()];
    if (values == null || values.isEmpty) return null;
    if (values.length > 1) {
      throw StateError("More than one value for header $name");
    }
    return values.first;
  }

  @override
  set contentType(ContentType? value) {
    _contentType = value;
    if (value != null) {
      set(HttpHeaders.contentTypeHeader, value.toString());
    }
  }

  @override
  ContentType? get contentType => _contentType;

  @override
  set chunkedTransferEncoding(bool value) {
    _chunkedTransferEncoding = value;
  }

  @override
  bool get chunkedTransferEncoding => _chunkedTransferEncoding;

  @override
  void forEach(void Function(String name, List<String> values) action) {
    _headers.forEach(action);
  }
}

class _FakeHttpResponse extends Fake implements HttpResponse {
  _FakeHttpResponse();

  final Completer<void> _done = Completer<void>();
  final List<List<int>> _chunks = <List<int>>[];

  @override
  final HttpHeaders headers = _FakeHttpHeaders();

  @override
  int statusCode = HttpStatus.ok;

  @override
  bool bufferOutput = true;

  @override
  int get contentLength => int.tryParse(headers.value(HttpHeaders.contentLengthHeader) ?? "0") ?? 0;

  @override
  set contentLength(int value) {
    headers.set(HttpHeaders.contentLengthHeader, value);
  }

  @override
  Future<void> get done => _done.future;

  @override
  void add(List<int> data) {
    _chunks.add(List<int>.from(data));
  }

  @override
  Future<void> addStream(Stream<List<int>> stream) async {
    await stream.forEach(add);
  }

  @override
  Future<void> close() async {
    if (!_done.isCompleted) {
      _done.complete();
    }
  }

  @override
  Future<void> flush() async {}

  List<int> get aggregatedBody => _chunks.expand((chunk) => chunk).toList();
}

class _FakeHttpRequest extends Fake implements HttpRequest {
  _FakeHttpRequest({this.method = "GET", Uri? uri}) : uri = uri ?? Uri.parse("http://localhost/");

  @override
  final String method;

  @override
  final Uri uri;

  @override
  final HttpResponse response = _FakeHttpResponse();
}

void main() {
  group("CtxResponse direct", () {
    test("Given a response body already set "
        "When another body is written "
        "Then it throws", () {
      final response = CtxResponse(_FakeHttpRequest())..string("one");
      expect(() => response.json({}), throwsStateError);
    });

    test("Given the created helper "
        "When both json and text bodies are provided "
        "Then it throws", () {
      final response = CtxResponse(_FakeHttpRequest(method: "POST"));
      expect(
        () => response.created("/resource", jsonBody: {"a": 1}, textBody: "body"),
        throwsArgumentError,
      );
    });

    test("Given a suppressed response "
        "When stream is invoked "
        "Then a StateError is thrown", () {
      final request = _FakeHttpRequest();
      final response = CtxResponse(request)..suppressBody();

      expect(
        () => response.stream(
          Stream<List<int>>.fromIterable([
            [1, 2, 3],
          ]),
        ),
        throwsA(isA<StateError>()),
      );
    });

    test("Given a byte stream with a known length "
        "When streamed "
        "Then headers and body reflect the provided metadata", () async {
      final request = _FakeHttpRequest();
      final response = CtxResponse(request);

      await response.stream(
        Stream<List<int>>.fromIterable([utf8.encode("hi")]),
        contentLength: 2,
        type: ContentType.text,
      );

      final fakeResponse = request.response as _FakeHttpResponse;
      expect(fakeResponse.headers.value(HttpHeaders.contentLengthHeader), "2");
      expect(fakeResponse.headers.contentType, ContentType.text);
      expect(fakeResponse.headers.chunkedTransferEncoding, isFalse);
      expect(fakeResponse.aggregatedBody, utf8.encode("hi"));
    });
  });

  group("CtxResponse integration", () {
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

    Future<({int status, Map<String, String> headers, String body})> rawGet(
      String path,
    ) async {
      await startServer();
      final client = HttpClient();
      try {
        final request = await client.getUrl(url(path));
        request.followRedirects = false;
        final response = await request.close();
        final buffer = StringBuffer();
        await for (final chunk in response.transform(utf8.decoder)) {
          buffer.write(chunk);
        }
        final headers = <String, String>{};
        response.headers.forEach((name, values) {
          headers[name.toLowerCase()] = values.join(", ");
        });
        return (
          status: response.statusCode,
          headers: headers,
          body: buffer.toString(),
        );
      } finally {
        client.close(force: true);
      }
    }

    setUp(() {
      app = Netto();
      router = app.router;
      server = null;
    });

    tearDown(() async {
      await server?.close(force: true);
    });

    test("Given a string response "
        "When sent "
        "Then utf8 content and status are applied", () async {
      router.get("/string", (ctx) {
        ctx.response.string("hello", status: HttpStatus.created);
      });

      final res = await get("/string");
      expect(res.statusCode, HttpStatus.created);
      expect(
        res.headers[HttpHeaders.contentTypeHeader],
        startsWith("text/plain"),
      );
      expect(res.body, "hello");
    });

    test("Given json data "
        "When sent "
        "Then it is encoded with the correct header", () async {
      router.get("/json", (ctx) {
        ctx.response.json({"a": 1});
      });

      final res = await get("/json");
      expect(
        res.headers[HttpHeaders.contentTypeHeader],
        startsWith(ContentType.json.mimeType),
      );
      expect(res.body, '{"a":1}');
    });

    test("Given byte data "
        "When sent "
        "Then it copies the bytes and honors the content type", () async {
      router.get("/bytes", (ctx) {
        final data = <int>[1, 2, 3];
        ctx.response.bytes(
          data,
          status: HttpStatus.accepted,
          type: ContentType.binary,
        );
        data[0] = 9;
      });

      final res = await get("/bytes");
      expect(res.statusCode, HttpStatus.accepted);
      expect(
        res.headers[HttpHeaders.contentTypeHeader],
        ContentType.binary.mimeType,
      );
      expect(res.bodyBytes, [1, 2, 3]);
    });

    test("Given html content "
        "When sent "
        "Then the html content type is set", () async {
      router.get("/html", (ctx) {
        ctx.response.html("<p>hi</p>");
      });

      final res = await get("/html");
      expect(
        res.headers[HttpHeaders.contentTypeHeader],
        startsWith("text/html"),
      );
      expect(res.body, "<p>hi</p>");
    });

    test("Given a byte stream "
        "When sent "
        "Then the data is aggregated into the response", () async {
      router.get("/stream", (ctx) async {
        await ctx.response.stream(
          Stream<List<int>>.fromIterable([
            utf8.encode("foo"),
            utf8.encode("bar"),
          ]),
          status: HttpStatus.partialContent,
          type: ContentType.text,
        );
      });

      final res = await get("/stream");
      expect(res.statusCode, HttpStatus.partialContent);
      expect(
        res.headers[HttpHeaders.contentTypeHeader],
        startsWith("text/plain"),
      );
      expect(res.body, "foobar");
    });

    test("Given a status-only response "
        "When finalized "
        "Then the status is set without a body", () async {
      router.get("/status", (ctx) {
        ctx.response.status(HttpStatus.accepted);
      });

      final res = await get("/status");
      expect(res.statusCode, HttpStatus.accepted);
      expect(res.body, isEmpty);
      expect(res.headers[HttpHeaders.contentLengthHeader], "0");
    });

    test("Given a noContent response "
        "When sent "
        "Then the status is 204 with an empty body", () async {
      router.get("/nocontent", (ctx) {
        ctx.response.noContent();
      });

      final res = await get("/nocontent");
      expect(res.statusCode, HttpStatus.noContent);
      expect(res.body, isEmpty);
      expect(res.headers[HttpHeaders.contentLengthHeader], "0");
    });

    test("Given the created helper with a json body "
        "When sent "
        "Then the location and payload are set", () async {
      router.get("/created/json", (ctx) {
        ctx.response.created("/items/1", jsonBody: {"id": 1});
      });

      final res = await get("/created/json");
      expect(res.statusCode, HttpStatus.created);
      expect(res.headers[HttpHeaders.locationHeader], "/items/1");
      expect(res.body, '{"id":1}');
    });

    test("Given the created helper with a text body "
        "When sent "
        "Then the payload and headers reflect the body", () async {
      router.get("/created/text", (ctx) {
        ctx.response.created("/items/3", textBody: "created");
      });

      final res = await get("/created/text");
      expect(res.statusCode, HttpStatus.created);
      expect(res.headers[HttpHeaders.locationHeader], "/items/3");
      expect(res.body, "created");
    });

    test("Given the created helper without a body "
        "When sent "
        "Then the response is empty", () async {
      router.get("/created/empty", (ctx) {
        ctx.response.created("/items/2");
      });

      final res = await get("/created/empty");
      expect(res.statusCode, HttpStatus.created);
      expect(res.headers[HttpHeaders.locationHeader], "/items/2");
      expect(res.body, isEmpty);
      expect(res.headers[HttpHeaders.contentLengthHeader], "0");
    });

    test("Given the redirect helpers "
        "When used "
        "Then the location header is set without a body", () async {
      router.get("/redirect/found", (ctx) {
        ctx.response.found("/somewhere");
      });

      final res = await rawGet("/redirect/found");
      expect(res.status, HttpStatus.found);
      expect(res.headers[HttpHeaders.locationHeader], "/somewhere");
      expect(res.body, isEmpty);
    });

    test("Given each redirect helper "
        "When invoked "
        "Then the expected status codes are returned", () async {
      final cases =
          <String, (int, void Function(Ctx ctx))>{
            "/redirect/301": (
              HttpStatus.movedPermanently,
              (ctx) => ctx.response.movedPermanently("/one"),
            ),
            "/redirect/302": (
              HttpStatus.found,
              (ctx) => ctx.response.found("/two"),
            ),
            "/redirect/303": (
              HttpStatus.seeOther,
              (ctx) => ctx.response.seeOther("/three"),
            ),
            "/redirect/307": (
              HttpStatus.temporaryRedirect,
              (ctx) => ctx.response.temporaryRedirect("/four"),
            ),
            "/redirect/308": (
              HttpStatus.permanentRedirect,
              (ctx) => ctx.response.permanentRedirect("/five"),
            ),
          }..forEach((path, entry) {
            router.get(path, entry.$2);
          });
      router.get("/redirect/custom", (ctx) {
        ctx.response.redirect("/custom", status: HttpStatus.temporaryRedirect);
      });

      for (final entry in cases.entries) {
        final res = await rawGet(entry.key);
        expect(res.status, entry.value.$1);
        expect(res.headers[HttpHeaders.locationHeader], isNotNull);
        expect(res.body, isEmpty);
      }

      final custom = await rawGet("/redirect/custom");
      expect(custom.status, HttpStatus.temporaryRedirect);
      expect(custom.headers[HttpHeaders.locationHeader], "/custom");
      expect(custom.body, isEmpty);
    });

    test("Given the error helpers "
        "When invoked "
        "Then the expected messages and headers are returned", () async {
      final cases =
          <String, (int, String, void Function(Ctx ctx))>{
            "/error/400": (
              HttpStatus.badRequest,
              "Bad Request",
              (ctx) => ctx.response.badRequest(),
            ),
            "/error/401": (
              HttpStatus.unauthorized,
              "Unauthorized",
              (ctx) => ctx.response.unauthorized(),
            ),
            "/error/403": (
              HttpStatus.forbidden,
              "Forbidden",
              (ctx) => ctx.response.forbidden(),
            ),
            "/error/404": (
              HttpStatus.notFound,
              "Not Found",
              (ctx) => ctx.response.notFound(),
            ),
            "/error/409": (
              HttpStatus.conflict,
              "Conflict",
              (ctx) => ctx.response.conflict(),
            ),
            "/error/410": (
              HttpStatus.gone,
              "Gone",
              (ctx) => ctx.response.gone(),
            ),
            "/error/500": (
              HttpStatus.internalServerError,
              "Internal Server Error",
              (ctx) => ctx.response.internalServerError(),
            ),
          }..forEach((path, entry) {
            router.get(path, entry.$3);
          });

      for (final entry in cases.entries) {
        final res = await get(entry.key);
        expect(res.statusCode, entry.value.$1);
        expect(res.body, entry.value.$2);
        expect(
          res.headers[HttpHeaders.contentTypeHeader],
          startsWith("text/plain"),
        );
      }
    });

    test("Given a streamed body without length "
        "When served "
        "Then chunks flush progressively", () async {
      final controller = StreamController<List<int>>();
      final ready = Completer<void>();

      router.get("/stream/progressive", (ctx) {
        ready.complete();
        return ctx.response.stream(controller.stream, type: ContentType.text);
      });

      await startServer();
      final client = HttpClient();

      try {
        final request = await client.getUrl(url("/stream/progressive"));
        final responseFuture = request.close();

        await ready.future;

        final received = <String>[];
        final firstChunk = Completer<void>();
        final done = Completer<void>();
        final subscriptionReady = Completer<void>();
        late final HttpClientResponse response;
        StreamSubscription<List<int>>? subscription;

        //
        // ignore: unawaited_futures
        responseFuture
            .then((res) {
              response = res;
              subscription = res.listen(
                (chunk) {
                  final text = utf8.decode(chunk);
                  received.add(text);
                  if (received.length == 1 && !firstChunk.isCompleted) {
                    firstChunk.complete();
                  }
                },
                onDone: done.complete,
                onError: done.completeError,
                cancelOnError: true,
              );
              subscriptionReady.complete();
            })
            .catchError((Object error, StackTrace stackTrace) {
              if (!subscriptionReady.isCompleted) {
                subscriptionReady.completeError(error, stackTrace);
              } else if (!done.isCompleted) {
                done.completeError(error, stackTrace);
              }
            });

        controller.add(utf8.encode("hello"));

        await subscriptionReady.future;
        expect(
          response.headers.value(HttpHeaders.transferEncodingHeader),
          "chunked",
        );

        await firstChunk.future;

        controller.add(utf8.encode("world"));
        await controller.close();

        await done.future;
        await subscription?.cancel();

        expect(received, ["hello", "world"]);
      } finally {
        client.close(force: true);
      }
    });
  });
}
