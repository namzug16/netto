import "dart:async";
import "dart:io";

import "package:netto/src/core/ctx.dart";
import "package:netto/src/core/middleware/head.dart";
import "package:netto/src/core/middleware_extensions.dart";
import "package:netto/src/core/router/group.dart";
import "package:netto/src/core/router/router.dart";
import "package:netto/src/core/types.dart";
import "package:netto/src/server/serve.dart" as server;

/// Primary entry-point combining router, middleware, and server integration.
class Netto {
  /// Creates a Netto application with a fresh router instance.
  Netto() : router = Router();

  /// Root router instance used to register routes and middleware.
  final Router router;

  Handler? _notFoundHandler;
  ErrorHandler? _errorHandler;

  /// Handler executed when no route matches.
  Handler get notFoundHandler => _notFoundHandler ?? _defaultNotFound;

  /// Overrides the handler used when no route matches the request.
  set notFoundHandler(Handler handler) => _notFoundHandler = handler;

  /// Handler executed when an uncaught [HttpException] escapes a route.
  ErrorHandler get errorHandler => _errorHandler ?? _defaultErrorHandler;

  /// Overrides the handler used for uncaught [HttpException]s.
  set errorHandler(ErrorHandler handler) => _errorHandler = handler;

  /// Root middleware chain applied to every request.
  Middleware? get middleware => router.middleware;

  /// Creates a sub-router with optional [prefix] and [middleware].
  Group group(String? prefix, [Middleware? middleware]) => router.group(prefix, middleware);

  /// Adds router-level middleware.
  void use(Middleware middleware) => router.use(middleware);

  /// Registers a handler for an HTTP [verb] at [route].
  void add(String verb, String route, Handler handler) => router.add(verb, route, handler);

  /// Registers a GET handler.
  void get(String route, Handler handler) => router.get(route, handler);

  /// Registers a HEAD handler.
  void head(String route, Handler handler) => router.head(route, handler);

  /// Registers a POST handler.
  void post(String route, Handler handler) => router.post(route, handler);

  /// Registers a PUT handler.
  void put(String route, Handler handler) => router.put(route, handler);

  /// Registers a DELETE handler.
  void delete(String route, Handler handler) => router.delete(route, handler);

  /// Registers a CONNECT handler.
  void connect(String route, Handler handler) => router.connect(route, handler);

  /// Registers an OPTIONS handler.
  void options(String route, Handler handler) => router.options(route, handler);

  /// Registers a TRACE handler.
  void trace(String route, Handler handler) => router.trace(route, handler);

  /// Registers a PATCH handler.
  void patch(String route, Handler handler) => router.patch(route, handler);

  /// Serves every file under [root] through routes prefixed by [prefix].
  void static(String prefix, String root) => router.static(prefix, root);

  /// Serves a single file located at [filePath] under the route [path].
  void file(String path, String filePath) => router.file(path, filePath);

  /// Spins up an [HttpServer] that delegates requests to this instance.
  Future<HttpServer> serve(
    Object address,
    int port, {
    SecurityContext? securityContext,
    int backlog = 0,
    bool shared = false,
    bool suppressBanner = false,
  }) {
    return server.serve(
      call,
      address,
      port,
      securityContext: securityContext,
      backlog: backlog,
      shared: shared,
      suppressBanner: suppressBanner,
    );
  }

  /// Dispatches an incoming request to the matching route.
  Future<void> call(Ctx ctx) async {
    final result = router.resolve(ctx.request.method, ctx.request.uri.path);

    if (result == null) {
      final allowedMethods = router.allowedMethods(ctx.request.uri.path);
      if (allowedMethods.isNotEmpty) {
        await _dispatchWithMiddleware(ctx, (Ctx innerCtx) {
          innerCtx.response.headers.set(
            HttpHeaders.allowHeader,
            allowedMethods.join(", "),
          );
          innerCtx.response.string(
            "Method Not Allowed",
            status: HttpStatus.methodNotAllowed,
          );
        }, router.middleware);
        return;
      }

      await _dispatchWithMiddleware(ctx, notFoundHandler, router.middleware);
      return;
    }

    ctx.request.updatePathParameters(result.params);

    final handler = result.value.handler;
    if (handler == null) {
      return;
    }

    await _dispatchWithMiddleware(
      ctx,
      handler,
      result.value.builder.middleware,
    );
  }

