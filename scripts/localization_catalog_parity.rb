# frozen_string_literal: true

# Host check for the Apple localization catalogs (en, es, pt-BR).
#
# Every locale must ship the same tables, every `.strings` table the same keys,
# and each key the same format-placeholder signature, so `String(format:)`
# never drops or misreads an argument and no locale renders a raw key. The
# XCTest counterparts (LocalizationParityTests, LocalizationCoverageTests) run
# only in the Apple build; this check runs on any host. Plural `.stringsdict`
# tables are not parsed yet: adding one fails until this check covers it.
#
# Usage: ruby scripts/localization_catalog_parity.rb [RESOURCES_DIRECTORY]
module LocalizationCatalogParity
  REQUIRED_LOCALES = %w[en es pt-BR].freeze
  DEFAULT_RESOURCES = File.expand_path("../ios/EpubToMp3/EpubToMp3/Resources", __dir__)
  STRING = /"((?:[^"\\]|\\.)*)"/
  ENTRY = /\A\s*#{STRING}\s*=\s*#{STRING}\s*;/
  # printf-style conversions accepted by String(format:), including positional
  # arguments (`%1$@`), `*` widths and length modifiers (`%ld`); `%%` is a
  # literal percent. The space flag is not accepted, so prose such as
  # "50% de desconto" is not mistaken for a conversion.
  FORMAT = /%(?:(\d+)\$)?[-+0#']*(\d+|\*)?(?:\.(\d+|\*))?(hh|h|ll|l|q|L|z|t|j)?([@dDiuUxXoOfFeEgGcCsSpaA%])/
  # App Shortcut phrases interpolate `${applicationName}`-style parameters.
  PARAMETER = /\$\{[A-Za-z_][A-Za-z0-9_]*\}/

  module_function

  # Decodes a table as Foundation does: UTF-16 with a byte-order mark, or UTF-8
  # with or without one.
  def read(path)
    bytes = File.binread(path)
    text = if bytes.start_with?("\xFF\xFE".b) then bytes.byteslice(2..).force_encoding("UTF-16LE")
           elsif bytes.start_with?("\xFE\xFF".b) then bytes.byteslice(2..).force_encoding("UTF-16BE")
           else bytes.delete_prefix("\xEF\xBB\xBF".b).force_encoding("UTF-8")
           end
    text = text.encode("UTF-8")
    text.valid_encoding? ? text : nil
  rescue EncodingError
    nil
  end

  # Parses one `.strings` table line by line. Outside block comments, a line
  # holds entries, comments or nothing, so a malformed line cannot hide a key.
  def parse(path)
    text = read(path)
    return [[], ["#{path}: not valid UTF-8 or UTF-16 text"]] unless text

    entries = []
    problems = []
    in_comment = false
    text.each_line.with_index(1) do |line, number|
      rest = line.chomp
      loop do
        if in_comment
          close = rest.index("*/") or break
          rest = rest[(close + 2)..]
          in_comment = false
        end
        rest = rest.lstrip
        break if rest.empty? || rest.start_with?("//")

        if rest.start_with?("/*")
          rest = rest[2..]
          in_comment = true
        elsif (match = ENTRY.match(rest))
          entries << [match[1], match[2], number]
          rest = match.post_match
        else
          problems << "#{path}:#{number}: unrecognized line"
          break
        end
      end
    end
    problems << "#{path}: unterminated block comment" if in_comment
    [entries, problems]
  end

  # Sorted placeholder tokens: argument position, `*` arguments, length modifier
  # and conversion, plus named `${…}` parameters. Mixing positional and implicit
  # arguments is reported separately because Foundation does not define it.
  def signature(value)
    implicit = 0
    formats = value.scan(FORMAT).flat_map do |position, width, precision, length, conversion|
      next [] if conversion == "%"

      stars = [width, precision].count("*")
      implicit += stars + 1 unless position
      ["#{position || implicit}$#{'*' * stars}#{length}#{conversion}"]
    end
    (formats + value.scan(PARAMETER)).sort
  end

  def mixes_argument_styles?(value)
    styles = value.scan(FORMAT).reject { _5 == "%" }.map { |position, *| position ? :positional : :implicit }
    styles.uniq.size > 1
  end

  def check(resources = DEFAULT_RESOURCES)
    problems = []
    present = Dir.glob(File.join(resources, "*.lproj")).select { File.directory?(_1) }.map { File.basename(_1, ".lproj") }
    (REQUIRED_LOCALES - present).each { problems << "#{File.join(resources, "#{_1}.lproj")}: missing locale directory" }
    locales = (REQUIRED_LOCALES & present) + (present - REQUIRED_LOCALES).sort
    tables = locales.to_h do |locale|
      [locale, Dir.children(File.join(resources, "#{locale}.lproj")).grep(/\.(?:strings|stringsdict)\z/).sort]
    end
    all_tables = tables.values.flatten.uniq.sort
    locales.each { |locale| (all_tables - tables[locale]).each { problems << "#{locale}.lproj: missing table #{_1}" } }
    all_tables.grep(/\.stringsdict\z/).each { problems << "#{_1}: .stringsdict tables are not checked yet; extend this check" }
    all_tables.grep(/\.strings\z/).each { |table| problems.concat(check_table(resources, locales, table)) }
    problems
  end

  def check_table(resources, locales, table)
    problems = []
    parsed = locales.filter_map do |locale|
      path = File.join(resources, "#{locale}.lproj", table)
      next unless File.file?(path)

      entries, parse_problems = parse(path)
      problems.concat(parse_problems)
      entries.group_by(&:first).each do |key, rows|
        problems << "#{path}: duplicate key #{key.inspect} at lines #{rows.map(&:last).join(', ')}" if rows.size > 1
      end
      entries.each do |key, value, line|
        problems << "#{path}:#{line}: empty value for #{key.inspect}" if value.strip.empty?
        problems << "#{path}:#{line}: #{key.inspect} mixes positional and implicit arguments" if mixes_argument_styles?(value)
      end
      [locale, entries.to_h { |key, value, _| [key, value] }]
    end.to_h
    keys = parsed.values.flat_map(&:keys).uniq.sort
    parsed.each { |locale, values| (keys - values.keys).each { problems << "#{locale}.lproj/#{table}: missing key #{_1.inspect}" } }
    keys.each do |key|
      signatures = parsed.filter_map { |locale, values| [locale, signature(values[key])] if values.key?(key) }.to_h
      next if signatures.values.uniq.size <= 1

      detail = signatures.map { |locale, tokens| "#{locale}=#{tokens.inspect}" }.join(" ")
      problems << "#{table}: placeholder mismatch for #{key.inspect}: #{detail}"
    end
    problems
  end
end

if $PROGRAM_NAME == __FILE__
  problems = LocalizationCatalogParity.check(ARGV.fetch(0, LocalizationCatalogParity::DEFAULT_RESOURCES))
  problems.each { warn _1 }
  puts "localization catalogs in parity" if problems.empty?
  exit(problems.empty? ? 0 : 1)
end
