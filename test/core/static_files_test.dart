import "dart:io";

import "package:http/http.dart" as http;
import "package:http_parser/http_parser.dart" as http_parser;
import "package:netto/netto.dart";
import "package:test/test.dart";

import "../test_utils.dart";

void main() {
  late HttpServer server;
  late String baseUrl;
  late Directory staticDir;
  late File textFile;
  late File nestedFile;
  late File standaloneFile;

  Uri url(String path) => Uri.parse("$baseUrl$path");

  setUpAll(() async {
    staticDir = Directory("test/fixtures/static");
    textFile = File("${staticDir.path}/hello.txt");
    nestedFile = File("${staticDir.path}/nested/deep.txt");
    standaloneFile = File("test/fixtures/files/standalone.txt");

    final app = Netto()
      ..static("/", staticDir.path)
      ..static("/assets", staticDir.path)
      ..file("/standalone.txt", standaloneFile.path);

    (server, baseUrl) = await TestUtils.createServer(app.call);
  });

  tearDownAll(() async {
    await server.close(force: true);
  });

  test("Given a static directory "
      "When a file is requested "
      "Then it responds with the file contents", () async {
    final response = await http.get(url("/hello.txt"));

    expect(response.statusCode, HttpStatus.ok);
    expect(response.body, textFile.readAsStringSync());
    expect(
      response.headers[HttpHeaders.contentTypeHeader],
      startsWith("text/plain"),
    );
    expect(response.headers[HttpHeaders.lastModifiedHeader], isNotNull);
    expect(response.headers[HttpHeaders.lastModifiedHeader], isNotEmpty);
    expect(response.headers["accept-ranges"], "bytes");
  });

  test("Given a static directory "
      "When a file is requested with HEAD "
      "Then only metadata is returned", () async {
    final response = await http.head(url("/hello.txt"));

    expect(response.statusCode, HttpStatus.ok);
    expect(response.body, isEmpty);
    expect(response.headers[HttpHeaders.contentLengthHeader], "${textFile.lengthSync()}");
    expect(response.headers["accept-ranges"], "bytes");
  });

  test("Given a static directory "
      "When a nested file is requested "
      "Then the nested path is served", () async {
    final response = await http.get(url("/nested/deep.txt"));

    expect(response.statusCode, HttpStatus.ok);
    expect(response.body, nestedFile.readAsStringSync());
  });

  test("Given a prefixed static directory "
      "When a file is requested "
      "Then the prefix is honored", () async {
    final response = await http.get(url("/assets/nested/deep.txt"));

    expect(response.statusCode, HttpStatus.ok);
    expect(response.body, nestedFile.readAsStringSync());
  });

  test("Given a file handler "
      "When its route is requested "
      "Then the file contents are returned", () async {
    final response = await http.get(url("/standalone.txt"));

    expect(response.statusCode, HttpStatus.ok);
    expect(response.body, standaloneFile.readAsStringSync());
  });

  test("Given a static handler "
      "When a missing file is requested "
      "Then a not found response is returned", () async {
    final response = await http.get(url("/missing.txt"));

    expect(response.statusCode, HttpStatus.notFound);
  });

  test("Given a static handler "
      "When requested with If-Modified-Since "
      "Then it responds with not modified", () async {
    final client = http.Client();
    addTearDown(client.close);

    final ifModifiedSince = http_parser.formatHttpDate(
      DateTime.now().toUtc().add(const Duration(days: 1)),
    );
    final request = http.Request("GET", url("/hello.txt"))..headers[HttpHeaders.ifModifiedSinceHeader] = ifModifiedSince;

    final streamed = await client.send(request);
    final body = await streamed.stream.bytesToString();

    expect(streamed.statusCode, HttpStatus.notModified);
    expect(body, isEmpty);
  });

  test("Given a static handler "
      "When requested with a byte range "
      "Then it serves only the requested portion", () async {
    final client = http.Client();
    addTearDown(client.close);

    final request = http.Request("GET", url("/hello.txt"))..headers[HttpHeaders.rangeHeader] = "bytes=0-4";

    final streamed = await client.send(request);
    final body = await streamed.stream.bytesToString();

    expect(streamed.statusCode, HttpStatus.partialContent);
    expect(body, "Hello");
    expect(
      streamed.headers[HttpHeaders.contentRangeHeader],
      "bytes 0-4/${textFile.lengthSync()}",
    );
    expect(streamed.contentLength, 5);
  });

  test("Given a static handler "
      "When a range is unsatisfiable "
      "Then it responds with requested range not satisfiable", () async {
    final client = http.Client();
    addTearDown(client.close);

    final request = http.Request("GET", url("/hello.txt"))..headers[HttpHeaders.rangeHeader] = "bytes=999-1000";

    final streamed = await client.send(request);
    final body = await streamed.stream.bytesToString();

    expect(streamed.statusCode, HttpStatus.requestedRangeNotSatisfiable);
    expect(
      streamed.headers[HttpHeaders.contentRangeHeader],
      "bytes */${textFile.lengthSync()}",
    );
    expect(body, isEmpty);
  });

  test("Given a static handler "
      "When a HEAD request includes a byte range "
      "Then it responds with headers only", () async {
    final client = http.Client();
    addTearDown(client.close);

    final request = http.Request("HEAD", url("/hello.txt"))..headers[HttpHeaders.rangeHeader] = "bytes=1-3";

    final streamed = await client.send(request);
    final chunks = await streamed.stream.toList();

    expect(streamed.statusCode, HttpStatus.partialContent);
    expect(
      streamed.headers[HttpHeaders.contentRangeHeader],
      "bytes 1-3/${textFile.lengthSync()}",
    );
    expect(streamed.contentLength, 3);
    expect(chunks, isEmpty);
  });
}
