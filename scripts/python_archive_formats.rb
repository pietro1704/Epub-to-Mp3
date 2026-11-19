# frozen_string_literal: true

# Byte-compatible Ruby replacements for the Python stdlib archive encoders the
# hosted Linux GUI artifact evidence used: gzip.GzipFile and tarfile PAX_FORMAT
# archives (CPython 3.14 behavior). JSON output lives in python_json.rb.
require 'zlib'

module PythonFormats
  class Error < StandardError; end

  class GzipWriter
    def initialize(path, mtime: nil)
      mtime ||= Time.now.to_i
      mtime = 0 unless mtime.between?(0, (2**32) - 1)
      name = File.basename(path).b.delete_suffix('.gz')
      flags = name.empty? ? "\0" : "\x08"
      fname = name.empty? ? '' : "#{name}\0"
      @file = File.open(path, 'wb')
      @file.write("\x1f\x8b\x08#{flags}".b + [mtime].pack('V') + "\x02\xff".b + fname.b)
      @deflate = Zlib::Deflate.new(9, -Zlib::MAX_WBITS, Zlib::DEF_MEM_LEVEL, Zlib::DEFAULT_STRATEGY)
      @crc = Zlib.crc32
      @size = 0
    end

    def write(data)
      data = data.b
      @crc = Zlib.crc32(data, @crc)
      @size += data.bytesize
      @file.write(@deflate.deflate(data))
      data.bytesize
    end

    def close
      @file.write(@deflate.finish)
      @file.write([@crc, @size & 0xffffffff].pack('VV'))
      @file.close
    end
  end

  # tarfile PAX_FORMAT output for TarInfo defaults (uid/gid 0, empty uname and
  # gname, mtime 0), including end-of-archive blocks and record padding.
  class TarWriter
    BLOCK = 512
    RECORD = BLOCK * 20
    MAGIC = "ustar\0" + '00' # tarfile.POSIX_MAGIC

    def initialize(io)
      @io = io
      @offset = 0
    end

    def add_directory(name, mode)
      name += '/' unless name.end_with?('/')
      emit(member_header(name, mode, 0, '5'))
    end

    def add_file(name, mode, path, size)
      emit(member_header(name, mode, size, '0'))
      copied = File.open(path, 'rb') { |source| IO.copy_stream(source, @io, size) }
      raise Error, "unexpected end of data: #{path}" unless copied == size

      @offset += size
      pad(size)
    end

    def close
      emit("\0" * (BLOCK * 2))
      remainder = @offset % RECORD
      emit("\0" * (RECORD - remainder)) if remainder.positive?
    end

    private

    def member_header(name, mode, size, type)
      pax = !name.ascii_only? || name.length > 100 ? { 'path' => name } : {}
      ascii = name.encode('US-ASCII', invalid: :replace, undef: :replace, replace: '?')
      (pax.empty? ? ''.b : pax_header(pax)) + header(ascii, mode & 0o7777, size, type)
    end

    def pax_header(values)
      records = values.map do |keyword, value|
        length = keyword.bytesize + value.bytesize + 3
        total = 0
        total = length + total.to_s.length until length + total.to_s.length == total
        "#{total} #{keyword}=#{value}\n".b
      end.join.b
      payload = records + ("\0" * ((BLOCK - (records.bytesize % BLOCK)) % BLOCK))
      header('././@PaxHeader', 0, records.bytesize, 'x') + payload
    end

    def header(name, mode, size, type)
      fields = [field(name, 100), octal(mode, 8), octal(0, 8), octal(0, 8), octal(size, 12),
                octal(0, 12), ' ' * 8, type, field('', 100), MAGIC, field('', 32), field('', 32),
                field('', 8), field('', 8), field('', 155)]
      block = fields.map(&:b).join.ljust(BLOCK, "\0")
      block[0, 148] + format("%06o\0", block.bytes.sum).b + block[155..]
    end

    def field(text, length) = text.b[0, length].ljust(length, "\0")

    def octal(number, digits)
      raise Error, 'overflow in number field' unless number.between?(0, (8**(digits - 1)) - 1)

      format("%0#{digits - 1}o\0", number)
    end

    def pad(size)
      remainder = size % BLOCK
      emit("\0" * (BLOCK - remainder)) if remainder.positive?
    end

    def emit(bytes)
      @io.write(bytes)
      @offset += bytes.bytesize
    end
  end
end
