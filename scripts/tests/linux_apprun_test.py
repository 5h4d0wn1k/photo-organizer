#!/usr/bin/env python3
"""The packaged launcher must reach Flutter without a blocking daemon probe."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


class AppRunTest(unittest.TestCase):
    def test_daemon_start_does_not_block_flutter(self):
        source = Path(__file__).resolve().parents[2] / "assets/linux/AppRun"
        with tempfile.TemporaryDirectory(prefix="photo-organizer-apprun-") as root:
            bundle = Path(root)
            shutil.copyfile(source, bundle / "AppRun")
            # galleryd has no --check mode: any invocation stays in its server
            # loop. This faithfully catches a foreground health-probe call.
            daemon = bundle / "galleryd"
            daemon.write_text('#!/bin/bash\nexec sleep 15\n')
            daemon.chmod(0o755)
            app = bundle / "private_gallery_app"
            app.write_text('#!/bin/bash\nprintf "%s\\n" "$@" > "$TEST_APP_ARGS"\n')
            app.chmod(0o755)
            tools = bundle / "bin"
            tools.mkdir()
            (tools / "pgrep").write_text('#!/bin/bash\nexit 1\n')
            (tools / "pgrep").chmod(0o755)
            args = bundle / "args.txt"
            env = dict(os.environ, PATH=f"{tools}:{os.environ['PATH']}",
                       PRIVATE_GALLERY_RUNTIME_ROOT=str(bundle / "runtime"),
                       TEST_APP_ARGS=str(args))
            process = subprocess.Popen(["bash", str(bundle / "AppRun"), "a photo.jpg"],
                                       env=env, start_new_session=True,
                                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            try:
                self.assertEqual(process.wait(timeout=3), 0)
                self.assertEqual(args.read_text(), "a photo.jpg\n")
            finally:
                import signal
                try:
                    os.killpg(process.pid, signal.SIGTERM)
                except ProcessLookupError:
                    pass
                process.wait(timeout=3)


if __name__ == "__main__":
    unittest.main()
