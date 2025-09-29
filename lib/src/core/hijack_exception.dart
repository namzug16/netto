/// Internal sentinel exception thrown once a request has been hijacked.
class HijackException implements Exception {
  /// Creates a new sentinel exception for hijacked requests.
  const HijackException();

  @override
  String toString() => "HijackException: request has been hijacked.";
}
