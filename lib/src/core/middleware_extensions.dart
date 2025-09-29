import "package:netto/src/core/types.dart";

/// Extensions on [Middleware] to aid in composing [Middleware] and [Handler]s.
///
extension MiddlewareExtensions on Middleware {
  /// Merges `this` and [other] into a new [Middleware].
  Middleware addMiddleware(Middleware other) =>
      (Handler handler) async => this(await other(handler));
}
