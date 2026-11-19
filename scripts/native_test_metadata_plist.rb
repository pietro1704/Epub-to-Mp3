# frozen_string_literal: true

require "strscan"

# Property-list codec mirroring CPython 3.14 plistlib semantics used by
# capture_native_test_metadata.rb: XML/binary loads (dict_type=dict) and
# binary dumps with sort_keys=True. No DTD, entity or external resolution.
module NativeTestMetadataPlist
  class Invalid < StandardError; end
  # Python-side failures that escape every handler (IndexError/AttributeError).
  class Crash < StandardError; end
  # Python RecursionError while reading deeply nested binary objects.
  class Recursion < StandardError; end

  Data = Struct.new(:bytes)
  Date = Struct.new(:value)
  Uid = Struct.new(:value)

  MAX_SIGNED = (1 << 63) - 1
  RECURSION_DEPTH = 996
  WHITESPACE = "\t\n\v\f\r \u001c\u001d\u001e\u001f\u0085\u00a0\u1680\u2000-\u200a\u2028\u2029\u202f\u205f\u3000"
  NAME_START = "A-Z_a-z:\u00C0-\u00D6\u00D8-\u00F6\u00F8-\u02FF\u0370-\u037D\u037F-\u1FFF\u200C\u200D" \
               "\u2070-\u218F\u2C00-\u2FEF\u3001-\uD7FF\uF900-\uFDCF\uFDF0-\uFFFD\u{10000}-\u{EFFFF}"
  NAME = /[#{NAME_START}][#{NAME_START}\-.0-9\u00B7\u0300-\u036F\u203F-\u2040]*/
  INVALID_CHAR = /[^\t\n\r\u0020-\uD7FF\uE000-\uFFFD\u{10000}-\u{10FFFF}]/
  XML_DECL = /\A<\?xml[ \t\r\n]+version[ \t\r\n]*=[ \t\r\n]*(["'])1\.[0-9]+\1(?:[ \t\r\n]+encoding[ \t\r\n]*=[ \t\r\n]*(["'])([A-Za-z][A-Za-z0-9._-]*)\2)?(?:[ \t\r\n]+standalone[ \t\r\n]*=[ \t\r\n]*(["'])(?:yes|no)\4)?[ \t\r\n]*\?>/
  DATE = /\A(\d\d\d\d)(?:-(\d\d)(?:-(\d\d)(?:T(\d\d)(?::(\d\d)(?::(\d\d))?)?)?)?)?Z/
  ENTITIES = { "amp" => "&", "lt" => "<", "gt" => ">", "apos" => "'", "quot" => '"' }.freeze
  B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

  module_function

  def load(data)
    data = data.b
    header = data.byteslice(0, 32)
    return XmlReader.new(xml_text(data)).parse if ["<?xml", "<plist", "\xEF\xBB\xBF<?xml".b, "\xEF\xBB\xBF<plist".b].any? { |prefix| header.start_with?(prefix.b) }
    return BinaryReader.new(data).parse if header.byteslice(0, 8) == "bplist00"

    raise Invalid, "Invalid file"
  end

  def xml_text(data)
    bom = data.start_with?("\xEF\xBB\xBF".b)
    body = bom ? data.byteslice(3..) : data
    encoding = body.match(XML_DECL)&.[](3)&.upcase
    raise Invalid, "unsupported encoding" if bom && encoding && encoding != "UTF-8"

    text = case encoding
           when nil, "UTF-8" then body.dup.force_encoding(Encoding::UTF_8)
           when "US-ASCII" then body.dup.force_encoding(Encoding::US_ASCII).encode(Encoding::UTF_8)
           when "ISO-8859-1" then body.dup.force_encoding(Encoding::ISO_8859_1).encode(Encoding::UTF_8)
           else raise Invalid, "unknown encoding"
           end
    raise Invalid, "not well-formed (invalid token)" unless text.valid_encoding? && !text.match?(INVALID_CHAR)

    text.gsub(/\r\n?/, "\n")
  rescue EncodingError
    raise Invalid, "not well-formed (invalid token)"
  end

  # Mirrors plistlib._PlistParser handlers.
  class Handler
    attr_reader :root

    def initialize
      @stack = []
      @current_key = nil
      @root = nil
      @data = []
    end

    def data(text) = @data << text

    def start(name)
      @data = []
      return unless %w[dict array].include?(name)

      value = name == "dict" ? {} : []
      add_object(value)
      @stack << value
    end

    def finish(name)
      case name
      when "dict"
        raise Invalid, "missing value for key" if @current_key && !@current_key.empty?

        @stack.pop
      when "key"
        raise Invalid, "unexpected key" if @current_key && !@current_key.empty?
        raise Crash, "IndexError: list index out of range" if @stack.empty?
        raise Invalid, "unexpected key" unless @stack.last.is_a?(Hash)

        @current_key = text
      when "array" then @stack.pop
      when "true" then add_object(true)
      when "false" then add_object(false)
      when "integer" then add_object(integer(text))
      when "real" then add_object(real(text))
      when "string" then add_object(text)
      when "data" then add_object(Data.new(NativeTestMetadataPlist.base64(text)))
      when "date" then add_object(NativeTestMetadataPlist.date(text))
      end
    end

    private

    def text
      joined = @data.join
      @data = []
      joined
    end

    def add_object(value)
      if !@current_key.nil?
        raise Crash, "IndexError: list index out of range" if @stack.empty?
        raise Invalid, "unexpected element" unless @stack.last.is_a?(Hash)

        @stack.last[@current_key] = value
        @current_key = nil
      elsif @stack.empty?
        @root = value
      else
        raise Invalid, "unexpected element" unless @stack.last.is_a?(Array)

        @stack.last << value
      end
    end

    def integer(raw)
      if raw.start_with?("0x", "0X")
        stripped = raw.sub(/[#{WHITESPACE}]+\z/o, "")
        raise Invalid, "invalid literal" unless stripped.match?(/\A0[xX](?:_?[0-9a-fA-F])+\z/)

        return stripped[2..].delete("_").to_i(16)
      end
      stripped = raw.gsub(/\A[#{WHITESPACE}]+|[#{WHITESPACE}]+\z/o, "")
      raise Invalid, "invalid literal" unless stripped.match?(/\A[+-]?[0-9](?:_?[0-9])*\z/)

      stripped.delete("_").to_i
    end

    def real(raw)
      stripped = raw.gsub(/\A[#{WHITESPACE}]+|[#{WHITESPACE}]+\z/o, "")
      digits = "[0-9](?:_?[0-9])*"
      number = /\A[+-]?(?:(?:#{digits}(?:\.(?:#{digits})?)?|\.#{digits})(?:[eE][+-]?#{digits})?|inf|infinity|nan)\z/i
      raise Invalid, "could not convert string to float" unless stripped.match?(number)

      return Float::NAN if stripped.match?(/nan\z/i)
      return stripped.start_with?("-") ? -Float::INFINITY : Float::INFINITY if stripped.match?(/inf(?:inity)?\z/i)

      Float(stripped.delete("_"))
    end
  end

  # Expat-equivalent well-formedness for the subset plistlib relies on.
  class XmlReader
    def initialize(text)
      @scanner = StringScanner.new(text)
      @handler = Handler.new
    end

    def parse
      @scanner.skip(XML_DECL)
      misc
      raise Invalid, "no element found" unless @scanner.check(/<#{NAME}/o)

      content
      misc
      raise Invalid, "junk after document element" unless @scanner.eos?

      @handler.root
    end

    private

    def misc
      loop do
        next if @scanner.skip(/[ \t\n]+/)
        next if comment || processing_instruction

        break
      end
    end

    def comment
      return false unless @scanner.skip(/<!--/)

      body = @scanner.scan_until(/-->/) or raise Invalid, "unclosed token"
      raise Invalid, "not well-formed (invalid token)" if body[0...-3].include?("--") || body[0...-3].end_with?("-")

      true
    end

    def processing_instruction
      return false unless @scanner.skip(/<\?/)

      target = @scanner.scan(NAME) or raise Invalid, "not well-formed (invalid token)"
      raise Invalid, "XML or text declaration not at start of entity" if target.casecmp?("xml")

      @scanner.skip(/\?>/) || (@scanner.skip(/[ \t\n]/) && @scanner.skip_until(/\?>/)) or raise Invalid, "unclosed token"
      true
    end

    def content
      stack = []
      loop do
        if @scanner.scan(/<(#{NAME})/o)
          start_tag(@scanner[1], stack)
        elsif @scanner.scan(%r{</(#{NAME})[ \t\n]*>}o)
          raise Invalid, "mismatched tag" unless stack.pop == @scanner[1]

          @handler.finish(@scanner[1])
        elsif comment || processing_instruction
          next
        elsif @scanner.skip(/<!\[CDATA\[/)
          body = @scanner.scan_until(/\]\]>/) or raise Invalid, "unclosed CDATA section"
          @handler.data(body[0...-3])
        elsif @scanner.skip(/&/)
          @handler.data(reference)
        elsif (text = @scanner.scan(/[^<&]+/))
          raise Invalid, "not well-formed (invalid token)" if text.include?("]]>")

          @handler.data(text)
        else
          raise Invalid, @scanner.eos? ? "no element found" : "not well-formed (invalid token)"
        end
        break if stack.empty?
      end
    end

    def start_tag(name, stack)
      seen = []
      while @scanner.skip(/[ \t\n]+/)
        break unless (attribute = @scanner.scan(NAME))
        raise Invalid, "duplicate attribute" if seen.include?(attribute)

        seen << attribute
        @scanner.skip(/[ \t\n]*=[ \t\n]*/) or raise Invalid, "not well-formed (invalid token)"
        quote = @scanner.scan(/["']/) or raise Invalid, "not well-formed (invalid token)"
        loop do
          next if @scanner.skip(/[^<&#{quote}]+/)
          next reference if @scanner.skip(/&/)
          break if @scanner.skip(/#{quote}/)

          raise Invalid, "not well-formed (invalid token)"
        end
      end
      closing = @scanner.scan(%r{/?>}) or raise Invalid, "not well-formed (invalid token)"
      @handler.start(name)
      closing == "/>" ? @handler.finish(name) : stack.push(name)
    end

    def reference
      token = @scanner.scan(/(#{NAME}|#[0-9]+|#x[0-9a-fA-F]+);/o) or raise Invalid, "not well-formed (invalid token)"
      body = token.chomp(";")
      return ENTITIES.fetch(body) { raise Invalid, "undefined entity" } unless body.start_with?("#")

      code = body.start_with?("#x") ? body[2..].to_i(16) : body[1..].to_i
      raise Invalid, "reference to invalid character number" if code > 0x10FFFF || (code >= 0xD800 && code <= 0xDFFF)

      character = code.chr(Encoding::UTF_8)
      raise Invalid, "reference to invalid character number" if character.match?(INVALID_CHAR)

      character
    end
  end

  # CPython binascii.a2b_base64 in non-strict mode.
  def base64(text)
    output = +"".b
    quad = 0
    left = 0
    pads = 0
    text.b.each_byte do |byte|
      if byte == 61
        return output if quad >= 2 && quad + (pads += 1) >= 4

        next
      end
      value = B64.index(byte.chr)
      next if value.nil?

      pads = 0
      case quad
      when 0 then left = value
      when 1 then output << (((left << 2) | (value >> 4)) & 0xFF)
                  left = value & 0x0F
      when 2 then output << (((left << 4) | (value >> 2)) & 0xFF)
                  left = value & 0x03
      when 3 then output << (((left << 6) | value) & 0xFF)
      end
      quad = (quad + 1) % 4
    end
    raise Invalid, "Incorrect padding" unless quad.zero?

    output
  end

  def date(text)
    match = text.match(DATE) or raise Crash, "AttributeError: 'NoneType' object has no attribute 'groupdict'"
    fields = match.captures.take_while { |value| !value.nil? }.map(&:to_i)
    raise Invalid, "missing datetime fields" if fields.length < 3

    year, month, day, hour, minute, second = fields
    valid = year.between?(1, 9999) && month.between?(1, 12) && day.between?(1, 31) &&
            day <= NativeTestMetadataPlist.days_in_month(year, month) &&
            (hour || 0) <= 23 && (minute || 0) <= 59 && (second || 0) <= 59
    raise Invalid, "datetime value out of range" unless valid

    Date.new(fields)
  end

  def days_in_month(year, month)
    return 29 if month == 2 && (year % 4).zero? && (!(year % 100).zero? || (year % 400).zero?)

    [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31][month - 1]
  end
end

require_relative "native_test_metadata_plist_binary"
