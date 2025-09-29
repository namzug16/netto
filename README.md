# Netto

```
    _   __     __  __      
   / | / /__  / /_/ /_____ 
  /  |/ / _ \/ __/ __/ __ \
 / /|  /  __/ /_/ /_/ /_/ /
/_/ |_/\___/\__/\__/\____/ 

A minimal, flexible, composable, and neat web framework for Dart.
```

Netto is an experimental web framework whose goal is to give you the lightest
possible foundation for building feature-rich web servers and applications. It
sticks closely to the `dart:io` library, adding zero hard wrappers,
no compile-time header type safety, and no file system based
conventions. Inspired by the ergonomics of [Echo](https://echo.labstack.com/) in
the Go ecosystem, Netto keeps out of your way so you can structure your server
however you want.

## Highlights

- **Familiar `dart:io` surface** - Work with the primitives you already know:
  `HttpServer`, `HttpRequest`, and `HttpResponse`.
- **Composable middleware** - Chain functions with `use` to add logging,
  authentication, or any custom behavior at either the app or group level.
- **Typed context storage** - Pass data between middleware and handlers using a
  per-request `Ctx` with helpers like `set`, `get`, and `require`.
- **First-class responses** - Write strings, JSON, or take over the response
  stream directly; Netto never hides the socket from you.
- **Centralized error handling** - Configure an app-wide error handler to
  produce consistent responses and logging from a single place.
- **Radix-tree router** - Netto's router is backed by a fast, prefix-based
  radix tree with support for route groups, named parameters, and all standard
  HTTP methods.

## Quick start

```dart
import "dart:io";

import "package:netto/netto.dart";

Future<void> main() async {
  final app = Netto()
    ..use(logger())
    ..get("/", (ctx) => ctx.response.string("Hello, Netto!"))
    ..get("/ping", (ctx) => ctx.response.json({"pong": DateTime.now().toIso8601String()}));

  await app.serve(InternetAddress.loopbackIPv4, 8080);
}
```

Add more routes by calling `get`, `post`, or group them with `group`.
Middlewares run in the order they are registered (globally scoped or group scoped), so you can build your own stack
for logging, authorization, caching, and beyond.

## Next steps

This README is intentionally light. Detailed guides, patterns, and API
explanations will live in the documentation site we are building next. Until
then, explore the examples in the `example/` directory and experiment with
Netto to see how it fits your projects.
