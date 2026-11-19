# frozen_string_literal: true

# Byte-compatible json.dumps(value, indent=..., sort_keys=...) for host scripts
# ported from Python: ensure_ascii escaping, ", "/": " separators and float repr.
module PythonJson
  ESCAPES = { '"' => '\\"', "\\" => "\\\\", "\n" => "\\n", "\r" => "\\r", "\t" => "\\t", "\b" => "\\b",
              "\f" => "\\f" }.freeze

  module_function

  def dump(value, indent: nil, sort_keys: false, level: 0)
    case value
    when Hash then container(value.to_a.then { |pairs| sort_keys ? pairs.sort_by { |key, _| key.to_s } : pairs },
                             "{", "}", indent, level) { |(key, item)| "#{string(key.to_s)}: #{dump(item, indent:, sort_keys:, level: level + 1)}" }
    when Array then container(value, "[", "]", indent, level) { |item| dump(item, indent:, sort_keys:, level: level + 1) }
    when String then string(value)
    when Float then float(value)
    when Integer then value.to_s
    when true, false then value.to_s
    when nil then "null"
    else raise TypeError, "Object of type #{value.class} is not JSON serializable"
    end
  end

  def container(items, open, close, indent, level)
    return "#{open}#{close}" if items.empty?
    return "#{open}#{items.map { |item| yield item }.join(', ')}#{close}" if indent.nil?

    inner = "\n#{' ' * (indent * (level + 1))}"
    "#{open}#{inner}#{items.map { |item| yield item }.join(",#{inner}")}\n#{' ' * (indent * level)}#{close}"
  end

  def string(text)
    body = text.each_char.map do |char|
      next ESCAPES[char] if ESCAPES.key?(char)

      code = char.ord
      next char if code >= 0x20 && code < 0x7f

      next format("\\u%04x", code) if code < 0x10000

      format("\\u%04x\\u%04x", 0xd800 | ((code - 0x10000) >> 10), 0xdc00 | ((code - 0x10000) & 0x3ff))
    end
    "\"#{body.join}\""
  end

  def float(value)
    return "NaN" if value.nan?
    return value.positive? ? "Infinity" : "-Infinity" if value.infinite?

    value.to_s.sub(".0e", "e")
  end
end
