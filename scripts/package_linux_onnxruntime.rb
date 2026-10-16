require 'digest'
require 'fileutils'
require 'open3'

# Inspect ELF metadata without loading build inputs or searching host libraries.
module PackageLinuxOnnxruntime
  class Failure < StandardError; end

  def self.dynamic_entries(path)
    output, status = Open3.capture2e({'LC_ALL' => 'C'}, 'readelf', '--dynamic', path)
    raise Failure, "Cannot inspect ELF dependencies: #{path}: #{output}" unless status.success?
    output
  rescue SystemCallError => error
    raise Failure, "Required ELF inspection failed: #{error.message}"
  end

  def self.architecture(path)
    header = File.binread(path, 20)
    unless header.bytesize == 20 && header.start_with?("\x7fELF") &&
        [1, 2].include?(header.getbyte(4)) && [1, 2].include?(header.getbyte(5)) && header.getbyte(6) == 1
      raise Failure, "Invalid ELF architecture: #{path}"
    end
    [header.getbyte(4), header.getbyte(5), header.byteslice(18, 2).unpack1(header.getbyte(5) == 1 ? 'v' : 'n')]
  end

  def self.copy!(executable:, directory:, runtime_directory:)
    entries = dynamic_entries(executable)
    dependencies = entries.scan(/\(NEEDED\).*?\[([^\]]+)\]/).flatten.grep(/onnxruntime/)
    return if dependencies.empty? # A truly static ORT build needs no shared payload.
    unless dependencies.length == 1 && dependencies.first.match?(/\Alibonnxruntime\.so(?:\.\d+)*\z/)
      raise Failure, 'The executable has an unsupported or ambiguous ONNX Runtime dependency'
    end
    needed = dependencies.first
    selected_root = File.realpath(runtime_directory)
    linker_name = File.join(selected_root, 'libonnxruntime.so')
    raise Failure, "Selected ONNX Runtime is missing: #{linker_name}" unless File.file?(linker_name)
    selected = File.realpath(linker_name)
    raise Failure, 'Selected ONNX Runtime escapes its declared library directory' unless File.dirname(selected) == selected_root
    soname_alias = File.join(selected_root, needed)
    if (File.exist?(soname_alias) || File.symlink?(soname_alias)) && File.realpath(soname_alias) != selected
      raise Failure, 'Selected ONNX Runtime linker and SONAME paths identify different files'
    end
    sonames = dynamic_entries(selected).scan(/\(SONAME\).*?\[([^\]]+)\]/).flatten
    raise Failure, 'Selected ONNX Runtime SONAME differs from the executable dependency' unless sonames == [needed]
    raise Failure, 'Selected ONNX Runtime ELF architecture differs from the executable' unless architecture(selected) == architecture(executable)
    destination = File.join(directory, needed)
    FileUtils.cp(selected, destination)
    unless File.file?(destination) && !File.symlink?(destination) && Digest::SHA256.file(destination).hexdigest == Digest::SHA256.file(selected).hexdigest
      raise Failure, 'Packaged ONNX Runtime bytes differ from the selected dependency'
    end
    destination
  rescue SystemCallError => error
    raise Failure, "Cannot package selected ONNX Runtime: #{error.message}"
  end
end
