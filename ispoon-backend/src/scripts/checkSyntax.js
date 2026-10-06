import { readdirSync } from "node:fs";
import { spawnSync } from "node:child_process";
import path from "node:path";

const roots = ["src", "test"];

const collectJavaScript = (directory) => readdirSync(directory, { withFileTypes: true })
  .flatMap((entry) => {
    const entryPath = path.join(directory, entry.name);
    return entry.isDirectory()
      ? collectJavaScript(entryPath)
      : entry.isFile() && entry.name.endsWith(".js")
        ? [entryPath]
        : [];
  });

const files = roots.flatMap((root) => collectJavaScript(root));
const failures = [];

for (const file of files) {
  const result = spawnSync(process.execPath, ["--check", file], { encoding: "utf8" });
  if (result.status !== 0) failures.push({ file, output: result.stderr || result.stdout });
}

if (failures.length > 0) {
  for (const failure of failures) {
    console.error(`Syntax check failed: ${failure.file}\n${failure.output}`);
  }
  process.exitCode = 1;
} else {
  console.log(`Syntax checks passed: ${files.length} files`);
}
