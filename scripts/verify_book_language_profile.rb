#!/usr/bin/env ruby
# frozen_string_literal: true

# Real-narration check of the whole-book language profile (card BOOK-LANGUAGE-PROFILE):
#   * a pt-BR book with a paragraph quoted in French (the "Jardim das Aflições" failure) must
#     convert completely with the Portuguese voice instead of stopping with
#     `tts_language_mismatch_v1` and asking for a French model;
#   * a book that is half Portuguese and half English (no English model installed) must also
#     convert completely, reading the English part with the main voice.
# Usage: ruby scripts/verify_book_language_profile.rb CONVERTER_CLI
# Needs zip, ffprobe and the pt_BR-faber-medium model installed in the CLI profile in use.
require 'fileutils'
require 'json'
require 'open3'
require 'tmpdir'

cli = ARGV.fetch(0)
XML = '<?xml version="1.0" encoding="UTF-8"?>'
PT = 'A tarde caiu devagar sobre a casa do jardim e ninguém ousou romper o silêncio que se instalara entre as velhas paredes. '
EN = 'The afternoon fell slowly over the house in the garden and nobody dared to break the silence that had settled between the old walls. '
FR = 'Il faut cultiver notre jardin, disait le vieux philosophe, car le monde est trop vaste pour que nous puissions le changer tout entier. Voilà ce que je pense de la vie et de tous ses malheurs. '

def write_epub(path, title, paragraphs)
  Dir.mktmpdir('epub') do |dir|
    File.write(File.join(dir, 'mimetype'), 'application/epub+zip')
    FileUtils.mkdir_p(File.join(dir, 'META-INF'))
    FileUtils.mkdir_p(File.join(dir, 'OEBPS'))
    File.write(File.join(dir, 'META-INF/container.xml'), '<?xml version="1.0"?><container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles></container>')
    File.write(File.join(dir, 'OEBPS/content.opf'), "#{XML}<package xmlns=\"http://www.idpf.org/2007/opf\" version=\"3.0\" unique-identifier=\"id\"><metadata xmlns:dc=\"http://purl.org/dc/elements/1.1/\"><dc:identifier id=\"id\">urn:uuid:#{title}</dc:identifier><dc:title>#{title}</dc:title><dc:creator>T</dc:creator><dc:language>pt-BR</dc:language><meta property=\"dcterms:modified\">2026-11-23T00:00:00Z</meta></metadata><manifest><item id=\"nav\" href=\"nav.xhtml\" media-type=\"application/xhtml+xml\" properties=\"nav\"/><item id=\"c1\" href=\"c1.xhtml\" media-type=\"application/xhtml+xml\"/></manifest><spine><itemref idref=\"c1\"/></spine></package>")
    File.write(File.join(dir, 'OEBPS/nav.xhtml'), "#{XML}<html xmlns=\"http://www.w3.org/1999/xhtml\" xmlns:epub=\"http://www.idpf.org/2007/ops\"><head><title>S</title></head><body><nav epub:type=\"toc\"><ol><li><a href=\"c1.xhtml\">Capítulo 1</a></li></ol></nav></body></html>")
    body = paragraphs.map { |text| "<p>#{text}</p>" }.join
    File.write(File.join(dir, 'OEBPS/c1.xhtml'), "#{XML}<html xmlns=\"http://www.w3.org/1999/xhtml\" xml:lang=\"pt-BR\"><head><title>C</title></head><body><h1>Capítulo 1</h1>#{body}</body></html>")
    Dir.chdir(dir) do
      system('zip', '-q', '-X0', path, 'mimetype') or abort 'zip failed'
      system('zip', '-q', '-Xr9', path, 'META-INF', 'OEBPS') or abort 'zip failed'
    end
  end
end

# Returns [success, last error line, seconds of audio]
def convert(cli, epub, out)
  output, status = Open3.capture2e(cli, 'convert', epub, '--engine', 'piper', '--model',
                                   'pt_BR-faber-medium', '--output-dir', out, '--yes')
  mp3 = Dir.glob(File.join(out, '**', '0001-*.mp3')).first
  return [false, output.lines.grep(/error|mismatch/i).last.to_s.strip, 0.0] unless status.success? && mp3

  seconds, = Open3.capture2('ffprobe', '-v', 'error', '-show_entries', 'format=duration', '-of', 'csv=p=0', mp3)
  [true, '', seconds.to_f]
end

failures = []
Dir.mktmpdir('profile') do |dir|
  quoted = File.join(dir, 'Citacao.epub')
  paragraphs = Array.new(40) { |i| "#{PT}Parágrafo #{i} do livro, escrito em português do Brasil." }
  paragraphs.insert(20, FR)
  write_epub(quoted, 'Citacao', paragraphs)
  ok, error, seconds = convert(cli, quoted, File.join(dir, 'quoted'))
  puts JSON.pretty_generate(book: 'pt-BR with a French quotation', converted: ok, seconds: seconds.round(1), error: error)
  failures << "pt-BR book with a French quotation did not convert: #{error}" unless ok

  parallel = File.join(dir, 'Bilingue.epub')
  mixed = (0...20).flat_map { |i| ["#{PT * 3}Seção #{i}.", "#{EN * 2}Section #{i}."] }
  write_epub(parallel, 'Bilingue', mixed)
  ok, error, seconds = convert(cli, parallel, File.join(dir, 'parallel'))
  puts JSON.pretty_generate(book: 'bilingual pt/en without an English model', converted: ok, seconds: seconds.round(1), error: error)
  failures << "bilingual book did not convert: #{error}" unless ok
end
if failures.empty?
  puts 'book language profile: PASS'
else
  warn failures.map { |f| "FAIL: #{f}" }
  exit 1
end
