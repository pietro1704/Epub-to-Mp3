# frozen_string_literal: true

require "optparse"
require "digest"
require "tempfile"

# Apply a single explicit byte patch to a verified baseline, preserving aliases.
module UpdateInstruction
  def self.apply(root:, destination:, baseline:, sha256:, old:, new:)
    root = File.realpath(root)
    target = File.realpath(destination)
    raise "Destination is outside declared root" unless target.start_with?(root + File::SEPARATOR)
    raise "Destination must be a regular file" unless File.file?(target)

    original = File.binread(baseline)
    raise "Invalid baseline SHA256" unless sha256.match?(/\A[0-9a-f]{64}\z/i) &&
                                           Digest::SHA256.hexdigest(original) == sha256.downcase
    old_bytes = File.binread(old)
    new_bytes = File.binread(new)
    raise "Old text must be nonempty" if old_bytes.empty?
    # Count overlapping occurrences too: either occurrence would be ambiguous.
    positions = []
    offset = 0
    while (position = original.index(old_bytes, offset))
      positions << position
      offset = position + 1
    end
    raise "Expected exactly one occurrence of old text in baseline" unless positions.length == 1
    expected = original.dup
    expected[positions.first, old_bytes.bytesize] = new_bytes

    # Cooperating invocations serialize across replacement of the target inode.
    # The lock is on the parent directory, so no extra project artifact is created.
    File.open(File.dirname(target), File::RDONLY) do |lock|
      raise "Another instruction update is active" unless lock.flock(File::LOCK_EX | File::LOCK_NB)
      raise "Destination changed during validation" unless File.realpath(destination) == target
      current = File.binread(target)
      return "Already applied: #{target}" if current == expected
      raise "Destination differs from baseline; inspect concurrent changes" unless current == original
      mode = File.stat(target).mode & 0o777
      Tempfile.create([".instruction-", ".tmp"], File.dirname(target)) do |temporary|
        temporary.binmode
        temporary.write(expected)
        temporary.flush
        temporary.fsync
        File.chmod(mode, temporary.path)
        raise "Destination changed during update" unless File.realpath(destination) == target &&
                                                          File.binread(target) == original
        File.rename(temporary.path, target)
      end
    end
    "Updated: #{target}"
  end

  def self.run(arguments)
    options = {}
    parser = OptionParser.new do |flags|
      flags.banner = "Usage: update_instruction.rb --root ROOT --destination FILE --baseline FILE --sha256 HASH --old FILE --new FILE"
      %i[root destination baseline sha256 old new].each do |key|
        flags.on("--#{key} VALUE") { |value| options[key] = value }
      end
    end
    parser.parse!(arguments)
    raise OptionParser::InvalidArgument, "Unexpected arguments" unless arguments.empty?
    missing = %i[root destination baseline sha256 old new] - options.keys
    raise OptionParser::MissingArgument, missing.join(", ") unless missing.empty?
    puts apply(**options)
    0
  rescue OptionParser::ParseError, SystemCallError, RuntimeError => error
    warn "Instruction update blocked: #{error.message}"
    1
  end
end

exit UpdateInstruction.run(ARGV) if $PROGRAM_NAME == __FILE__
