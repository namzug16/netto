import "package:netto/src/core/ctx.dart";
import "package:netto/src/core/ctx_request.dart";
import "package:netto/src/core/ctx_response.dart";

/// Shared helper methods for working with the contextual extras map.
///
/// The mixin expects an implementing class to expose a mutable
/// [extras] map. It provides typed accessors that can be used by the
/// core [Ctx], [CtxRequest], and [CtxResponse] classes to share data
/// during the lifetime of a request.
mixin CtxExtrasAccessors {
  /// Map used to store arbitrary contextual data.
  Map<String, Object?> get extras;

  /// Stores [value] under [key].
  void set<T>(String key, T value) {
    extras[key] = value;
  }

  /// Retrieves a typed value for [key] if present.
  ///
  /// Returns `null` when the key is absent or when the stored value is
  /// explicitly `null`. Throws when the stored value is of a different
  /// type than [T].
  T? get<T>(String key) {
    if (!extras.containsKey(key)) return null;

    final value = extras[key];
    if (value == null) return null;
    if (value is T) return value as T;

    throw StateError(
      'Value for "$key" is not of expected type $T (found ${value.runtimeType}).',
    );
  }

  /// Retrieves a typed value for [key] or throws if it is missing.
  T require<T>(String key) {
    if (!extras.containsKey(key)) {
      throw StateError('No value stored for "$key".');
    }

    final value = extras[key];
    if (value == null) {
      if (null is T) return null as T;
      throw StateError('Value for "$key" is null but $T is not nullable.');
    }
    if (value is T) return value as T;

    throw StateError(
      'Value for "$key" is not of expected type $T (found ${value.runtimeType}).',
    );
  }

  /// Returns a typed value for [key], computing and storing it when absent.
  T getOrPut<T>(String key, T Function() ifAbsent) {
    if (extras.containsKey(key)) {
      return require<T>(key);
    }

    final value = ifAbsent();
    set<T>(key, value);
    return value;
  }

  /// Whether a value exists for [key].
  bool contains(String key) => extras.containsKey(key);

  /// Removes and returns the value stored at [key].
  T? remove<T>(String key) {
    if (!extras.containsKey(key)) return null;

    final value = extras.remove(key);
    if (value == null) {
      if (null is T) return null;
      throw StateError('Value for "$key" is null but $T is not nullable.');
    }
    if (value is T) return value as T;

    throw StateError(
      'Value for "$key" is not of expected type $T (found ${value.runtimeType}).',
    );
  }
}
