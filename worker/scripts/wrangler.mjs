#!/usr/bin/env node
// Runs wrangler with this checkout's config: wrangler.jsonc, with wrangler.local.jsonc
// (git-ignored: your route, D1 database id, APNs team and topic) laid over it when it exists.
// The merged file is written to wrangler.resolved.jsonc (git-ignored) and passed as --config.
//   node scripts/wrangler.mjs deploy            node scripts/wrangler.mjs --print
import { spawnSync } from "node:child_process";
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const PLACEHOLDER = "00000000-0000-0000-0000-000000000000";

/** JSON with comments and trailing commas, as wrangler reads it. */
export function parseJSONC(text) {
  let out = "", inString = false;
  for (let i = 0; i < text.length; i++) {
    const c = text[i], next = text[i + 1];
    if (inString) {
      out += c;
      if (c === "\\") out += text[++i];
      else if (c === '"') inString = false;
    } else if (c === '"') { inString = true; out += c; }
    else if (c === "/" && next === "/") { while (i < text.length && text[i] !== "\n") i++; out += "\n"; }
    else if (c === "/" && next === "*") { i += 2; while (i < text.length && !(text[i] === "*" && text[i + 1] === "/")) i++; i++; }
    else out += c;
  }
  return JSON.parse(out.replace(/,(\s*[}\]])/g, "$1"));
}

/** The tracked config with the local one over it: each key replaced, "vars" merged. */
export function resolve(base, local) {
  if (!local) return base;
  const merged = { ...base, ...local };
  if (base.vars || local.vars) merged.vars = { ...base.vars, ...local.vars };
  return merged;
}

/** What stops a real deploy: placeholders left from wrangler.jsonc or wrangler.local.example.jsonc. */
export function deployProblems(config) {
  const problems = [];
  const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
  for (const d of config.d1_databases ?? []) {
    if (!d.database_id || d.database_id === PLACEHOLDER || !uuid.test(d.database_id)) {
      problems.push("the D1 database_id is a placeholder: run `wrangler d1 create beeline-alerts` and put its id in wrangler.local.jsonc");
    }
  }
  const vars = config.vars ?? {};
  if (vars.APNS_TEAM_ID === "ABCDE12345") problems.push("APNS_TEAM_ID is the example's: put your Apple team ID");
  if (vars.APNS_TOPIC?.startsWith("com.example.")) problems.push("APNS_TOPIC is the example's: put your app's bundle ID");
  const example = /(^|\.)example\.(com|org|net)$/i;
  const routes = [...(config.routes ?? []), ...(config.route ? [config.route] : [])];
  for (const r of routes) {
    // "alerts.example.com/*" or { pattern, zone_name }: the host is what's before any path.
    const host = String(typeof r === "string" ? r : r.pattern ?? "").replace(/^https?:\/\//, "").split("/")[0].replace(/^\*\.?/, "");
    const zone = typeof r === "string" ? "" : String(r.zone_name ?? "");
    if (example.test(host) || (zone && example.test(zone))) problems.push("a route is the example's domain");
  }
  return problems;
}

const read = (name) => (existsSync(join(root, name)) ? parseJSONC(readFileSync(join(root, name), "utf8")) : undefined);

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const local = read("wrangler.local.jsonc");
  const config = resolve(read("wrangler.jsonc"), local);
  const args = process.argv.slice(2);
  if (args[0] === "--print") {
    console.log(JSON.stringify(config, null, 2));
    process.exit(0);
  }
  console.error(local ? "wrangler: wrangler.jsonc + wrangler.local.jsonc" : "wrangler: wrangler.jsonc only (no wrangler.local.jsonc)");
  // Anything that puts code or settings on Cloudflare: deploy, versions upload or deploy, D1 --remote.
  const uploads = args[0] === "deploy" || (args[0] === "versions" && ["upload", "deploy"].includes(args[1]));
  const remote = (uploads && !args.includes("--dry-run")) || args.includes("--remote");
  const problems = remote ? deployProblems(config) : [];
  if (problems.length) {
    console.error(`Refusing: ${problems.join("; ")}.`);
    process.exit(1);
  }
  const resolved = join(root, "wrangler.resolved.jsonc");
  writeFileSync(resolved, `// Written by scripts/wrangler.mjs from wrangler.jsonc${local ? " and wrangler.local.jsonc" : ""}. Don't edit.\n${JSON.stringify(config, null, 2)}\n`);
  const bin = join(root, "node_modules", ".bin", process.platform === "win32" ? "wrangler.cmd" : "wrangler");
  const run = spawnSync(existsSync(bin) ? bin : "wrangler", [...args, "--config", resolved], { stdio: "inherit", cwd: root, shell: process.platform === "win32" });
  if (run.error) console.error(String(run.error));
  process.exit(run.status ?? 1);
}
