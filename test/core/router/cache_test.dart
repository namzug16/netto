import "package:netto/netto.dart";
import "package:test/test.dart";

void main() {
  test(
    "Given a registered route "
    "When resolving it multiple times "
    "Then the lookup result is cached",
    () {
      final router = Router();

      router.get("/foo", (ctx) async => ctx.response.string("foo"));

      final first = router.resolve("GET", "/foo");
      final second = router.resolve("GET", "/foo");

      expect(first, isNotNull);
      expect(second, isNotNull);
      expect(router.cacheSize, 1);
      expect(router.isRouteCached("GET", "/foo"), isTrue);
    },
  );

  test(
    "Given cache capacity is exceeded "
    "When resolving many unique routes "
    "Then the least recently used entry is evicted",
    () {
      final router = Router();

      for (var i = 0; i < 101; i++) {
        router.get("/$i", (ctx) async => ctx.response.string("$i"));
      }

      for (var i = 0; i < 101; i++) {
        expect(router.resolve("GET", "/$i"), isNotNull);
      }

      expect(router.isRouteCached("GET", "/0"), isFalse);
      expect(router.cacheSize, lessThanOrEqualTo(100));
    },
  );

  test(
    "Given an unknown route "
    "When resolving it repeatedly "
    "Then the miss result is cached",
    () {
      final router = Router();

      expect(router.resolve("GET", "/missing"), isNull);
      expect(router.resolve("GET", "/missing"), isNull);

      expect(router.cacheSize, 1);
      expect(router.isRouteCached("GET", "/missing"), isTrue);
    },
  );
}
