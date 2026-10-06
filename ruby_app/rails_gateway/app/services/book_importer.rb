class BookImporter
  MAX_BYTES = 100 * 1024 * 1024
  def self.call(upload)
    raise ArgumentError, "EPUB file required" unless upload.respond_to?(:original_filename) && upload.respond_to?(:tempfile)
    raise ArgumentError, "EPUB files only" unless File.extname(upload.original_filename).downcase == ".epub"
    raise ArgumentError, "EPUB too large" if upload.tempfile.size > MAX_BYTES
    root = Rails.root.join("storage", "books")
    FileUtils.mkdir_p(root)
    safe = "#{SecureRandom.uuid}.epub"
    path = root.join(safe)
    FileUtils.copy_file(upload.tempfile.path, path)
    Book.create!(title: File.basename(upload.original_filename, ".epub"), source_path: path.to_s)
  end
end
