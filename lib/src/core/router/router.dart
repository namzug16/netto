import "package:lru/lru.dart";
import "package:meta/meta.dart";
import "package:netto/src/core/router/builder.dart";
import "package:netto/src/core/router/radix_tree.dart";
import "package:netto/src/core/router/route_node.dart";
import "package:netto/src/core/router/utils.dart";

/// HTTP router based on a radix tree with middleware support.
class Router extends Builder {
  /// Creates an empty router backed by a [RadixTree].
  Router() : _resolveCache = LruCache<String, _RouteCacheEntry>(_cacheCapacity), super(null, RadixTree<RouteNode>());

  static const int _cacheCapacity = 100;

  final LruCache<String, _RouteCacheEntry> _resolveCache;

  /// Resolves [method] and [path] to a route node along with extracted params.
  RadixResult<RouteNode>? resolve(String method, String path) {
    final normalizedPath = normalizePath(path);
    final methodKey = method.toUpperCase();
    final cacheKey = _cacheKey(methodKey, normalizedPath);

    final cached = _resolveCache[cacheKey];
    if (cached != null) {
      return cached.result;
    }

    final result = rTree.get("$methodKey$normalizedPath");
    _resolveCache[cacheKey] = _RouteCacheEntry.fromResult(result);

    return result;
  }

  /// Returns the list of methods available for [path] (useful for 405 handling).
  List<String> allowedMethods(String path) {
    final normalizedPath = normalizePath(path);
    final matches = rTree.matchFirstSegments(normalizedPath);
    final allowed = <String>{};
    for (final method in matches) {
      allowed.add(method.toUpperCase());
    }
    final methods = allowed.toList()..sort();
    return methods;
  }

  String _cacheKey(String method, String normalizedPath) => "$method$normalizedPath";

  @visibleForTesting
  bool isRouteCached(String method, String path) {
    final normalizedPath = normalizePath(path);
    final methodKey = method.toUpperCase();
    return _resolveCache.containsKey(_cacheKey(methodKey, normalizedPath));
  }

  @visibleForTesting
  int get cacheSize => _resolveCache.length;
}

class _RouteCacheEntry {
  const _RouteCacheEntry._(this.result);

  final RadixResult<RouteNode>? result;

  static const _RouteCacheEntry _miss = _RouteCacheEntry._(null);

  factory _RouteCacheEntry.fromResult(RadixResult<RouteNode>? result) {
    if (result == null) {
      return _miss;
    }

    return _RouteCacheEntry._(result);
  }
}
