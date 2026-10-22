# frozen_string_literal: true

# GitHub's Ubuntu runner can select Azure through a mirror+file source. Keep
# APT's existing suites, keyrings and mirror selection; change only that URI.
module UbuntuPackageMirror
  DEFAULT_PATHS = %w[/etc/apt/sources.list.d/ubuntu.sources /etc/apt/sources.list /etc/apt/apt-mirrors.txt].freeze
  AZURE_URI = %r{https?://azure\.archive\.ubuntu\.com/ubuntu(/?)(?=\s|\z)}

  def self.run(paths)
    paths = DEFAULT_PATHS if paths.empty?
    existing = paths.select { |path| File.exist?(path) }
    raise ArgumentError, 'No APT source files found' if existing.empty?

    # Validate the full inventory before writing any file.
    changes = existing.filter_map do |path|
      raise ArgumentError, "APT source must be a regular file: #{path}" unless File.file?(path) && !File.symlink?(path)

      original = File.binread(path)
      normalized = original.lines.map do |line|
        active, marker, comment = line.partition('#')
        active = active.gsub(AZURE_URI) { "https://archive.ubuntu.com/ubuntu#{Regexp.last_match(1)}" }
        if active.include?('azure.archive.ubuntu.com')
          raise ArgumentError, "Unsupported Azure archive URI in #{path}"
        end
        active + marker + comment
      end.join
      [path, normalized] unless normalized == original
    end
    changes.each { |path, bytes| File.binwrite(path, bytes) }
    puts "Ubuntu package mirror: inspected=#{existing.length} updated=#{changes.length}"
    0
  rescue ArgumentError, SystemCallError => error
    warn error.message
    1
  end
end

exit UbuntuPackageMirror.run(ARGV) if $PROGRAM_NAME == __FILE__
