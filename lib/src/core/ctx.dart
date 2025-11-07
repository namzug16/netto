import "dart:io";

import "package:netto/src/core/ctx_extras.dart";
import "package:netto/src/core/ctx_request.dart";
import "package:netto/src/core/ctx_response.dart";

/// Request context shared between middleware and handlers.
class Ctx with CtxExtrasAccessors {
  /// Creates a context wrapper for an [HttpRequest] and related response.
  Ctx(HttpRequest request) : extras = <String, Object?>{} {
    this.request = CtxRequest(request);
    response = CtxResponse(request);
  }

  /// Mutable bag for sharing data between middleware and handlers.
  @override
  final Map<String, Object?> extras;

  /// Encapsulated HTTP request with helpers and shared extras.
  late final CtxRequest request;

  /// Response helper tied to the current request lifecycle.
  late final CtxResponse response;
}
