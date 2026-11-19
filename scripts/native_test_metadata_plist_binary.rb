# frozen_string_literal: true

module NativeTestMetadataPlist
  FORMATS = { 1 => "C", 2 => "n", 4 => "N", 8 => "Q>" }.freeze
  EPOCH_MIN = -730_485 * 86_400
  EPOCH_MAX = 2_921_574 * 86_400

  # Mirrors plistlib._BinaryPlistParser over a BytesIO-like cursor.
  class BinaryReader
    UNDEFINED = Object.new.freeze

    def initialize(data)
      @data = data
      @position = 0
    end

    def parse
      raise Invalid, "negative seek value" if @data.bytesize < 32

      @position = @data.bytesize - 32
      trailer = read(32)
      offset_size, @ref_size = trailer.byteslice(6, 2).unpack("CC")
      count, top, table = trailer.byteslice(8, 24).unpack("Q>Q>Q>")
      seek(table)
      @offsets = read_ints(count, offset_size)
      @objects = Hash.new(UNDEFINED)
      @count = count
      read_object(top, 1)
    end

    private

    def read(length)
      return "".b if @position >= @data.bytesize

      chunk = @data.byteslice(@position, [length, @data.bytesize - @position].min)
      @position += chunk.bytesize
      chunk
    end

    def seek(position)
      raise Invalid, "seek out of range" if position > MAX_SIGNED

      @position = position
    end

    def unpack(length, format)
      bytes = read(length)
      raise Invalid, "struct.error" unless bytes.bytesize == length

      bytes.unpack1(format)
    end

    def read_ints(count, size)
      data = read(size * count)
      raise Invalid, "struct.error" if size.zero? || data.bytesize != size * count

      Array.new(count) { |index| data.byteslice(index * size, size).unpack1("H*").to_i(16) }
    end

    def size(low)
      return low unless low == 0x0F

      marker = read(1)
      raise Invalid, "IndexError" if marker.empty?

      width = 1 << (marker.getbyte(0) & 0x3)
      unpack(width, FORMATS.fetch(width))
    end

    def integer(bytes, signed)
      value = bytes.empty? ? 0 : bytes.unpack1("H*").to_i(16)
      signed && !bytes.empty? && bytes.getbyte(0) >= 0x80 ? value - (1 << (8 * bytes.bytesize)) : value
    end

    def read_object(ref, depth)
      raise Recursion, "maximum recursion depth exceeded" if depth >= RECURSION_DEPTH
      raise Invalid, "IndexError" if ref >= @count

      cached = @objects[ref]
      return cached unless cached.equal?(UNDEFINED)

      seek(@offsets[ref])
      token = read(1)
      raise Invalid, "IndexError" if token.empty?

      token = token.getbyte(0)
      high = token & 0xF0
      low = token & 0x0F
      result = case
               when token == 0x00 then nil
               when token == 0x08 then false
               when token == 0x09 then true
               when token == 0x0F then Data.new("".b)
               when high == 0x10 then integer(read(1 << low), low >= 3)
               when token == 0x22 then unpack(4, "g")
               when token == 0x23 then unpack(8, "G")
               when token == 0x33 then date(unpack(8, "G"))
               when high == 0x40 then Data.new(exact(size(low)))
               when high == 0x50 then ascii(exact(size(low)))
               when high == 0x60 then utf16(exact(size(low) * 2))
               when high == 0x80 then Uid.new(integer(read(1 + low), false))
               when high == 0xA0 then array(ref, size(low), depth)
               when high == 0xD0 then dictionary(ref, size(low), depth)
               else raise Invalid, "unknown token"
               end
      @objects[ref] = result
    end

    def exact(length)
      bytes = read(length)
      raise Invalid, "short read" unless bytes.bytesize == length

      bytes
    end

    def ascii(bytes)
      raise Invalid, "UnicodeDecodeError" unless bytes.ascii_only?

      bytes.dup.force_encoding(Encoding::UTF_8)
    end

    def utf16(bytes)
      bytes.dup.force_encoding(Encoding::UTF_16BE).encode(Encoding::UTF_8)
    rescue EncodingError
      raise Invalid, "UnicodeDecodeError"
    end

    def date(seconds)
      raise Invalid, "date value out of range" unless seconds.finite? && seconds.round(6) >= EPOCH_MIN && seconds.round(6) < EPOCH_MAX

      NativeTestMetadataPlist::Date.new(seconds)
    end

    def array(ref, count, depth)
      refs = read_ints(count, @ref_size)
      result = []
      @objects[ref] = result
      refs.each { |child| result << read_object(child, depth + 1) }
      result
    end

    def dictionary(ref, count, depth)
      keys = read_ints(count, @ref_size)
      values = read_ints(count, @ref_size)
      result = {}
      @objects[ref] = result
      keys.zip(values).each do |key_ref, value_ref|
        key = read_object(key_ref, depth + 1)
        raise Invalid, "unhashable key" if key.is_a?(Array) || key.is_a?(Hash)

        result[key] = read_object(value_ref, depth + 1)
      end
      result
    end
  end

  # Mirrors plistlib._BinaryPlistWriter(sort_keys=True) for dict/list/str/int/bool.
  class BinaryWriter
    def initialize
      @objects = []
      @scalars = {}
      @containers = {}.compare_by_identity
    end

    def dump(value)
      flatten(value)
      @ref_size = count_size(@objects.length)
      offsets = []
      output = +"bplist00".b
      @objects.each do |object|
        offsets << output.bytesize
        output << encode(object)
      end
      table = output.bytesize
      offset_size = count_size(table)
      offsets.each { |offset| output << pack(offset, offset_size) }
      output << [0, 0, 0, 0, 0, 0, offset_size, @ref_size].pack("C8")
      output << [@objects.length, ref(value), table].pack("Q>Q>Q>")
    end

    private

    def scalar?(value) = value.is_a?(String) || value.is_a?(Integer) || value == true || value == false

    def scalar_key(value) = [value.class, value]

    def ref(value) = scalar?(value) ? @scalars.fetch(scalar_key(value)) : @containers.fetch(value)

    def flatten(value)
      if scalar?(value)
        return if @scalars.key?(scalar_key(value))

        @scalars[scalar_key(value)] = @objects.length
      else
        return if @containers.key?(value)

        @containers[value] = @objects.length
      end
      @objects << value
      case value
      when Hash
        items = value.sort_by { |key, _| key }
        raise TypeError, "keys must be strings" unless items.all? { |key, _| key.is_a?(String) }

        (items.map(&:first) + items.map(&:last)).each { |child| flatten(child) }
      when Array then value.each { |child| flatten(child) }
      end
    end

    def count_size(count)
      return 1 if count < (1 << 8)
      return 2 if count < (1 << 16)
      return 4 if count < (1 << 32)

      8
    end

    def pack(value, size) = [value].pack(FORMATS.fetch(size))

    def size_marker(token, size)
      return [token | size].pack("C") if size < 15
      return [token | 0xF, 0x10, size].pack("CCC") if size < (1 << 8)
      return [token | 0xF, 0x11, size].pack("CCn") if size < (1 << 16)
      return [token | 0xF, 0x12, size].pack("CCN") if size < (1 << 32)

      [token | 0xF, 0x13, size].pack("CCQ>")
    end

    def encode(value)
      case value
      when false then "\x08".b
      when true then "\x09".b
      when Integer then integer(value)
      when String then string(value)
      when Array then size_marker(0xA0, value.length) + value.map { |child| pack(ref(child), @ref_size) }.join
      when Hash
        items = value.sort_by { |key, _| key }
        size_marker(0xD0, items.length) + items.map { |key, _| pack(ref(key), @ref_size) }.join +
          items.map { |_, child| pack(ref(child), @ref_size) }.join
      else raise TypeError, "unsupported type: #{value.class}"
      end
    end

    def integer(value)
      return [0x13, value].pack("Cq>") if value.negative? && value >= -(1 << 63)
      return [0x10, value].pack("CC") if value.between?(0, (1 << 8) - 1)
      return [0x11, value].pack("Cn") if value.between?(0, (1 << 16) - 1)
      return [0x12, value].pack("CN") if value.between?(0, (1 << 32) - 1)
      return [0x13, value].pack("CQ>") if value.between?(0, (1 << 63) - 1)
      return "\x14".b + [value.to_s(16).rjust(32, "0")].pack("H*") if value.between?(0, (1 << 64) - 1)

      raise RangeError, "OverflowError: #{value}"
    end

    def string(value)
      return size_marker(0x50, value.length) + value.b if value.ascii_only?

      encoded = value.encode(Encoding::UTF_16BE).b
      size_marker(0x60, encoded.bytesize / 2) + encoded
    end
  end

  def self.dump_binary(value) = BinaryWriter.new.dump(value)
end
