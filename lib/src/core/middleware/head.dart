import "dart:async";

import "package:netto/src/core/ctx.dart";
import "package:netto/src/core/types.dart";

/// Middleware used to suppress response bodies for HEAD requests after
/// the underlying handler completes.
Middleware headResponseMiddleware() {
  return (Handler next) async {
    return (Ctx ctx) async {
      await Future.sync(() => next(ctx));
      ctx.response.suppressBody();
    };
  };
}
