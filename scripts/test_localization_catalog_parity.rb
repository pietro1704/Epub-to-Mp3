# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "open3"
require "rbconfig"
require_relative "localization_catalog_parity"

# The real Apple catalogs stay in parity, and the checker rejects each kind of
# divergence on scratch fixtures (a key missing in one locale, a changed
# placeholder signature, a duplicate key, a malformed line, a missing table).
class LocalizationCatalogParityTest < Minitest::Test
  SCRIPT = File.expand_path("localization_catalog_parity.rb", __dir__)

  def write_catalogs(root, tables)
    tables.each do |locale, files|
      directory = File.join(root, "#{locale}.lproj")
      FileUtils.mkdir_p(directory)
      files.each { |name, body| File.write(File.join(directory, name), body) }
    end
    root
  end

  def matching_catalogs(root, en: nil, es: nil, pt: nil)
    base = %(/* Header */\n"greeting" = "Hello %@";\n"count" = "%1$d of %2$d";\n\n"percent" = "%d%% done";\n)
    shortcut = %("Open in ${applicationName}" = "Open in ${applicationName}";\n)
    write_catalogs(root, {
      "en" => { "Localizable.strings" => en || base, "AppShortcuts.strings" => shortcut },
      "es" => { "Localizable.strings" => es || base, "AppShortcuts.strings" => shortcut },
      "pt-BR" => { "Localizable.strings" => pt || base, "AppShortcuts.strings" => shortcut }
    })
  end

  def test_repository_catalogs_are_in_parity
    assert_equal [], LocalizationCatalogParity.check
  end

  def test_repository_catalogs_include_both_apple_tables
    %w[en es pt-BR].each do |locale|
      %w[Localizable.strings AppShortcuts.strings].each do |table|
        assert File.file?(File.join(LocalizationCatalogParity::DEFAULT_RESOURCES, "#{locale}.lproj", table)), "#{locale} #{table}"
      end
    end
  end

  def test_matching_fixture_passes
    Dir.mktmpdir { |root| assert_equal [], LocalizationCatalogParity.check(matching_catalogs(root)) }
  end

  def test_key_missing_from_one_locale_fails
    Dir.mktmpdir do |root|
      es = %("greeting" = "Hola %@";\n"count" = "%1$d de %2$d";\n)
      problems = LocalizationCatalogParity.check(matching_catalogs(root, es: es))
      assert_equal ['es.lproj/Localizable.strings: missing key "percent"'], problems
    end
  end

  def test_key_only_in_a_translation_fails
    Dir.mktmpdir do |root|
      pt = %("greeting" = "Olá %@";\n"count" = "%1$d de %2$d";\n"percent" = "%d%% feito";\n"extra" = "Extra";\n)
      problems = LocalizationCatalogParity.check(matching_catalogs(root, pt: pt))
      assert_includes problems, 'en.lproj/Localizable.strings: missing key "extra"'
      assert_includes problems, 'es.lproj/Localizable.strings: missing key "extra"'
    end
  end

  def test_placeholder_count_type_and_position_mismatches_fail
    Dir.mktmpdir do |root|
      es = %("greeting" = "Hola";\n"count" = "%1$@ de %2$d";\n"percent" = "%ld%% hecho";\n)
      problems = LocalizationCatalogParity.check(matching_catalogs(root, es: es))
      assert_equal 3, problems.size, problems.join("\n")
      assert(problems.all? { _1.include?("placeholder mismatch") })
      %w[greeting count percent].each { |key| assert(problems.any? { _1.include?(key.inspect) }, key) }
    end
  end

  def test_reordered_positional_arguments_pass
    Dir.mktmpdir do |root|
      pt = %("greeting" = "Olá %@";\n"count" = "%2$d de %1$d";\n"percent" = "%d%% feito";\n)
      assert_equal [], LocalizationCatalogParity.check(matching_catalogs(root, pt: pt))
    end
  end

  def test_shortcut_parameter_mismatch_fails
    Dir.mktmpdir do |root|
      matching_catalogs(root)
      File.write(File.join(root, "es.lproj/AppShortcuts.strings"), %("Open in ${applicationName}" = "Abrir";\n))
      problems = LocalizationCatalogParity.check(root)
      assert_equal 1, problems.size, problems.join("\n")
      assert_includes problems.first, "AppShortcuts.strings: placeholder mismatch"
    end
  end

  def test_duplicate_key_empty_value_and_malformed_line_fail
    Dir.mktmpdir do |root|
      en = %("greeting" = "Hello %@";\n"count" = "%1$d of %2$d";\n"percent" = "%d%% done";\n) +
           %("percent" = "%d%% complete";\n"blank" = " ";\n"broken" = "missing semicolon"\n)
      es = %("greeting" = "Hola %@";\n"count" = "%1$d de %2$d";\n"percent" = "%d%% hecho";\n"blank" = "x";\n)
      pt = %("greeting" = "Olá %@";\n"count" = "%1$d de %2$d";\n"percent" = "%d%% feito";\n"blank" = "x";\n)
      problems = LocalizationCatalogParity.check(matching_catalogs(root, en: en, es: es, pt: pt))
      assert(problems.any? { _1.include?('duplicate key "percent" at lines 3, 4') }, problems.join("\n"))
      assert(problems.any? { _1.end_with?('empty value for "blank"') }, problems.join("\n"))
      assert(problems.any? { _1.end_with?("en.lproj/Localizable.strings:6: unrecognized line") }, problems.join("\n"))
    end
  end

  def test_missing_table_fails
    Dir.mktmpdir do |root|
      matching_catalogs(root)
      File.delete(File.join(root, "pt-BR.lproj/AppShortcuts.strings"))
      assert_equal ["pt-BR.lproj: missing table AppShortcuts.strings"], LocalizationCatalogParity.check(root)
    end
  end

  def test_percent_sign_in_prose_is_not_a_placeholder
    assert_equal [], LocalizationCatalogParity.signature("50% off")
    assert_equal [], LocalizationCatalogParity.signature("100% sincronizado, 50% de desconto")
    assert_equal ["1$d"], LocalizationCatalogParity.signature("%d%% done")
  end

  def test_star_width_counts_as_an_argument
    refute_equal LocalizationCatalogParity.signature("%*d items"), LocalizationCatalogParity.signature("%d artículos")
  end

  def test_mixed_positional_and_implicit_arguments_fail
    Dir.mktmpdir do |root|
      pt = %("greeting" = "Olá %@";\n"count" = "%1$d de %d";\n"percent" = "%d%% feito";\n)
      problems = LocalizationCatalogParity.check(matching_catalogs(root, pt: pt))
      assert(problems.any? { _1.end_with?('"count" mixes positional and implicit arguments') }, problems.join("\n"))
    end
  end

  def test_byte_order_marks_and_utf16_tables_parse
    Dir.mktmpdir do |root|
      matching_catalogs(root)
      es = %("greeting" = "Hola %@";\n"count" = "%1$d de %2$d";\n"percent" = "%d%% hecho";\n)
      File.binwrite(File.join(root, "es.lproj/Localizable.strings"), "\xFF\xFE".b + es.encode("UTF-16LE").b)
      pt = %("greeting" = "Olá %@";\n"count" = "%1$d de %2$d";\n"percent" = "%d%% feito";\n)
      File.binwrite(File.join(root, "pt-BR.lproj/Localizable.strings"), "\xEF\xBB\xBF".b + pt.b)
      assert_equal [], LocalizationCatalogParity.check(root)
    end
  end

  def test_undecodable_table_is_reported_not_raised
    Dir.mktmpdir do |root|
      matching_catalogs(root)
      File.binwrite(File.join(root, "es.lproj/Localizable.strings"), "\"greeting\" = \"\xFF\";\n".b)
      problems = LocalizationCatalogParity.check(root)
      assert(problems.any? { _1.end_with?("es.lproj/Localizable.strings: not valid UTF-8 or UTF-16 text") }, problems.join("\n"))
    end
  end

  def test_block_and_trailing_comments_parse
    Dir.mktmpdir do |root|
      en = %(/* Context\n   spanning lines */\n"greeting" = "Hello %@"; // trailing\n) +
           %("count" = "%1$d of %2$d"; /* inline */ "percent" = "%d%% done";\n)
      assert_equal [], LocalizationCatalogParity.check(matching_catalogs(root, en: en))
    end
  end

  def test_unterminated_block_comment_fails
    Dir.mktmpdir do |root|
      en = %("greeting" = "Hello %@";\n"count" = "%1$d of %2$d";\n"percent" = "%d%% done";\n/* open\n)
      problems = LocalizationCatalogParity.check(matching_catalogs(root, en: en))
      assert(problems.any? { _1.end_with?("unterminated block comment") }, problems.join("\n"))
    end
  end

  def test_plural_tables_are_not_silently_accepted
    Dir.mktmpdir do |root|
      matching_catalogs(root)
      %w[en es pt-BR].each { File.write(File.join(root, "#{_1}.lproj/Localizable.stringsdict"), "<plist/>") }
      assert_equal ["Localizable.stringsdict: .stringsdict tables are not checked yet; extend this check"],
                   LocalizationCatalogParity.check(root)
    end
  end

  def test_additional_locale_is_checked
    Dir.mktmpdir do |root|
      matching_catalogs(root)
      write_catalogs(root, "fr" => { "Localizable.strings" => %("greeting" = "Bonjour %@";\n) })
      problems = LocalizationCatalogParity.check(root)
      assert_includes problems, "fr.lproj: missing table AppShortcuts.strings"
      assert_includes problems, 'fr.lproj/Localizable.strings: missing key "count"'
    end
  end

  def test_missing_locale_is_reported_once
    Dir.mktmpdir do |root|
      matching_catalogs(root)
      FileUtils.rm_rf(File.join(root, "es.lproj"))
      assert_equal ["#{File.join(root, 'es.lproj')}: missing locale directory"], LocalizationCatalogParity.check(root)
    end
  end

  def test_command_line_reports_status
    Dir.mktmpdir do |root|
      matching_catalogs(root)
      output, status = Open3.capture2e(RbConfig.ruby, SCRIPT, root)
      assert status.success?, output
      File.write(File.join(root, "es.lproj/Localizable.strings"), %("greeting" = "Hola %@";\n))
      output, status = Open3.capture2e(RbConfig.ruby, SCRIPT, root)
      assert_equal 1, status.exitstatus
      assert_includes output, 'es.lproj/Localizable.strings: missing key "count"'
    end
  end
end
