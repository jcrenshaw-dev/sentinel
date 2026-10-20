"""Read the JSON events of lens runs, for lenses.sh.

    lens-events.py claude|codex <events> <dest> <reads> <snapshot>
    lens-events.py coverage <snapshot> <reads-dir> <coverage.txt>

The first form writes the files one run read to <reads>, as JSON mapping each
snapshot path to "full" or "part", and prints three lines: the models that
wrote output, comma separated, "blocked" when a safeguard stopped the reply,
and how many files the run read in full. For Claude it also writes the reply
to <dest>.md.part, and exits 1 when the events hold no result.

A file counts as read only when its contents reached the model. For Claude
that is a Read call whose result was not an error; the lines it returned
decide whether the read was full or in part. Codex reads through shell
commands, so a snapshot path counts when it is an operand of a command that
prints file contents (cat, sed, head and the like), the command exited 0, and
the output was not redirected or piped into something that doesn't print it.
Anything else about a command is unknown and does not count.

The second form writes coverage.txt from every run's reads file.

lenses.sh runs this with python3 -I, so a json.py in the working directory
can't stand in for the standard library's.
"""
import json
import os
import re
import shlex
import sys

# Commands that print a whole file, and ones that print part of it.
WHOLE = {"cat", "nl", "bat", "less", "more"}
SOME = {"grep", "rg", "egrep", "fgrep", "awk", "tail", "cut", "sort", "uniq"}
SEPARATORS = {";", "&&", "||", "&", "(", ")", ";;"}


def snapshot_path(root, path):
    """The path relative to the snapshot, or None when it is not a file in it."""
    full = os.path.realpath(os.path.join(root, path))
    rel = os.path.relpath(full, root)
    return rel if not rel.startswith("..") and os.path.isfile(full) else None


def line_count(root, rel):
    with open(os.path.join(root, rel), "rb") as f:
        data = f.read()
    return data.count(b"\n") + (1 if data and not data.endswith(b"\n") else 0)


def covers(spans, total):
    """Whether the (first, last) line spans cover lines 1 to total."""
    reached = 0
    for first, last in sorted(spans):
        if first > reached + 1:
            return False
        reached = max(reached, last)
    return reached >= total


class Reads:
    def __init__(self, root):
        self.root = root
        self.full = set()
        self.spans = {}  # rel -> [(first, last)], or None when unknown
        self.totals = {}

    def add(self, rel, span=None, total=None):
        """A read of rel: the whole file when span is None, else lines span."""
        if span is None:
            self.full.add(rel)
            return
        if total is not None:
            self.totals[rel] = total
        if span == "unknown":
            self.spans.setdefault(rel, [])
            return
        self.spans.setdefault(rel, []).append(span)

    def result(self):
        out = {rel: "full" for rel in self.full}
        for rel, spans in self.spans.items():
            if rel in out:
                continue
            total = self.totals.get(rel)
            if total is None:
                total = line_count(self.root, rel)
            out[rel] = "full" if spans and covers(spans, total) else "part"
        return out


def claude_events(lines, reads):
    calls, result = {}, None
    for d in lines:
        t = d.get("type")
        if t == "assistant":
            for c in (d.get("message") or {}).get("content") or []:
                if c.get("type") == "tool_use" and c.get("name") == "Read":
                    calls[c.get("id")] = c.get("input") or {}
        elif t == "user":
            meta = d.get("tool_use_result")
            for c in (d.get("message") or {}).get("content") or []:
                if c.get("type") != "tool_result" or c.get("is_error"):
                    continue
                args = calls.pop(c.get("tool_use_id"), None)
                if args is None:
                    continue
                rel = snapshot_path(reads.root, str(args.get("file_path", "")))
                if rel is None:
                    continue
                f = meta.get("file") if isinstance(meta, dict) else None
                if isinstance(f, dict) and f.get("filePath") == args.get("file_path") \
                        and isinstance(f.get("numLines"), int):
                    first = f.get("startLine") or 1
                    reads.add(rel, (first, first + f["numLines"] - 1), f.get("totalLines"))
                elif isinstance(meta, dict) and meta.get("type") not in (None, "text"):
                    reads.add(rel)  # an image, PDF or notebook comes back whole
                elif args.get("offset") or args.get("limit"):
                    reads.add(rel, "unknown")
                else:
                    reads.add(rel)
        elif t == "result":
            result = d
    return result


def words(command):
    """The command's words, unwrapped from the shell Codex runs it in."""
    try:
        parts = shlex.split(command)
        if len(parts) >= 3 and parts[-2] in ("-lc", "-c"):
            command = parts[-1]
        lex = shlex.shlex(command, posix=True, punctuation_chars=True)
        lex.whitespace_split = True
        return list(lex)
    except ValueError:
        return []


def sed_span(args):
    """The lines a sed command prints: None for all, a span, or "unknown"."""
    quiet = any(a == "-n" or re.fullmatch(r"-[a-zA-Z]*n[a-zA-Z]*", a) for a in args)
    if not quiet:
        return None
    for a in args:
        m = re.fullmatch(r"(\d+)(?:,(\d+|\$))?p", a)
        if m:
            first = int(m.group(1))
            last = m.group(2)
            return (first, float("inf") if last == "$" else int(last) if last else first)
    return "unknown"


def head_span(args):
    n = 10
    for i, a in enumerate(args):
        if a in ("-n", "--lines") and i + 1 < len(args) and args[i + 1].isdigit():
            n = int(args[i + 1])
        elif re.fullmatch(r"-n?\d+", a):
            n = int(a.lstrip("-n"))
    return (1, n)


