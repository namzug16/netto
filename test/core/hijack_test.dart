import "dart:io";

import "package:netto/netto.dart";
import "package:test/fake.dart";
import "package:test/test.dart";

class _FakeHttpResponse extends Fake implements HttpResponse {}

class _FakeHttpRequest extends Fake implements HttpRequest {
  _FakeHttpRequest();

  @override
  final HttpResponse response = _FakeHttpResponse();
}

void main() {
  group("CtxRequest hijack", () {
    test("Given a request without hijack support "
        "When hijack is invoked "
        "Then it throws a StateError", () {
      final request = CtxRequest(_FakeHttpRequest(), enableHijack: false);

      expect(request.canHijack, isFalse);
      expect(() => request.hijack((_) {}), throwsStateError);
    });

    test("Given a hijackable request "
        "When hijack is invoked "
        "Then it throws a HijackException after executing the callback", () {
      final raw = _FakeHttpRequest();
      final request = CtxRequest(raw);

      expect(request.canHijack, isTrue);
      expect(
        () => request.hijack(
          expectAsync1((HttpRequest hijacked) {
            expect(hijacked, same(raw));
          }),
        ),
        throwsA(isA<HijackException>()),
      );
      expect(request.isHijacked, isTrue);
      expect(request.canHijack, isFalse);
    });

    test("Given a hijackable request "
        "When hijack is invoked twice "
        "Then the second call throws a StateError", () {
      final request = CtxRequest(_FakeHttpRequest());

      expect(
        () => request.hijack(expectAsync1((_) {})),
        throwsA(isA<HijackException>()),
      );

      expect(() => request.hijack((_) {}), throwsStateError);
    });
  });
}
