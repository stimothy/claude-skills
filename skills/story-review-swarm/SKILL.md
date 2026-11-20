---
name: story-review-swarm
description: "Runs one round of a multi-lens review of a change to a novel's story bible, outline or manuscript, with the story-review-* agents the change calls for, in parallel, then acts on the findings. Use when asked for a full, thorough, multi-lens, all-lens or swarm review of story-bible changes, or a review round, or before merging a branch of bible changes when the user asks for a review. Otherwise a plain story-bible review goes to story-review-archivist, and a review with one named lens to that lens's agent."
---

# Story review swarm

A round sends one change to the read-only reviewers it calls for, each with one lens:

| Agent | Lens |
|---|---|
| `story-review-archivist` | continuity |
| `story-review-heckler` | what the world's rules imply |
| `story-review-cartographer` | coverage: missing and unused material |
| `story-review-shrink` | character |
| `story-review-dramaturg` | structure |
| `story-review-oathkeeper` | fit to the author's stated intent |
| `story-review-scholar` | real-world accuracy |
| `story-review-librarian` | the bible as a working document |
| `story-review-turing` | machine-patterned writing |
| `story-review-stylist` | prose |
| `story-review-stranger` | a cold read with no bible |

You are the orchestrator, whether you wrote the change or a subagent did. The point of the design is to keep context out of every window, yours most of all: scripts write the diff, the author's notes and the reports to files, and you pass paths, never content. Do not read `diff.patch`, `context.md` or a single report file, and do not paste a diff, bible entry or chapter into any prompt. Every script takes `--help`.

## Running a round

A round reviews the working tree that is checked out, so the bible must be in a git repository. If it is not, or the user names a branch that is not checked out, say so and ask how to proceed instead of starting a round.

If the change also touches Claude instruction files (`SKILL.md`, agent definitions, `CLAUDE.md`, rules, commands), also send those files by name to `claude-whisperer`; send scripts or code to `code-review-swarm`. A change that touches only those goes there alone, with one exception: in a novel's repository, `CLAUDE.md` or a rule often states the premise, intent or voice. When such a part changed, treat it as story material too and choose lenses for it as for a premise file or style guide.

Run every command from inside the repository under review.

1. **Start the round.**

   ```sh
   ${CLAUDE_SKILL_DIR}/scripts/start-round.sh
   ```

   It snapshots the working tree (commits, staged and unstaged edits, untracked files) without touching the index, writes the diff from the default branch's merge base, and prints `round: <dir>`, the diff's path, the base, a summary, `files:` and `sections:`. It never prints the changed text. Each `files:` line gives the status, the lines added and removed (or `binary`) and the path, such as `M  +1 -1  bible/characters.md`; a rename shows `R<similarity>`, then the old path and the new. `sections:` lists for each changed Markdown file the headings of the sections the change touches (`## Name` for changed lines inside, `+ ## Name` added, `- ## Name` removed). The files list stops at 40 files and `sections:` at 40 files of 10 headings each; for a complete list in order, such as for `--cold` on a large branch, run `git diff --name-status --find-renames <base> <snapshot>` with the two ids from `<round>/meta`, which prints no text either. Use that `<dir>` as `<round>` below. Add `--base <ref>` when the change targets another branch. Exit 3 means there is nothing to review: tell the user and stop.

2. **Record what the author has said about the change**, if anything.

   ```sh
   ${CLAUDE_SKILL_DIR}/scripts/add-context.sh <round> [--file <absolute path>]... --note - <<'EOF'
   <what the author said about the change>
   EOF
   ```

   Pass only what the author said or wrote: why they made the change and what is deliberate, such as "Mara's age is a deliberate retcon; chapter 3 not updated yet". Use `--file` for a plan or note they wrote, with an absolute path, since this script resolves paths from the current directory; `--note` for what they told you. Never add your own summary of the diff: reviewers read the diff themselves and take this file as the author's account. When the author has said nothing, skip this step; do not write a placeholder. The stranger never sees it.

3. **Choose the lenses**, as "Choosing the lenses" describes. If a changed bible or manuscript file shows `binary` or is .docx or a Scrivener project, no reviewer can read it: ask the user for a Markdown or plain-text export and stop, and once the export is in the working tree, start a new round. Go ahead with the readable files alone only if the user says so. Tell the user in one line which lenses and why, and any borderline lens you left out, then go on without waiting; they can ask to add or drop one.

