#!/bin/bash
set -euo pipefail
umask 022
# Runs outside job containers, before their creation. The runner is serial: no
# preceding job uses the projection when this hook publishes the next snapshot.
# Positional paths are for isolated fixtures; production always uses these defaults.
runner=$(realpath -e -- "${1:-/runner}")
projection=$(realpath -e -- "${2:-/runner-runtime}")
fail() { echo "Runner runtime projection refused: $1" >&2; exit 1; }
[[ "$runner" != / && "$projection" != / && "$projection" != "$runner" && "$projection" != "$runner/"* && "$runner" != "$projection/"* ]] || fail 'overlapping source/destination'
externals=$(realpath -e -- "$runner/externals")
# The updater switches externals to an absolute versioned sibling symlink.
[[ "$(dirname -- "$externals")" == "$runner" && "$(basename -- "$externals")" =~ ^externals(\.[0-9]+\.[0-9]+\.[0-9]+)?$ ]] || fail 'unexpected externals target'
[[ -d "$externals" ]] || fail 'externals is not a directory'
stage=$(mktemp -d "$projection/.stage.XXXXXXXX")
trap 'rm -rf -- "$stage"' EXIT
count=0
shopt -s nullglob
for runtime in "$externals"/node*; do
    name=$(basename -- "$runtime")
    [[ "$name" =~ ^node[0-9]+(_alpine)?$ ]] || continue
    # Copy exactly bin/node, never npm, arbitrary siblings, registration files or
    # links into them. Do not recursively copy/dereference the externals tree.
    [[ -d "$runtime" && ! -L "$runtime" && -d "$runtime/bin" && ! -L "$runtime/bin" ]] || fail 'linked or missing runtime directory'
    node="$runtime/bin/node"
    [[ -f "$node" && ! -L "$node" && -x "$node" && "$(stat -c %h -- "$node")" == 1 ]] || fail 'runtime must be a regular, executable, unlinked file'
    mkdir -p -- "$stage/$name/bin"
    cp -- "$node" "$stage/$name/bin/node"
    chmod 755 -- "$stage/$name/bin/node"
    if [[ "$name" != *_alpine ]]; then count=$((count + 1)); fi
done
(( count > 0 )) || fail 'no Node runtimes found'
# Validate/stage everything before publishing; remove stale versions and any old
# projection contents. No live runner state is read, copied or rewritten here.
find "$projection" -mindepth 1 -maxdepth 1 ! -path "$stage" -exec rm -rf -- {} +
chmod 755 -- "$projection"
mv -- "$stage"/* "$projection/"
echo 'Runner Node runtime projection refreshed.'
