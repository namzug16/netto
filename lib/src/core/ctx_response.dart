import "dart:convert";
import "dart:io";

import "package:meta/meta.dart";
import "package:netto/src/core/ctx_extras.dart";

/// Response helper that tracks outgoing data and exposes the shared extras
/// map used by middleware and handlers.
class CtxResponse with CtxExtrasAccessors {
  /// Creates a response helper bound to the provided [HttpRequest].
  CtxResponse(this._request, {Map<String, Object?>? extras}) : _extras = extras ?? <String, Object?>{};

  final HttpRequest _request;
  final Map<String, Object?> _extras;

  /// Shared extras map. Prefer using helpers such as [set] and [get] to
  /// interact with it.
  @override
  Map<String, Object?> get extras => _extras;

  /// Mutable headers for the pending response.
  HttpHeaders get headers => _request.response.headers;

  /// Status code that will be sent when the response is finalized.
  int get statusCode => _status;

  /// Whether the underlying [HttpResponse] has already been written to.
  bool get isCommitted => _committed;

  /// Whether the response body will be omitted when finalized.
  bool get isBodySuppressed => _suppress;

  /// Returns the length of the buffered response body, if any.
  int? get bodyLength => _body?.length;

  //NOTE: Response Setters {{{

  int _status = HttpStatus.ok;
  ContentType? _type;
  // single slot
  List<int>? _body;
  bool _bodyWriterActive = false;
  bool _committed = false;
  bool _suppress = false;

  /// Updates the HTTP status code for the pending response.
  void status(int code) {
    _ensureNotCommitted();
    _status = code;
  }

  /// Sends a binary body optionally overriding [status] and content [type].
  void bytes(List<int> bytes, {int status = HttpStatus.ok, ContentType? type}) {
    _reserveBodyWriter();
    _status = status;
    if (type != null) _type = type;
    _body = List<int>.from(bytes);
  }

  /// Sends a plain-text body encoded with [enc].
  void string(String s, {int status = HttpStatus.ok, Encoding enc = utf8}) {
    _reserveBodyWriter();
    _status = status;
    _type = ContentType("text", "plain", charset: enc.name);
    _body = enc.encode(s);
  }

  /// Sends an HTML body encoded with [enc].
  void html(String html, {int status = HttpStatus.ok, Encoding enc = utf8}) {
    _reserveBodyWriter();
    _status = status;
    _type = ContentType("text", "html", charset: enc.name);
    _body = enc.encode(html);
  }

  /// Serializes [data] as JSON and sends it with the provided [status].
  void json(Object data, {int status = HttpStatus.ok}) {
    _reserveBodyWriter();
    _status = status;
    _type = ContentType.json;
    _body = utf8.encode(jsonEncode(data));
  }

  /// Streams an arbitrary byte [source] directly to the client.
  Future<void> stream(
    Stream<List<int>> source, {
    int status = HttpStatus.ok,
    ContentType? type,
    int? contentLength,
  }) async {
    if (_suppress) {
      throw StateError("Response body suppressed");
    }

    _reserveBodyWriter();

    _status = status;
    if (type != null) _type = type;

    final res = _request.response..statusCode = _status;
    if (_type != null) res.headers.contentType = _type;

    if (contentLength != null) {
      res.headers.set(HttpHeaders.contentLengthHeader, contentLength);
    } else {
      res.headers.chunkedTransferEncoding = true;
    }

    res.bufferOutput = false;

    _committed = true;

    try {
      await res.flush();
      await for (final chunk in source) {
        if (chunk.isEmpty) continue;
        res.add(chunk);
        await res.flush();
      }
    } finally {
      await res.close();
    }
  }

  // }}}

  //NOTE: Common Response {{{

  /// Sends a 204 response with no body.
  void noContent() {
    _ensureNotCommitted();
    _status = HttpStatus.noContent;
    _suppress = true;
  }

  /// Sends a 400 Bad Request response with an optional [message].
  void badRequest([String message = "Bad Request"]) => string(message, status: HttpStatus.badRequest);

  /// Sends a 401 Unauthorized response with an optional [message].
  void unauthorized([String message = "Unauthorized"]) => string(message, status: HttpStatus.unauthorized);

