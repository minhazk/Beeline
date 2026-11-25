#!/usr/bin/env node
// Runs wrangler with this checkout's config: wrangler.jsonc, with wrangler.local.jsonc
// (git-ignored: your route, D1 database id, APNs team and topic) laid over it when it exists.
// The merged file is written to wrangler.resolved.jsonc (git-ignored) and passed as --config.
//   node scripts/wrangler.mjs deploy            node scripts/wrangler.mjs --print
import { spawnSync } from "node:child_process";
import { chmodSync, existsSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const PLACEHOLDER = "00000000-0000-0000-0000-000000000000";
/** What belongs in `wrangler secret put` (or .dev.vars locally), never in a config file. */
export const SECRETS = ["APP_TOKEN", "APNS_KEY", "APNS_KEY_ID", "TFL_APP_KEY"];

/** The config as it may be shown or written to disk: a secret put in "vars" by mistake is hidden. */
export function redacted(config) {
  const hide = (vars) => vars && Object.fromEntries(Object.entries(vars).map(([name, value]) => [name, SECRETS.includes(name) ? "<a secret: remove it from vars>" : value]));
  const shown = { ...config };
  if (config.vars) shown.vars = hide(config.vars);
  // A named environment's vars too (a deploy with one is refused, but this prints first).
  if (config.env && typeof config.env === "object") {
    shown.env = Object.fromEntries(Object.entries(config.env).map(([name, env]) => [name, env && typeof env === "object" && env.vars ? { ...env, vars: hide(env.vars) } : env]));
  }
  return shown;
}

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
  // A var is plain text in the dashboard, in `--print` and in wrangler.resolved.jsonc.
  for (const name of SECRETS) if (name in vars) problems.push(`${name} is a secret, not a var: take it out of the config and run \`pnpm run wrangler secret put ${name}\``);
  // The local file replaces whole keys, so one that sets "observability" or "preview_urls" for
  // another reason can undo what the tracked config turned off.
  const logs = config.observability?.logs;
  if ((config.observability?.enabled || logs?.enabled) && logs?.invocation_logs !== false) {
    problems.push('request logs would record each phone\'s push token (it is in the path): keep "invocation_logs": false under observability.logs');
  }
  // Traces, Logpush and tail Workers record the same addresses invocation logs do, and the
  // addresses asked of Apple and TfL besides.
  if (config.observability?.traces?.enabled) problems.push('"observability.traces" would record each phone\'s push token (it is in the path): keep traces off');
  if (config.logpush) problems.push('"logpush" would export request addresses, which carry each phone\'s push token');
  if (config.tail_consumers?.length || config.streaming_tail_consumers?.length) problems.push("tail consumers would be sent request addresses, which carry each phone's push token");
  // Each named environment has its own vars, routes and bindings, which nothing here reads.
  if (config.env) problems.push('named environments ("env") aren\'t checked by this wrapper: keep one deployment per config');
  if (config.preview_urls !== false) problems.push('"preview_urls" must stay false: each preview address runs with the live secrets and database');
  if ("TFL_BASE" in vars) problems.push("TFL_BASE is for local runs with recorded answers: it sends every TfL request elsewhere");
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
    console.log(JSON.stringify(redacted(config), null, 2));
    process.exit(0);
  }
  console.error(local ? "wrangler: wrangler.jsonc + wrangler.local.jsonc" : "wrangler: wrangler.jsonc only (no wrangler.local.jsonc)");
  // Anything that puts code, settings or secrets on Cloudflare: deploy, versions upload or deploy,
  // secret put/bulk/delete, D1 --remote.
  // Any of these words anywhere among the arguments: wrangler decides what the command is, and
  // guessing the same way it does (a flag first, a flag's value) is how a check gets skipped.
  // Checking a command that turns out to be local costs nothing.
  const uploads = args.some((arg) => ["deploy", "versions", "secret", "publish", "rollback", "triggers"].includes(arg));
  const remote = (uploads && !args.includes("--dry-run")) || args.includes("--remote");
  const problems = remote ? deployProblems(config) : [];
  // Values given on the command line never pass through the checks above.
  if (remote && args.some((arg) => /^(--var|--env|-e|--define|--alias)(=|$)/.test(arg))) {
    problems.push("--var, --env, --define and --alias aren't taken for a deploy: put settings in wrangler.local.jsonc and secrets in `wrangler secret put`");
  }
  if (problems.length) {
    console.error(`Refusing: ${problems.join("; ")}.`);
    process.exit(1);
  }
  const resolved = join(root, "wrangler.resolved.jsonc");
  // Your own deployment's ids: readable by you alone.
  writeFileSync(resolved, "", { mode: 0o600 });
  chmodSync(resolved, 0o600);
  writeFileSync(resolved, `// Written by scripts/wrangler.mjs from wrangler.jsonc${local ? " and wrangler.local.jsonc" : ""}. Don't edit.\n${JSON.stringify(config, null, 2)}\n`);
  // Only the wrangler the lockfile pins: never whichever one happens to be on PATH.
  const bin = join(root, "node_modules", ".bin", process.platform === "win32" ? "wrangler.cmd" : "wrangler");
  if (!existsSync(bin)) {
    console.error("wrangler isn't installed here: run `pnpm install --frozen-lockfile` in worker/ first.");
    process.exit(1);
  }
  const run = spawnSync(bin, [...args, "--config", resolved], { stdio: "inherit", cwd: root, shell: process.platform === "win32" });
  if (run.error) console.error(String(run.error));
  process.exit(run.status ?? 1);
}