4. **Get the briefs.**

   ```sh
   ${CLAUDE_SKILL_DIR}/scripts/briefs.sh <round> --lenses <list> [--cold <path>]... [--intent <path>]
   ```

   With stranger, pass each reader-facing file with `--cold`, as the repo-relative path from the files list (the new path for a renamed file; leave out deleted ones), in reading order: outline or synopsis first, then chapters in order. With oathkeeper, pass `--intent` for the statement-of-intent file (premise, pitch, logline, about) when the files list or the project's `CLAUDE.md` makes one evident; otherwise leave it out and oathkeeper looks for one itself. It prints one prompt per chosen reviewer under `=== story-review-<lens> ===` headings.

5. **Spawn every chosen lens in one message, in the background.** For each heading, call the Agent tool with `subagent_type: story-review-<lens>` and the text under the heading as the whole prompt, unchanged. Add nothing, above all nothing about the story to the stranger, since anything you tell it is something it can no longer report as unclear. The brief already points the others at the diff and the context file, and tells each one to save its report to a file and reply with one line, because long replies get cut off and re-asking costs more.

   Reviewers can save only if Bash is allowed to run this skill's scripts, since background agents cannot answer a permission prompt. The claude-skills installer prints the exact `permissions.allow` rules to add, one per script. If reviewers report that `save-report.sh` was denied, pass that on to the user.

6. **Wait for all of them to finish.** Do not poll or collect before then. Until all have finished, do not edit files, commit or push: reviewers read the files on disk as the new side of the diff, so a change made now shows them text the diff does not match. Each should reply with one `saved story-review-<lens>: ...` line.
   - If one replied with its report instead of saving it, that reply is the lens's report; leave it where it is. Do not pipe it through `save-report.sh`, which would print it into your context a second time. Collect the others with `--partial`.
   - Some return without reviewing by design; do not respawn them. If oathkeeper found no statement of intent, ask the user for it, or collect with `--partial` and say oathkeeper did not run. If a lens asks for a Markdown or plain-text export of files it needed, pass that on and collect with `--partial`.
   - If one failed, spawn it again with the same brief. If it fails again, collect with `--partial` and tell the user which lens is missing.

7. **Collect the reports in one call.**

   ```sh
   ${CLAUDE_SKILL_DIR}/scripts/collect-reports.sh <round>
   ```

   It prints a table of findings by reviewer and severity, then every report. Exit 3 prints `waiting on: <lenses>`.

## Choosing the lenses

Unlike a code review, a round does not run every lens. Fewer lenses is the point: each reviewer is an expensive model reading much of the bible, so a lens joins only when the change touches what it checks.

Decide from the `files:` and `sections:` lists, with what the user and the project's `CLAUDE.md` say about how the bible is laid out. Do not read the diff to decide. Judge each file's change by its line counts and the sections it touches. If the paths and headings leave unclear what kind of file one is, read only its first lines or its headings, not the change.

A small change, a few lines per file that adds no new event, entry or scene, gets only archivist, by its rule below, plus a lens only when a heading it touches is squarely that lens's subject, such as heckler for a fix under `## Magic`. A full or thorough request does not lift this. Otherwise, choose by these rules, where a chapter counts only when scenes are added, removed or substantially rewritten, not for any edit (stylist excepted):

