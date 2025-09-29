import "dart:io";

import "package:netto/netto.dart";
import "package:test/fake.dart";
import "package:test/test.dart";

class _FakeHttpResponse extends Fake implements HttpResponse {}

class _FakeHttpRequest extends Fake implements HttpRequest {
  @override
  final Uri uri = Uri.parse("http://localhost/");

  @override
  final String method = "GET";

  @override
  final HttpResponse response = _FakeHttpResponse();
}

void main() {
  group("Ctx extras", () {
    test("Given extras stored on ctx "
        "When accessed via request and response "
        "Then the same values are visible", () {
      final ctx = Ctx(_FakeHttpRequest())..set<String>("greeting", "hello");
      expect(ctx.request.require<String>("greeting"), "hello");

      ctx.request.set<int>("counter", 1);
      expect(ctx.response.require<int>("counter"), 1);

      expect(ctx.contains("greeting"), isTrue);
      expect(ctx.remove<String>("greeting"), "hello");
      expect(ctx.get<String>("greeting"), isNull);
    });

    test("Given a value generated through getOrPut "
        "When accessed multiple times "
        "Then the generator is only invoked once", () {
      final ctx = Ctx(_FakeHttpRequest());
      var built = 0;

      final first = ctx.getOrPut<int>("value", () {
        built++;
        return 42;
      });

      final second = ctx.getOrPut<int>("value", () {
        built++;
        return 1337;
      });

      expect(first, 42);
      expect(second, 42);
      expect(built, 1);
    });

    test("Given a missing extras key "
        "When require is invoked "
        "Then a StateError is thrown", () {
      final ctx = Ctx(_FakeHttpRequest());
      expect(() => ctx.require<String>("missing"), throwsStateError);
    });

    test("Given an extras value with a different type "
        "When get is invoked "
        "Then a StateError is thrown", () {
      final ctx = Ctx(_FakeHttpRequest());
      ctx.set<String>("value", "text");

      expect(() => ctx.get<int>("value"), throwsStateError);
    });

    test("Given a nullable extras value "
        "When require requests a non-nullable type "
        "Then a StateError is thrown", () {
      final ctx = Ctx(_FakeHttpRequest());
      ctx.set<String?>("nullable", null);

      expect(() => ctx.require<String>("nullable"), throwsStateError);
      expect(ctx.require<String?>("nullable"), isNull);
    });

    test("Given extras removals "
        "When removing values with different type expectations "
        "Then type enforcement and nullability are preserved", () {
      final ctx = Ctx(_FakeHttpRequest())
        ..set<int>("count", 2)
        ..set<String?>("maybe", null)
        ..set<Object>("other", 1.0);

      expect(ctx.remove<int>("count"), 2);
      expect(ctx.remove<String?>("maybe"), isNull);
      expect(() => ctx.remove<String>("other"), throwsStateError);
    });
  });
}
