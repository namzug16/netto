import "dart:async";
import "dart:convert";
import "dart:io";

import "package:logging/logging.dart";

import "package:netto/src/core/ctx.dart";
import "package:netto/src/core/ctx_request.dart";
import "package:netto/src/core/ctx_response.dart";
import "package:netto/src/core/types.dart";

/// Callback that decides whether logging should be skipped for the request.
typedef LogSkipper = bool Function(Ctx ctx);

/// Produces a custom tag value for the serialized log output.
typedef CustomTagCallback = String? Function(LoggerEvent event);

/// Configuration object for the structured logging middleware.
///
/// The configuration exposes custom formatting, filtering, and logging
/// behaviour while still providing sensible defaults for quick usage.
class LoggerConfig {
  /// Creates logging middleware configuration with optional overrides.
  LoggerConfig({
    LogSkipper? skipper,
    String? format,
    this.customTimeFormat = _defaultCustomTimeFormat,
    this.customTag,
    Logger? logger,
    this.level = Level.INFO,
    DateTime Function()? clock,
  }) : skipper = skipper ?? _defaultSkipper,
       format = format ?? _defaultFormat,
       logger = logger ?? Logger("netto.middleware.logger"),
       now = clock ?? DateTime.now;

  /// Predicate that determines whether to skip logging for the request.
  final LogSkipper skipper;

  /// Template used to render the log message.
  final String format;

  /// Formatting pattern used by the `time_custom` tag.
  final String customTimeFormat;

  /// Hook for injecting additional structured data.
  final CustomTagCallback? customTag;

  /// The [Logger] instance that receives the log message.
  final Logger logger;

  /// Minimum level required for a message to be emitted.
  final Level level;

  /// Clock function used for latency calculation and timestamp rendering.
  final DateTime Function() now;
}

/// Tracks whether the root logger print listener has been configured.
bool _defaultLoggerOutputInitialized = false;

/// Lazily attaches a basic print listener to the root logger.
void _ensureDefaultLoggerOutput() {
  if (_defaultLoggerOutputInitialized) {
    return;
  }
  _defaultLoggerOutputInitialized = true;
  Logger.root.onRecord.listen((record) {
    //
    // ignore: avoid_print
    print("${record.level.name}: ${record.time}: ${record.message}");
  });
}

/// Returns middleware that logs request and response information.
Middleware logger() {
  _ensureDefaultLoggerOutput();
  return loggerWithConfig(LoggerConfig());
}

/// Returns middleware that logs request and response information using [config].
Middleware loggerWithConfig(LoggerConfig config) {
  return (Handler next) {
    return (Ctx ctx) async {
      if (config.skipper(ctx)) {
        await Future.sync(() => next(ctx));
        return;
      }

      final start = config.now();
      Object? caughtError;
      StackTrace? caughtStackTrace;
      try {
        await Future.sync(() => next(ctx));
        //
        // ignore: avoid_catches_without_on_clauses
      } catch (error, stackTrace) {
        caughtError = error;
        caughtStackTrace = stackTrace;
      }

      final end = config.now();
      final latency = end.difference(start);
      final event = LoggerEvent._(
        ctx: ctx,
        start: start,
        end: end,
        latency: latency,
        status: ctx.response.statusCode,
        bytesIn: ctx.request.contentLength,
        bytesOut: _resolveBytesOut(ctx.response),
        error: caughtError,
        stackTrace: caughtStackTrace,
      );

      if (config.logger.isLoggable(config.level)) {
        final message = _renderFormat(config.format, config, event);
        if (message.isNotEmpty) {
          config.logger.log(
            config.level,
            message,
            caughtError,
            caughtStackTrace,
          );
        }
      }

      if (caughtError != null) {
        Error.throwWithStackTrace(caughtError, caughtStackTrace!);
      }
    };
  };
}

/// Immutable snapshot of request/response metadata passed to formatting hooks.
class LoggerEvent {
  LoggerEvent._({
    required this.ctx,
    required this.start,
    required this.end,
    required this.latency,
    required this.status,
    required this.bytesIn,
    required this.bytesOut,
    this.error,
    this.stackTrace,
  }) : request = ctx.request.raw,
       response = ctx.response;

  /// Context for the in-flight request.
  final Ctx ctx;

  /// Underlying [HttpRequest] for additional inspection.
  final HttpRequest request;

