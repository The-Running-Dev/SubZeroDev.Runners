#!/bin/bash
set -euo pipefail
# Job containers may use a different UID, even when the runner has a strict umask.
umask 077
repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
temp=$(mktemp -d)
trap 'rm -rf -- "$temp"' EXIT
runner="$temp/runner installation with spaces"
projection="$temp/sidecar externals"
mkdir -p -- "$runner/externals" "$projection"
# Model only the proposed daemon/job namespaces, without a Docker engine.
sidecar="$temp/sidecar"
job="$temp/job"
mkdir -p -- "$sidecar/runner" "$job"
ln -s -- "$projection" "$sidecar/runner/externals"
ln -s -- "$sidecar/runner/externals" "$job/__e"
hook="$repo/scripts/Sync-LinuxRunnerRuntimes.sh"
fail() { echo "FAIL: $1" >&2; exit 1; }
refuse() { if bash "$hook" "$runner" "$projection" >"$temp/refusal.log" 2>&1; then fail "$1"; fi; }
make_runtimes() {
    local root=$1 version=$2 name
    mkdir -p -- "$root"
    for name in node20 node20_alpine node24 node24_alpine; do
        mkdir -p -- "$root/$name/bin"
        printf '#!/bin/sh\nprintf "%%s\\n" "%s:%s"\n' "$version" "$name" > "$root/$name/bin/node"
        chmod +x -- "$root/$name/bin/node"
        # Arbitrary files under otherwise allowed directories must not be copied.
        printf 'synthetic secret' > "$root/$name/bin/.credentials"
        ln -s -- "$runner/.credentials" "$root/$name/bin/npm"
    done
}
assert_projection() {
    local version=$1 name
    [[ $(find "$projection" -type f | wc -l) == 4 ]] || fail 'unexpected projected files'
    [[ $(stat -c %a -- "$projection") == 755 ]] || fail 'projection root cannot be traversed by a job UID'
    [[ -z $(find "$projection" \( -type l -o -name '.credentials*' -o -name '.runner' -o -name '.env' -o -name '.service' \) -print -quit) ]] || fail 'projection contains registration files or links'
    for name in node20 node20_alpine node24 node24_alpine; do
        [[ $("$projection/$name/bin/node") == "$version:$name" ]] || fail 'runtime missing, stale or not executable'
        [[ $("$job/__e/$name/bin/node") == "$version:$name" ]] || fail 'job namespace cannot execute the projected runtime'
        for directory in "$projection/$name" "$projection/$name/bin"; do
            [[ $(stat -c %a -- "$directory") == 755 ]] || fail 'runtime directory cannot be traversed by a job UID'
        done
    done
    for name in .credentials .credentials_rsaparams .credentials_future .runner .env .service; do
        [[ ! -e "$sidecar/runner/$name" && ! -e "$job/__e/$name" ]] || fail 'registration path exposed in namespace model'
    done
}
# Synthetic canaries only. No installed/live runner directory is examined.
for name in .credentials .credentials_rsaparams .credentials_future .runner .env .service; do
    printf 'synthetic registration canary' > "$runner/$name"
done
make_runtimes "$runner/externals" initial
bash "$hook" "$runner" "$projection"
assert_projection initial
# The real updater uses an absolute sibling link; a relative one must also work.
mv -- "$runner/externals" "$runner/externals.2.338.0"
make_runtimes "$runner/externals.2.339.0" updated
ln -s -- "$runner/externals.2.339.0" "$runner/externals"
mkdir -p -- "$projection/node16/bin"
printf stale > "$projection/node16/bin/node"
printf stale > "$projection/.credentials-stale"
bash "$hook" "$runner" "$projection"
assert_projection updated
rm -- "$runner/externals"
ln -s externals.2.338.0 "$runner/externals"
bash "$hook" "$runner" "$projection"
assert_projection initial
# A versioned directory disappearing after update must not pin the old snapshot.
rm -rf -- "$runner/externals.2.339.0"
# Reject source paths that could copy registration data, including link/hardlink
# substitution at each allowed path component; never follow an interior link.
runtime="$runner/externals.2.338.0/node24"
mv -- "$runtime" "$runner/saved-node24"
ln -s -- "$runner/saved-node24" "$runtime"
refuse 'followed linked runtime directory'
rm -- "$runtime"; mv -- "$runner/saved-node24" "$runtime"
mv -- "$runtime/bin" "$runtime/saved-bin"
ln -s saved-bin "$runtime/bin"
refuse 'followed linked bin directory'
rm -- "$runtime/bin"; mv -- "$runtime/saved-bin" "$runtime/bin"
mv -- "$runtime/bin/node" "$runtime/bin/saved-node"
ln -s -- "$runner/.credentials" "$runtime/bin/node"
refuse 'followed linked Node file'
rm -- "$runtime/bin/node"
ln -- "$runner/.credentials" "$runtime/bin/node"
chmod +x -- "$runtime/bin/node"
refuse 'copied a hardlinked registration file'
rm -- "$runtime/bin/node"; mv -- "$runtime/bin/saved-node" "$runtime/bin/node"
rm -- "$runner/externals"; ln -s "$temp" "$runner/externals"
refuse 'accepted externals outside the runner'
rm -- "$runner/externals"; ln -s "$runner" "$runner/externals"
refuse 'accepted runner root as externals'
rm -- "$runner/externals"; ln -s externals.missing "$runner/externals"
refuse 'accepted broken update link'
mkdir -- "$runner/externals.2.340.0"
rm -- "$runner/externals"; ln -s externals.2.340.0 "$runner/externals"
refuse 'accepted missing runtimes'
# Failed refresh keeps the prior validated projection, and a subsequent good
# refresh recovers. The hook failure blocks job-container initialization upstream.
assert_projection initial
rm -- "$runner/externals"; ln -s externals.2.338.0 "$runner/externals"
bash "$hook" "$runner" "$projection"
assert_projection initial
if bash "$hook" "$runner" "$runner" >"$temp/refusal.log" 2>&1; then fail 'accepted overlapping source/destination'; fi
echo 'PASS: executable Node 20/24 and Alpine projections; fresh, absolute/relative self-update layouts; refresh and stale removal; registration exclusion; symlink/hardlink/invalid-target refusal (synthetic filesystem, no Docker).'
