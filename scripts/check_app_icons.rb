#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'rexml/document'
require_relative 'export_app_icons'

AppIcons.check

def png(path, size, opaque: false)
  bytes = File.binread(File.join(AppIcons::ROOT, path), 26)
  raise "Not a PNG: #{path}" unless bytes.start_with?("\x89PNG\r\n\x1a\n".b)
  raise "Wrong dimensions: #{path}" unless bytes[16, 8].unpack('NN') == [size, size]
  raise "Not 8-bit: #{path}" unless bytes.getbyte(24) == 8
  raise "Unexpected alpha channel: #{path}" if opaque && [4, 6].include?(bytes.getbyte(25))
end

catalog = JSON.parse(File.read(File.join(AppIcons::ROOT, AppIcons::CATALOG, 'AppIcon.appiconset/Contents.json')))
catalog.fetch('images').each do |image|
  size = (image.fetch('size').split('x').first.to_f * image.fetch('scale').to_f).round
  png("#{AppIcons::CATALOG}/AppIcon.appiconset/#{image.fetch('filename')}", size, opaque: image['idiom'] != 'mac')
end

AppIcons::DENSITIES.each do |density, scale|
  png("#{AppIcons::ANDROID}/mipmap-#{density}/ic_launcher.png", (48 * scale).round)
  png("#{AppIcons::ANDROID}/drawable-#{density}/ic_launcher_foreground.png", (108 * scale).round)
end

{ 'web/public/favicon.ico' => [16, 32, 48, 64],
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

manifest = JSON.parse(File.read(File.join(AppIcons::ROOT, 'web/public/site.webmanifest')))
manifest.fetch('icons').each do |icon|
  size = Integer(icon.fetch('sizes').split('x').first)
  png('web/public' + icon.fetch('src'), size)
end
png('web/public/favicon.png', 64)
png('web/public/apple-touch-icon.png', 180)
png('flutter_app/linux/resources/app-icon.png', 512)
Dir.glob(File.join(AppIcons::ROOT, AppIcons::ANDROID, '**/*launcher*.xml')).each do |path|
  REXML::Document.new(File.read(path))
end
puts 'Apple slot dimensions/opacity, Windows/Web ICO payloads, Web references and Android icon resources passed.'
