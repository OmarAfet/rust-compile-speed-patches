#!/usr/bin/env bash
# Shows Cargo with -Zpublic-api-hash skipping a library whose dependency changed in a way it cannot see.
# Workspace: a (lib) <- b (lib) <- app (bin, uses a and b). Each step edits a, rebuilds, and prints
# which crates rustc compiled. At the end, a clean build must give the same program output.
# Usage: demo/skip-demo.sh <patched cargo> <patched rustc>
set -euo pipefail
[ $# -eq 2 ] || { echo "usage: $0 <patched cargo> <patched rustc>" >&2; exit 2; }
abs() { echo "$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"; }
CARGO="$(abs "$1")"; export RUSTC; RUSTC="$(abs "$2")"
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT; cd "$W"
echo "# $("$CARGO" -V); $("$RUSTC" -V)"
echo "# every build: RUSTC=$RUSTC $CARGO -Zpublic-api-hash build -v   (in a temporary folder)"

cat > Cargo.toml <<'EOF'
[workspace]
members = ["a", "b", "app"]
resolver = "3"
EOF
mkdir -p a/src b/src app/src
printf '[package]\nname = "a"\nversion = "0.1.0"\nedition = "2024"\n' > a/Cargo.toml
printf '[package]\nname = "b"\nversion = "0.1.0"\nedition = "2024"\n[dependencies]\na = { path = "../a" }\n' > b/Cargo.toml
printf '[package]\nname = "app"\nversion = "0.1.0"\nedition = "2024"\n[dependencies]\na = { path = "../a" }\nb = { path = "../b" }\n' > app/Cargo.toml
cat > a/src/lib.rs <<'EOF'
pub mod tagged;
pub struct Point { pub x: u32, pub y: u32 }
pub fn work(n: u32) -> u32 { (0..n).map(|i| i * 3).sum() }
pub fn norm1(p: &Point) -> u32 { p.x + p.y }
EOF
cat > a/src/tagged.rs <<'EOF'
#[derive(Clone, Debug, PartialEq)]
pub struct Tagged(pub u32);
EOF
echo 'pub fn total(n: u32) -> u64 { a::work(n) as u64 + a::norm1(&a::Point { x: n, y: 1 }) as u64 }' > b/src/lib.rs
echo 'fn main() { println!("{} {:?}", b::total(10), a::tagged::Tagged(a::work(3)).clone()); }' > app/src/main.rs

build() { # → names of the crates rustc compiled
  "$CARGO" -Zpublic-api-hash build -v > build.log 2>&1 || { cat build.log; exit 1; }
  grep -oE 'Running `[^ ]*rustc --crate-name [a-z_]+' build.log | sed 's/.*--crate-name //' | sort | tr '\n' ' '; }
step() { # description, shell command that edits a
  sh -c "$2"; printf '%-48s rustc compiled: %s\n' "$1" "$(build)"; }

build > /dev/null
step "1. add a private fn at the end of a"             'printf "\n#[allow(dead_code)]\nfn helper() -> u32 { 7 }\n" >> a/src/lib.rs'
step "2. change the body of a pub fn in a"             'sed -i.bak "s/i \* 3/i * 4/" a/src/lib.rs'
step "3. add a line at the top of a (moves items)"     'printf "// note\n" | cat - a/src/lib.rs > t && mv t a/src/lib.rs'
step "4. add a line above a #[derive] type in a"       'printf "// note\n" | cat - a/src/tagged.rs > t && mv t a/src/tagged.rs'
step "5. add a pub fn to a"                            'printf "pub fn extra() {}\n" >> a/src/lib.rs'
echo "Expected: b is skipped in steps 1-3 (nothing b can see changed). b is compiled in step 4 (the derived methods moved, and dependents copy their line numbers into their own debug info; the hash covers all of a, not only what b uses) and in step 5 (b can see the new fn). app is a binary, so it is always compiled and linked again."
out1=$(./target/debug/app); rm -rf target; build > /dev/null; out2=$(./target/debug/app)
echo "program output after the steps: $out1; after a clean build: $out2 ($([ "$out1" = "$out2" ] && echo same || echo DIFFERENT))"
