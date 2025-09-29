import "package:netto/src/core/router/builder.dart";
import "package:netto/src/core/router/utils.dart";
import "package:netto/src/core/types.dart";

/// Route builder that scopes nested routes under a shared prefix and middleware.
class Group extends Builder {
  /// Creates a nested builder with an optional [prefix] and [middleware].
  Group(super._parent, super.rTree, String? prefix, Middleware? middleware) : prefix = prefix != null ? normalizePath(prefix) : null {
    if (middleware != null) {
      use(middleware);
    }
  }

  /// Normalized prefix applied to every route within the group.
  final String? prefix;

  /// Registers a handler inside the group's prefix.
  @override
  void add(String verb, String route, Handler handler) {
    super.add(verb, [?prefix, route].join(), handler);
  }

  /// Creates a nested group preserving the full prefix chain.
  @override
  Group group(String? prefix, [Middleware? middleware]) {
    final p = [?this.prefix, ?prefix].join();
    return super.group(p.isEmpty ? null : p, middleware);
  }
}
