---
name: code-review-swarm
description: "Runs one round of a full code review with all seven code-review-* agents in parallel, then acts on the findings. Use before creating a pull request or pushing to one, or when asked for a full, thorough, multi-lens, all-lens or swarm review, or a review round. Otherwise a plain code review goes to code-review-sleuth, and a review with one named lens to that lens's agent. Not for changes to Claude instruction files (skills, agents, rules, CLAUDE.md): use claude-whisperer. Not for a novel's story bible or manuscript: use story-review-swarm."
---

# Code review swarm

A round sends one change to seven read-only reviewers, each with one lens:

| Agent | Lens |
|---|---|
| `code-review-sleuth` | correctness |
| `code-review-pedant` | edge cases and failure paths |
| `code-review-advocate` | does it do what was asked |
| `code-review-doubter` | would the tests catch it breaking |
| `code-review-locksmith` | security |
| `code-review-minimalist` | simplicity |
| `code-review-skeptic` | a blind read of the diff alone |

You are the orchestrator, whether you wrote the change or a subagent did. The point of the design is to keep context out of every window, yours most of all: scripts write the diff, the intent and the reports to files, and you pass paths, never content. Do not read `diff.patch`, `context.md` or a single report file, and do not paste a diff, ticket or spec into any prompt. Every script takes `--help`.

## Running a round

A round reviews the working tree that is checked out. If the user names a pull request or branch that is not checked out, say so and ask how to proceed instead of starting a round.

If the change also touches Claude instruction files (`SKILL.md`, agent definitions, `CLAUDE.md`, rules, commands), also send those files by name to `claude-whisperer`. A change that touches only those files goes to `claude-whisperer` alone.

Run every command from inside the repository under review.

1. **Start the round.**

   ```sh
   ${CLAUDE_SKILL_DIR}/scripts/start-round.sh
   ```

   It snapshots the working tree (commits, staged and unstaged edits, untracked files) without touching the index, writes the diff from the default branch's merge base, and prints `round: <dir>`, the base and the changed files. Use that `<dir>` as `<round>` below. Add `--base <ref>` when the change targets another branch. Exit 3 means there is nothing to review: tell the user and stop.

2. **Record what the change is for.**

   ```sh
   ${CLAUDE_SKILL_DIR}/scripts/add-context.sh <round> <source>... --note - <<'EOF'
   <what was asked for that is written nowhere else>
   EOF
   ```

   Name every place the request is written and let the script fetch it: `--issue <number or URL>`, `--pr <number or URL>` when its description states the request, `--file <path>` for a spec, plan or ticket. Use `--note` only for what is written nowhere, such as the user's request in their words or decisions made with them since; leave it out when there is nothing to add. Describe what was asked for, not how you built it: the reviewers judge the code against this, and advocate treats it as the request.

   If you know nothing of what the change is for, ask the user for the request before starting the round. Do not write a placeholder note: advocate refuses to review without a statement of intent.

3. **Get the briefs.**

   ```sh
   ${CLAUDE_SKILL_DIR}/scripts/briefs.sh <round>
   ```

   It prints one prompt per reviewer under `=== code-review-<lens> ===` headings.

4. **Spawn all seven in one message, in the background.** For each heading, call the Agent tool with `subagent_type: code-review-<lens>` and the text under the heading as the whole prompt, unchanged. Add nothing: the skeptic must see only the diff, the others read the context file, and the brief already tells each one to save its report to a file and reply with one line, because long replies get cut off and re-asking costs more.

   Reviewers can save only if Bash is allowed to run this skill's scripts, since background agents cannot answer a permission prompt. The claude-skills installer prints the exact `permissions.allow` rules to add, one per script. If reviewers report that `save-report.sh` was denied, pass that on to the user.

5. **Wait for all seven to finish.** Do not poll or collect before then. Until all seven have finished, do not edit files, commit or push: reviewers read the working tree as the new side of the diff, so a change made now shows them code the diff does not match. Each should reply with one `saved code-review-<lens>: ...` line.
   - If one replied with its report instead of saving it, that reply is the lens's report; leave it where it is. Do not pipe it through `save-report.sh`, which would print it into your context a second time. Collect the others with `--partial`.
   - If advocate asks for the request instead of reviewing, it has not failed: do not respawn it. Ask the user for the request, or collect with `--partial` and say advocate did not run.
   - If one failed, spawn it again with the same brief. If it fails again, collect with `--partial` and tell the user which lens is missing.

6. **Collect the reports in one call.**

   ```sh
   ${CLAUDE_SKILL_DIR}/scripts/collect-reports.sh <round>
   ```

   It prints a table of findings by reviewer and severity, then every report. Exit 3 prints `waiting on: <lenses>`.

## Acting on the findings

Each finding is a `### <title>` with `- Severity:` and `- Confidence:` lines.

- Merge duplicates: the same problem from several lenses is one item.
- Verify each finding before acting on it, by reading the code it names rather than the whole diff. Reviewers can be wrong, low-confidence findings most often. Each skeptic finding has a `- Check:` line naming the one fact that confirms or dismisses it; check that fact. A `Noticed in passing, not investigated:` line is a lead to look into, not a finding.
- Fix every critical and high finding that holds up. Fix a medium or low one when the fix is small and clearly right; otherwise dismiss it with a reason.
- When an advocate finding (a missed or misread requirement, or unrequested work) comes down to a choice about scope, ask the user instead of deciding.
- Make the fixes yourself or hand them to a subagent, whichever suits the change.
- Tell the user, one line per item, what you fixed and what you dismissed and why.

## Re-reviewing the fixes

After acting on the findings, ask the user whether to review the fixes. A round costs seven reviews, so the user decides whether it is worth it; never start one unasked. If they say yes, start the new round from the previous one, so it covers only what changed since:

```sh
${CLAUDE_SKILL_DIR}/scripts/start-round.sh --since <previous round>
${CLAUDE_SKILL_DIR}/scripts/add-context.sh <new round> --file <previous round>/context.md --note - <<'EOF'
<which findings these changes fix, which were dismissed or decided with the user, and why>
EOF
```

Then continue from step 3 with the new round.
