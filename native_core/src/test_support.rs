use std::{
    ops::Deref,
    path::PathBuf,
    sync::{
        Arc,
        atomic::{AtomicU64, Ordering},
    },
};

static NEXT_TEMP_ROOT: AtomicU64 = AtomicU64::new(0);

/// Owns a test-only temporary directory and removes it when the final clone drops.
#[derive(Clone, Debug)]
pub(crate) struct TestTempDir(Arc<TestTempDirInner>);

#[derive(Debug)]
struct TestTempDirInner {
    path: PathBuf,
}

impl TestTempDir {
    pub(crate) fn new(name: &str) -> Self {
        loop {
            let sequence = NEXT_TEMP_ROOT.fetch_add(1, Ordering::Relaxed);
            let path = std::env::temp_dir().join(format!(
                "private-gallery-{name}-{}-{sequence}",
                std::process::id()
            ));
            match std::fs::create_dir(&path) {
                Ok(()) => return Self(Arc::new(TestTempDirInner { path })),
                Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => continue,
                Err(error) => panic!("create test temp root {}: {error}", path.display()),
            }
        }
    }
}

impl Deref for TestTempDir {
    type Target = PathBuf;

    fn deref(&self) -> &Self::Target {
        &self.0.path
    }
}

impl Drop for TestTempDirInner {
    fn drop(&mut self) {
        // Cleanup is best-effort: it must never replace a test's original result
        // or panic while another panic is already unwinding.
        let _ = std::fs::remove_dir_all(&self.path);
    }
}

#[cfg(test)]
mod tests {
    use super::TestTempDir;

    #[test]
    fn removes_directory_after_normal_scope_exit() {
        let path;
        {
            let temp = TestTempDir::new("drop-normal");
            path = temp.to_path_buf();
            std::fs::write(path.join("fixture"), b"test").expect("write fixture");
        }
        assert!(!path.exists(), "temporary root should be removed on drop");
    }

    #[test]
    fn removes_directory_when_test_code_unwinds() {
        let path = std::cell::RefCell::new(None);
        let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
            let temp = TestTempDir::new("drop-unwind");
            *path.borrow_mut() = Some(temp.to_path_buf());
            panic!("exercise unwind cleanup");
        }));
        assert!(result.is_err());
        let path = path.into_inner().expect("temp path was recorded");
        assert!(!path.exists(), "temporary root should be removed on unwind");
    }

    #[test]
    fn cleanup_failure_does_not_panic() {
        let temp = TestTempDir::new("drop-cleanup-failure");
        std::fs::remove_dir_all(&*temp).expect("remove directory before guard drop");
        drop(temp);
    }
}
