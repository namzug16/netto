import "package:netto/netto.dart";
import "package:test/test.dart";

void main() {
  group("RadixTree", () {
    test("Given a static route "
        "When searched "
        "Then the matching handler is returned", () {
      final tree = RadixTree<String>()..insert("/about", "About Page");

      final result = tree.get("/about");
      expect(result, isNotNull);
      expect(result!.value, equals("About Page"));
      expect(result.params, isEmpty);
    });

    test("Given a route with a parameter "
        "When searched "
        "Then the parameter value is extracted", () {
      final tree = RadixTree<String>()..insert("/product/:id", "Product Handler");

      final result = tree.get("/product/123");
      expect(result, isNotNull);
      expect(result!.value, equals("Product Handler"));
      expect(result.params, equals({"id": "123"}));
    });

    test("Given a nested route with a parameter "
        "When searched "
        "Then it matches with the parameter", () {
      final tree = RadixTree<String>()..insert("/user/:uid/settings", "User Settings");

      final result = tree.get("/user/42/settings");
      expect(result, isNotNull);
      expect(result!.value, equals("User Settings"));
      expect(result.params, equals({"uid": "42"}));
    });

    test("Given an unknown route "
        "When searched "
        "Then no match is found", () {
      final tree = RadixTree<String>()..insert("/home", "Home");

      final result = tree.get("/missing");
      expect(result, isNull);
    });

    test("Given a duplicate static route "
        "When inserted "
        "Then an exception is thrown", () {
      final tree = RadixTree<String>()..insert("/about", "A");
      expect(() => tree.insert("/about", "B"), throwsException);
    });

    test("Given conflicting parameter names "
        "When inserted "
        "Then an exception is thrown", () {
      final tree = RadixTree<String>()..insert("/product/:id", "handler1");
      expect(
        () => tree.insert("/product/:productId", "handler2"),
        throwsException,
      );
    });

    test("Given static and parameter routes "
        "When searched "
        "Then the static route takes priority", () {
      final tree = RadixTree<String>()
        ..insert("/page/:id", "param route")
        ..insert("/page/details", "static route");
      final result = tree.get("/page/details");
      expect(result, isNotNull);
      expect(result!.value, equals("static route"));
    });

    test("Given routes with a shared static prefix "
        "When searched "
        "Then each route resolves correctly", () {
      final tree = RadixTree<String>()
        ..insert("/blog", "Blog Home")
        ..insert("/blog/:slug", "Blog Post");

      final home = tree.get("/blog");
      final post = tree.get("/blog/flutter-tips");

      expect(home!.value, equals("Blog Home"));
      expect(post!.value, equals("Blog Post"));
      expect(post.params, equals({"slug": "flutter-tips"}));
    });

    test("Given a populated tree "
        "When getTreeString is invoked "
        "Then the textual structure is returned", () {
      final tree = RadixTree<String>()
        ..insert("/api/users", "users")
        ..insert("/api/users/:id", "user")
        ..insert("/health", "health");

      final representation = tree.getTreeString();
      expect(representation, contains("api"));
      expect(representation, contains("users"));
      expect(representation, contains(":id"));
      expect(representation, contains("health"));
    });

    group("getLongestLiteralMatch", () {
      test("Given a full path "
          "When finding the longest literal match "
          "Then the exact match is returned", () {
        final tree = RadixTree<String>()..insert("product/:id/details/screen", "Handler A");

        final result = tree.getLongestLiteralMatch(
          "product/:id/details/screen",
        );
        expect(result, isNotNull);
        expect(result!.value, equals("Handler A"));
      });

      test("Given nested literal segments "
          "When searching "
          "Then the deepest matching prefix is returned", () {
        final tree = RadixTree<String>()
          ..insert("product", "Root")
          ..insert("product/:id", "Level 1")
          ..insert("product/:id/details", "Level 2");

        final result = tree.getLongestLiteralMatch(
          "product/:id/details/screen/config",
        );
        expect(result, isNotNull);
        expect(result!.value, equals("Level 2"));
      });

      test("Given only a top-level literal match "
          "When searching "
          "Then that match is returned", () {
        final tree = RadixTree<String>()..insert("product", "Root");

        final result = tree.getLongestLiteralMatch("product/:id/details");
        expect(result, isNotNull);
        expect(result!.value, equals("Root"));
      });

      test("Given a non-matching path "
          "When searching "
          "Then null is returned", () {
        final tree = RadixTree<String>()..insert("home", "Home");

        final result = tree.getLongestLiteralMatch("about/us");
        expect(result, isNull);
      });

      test("Given an empty tree "
          "When searching "
          "Then no longest literal match is found", () {
        final tree = RadixTree<String>();

        final result = tree.getLongestLiteralMatch("any/path/here");
        expect(result, isNull);
      });
    });
  });
}
