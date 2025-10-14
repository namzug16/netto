import "dart:io";

import "package:htmdart/htmdart.dart";
import "package:netto/netto.dart";

Future<void> main() async {
  final app = Netto()
    ..get(
      "/",
      (ctx) => ctx.response.html(
        html([
          head([
            script([
              $src("https://unpkg.com/htmx.org@2.0.4"),
            ]),
          ]),
          body([
            h1(["Hello from htmdart + Netto".t]),
            button([
              $hx.post("/clicked"),
              $hx.target("#container"),
              "Click me".t,
            ]),
            div([$id("container")]),
          ]),
        ]).toHtml(),
      ),
    )
    ..post(
      "/clicked",
      (ctx) => ctx.response.html(
        div([
          $id("container"),
          "Button clicked at ${DateTime.now()}".t,
        ]).toHtml(),
      ),
    );

  await app.serve(InternetAddress.anyIPv4, 8080);
}