  /// Wrapped response helper associated with the request.
  final CtxResponse response;

  /// Timestamp captured before invoking the handler.
  final DateTime start;

  /// Timestamp captured after the handler completes.
  final DateTime end;

  /// Duration between [start] and [end].
  final Duration latency;

  /// Response status code observed when logging.
  final int status;

  /// Bytes reported as incoming (may be `null` for chunked requests).
  final int? bytesIn;

  /// Bytes written to the response.
  final int bytesOut;

  /// Error thrown by the handler, if any.
  final Object? error;

  /// Stack trace associated with [error].
  final StackTrace? stackTrace;
}

/// JSON log template used when no custom format is provided.
const String _defaultFormat =
    '{"time":"\${time_rfc3339_nano}","id":"\${id}","remote_ip":"\${remote_ip}","host":"\${host}","method":"\${method}","uri":"\${uri}","user_agent":"\${user_agent}","status":\${status},"error":"\${error}","latency":\${latency},"latency_human":"\${latency_human}","bytes_in":\${bytes_in},"bytes_out":\${bytes_out}}\n';

/// Default pattern applied when using the `time_custom` token.
const String _defaultCustomTimeFormat = "yyyy-MM-dd HH:mm:ss.SSSSS";

/// Default skipper that logs every request.
bool _defaultSkipper(Ctx _) => false;

/// Matches `${token}` placeholders inside the log template.
final RegExp _tokenPattern = RegExp(r"\$\{([^}]+)\}");

/// Renders the configured format string using data from [event].
String _renderFormat(String format, LoggerConfig config, LoggerEvent event) {
  final buffer = StringBuffer();
  var index = 0;
  for (final match in _tokenPattern.allMatches(format)) {
    buffer.write(format.substring(index, match.start));
    final tag = match.group(1)!;
    buffer.write(_resolveTag(tag, config, event));
    index = match.end;
  }
  buffer.write(format.substring(index));
  return buffer.toString();
}

/// Resolves a single interpolation [tag] to its string representation.
String _resolveTag(String tag, LoggerConfig config, LoggerEvent event) {
  switch (tag) {
    case "custom":
      return config.customTag?.call(event) ?? "";
    case "time_unix":
      return (event.end.millisecondsSinceEpoch ~/ 1000).toString();
    case "time_unix_milli":
      return event.end.millisecondsSinceEpoch.toString();
    case "time_unix_micro":
      return event.end.microsecondsSinceEpoch.toString();
    case "time_unix_nano":
      return (event.end.microsecondsSinceEpoch * 1000).toString();
    case "time_rfc3339":
      return event.end.toUtc().toIso8601String();
    case "time_rfc3339_nano":
      return event.end.toUtc().toIso8601String();
    case "time_custom":
      return _formatCustomTime(event.end.toLocal(), config.customTimeFormat);
    case "id":
      return _sanitizeString(
        event.ctx.request.header("x-request-id") ?? event.response.headers.value("x-request-id") ?? "",
      );
    case "remote_ip":
      return _sanitizeString(_remoteIp(event.ctx.request));
    case "host":
      return _sanitizeString(
        event.ctx.request.host ?? event.request.headers.host ?? "",
      );
    case "uri":
      return _sanitizeString(event.request.uri.toString());
    case "method":
      return _sanitizeString(event.ctx.request.method);
    case "path":
      return _sanitizeString(event.ctx.request.path);
    case "protocol":
      return _sanitizeString(event.request.protocolVersion);
    case "referer":
      return _sanitizeString(
        event.ctx.request.header(HttpHeaders.refererHeader) ?? "",
      );
    case "user_agent":
      return _sanitizeString(event.ctx.request.userAgent ?? "");
    case "status":
      return event.status.toString();
    case "error":
      final error = event.error;
      return error == null ? "" : _sanitizeString(error.toString());
    case "latency":
      return (event.latency.inMicroseconds * 1000).toString();
    case "latency_human":
      return event.latency.toString();
    case "bytes_in":
      return (event.bytesIn ?? 0).toString();
    case "bytes_out":
      return event.bytesOut.toString();
    default:
      if (tag.startsWith("header:")) {
        final name = tag.substring("header:".length);
        return _sanitizeString(event.ctx.request.header(name) ?? "");
      }
      if (tag.startsWith("query:")) {
        final name = tag.substring("query:".length);
        final value = event.ctx.request.queryParameters[name];
        return _sanitizeString(value ?? "");
      }
      if (tag.startsWith("cookie:")) {
        final name = tag.substring("cookie:".length);
        return _sanitizeString(event.ctx.request.cookie(name) ?? "");
      }
      return "";
  }
}

