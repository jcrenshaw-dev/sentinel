# Threat model: <tool name>

Copy this file to the root of the repo under audit as `THREAT-MODEL.md` and fill in every section. The pull request review, the lenses and the check of their findings read it first and treat it as the definition of what matters, and `/snt:onboard` builds the security-guidance rules from it, so a section left vague makes all of them vague. Answer with paths, commands, users and data types, not adjectives. If a section does not apply, say so and say why.

Version or commit this describes:
Last reviewed:

## What this tool reads

- Which files and directories does it read, by exact path or path pattern (transcripts, config, other tools' state)?
- Which environment variables, CLI arguments, sockets, network endpoints or stdin streams does it read?
- Does it read anything owned by another user, another project, or another tool?

## What it writes

- Which files and directories does it create or modify, by exact path, and with what file modes?
- Does it write anywhere outside its own data directory (Claude Code settings, shell rc files, systemd units, temp dirs)?
- What does it print to stdout and stderr, and who reads that output (a terminal, Claude Code's context, a log collector)?

## What it executes

- Which external programs does it run, and are they found through PATH or by absolute path?
- Which hooks does it install into Claude Code or anything else, and what triggers each one?
- Does it ever build a command, SQL statement, FTS query or prompt out of data it read?

## What it must never touch

- Which files, directories, keys or services must it never read, write or delete?
- Which data must never leave the machine, or never leave its own data directory?
- Which actions must it never take on the user's behalf (commits, pushes, network calls, permission approvals)?

## Who runs it and with what privileges

- Which user runs it: the interactive user, a dedicated service user, root, a systemd unit?
- Is it started by hand, by Claude Code (hook or MCP server), by a timer, or at login?
- What could that user already do without this tool, so a finding can be judged as a real escalation or not?

## What the worst outcome looks like

- What is the single worst thing an attacker or a bug could make this tool do?
- Which data loss, data leak or unwanted action would hurt the most, and who would it hurt?
- What would the user not notice happening?

## Trust boundaries (where untrusted data enters)

- List every place outside data enters: transcript content (which carries web pages, files and tool output Claude saw), config, CLI args, env vars, MCP tool inputs, network responses, files from other projects.
- At each boundary, what validation, size limit or escaping happens before the data is used?
- Which data does the tool treat as trusted only because it came from its own earlier output?

## Secrets that may pass through

- Which secrets can appear in the data this tool handles (API keys pasted into chats, tokens in env vars, credentials in tool output)?
- Where can those secrets end up: storage, indexes, logs, search results, injected context, error messages?
- Which secrets does the tool itself hold, where are they stored, and with what file modes?
