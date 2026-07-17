import fs from "node:fs";
import path from "node:path";

const distDir = process.argv[2] ?? "/app/dist";
const files = fs.readdirSync(distDir)
  .filter((name) => /^sqlite-wal-.*\.js$/.test(name))
  .map((name) => path.join(distDir, name));

if (files.length !== 1) {
  throw new Error(`expected exactly one sqlite-wal bundle in ${distDir}, found ${files.length}`);
}

const file = files[0];
const source = fs.readFileSync(file, "utf8");
const marker = 'const NETWORK_FILESYSTEM_TYPES = new Set([\n';
if (!source.includes(marker)) {
  throw new Error(`network filesystem marker not found in ${file}`);
}
if (source.includes(`${marker}\t"virtiofs",\n`)) {
  throw new Error(`virtiofs policy is already present in ${file}`);
}

const patched = source.replace(marker, `${marker}\t"virtiofs",\n`);
fs.writeFileSync(file, patched);

const verified = fs.readFileSync(file, "utf8");
if (!verified.includes(`${marker}\t"virtiofs",\n`)) {
  throw new Error(`failed to verify virtiofs policy in ${file}`);
}
console.log(`patched ${path.basename(file)}: virtiofs uses rollback journal`);