/// Escapes control characters for safe JSON embedding.
String _sanitizeString(String value) {
  if (value.isEmpty) return "";
  final encoded = jsonEncode(value);
  return encoded.substring(1, encoded.length - 1);
}

/// Determines the best-effort remote IP respecting proxy headers.
String _remoteIp(CtxRequest request) {
  final real = request.header("x-real-ip");
  if (real != null && real.isNotEmpty) {
    return real;
  }
  final forwarded = request.header("x-forwarded-for");
  if (forwarded != null && forwarded.isNotEmpty) {
    final parts = forwarded.split(",");
    if (parts.isNotEmpty) {
      return parts.first.trim();
    }
  }
  final address = request.remoteAddress;
  return address?.address ?? "";
}

/// Computes the number of bytes written to the response.
int _resolveBytesOut(CtxResponse response) {
  if (response.isBodySuppressed) {
    return 0;
  }
  final bodyLength = response.bodyLength;
  if (bodyLength != null) {
    return bodyLength;
  }
  final header = response.headers.value(HttpHeaders.contentLengthHeader);
  if (header != null) {
    final parsed = int.tryParse(header);
    if (parsed != null) {
      return parsed;
    }
  }
  return 0;
}

/// Applies the lightweight custom time formatting used by log templates.
String _formatCustomTime(DateTime time, String pattern) {
  if (pattern.isEmpty) {
    return "";
  }

  final buffer = StringBuffer();
  var index = 0;
  while (index < pattern.length) {
    final token = _matchToken(pattern, index);
    if (token == null) {
      buffer.write(pattern[index]);
      index++;
      continue;
    }
    buffer.write(token.formatter(time));
    index += token.pattern.length;
  }
  return buffer.toString();
}

/// Returns the formatting token starting at [index], if any.
_CustomTimeToken? _matchToken(String pattern, int index) {
  for (final token in _customTimeTokens) {
    if (pattern.startsWith(token.pattern, index)) {
      return token;
    }
  }
  return null;
}

/// Supported formatting tokens for [LoggerConfig.customTimeFormat].
final List<_CustomTimeToken> _customTimeTokens = <_CustomTimeToken>[
  _CustomTimeToken(
    "yyyy",
    (DateTime time) => time.year.toString().padLeft(4, "0"),
  ),
  _CustomTimeToken(
    "MM",
    (DateTime time) => time.month.toString().padLeft(2, "0"),
  ),
  _CustomTimeToken(
    "dd",
    (DateTime time) => time.day.toString().padLeft(2, "0"),
  ),
  _CustomTimeToken(
    "HH",
    (DateTime time) => time.hour.toString().padLeft(2, "0"),
  ),
  _CustomTimeToken(
    "mm",
    (DateTime time) => time.minute.toString().padLeft(2, "0"),
  ),
  _CustomTimeToken(
    "ss",
    (DateTime time) => time.second.toString().padLeft(2, "0"),
  ),
  _CustomTimeToken("SSSSSS", (DateTime time) => _subsecond(time, 6)),
  _CustomTimeToken("SSSSS", (DateTime time) => _subsecond(time, 5)),
  _CustomTimeToken("SSSS", (DateTime time) => _subsecond(time, 4)),
  _CustomTimeToken("SSS", (DateTime time) => _subsecond(time, 3)),
  _CustomTimeToken("SS", (DateTime time) => _subsecond(time, 2)),
  _CustomTimeToken("S", (DateTime time) => _subsecond(time, 1)),
];

/// Represents a small formatting directive for custom time rendering.
class _CustomTimeToken {
  const _CustomTimeToken(this.pattern, this.formatter);

  final String pattern;

  final String Function(DateTime time) formatter;
}

/// Formats the fractional seconds component with the requested [digits].
String _subsecond(DateTime time, int digits) {
  final micro = time.microsecondsSinceEpoch % 1000000;
  final value = micro.toString().padLeft(6, "0");
  if (digits >= 6) {
    return value;
  }
  return value.substring(0, digits);
}
