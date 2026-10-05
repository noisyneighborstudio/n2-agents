# Fleet find spike

Question: can N2 answer "where was that work I was doing on X?" across machines,
profiles and labs, from a loose query such as `appcast n2 agents`? One
observation, on 2026-10-05, on one Mac (mac-mini) with three profiles' Claude
and Codex transcripts. Evidence: [fleet-find-spike.json](fleet-find-spike.json).
The spike code was discarded.

## Findings

- The cached metadata is not enough. `agents sessions` caches the working
  folder, branch, title and first prompt, and the Sessions window filters on
  those. For "appcast", which had been worked on in the last two days, it matched
  0 of 609 sessions.
- Scanning raw transcripts is too slow. The foreground transcripts total 2.1 GB
  (largest file: a 273 MB Codex rollout). One `grep -lisF` for one term took
  22 s of CPU; with one-typo variants, about 140 s per query. On Claude alone
  (416 MB, warm cache) it took 0.55 s, so Codex dominates.
- The conversation is small. Only the user prompts and the assistant text, with
  tool output and injected context (system reminders, AGENTS.md, environment
  blocks) left out, came to 6.8M characters. An SQLite FTS5 table with the
  `trigram` tokenizer (`/usr/bin/python3`, SQLite 3.54) built in 3.8 s with a
  warm cache. The file was 26 MB; each query took 0.02 s.
- Splitting the query across fields works. Each term must match somewhere, but
  each term can match a different field: in `appcast n2 agents`, "n2 agents"
  matches the folder and "appcast" the conversation. Words split on anything
  that isn't a letter or digit, and adjacent pairs also count joined, so
  `n2agents` meets `n2-agents`.
- Typos work. Terms of five or more letters also match with one letter
  deleted; this covers a dropped, doubled or swapped letter. Terms of three or
  more also match as a prefix. `apcast n2agents` returned the same four
  sessions as `appcast n2 agents`, and `sparkel release n2` found the release
  work.
- Ranking: title 5, folder or branch 4, the user's own prompts 3, the agent's
  replies 1, with recency breaking ties. All three of the known recent
  sessions ranked in the top four. Each had a pushed branch and a folder that
  still exists.
- The index trades recall for precision: 4 hits against grep's 24. The
  difference is mentions inside tool output.
- `git remote get-url` hung on a folder under `~/Documents` (TCC-protected).
  Every git call made during a search needs a timeout.
- The searching session finds itself. Exclude the caller's own session.

## Decisions

- The index is per Mac, at `~/.n2-agents/.find.v1.db` (mode 0600), beside
  `.sessions.v1.tsv`. It never syncs: sync is an allowlist over profile slots
  and doesn't include files at the root. Like the sessions cache, it re-reads
  only transcripts whose path or mtime changed.
- When the index finds nothing, the fast search scans the raw transcripts,
  tool output included. Sessions whose folder, branch or title already matched
  some terms are scanned first. The output says it is scanning, so the extra
  time is visible.
- Other machines answer through a signed `sessions-find` verb, which searches
  that machine's own index. A reply holds rows and a short snippet, never
  transcript bytes. An unreachable peer is reported in a line, not as an
  error.
- `--deep` starts an agent on each reachable machine through fleet tasks. Each
  uses that machine's slot with measured headroom; a machine without one says
  so. Each agent is read-only. It tries other wordings, reads its own
  transcripts, git state, loops and tasks, and returns the same rows as the
  fast search, each with a quoted excerpt as evidence. Its answer passes the
  secret scanner before it leaves the machine. The origin merges the answers.
- Resume uses the session's own profile, never `--best`.

## Slices

1. `find-local`: the index and fuzzy `agents find` on one Mac (queued in
   `docs/slices.md`).
2. `find-fleet`: `sessions-find` across approved peers, each row labeled with
   its machine.
3. `find-deep`: `--deep` with one read-only agent per machine. Proof uses a
   fake agent: a command outside the read-only set is refused; a planted secret
   arrives redacted; a machine with only unmeasured slots reports no headroom;
   the run stops at its budget.
4. `find-sources`: loops and fleet tasks, then Grok
   (`sessions/<cwd>/<uuid>/summary.json`) and opencode (the `session` table of
   `opencode.db`) as sources.
5. `find-ui`: fleet search in the tray, with a loading state for each machine
   (the AGENTS.md UI rule).

Not yet located: where `cursor-agent` and Muse keep chat history. Spike before
giving either a reader.