- **archivist**: every round, because contradictions are what a change most often introduces, unless every changed file is a pure rename (status `R`, `+0 -0`) or a deletion (status `D`): those cannot create one, and librarian and cartographer cover what they break. Lines removed inside a file still call for archivist, since a later passage may rely on what they established.
- **heckler**: world rules, magic, technology, institutions, laws or customs; a character's abilities or resources; outline steps where someone makes a plan.
- **cartographer**: outline steps added, removed or reordered; entries added or removed; chapters. Not for rewording within existing entries.
- **shrink**: a character entry's wants, fears, beliefs, backstory or relationships; outline steps where characters choose; chapters.
- **dramaturg**: the outline, synopsis or chapter plan; an entry that supplies a setup, cause or stake the outline uses, such as a secret, an object or a deadline; chapters.
- **oathkeeper**: the premise, pitch or statement of intent itself; the ending or main plot line; a main character; a subplot added or removed; anything that shifts tone or genre. Not for small factual edits.
- **scholar**: touched sections about real period detail, places, professions, medicine, law or science. Decide by what the sections are about, not by the book's setting; skip invented-world facts with nothing real to check.
- **librarian**: files or entries added, removed, renamed, split or moved; canon, notes or TBD markers; indexes or cross-references. Never for a change to manuscript alone, which it returns without reviewing.
- **turing**: a substantial amount of new prose, such as new entries, sample scenes or chapters, especially if drafted with an AI. Skip for small edits.
- **stylist**: chapter prose revised beyond a few lines, or bible prose meant for the page, such as a sample scene or voice sample; a change to the style guide or voice notes when chapters changed too. Never for reference entries alone.
- **stranger**: the outline, synopsis or chapters, when they changed and live in files of their own; pass those files with `--cold`. Skip when the outline only sits inside a larger bible file, since the stranger must not open bible material.

Only "all lenses" or "every lens" means every lens the material allows: stylist needs prose meant for the page, stranger needs reader-facing files of their own, librarian needs bible files. A full or thorough request keeps the small-change rule and includes borderline lenses for anything over it; say so in the one-line summary, including when the small-change rule applied. If the user names lenses, use exactly those, plus archivist unless they say otherwise or its rule excludes it. Otherwise, when unsure whether a borderline lens applies, leave it out and offer it in the one-line summary.

If no lens applies, such as for a pure rename of chapter files, tell the user and stop without running `briefs.sh`.

## Acting on the findings

Each finding is a `### <title>` with `- Severity:` and `- Confidence:` lines; scholar's `- Applies to this story:` line stands in for confidence.

- Merge duplicates: the same problem from several lenses is one item.
- Verify each finding before passing it on, by reading the passages it quotes rather than the whole diff. Reviewers can be wrong, low-confidence findings most often. A `Noticed in passing, not investigated:` line is a lead to look into, not a finding.
- Check a stranger finding only against the files it was given: dismiss it only if those pages establish the thing before the point it names. What the bible says does not count, because the reader never sees it.
- Scholar works from memory and cannot look facts up, so reading the passage shows only that the claim is there. Present its findings, with its `Worth verifying:` list, as claims to check against a source, and do not call them verified unless you checked one.
- `Already in the bible:` and `Already in the text:` lines are problems the change did not cause, outside its scope: report them separately and briefly.
- Give the user the stranger's `What I took this to be:` in full, to compare with what the author meant. Pass the other named sections on briefly as questions for the author: `Undecided, but relied on:`, `Undecided, but needed:`, `Vague rules the plot leans on:`, `Open questions at the end:`, `Outside what I can judge:`, `Standard in question:` and `Copyedit:`.

The bible is the author's creative work. The reviewers never pick which of two statements is canon and never rewrite prose, and you do not change canon on your own either: which statement stands, whether a rule or plot step changes, how a character is reworked, and whether the statement of intent or the bible should move are the author's decisions.

- Present the verified findings, and scholar's claims marked as unverified, to the user, most severe first, one line each, saying what decision each needs and naming the options the finding implies, without choosing between them.
- Fix only what has a single right answer that the bible itself settles, such as a broken cross-reference, a name misspelled against its own entry or a stale index line, and only when the user asked you to fix or apply findings; a request for a review is not one. Otherwise list those as ready to fix.
- Tell the user, one line per item, what you dismissed and why.

## Re-reviewing the changes

After the author has made changes in response, ask the user whether to review them. Each lens is an expensive review, so the user decides whether it is worth it; never start a round unasked. If they say yes, start the new round from the previous one, so it covers only what changed since:

```sh
${CLAUDE_SKILL_DIR}/scripts/start-round.sh --since <previous round>
${CLAUDE_SKILL_DIR}/scripts/add-context.sh <new round> --file <previous round>/context.md --note - <<'EOF'
<which findings these changes address, and what the author decided about the others>
EOF
```

Leave out `--file` if the previous round had no context. Then continue from step 3 with the new round, choosing the lenses again for the new, smaller change; it usually needs far fewer.
