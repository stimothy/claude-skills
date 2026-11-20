#!/usr/bin/env bash
#
# Install the skills in this repository into Claude Code's user-level skills
# directory, so they are available in every project.

set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/install.sh [options]

Installs every skill in skills/ (each directory with a SKILL.md) into Claude
Code's user-level skills directory (~/.claude/skills, or
$CLAUDE_CONFIG_DIR/skills if that is set).

By default each skill directory is symlinked, so edits in this repository and
"git pull" take effect without reinstalling, and a skill's scripts run from
this clone.

Options:
  --copy        Copy the skill directories instead of symlinking them.
  --force       Replace existing files, symlinks and edited copies that this
                script did not install. A directory it did not install is
                never replaced.
  --uninstall   Remove the skills this script installed. Anything it did not
                install, or that was edited after a --copy install, is left
                alone.
  -h, --help    Show this help.
EOF
}

mode="link"
action="install"
force=0

while [ $# -gt 0 ]; do
  case "$1" in
    --copy) mode="copy" ;;
    --force) force=1 ;;
    --uninstall) action="uninstall" ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      echo >&2
      usage >&2
      exit 2
      ;;
  esac
  shift
done

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
src_dir="$(cd "$script_dir/../skills" && pwd -P)"
dest_dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills"

# The manifest records what this script installed: one line per skill, holding
# its name, "link" or "copy", and the link target or the copy's checksum. It
# lets the script recognise its own installs after the source has changed or
# the repository has moved, without mistaking anyone else's for its own.
manifest="$dest_dir/.claude-skills-manifest"
tab="$(printf '\t')"

