#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export PATH="$HOME/.local/bin:$HOME/.cargo/bin:$PATH"
PORT="${RUST_PORT:-18000}"
FIXTURE="${E2E_EPUB:-$ROOT/python_app/tests/fixtures/epubs/test_multifeature.epub}"
TMP="$(mktemp -d)"
cleanup() { [[ -n "${RUST_PID:-}" ]] && kill "$RUST_PID" 2>/dev/null || true; rm -rf "$TMP"; }
trap cleanup EXIT
[[ -f "$FIXTURE" ]] || { echo "fixture not found: $FIXTURE" >&2; exit 1; }
(cd "$ROOT" && PORT="$PORT" cargo run -p converter-server >"$TMP/rust.log" 2>&1) & RUST_PID=$!
for _ in $(seq 1 90); do curl -fsS "http://127.0.0.1:$PORT/health" >/dev/null && break || sleep 1; done
curl -fsS "http://127.0.0.1:$PORT/health" >/dev/null
(export E2E_EPUB="$FIXTURE"; cd "$ROOT/ruby_app/rails_gateway"; RUST_CONVERTER_URL="http://127.0.0.1:$PORT" RAILS_ENV=test bundle exec rails runner - <<'RUBY'
require "json"
fixture = ENV.fetch("E2E_EPUB")
Book.delete_all
book = Book.create!(title: File.basename(fixture, ".epub"), source_path: fixture)
ConvertBookJob.perform_now(book.id, { engine: ENV.fetch("E2E_ENGINE", "edge"), language: "pt-BR" })
book.reload
abort "conversion did not create a Rust job" if book.job_id.to_s.empty?
client = RustClient.new
deadline = Time.now + Integer(ENV.fetch("E2E_TIMEOUT", "300"))
loop do
  payload = client.job(book.job_id)
  state = payload.fetch("state")
  abort JSON.generate(payload) if %w[failed cancelled interrupted].include?(state)
  break if %w[finished completed].include?(state)
  abort "timeout waiting for #{book.job_id}" if Time.now >= deadline
  sleep 2
end
payload = client.job(book.job_id)
outputs = payload.fetch("outputs")
abort "no outputs" if outputs.empty?
outputs.each do |asset|
  bytes, = client.output(book.job_id, asset.fetch("name"))
  abort "empty output #{asset.fetch("name")}" if bytes.bytesize.zero?
end
puts JSON.generate(bookId: book.id, jobId: book.job_id, state: payload.fetch("state"), outputs: outputs)
RUBY
)