def printed(name, args):
    """What a command prints of its input: None for all, a span, "unknown"
    for part, or False when it prints none of it."""
    if name in WHOLE:
        return None
    if name == "sed":
        return sed_span(args)
    if name == "head":
        return head_span(args)
    if name in SOME:
        return "unknown"
    return False


def combine(upstream, downstream):
    if downstream is False or upstream is False:
        return False
    if downstream is None:
        return upstream
    if upstream is None:
        return downstream
    return "unknown"


def codex_command(command, reads):
    segment, segments = [], []
    for w in words(command) + [";"]:
        if w in SEPARATORS:
            segments.append(segment)
            segment = []
        else:
            segment.append(w)
    for seg in segments:
        pipeline, stage = [], []
        for w in seg + ["|"]:
            if w == "|":
                pipeline.append(stage)
                stage = []
            else:
                stage.append(w)
        # Output redirected anywhere but stderr never reached the model.
        stages = []
        for st in pipeline:
            kept, redirected, i = [], False, 0
            while i < len(st):
                w = st[i]
                if w in (">", ">>", "&>", ">&", ">|"):
                    if not (kept and kept[-1] == "2"):
                        redirected = True
                    elif kept:
                        kept.pop()
                    i += 2
                    continue
                kept.append(w)
                i += 1
            stages.append((kept, redirected))
        if not stages or not stages[0][0]:
            continue
        first, redirected = stages[0]
        span = printed(os.path.basename(first[0]), first[1:])
        for st, redir in stages[1:]:
            if not st:
                span = False
                break
            span = combine(span, printed(os.path.basename(st[0]), st[1:]))
            redirected = redirected or redir
        if span is False or redirected:
            continue
        for w in first[1:]:
            rel = snapshot_path(reads.root, w)
            if rel is None:
                continue
            if span is None:
                reads.add(rel)
            elif span == "unknown":
                reads.add(rel, "unknown")
            else:
                total = line_count(reads.root, rel)
                reads.add(rel, (span[0], min(span[1], max(total, span[0]))), total)


def codex_events(lines, reads):
    for d in lines:
        t = d.get("type")
        if t == "item.completed":
            item = d.get("item") or {}
            if item.get("type") == "command_execution" and item.get("exit_code") == 0:
                codex_command(str(item.get("command", "")), reads)
        elif t in ("error", "turn.failed"):
            print(d.get("message") or (d.get("error") or {}).get("message"), file=sys.stderr)


def events(path):
    with open(path, errors="replace") as f:
        for line in f:
            try:
                d = json.loads(line)
            except ValueError:
                continue
            if isinstance(d, dict):
                yield d


def run(mode, events_path, dest, reads_path, root):
    reads = Reads(os.path.realpath(root))
    if mode == "claude":
        result = claude_events(events(events_path), reads)
    else:
        codex_events(events(events_path), reads)
    read = reads.result()
    with open(reads_path, "w") as f:
        json.dump(read, f)
    models, blocked = [], ""
    if mode == "claude":
        if result is None:
            sys.exit(1)
        with open(dest + ".md.part", "w") as f:
            f.write(result.get("result") or "")
        # Model names are cut to safe characters before they reach the terminal.
        models = [re.sub(r"[^A-Za-z0-9._-]", "", m)
                  for m, u in (result.get("modelUsage") or {}).items() if u.get("outputTokens")]
        if result.get("safety_stops") or result.get("stop_reason") == "refusal":
            blocked = "blocked"
        print("stop_reason: %s, safety_stops: %s" % (result.get("stop_reason"), result.get("safety_stops")),
              file=sys.stderr)
    print(",".join(models))
    print(blocked)
    print(sum(1 for v in read.values() if v == "full"))


def coverage(root, reads_dir, dest):
    full, part = {}, {}
    for name in sorted(os.listdir(reads_dir)):
        label = name.replace("-", "/", 1)
        with open(os.path.join(reads_dir, name)) as f:
            for rel, how in json.load(f).items():
                (full if how == "full" else part).setdefault(rel, []).append(label)
    files = sorted(os.path.relpath(os.path.join(d, f), root) for d, _, fs in os.walk(root) for f in fs)
    unread = [p for p in files if p not in full and p not in part]
    in_part = [p for p in files if p in part and p not in full]

    # Names that are not valid UTF-8 keep their bad bytes as \x escapes, and
    # control characters are stripped, as in run.txt.
    def clean(p):
        p = p.encode("utf-8", "surrogateescape").decode("utf-8", "backslashreplace")
        return re.sub(r"[\x00-\x1f\x7f-\x9f]", "", p)

    def runs(p):
        return ", ".join(full.get(p, []) + [r + " (part)" for r in part.get(p, [])])

    with open(dest, "w") as out:
        out.write("%d of %d files in the snapshot were read in full by a run that made a report.\n\n"
                  % (len(files) - len(unread) - len(in_part), len(files)))
        out.write("Read by no run:\n")
        out.writelines("  %s\n" % clean(p) for p in unread)
        out.write("" if unread else "  none\n")
        out.write("\nRead only in part:\n")
        out.writelines("  %s: %s\n" % (clean(p), runs(p)) for p in in_part)
        out.write("" if in_part else "  none\n")
        out.write("\nRead in full by:\n")
        out.writelines("  %s: %s\n" % (clean(p), runs(p)) for p in files if p in full)
    print("Coverage: %d of %d files read in full, %d only in part, %d by no run; see coverage.txt"
          % (len(files) - len(unread) - len(in_part), len(files), len(in_part), len(unread)))


if __name__ == "__main__":
    if sys.argv[1:2] == ["coverage"] and len(sys.argv) == 5:
        coverage(*sys.argv[2:])
    elif sys.argv[1:2] in (["claude"], ["codex"]) and len(sys.argv) == 6:
        run(*sys.argv[1:])
    else:
        sys.exit(__doc__)
