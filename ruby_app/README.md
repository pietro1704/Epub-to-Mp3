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

The boundary is intentionally dependency-light and works on the existing Ruby 2.6 development machine. A future Rails API can reuse the client and keep Rails responsible for authentication, persistence, and jobs without duplicating conversion logic.
