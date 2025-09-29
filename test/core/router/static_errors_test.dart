import "dart:io";

import "package:netto/netto.dart";
import "package:test/test.dart";

void main() {
  group("Router static and file error handling", () {
    test("Given a missing directory "
        "When registering a static handler "
        "Then an ArgumentError is thrown", () {
      final router = Router();

      expect(
        () => router.static("/assets", "/path/that/does/not/exist"),
        throwsA(
          isA<ArgumentError>().having(
            (error) => error.message?.toString(),
            "message",
            contains("could not be found"),
          ),
        ),
      );
    });

    test("Given an invalid static route prefix "
        "When registering a static handler "
        "Then an ArgumentError is thrown", () {
      final router = Router();
      final tempDir = Directory.systemTemp.createTempSync("netto_static_test");
      addTearDown(() => tempDir.deleteSync(recursive: true));

      expect(
        () => router.static("invalid", tempDir.path),
        throwsA(isA<ArgumentError>()),
      );
    });

    test("Given a missing file "
        "When registering a file handler "
        "Then an ArgumentError is thrown", () {
      final router = Router();

      expect(
        () => router.file("/file", "/does/not/exist.txt"),
        throwsA(
          isA<ArgumentError>().having(
            (error) => error.message?.toString(),
            "message",
            contains("does not refer to an existing file"),
          ),
        ),
      );
    });

    test("Given an invalid file route "
        "When registering a file handler "
        "Then an ArgumentError is thrown", () {
      final router = Router();
      final file = File("test/fixtures/files/standalone.txt");
      expect(file.existsSync(), isTrue, reason: "Expected fixture file to exist for the test");

      expect(
        () => router.file("invalid", file.path),
        throwsA(isA<ArgumentError>()),
      );
    });
  });
}
