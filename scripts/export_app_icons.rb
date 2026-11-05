#!/usr/bin/env ruby
# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'json'
require 'open3'
require 'optparse'
require 'rexml/document'
require 'tmpdir'

# Icon Composer owns the Apple materials. Static clients share its rendered
# artwork; legacy Apple and Android adaptive icons use the same clean shapes.
module AppIcons
  ROOT = File.expand_path('..', __dir__)
  DOCUMENT = 'ios/EpubToMp3/EpubToMp3/AppIcon.icon'
  CATALOG = 'ios/EpubToMp3/EpubToMp3/AppIcons.xcassets'
  ARTWORK = 'artwork/app-icons'
  ANDROID = 'flutter_app/android/app/src/main/res'
  DENSITIES = { 'mdpi' => 1, 'hdpi' => 1.5, 'xhdpi' => 2, 'xxhdpi' => 3, 'xxxhdpi' => 4 }.freeze

  def self.run!(*argv)
    out, err, status = Open3.capture3({ 'MAGICK_THREAD_LIMIT' => '1' }, *argv, chdir: ROOT)
    raise "#{argv.first} failed: #{err}\n#{out}" unless status.success?
    out
  end

  def self.write(path, content)
    absolute = File.join(ROOT, path)
    FileUtils.mkdir_p(File.dirname(absolute))
    File.binwrite(absolute, content) unless File.file?(absolute) && File.binread(absolute) == content
  end

  def self.json(path, value)
    write(path, JSON.pretty_generate(value) + "\n")
  end

  def self.source_hashes
    Dir.glob(File.join(ROOT, DOCUMENT, '**/*')).select { |f| File.file?(f) }.sort.to_h do |file|
      [file.delete_prefix(ROOT + '/'), Digest::SHA256.file(file).hexdigest]
    end
  end

  def self.render_apple
    require_relative 'native_job'
    require_relative 'xcode_build_paths'
    # Legacy app tasks intentionally select Xcode 16.4; the composer is a
    # separate installed producer and must not inherit that older selection.
    developer = ENV['ICON_COMPOSER_DEVELOPER_DIR'] || XcodeBuildPaths::IPHONE_16E_DEVELOPER
    tool = File.expand_path('../Applications/Icon Composer.app/Contents/Executables/ictool', developer)
    raise 'Icon Composer is required from the installed Xcode 26.3' unless File.executable?(tool)
    %w[iOS macOS].each do |platform|
      Dir.mktmpdir('app-icon-render-') do |tmp|
        output = File.join(tmp, 'icon.png')
        argv = [tool, File.join(ROOT, DOCUMENT), '--export-image', '--output-file', output,
                '--platform', platform, '--rendition', 'Default', '--width', '1024', '--height', '1024', '--scale', '1']
        status = NativeJob.run(phase: 'build', command: argv)
        raise "Icon Composer failed for #{platform}" unless status == 0
        name = platform == 'iOS' ? 'app-icon.png' : 'app-icon-macos.png'
        normalized = File.join(tmp, 'normalized.png')
        run!('magick', output, '-depth', '8', '-strip', normalized)
        write("#{ARTWORK}/#{name}", File.binread(normalized))
      end
    end
    json("#{ARTWORK}/render-receipt.json", {
      'inputs' => source_hashes, 'tool_version' => JSON.parse(run!(tool, '--version')),
      'renders' => %w[app-icon.png app-icon-macos.png].to_h do |name|
        [name, Digest::SHA256.file(File.join(ROOT, ARTWORK, name)).hexdigest]
      end
    })
  end

  def self.verify_render
    receipt = JSON.parse(File.read(File.join(ROOT, ARTWORK, 'render-receipt.json')))
    raise 'Icon source changed; run with --render-apple using Xcode 26.3' unless receipt.fetch('inputs') == source_hashes
    receipt.fetch('renders').each do |name, hash|
      raise "Rendered master changed: #{name}" unless Digest::SHA256.file(File.join(ROOT, ARTWORK, name)).hexdigest == hash
    end
  end

  def self.layer_markup
    document = JSON.parse(File.read(File.join(ROOT, DOCUMENT, 'icon.json')))
    # Icon Composer stores the frontmost group first; SVG paints back to front.
    document.fetch('groups').reverse.flat_map { |g| g.fetch('layers').reverse }.map do |layer|
      file = File.join(ROOT, DOCUMENT, 'Assets', layer.fetch('image-name'))
      REXML::Document.new(File.read(file)).root.elements.map(&:to_s).join("\n")
    end.join("\n")
  end

  def self.generate
    verify_render
    outputs = []
    export = lambda do |source, path, size, *arguments|
      Dir.mktmpdir('app-icon-export-') do |tmp|
        output = File.join(tmp, File.basename(path))
        run!('magick', '-background', 'none', source, '-resize', "#{size}x#{size}", *arguments, '-depth', '8', '-strip', output)
        write(path, File.binread(output))
      end
      outputs << path
    end
    Dir.mktmpdir('app-icon-layers-') do |tmp|
      foreground = File.join(tmp, 'foreground.svg')
      square = File.join(tmp, 'square.svg')
      opening = '<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">'
      markup = layer_markup
      File.write(foreground, opening + markup + '</svg>')
      File.write(square, opening + '<rect width="1024" height="1024" fill="#6f5bd0"/>' + markup + '</svg>')
      master = File.join(ROOT, ARTWORK, 'app-icon.png')
      mac = File.join(ROOT, ARTWORK, 'app-icon-macos.png')
      entries = JSON.parse(File.read(File.join(ROOT, CATALOG, 'AppIcon.appiconset/Contents.json'))).fetch('images')
      entries.each do |entry|
        size = (entry.fetch('size').split('x').first.to_f * entry.fetch('scale').to_f).round
        source = entry['idiom'] == 'mac' ? mac : square
        arguments = entry['idiom'] == 'mac' ? [] : ['-alpha', 'off']
        export.call(source, "#{CATALOG}/AppIcon.appiconset/#{entry.fetch('filename')}", size, *arguments)
      end
      { 'web/public/favicon.png' => 64, 'web/public/apple-touch-icon.png' => 180,
        'web/public/app-icon-192.png' => 192, 'web/public/app-icon-512.png' => 512,
        'flutter_app/linux/resources/app-icon.png' => 512 }.each { |path, size| export.call(master, path, size) }
      export.call(master, 'flutter_app/windows/runner/resources/app_icon.ico', 256, '-define', 'icon:auto-resize=256,128,64,48,32,16')
      export.call(master, 'web/public/favicon.ico', 64, '-define', 'icon:auto-resize=64,48,32,16')
      DENSITIES.each do |density, scale|
        export.call(master, "#{ANDROID}/mipmap-#{density}/ic_launcher.png", (48 * scale).round)
        # Keep the complete mark inside Android's 66/108 adaptive safe region.
        Dir.mktmpdir('adaptive-icon-') do |adaptive|
          padded = File.join(adaptive, 'foreground.svg')
          File.write(padded, opening + '<g transform="translate(133.12 133.12) scale(0.74)">' + markup + '</g></svg>')
          export.call(padded, "#{ANDROID}/drawable-#{density}/ic_launcher_foreground.png", (108 * scale).round)
        end
      end
      monochrome = REXML::Document.new(opening + '<g pivot="512">' + markup + '</g></svg>')
      paths = REXML::XPath.match(monochrome, '//path|//rect').map do |shape|
        # Android's VectorDrawable pathData has no SVG rect shorthand.
        if shape.name == 'rect'
          x, y, w, h, r = %w[x y width height rx].map { |key| shape.attributes[key].to_f }
          d = "M#{x+r},#{y} H#{x+w-r} Q#{x+w},#{y} #{x+w},#{y+r} V#{y+h-r} Q#{x+w},#{y+h} #{x+w-r},#{y+h} H#{x+r} Q#{x},#{y+h} #{x},#{y+h-r} V#{y+r} Q#{x},#{y} #{x+r},#{y} Z"
        else
          d = shape.attributes['d']
        end
        fill = shape.attributes['fill'] == 'none' ? '#00000000' : '#FFFFFFFF'
        stroke = shape.attributes['stroke'] ? " android:strokeColor=\"#FFFFFFFF\" android:strokeWidth=\"#{shape.attributes['stroke-width']}\" android:strokeLineCap=\"round\"" : ''
        "    <path android:fillColor=\"#{fill}\" android:pathData=\"#{d}\"#{stroke}/>"
      end.join("\n")
      path = "#{ANDROID}/drawable/ic_launcher_monochrome.xml"
      write(path, "<vector xmlns:android=\"http://schemas.android.com/apk/res/android\" android:width=\"108dp\" android:height=\"108dp\" android:viewportWidth=\"1024\" android:viewportHeight=\"1024\">\n  <group android:pivotX=\"512\" android:pivotY=\"512\" android:scaleX=\"0.74\" android:scaleY=\"0.74\">\n#{paths}\n  </group>\n</vector>\n")
      outputs << path
    end
    json("#{ARTWORK}/exports.json", { 'inputs' => source_hashes,
      'exporter_sha256' => Digest::SHA256.file(__FILE__).hexdigest,
      'outputs' => outputs.sort.to_h { |path| [path, Digest::SHA256.file(File.join(ROOT, path)).hexdigest] } })
    puts "Exported #{outputs.size} app icon resources."
  end

  def self.check
    verify_render
    manifest = JSON.parse(File.read(File.join(ROOT, ARTWORK, 'exports.json')))
    raise 'Export source identity is stale' unless manifest.fetch('inputs') == source_hashes
    raise 'Exporter changed; regenerate icons' unless manifest.fetch('exporter_sha256') == Digest::SHA256.file(__FILE__).hexdigest
    manifest.fetch('outputs').each do |path, hash|
      raise "Stale icon resource: #{path}" unless Digest::SHA256.file(File.join(ROOT, path)).hexdigest == hash
    end
    puts "Verified #{manifest.fetch('outputs').size} resources against their source and rendered-master identities."
  end

  def self.main(argv)
    options = {}
    OptionParser.new do |parser|
      parser.banner = 'Usage: export_app_icons.rb [--render-apple] [--check]'
      parser.on('--render-apple') { options[:render] = true }
      parser.on('--check') { options[:check] = true }
    end.parse!(argv)
    raise 'Unexpected arguments' unless argv.empty?
    raise '--check cannot render' if options[:check] && options[:render]
    render_apple if options[:render]
    options[:check] ? check : generate
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    AppIcons.main(ARGV)
  rescue StandardError => error
    warn "App icon export failed: #{error.message}"
    exit 1
  end
end
