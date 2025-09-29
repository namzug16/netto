import "dart:convert";
import "dart:io";

import "package:http/http.dart" as http;
import "package:netto/netto.dart";
import "package:test/test.dart";

import "../test_utils.dart";

void main() {
  group("CtxRequestBody", () {
    late Netto app;
    late Router router;
    HttpServer? server;
    late String baseUrl;

    Future<void> startServer() async {
      if (server != null) return;
      final result = await TestUtils.createServer(app.call);
      server = result.$1;
      baseUrl = result.$2;
    }

    Uri url(String path) => Uri.parse("$baseUrl$path");

    Future<http.Response> request(
      String method,
      String path, {
      Map<String, String>? headers,
      Object? body,
    }) async {
      await startServer();
      final req = http.Request(method, url(path));
      if (headers != null) {
        req.headers.addAll(headers);
      }
      if (body != null) {
        switch (body) {
          case final String text:
            req.body = text;
          case final List<int> bytes:
            req.bodyBytes = bytes;
          case final Map<String, String> fields:
            req.bodyFields = fields;
          default:
            throw ArgumentError("Unsupported body type: ${body.runtimeType}");
        }
      }
      final streamed = await req.send();
      return http.Response.fromStream(streamed);
    }

    setUp(() {
      app = Netto();
      router = app.router;
      server = null;
    });

    tearDown(() async {
      await server?.close(force: true);
    });

    test("Given a request body "
        "When read multiple times "
        "Then bytes are cached and accessible as string", () async {
      router.post("/body/bytes", (Ctx ctx) async {
        final consumedBefore = ctx.request.body.isConsumed;
        final first = await ctx.request.body.bytes();
        final second = await ctx.request.body.bytes();
        ctx.response.json({
          "same": identical(first, second),
          "text": utf8.decode(first),
          "consumedBefore": consumedBefore,
          "consumedAfter": ctx.request.body.isConsumed,
        });
      });

      final res = await request("POST", "/body/bytes", body: "hello");
      final json = jsonDecode(res.body) as Map<String, dynamic>;
      expect(json["same"], isTrue);
      expect(json["text"], "hello");
      expect(json["consumedBefore"], isFalse);
      expect(json["consumedAfter"], isTrue);
    });

    test("Given a request body with charset "
        "When decoded "
        "Then the charset is honored", () async {
      router.post("/body/string", (Ctx ctx) async {
        final text = await ctx.request.body.string(latin1);
        ctx.response.string(text);
      });

      final res = await request(
        "POST",
        "/body/string",
        headers: {HttpHeaders.contentTypeHeader: "text/plain; charset=latin1"},
        body: latin1.encode("hêllo"),
      );

      expect(res.body, "hêllo");
    });

    test(
      "Given json request data "
      "When parsed "
      "Then valid content succeeds and invalid content raises HttpException",
      () async {
        router.post("/body/json", (Ctx ctx) async {
          try {
            final data = await ctx.request.body.json();
            ctx.response.json({"ok": data});
          } on HttpException catch (e) {
            ctx.response.string(
              "error:${e.status}:${e.message}",
              status: e.status,
            );
          }
        });

        final ok = await request(
          "POST",
          "/body/json",
          headers: {HttpHeaders.contentTypeHeader: ContentType.json.mimeType},
          body: '{"a":1}',
        );
        expect(jsonDecode(ok.body), {
          "ok": {"a": 1},
        });

        final bad = await request(
          "POST",
          "/body/json",
          headers: {HttpHeaders.contentTypeHeader: ContentType.json.mimeType},
          body: "{invalid}",
        );
        expect(bad.statusCode, HttpStatus.badRequest);
        expect(bad.body, startsWith("error:400"));
      },
    );

    test("Given form urlencoded data "
        "When parsed "
        "Then helpers expose fields and values", () async {
      router.post("/body/form", (Ctx ctx) async {
        final fields = await ctx.request.body.formFields();
        final single = await ctx.request.body.formValue("name");
        final values = await ctx.request.body.formValues("name");
        ctx.response.json({
          "fields": fields,
          "single": single,
          "values": values,
        });
      });

      final res = await request(
        "POST",
        "/body/form",
        headers: {
          HttpHeaders.contentTypeHeader: "application/x-www-form-urlencoded; charset=utf-8",
        },
        body: "name=first&name=second",
      );

      final json = jsonDecode(res.body) as Map<String, dynamic>;
      expect(json["fields"], {
        "name": ["first", "second"],
      });
      expect(json["single"], "first");
      expect(json["values"], ["first", "second"]);
    });

    test("Given an empty body without content type "
        "When parsed best effort "
        "Then it returns empty fields", () async {
      router.post("/body/form-empty", (Ctx ctx) async {
        final fields = await ctx.request.body.formFields(allowBestEffort: true);
        ctx.response.json(fields);
      });

      final res = await request("POST", "/body/form-empty");
      expect(jsonDecode(res.body), isEmpty);
    });

    test("Given a non-multipart request "
        "When requesting a form file "
        "Then an error is thrown", () async {
      router.post("/body/formfile", (Ctx ctx) async {
        try {
          await ctx.request.body.formFile("upload");
        } on HttpException catch (e) {
          ctx.response.string("error:${e.status}", status: e.status);
        }
      });

      final res = await request("POST", "/body/formfile", body: "plain");
      expect(res.statusCode, HttpStatus.unsupportedMediaType);
      expect(res.body, "error:415");
    });

    test("Given the request body stream "
        "When consumed twice "
        "Then the second access throws", () async {
      router.post("/body/stream", (Ctx ctx) async {
        final first = await utf8.decodeStream(ctx.request.body.stream());
        bool threw = false;
        try {
          await ctx.request.body.stream().toList();
        } on StateError {
          threw = true;
        }
        ctx.response.json({"data": first, "error": threw});
      });

      final res = await request("POST", "/body/stream", body: "chunk");
      final json = jsonDecode(res.body) as Map<String, dynamic>;
      expect(json, {"data": "chunk", "error": true});
    });

    test("Given a multipart form submission "
        "When parsed "
        "Then fields and files are accessible", () async {
      router.post("/body/multipart", (Ctx ctx) async {
        final form = await ctx.request.body.multipart();
        final file = form.files.single;
        final fileContent = utf8.decode(await file.readAsBytes());
        await file.delete();

        ctx.response.json({
          "field": form.fields["text"]?.first,
          "file": {
            "field": file.fieldName,
            "name": file.filename,
            "length": file.length,
            "content": fileContent,
          },
        });
      });

      const boundary = "abc123";
      final body = [
        "--$boundary",
        'Content-Disposition: form-data; name="text"',
        "",
        "hello",
        "--$boundary",
        'Content-Disposition: form-data; name="upload"; filename="file.txt"',
        "Content-Type: text/plain",
        "",
        "file-body",
        "--$boundary--",
        "",
      ].join("\r\n");

      final res = await request(
        "POST",
        "/body/multipart",
        headers: {
          HttpHeaders.contentTypeHeader: "multipart/form-data; boundary=$boundary",
        },
        body: body,
      );

      final json = jsonDecode(res.body) as Map<String, dynamic>;
      expect(json["field"], "hello");
      final fileJson = json["file"] as Map<String, dynamic>;
      expect(fileJson["field"], "upload");
      expect(fileJson["name"], "file.txt");
      expect(fileJson["length"], 9);
      expect(fileJson["content"], "file-body");
    });

    test("Given a multipart body "
        "When parsed multiple times "
        "Then cached results are reused", () async {
      router.post("/body/multipart/reuse", (Ctx ctx) async {
        final first = await ctx.request.body.multipart();
        final second = await ctx.request.body.multipart();
        final file = second.files.single;
        final bytes = await file.readAsBytes();
        await file.delete();

        ctx.response.json({
          "sameInstance": identical(first, second),
          "field": second.fields["text"]?.first,
          "fileLength": bytes.length,
        });
      });

      const boundary = "reuse";
      final body = [
        "--$boundary",
        'Content-Disposition: form-data; name="text"',
        "",
        "cached",
        "--$boundary",
        'Content-Disposition: form-data; name="upload"; filename="data.bin"',
        "Content-Type: application/octet-stream",
        "",
        "123456",
        "--$boundary--",
        "",
      ].join("\r\n");

      final res = await request(
        "POST",
        "/body/multipart/reuse",
        headers: {
          HttpHeaders.contentTypeHeader: "multipart/form-data; boundary=$boundary",
        },
        body: body,
      );

      final json = jsonDecode(res.body) as Map<String, dynamic>;
      expect(json["sameInstance"], isTrue);
      expect(json["field"], "cached");
      expect(json["fileLength"], 6);
    });

    test("Given the body stream is consumed "
        "When bytes are requested "
        "Then a StateError is thrown", () async {
      router.post("/body/stream-consumed", (Ctx ctx) async {
        await ctx.request.body.stream().drain();
        try {
          await ctx.request.body.bytes();
          ctx.response.string("unexpected");
        } on StateError catch (error) {
          ctx.response.string("error:${error.message}");
        }
      });

      final res = await request("POST", "/body/stream-consumed", body: "data");
      expect(res.body, startsWith("error:Request body stream already consumed."));
    });

    test("Given a non urlencoded content type "
        "When formUrlencoded is requested "
        "Then an unsupported media type error is thrown", () async {
      router.post("/body/form-unsupported", (Ctx ctx) async {
        try {
          await ctx.request.body.formUrlencoded();
          ctx.response.string("unexpected");
        } on HttpException catch (error) {
          ctx.response.string("error:${error.status}", status: error.status);
        }
      });

      final res = await request(
        "POST",
        "/body/form-unsupported",
        headers: {HttpHeaders.contentTypeHeader: "text/plain"},
        body: "a=b",
      );

      expect(res.statusCode, HttpStatus.unsupportedMediaType);
      expect(res.body, "error:415");
    });

    test("Given cached urlencoded data "
        "When multipart parsing is forced "
        "Then a 415 error is returned", () async {
      router.post("/body/form-to-multipart", (Ctx ctx) async {
        try {
          await ctx.request.body.formFields();
          await ctx.request.body.multipart();
          ctx.response.string("unexpected");
        } on HttpException catch (error) {
          ctx.response.string("error:${error.status}", status: error.status);
        }
      });

      final res = await request(
        "POST",
        "/body/form-to-multipart",
        headers: {
          HttpHeaders.contentTypeHeader: "application/x-www-form-urlencoded; charset=utf-8",
        },
        body: "field=value",
      );

      expect(res.statusCode, HttpStatus.unsupportedMediaType);
      expect(res.body, "error:415");
    });

    test("Given a multipart request without a boundary "
        "When parsed "
        "Then a bad request error is produced", () async {
      router.post("/body/multipart-missing-boundary", (Ctx ctx) async {
        try {
          await ctx.request.body.multipart();
          ctx.response.string("unexpected");
        } on HttpException catch (error) {
          ctx.response.string("error:${error.status}", status: error.status);
        }
      });

      final res = await request(
        "POST",
        "/body/multipart-missing-boundary",
        headers: {
          HttpHeaders.contentTypeHeader: "multipart/form-data",
        },
        body: "--boundary--\r\n",
      );

      expect(res.statusCode, HttpStatus.badRequest);
      expect(res.body, "error:400");
    });

    test("Given a multipart request with a consumed stream "
        "When parsed "
        "Then a StateError is thrown", () async {
      router.post("/body/multipart-consumed", (Ctx ctx) async {
        await ctx.request.body.stream().drain();
        try {
          await ctx.request.body.multipart();
          ctx.response.string("unexpected");
        } on StateError catch (error) {
          ctx.response.string("error:${error.message}");
        }
      });

      const boundary = "consumed";
      final body = [
        "--$boundary",
        'Content-Disposition: form-data; name="field"',
        "",
        "value",
        "--$boundary--",
        "",
      ].join("\r\n");

      final res = await request(
        "POST",
        "/body/multipart-consumed",
        headers: {
          HttpHeaders.contentTypeHeader: "multipart/form-data; boundary=$boundary",
        },
        body: body,
      );

      expect(res.body, startsWith("error:Request body stream already consumed."));
    });

    test("Given multipart parts without names "
        "When parsed "
        "Then nameless parts are ignored", () async {
      router.post("/body/multipart-unnamed", (Ctx ctx) async {
        final form = await ctx.request.body.multipart();
        ctx.response.json(form.fields);
      });

      const boundary = "skip";
      final body = [
        "--$boundary",
        'Content-Disposition: form-data; filename="file.txt"',
        "",
        "ignored",
        "--$boundary",
        'Content-Disposition: form-data; name="actual"',
        "",
        "value",
        "--$boundary--",
        "",
      ].join("\r\n");

      final res = await request(
        "POST",
        "/body/multipart-unnamed",
        headers: {
          HttpHeaders.contentTypeHeader: "multipart/form-data; boundary=$boundary",
        },
        body: body,
      );

      final fields = jsonDecode(res.body) as Map<String, dynamic>;
      expect(fields.keys, ["actual"]);
      expect(fields["actual"], ["value"]);
    });

    test("Given multipart field limits "
        "When exceeded "
        "Then a 413 error is returned", () async {
      router.post("/body/multipart-max-fields", (Ctx ctx) async {
        try {
          await ctx.request.body.multipart(
            limits: const MultipartLimits(maxFields: 1),
          );
          ctx.response.string("unexpected");
        } on HttpException catch (error) {
          ctx.response.string("error:${error.status}", status: error.status);
        }
      });

      const boundary = "fields";
      final body = [
        "--$boundary",
        'Content-Disposition: form-data; name="a"',
        "",
        "1",
        "--$boundary",
        'Content-Disposition: form-data; name="b"',
        "",
        "2",
        "--$boundary--",
        "",
      ].join("\r\n");

      final res = await request(
        "POST",
        "/body/multipart-max-fields",
        headers: {
          HttpHeaders.contentTypeHeader: "multipart/form-data; boundary=$boundary",
        },
        body: body,
      );

      expect(res.statusCode, HttpStatus.requestEntityTooLarge);
      expect(res.body, "error:413");
    });

    test("Given multipart total size limits "
        "When exceeded "
        "Then a 413 error is thrown", () async {
      router.post("/body/multipart-total-size", (Ctx ctx) async {
        try {
          await ctx.request.body.multipart(
            limits: const MultipartLimits(maxTotalSize: 5),
          );
          ctx.response.string("unexpected");
        } on HttpException catch (error) {
          ctx.response.string("error:${error.status}", status: error.status);
        }
      });

      const boundary = "totals";
      final body = [
        "--$boundary",
        'Content-Disposition: form-data; name="field"',
        "",
        "abcdef",
        "--$boundary--",
        "",
      ].join("\r\n");

      final res = await request(
        "POST",
        "/body/multipart-total-size",
        headers: {
          HttpHeaders.contentTypeHeader: "multipart/form-data; boundary=$boundary",
        },
        body: body,
      );

      expect(res.statusCode, HttpStatus.requestEntityTooLarge);
      expect(res.body, "error:413");
    });

    test("Given an uploaded file "
        "When using the helper methods "
        "Then reading path and deletion work", () async {
      final tmp = await File(
        "${Directory.systemTemp.path}/uploaded_test_${DateTime.now().microsecondsSinceEpoch}",
      ).create();
      await tmp.writeAsString("data");

      final uploaded = UploadedFile(
        fieldName: "file",
        filename: "test.txt",
        contentType: ContentType.text,
        length: await tmp.length(),
        tmpFile: tmp,
      );

      final chunks = await uploaded.openRead().expand((chunk) => chunk).toList();
      expect(String.fromCharCodes(chunks), "data");

      final bytes = await uploaded.readAsBytes();
      expect(bytes, utf8.encode("data"));
      expect(uploaded.path, tmp.path);

      await uploaded.delete();
      expect(await tmp.exists(), isFalse);
    });
  });
}
