# claude-skills

A collection of [Claude Code skills](https://docs.claude.com/en/docs/claude-code/skills), with a script that installs them for your user account so they are available in every project.

A skill here can come with scripts. They do the repetitive, mechanical parts of a task, so Claude spends no tokens reasoning them out each time and keeps bulky material such as diffs out of its context.

## Install

```sh
git clone https://github.com/stimothy/claude-skills.git
cd claude-skills
scripts/install.sh
```

This symlinks every skill directory in `skills/` into `~/.claude/skills/` (or `$CLAUDE_CONFIG_DIR/skills/` if you have set that variable). Because the whole directory is linked, a skill's scripts run from this clone whichever project you are working in, and `git pull` updates them without a reinstall. Run the script again after a pull that adds new skills.

Skills run their scripts with Bash. So that Claude and its subagents can run them without a permission prompt each time, add these to `permissions.allow` in `~/.claude/settings.json` (the installer prints the exact lines). A script may be named by its path through `~/.claude/skills` or in the clone, so allow both:

```json
"Bash(/Users/you/.claude/skills/*/scripts/*)",
"Bash(/Users/you/path/to/claude-skills/skills/*/scripts/*)"
```

This matters most for `code-review-swarm`: its reviewers run in the background and save their reports with a script, and they cannot answer a permission prompt.

### Options

| Option | Effect |
|---|---|
| `--copy` | Copy the skill directories instead of symlinking them. Use this if you plan to delete the clone. |
| `--force` | Replace an existing file, symlink or edited copy that has the same name but was not installed by this script. A directory the script did not install is never replaced: remove it yourself. |
| `--uninstall` | Remove the skills this script installed. Anything it did not install is left alone. |
| `--help` | Show usage. |

The script needs bash and works on macOS and Linux. It is safe to run more than once.

### What the script will and will not touch

The script only replaces or removes what it installed. It keeps a small manifest, `.claude-skills-manifest`, in the skills directory to remember them: for each skill, either the link it made or a checksum of the copy it made.

- A copy is still recognised after the skill changes upstream, so running `--copy` again updates it.
- A copy you have edited is treated as yours. It is skipped, not overwritten or removed, unless you pass `--force`.
- A symlink that points somewhere else is left alone, even when its target is missing.
- If you move the clone, run the script again from the new location and it repairs its own links.

The script exits with status 1 when it skipped anything, so you can tell a partial install from a complete one.

## Skills

| Skill | What it does |
|---|---|
| [`code-review-swarm`](skills/code-review-swarm/SKILL.md) | Runs a review round on a code change with all seven `code-review-*` agents from [claude-agents](https://github.com/stimothy/claude-agents) in parallel, then acts on what they find. Scripts write the diff and the change's intent to files, the reviewers save their reports to files, and one script collects them, so neither Claude nor the reviewers carry more context than they need. Meant for the moment before creating or pushing to a pull request; after fixes, Claude asks whether to re-review only what changed. Needs the claude-agents agents installed. |

## Development

Scripts are written test first, in bash, and must work with the bash 3.2 that macOS ships. Run everything CI runs with:

```sh
shellcheck -x scripts/*.sh skills/*/scripts/*.sh tests/*.sh
shfmt -d scripts skills tests
scripts/lint-skills.sh
tests/run.sh
```

- `tests/run.sh` runs every `tests/test_*.sh` file and then measures line coverage of every script in `scripts/` and `skills/*/scripts/`. It fails if any script is below 80%. Set `COVERAGE_MIN` to change the threshold, and `TEST_FILTER` to run only the tests whose names match.
- Tests need only bash, git and the standard Unix tools. Each runs against throwaway repositories and config directories, so your real `~/.claude` is never touched.
- `scripts/lint-skills.sh` checks that each skill's `SKILL.md` has frontmatter with a matching `name` and a `description`, that every `${CLAUDE_SKILL_DIR}/scripts/...` it mentions exists, and that its scripts are executable.
- `shfmt` takes its settings from `.editorconfig`.

The same checks run on Linux and macOS for every pull request.

## License

[MIT](LICENSE)
