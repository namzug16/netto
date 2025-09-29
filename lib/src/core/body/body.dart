import "dart:async";
import "dart:io";

/// Limits for multipart processing. All fields are optional.
/// - Sizes in bytes, counts as integers.
/// - If a limit is exceeded, an [HttpException] with status 413 is thrown.
class MultipartLimits {
  /// Creates a new configuration describing multipart parsing limits.
  const MultipartLimits({
    this.maxFields,
    this.maxFieldLength,
    this.maxFiles,
    this.maxFileSize,
    this.maxTotalSize,
  });

  /// Maximum number of non-file fields allowed.
  final int? maxFields;

  /// Maximum length for each individual field value.
  final int? maxFieldLength;

  /// Maximum number of uploaded files.
  final int? maxFiles;

  /// Maximum size for any single uploaded file.
  final int? maxFileSize;

  /// Maximum cumulative size for all fields and files.
  final int? maxTotalSize;
}

/// A streamed uploaded file backed by a temporary file on disk.
class UploadedFile {
  /// Creates a view over an uploaded file persisted to a temporary file.
  UploadedFile({
    required this.fieldName,
    required this.filename,
    required this.contentType,
    required this.length,
    required File tmpFile,
  }) : _tmp = tmpFile;

  /// Name of the multipart field that carried the upload.
  final String fieldName;

  /// Original filename reported by the client, if any.
  final String? filename;

  /// Content type provided for the upload.
  final ContentType? contentType;

  /// Number of bytes written to the temporary file.
  final int length; // bytes written to temp file
  final File _tmp;

  /// Read the file as a stream (do not delete the temp file until done).
  Stream<List<int>> openRead() => _tmp.openRead();

  /// Convenience to read all bytes (only if the file is reasonably small).
  Future<List<int>> readAsBytes() async {
    final bytes = await _tmp.readAsBytes();
    return List<int>.from(bytes);
  }

  /// Path to the temp file (if you need to move/rename it).
  String get path => _tmp.path;

  /// Clean up the temp file.
  /// Deletes the backing temporary file.
  // ignore: body_might_complete_normally_catch_error
  Future<void> delete() => _tmp.delete().catchError((_) {});
}

/// Aggregated multipart form result.
class FormData {
  /// Creates an aggregate of parsed multipart form fields and uploaded files.
  FormData({Map<String, List<String>>? fields, List<UploadedFile>? files}) : fields = fields ?? <String, List<String>>{}, files = files ?? <UploadedFile>[];

  /// Text fields: name → list of values (multi-value support).
  final Map<String, List<String>> fields;

  /// Uploaded files.
  final List<UploadedFile> files;

  /// Adds [value] to the list of values for [name].
  void addField(String name, String value) {
    (fields[name] ??= <String>[]).add(value);
  }
}
