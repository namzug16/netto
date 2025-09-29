import "dart:async";
import "dart:io";

import "package:meta/meta.dart";
import "package:netto/src/core/ctx_extras.dart";
import "package:netto/src/core/ctx_request_body.dart";
import "package:netto/src/core/hijack_exception.dart";

/// Wrapper around [HttpRequest] offering convenient access to request data
/// and the shared contextual extras map.
class CtxRequest with CtxExtrasAccessors {
  /// Creates a wrapper around the incoming [HttpRequest].
  CtxRequest(
    this._request, {
    bool enableHijack = true,
    Map<String, Object?>? extras,
  }) : _canHijack = enableHijack,
       _extras = extras ?? <String, Object?>{} {
    body = CtxRequestBody(this, _request);
  }

  final HttpRequest _request;
  final bool _canHijack;
  bool _hijacked = false;
  final Map<String, Object?> _extras;

  /// Shared extras map. Prefer using helpers such as [set] and [get] to
  /// interact with it.
  @override
  Map<String, Object?> get extras => _extras;

  /// Populated by the router via [updatePathParameters].
  Map<String, String> get pathParameters => _pathParameters;
  Map<String, String> _pathParameters = {};

  @internal
  /// Updates the cached path parameters when a route matches.
  // ignore: use_setters_to_change_properties
  void updatePathParameters(Map<String, String> params) {
    _pathParameters = params;
  }

  /// Retrieves a path parameter based on a key.
  /// In case, no path parameter is available, it returns an empty string.
  String pathParameter(String key) => pathParameters[key] ?? "";

  /// Helper exposing lazy parsing utilities for the request body.
  late final CtxRequestBody body;

  // Internal Caches
  Map<String, List<String>>? _headersLower;
  Map<String, String>? _cookiesMap;

  // Basics
  /// HTTP method of the incoming request.
  String get method => _request.method;

  /// Full request URI including query parameters.
  Uri get uri => _request.uri;

  /// Path component of the request URI.
  String get path => _request.uri.path;

  /// All query parameters with all values preserved.
  Map<String, List<String>> get queryParameters => Map.unmodifiable(_request.uri.queryParametersAll);

  /// Whether this request can currently be hijacked.
  bool get canHijack => _canHijack && !_hijacked;

  /// Whether the request has already been hijacked.
  bool get isHijacked => _hijacked;

  /// Access to the underlying [HttpRequest].
  HttpRequest get raw => _request;

  /// Hands control of the underlying [HttpRequest] to [callback].
  ///
  /// Once hijacked the regular response lifecycle is bypassed and a
  /// [HijackException] is thrown to signal the server to stop processing the
  /// request. Attempting to hijack an ineligible or already hijacked request
  /// throws a [StateError].
  Never hijack(FutureOr<void> Function(HttpRequest request) callback) {
    if (!_canHijack) {
      throw StateError("This request cannot be hijacked.");
    }
    if (_hijacked) {
      throw StateError("This request has already been hijacked.");
    }

    _hijacked = true;
    final result = callback(_request);
    if (result is Future) {
      unawaited(result);
    }

    throw const HijackException();
  }

  // Headers & cookies
  /// Lowercased header names; values are unmodifiable lists.
  Map<String, List<String>> get headers {
    final cached = _headersLower;
    if (cached != null) return cached;

    final map = <String, List<String>>{};
    _request.headers.forEach((name, values) {
      final key = name.toLowerCase();
      map[key] = List.unmodifiable(List<String>.from(values));
    });
    _headersLower = Map.unmodifiable(map);
    return _headersLower!;
  }

  /// First value of a header (case-insensitive) or null.
  String? header(String name) {
    final vals = headers[name.toLowerCase()];
    return (vals == null || vals.isEmpty) ? null : vals.first;
  }

  /// Parsed cookies (first value wins on duplicate names).
  Map<String, String> get cookies {
    final c = _cookiesMap;
    if (c != null) return c;

    final map = <String, String>{};
    for (final ck in _request.cookies) {
      map.putIfAbsent(ck.name, () => ck.value);
    }
    _cookiesMap = Map.unmodifiable(map);
    return _cookiesMap!;
  }

  /// Looks up a cookie value by [name], if present.
  String? cookie(String name) => cookies[name];

  // Meta
  /// Declared content length of the request, if known.
  int? get contentLength {
    // -1 if unknown/chunked
    final len = _request.contentLength;
    return (len >= 0) ? len : null;
  }

  /// Parsed content type header.
  ContentType? get contentType => _request.headers.contentType;

  /// Remote address associated with the underlying socket, if available.
  InternetAddress? get remoteAddress => _request.connectionInfo?.remoteAddress;

  /// Whether the request is served over HTTPS (directly or inferred).
  bool get isHttps {
    // Best-effort: scheme or X-Forwarded-Proto (behind proxies).
    if (_request.uri.scheme.toLowerCase() == "https") return true;
    final xfProto = header("x-forwarded-proto");
    return xfProto != null && xfProto.toLowerCase() == "https";
  }

