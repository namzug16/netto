import "dart:async";
import "dart:io";

import "package:http/http.dart" as http;
import "package:logging/logging.dart";
import "package:netto/netto.dart";
import "package:test/test.dart";

import "../test_utils.dart";

void main() {
  group("Logger middleware", () {
    late Netto app;
    HttpServer? server;
    late String baseUrl;
    late Logger testLogger;
    late List<LogRecord> records;
    StreamSubscription<LogRecord>? subscription;

    setUp(() {
      app = Netto();
      server = null;
      records = <LogRecord>[];
      testLogger = Logger.detached("logger_test")..level = Level.ALL;
      subscription = testLogger.onRecord.listen(records.add);
    });

    tearDown(() async {
      await subscription?.cancel();
      await server?.close(force: true);
    });

    Future<void> startServer() async {
      if (server != null) {
        return;
      }
      final result = await TestUtils.createServer(app.call);
      server = result.$1;
      baseUrl = result.$2;
    }

    Future<http.Response> get(
      String path, {
      Map<String, String>? headers,
    }) async {
      await startServer();
      final uri = Uri.parse("$baseUrl$path");
      return http.get(uri, headers: headers);
    }

    Future<http.Response> send(http.Request request) async {
      await startServer();
      final streamed = await request.send();
      return http.Response.fromStream(streamed);
    }

    Future<void> flushLogs() async {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }

    test("Given the default logger middleware "
        "When a request is processed "
        "Then Logger.root receives the formatted entry", () async {
      final captured = <String>[];

      await runZoned(
        () async {
          app
            ..use(logger())
            ..get("/default", (ctx) {
              ctx.response.string("default");
            });

          final response = await get("/default");
          expect(response.statusCode, HttpStatus.ok);

          await flushLogs();
        },
        zoneSpecification: ZoneSpecification(
          print: (self, parent, zone, line) {
            captured.add(line);
          },
        ),
      );

      final logLine = captured.firstWhere(
        (line) => line.contains('"method":"GET"'),
        orElse: () => "",
      );

      expect(logLine, isNotEmpty);
      expect(logLine, startsWith("INFO: "));
      expect(logLine, contains('"uri":"/default"'));
    });

    test("Given the default logger configuration "
        "When a request completes "
        "Then request metadata is logged", () async {
      final clock = _FakeClock([
        DateTime(2024, 1, 1, 12),
        DateTime(2024, 1, 1, 12, 0, 0, 0, 12),
      ]);

      app
        ..use(
          loggerWithConfig(
            LoggerConfig(logger: testLogger, clock: clock.next),
          ),
        )
        ..get("/hello", (ctx) {
          ctx.response.string("ok");
        });

      final response = await get(
        "/hello?foo=bar",
        headers: {
          "X-Real-IP": "203.0.113.42",
          "X-Request-ID": "abc-123",
          HttpHeaders.userAgentHeader: "netto-tests",
        },
      );

      expect(response.statusCode, HttpStatus.ok);

      await flushLogs();

      expect(records, hasLength(1));
      final message = records.single.message;
      expect(message, contains('"method":"GET"'));
      expect(message, contains('"uri":"/hello?foo=bar"'));
      expect(message, contains('"remote_ip":"203.0.113.42"'));
      expect(message, contains('"status":200'));
      expect(message, contains('"bytes_in":0'));
      expect(message, contains('"bytes_out":2'));
      expect(message, contains('"user_agent":"netto-tests"'));
      expect(message, contains('"id":"abc-123"'));
    });

    test("Given a skipper that opts out "
        "When the middleware evaluates the request "
        "Then logging is skipped", () async {
      final clock = _FakeClock([
        DateTime(2024, 1, 1, 8),
        DateTime(2024, 1, 1, 8, 0, 0, 0, 1),
      ]);

      app
        ..use(
          loggerWithConfig(
            LoggerConfig(
              logger: testLogger,
              clock: clock.next,
              skipper: (_) => true,
            ),
          ),
        )
        ..get("/skip", (ctx) {
          ctx.response.string("skip");
        });

      final response = await get("/skip");
      expect(response.statusCode, HttpStatus.ok);

      await flushLogs();

      expect(records, isEmpty);
    });

    test("Given a custom log format "
        "When headers cookies and custom tags are present "
        "Then the rendered entry contains each value", () async {
      final clock = _FakeClock([
        DateTime(2024, 1, 1, 9),
        DateTime(2024, 1, 1, 9, 0, 0, 0, 1),
      ]);

      app
        ..use(
          loggerWithConfig(
            LoggerConfig(
              logger: testLogger,
              clock: clock.next,
              format: r"${method} ${uri} ${status} ${header:x-custom} ${query:foo} ${cookie:session} ${custom}",
              customTag: (event) => "tag=${event.status}",
            ),
          ),
        )
        ..get("/tags", (ctx) {
          ctx.response.string("tags");
        });

      await startServer();

      final request = http.Request("GET", Uri.parse("$baseUrl/tags?foo=bar"))
        ..headers.addAll({
          "x-custom": "custom-header",
          HttpHeaders.cookieHeader: "session=abc123",
        });

      final response = await send(request);
      expect(response.statusCode, HttpStatus.ok);

      await flushLogs();

      expect(records, hasLength(1));
      final message = records.single.message;
      expect(message, contains("GET"));
      expect(message, contains("/tags?foo=bar"));
      expect(message, contains("200"));
      expect(message, contains("custom-header"));
      expect(message, contains("bar"));
      expect(message, contains("abc123"));
      expect(message, contains("tag=200"));
    });

    test("Given a custom timestamp pattern "
        "When the log entry is rendered "
        "Then the formatter output is used", () async {
      final timestamp = DateTime(2024, 1, 1, 10, 0, 0, 123, 450);
      final clock = _FakeClock([timestamp, timestamp]);

      app
        ..use(
          loggerWithConfig(
            LoggerConfig(
              logger: testLogger,
              clock: clock.next,
              format: r"${time_custom}",
              customTimeFormat: "yyyy/MM/dd HH:mm:ss.SSSSS",
            ),
          ),
        )
        ..get("/time", (ctx) {
          ctx.response.string("time");
        });

      final response = await get("/time");
      expect(response.statusCode, HttpStatus.ok);

      await flushLogs();

      expect(records, hasLength(1));
      expect(records.single.message, "2024/01/01 10:00:00.12345");
    });

    test("Given a handler that throws "
        "When the logger middleware observes it "
        "Then the error is rethrown after logging", () async {
      final clock = _FakeClock([
        DateTime(2024, 1, 1, 11),
        DateTime(2024, 1, 1, 11, 0, 0, 0, 5),
      ]);

      app
        ..use(
          loggerWithConfig(
            LoggerConfig(
              logger: testLogger,
              clock: clock.next,
            ),
          ),
        )
        ..get("/boom", (ctx) {
          throw StateError("boom");
        });

      final response = await get("/boom");
      expect(response.statusCode, HttpStatus.internalServerError);

      await flushLogs();

      expect(records, hasLength(1));
      expect(records.single.error, isA<StateError>());
    });

    test("Given detailed time and request tokens "
        "When the log entry is rendered "
        "Then each token is populated", () async {
      final timestamp = DateTime.utc(2024, 1, 1, 12, 0, 0, 123, 456);
      final clock = _FakeClock([timestamp, timestamp]);

      app
        ..use(
          loggerWithConfig(
            LoggerConfig(
              logger: testLogger,
              clock: clock.next,
              format: r"${time_unix} ${time_unix_milli} ${time_unix_micro} ${time_unix_nano} ${time_rfc3339} ${time_rfc3339_nano} ${path} ${protocol} ${referer}",
            ),
          ),
        )
        ..get("/details", (ctx) {
          ctx.response.string("details");
        });

      final response = await get(
        "/details",
        headers: {
          HttpHeaders.refererHeader: "https://example.com/page",
        },
      );
      expect(response.statusCode, HttpStatus.ok);

      await flushLogs();

      expect(records, hasLength(1));
      final message = records.single.message;
      expect(message, contains("${timestamp.millisecondsSinceEpoch ~/ 1000}"));
      expect(message, contains(timestamp.millisecondsSinceEpoch.toString()));
      expect(message, contains(timestamp.microsecondsSinceEpoch.toString()));
      expect(message, contains((timestamp.microsecondsSinceEpoch * 1000).toString()));
      expect(message, contains(timestamp.toUtc().toIso8601String()));
      expect(message, contains("/details"));
      expect(message, contains("https://example.com/page"));
      expect(message, contains(" /details 1.1 https://"));
    });
  });
}

class _FakeClock {
  _FakeClock(this._ticks);

  final List<DateTime> _ticks;
  int _index = 0;

  DateTime next() {
    if (_index >= _ticks.length) {
      return _ticks.last;
    }
    return _ticks[_index++];
  }
}
