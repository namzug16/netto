import "dart:async";
import "dart:convert";
import "dart:io";
import "dart:typed_data";

import "package:collection/collection.dart";
import "package:mime/mime.dart";

import "package:netto/src/core/body/body.dart";
import "package:netto/src/core/ctx_request.dart";
import "package:netto/src/core/types.dart";

/// Helpers for consuming the request body in different representations.
///
/// The wrapper keeps track of whether the incoming byte stream has already
/// been consumed, exposes common decoding helpers, and caches expensive
/// parsing work such as multipart form processing.
class CtxRequestBody {
  /// Creates a helper that exposes multiple views over the request body.
  CtxRequestBody(this._ctxRequest, this._request);

  final CtxRequest _ctxRequest;
  final HttpRequest _request;

  List<int>? _cached;
  bool _streamTaken = false;

  /// True after the first terminal read method is called.
  bool get isConsumed => _streamTaken || _cached != null;

  /// Raw bytes (cached). Subsequent calls return the cached buffer.
  Future<List<int>> bytes() async {
    if (_cached != null) return _cached!;
    if (_streamTaken) {
      throw StateError("Request body stream already consumed.");
    }
    final builder = BytesBuilder(copy: false);
    await for (final chunk in _request) {
      builder.add(chunk);
    }
    _cached = builder.takeBytes();
    _streamTaken = true; // terminal read
    return _cached!;
  }

  /// String with optional encoding (defaults UTF-8).
  Future<String> string([Encoding? encoding]) async {
    final data = await bytes();
    return (encoding ?? utf8).decode(data);
  }

  /// JSON decoded as Map/List. Throws [HttpException] with status 400 on invalid JSON.
  Future<dynamic> json() async {
    final txt = await string(utf8);
    try {
      return jsonDecode(txt);
    } on FormatException catch (e) {
      throw HttpException(400, "Invalid JSON: ${e.message}");
    }
  }

  /// application/x-www-form-urlencoded → field → values.
  Future<Map<String, List<String>>> formUrlencoded() async {
    final ctype = _request.headers.contentType;
    if (ctype == null || ctype.mimeType.toLowerCase() != "application/x-www-form-urlencoded") {
      throw HttpException(415, "Unsupported media type for formUrlencoded.");
    }

    final body = await string(_charsetFromContentType(ctype) ?? utf8);
    return _parseFormUrlencoded(body);
  }

  /// multipart/form-data → fields + files (streamed files via temp files).
  Future<FormData> multipart({MultipartLimits? limits}) async {
    final cached = _formCache[_request];
    if (cached != null) {
      if (!cached.isMultipart) {
        throw HttpException(415, "Request is not multipart/form-data");
      }
      return cached.data;
    }

    final contentType = _request.headers.contentType;
    if (contentType == null || !_ctxRequest.isMultipart) {
      throw HttpException(415, "Content-Type must be multipart/form-data.");
    }

    final boundary = contentType.parameters["boundary"];
    if (boundary == null || boundary.isEmpty) {
      throw HttpException(400, "Missing multipart boundary.");
    }

    if (_streamTaken && _cached == null) {
      throw StateError("Request body stream already consumed.");
    }

    final Stream<List<int>> sourceStream = _cached != null ? Stream<List<int>>.fromIterable([_cached!]) : _takeStream();

    final form = FormData();
    final lmts = limits ?? const MultipartLimits();

    int totalBytes = 0;
    int fieldCount = 0;
    int fileCount = 0;

    final transformer = MimeMultipartTransformer(boundary);

    Directory? tmpDir;

    await for (final part in transformer.bind(sourceStream)) {
      final headers = <String, String>{};
      for (final entry in part.headers.entries) {
        headers[entry.key.toLowerCase()] = entry.value;
      }

      final disp = headers["content-disposition"];
      if (disp == null) {
        await _drain(
          part,
          onChunk: (len) {
            totalBytes += len;
            if (lmts.maxTotalSize != null && totalBytes > lmts.maxTotalSize!) {
              throw HttpException(413, "Multipart total size exceeded.");
            }
          },
        );
        continue;
      }

      final dispParams = _parseContentDisposition(disp);
      final fieldName = dispParams["name"];
      final filename = dispParams["filename"];
      final partCt = _parseContentType(headers["content-type"]);

      if (fieldName == null || fieldName.isEmpty) {
        await _drain(
          part,
          onChunk: (len) {
            totalBytes += len;
            if (lmts.maxTotalSize != null && totalBytes > lmts.maxTotalSize!) {
              throw HttpException(413, "Multipart total size exceeded.");
            }
          },
        );
        continue;
      }

      if (filename == null || filename.isEmpty) {
        fieldCount++;
        if (lmts.maxFields != null && fieldCount > lmts.maxFields!) {
          throw HttpException(413, "Too many form fields.");
        }

        final encoding = _charsetFromContentType(partCt) ?? utf8;
        final builder = BytesBuilder(copy: false);
        await for (final chunk in part) {
          totalBytes += chunk.length;
          if (lmts.maxTotalSize != null && totalBytes > lmts.maxTotalSize!) {
            throw HttpException(413, "Multipart total size exceeded.");
          }
          builder.add(chunk);
          if (lmts.maxFieldLength != null && builder.length > lmts.maxFieldLength!) {
            throw HttpException(413, "Form field too long.");
          }
        }

        final value = encoding.decode(builder.takeBytes());
        form.addField(fieldName, value);
        continue;
      }

      fileCount++;
      if (lmts.maxFiles != null && fileCount > lmts.maxFiles!) {
        throw HttpException(413, "Too many uploaded files.");
      }

      tmpDir ??= await Directory.systemTemp.createTemp("netto_upload_");
      final tmpFile = File("${tmpDir.path}/part_$fileCount");
      await tmpFile.create();
      int written = 0;
      final sink = tmpFile.openWrite();
      try {
        await for (final chunk in part) {
          written += chunk.length;
          totalBytes += chunk.length;
          if (lmts.maxFileSize != null && written > lmts.maxFileSize!) {
            throw HttpException(413, "Uploaded file too large.");
          }
          if (lmts.maxTotalSize != null && totalBytes > lmts.maxTotalSize!) {
            throw HttpException(413, "Multipart total size exceeded.");
          }
          sink.add(chunk);
        }
        await sink.close();
      } catch (e) {
        await sink.close().catchError((_) {});
        //
        // ignore: body_might_complete_normally_catch_error
        await tmpFile.delete().catchError((_) {});
        rethrow;
      }

      form.files.add(
        UploadedFile(
          fieldName: fieldName,
          filename: filename,
          contentType: partCt,
          length: written,
          tmpFile: tmpFile,
        ),
      );
    }

    _formCache[_request] = _FormCache(form, true, limits);

    return form;
  }

