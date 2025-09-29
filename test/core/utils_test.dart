import "package:netto/src/core/router/utils.dart";
import "package:test/test.dart";

void main() {
  group("normalizePath", () {
    test("Given an empty path "
        "When normalized "
        "Then it becomes the root", () {
      expect(normalizePath(""), "/");
    });

    test("Given the root path "
        "When normalized "
        "Then it remains unchanged", () {
      expect(normalizePath("/"), "/");
    });

    test("Given a relative path "
        "When normalized "
        "Then it gains a leading slash and removes trailing slashes", () {
      expect(normalizePath("foo/"), "/foo");
      expect(normalizePath("foo/bar"), "/foo/bar");
    });
  });

  group("checkPath", () {
    test("Given a valid path "
        "When checked "
        "Then it is accepted", () {
      expect(() => checkPath("/valid"), returnsNormally);
      expect(() => checkPath("/"), returnsNormally);
    });

    test("Given a path without a leading slash "
        "When checked "
        "Then it is rejected", () {
      expect(
        () => checkPath("invalid"),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message,
            "message",
            contains("start with a slash"),
          ),
        ),
      );
    });

    test("Given a path with a trailing slash "
        "When checked "
        "Then it is rejected unless it is the root", () {
      expect(
        () => checkPath("/invalid/"),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message,
            "message",
            contains("not end with a slash"),
          ),
        ),
      );
    });
  });
}
