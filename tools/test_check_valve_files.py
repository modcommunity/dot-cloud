#!/usr/bin/env python3
"""Tests for check_valve_files.py: python3 -I tools/test_check_valve_files.py"""
import os, subprocess, sys, tempfile, unittest, zlib

TOOL = os.path.join(os.path.dirname(os.path.abspath(__file__)), "check_valve_files.py")


def run(*args, env=None):
    e = dict(os.environ, DOT_VALVE_INDEX="/nonexistent"); e.update(env or {})
    return subprocess.run([sys.executable, "-I", TOOL, *args], capture_output=True, text=True, env=e)


def put(root, rel, data=b"x"):
    p = os.path.join(root, rel); os.makedirs(os.path.dirname(p), exist_ok=True)
    with open(p, "wb") as f:
        f.write(data)


class Guard(unittest.TestCase):
    def setUp(self):
        self.t = tempfile.TemporaryDirectory(); self.d = self.t.name

    def tearDown(self):
        self.t.cleanup()

    def test_clean_pack_passes(self):
        put(self.d, "maps/a/map.json", b"{}"); put(self.d, "tex/wall.png", b"png"); put(self.d, "m/prop.glb", b"glb")
        r = run(self.d, "--id", "good_pack")
        self.assertEqual(r.returncode, 0, r.stderr); self.assertEqual(r.stdout, "")

    def test_stock_files_refused_and_listed(self):
        bad = ["tf/tf2_misc_dir.vpk", "x/brick.vtf", "x/brick.vmt", "m/crate.mdl", "m/crate.dx90.vtx", "m/crate.vvd", "m/crate.phy", "textures/orig/a.png"]
        for b in bad: put(self.d, b)
        put(self.d, "ok.png")
        r = run(self.d)
        self.assertEqual(r.returncode, 1)
        for b in bad: self.assertIn(b + ":", r.stdout)
        self.assertNotIn("ok.png", r.stdout); self.assertIn("REFUSED, %d" % len(bad), r.stderr)

    def test_orig_pack_id_refused(self):
        put(self.d, "a.png"); r = run(self.d, "--id", "cp_orange_x3_orig")
        self.assertEqual(r.returncode, 1); self.assertIn("_orig", r.stdout)

    def test_content_hash_match_under_innocent_name(self):
        data = b"stock bytes pretending to be ours"
        idx = os.path.join(self.d, "idx")
        with open(idx, "w") as f:
            f.write("%08x\t%d\tmaterials/brick/x.vtf\n" % (zlib.crc32(data), len(data)))
        pack = os.path.join(self.d, "pack"); put(pack, "tex/wall.png", data); put(pack, "tex/other.png", b"mine")
        r = run(pack, env={"DOT_VALVE_INDEX": idx})
        self.assertEqual(r.returncode, 1); self.assertIn("tex/wall.png", r.stdout); self.assertIn("materials/brick/x.vtf", r.stdout)
        self.assertNotIn("other.png", r.stdout)

    def test_no_index_notes_skip_but_still_checks_names(self):
        put(self.d, "a.vtf"); r = run(self.d)
        self.assertEqual(r.returncode, 1); self.assertIn("content-hash match skipped", r.stderr)

    def test_git_mode_checks_tracked_and_staged(self):
        subprocess.run(["git", "init", "-q", self.d], check=True)
        put(self.d, "a.png"); put(self.d, "bad.vmt")
        subprocess.run(["git", "-C", self.d, "add", "-A"], check=True)
        self.assertEqual(run("--git", "--staged", self.d).returncode, 1)
        self.assertIn("bad.vmt", run("--git", self.d).stdout)
        put(self.d, "untracked.vtf")  # not tracked: not a repo problem
        self.assertNotIn("untracked.vtf", run("--git", self.d).stdout)

    def test_hook_blocks_commit(self):
        subprocess.run(["git", "init", "-q", self.d], check=True)
        self.assertEqual(run("--install-hook", self.d).returncode, 0)
        put(self.d, "m.mdl"); subprocess.run(["git", "-C", self.d, "add", "-A"], check=True)
        c = subprocess.run(["git", "-C", self.d, "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "x"],
                           capture_output=True, text=True, env=dict(os.environ, DOT_VALVE_INDEX="/nonexistent"))
        self.assertNotEqual(c.returncode, 0); self.assertIn("m.mdl", c.stdout + c.stderr)

    def test_excluded_dir_is_not_scanned(self):
        put(self.d, "addons/x/a.vtf"); put(self.d, "ok.png")
        self.assertEqual(run(self.d, "--exclude-dir", "addons/x").returncode, 0)

    def test_lock_scans_published_manifest_paths(self):
        import base64, json
        def pub(pid, paths):
            body = json.dumps({"files": [{"path": p} for p in paths]}).encode()
            put(self.d, "cdn/%s/1.0.0/manifest.json" % pid, json.dumps({"payload": base64.urlsafe_b64encode(body).decode().rstrip("=")}).encode())
        pub("o/good", ["a.png", "m.glb"]); pub("o/bad", ["tex/x.vtf", "a.png"])
        lock = os.path.join(self.d, "l.json")
        with open(lock, "w") as f:
            json.dump({"origin": "file://" + os.path.join(self.d, "cdn"), "packs": [{"id": "o/good", "version": "1.0.0"}, {"id": "o/bad", "version": "1.0.0"}]}, f)
        r = run("--lock", lock)
        self.assertEqual(r.returncode, 1); self.assertIn("o/bad@1.0.0:tex/x.vtf", r.stdout); self.assertNotIn("o/good", r.stdout)
        self.assertEqual(run("--lock", lock, "--only", "o/good").returncode, 0)
        with open(lock, "w") as f:
            json.dump({"origin": "file:///nonexistent", "packs": [{"id": "o/good", "version": "1.0.0"}]}, f)
        self.assertEqual(run("--lock", lock).returncode, 2)

    def test_allow_file_exempts_fixtures(self):
        put(self.d, "fixture/tiny.vpk"); al = os.path.join(self.d, "allow")
        with open(al, "w") as f:
            f.write("fixture/*\n")
        self.assertEqual(run(self.d, env={"DOT_VALVE_ALLOW": al}).returncode, 0)


if __name__ == "__main__":
    unittest.main()