  /// Sends a 403 Forbidden response with an optional [message].
  void forbidden([String message = "Forbidden"]) => string(message, status: HttpStatus.forbidden);

  /// Sends a 404 Not Found response with an optional [message].
  void notFound([String message = "Not Found"]) => string(message, status: HttpStatus.notFound);

  /// Sends a 409 Conflict response with an optional [message].
  void conflict([String message = "Conflict"]) => string(message, status: HttpStatus.conflict);

  /// Sends a 410 Gone response with an optional [message].
  void gone([String message = "Gone"]) => string(message, status: HttpStatus.gone);

  /// Sends a 500 Internal Server Error response with an optional [message].
  void internalServerError([String message = "Internal Server Error"]) => string(message, status: HttpStatus.internalServerError);

  /// 201 Created with optional body and Location header.
  /// Provide either [jsonBody] or [textBody], not both.
  void created(String location, {Object? jsonBody, String? textBody}) {
    _ensureNotCommitted();
    headers.set(HttpHeaders.locationHeader, location);
    if (jsonBody != null && textBody != null) {
      throw ArgumentError("Provide only one of jsonBody or textBody.");
    }
    if (jsonBody != null) {
      json(jsonBody, status: HttpStatus.created);
    } else if (textBody != null) {
      string(textBody, status: HttpStatus.created);
    } else {
      // No body, just status + header.
      _status = HttpStatus.created;
      _reserveBodyWriter();
      _body = _emptyBody;
    }
  }

  // }}}

  //NOTE: Redirects {{{

  /// Sends a 301 redirect to [location].
  void movedPermanently(String location) => _redirect(location, HttpStatus.movedPermanently);

  /// Sends a 302 redirect to [location].
  void found(String location) => _redirect(location, HttpStatus.found);

  /// Sends a 303 redirect to [location].
  void seeOther(String location) => _redirect(location, HttpStatus.seeOther);

  /// Sends a 307 redirect to [location].
  void temporaryRedirect(String location) => _redirect(location, HttpStatus.temporaryRedirect);

  /// Sends a 308 redirect to [location].
  void permanentRedirect(String location) => _redirect(location, HttpStatus.permanentRedirect);

  /// Generic redirect helper. Defaults to 302 Found.
  void redirect(String location, {int status = HttpStatus.found}) => _redirect(location, status);

  /// Applies a redirect status and Location header.
  void _redirect(String location, int code) {
    _ensureNotCommitted();
    _status = code;
    headers.set(HttpHeaders.locationHeader, location);
    // Spec allows a small body, but safest default is to suppress.
    _suppress = true;
  }

  // }}}

  @internal
  /// Prevents any response body from being written (used for HEAD requests).
  void suppressBody() {
    _suppress = true;
  }

  /// Flushes pending headers/body to the underlying [HttpResponse].
  Future<void> finalize() async {
    if (_committed) return;
    _committed = true;

    final res = _request.response..statusCode = _status;

    if (_type != null) res.headers.contentType = _type;

    final hasContentLength = res.headers.value(HttpHeaders.contentLengthHeader) != null;

    if (_suppress || _status == HttpStatus.noContent || _status == HttpStatus.notModified) {
      if (!hasContentLength) {
        res.headers.set(HttpHeaders.contentLengthHeader, "0");
      }
      await res.close();
      return;
    }

    final body = _body;
    if (body != null) {
      res.headers.set(HttpHeaders.contentLengthHeader, body.length);
      res.add(body);
      await res.close();
      return;
    }

    if (!hasContentLength) {
      res.headers.set(HttpHeaders.contentLengthHeader, "0");
    }
    await res.close();
  }

  /// Throws if the response has already been finalized or a body writer is active.
  void _ensureNotCommitted() {
    if (_committed) throw StateError("Response already finalized");
    if (_bodyWriterActive) throw StateError("Response body already set");
  }

  /// Marks the response as having an in-memory body, preventing duplicates.
  void _reserveBodyWriter() {
    if (_committed) throw StateError("Response already finalized");
    if (_bodyWriterActive) throw StateError("Response body already set");
    _bodyWriterActive = true;
  }
}

const List<int> _emptyBody = <int>[];
