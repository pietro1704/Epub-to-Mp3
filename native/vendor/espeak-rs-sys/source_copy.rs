use std::path::Path;
use std::process::Command;

pub fn prepare_source(src: &Path, dst: &Path) {
    if dst.exists() {
        std::fs::remove_dir_all(dst).expect("Failed to remove cached espeak-ng source");
    }
    std::fs::create_dir_all(dst).expect("Failed to create dst directory");
    if cfg!(unix) {
        let status = Command::new("cp")
            .arg("-rf")
            .arg(src)
            .arg(dst.parent().unwrap())
            .status()
            .expect("Failed to execute cp command");
        assert!(
            status.success(),
            "Failed to copy espeak-ng source: {status}"
        );
    }
    if cfg!(windows) {
        let status = Command::new("robocopy.exe")
            .arg("/e")
            .arg(src)
            .arg(dst)
            .status()
            .expect("Failed to execute robocopy command");
        assert!(
            matches!(status.code(), Some(0..=7)),
            "Failed to copy espeak-ng source: {status}"
        );
    }
}

#[cfg(test)]
mod tests {
    use super::prepare_source;
    use std::fs;
    use std::path::PathBuf;
    use std::sync::atomic::{AtomicU64, Ordering};

    struct Fixture(PathBuf);

    impl Fixture {
        fn new() -> Self {
            static NEXT: AtomicU64 = AtomicU64::new(0);
            let path = std::env::temp_dir().join(format!(
                "espeak source copy {} {}",
                std::process::id(),
                NEXT.fetch_add(1, Ordering::Relaxed)
            ));
            fs::create_dir(&path).expect("Create exclusive test directory");
            Self(path)
        }
    }

    impl Drop for Fixture {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }

    #[test]
    fn refreshes_changed_added_and_removed_source_inputs() {
        let fixture = Fixture::new();
        let src = fixture.0.join("vendor with spaces/espeak-ng");
        let dst = fixture.0.join("cached output/espeak-ng");
        let build_sentinel = fixture.0.join("cached output/build/sentinel");
        fs::create_dir_all(build_sentinel.parent().unwrap()).unwrap();
        fs::write(&build_sentinel, b"preserve sibling build output").unwrap();
        fs::create_dir_all(&src).unwrap();
        fs::write(src.join("changed.wav"), b"original").unwrap();
        fs::write(src.join("removed.wav"), b"obsolete").unwrap();
        prepare_source(&src, &dst);
        assert_eq!(fs::read(dst.join("changed.wav")).unwrap(), b"original");
        assert_eq!(fs::read(dst.join("removed.wav")).unwrap(), b"obsolete");

        fs::write(src.join("changed.wav"), b"updated").unwrap();
        fs::remove_file(src.join("removed.wav")).unwrap();
        fs::create_dir(src.join("new phonemes")).unwrap();
        fs::write(src.join("new phonemes/null.wav"), b"new input").unwrap();
        prepare_source(&src, &dst);
        prepare_source(&src, &dst);
        assert_eq!(fs::read(dst.join("changed.wav")).unwrap(), b"updated");
        assert_eq!(
            fs::read(dst.join("new phonemes/null.wav")).unwrap(),
            b"new input"
        );
        assert!(!dst.join("removed.wav").exists());
        assert!(!dst.join("espeak-ng").exists());
        assert_eq!(
            fs::read(build_sentinel).unwrap(),
            b"preserve sibling build output"
        );
    }

    #[test]
    fn failed_copy_refuses_to_continue_with_cached_source() {
        let fixture = Fixture::new();
        let src = fixture.0.join("missing vendor/espeak-ng");
        let dst = fixture.0.join("cached output/espeak-ng");
        fs::create_dir_all(&dst).unwrap();
        fs::write(dst.join("stale.wav"), b"stale").unwrap();
        let failure = std::panic::catch_unwind(|| prepare_source(&src, &dst));
        let payload = failure.expect_err("A nonzero copy exit must fail the build");
        let message = payload
            .downcast_ref::<String>()
            .map(String::as_str)
            .or_else(|| payload.downcast_ref::<&str>().copied())
            .unwrap_or("");
        assert!(message.contains("Failed to copy espeak-ng source"));
        assert!(!dst.join("stale.wav").exists());
    }
}