  /// Raw byte stream of the request body (one-time terminal read).
  Stream<List<int>> stream() => _takeStream();

  /// Returns the first value for `name` from form fields (urlencoded or multipart).
  ///  - `null` if not present.
  ///  - 415 if content-type isn’t form (unless `allowBestEffort` true and body empty).
  Future<String?> formValue(String name, {bool allowBestEffort = false}) async {
    final fields = await formFields(allowBestEffort: allowBestEffort);
    final vals = fields[name];
    return (vals == null || vals.isEmpty) ? null : vals.first;
  }

  /// Returns all values for `name` from form fields. Empty list if missing.
  Future<List<String>> formValues(
    String name, {
    bool allowBestEffort = false,
  }) async {
    final fields = await formFields(allowBestEffort: allowBestEffort);
    final vals = fields[name];
    return vals == null ? const <String>[] : List<String>.from(vals);
  }

  /// Returns the first uploaded file whose field name matches [name].
  ///  - `null` if missing.
  ///  - 415 if not multipart.
  Future<UploadedFile?> formFile(String name, {MultipartLimits? limits}) async {
    final data = await _ensureParsedForm(
      _request,
      limits: limits,
      requireMultipart: true,
    );
    return data.files.firstWhereOrNull((e) => e.fieldName == name);
  }

  /// Returns every uploaded file whose field name matches [name].
  Future<List<UploadedFile>> formFiles(
    String name, {
    MultipartLimits? limits,
  }) async {
    final data = await _ensureParsedForm(
      _request,
      limits: limits,
      requireMultipart: true,
    );
    return data.files.where((e) => e.fieldName == name).toList();
  }

  /// Returns all fields (merged); for urlencoded there are no files.
  Future<Map<String, List<String>>> formFields({
    bool allowBestEffort = false,
  }) async {
    final data = await _ensureParsedForm(
      _request,
      allowBestEffort: allowBestEffort,
    );
    // return as an unmodifiable map to prevent accidental mutation by callers
    return UnmodifiableMapView(data.fields);
  }

  /// Full access when you actually need both fields & files together.
  Future<FormData> formData({
    MultipartLimits? limits,
    bool allowBestEffort = false,
  }) {
    return _ensureParsedForm(
      _request,
      limits: limits,
      allowBestEffort: allowBestEffort,
    );
  }

  // helpers

  /// Returns the raw request stream while ensuring single consumption.
  Stream<List<int>> _takeStream() {
    if (_cached != null) {
      // If already cached, expose the cached bytes as a stream.
      final s = Stream<List<int>>.fromIterable([_cached!]);
      // Keep consumed state as true.
      return s;
    }
    if (_streamTaken) {
      throw StateError("Request body stream already consumed.");
    }
    _streamTaken = true;
    return _request;
  }

  /// Resolves the charset parameter from [ct], defaulting to UTF-8.
  static Encoding? _charsetFromContentType(ContentType? ct) {
    final cs = ct?.parameters["charset"];
    if (cs == null) return null;
    final name = cs.toLowerCase();
    switch (name) {
      case "utf-8":
      case "utf8":
        return utf8;
      case "latin1":
      case "iso-8859-1":
        return latin1;
      case "us-ascii":
      case "ascii":
        return ascii;
      default:
        // Unknown → default to UTF-8
        return utf8;
    }
  }

