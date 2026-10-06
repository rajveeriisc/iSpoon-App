#!/usr/bin/env bash
set -eu

repo_path=${1:-.}
cd "$repo_path"

echo "Repository: $(pwd)"
echo "Top-level components:"
find . -mindepth 1 -maxdepth 1 -type d \
  ! -name '.git' ! -name 'node_modules' ! -name 'build' ! -name '.dart_tool' \
  -print | LC_ALL=C sort | sed -n '1,40p'

echo "Instruction and skill files (bytes, approximate tokens):"
rg --files --hidden \
  -g 'AGENTS.md' -g '**/SKILL.md' \
  -g '!**/.git/**' -g '!**/node_modules/**' -g '!**/build/**' -g '!**/.dart_tool/**' \
  -0 | while IFS= read -r -d '' file; do
    bytes=$(wc -c < "$file" | tr -d ' ')
    approx=$(( (bytes + 3) / 4 ))
    printf '%8s bytes  ~%7s tokens  %s\n' "$bytes" "$approx" "$file"
  done | LC_ALL=C sort -nr | sed -n '1,40p'

echo "Relevant manifests:"
rg --files \
  -g 'package.json' -g 'pubspec.yaml' -g 'pyproject.toml' -g 'Cargo.toml' \
  -g 'Podfile' -g 'CMakeLists.txt' -g 'platformio.ini' \
  -g '!**/node_modules/**' -g '!**/build/**' -g '!**/.dart_tool/**' \
  | LC_ALL=C sort | sed -n '1,60p'

echo "Largest source files; inspect only when relevant:"
rg --files \
  -g '*.dart' -g '*.js' -g '*.jsx' -g '*.ts' -g '*.tsx' -g '*.py' \
  -g '*.swift' -g '*.kt' -g '*.java' -g '*.c' -g '*.h' -g '*.cpp' \
  -g '!**/node_modules/**' -g '!**/build/**' -g '!**/.dart_tool/**' \
  -g '!**/.next/**' -g '!**/Pods/**' -0 \
  | xargs -0 wc -c 2>/dev/null \
  | sed '/ total$/d' \
  | LC_ALL=C sort -nr | sed -n '1,21p'
