# Ruby gateway

This is the Ruby web boundary for EpubToMp3. It deliberately contains no EPUB, TTS, audio, cache, or conversion domain logic. It delegates to the Rust Axum server through `EpubToMp3::RustClient`.

Run tests:

```sh
ruby -I. test/rust_client_test.rb
```

Run the gateway against Rust on `127.0.0.1:8787`:

```sh
RUST_CONVERTER_URL=http://127.0.0.1:8787 ruby server.rb
curl http://127.0.0.1:9292/health
curl http://127.0.0.1:9292/api/metadata
```

The development bundle requires Ruby 3.2 or newer for Minitest 6 and Bundler 4; the project pins Ruby 4.0.10. The boundary remains dependency-light. The Rails gateway reuses the client and keeps Rails responsible for authentication, persistence, and jobs without duplicating conversion logic.

`rails_gateway/` is also the Rails web client (it replaced the former React client in `web/`, removed in the Rails cutover); see `rails_gateway/README.md`. Its `/books…` and `/api/metadata` routes are the server-side compatibility API and are mounted only when `RUST_CONVERTER_URL` is set.