skills=()
for dir in "$src_dir"/*/; do
  if [ -f "$dir/SKILL.md" ]; then
    skills+=("${dir%/}")
  fi
done

if [ ${#skills[@]} -eq 0 ]; then
  echo "No skills found in $src_dir" >&2
  exit 1
fi

# True if anything exists at the path, including a dangling symlink.
exists() {
  [ -e "$1" ] || [ -L "$1" ]
}

# A checksum of a directory's file names, contents and executable bits, and
# of any symlinks in it and their targets.
checksum() {
  (
    cd "$1"
    find . \( -type f -o -type l \) | LC_ALL=C sort | while IFS= read -r f; do
      if [ -L "$f" ]; then
        printf '%s l %s\n' "$f" "$(readlink "$f")"
      elif [ -x "$f" ]; then
        printf '%s x %s\n' "$f" "$(cksum <"$f")"
      else
        printf '%s - %s\n' "$f" "$(cksum <"$f")"
      fi
    done
  ) | cksum
}

# True if two directories hold the same files, contents and executable bits.
same_tree() {
  [ -n "$1" ] && [ -d "$1" ] && [ -d "$2" ] && [ "$(checksum "$1")" = "$(checksum "$2")" ]
}

# Prints the manifest entry for a skill as "kind<TAB>value", or nothing.
recorded() {
  if [ -f "$manifest" ]; then
    awk -F'\t' -v name="$1" '$1 == name { print $2 "\t" $3 }' "$manifest"
  fi
}

# Removes a skill from the manifest, and the manifest once it is empty.
forget() {
  if [ -f "$manifest" ]; then
    awk -F'\t' -v name="$1" '$1 != name' "$manifest" >"$manifest.tmp"
    mv "$manifest.tmp" "$manifest"
    if [ ! -s "$manifest" ]; then
      rm -f "$manifest"
    fi
  fi
}

# Records a skill in the manifest with its kind and value.
record() {
  forget "$1"
  printf '%s\t%s\t%s\n' "$1" "$2" "$3" >>"$manifest"
}

# True if the destination is something this script installed and nobody has
# changed since: a link to the source, a link the manifest recorded, a copy
# identical to the source, or a copy whose checksum the manifest recorded.
is_ours() {
  local src="$1" dest="$2" name="$3" entry kind value target
  entry="$(recorded "$name")"
  kind="${entry%%"$tab"*}"
  value="${entry#*"$tab"}"

  if [ -L "$dest" ]; then
    target="$(readlink "$dest")"
    if [ "$target" = "$src" ]; then
      return 0
    fi
    if [ "$kind" = "link" ] && [ "$target" = "$value" ]; then
      return 0
    fi
    return 1
  fi

  if [ -d "$dest" ]; then
    if same_tree "$src" "$dest"; then
      return 0
    fi
    if [ "$kind" = "copy" ] && [ "$(checksum "$dest")" = "$value" ]; then
      return 0
    fi
  fi
  return 1
}

# True if the destination is a copy this script made, edited or not.
is_our_copy() {
  local entry
  entry="$(recorded "$1")"
  [ "${entry%%"$tab"*}" = "copy" ]
}

done_count=0
skipped_count=0

skip() {
  echo "  skipped  $1 ($2)" >&2
  skipped_count=$((skipped_count + 1))
}

install_skill() {
  local src="$1" name dest
  name="$(basename "$src")"
  dest="$dest_dir/$name"

  if [ "$mode" = "link" ] && [ -L "$dest" ] && [ "$(readlink "$dest")" = "$src" ]; then
    record "$name" link "$src"
    echo "  ok       $name (already linked)"
    return 0
  fi
  if [ "$mode" = "copy" ] && [ -d "$dest" ] && [ ! -L "$dest" ] && same_tree "$src" "$dest"; then
    record "$name" copy "$(checksum "$dest")"
    echo "  ok       $name (already up to date)"
    return 0
  fi

  if exists "$dest"; then
    if ! is_ours "$src" "$dest" "$name"; then
      if [ -d "$dest" ] && [ ! -L "$dest" ] && ! is_our_copy "$name"; then
        skip "$name" "a directory this script did not install exists; remove it yourself to install"
        return 0
      fi
      if [ "$force" -eq 0 ]; then
        skip "$name" "something this script did not install, or an edited copy, exists; use --force to replace it"
        return 0
      fi
    fi
    rm -rf "$dest"
  fi

  if [ "$mode" = "link" ]; then
    ln -s "$src" "$dest"
    record "$name" link "$src"
    echo "  linked   $name"
  else
    cp -R "$src" "$dest"
    record "$name" copy "$(checksum "$dest")"
    echo "  copied   $name"
  fi
  done_count=$((done_count + 1))
}

# Prints the names the manifest records whose skill is no longer in this
# repository, because it was removed or renamed.
orphans() {
  local name
  if [ -f "$manifest" ]; then
    awk -F'\t' '{ print $1 }' "$manifest" | while IFS= read -r name; do
      if [ ! -f "$src_dir/$name/SKILL.md" ]; then
        echo "$name"
      fi
    done
  fi
}

# Removes an install of a skill that is no longer in this repository, if it
# is still exactly what this script installed.
remove_orphan() {
  local name="$1" dest="$dest_dir/$1"
  if ! exists "$dest"; then
    forget "$name"
    return 0
  fi
  if is_ours "" "$dest" "$name"; then
    rm -rf "$dest"
    forget "$name"
    echo "  removed  $name (no longer in this repository)"
    if [ "$action" = "uninstall" ]; then
      done_count=$((done_count + 1))
    fi
  else
    skip "$name" "no longer in this repository, but changed since it was installed"
  fi
}

# Prints a permission rule for each script the installed skills can run, by
# its path through the skills directory and in this clone.
allow_rules() {
  local src name script
  for src in "${skills[@]}"; do
    name="$(basename "$src")"
    if [ ! -d "$src/scripts" ]; then
      continue
    fi
    find "$src/scripts" -type f | LC_ALL=C sort | while IFS= read -r script; do
      if [ -x "$script" ]; then
        printf '"Bash(%s *)"\n' "$dest_dir/$name/${script#"$src"/}" "$script"
      fi
    done
  done
}

uninstall_skill() {
  local src="$1" name dest
  name="$(basename "$src")"
  dest="$dest_dir/$name"

  if ! exists "$dest"; then
    forget "$name"
    return 0
  fi
  if is_ours "$src" "$dest" "$name"; then
    rm -rf "$dest"
    forget "$name"
    echo "  removed  $name"
    done_count=$((done_count + 1))
  else
    skip "$name" "not installed by this script, or changed since"
  fi
}

if [ "$action" = "install" ]; then
  mkdir -p "$dest_dir"
  echo "Installing skills into $dest_dir"
  for src in "${skills[@]}"; do
    install_skill "$src"
  done
  while IFS= read -r name; do
    remove_orphan "$name"
  done < <(orphans)
  echo "Installed $done_count, skipped $skipped_count."
  rules="$(allow_rules)"
  if [ -n "$rules" ]; then
    echo
    echo "Skills run their scripts with Bash. To let Claude and its subagents run"
    echo "them without a permission prompt, add these to permissions.allow in"
    echo "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json. A script may be named"
    echo "by its path through the skills directory or in this clone, so each is"
    echo "allowed by both:"
    printf '%s\n' "$rules" | sed -e 's/^/  /' -e '$!s/$/,/'
  fi
else
  echo "Removing skills from $dest_dir"
  if [ -d "$dest_dir" ]; then
    for src in "${skills[@]}"; do
      uninstall_skill "$src"
    done
    while IFS= read -r name; do
      remove_orphan "$name"
    done < <(orphans)
  fi
  echo "Removed $done_count, skipped $skipped_count."
fi

if [ "$skipped_count" -gt 0 ]; then
  exit 1
fi