  /// Parses `application/x-www-form-urlencoded` payloads into a map.
  static Map<String, List<String>> _parseFormUrlencoded(String body) {
    final out = <String, List<String>>{};
    if (body.isEmpty) return out;

    // RFC 3986 / HTML5 form encoding: '+' decodes to space.
    final List<String> pairs = body.split("&");
    for (final pair in pairs) {
      if (pair.isEmpty) continue;
      final idx = pair.indexOf("=");
      String k;
      String v;
      if (idx == -1) {
        k = pair;
        v = "";
      } else {
        k = pair.substring(0, idx);
        v = pair.substring(idx + 1);
      }
      k = _decodeFormComponent(k);
      v = _decodeFormComponent(v);
      (out[k] ??= <String>[]).add(v);
    }
    return out;
  }

  /// Decodes a form-encoded component replacing `+` with spaces.
  static String _decodeFormComponent(String s) {
    // Replace '+' with space before percent-decoding.
    return Uri.decodeQueryComponent(s.replaceAll("+", " "));
  }

  /// Parses and caches form data for the request, respecting [limits].
  Future<FormData> _ensureParsedForm(
    HttpRequest req, {
    MultipartLimits? limits,
    bool allowBestEffort = false,
    bool requireMultipart = false,
  }) async {
    // Serve from cache if available.
    final cached = _formCache[req];
    if (cached != null) {
      // If caller demands multipart but the cached parse was urlencoded/empty, error.
      if (requireMultipart && !cached.isMultipart) {
        throw HttpException(415, "Request is not multipart/form-data");
      }
      return cached.data;
    }

    // Decide how to parse based on Content-Type.
    if (_ctxRequest.isMultipart) {
      final parsed = await multipart(limits: limits);
      final data = FormData(fields: parsed.fields, files: parsed.files);
      _formCache[req] = _FormCache(data, true, limits);
      return data;
    }

    if (_ctxRequest.isFormUrlencoded) {
      final fields = await formUrlencoded();
      final data = FormData(fields: fields, files: []);
      _formCache[req] = _FormCache(data, false, null);
      if (requireMultipart) {
        // Caller explicitly requested multipart-only access.
        throw HttpException(415, "Request is not multipart/form-data");
      }
      return data;
    }

    // Not a known form content-type.
    // If best-effort is allowed and the body is empty, expose empty form.
    final isEmpty = req.contentLength == 0 || req.contentLength == -1;
    if (allowBestEffort && isEmpty) {
      // For unknown length (-1), verify by attempting to read
      if (req.contentLength == -1) {
        final hasData = await _request.isEmpty;
        if (!hasData) {
          throw HttpException(415, "Unsupported Content-Type for form parsing");
        }
      }
      final data = FormData(fields: const {}, files: []);
      _formCache[req] = _FormCache(data, false, null);
      if (requireMultipart) {
        throw HttpException(415, "Request is not multipart/form-data");
      }
      return data;
    }

    // Strict behavior: unsupported media type.
    throw HttpException(415, "Unsupported Content-Type for form parsing");
  }
}

/// Caches parsed form data for individual [HttpRequest] instances.
final Expando<_FormCache> _formCache = Expando<_FormCache>("form-cache");

/// Internal cache record storing parsed form data and metadata.
class _FormCache {
  //
  // ignore: avoid_positional_boolean_parameters
  _FormCache(this.data, this.isMultipart, this.limits);

  final FormData data;
  final bool isMultipart;
  // note: first-parse policy wins
  final MultipartLimits? limits;
}

/// Parses a Content-Disposition header into lowercase parameters.
Map<String, String> _parseContentDisposition(String value) {
  final result = <String, String>{};
  final parts = value.split(";");
  for (var i = 1; i < parts.length; i++) {
    final seg = parts[i].trim();
    final eq = seg.indexOf("=");
    if (eq <= 0) continue;
    final key = seg.substring(0, eq).trim().toLowerCase();
    var val = seg.substring(eq + 1).trim();
    if (val.startsWith('"') && val.endsWith('"') && val.length >= 2) {
      val = val.substring(1, val.length - 1);
    }
    result[key] = val;
  }
  return result;
}

/// Safely parses a content-type header returning `null` on failure.
ContentType? _parseContentType(String? raw) {
  if (raw == null) return null;
  try {
    return ContentType.parse(raw);
    //
    // ignore: avoid_catches_without_on_clauses
  } catch (_) {
    return null;
  }
}

/// Consumes and discards the remaining bytes of [stream].
Future<void> _drain(Stream<List<int>> stream, {void Function(int chunkLength)? onChunk}) async {
  await for (final chunk in stream) {
    onChunk?.call(chunk.length);
  }
}
