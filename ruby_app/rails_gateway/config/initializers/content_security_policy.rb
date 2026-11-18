# Be sure to restart your server when you modify this file.

# The page loads only same-origin modules, the Rust/WASM runtime and workers.
# Catalog weights resolve from huggingface.co to us.aws.cdn.hf.co.
EMBEDDING_ORIGINS = [ "'self'", "https://huggingface.co" ].freeze

Rails.application.configure do
  config.content_security_policy do |policy|
    policy.default_src :self
    policy.script_src :self, :wasm_unsafe_eval
    policy.style_src :self
    policy.worker_src :self, :blob
    policy.media_src :self, :blob
    policy.img_src :self, :data, :blob
    policy.connect_src :self, :blob, "https://huggingface.co", "https://us.aws.cdn.hf.co"
    policy.frame_ancestors(*EMBEDDING_ORIGINS)
  end

  # The import map is an inline script and Turbo injects its progress-bar
  # style; a per-response nonce admits both.
  config.content_security_policy_nonce_generator = ->(_request) { SecureRandom.base64(16) }
  config.content_security_policy_nonce_directives = %w[script-src style-src]

  # frame-ancestors replaces the same-origin-only X-Frame-Options default.
  config.action_dispatch.default_headers = config.action_dispatch.default_headers.except("X-Frame-Options")
end
