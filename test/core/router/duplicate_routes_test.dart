import "package:netto/netto.dart";
import "package:test/test.dart";

void main() {
  group("Router duplicate registrations", () {
    test("Given a GET route is already registered "
        "When the same GET route is added again "
        "Then a duplicate route exception is thrown", () {
      final router = Router();

      router.get("/users", (ctx) {});

      expect(
        () => router.get("/users", (ctx) {}),
        throwsA(
          isA<Exception>().having(
            (error) => error.toString(),
            "message",
            contains("Duplicate route"),
          ),
        ),
      );
    });

    test("Given a GET route implicitly registers HEAD "
        "When a HEAD handler is added "
        "Then a duplicate route exception is thrown", () {
      final router = Router();

      router.get("/users", (ctx) {});

      expect(
        () => router.head("/users", (ctx) {}),
        throwsA(
          isA<Exception>().having(
            (error) => error.toString(),
            "message",
            contains("Duplicate route"),
          ),
        ),
      );
    });

    test("Given a file route is registered "
        "When the same file route is registered again "
        "Then a duplicate route exception is thrown", () {
      final router = Router();
      final filePath = "test/fixtures/files/standalone.txt";

      router.file("/download", filePath);

      expect(
        () => router.file("/download", filePath),
        throwsA(
          isA<Exception>().having(
            (error) => error.toString(),
            "message",
            contains("Duplicate route"),
          ),
        ),
      );
    });

    test("Given routes registered in a parent group "
        "When the same route is registered in a child group "
        "Then a duplicate route exception is thrown", () {
      final router = Router();
      final group = router.group("/api");

      router.get("/api/users", (ctx) {});

      expect(
        () => group.get("/users", (ctx) {}),
        throwsA(
          isA<Exception>().having(
            (error) => error.toString(),
            "message",
            contains("Duplicate route"),
          ),
        ),
      );
    });
  });
}
