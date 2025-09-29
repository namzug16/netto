import "dart:async";

import "package:netto/src/core/ctx.dart";
import "package:netto/src/core/middleware/head.dart";
import "package:netto/src/core/middleware_extensions.dart";
import "package:netto/src/core/router/builder.dart";
import "package:netto/src/core/types.dart";

/// Holds the handler and middleware context for a concrete route.
class RouteNode {
  /// Creates a route node bound to a handler and originating [builder].
  RouteNode(this.handler, this.builder);

  /// Handler registered for the route.
  Handler? handler;
  //NOTE: we store a reference to the builder in order to extract the
  // most updated middleware
  /// Builder that produced the route, used to access middleware.
  Builder builder;

  /// Executes the handler associated with the route using [ctx] and [params].
  Future<void> invoke(Ctx ctx, Map<String, String> params) async {
    if (handler == null) return;

    final middleware = builder.middleware;
    if (middleware != null) {
      final effectiveMiddleware = middleware;
      final requestMethod = ctx.request.method.toUpperCase();
      if (requestMethod == "HEAD") {
        final headMiddleware = headResponseMiddleware().addMiddleware(
          effectiveMiddleware,
        );
        return (await headMiddleware(handler!))(ctx);
      }
      return (await effectiveMiddleware(handler!))(ctx);
    }

    return handler!(ctx);
  }
}
