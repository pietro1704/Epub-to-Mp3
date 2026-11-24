#!/usr/bin/env ruby
# frozen_string_literal: true

# Real-narration check of inline footnotes (default preference `inline`). Generates a pt-BR
# EPUB shaped like "Jardim das Aflições" (note references in the text, the note bodies in
# <aside epub:type="footnote"> elements at the end of the chapter), converts it with the CLI and
# measures the published MP3 with ffmpeg silencedetect:
#   * a 0.5 s pause before and after each of the two notes, plus the two paragraph pauses
#     (0.45 s): six pauses of about half a second between the heading pause and the chapter end;
#   * each spoken note (markers plus body, several seconds) sits between two of those pauses;
#   * the note bodies are NOT read again after the last paragraph: the chapter ends one
#     paragraph after the last note, with the 1.0 s chapter-end pause.
# (The Piper path publishes no word-alignment tag; the text and the map back to the source are
# covered by the Rust tests `epub_footnotes_tests` and `footnote_narration`.)
# Usage: ruby scripts/verify_footnote_narration.rb CONVERTER_CLI [KEEP_DIR]
# Needs zip, ffmpeg and the pt_BR-faber-medium model installed in the CLI profile in use.
require 'fileutils'
require 'json'
require 'open3'
require 'tmpdir'

cli = ARGV.fetch(0)
keep = ARGV[1] # optional directory that receives the EPUB and the MP3 for inspection
XML = '<?xml version="1.0" encoding="UTF-8"?>'
NOTES = [
  'A primeira nota explica a origem do jardim.',
  'A segunda nota cita o livro do velho jardineiro.'
].freeze
BODY = <<~HTML.delete("\n")
  <p>A casa ficava no fim da rua.<a epub:type="noteref" href="#n1">1</a> O jardim era grande e silencioso.</p>
  <p>Ninguém passava por ali depois do almoço.</p>
  <p>O velho abriu o portão devagar.<a epub:type="noteref" href="#n2">2</a> A tarde seguiu tranquila.</p>
  <aside epub:type="footnote" id="n1"><p>1 #{NOTES[0]}</p></aside>
  <aside epub:type="footnote" id="n2"><p>2 #{NOTES[1]}</p></aside>
HTML

def write_epub(path, body)
  Dir.mktmpdir('epub') do |dir|
    File.write(File.join(dir, 'mimetype'), 'application/epub+zip')
    FileUtils.mkdir_p(File.join(dir, 'META-INF'))
    FileUtils.mkdir_p(File.join(dir, 'OEBPS'))
    File.write(File.join(dir, 'META-INF/container.xml'), '<?xml version="1.0"?><container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles></container>')
    File.write(File.join(dir, 'OEBPS/content.opf'), "#{XML}<package xmlns=\"http://www.idpf.org/2007/opf\" version=\"3.0\" unique-identifier=\"id\"><metadata xmlns:dc=\"http://purl.org/dc/elements/1.1/\"><dc:identifier id=\"id\">urn:uuid:Jardim</dc:identifier><dc:title>Jardim</dc:title><dc:creator>T</dc:creator><dc:language>pt-BR</dc:language><meta property=\"dcterms:modified\">2026-11-23T00:00:00Z</meta></metadata><manifest><item id=\"nav\" href=\"nav.xhtml\" media-type=\"application/xhtml+xml\" properties=\"nav\"/><item id=\"c1\" href=\"c1.xhtml\" media-type=\"application/xhtml+xml\"/></manifest><spine><itemref idref=\"c1\"/></spine></package>")
    File.write(File.join(dir, 'OEBPS/nav.xhtml'), "#{XML}<html xmlns=\"http://www.w3.org/1999/xhtml\" xmlns:epub=\"http://www.idpf.org/2007/ops\"><head><title>S</title></head><body><nav epub:type=\"toc\"><ol><li><a href=\"c1.xhtml\">Capítulo 1</a></li></ol></nav></body></html>")
    File.write(File.join(dir, 'OEBPS/c1.xhtml'), "#{XML}<html xmlns=\"http://www.w3.org/1999/xhtml\" xmlns:epub=\"http://www.idpf.org/2007/ops\" xml:lang=\"pt-BR\"><head><title>C</title></head><body><h1>Capítulo 1</h1>#{body}</body></html>")
    Dir.chdir(dir) do
      system('zip', '-q', '-X0', path, 'mimetype') or abort 'zip failed'
      system('zip', '-q', '-Xr9', path, 'META-INF', 'OEBPS') or abort 'zip failed'
    end
  end
end

def convert(cli, epub, out)
  _, status = Open3.capture2e(cli, 'convert', epub, '--engine', 'piper', '--model',
                              'pt_BR-faber-medium', '--output-dir', out, '--yes')
  abort "conversion failed: #{epub}" unless status.success?
  Dir.glob(File.join(out, '**', '0001-*.mp3')).first or abort 'no chapter audio produced'
end

# [[start, duration], ...] of the silences of at least 0.30 s
def silences(mp3)
  _, err, = Open3.capture3('ffmpeg', '-hide_banner', '-i', mp3, '-af',
                           'silencedetect=noise=-38dB:d=0.30', '-f', 'null', '-')
  starts = err.scan(/silence_start: ([\d.]+)/).flatten.map(&:to_f)
  durations = err.scan(/silence_duration: ([\d.]+)/).flatten.map(&:to_f)
  starts.zip(durations).reject { |_, duration| duration.nil? }
end

def total_duration(mp3)
  out, = Open3.capture2('ffprobe', '-v', 'error', '-show_entries', 'format=duration',
                        '-of', 'csv=p=0', mp3)
  out.to_f
end

failures = []
Dir.mktmpdir('footnotes') do |dir|
  book = File.join(dir, 'Jardim.epub')
  write_epub(book, BODY)
  mp3 = convert(cli, book, File.join(dir, 'out'))
  if keep
    FileUtils.mkdir_p(keep)
    FileUtils.cp([book, mp3], keep)
  end
  pauses = silences(mp3)
  total = total_duration(mp3)
  puts "silences (start, duration): #{pauses.map { |s, d| [s.round(2), d.round(2)] }.inspect}; total #{total.round(2)} s"
  half = pauses.select { |_, duration| duration.between?(0.38, 0.65) }
  failures << "found #{half.length} pauses of about 0.5 s, want 6" unless half.length == 6
  # Two notes: the gap between a pause before a note and the pause after it holds the spoken
  # note (start marker, body, end marker): well over four seconds with this voice.
  spans = half.each_cons(2).map { |(a_start, a_dur), (b_start, _)| b_start - (a_start + a_dur) }
  failures << "expected two spoken notes of more than 4 s between pauses, got #{spans.map { |x| x.round(1) }.inspect}" unless spans.count { |x| x > 4.0 } >= 2
  last_start, last_duration = pauses.last
  failures << "chapter end pause is #{last_duration.round(2)} s, want about 1.0" unless last_duration.between?(0.85, 1.15)
  # The audio ends with the chapter-end pause right after the last paragraph, not after note bodies.
  failures << 'audio continues after the chapter-end pause' unless (total - (last_start + last_duration)).abs < 0.2
end
if failures.empty?
  puts 'footnote narration: PASS'
else
  warn failures.map { |f| "FAIL: #{f}" }
  exit 1
end
