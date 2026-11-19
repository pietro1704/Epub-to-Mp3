require "digest"
require "fileutils"
require "json"
require "pathname"
require_relative "tree"

module ConverterRuntime
  # Publishes already-built runtime files as one content-addressed tree and
  # writes the manifest Rails reads. It never compiles: the Rust/WASM and
  # browser library builds hand their output directories to it.
  class Assembler
    REQUIRED_FILES = %w[wasm/converter_wasm.js wasm/converter_wasm_bg.wasm].freeze

    # sources maps a subtree name ("wasm", "tts", "workers") to a directory.
    def initialize(sources:, output_root:, manifest_path:)
      @sources = sources.transform_values { |directory| Pathname(directory) }
      @output_root = Pathname(output_root)
      @manifest_path = Pathname(manifest_path)
    end

    def call
      files = collect_files
      missing = REQUIRED_FILES - files.keys
      raise ArgumentError, "Converter runtime is missing #{missing.join(', ')}" unless missing.empty?

      runtime_id = tree_digest(files)
      publish(files, @output_root.join(runtime_id))
      remove_stale_trees(runtime_id)
      write_manifest(runtime_id, files)
      runtime_id
    end

    private

    def collect_files
      @sources.each_with_object({}) do |(subtree, directory), files|
        raise ArgumentError, "Converter runtime source is not a directory: #{directory}" unless directory.directory?

        directory.glob("**/*").select(&:file?).sort.each do |source|
          raise ArgumentError, "Converter runtime file is empty: #{source}" if source.zero?

          files[File.join(subtree, source.relative_path_from(directory).to_s)] = source
        end
      end
    end

    def tree_digest(files)
      digest = Digest::SHA256.new
      files.sort.each { |relative_path, source| digest << relative_path << "\0" << Digest::SHA256.file(source).hexdigest << "\n" }
      digest.hexdigest
    end

    def publish(files, destination)
      FileUtils.rm_rf(destination)
      files.each do |relative_path, source|
        target = destination.join(relative_path)
        FileUtils.mkdir_p(target.dirname)
        FileUtils.cp(source, target)
      end
    end

    def remove_stale_trees(runtime_id)
      @output_root.children.each do |entry|
        name = entry.basename.to_s
        FileUtils.rm_rf(entry) if entry.directory? && name != runtime_id && Tree::RUNTIME_ID.match?(name)
      end
    end

    def write_manifest(runtime_id, files)
      entries = files.sort.to_h do |relative_path, source|
        [ relative_path, { "sha256" => Digest::SHA256.file(source).hexdigest, "bytes" => source.size } ]
      end
      FileUtils.mkdir_p(@manifest_path.dirname)
      @manifest_path.write(JSON.pretty_generate("runtime_id" => runtime_id, "files" => entries) + "\n")
    end
  end
end
