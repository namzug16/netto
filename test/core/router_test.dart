import "dart:io";

import "package:http/http.dart" as http;
import "package:netto/netto.dart";
import "package:test/test.dart";

import "../test_utils.dart";

Netto _createApp() {
  final app = Netto()
    ..get("/hello", (Ctx ctx) => ctx.response.string("Hello"))
    ..get(
      "/user/:id",
      (Ctx ctx) => ctx.response.string("User ${ctx.request.pathParameter("id")}"),
    )
    ..get("/with-middleware", (Ctx ctx) => ctx.response.string("ok"));

  final _ = app.group("/api", (innerHandler) {
    return (Ctx ctx) async {
      await innerHandler(ctx);
      ctx.response.headers.set("x-group", "1");
    };
  })..get("/ping", (Ctx ctx) => ctx.response.string("pong"));

  final _ = app.group("/g1", (innerHandler) {
    return (Ctx ctx) async {
      await innerHandler(ctx);
      ctx.response.headers.set("x-group", "g1");
    };
  })..get("/a", (Ctx ctx) => ctx.response.string("a"));

  final g2 =
      app.group("/g2", (innerHandler) {
          return (Ctx ctx) async {
            await innerHandler(ctx);
            ctx.response.headers.set("x-group", "g2");
          };
        })
        ..get("/b", (Ctx ctx) => ctx.response.string("b"))
        //NOTE: test a middleware that has been added later one
        ..use((innerHandler) {
          return (Ctx ctx) async {
            await innerHandler(ctx);
            ctx.response.headers.set("x-extra", "");
          };
        });

  //NOTE: anonymous group
  final _ = app.group(null, (innerHandler) {
    return (Ctx ctx) async {
      await innerHandler(ctx);
      ctx.response.headers.set("x-group", "anon");
    };
  })..get("/anon", (Ctx ctx) => ctx.response.string(""));

  //NOTE: nested group
  final _ = g2.group("/n", (innerHandler) {
    return (Ctx ctx) async {
      await innerHandler(ctx);
      ctx.response.headers.set("x-nested", "g2/n");
    };
  })..get("/c", (Ctx ctx) => ctx.response.string("c"));

  //NOTE: tests also the correctness of middleware chaining in groups
  app.use((innerHandler) {
    return (Ctx ctx) async {
      ctx.response.headers.set("x-powered-by", "test");
      await innerHandler(ctx);
    };
  });

  return app;
}

void main() {
  late HttpServer server;
  late String baseUrl;

  setUp(() async {
    (server, baseUrl) = await TestUtils.createServer(_createApp().call);
  });

  tearDown(() async {
    await server.close(force: true);
  });

  Uri url(String path) => Uri.parse("$baseUrl$path");

  Future<String> read(String path) => http.read(url(path));
  Future<int> head(String path) async => (await http.head(url(path))).statusCode;
  Future<http.Response> get(String path) => http.get(url(path));
  // Future<http.Response> put(String path) => http.put(url(path));
  // Future<http.Response> post(String path) => http.post(url(path));

  test("Given a registered route "
      "When it is requested "
      "Then the matching handler responds", () async {
    expect(await head("/hello"), HttpStatus.ok);
    expect(await read("/hello"), "Hello");
  });

  test("Given a parameterized route "
      "When requested "
      "Then path parameters are passed to the handler", () async {
    expect(await read("/user/42"), "User 42");
  });

  test("Given a route with middleware "
      "When requested "
      "Then the middleware runs", () async {
    final res = await get("/with-middleware");
    expect(res.statusCode, HttpStatus.ok);
    expect(res.headers["x-powered-by"], "test");
  });

  test("Given a route inside a group "
      "When requested "
      "Then the group middleware runs", () async {
    final res = await get("/api/ping");
    expect(res.statusCode, HttpStatus.ok);
    expect(res.headers["x-group"], "1");
  });

  test("Given separate groups "
      "When their routes are requested "
      "Then their middleware remains isolated", () async {
    final res1 = await get("/g1/a");
    final res2 = await get("/g2/b");

    expect(res1.statusCode, HttpStatus.ok);
    expect(res2.statusCode, HttpStatus.ok);

    expect(res1.headers["x-group"], "g1");
    expect(res2.headers["x-group"], "g2");
  });

  test("Given middleware added after group creation "
      "When a group route is requested "
      "Then the middleware still applies", () async {
    final res = await get("/g2/b");

    expect(res.statusCode, HttpStatus.ok);

    expect(res.headers["x-group"], "g2");
    expect(res.headers["x-extra"], "");
  });

  test("Given nested groups "
      "When a nested route is requested "
      "Then middleware stacks correctly", () async {
    final res = await get("/g2/n/c");

    expect(res.statusCode, HttpStatus.ok);
    expect(res.headers["x-group"], "g2");
    expect(res.headers["x-extra"], "");
    expect(res.headers["x-nested"], "g2/n");
    expect(res.body, "c");
  });

  test("Given an anonymous group "
      "When its route is requested "
      "Then its middleware applies", () async {
    final res = await get("/anon");

    expect(res.statusCode, HttpStatus.ok);
    expect(res.headers["x-group"], "anon");
    expect(res.headers["x-powered-by"], "test");
    expect(res.body, "");
  });

  test("Given global middleware "
      "When any route is requested "
      "Then the middleware headers are present", () async {
    Future<String?> getPoweredBy(String path) async {
      final res = await get(path);
      return res.headers["x-powered-by"];
    }

    const s = "test";

    expect(await getPoweredBy("/hello"), s);
    expect(await getPoweredBy("/user/a"), s);
    expect(await getPoweredBy("/api/ping"), s);
    expect(await getPoweredBy("/g1/a"), s);
    expect(await getPoweredBy("/g2/b"), s);
    expect(await getPoweredBy("/g2/n/c"), s);
  });
}