  /// Value of the `Host` header, if provided.
  String? get host => header(HttpHeaders.hostHeader);

  /// Reported user agent string, if provided.
  String? get userAgent => header(HttpHeaders.userAgentHeader);

  // Negotiation helpers (minimal)
  /// Returns true if the `Accept` header allows the provided [mime] type.
  bool accepts(String mime) {
    final accept = header("accept");
    if (accept == null || accept.trim().isEmpty) return true; // no preference
    final offered = mime.toLowerCase();
    final slash = offered.indexOf("/");
    if (slash <= 0) return false;
    final oType = offered.substring(0, slash);
    final oSub = offered.substring(slash + 1);

    final items = accept.toLowerCase().split(",");
    for (final raw in items) {
      final item = raw.split(";").first.trim(); // drop params like ;q=0.8
      if (item == "*/*") return true;
      final iSlash = item.indexOf("/");
      if (iSlash <= 0) continue;
      final aType = item.substring(0, iSlash).trim();
      final aSub = item.substring(iSlash + 1).trim();
      if (aType == oType && (aSub == "*" || aSub == oSub)) return true;
    }
    return false;
  }

  /// Returns the best match from [mimes] based on Accept (very small impl).
  /// If no Accept header, returns the first offered.
  String? bestMatch(Iterable<String> mimes) {
    final accept = header("accept");
    if (accept == null || accept.trim().isEmpty) {
      return mimes.isEmpty ? null : mimes.first;
    }

    final accepted = _parseAccept(accept);
    double bestQ = -1;
    // 2 exact, 1 type/*, 0 */*
    int bestSpecificity = -1;
    int bestIndex = 1 << 30;
    String? best;

    var idx = 0;
    for (final offered in mimes) {
      final o = offered.toLowerCase();
      final slash = o.indexOf("/");
      if (slash <= 0) {
        idx++;
        continue;
      }
      final oType = o.substring(0, slash);
      final oSub = o.substring(slash + 1);

      for (final a in accepted) {
        final spec = _specificity(a.type, a.sub, oType, oSub);
        // no match
        if (spec < 0) continue;
        // Rank by q, then specificity, then offered order (stable).
        if (a.q > bestQ || (a.q == bestQ && (spec > bestSpecificity || (spec == bestSpecificity && idx < bestIndex)))) {
          bestQ = a.q;
          bestSpecificity = spec;
          bestIndex = idx;
          best = offered;
        }
      }
      idx++;
    }
    return best;
  }

  bool get isJson {
    final ct = contentType;
    if (ct == null) return false;
    final pt = ct.primaryType.toLowerCase();
    final st = ct.subType.toLowerCase();
    return pt == "application" && (st == "json" || st.endsWith("+json"));
  }

  bool get isFormUrlencoded {
    final ct = contentType;
    if (ct == null) return false;
    return ct.primaryType.toLowerCase() == "application" && ct.subType.toLowerCase() == "x-www-form-urlencoded";
  }

  bool get isMultipart {
    final ct = contentType;
    if (ct == null) return false;
    return ct.primaryType.toLowerCase() == "multipart" && ct.subType.toLowerCase() == "form-data";
  }

  // helpers for Accept parsing
  /// Parses the Accept header into sortable entries.
  static List<_AcceptItem> _parseAccept(String header) {
    final items = <_AcceptItem>[];
    final parts = header.split(",");
    var order = 0;
    for (final p in parts) {
      final seg = p.trim();
      if (seg.isEmpty) continue;
      final semi = seg.split(";");
      final mime = semi.first.trim().toLowerCase();
      double q = 1;
      for (var i = 1; i < semi.length; i++) {
        final kv = semi[i].split("=");
        if (kv.length == 2 && kv[0].trim() == "q") {
          final v = double.tryParse(kv[1].trim());
          if (v != null) q = v;
        }
      }
      final slash = mime.indexOf("/");
      if (slash <= 0) continue;
      items.add(
        _AcceptItem(
          type: mime.substring(0, slash),
          sub: mime.substring(slash + 1),
          q: q,
          order: order++,
        ),
      );
    }
    return items;
  }

  /// Returns how specific an Accept entry is relative to an offered mime.
  static int _specificity(
    String aType,
    String aSub,
    String oType,
    String oSub,
  ) {
    if (aType == "*") return (aSub == "*") ? 0 : -1;
    // */* matches any
    if (aType != oType) return -1;
    // type/* matches subtype
    if (aSub == "*") return 1;
    // exact
    return (aSub == oSub) ? 2 : -1;
  }
}

/// Parsed representation of a single Accept header entry.
class _AcceptItem {
  const _AcceptItem({
    required this.type,
    required this.sub,
    required this.q,
    required this.order,
  });

  /// Media type portion of the entry.
  final String type;

  /// Media subtype portion of the entry.
  final String sub;

  /// Quality factor associated with the entry.
  final double q;

  /// Original order in the header (used as a tiebreaker).
  final int order;
}
