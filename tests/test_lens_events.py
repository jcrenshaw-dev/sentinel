"""Tests for lens-events.py: what counts as read, the run summary and coverage.txt.

Run from the kit's root: python3 -I -m unittest discover -s tests
"""
import contextlib
import importlib.util
import io
import json
import os
import pathlib
import tempfile
import unittest

HERE = pathlib.Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("lens_events", HERE.parent / "lens-events.py")
le = importlib.util.module_from_spec(spec)
spec.loader.exec_module(le)


def write(root, name, lines):
    path = os.path.join(root, name)
    with open(path, "w") as f:
        f.write("".join("line %d\n" % i for i in range(1, lines + 1)))
    return path


def events_file(root, lines):
    path = os.path.join(root, "events.jsonl")
    with open(path, "w") as f:
        for d in lines:
            f.write(json.dumps(d) + "\n")
    return path


class Covers(unittest.TestCase):
    def test_spans(self):
        self.assertTrue(le.covers([(1, 5), (6, 10)], 10))
        self.assertTrue(le.covers([(3, 10), (1, 4)], 10))
        self.assertFalse(le.covers([(1, 4), (6, 10)], 10))
        self.assertFalse(le.covers([(2, 10)], 10))
        self.assertFalse(le.covers([(1, 9)], 10))


class ClaudeRun(unittest.TestCase):
    def test_reads_and_summary(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = os.path.join(tmp, "repo")
            os.mkdir(root)
            a, b, c = (write(root, n, k) for n, k in (("a.rs", 10), ("b.rs", 3), ("c.rs", 5)))

            def read_call(cid, path, **extra):
                return {"type": "assistant", "message": {"content": [
                    {"type": "tool_use", "id": cid, "name": "Read", "input": dict(file_path=path, **extra)}]}}

            def read_result(cid, meta, is_error=False):
                return {"type": "user", "tool_use_result": meta, "message": {"content": [
                    {"type": "tool_result", "tool_use_id": cid, "is_error": is_error}]}}

            lines = [
                read_call("1", a),
                read_result("1", {"type": "text", "file": {"filePath": a, "numLines": 10, "startLine": 1, "totalLines": 10}}),
                read_call("2", b, offset=2, limit=1),
                read_result("2", {"type": "text", "file": {"filePath": b, "numLines": 1, "startLine": 2, "totalLines": 3}}),
                read_call("3", c),
                read_result("3", {"type": "text"}, is_error=True),
                read_call("4", "/etc/hostname"),
                read_result("4", {"type": "text", "file": {"filePath": "/etc/hostname", "numLines": 1, "startLine": 1, "totalLines": 1}}),
                {"type": "result", "result": "## No findings\n- examined: a.rs\n", "stop_reason": "refusal",
                 "safety_stops": 2, "modelUsage": {"claude-opus-5-5": {"outputTokens": 5}, "claude-haiku-5-5": {"outputTokens": 0}}},
            ]
            events = events_file(tmp, lines)
            dest = os.path.join(tmp, "lens")
            reads_path = os.path.join(tmp, "reads")
            out, err = io.StringIO(), io.StringIO()
            with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
                le.run("claude", events, dest, reads_path, root)
            self.assertEqual(out.getvalue().split("\n")[:4], ["claude-opus-5-5", "blocked", "1", "2"])
            with open(reads_path) as f:
                self.assertEqual(json.load(f), {"a.rs": "full", "b.rs": "part"})
            with open(dest + ".md.part") as f:
                self.assertEqual(f.read(), "## No findings\n- examined: a.rs\n")

    def test_no_result_exits_1(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = os.path.join(tmp, "repo")
            os.mkdir(root)
            events = events_file(tmp, [{"type": "assistant", "message": {"content": []}}])
            with self.assertRaises(SystemExit) as cm, contextlib.redirect_stdout(io.StringIO()):
                le.run("claude", events, os.path.join(tmp, "lens"), os.path.join(tmp, "reads"), root)
            self.assertEqual(cm.exception.code, 1)


class CodexRun(unittest.TestCase):
    def test_commands(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = os.path.join(tmp, "repo")
            os.mkdir(root)
            for n, k in (("a.rs", 10), ("b.rs", 3), ("c.rs", 5), ("d.rs", 4), ("e.rs", 4), ("f.rs", 3), ("g.rs", 6)):
                write(root, n, k)

            def cmd(command, exit_code=0):
                return {"type": "item.completed", "item": {"type": "command_execution", "exit_code": exit_code, "command": command}}

            lines = [
                cmd("bash -lc 'cat a.rs'"),                 # whole file
                cmd("sed -n 1,2p b.rs"),                    # two of three lines
                cmd("grep foo c.rs"),                       # some unknown part
                cmd("cat d.rs > /dev/null"),                # redirected: never reached the model
                cmd("bash -lc 'cat e.rs | wc -l'"),         # piped into something that prints none of it
                cmd("head -n 3 f.rs"),                      # all three lines
                cmd("cat g.rs", exit_code=1),               # failed
                cmd("cat /etc/hostname"),                   # outside the snapshot
                {"type": "error", "message": "rate limited"},
            ]
            events = events_file(tmp, lines)
            reads_path = os.path.join(tmp, "reads")
            out, err = io.StringIO(), io.StringIO()
            with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
                le.run("codex", events, os.path.join(tmp, "lens"), reads_path, root)
            self.assertEqual(out.getvalue().split("\n")[:4], ["", "", "2", "0"])
            self.assertIn("rate limited", err.getvalue())
            with open(reads_path) as f:
                self.assertEqual(json.load(f), {"a.rs": "full", "b.rs": "part", "c.rs": "part", "f.rs": "full"})


class Coverage(unittest.TestCase):
    def test_lists(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = os.path.join(tmp, "repo")
            reads = os.path.join(tmp, "reads")
            os.mkdir(root)
            os.mkdir(reads)
            for n in ("a.rs", "b.rs", "c.rs"):
                write(root, n, 2)
            with open(os.path.join(reads, "claude-paths"), "w") as f:
                json.dump({"a.rs": "full", "b.rs": "part"}, f)
            with open(os.path.join(reads, "codex-paths"), "w") as f:
                json.dump({"a.rs": "full"}, f)
            dest = os.path.join(tmp, "coverage.txt")
            with contextlib.redirect_stdout(io.StringIO()):
                le.coverage(root, reads, dest)
            with open(dest) as f:
                text = f.read()
            self.assertTrue(text.startswith("1 of 3 files in the snapshot were read in full by a run that made a report.\n"))
            self.assertIn("Read by no run:\n  c.rs\n", text)
            self.assertIn("Read only in part:\n  b.rs: claude/paths (part)\n", text)
            self.assertIn("Read in full by:\n  a.rs: claude/paths, codex/paths\n", text)


if __name__ == "__main__":
    unittest.main()
