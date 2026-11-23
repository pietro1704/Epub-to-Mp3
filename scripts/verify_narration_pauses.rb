#!/usr/bin/env ruby
# frozen_string_literal: true

# Measures a real narration with `ffmpeg silencedetect` and checks the approved pause
# policy (paragraph 0.45 s Piper / 0.55 s system voice, chapter end 1.0 s, sentences and
# headings unchanged). Usage:
#   ruby scripts/verify_narration_pauses.rb CONVERTER_CLI [piper|system]
# Fixtures are generated here: book A has 12 one-sentence paragraphs and book B the same
# sentences in ONE paragraph. Needs zip, ffmpeg/ffprobe, and for `piper` the
# pt_BR-faber-medium model installed in the CLI profile in use.
#
# The paragraph pause is the extra length A has over B per paragraph boundary
# ((A - B) / 11, trailing silence left out), because A and B speak the same sentences.
require 'fileutils'
require 'json'
require 'open3'
require 'tmpdir'

cli = ARGV.fetch(0)
engine = ARGV.fetch(1, 'piper')
SENTENCES = [
  'O gato dorme no sofá.', 'A chuva cai sobre o telhado.', 'Marta abriu a janela.',
  'O vento entrou na sala.', 'Os pássaros cantam cedo.', 'O rio corre devagar.',
  'Ele leu o livro inteiro.', 'Depois fechou a porta.', 'A casa fica na colina.',
  'Ninguém tinha pressa.', 'Hoje o céu está limpo.', 'As crianças brincam fora.'
].freeze

# Natural gap each voice leaves between sentences (measured) and the approved totals.
POLICY = {
  'piper' => { natural: 0.14, paragraph_total: 0.45 },
  'system' => { natural: 0.30, paragraph_total: 0.55 }
}.freeze
CHAPTER_END_TOTAL = 1.0
TOLERANCE = 0.08
BOUNDARIES = 11

XML = '<?xml version="1.0" encoding="UTF-8"?>'

# Writes a one-chapter pt-BR EPUB: a heading and [body] as the chapter content.
def write_epub(path, title, body)
  Dir.mktmpdir('epub') do |dir|
    File.write(File.join(dir, 'mimetype'), 'application/epub+zip')
    FileUtils.mkdir_p(File.join(dir, 'META-INF'))
    FileUtils.mkdir_p(File.join(dir, 'OEBPS'))
    File.write(File.join(dir, 'META-INF/container.xml'), '<?xml version="1.0"?><container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles></container>')
    File.write(File.join(dir, 'OEBPS/content.opf'), "#{XML}<package xmlns=\"http://www.idpf.org/2007/opf\" version=\"3.0\" unique-identifier=\"id\"><metadata xmlns:dc=\"http://purl.org/dc/elements/1.1/\"><dc:identifier id=\"id\">urn:uuid:#{title}</dc:identifier><dc:title>#{title}</dc:title><dc:creator>T</dc:creator><dc:language>pt-BR</dc:language><meta property=\"dcterms:modified\">2026-11-23T00:00:00Z</meta></metadata><manifest><item id=\"nav\" href=\"nav.xhtml\" media-type=\"application/xhtml+xml\" properties=\"nav\"/><item id=\"c1\" href=\"c1.xhtml\" media-type=\"application/xhtml+xml\"/></manifest><spine><itemref idref=\"c1\"/></spine></package>")
    File.write(File.join(dir, 'OEBPS/nav.xhtml'), "#{XML}<html xmlns=\"http://www.w3.org/1999/xhtml\" xmlns:epub=\"http://www.idpf.org/2007/ops\"><head><title>S</title></head><body><nav epub:type=\"toc\"><ol><li><a href=\"c1.xhtml\">Capítulo 1</a></li></ol></nav></body></html>")
    File.write(File.join(dir, 'OEBPS/c1.xhtml'), "#{XML}<html xmlns=\"http://www.w3.org/1999/xhtml\" xml:lang=\"pt-BR\"><head><title>C</title></head><body><h1>Capítulo 1</h1>#{body}</body></html>")
    Dir.chdir(dir) do
      system('zip', '-q', '-X0', path, 'mimetype') or abort 'zip failed'
      system('zip', '-q', '-Xr9', path, 'META-INF', 'OEBPS') or abort 'zip failed'
    end
  end
end

def convert(cli, epub, engine, out)
  args = [cli, 'convert', epub, '--engine', engine, '--output-dir', out, '--yes']
  args += ['--model', 'pt_BR-faber-medium'] if engine == 'piper'
  _, status = Open3.capture2e(*args)
  abort "conversion failed: #{epub}" unless status.success?
  Dir.glob(File.join(out, '**', '0001-*.mp3')).first or abort 'no chapter audio produced'
end

# [duration, trailing silence at the end of the file]
def measure(mp3)
  out, = Open3.capture2('ffprobe', '-v', 'error', '-show_entries', 'format=duration',
                        '-of', 'csv=p=0', mp3)
  duration = out.to_f
  _, err, = Open3.capture3('ffmpeg', '-hide_banner', '-i', mp3,
                           '-af', 'silencedetect=noise=-38dB:d=0.06', '-f', 'null', '-')
  starts = err.scan(/silence_start: ([\d.]+)/).flatten.map(&:to_f)
  ends = err.scan(/silence_end: ([\d.]+)/).flatten.map(&:to_f)
  # ffmpeg closes a silence that runs to the end of the file at EOF (or leaves it open).
  ends << duration while ends.length < starts.length
  trailing = starts.empty? || ends.last < duration - 0.05 ? 0.0 : ends.last - starts.last
  [duration, trailing]
end

policy = POLICY.fetch(engine)
failures = []
Dir.mktmpdir('pauses') do |dir|
  book_a = File.join(dir, 'PausasA.epub')
  book_b = File.join(dir, 'PausasB.epub')
  write_epub(book_a, 'PausasA', SENTENCES.map { |s| "<p>#{s}</p>" }.join)
  write_epub(book_b, 'PausasB', "<p>#{SENTENCES.join(' ')}</p>")
  dur_a, end_a = measure(convert(cli, book_a, engine, File.join(dir, 'a')))
  dur_b, end_b = measure(convert(cli, book_b, engine, File.join(dir, 'b')))
  extra = ((dur_a - end_a) - (dur_b - end_b)) / BOUNDARIES
  want_extra = policy[:paragraph_total] - policy[:natural]
  puts JSON.pretty_generate(engine: engine, paragraph_extra_per_boundary: extra.round(3),
                            want_extra: want_extra.round(3), chapter_end_a: end_a.round(3),
                            chapter_end_b: end_b.round(3))
  failures << "paragraph pause adds #{extra.round(3)} s per boundary, want #{want_extra.round(3)} +-#{TOLERANCE}" unless (extra - want_extra).abs <= TOLERANCE
  [[end_a, 'A'], [end_b, 'B']].each do |trailing, name|
    failures << "chapter end of #{name} is #{trailing.round(3)} s, want #{CHAPTER_END_TOTAL} +-#{TOLERANCE}" unless (trailing - CHAPTER_END_TOTAL).abs <= TOLERANCE
  end
end
if failures.empty?
  puts 'narration pauses: PASS'
else
  warn failures.map { |f| "FAIL: #{f}" }
  exit 1
end
