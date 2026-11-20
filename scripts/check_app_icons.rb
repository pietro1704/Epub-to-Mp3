#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'rexml/document'
require 'zlib'
require_relative 'export_app_icons'

AppIcons.check

def png(path, size, opaque: false)
  bytes = File.binread(File.join(AppIcons::ROOT, path), 26)
  raise "Not a PNG: #{path}" unless bytes.start_with?("\x89PNG\r\n\x1a\n".b)
  raise "Wrong dimensions: #{path}" unless bytes[16, 8].unpack('NN') == [size, size]
  raise "Not 8-bit: #{path}" unless bytes.getbyte(24) == 8
  raise "Unexpected alpha channel: #{path}" if opaque && [4, 6].include?(bytes.getbyte(25))
end

# Width of the non-transparent area of an 8-bit RGBA, non-interlaced PNG.
# Decoded here so the checker needs no image tool on CI.
def opaque_width(path)
  data = File.binread(path)
  raise "Not a PNG: #{path}" unless data.start_with?("\x89PNG\r\n\x1a\n".b)
  offset = 8
  idat = +''.b
  width = height = nil
  while offset < data.bytesize
    length, type = data[offset, 8].unpack('Na4')
    chunk = data[offset + 8, length]
    case type
    when 'IHDR'
      width, height, depth, color, _, _, interlace = chunk.unpack('NNCCCCC')
      raise "Expected 8-bit RGBA non-interlaced: #{path}" unless depth == 8 && color == 6 && interlace.zero?
    when 'IDAT' then idat << chunk
    when 'IEND' then break
    end
    offset += 12 + length
  end
  raw = Zlib::Inflate.inflate(idat)
  stride = width * 4
  previous = Array.new(stride, 0)
  left = width
  right = -1
  height.times do |row|
    filter = raw.getbyte(row * (stride + 1))
    line = raw.byteslice(row * (stride + 1) + 1, stride).bytes
    stride.times do |index|
      a = index >= 4 ? line[index - 4] : 0
      b = previous[index]
      c = index >= 4 ? previous[index - 4] : 0
      line[index] = (line[index] + case filter
                                   when 0 then 0
                                   when 1 then a
                                   when 2 then b
                                   when 3 then (a + b) / 2
                                   when 4
                                     p = a + b - c
                                     pa = (p - a).abs
                                     pb = (p - b).abs
                                     pc = (p - c).abs
                                     pa <= pb && pa <= pc ? a : (pb <= pc ? b : c)
                                   else raise "Unknown PNG filter #{filter}: #{path}"
                                   end) & 0xff
    end
    3.step(stride - 1, 4) do |alpha|
      next if line[alpha].zero?

      x = alpha / 4
      left = x if x < left
      right = x if x > right
    end
    previous = line
  end
  right < left ? 0 : right - left + 1
end

catalog = JSON.parse(File.read(File.join(AppIcons::ROOT, AppIcons::CATALOG, 'AppIcon.appiconset/Contents.json')))
catalog.fetch('images').each do |image|
  size = (image.fetch('size').split('x').first.to_f * image.fetch('scale').to_f).round
  png("#{AppIcons::CATALOG}/AppIcon.appiconset/#{image.fetch('filename')}", size, opaque: image['idiom'] != 'mac')
end

# The macOS Dock draws the file as given: the icon body must keep the 824/1024 grid.
mac_largest = File.join(AppIcons::ROOT, AppIcons::CATALOG, 'AppIcon.appiconset/icon-mac-512@2x.png')
body = opaque_width(mac_largest)
unless body.between?((1024 * AppIcons::MAC_BODY_RATIO).round - 2, (1024 * AppIcons::MAC_BODY_RATIO).round + 2)
  raise "macOS icon body is #{body}px wide in 1024; expected about #{(1024 * AppIcons::MAC_BODY_RATIO).round}"
end

AppIcons::DENSITIES.each do |density, scale|
  png("#{AppIcons::ANDROID}/mipmap-#{density}/ic_launcher.png", (48 * scale).round)
  png("#{AppIcons::ANDROID}/drawable-#{density}/ic_launcher_foreground.png", (108 * scale).round)
end

{ 'ruby_app/rails_gateway/public/favicon.ico' => [16, 32, 48, 64],
  'flutter_app/windows/runner/resources/app_icon.ico' => [16, 32, 48, 64, 128, 256] }.each do |path, expected|
  bytes = File.binread(File.join(AppIcons::ROOT, path))
  reserved, type, count = bytes.unpack('vvv')
  raise "Invalid ICO: #{path}" unless reserved == 0 && type == 1 && count == expected.size
  dimensions = count.times.map do |index|
    entry = bytes[6 + index * 16, 16]
    width, height = entry.unpack('CC').map { |value| value.zero? ? 256 : value }
    size, offset = entry[8, 8].unpack('VV')
    raise "Invalid ICO image: #{path}" unless width == height && size.positive? && offset >= 6 + 16 * count && offset + size <= bytes.bytesize
    width
  end
  raise "Missing ICO sizes: #{path}" unless dimensions.sort == expected
end

manifest = JSON.parse(File.read(File.join(AppIcons::ROOT, 'ruby_app/rails_gateway/public/site.webmanifest')))
manifest.fetch('icons').each do |icon|
  size = Integer(icon.fetch('sizes').split('x').first)
  png('ruby_app/rails_gateway/public' + icon.fetch('src'), size)
end
png('ruby_app/rails_gateway/public/favicon.png', 64)
png('ruby_app/rails_gateway/public/apple-touch-icon.png', 180)
png('flutter_app/linux/resources/app-icon.png', 512)
Dir.glob(File.join(AppIcons::ROOT, AppIcons::ANDROID, '**/*launcher*.xml')).each do |path|
  REXML::Document.new(File.read(path))
end
puts 'Apple slot dimensions/opacity, Windows/Web ICO payloads, Web references and Android icon resources passed.'
