# frozen_string_literal: true

# Host check for the Apple localization catalogs (en, es, pt-BR).
#
# Every locale must ship the same tables, every table the same keys, and each
# key the same format-placeholder signature, so `String(format:)` never drops
# or misreads an argument and no locale renders a raw key. The XCTest
# counterparts (LocalizationParityTests, LocalizationCoverageTests) run only in
# the Apple build; this check runs on any host.
#
# Usage: ruby scripts/localization_catalog_parity.rb [RESOURCES_DIRECTORY]
module LocalizationCatalogParity
  LOCALES = %w[en es pt-BR].freeze
  DEFAULT_RESOURCES = File.expand_path("../ios/EpubToMp3/EpubToMp3/Resources", __dir__)
  ENTRY = /\A\s*"((?:[^"\\]|\\.)*)"\s*=\s*"((?:[^"\\]|\\.)*)"\s*;\s*\z/
  COMMENT = %r{\A\s*(?:/\*.*\*/|//.*)\s*\z}
  # printf-style conversions accepted by String(format:), including positional
  # arguments (`%1$@`) and length modifiers (`%ld`); `%%` is a literal percent.
  FORMAT = /%(?:(\d+)\$)?[-+ 0#']*(?:\d+|\*)?(?:\.(?:\d+|\*))?(hh|h|ll|l|q|L|z|t|j)?([@dDiuUxXoOfFeEgGcCsSpaA%])/
  # App Shortcut phrases interpolate `${applicationName}`-style parameters.
  PARAMETER = /\$\{[A-Za-z_][A-Za-z0-9_]*\}/

  module_function

  # Parses one `.strings` table. Every line must be an entry, a one-line
  # `/* */` or `//` comment or blank, so a malformed line cannot hide a key.
  def parse(path)
    entries = []
    problems = []
    File.readlines(path, encoding: "UTF-8").each_with_index do |line, index|
      text = line.chomp
      if (match = ENTRY.match(text))
        entries << [match[1], match[2], index + 1]
      elsif !(text.strip.empty? || COMMENT.match?(text))
        problems << "#{path}:#{index + 1}: unrecognized line"
      end
    end
    [entries, problems]
  end

  # Sorted placeholder tokens: argument position, length modifier and
  # conversion, plus named `${…}` parameters.
  def signature(value)
    implicit = 0
    formats = value.scan(FORMAT).filter_map do |position, length, conversion|
      next if conversion == "%"

      implicit += 1 unless position
      "#{position || implicit}$#{length}#{conversion}"
    end
    (formats + value.scan(PARAMETER)).sort
  end

  def check(resources = DEFAULT_RESOURCES)
    problems = []
    tables = LOCALES.to_h do |locale|
      directory = File.join(resources, "#{locale}.lproj")
      problems << "#{directory}: missing locale directory" unless File.directory?(directory)
      names = File.directory?(directory) ? Dir.children(directory).grep(/\.(?:strings|stringsdict)\z/) : []
      [locale, names.sort]
    end
    all_tables = tables.values.flatten.uniq.sort
    LOCALES.each do |locale|
      (all_tables - tables[locale]).each { problems << "#{locale}.lproj: missing table #{_1}" }
    end
    all_tables.select { _1.end_with?(".strings") }.each do |table|
      parsed = LOCALES.filter_map do |locale|
        path = File.join(resources, "#{locale}.lproj", table)
        next unless File.file?(path)

        entries, parse_problems = parse(path)
        problems.concat(parse_problems)
        entries.group_by(&:first).each do |key, rows|
          problems << "#{path}: duplicate key #{key.inspect} at lines #{rows.map(&:last).join(', ')}" if rows.size > 1
        end
        entries.each { |key, value, line| problems << "#{path}:#{line}: empty value for #{key.inspect}" if value.strip.empty? }
        [locale, entries.to_h { |key, value, _| [key, value] }]
      end.to_h
      keys = parsed.values.flat_map(&:keys).uniq.sort
      parsed.each do |locale, values|
        (keys - values.keys).each { problems << "#{locale}.lproj/#{table}: missing key #{_1.inspect}" }
      end
      keys.each do |key|
        signatures = parsed.filter_map { |locale, values| [locale, signature(values[key])] if values.key?(key) }.to_h
        next if signatures.values.uniq.size <= 1

        detail = signatures.map { |locale, tokens| "#{locale}=#{tokens.inspect}" }.join(" ")
        problems << "#{table}: placeholder mismatch for #{key.inspect}: #{detail}"
      end
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
