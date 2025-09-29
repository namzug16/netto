// coverage:ignore-file

import "dart:async";
import "dart:io";

import "package:netto/src/core/ctx.dart";

/// Signature for route handlers.
typedef Handler = FutureOr<void> Function(Ctx ctx);

/// Signature for error handlers triggered by uncaught [HttpException]s.
typedef ErrorHandler = FutureOr<void> Function(Ctx ctx, HttpException error);

/// Signature for middleware that transforms a downstream [Handler].
typedef Middleware = FutureOr<Handler> Function(Handler next);

/// Minimal HTTP exception hierarchy with common helpers.
sealed class HttpException implements Exception {
  /// Creates a generic [HttpException] with the provided [status] and [message].
  factory HttpException(
    int status,
    String message, [
    Map<String, dynamic>? meta,
  ]) => HttpExceptionWithStatus(status: status, message: message, meta: meta);

  HttpException._({
    required this.status,
    required this.message,
    this.meta,
    StackTrace? stackTrace,
  }) : stackTrace = stackTrace ?? StackTrace.current;

  /// A convenience constructor for 400 Bad Request errors.
  static HttpException badRequest({
    String message = "Bad Request",
    Map<String, dynamic>? meta,
  }) => HttpExceptionBadRequest(message: message, meta: meta);

  /// A convenience constructor for 401 Unauthorized errors.
  static HttpException unauthorized({
    String message = "Unauthorized",
    Map<String, dynamic>? meta,
  }) => HttpExceptionUnauthorized(message: message, meta: meta);

  /// A convenience constructor for 403 Forbidden errors.
  static HttpException forbidden({
    String message = "Forbidden",
    Map<String, dynamic>? meta,
  }) => HttpExceptionForbidden(message: message, meta: meta);

  /// A convenience constructor for 404 Not Found errors.
  static HttpException notFound({
    String message = "Not Found",
    Map<String, dynamic>? meta,
  }) => HttpExceptionNotFound(message: message, meta: meta);

  /// A convenience constructor for 405 Method Not Allowed errors.
  static HttpException methodNotAllowed({
    String message = "Method Not Allowed",
    Map<String, dynamic>? meta,
  }) => HttpExceptionMethodNotAllowed(message: message, meta: meta);

  /// A convenience constructor for 409 Conflict errors.
  static HttpException conflict({
    String message = "Conflict",
    Map<String, dynamic>? meta,
  }) => HttpExceptionConflict(message: message, meta: meta);

  /// A convenience constructor for 413 Payload Too Large errors.
  static HttpException payloadTooLarge({
    String message = "Payload Too Large",
    Map<String, dynamic>? meta,
  }) => HttpExceptionPayloadTooLarge(message: message, meta: meta);

  /// A convenience constructor for 415 Unsupported Media Type errors.
  static HttpException unsupportedMediaType({
    String message = "Unsupported Media Type",
    Map<String, dynamic>? meta,
  }) => HttpExceptionUnsupportedMediaType(message: message, meta: meta);

  /// A convenience constructor for 422 Unprocessable Entity errors.
  static HttpException unprocessableEntity({
    String message = "Unprocessable Entity",
    Map<String, dynamic>? meta,
  }) => HttpExceptionUnprocessableEntity(message: message, meta: meta);

  /// A convenience constructor for 500 Internal Server Error errors.
  static HttpException internalServerError({
    String message = "Internal Server Error",
    Map<String, dynamic>? meta,
  }) => HttpExceptionInternalServerError(message: message, meta: meta);

  /// Status code associated with this HTTP exception.
  final int status;

  /// Human-readable description of the error.
  final String message;

  /// Captured stack trace at instantiation time.
  final StackTrace stackTrace;

  /// Optional metadata associated with the error.
  final Map<String, dynamic>? meta;

  @override
  String toString() => "HttpException($status): $message";
}

/// A generic [HttpException] for an arbitrary status code.
class HttpExceptionWithStatus extends HttpException {
  /// Creates an exception representing an arbitrary HTTP status code.
  HttpExceptionWithStatus({
    required super.status,
    required super.message,
    super.meta,
    super.stackTrace,
  }) : super._();
}

/// 400 Bad Request.
class HttpExceptionBadRequest extends HttpException {
  /// Creates a 400 Bad Request exception.
  HttpExceptionBadRequest({super.message = "Bad Request", super.meta}) : super._(status: HttpStatus.badRequest);
}

/// 401 Unauthorized.
class HttpExceptionUnauthorized extends HttpException {
  /// Creates a 401 Unauthorized exception.
  HttpExceptionUnauthorized({super.message = "Unauthorized", super.meta}) : super._(status: HttpStatus.unauthorized);
}

/// 403 Forbidden.
class HttpExceptionForbidden extends HttpException {
  /// Creates a 403 Forbidden exception.
  HttpExceptionForbidden({super.message = "Forbidden", super.meta}) : super._(status: HttpStatus.forbidden);
}

/// 404 Not Found.
class HttpExceptionNotFound extends HttpException {
  /// Creates a 404 Not Found exception.
  HttpExceptionNotFound({super.message = "Not Found", super.meta}) : super._(status: HttpStatus.notFound);
}

/// 405 Method Not Allowed.
class HttpExceptionMethodNotAllowed extends HttpException {
  /// Creates a 405 Method Not Allowed exception.
  HttpExceptionMethodNotAllowed({
    super.message = "Method Not Allowed",
    super.meta,
  }) : super._(status: HttpStatus.methodNotAllowed);
}

/// 409 Conflict.
class HttpExceptionConflict extends HttpException {
  /// Creates a 409 Conflict exception.
  HttpExceptionConflict({super.message = "Conflict", super.meta}) : super._(status: HttpStatus.conflict);
}

/// 413 Payload Too Large.
class HttpExceptionPayloadTooLarge extends HttpException {
  /// Creates a 413 Payload Too Large exception.
  HttpExceptionPayloadTooLarge({
    super.message = "Payload Too Large",
    super.meta,
  }) : super._(status: HttpStatus.requestEntityTooLarge);
}

/// 415 Unsupported Media Type.
class HttpExceptionUnsupportedMediaType extends HttpException {
  /// Creates a 415 Unsupported Media Type exception.
  HttpExceptionUnsupportedMediaType({
    super.message = "Unsupported Media Type",
    super.meta,
  }) : super._(status: HttpStatus.unsupportedMediaType);
}

/// 422 Unprocessable Entity.
class HttpExceptionUnprocessableEntity extends HttpException {
  /// Creates a 422 Unprocessable Entity exception.
  HttpExceptionUnprocessableEntity({
    super.message = "Unprocessable Entity",
    super.meta,
  }) : super._(status: HttpStatus.unprocessableEntity);
}

/// 500 Internal Server Error.
class HttpExceptionInternalServerError extends HttpException {
  /// Creates a 500 Internal Server Error exception.
  HttpExceptionInternalServerError({
    super.message = "Internal Server Error",
    super.meta,
  }) : super._(status: HttpStatus.internalServerError);
}
