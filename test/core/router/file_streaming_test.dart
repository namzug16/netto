import "dart:io";

import "package:http/http.dart" as http;
import "package:netto/netto.dart";
import "package:test/test.dart";

import "../../test_utils.dart";

void main() {
  late HttpServer server;
  late String baseUrl;
  late Directory tempDir;
  late File largeFile;
  late List<int> largeBytes;

  Uri url(String path) => Uri.parse("$baseUrl$path");

  setUpAll(() async {
    tempDir = await Directory.systemTemp.createTemp("netto-large-file-test-");
    largeFile = File("${tempDir.path}/large.bin");
    largeBytes = List<int>.generate(2 * 1024 * 1024, (index) => index % 256);
    await largeFile.writeAsBytes(largeBytes, flush: true);

    final app = Netto()..file("/large.bin", largeFile.path);

    (server, baseUrl) = await TestUtils.createServer(app.call);
  });

  tearDownAll(() async {
    await server.close(force: true);
    if (tempDir.existsSync()) {
      await tempDir.delete(recursive: true);
    }
  });

  test("Given a large file "
      "When it is requested "
      "Then the response streams with the full content", () async {
    final client = http.Client();
    addTearDown(client.close);

    final request = http.Request("GET", url("/large.bin"));
    final streamed = await client.send(request);
    final chunks = await streamed.stream.toList();
    final body = chunks.expand((chunk) => chunk).toList();

    expect(streamed.statusCode, HttpStatus.ok);
    expect(streamed.contentLength, largeBytes.length);
    expect(body.length, largeBytes.length);
    expect(body, largeBytes);
  });

  test("Given a large file "
      "When it is requested with HEAD "
      "Then headers are returned without a body", () async {
    final response = await http.head(url("/large.bin"));

    expect(response.statusCode, HttpStatus.ok);
    expect(
      response.headers[HttpHeaders.contentLengthHeader],
      "${largeBytes.length}",
    );
    expect(response.bodyBytes, isEmpty);
  });

  test("Given a large file "
      "When a byte range is requested "
      "Then only the requested bytes are streamed", () async {
    final client = http.Client();
    addTearDown(client.close);

    const start = 1024;
    const end = start + 2048 - 1;

    final request = http.Request("GET", url("/large.bin"))..headers[HttpHeaders.rangeHeader] = "bytes=$start-$end";

    final streamed = await client.send(request);
    final chunks = await streamed.stream.toList();
    final body = chunks.expand((chunk) => chunk).toList();

    expect(streamed.statusCode, HttpStatus.partialContent);
    expect(streamed.contentLength, end - start + 1);
    expect(
      streamed.headers[HttpHeaders.contentRangeHeader],
      "bytes $start-$end/${largeBytes.length}",
    );
    expect(body, largeBytes.sublist(start, end + 1));
  });
}
