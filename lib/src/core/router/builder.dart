import "dart:async";
import "dart:io";

import "package:http_parser/http_parser.dart" as http_parser;
import "package:mime/mime.dart";
import "package:netto/src/core/ctx.dart";
import "package:netto/src/core/middleware_extensions.dart";
import "package:netto/src/core/router/group.dart";
import "package:netto/src/core/router/radix_tree.dart";
import "package:netto/src/core/router/route_node.dart";
import "package:netto/src/core/router/utils.dart";
import "package:netto/src/core/types.dart";

/// Base builder abstraction that wires routes into the shared radix tree.
abstract class Builder {
  /// Creates a builder bound to the shared [RadixTree] and optional parent.
  Builder(this._parent, this.rTree);

  final Builder? _parent;

  /// Shared radix tree storing every registered route for this builder chain.
  final RadixTree<RouteNode> rTree;

  /// Effective middleware chain for this builder including ancestors.
  Middleware? get middleware {
    if (_parent?.middleware != null) {
      if (_middleware != null) {
        return _parent?.middleware?.addMiddleware(_middleware!);
      } else {
        return _parent?.middleware;
      }
    }

    return _middleware;
  }

  Middleware? _middleware;

  /// Creates a nested route group optionally scoped by [prefix] and [middleware].
  Group group(String? prefix, [Middleware? middleware]) {
    return Group(this, rTree, prefix, middleware);
  }

  /// Adds middleware to the group or router, composing with existing ones.
  void use(Middleware m) {
    if (_middleware == null) {
      _middleware = m;
    } else {
      _middleware = _middleware!.addMiddleware(m);
    }
  }

  /// Registers a handler for an HTTP [verb] at [route].
  void add(String verb, String route, Handler handler) {
    // Should I add it back?
    // if (!isHttpMethod(verb)) {
    //   throw ArgumentError.value(verb, 'verb', 'expected a valid HTTP method');
    // }
    final v = verb.toUpperCase();

    if (v == "GET") {
      // Handling in a 'GET' request without handling a 'HEAD' request is always
      // wrong, thus, we add a default implementation that discards the body.
      rTree.insert("HEAD$route", RouteNode(handler, this));
    }
    rTree.insert("$verb$route", RouteNode(handler, this));
  }

  /// Convenience for responding with a 301 redirect from [route] to [redirect].
  void redirect(String route, String redirect) => add("GET", route, (ctx) => ctx.response.movedPermanently(redirect));

  /// Registers a GET handler.
  void get(String route, Handler handler) => add("GET", route, handler);

  /// Registers a HEAD handler.
  void head(String route, Handler handler) => add("HEAD", route, handler);

  /// Registers a POST handler.
  void post(String route, Handler handler) => add("POST", route, handler);

  /// Registers a PUT handler.
  void put(String route, Handler handler) => add("PUT", route, handler);

  /// Registers a DELETE handler.
  void delete(String route, Handler handler) => add("DELETE", route, handler);

  /// Registers a CONNECT handler.
  void connect(String route, Handler handler) => add("CONNECT", route, handler);

  /// Registers an OPTIONS handler.
  void options(String route, Handler handler) => add("OPTIONS", route, handler);

  /// Registers a TRACE handler.
  void trace(String route, Handler handler) => add("TRACE", route, handler);

  /// Registers a PATCH handler.
  void patch(String route, Handler handler) => add("PATCH", route, handler);