  /// Applies middleware around [handler] and executes it.
  Future<void> _dispatchWithMiddleware(
    Ctx ctx,
    Handler handler,
    Middleware? middleware,
  ) async {
    final resolvedMiddleware = _resolveMiddleware(ctx, middleware);
    final wrapped = _wrapHandler(handler);

    if (resolvedMiddleware == null) {
      await _executeHandler(ctx, wrapped);
      return;
    }

    final resolvedHandler = await resolvedMiddleware(wrapped);
    await _executeHandler(ctx, resolvedHandler);
  }

  /// Resolves head-specific middleware adjustments when necessary.
  Middleware? _resolveMiddleware(Ctx ctx, Middleware? middleware) {
    if (middleware == null) {
      return null;
    }

    final effectiveMiddleware = middleware;

    if (ctx.request.method.toUpperCase() == "HEAD") {
      return headResponseMiddleware().addMiddleware(effectiveMiddleware);
    }

    return effectiveMiddleware;
  }

  /// Wraps handlers to surface errors through the configured error handler.
  Handler _wrapHandler(Handler handler) {
    return (Ctx ctx) async {
      try {
        await Future.sync(() => handler(ctx));
      } on HttpException catch (error) {
        _markErrorHandled(ctx);
        await _invokeErrorHandler(ctx, error);
        rethrow;
      } catch (error, stackTrace) {
        _markErrorHandled(ctx);
        await _invokeErrorHandler(
          ctx,
          HttpExceptionWithStatus(
            status: HttpStatus.internalServerError,
            message: "Internal Server Error",
            meta: {"error": error.toString()},
            stackTrace: stackTrace,
          ),
        );
        Error.throwWithStackTrace(error, stackTrace);
      }
    };
  }

  /// Executes [handler] and rethrows errors unless already handled.
  Future<void> _executeHandler(Ctx ctx, Handler handler) async {
    try {
      await Future.sync(() => handler(ctx));
    } catch (error, stackTrace) {
      if (!_consumeHandledError(ctx)) {
        Error.throwWithStackTrace(error, stackTrace);
      }
    }
  }

  /// Invokes the configured error handler while guarding against failures.
  Future<void> _invokeErrorHandler(Ctx ctx, HttpException error) async {
    try {
      await Future.sync(() => errorHandler(ctx, error));
      //
      // ignore: avoid_catches_without_on_clauses
    } catch (handlerError, handlerStackTrace) {
      stderr.writeln("Error handler threw an exception: $handlerError");
      if (handlerStackTrace != StackTrace.empty) {
        stderr.writeln(handlerStackTrace);
      }
      await _fallbackErrorResponse(ctx);
    }
  }

  /// Provides a best-effort fallback response when the error handler fails.
  Future<void> _fallbackErrorResponse(Ctx ctx) async {
    if (ctx.request.isHijacked) {
      return;
    }

    try {
      if (!ctx.response.isCommitted && ctx.response.bodyLength == null) {
        ctx.response.internalServerError();
      }
      //
      // ignore: avoid_catching_errors
    } on StateError catch (error, stackTrace) {
      stderr.writeln("Failed to prepare fallback 500 response: $error");
      if (stackTrace != StackTrace.empty) {
        stderr.writeln(stackTrace);
      }
    }

    try {
      await ctx.response.finalize();
      //
      // ignore: avoid_catches_without_on_clauses
    } catch (error, stackTrace) {
      stderr.writeln(
        "Failed to finalize response after error handler failure: $error",
      );
      if (stackTrace != StackTrace.empty) {
        stderr.writeln(stackTrace);
      }
    }
  }

  /// Marks that an error has already been reported to the error handler.
  void _markErrorHandled(Ctx ctx) {
    ctx.extras[_handledErrorFlag] = true;
  }

  /// Returns whether the error associated with [ctx] has already been handled.
  bool _consumeHandledError(Ctx ctx) {
    final handled = ctx.extras.remove(_handledErrorFlag);
    return handled == true;
  }
}

/// Default 404 handler that writes a textual response.
Future<void> _defaultNotFound(Ctx ctx) async => ctx.response.notFound("Route not found");

/// Default error handler that mirrors the [HttpException] into the response.
Future<void> _defaultErrorHandler(Ctx ctx, HttpException error) async {
  ctx.response.string(error.message, status: error.status);
}

/// Marker stored in [Ctx.extras] to signal that an error was handled.
const _handledErrorFlag = "__netto.errorHandled";
