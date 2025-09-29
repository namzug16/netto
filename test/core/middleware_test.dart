import "dart:io";

import "package:netto/netto.dart";
import "package:test/fake.dart";
import "package:test/test.dart";

class _FakeHttpResponse extends Fake implements HttpResponse {}

class _FakeHttpRequest extends Fake implements HttpRequest {
  @override
  final String method = "GET";

  @override
  final Uri uri = Uri.parse("http://localhost/");

  @override
  final HttpResponse response = _FakeHttpResponse();
}

void main() {
  test("Given multiple middleware "
      "When composed "
      "Then they execute in order", () async {
    final calls = <String>[];

    Future<void> base(Ctx ctx) async {
      calls.add("handler");
      expect(ctx.require<int>("counter"), 2);
      expect(ctx.response.require<String>("note"), "set in middleware");
    }

    Future<Future<Null> Function(Ctx ctx)> m1(Handler next) async {
      return (Ctx ctx) async {
        calls.add("m1");
        ctx.set<int>("counter", 1);
        ctx.response.set<String>("note", "set in middleware");
        await next(ctx);
      };
    }

    Future<Future<Null> Function(Ctx ctx)> m2(Handler next) async {
      return (Ctx ctx) async {
        calls.add("m2");
        final current = ctx.request.get<int>("counter") ?? 0;
        ctx.request.set<int>("counter", current + 1);
        await next(ctx);
      };
    }

    final composed = m1.addMiddleware(m2);
    final handler = await composed(base);
    await handler(Ctx(_FakeHttpRequest()));

    expect(calls, ["m1", "m2", "handler"]);
  });
}