  /// Exposes every file under [root] through routes prefixed by [prefix].
  void static(String prefix, String root) {
    checkPath(prefix);

    final rootDir = Directory(root);

    if (!rootDir.existsSync()) {
      throw ArgumentError(
        'A directory corresponding to fileSystemPath "$root" could not be found',
      );
    }

    final resolvedRoot = rootDir.resolveSymbolicLinksSync();

    final entities = rootDir.listSync(recursive: true, followLinks: false);

    for (final entity in entities) {
      final entityType = FileSystemEntity.typeSync(
        entity.path,
        followLinks: false,
      );
      if (entityType != FileSystemEntityType.file) {
        continue;
      }

      final resolvedPath = entity.resolveSymbolicLinksSync();
      var relative = resolvedPath.substring(resolvedRoot.length);
      if (relative.isEmpty) {
        continue;
      }

      relative = relative.replaceAll(r"\", "/");
      if (!relative.startsWith("/")) {
        relative = "/$relative";
      }

      final routePath = prefix == "/" ? relative : "$prefix$relative";
      file(routePath, resolvedPath);
    }
  }

  /// Serves a single file located at [filePath] under the route [path].
  void file(String path, String filePath) {
    checkPath(path);
    final eType = FileSystemEntity.typeSync(filePath);
    if (eType == FileSystemEntityType.file) {
      final file = File(filePath);
      get(
        path,
        (Ctx ctx) => _handleFile(ctx, file, () async {
          final mimeResolver = MimeTypeResolver();
          return mimeResolver.lookup(file.path);
        }),
      );
    } else {
      throw ArgumentError.value(
        filePath,
        "file",
        'The provided file path "$filePath" does not refer to an existing file. Please verify that the file exists and the path is correct.',
      );
    }
  }
}

/// Streams the contents of [file] into the response with range support.
Future<void> _handleFile(
  Ctx ctx,
  File file,
  FutureOr<String?> Function() getContentType,
) async {
  final stat = file.statSync();
  final lastModified = _toSecondResolution(stat.modified.toUtc());

  final headers = ctx.response.headers
    ..set(
      HttpHeaders.lastModifiedHeader,
      http_parser.formatHttpDate(lastModified),
    )
    ..set(HttpHeaders.acceptRangesHeader, "bytes");

  final resolvedType = await getContentType();
  ContentType? parsedContentType;
  if (resolvedType != null) {
    try {
      parsedContentType = ContentType.parse(resolvedType);
      headers.contentType = parsedContentType;
    } on FormatException {
      headers.set(HttpHeaders.contentTypeHeader, resolvedType);
    }
  }

  final ifModifiedSinceHeader = ctx.request.header(
    HttpHeaders.ifModifiedSinceHeader,
  );
  if (ifModifiedSinceHeader != null) {
    try {
      final ifModifiedSince = _toSecondResolution(
        http_parser.parseHttpDate(ifModifiedSinceHeader).toUtc(),
      );
      if (!lastModified.isAfter(ifModifiedSince)) {
        ctx.response.status(HttpStatus.notModified);
        return;
      }
    } on FormatException {
      // Ignore malformed headers and continue serving the file.
    }
  }

  final rangeSelection = _fileRangeResponse(ctx, stat.size);
  if (rangeSelection is _RangeUnsatisfiable) {
    headers
      ..set(HttpHeaders.contentRangeHeader, "bytes */${stat.size}")
      ..set(HttpHeaders.contentLengthHeader, "0");
    ctx.response.status(HttpStatus.requestedRangeNotSatisfiable);
    return;
  } else if (rangeSelection is _RangeSlice) {
    final start = rangeSelection.start;
    final end = rangeSelection.end;
    final length = end - start + 1;

    headers
      ..set(HttpHeaders.contentRangeHeader, "bytes $start-$end/${stat.size}")
      ..set(HttpHeaders.contentLengthHeader, "$length");

    if (ctx.request.method == "HEAD") {
      ctx.response.status(HttpStatus.partialContent);
      return;
    }

    final stream = file.openRead(start, end + 1);
    await ctx.response.stream(
      stream,
      status: HttpStatus.partialContent,
      type: parsedContentType,
      contentLength: length,
    );
    return;
  }

  headers.set(HttpHeaders.contentLengthHeader, "${stat.size}");

  if (ctx.request.method == "HEAD") {
    ctx.response.status(HttpStatus.ok);
    return;
  }

  await ctx.response.stream(
    file.openRead(),
    type: parsedContentType,
    contentLength: stat.size,
  );
}

/// Normalizes [dt] to second precision to align with HTTP caching semantics.
DateTime _toSecondResolution(DateTime dt) {
  if (dt.millisecond == 0 && dt.microsecond == 0) {
    return dt;
  }
  return dt.subtract(
    Duration(milliseconds: dt.millisecond, microseconds: dt.microsecond),
  );
}

/// Extracts start/end offsets from a Range header.
final _bytesMatcher = RegExp(r"^bytes=(\d*)-(\d*)$");

/// Parses the incoming Range header and validates it against [fileLength].
_RangeSelection? _fileRangeResponse(Ctx ctx, int fileLength) {
  final rangeHeader = ctx.request.header(HttpHeaders.rangeHeader);
  if (rangeHeader == null) {
    return null;
  }

  final matches = _bytesMatcher.firstMatch(rangeHeader.trim());
  if (matches == null) {
    return null;
  }

  final startMatch = matches[1]!;
  final endMatch = matches[2]!;

  if (startMatch.isEmpty && endMatch.isEmpty) {
    return null;
  }

  if (fileLength == 0) {
    return const _RangeUnsatisfiable();
  }

  int start;
  int end;

  if (startMatch.isEmpty) {
    final suffixLength = int.tryParse(endMatch);
    if (suffixLength == null || suffixLength <= 0) {
      return null;
    }
    if (suffixLength >= fileLength) {
      start = 0;
    } else {
      start = fileLength - suffixLength;
    }
    end = fileLength - 1;
  } else {
    final startValue = int.tryParse(startMatch);
    if (startValue == null || startValue < 0) {
      return null;
    }
    start = startValue;

    if (endMatch.isEmpty) {
      end = fileLength - 1;
    } else {
      final endValue = int.tryParse(endMatch);
      if (endValue == null || endValue < 0) {
        return null;
      }
      end = endValue;
    }
  }

  if (start > end) {
    return null;
  }

  if (start >= fileLength) {
    return const _RangeUnsatisfiable();
  }

  if (end >= fileLength) {
    end = fileLength - 1;
  }

  return _RangeSlice(start, end);
}

/// Marker interface for the outcome of parsing a Range header.
sealed class _RangeSelection {
  const _RangeSelection();
}

/// Represents a satisfiable range request.
class _RangeSlice extends _RangeSelection {
  const _RangeSlice(this.start, this.end);

  final int start;
  final int end;
}

/// Represents a range request that cannot be fulfilled.
class _RangeUnsatisfiable extends _RangeSelection {
  const _RangeUnsatisfiable();
}
