# frozen_string_literal: true
require 'fileutils'
require 'json'
root = File.realpath(File.expand_path('../../..', __dir__))
out = File.join(root, '.reports/tts-six/20261014')
target = File.join(out, 'downloads')
abort 'Unexpected cleanup path' unless File.directory?(target) && !File.symlink?(target) && File.realpath(target) == target
lease = File.open('/tmp/epub2mp3.heavy-job.lock', 'a+')
abort 'Native job is still active; no cleanup performed' unless lease.flock(File::LOCK_EX | File::LOCK_NB)
begin
  files = Dir.glob(File.join(target, '**/*'), File::FNM_DOTMATCH).select { |f| File.file?(f) }
  bytes = files.sum { |f| File.size(f) }
  FileUtils.remove_entry_secure(target)
  abort 'Downloaded test tree still exists' if File.exist?(target)
  File.write(File.join(out, 'host-cleanup.json'), JSON.pretty_generate({ deleted_path: target, file_count: files.length, bytes: bytes, absence_verified: true, preserved: ['pre-existing models', 'reports', 'generated benchmark audio'] }) + "\n")
ensure
  lease.flock(File::LOCK_UN)
  lease.close
end
