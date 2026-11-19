require "json"
require "pathname"

module ConverterRuntime
  # The generated browser runtime (Rust/WASM glue, workers, TTS libraries) as
  # published under public/runtime/<id>/. The id is the SHA-256 of the tree, so
  # a path is immutable and files keep their relative names.
  class Tree
    MOUNT_PATH = "/runtime".freeze
    RUNTIME_ID = /\A[0-9a-f]{64}\z/

    attr_reader :root

    def initialize(manifest_path:, root:)
      @manifest_path = Pathname(manifest_path)
      @root = Pathname(root)
      @loaded_at = nil
      @manifest = nil
    end

    def available? = !id.nil?

    def id = manifest&.fetch("runtime_id")

    # Trailing slash matters: the page resolves runtime files against it.
    def base_path = available? ? "#{MOUNT_PATH}/#{id}/" : nil

    def file?(relative_path) = manifest ? manifest.fetch("files").key?(relative_path) : false

    def directory = available? ? root.join(id) : nil

    private

    # Re-read after a rebuild so a development server does not need a restart.
    def manifest
      modified_at = @manifest_path.file? ? @manifest_path.mtime : nil
      return @manifest if modified_at == @loaded_at

      @loaded_at = modified_at
      @manifest = modified_at && validated(JSON.parse(@manifest_path.read))
    end

    def validated(manifest)
      valid = manifest.is_a?(Hash) && RUNTIME_ID.match?(manifest["runtime_id"].to_s) && manifest["files"].is_a?(Hash)
      raise ArgumentError, "Invalid converter runtime manifest: #{@manifest_path}" unless valid

      manifest
    end
  end
end
