import "package:netto/src/core/router/utils.dart";

/// Node used by the radix tree to store path segments and route metadata.
class RadixNode<T> {
  /// Creates a node storing [prefix] and an optional [value].
  RadixNode(this.prefix, this.value);

  String prefix;
  T? value;
  final List<RadixNode<T>> children = [];

  /// Whether this node represents a parameter segment.
  bool get isParam => prefix.startsWith(":");
}

/// Result returned when resolving a path through the radix tree.
class RadixResult<T> {
  /// Creates a lookup result with the matched [value] and [params].
  RadixResult(this.value, this.params);

  /// Matched value stored for the node.
  final T value;

  /// Captured path parameters keyed by name.
  final Map<String, String> params;
}

/// Lightweight radix tree optimized for HTTP route lookup.
class RadixTree<T> {
  final RadixNode<T> _root = RadixNode<T>("", null);

  /// Inserts [value] under the normalized [path].
  void insert(String path, T value) {
    final segments = _splitPath(normalizePath(path));
    _insert(_root, segments, value);
  }

  void _insert(RadixNode<T> node, List<String> segments, T value) {
    if (segments.isEmpty) {
      if (node.value != null) {
        throw Exception("Duplicate route");
      }
      node.value = value;
      return;
    }

    final segment = segments.first;

    for (final child in node.children) {
      final sameLiteral = child.prefix == segment;
      final bothParams = child.isParam && segment.startsWith(":");

      if (sameLiteral || bothParams) {
        if (bothParams && child.prefix != segment) {
          throw Exception(
            "Conflicting parameter names at segment: '${child.prefix}' vs '$segment'",
          );
        }
        _insert(child, segments.sublist(1), value);
        return;
      }
    }

    final newNode = RadixNode<T>(segment, null);
    node.children.add(newNode);
    _insert(newNode, segments.sublist(1), value);
  }

  /// Retrieves the value associated with [path], including path params.
  RadixResult<T>? get(String path) {
    final segments = _splitPath(normalizePath(path));
    return _get(_root, segments);
  }

  /// Returns the set of first-level segments that match [path].
  List<String> matchFirstSegments(String path) {
    final segments = _splitPath(normalizePath(path));
    final matches = <String>[];

    for (final child in _root.children) {
      if (_matches(child, segments)) {
        matches.add(child.prefix);
      }
    }

    return matches;
  }

  RadixResult<T>? _get(RadixNode<T> node, List<String> segments) {
    if (segments.isEmpty) {
      return node.value != null ? RadixResult<T>(node.value as T, {}) : null;
    }

    final segment = segments.first;

    //NOTE: route resolution priority
    final children = [...node.children]..sort((a, b) => a.isParam ? 1 : -1);

    for (final child in children) {
      if (child.prefix == segment) {
        final result = _get(child, segments.sublist(1));
        if (result != null) return result;
      } else if (child.isParam) {
        final result = _get(child, segments.sublist(1));
        if (result != null) {
          return RadixResult<T>(result.value, {
            child.prefix.substring(1): segment,
            ...result.params,
          });
        }
      }
    }

    return null;
  }

  bool _matches(RadixNode<T> node, List<String> segments) {
    if (segments.isEmpty) {
      return node.value != null;
    }

    final segment = segments.first;
    final children = [...node.children]..sort((a, b) => a.isParam ? 1 : -1);

    for (final child in children) {
      if (child.prefix == segment || child.isParam) {
        if (_matches(child, segments.sublist(1))) {
          return true;
        }
      }
    }

    return false;
  }

  /// Finds the deepest literal match for [path] ignoring parameters.
  RadixResult<T>? getLongestLiteralMatch(String path) {
    final segments = _splitPath(normalizePath(path));
    return _getLongestLiteral(_root, segments);
  }

  RadixResult<T>? _getLongestLiteral(RadixNode<T> node, List<String> segments) {
    RadixResult<T>? bestMatch;

    if (node.value != null) {
      bestMatch = RadixResult<T>(node.value as T, {});
    }

    if (segments.isEmpty) return bestMatch;

    final segment = segments.first;

    for (final child in node.children) {
      if (child.prefix == segment) {
        final result = _getLongestLiteral(child, segments.sublist(1));
        if (result != null) return result;
      }
    }

    return bestMatch;
  }

  /// Splits the path into non-empty segments.
  List<String> _splitPath(String path) {
    return path.split("/").where((s) => s.isNotEmpty).toList();
  }

  /// Returns a human-readable tree representation (useful in debugging).
  String getTreeString() {
    final buffer = StringBuffer();

    void buildNodeString(RadixNode<T> node, String indent) {
      final valueStr = node.value != null ? " => ${node.value}" : "";
      buffer.writeln("$indent${node.prefix}$valueStr");
      for (final child in node.children) {
        buildNodeString(child, "$indent  ");
      }
    }

    buildNodeString(_root, "");
    return buffer.toString();
  }
}
