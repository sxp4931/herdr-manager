import { execFileSync } from "node:child_process";
import { existsSync, readFileSync, readdirSync, statSync } from "node:fs";
import path from "node:path";

const expectedDirect = {
  typescript: "5.9.3",
  react: "19.2.3",
  "react-dom": "19.2.3",
  vite: "8.3.0",
  "@vitejs/plugin-react": "6.1.1",
  zod: "4.4.3",
  esbuild: "0.28.2",
  vitest: "4.1.11",
  "@playwright/test": "1.63.0",
  eslint: "9.39.5",
  "@eslint/js": "9.39.5",
  "typescript-eslint": "8.68.0",
  "@types/node": "22.16.5",
  "@types/react": "19.2.18",
  "@types/react-dom": "19.2.5",
};

const failures = [];

function fail(message) {
  failures.push(message);
}

function readJson(file) {
  return JSON.parse(readFileSync(file, "utf8"));
}

function walkPackageFiles(dir, out = []) {
  for (const entry of readdirSync(dir)) {
    if (entry === "node_modules" || entry === "dist" || entry === ".venv" || entry === ".git") continue;
    const full = path.join(dir, entry);
    const info = statSync(full);
    if (info.isDirectory()) walkPackageFiles(full, out);
    else if (entry === "package.json") out.push(full);
  }
  return out;
}


const gitignore = existsSync(".gitignore") ? readFileSync(".gitignore", "utf8") : "";
for (const needle of [".venv/", "node_modules/", ".local/", ".artifacts/", "dashboard.local.json", ".env*"]) {
  if (!gitignore.includes(needle)) fail(`gitignore missing ${needle}`);
}
if (!gitignore.includes("!.env.example")) fail("gitignore missing .env.example exception");

const manifests = walkPackageFiles(".");
for (const file of manifests) {
  const json = readJson(file);
  for (const [name, version] of Object.entries(json.overrides ?? {})) {
    if (typeof version !== "string" || /[\^~*]/.test(version) || version === "latest") {
      fail(`${file} override ${name} is not an exact pin (${String(version)})`);
    }
  }
  const groups = ["dependencies", "devDependencies", "optionalDependencies", "peerDependencies"];
  for (const group of groups) {
    const deps = json[group] ?? {};
    for (const [name, version] of Object.entries(deps)) {
      if (typeof version !== "string" || /[\^~*]/.test(version) || version === "latest" || version.startsWith("workspace:")) {
        fail(`${file} ${group}.${name} is not an exact pin (${version})`);
      }
      if (Object.hasOwn(expectedDirect, name) && version !== expectedDirect[name]) {
        fail(`${file} pins ${name}@${version}, expected ${expectedDirect[name]}`);
      }
      if ((name === "@herdr/contracts" || name === "@herdr/server" || name === "@herdr/web") && version !== "0.1.0") {
        fail(`${file} internal dependency ${name}@${version}`);
      }
    }
  }
}

const root = readJson("package.json");
if (root.packageManager !== "npm@10.9.3") fail("packageManager must be npm@10.9.3");
if (root.engines?.node !== "22.23.2") fail("engines.node must be 22.23.2");
if (root.engines?.npm !== "10.9.3") fail("engines.npm must be 10.9.3");

const examplePath = "config/dashboard.example.json";
if (!existsSync(examplePath)) fail("missing config/dashboard.example.json");
else {
  const example = readJson(examplePath);
  if (example.host !== "127.0.0.1") fail("example host must be 127.0.0.1");
  if (example.mode !== "passive") fail("example mode must be passive");
  if (example.quotaProbesEnabled !== false) fail("example quota probes must be disabled");
  const poll = example.poll ?? {};
  if (poll.sessionsSeconds < 10 || poll.gitSeconds < 30 || poll.quotaSeconds < 300) {
    fail("example poll intervals are below the minimums");
  }
}

const runnerPath = "apps/server/src/adapters/command-runner.ts";
if (!existsSync(runnerPath)) fail("missing command runner");
else {
  const runner = readFileSync(runnerPath, "utf8");
  if (!runner.includes("shell: false")) fail("command runner must set shell: false");
  if (/shell\s*:\s*true/.test(runner)) fail("command runner enables a shell");
  if (!runner.includes("GIT_OPTIONAL_LOCKS")) fail("command runner must force GIT_OPTIONAL_LOCKS=0");
  if (!runner.includes("GIT_TERMINAL_PROMPT")) fail("command runner must force GIT_TERMINAL_PROMPT=0");
  for (const denied of ["send-keys", "capture-pane", "kill-session"]) {
    if (!runner.includes(denied)) fail(`command runner does not name denied tmux command ${denied}`);
  }
}
for (const name of Object.keys(expectedDirect)) {
  const present = manifests.some((file) => {
    const json = readJson(file);
    return ["dependencies", "devDependencies"].some((group) => json[group]?.[name] === expectedDirect[name]);
  });
  if (!present) fail(`missing direct pin ${name}@${expectedDirect[name]}`);
}

const forbiddenRoute = /\.(post|put|patch|delete)\s*\(/i;
const sourceRoots = ["apps/server/src", "apps/web/src", "packages/contracts/src"];
for (const rootDir of sourceRoots) {
  if (!existsSync(rootDir)) continue;
  const files = [];
  const stack = [rootDir];
  while (stack.length) {
    const current = stack.pop();
    for (const entry of readdirSync(current)) {
      const full = path.join(current, entry);
      if (statSync(full).isDirectory()) stack.push(full);
      else if (/\.(ts|tsx|js|mjs)$/.test(entry)) files.push(full);
    }
  }
  for (const file of files) {
    const text = readFileSync(file, "utf8");
    if (forbiddenRoute.test(text)) fail(`${file} registers a mutating HTTP method`);
    if (/shell\s*:\s*true/.test(text)) fail(`${file} enables a shell`);
    if (/\bexecSync\s*\(/.test(text)) fail(`${file} uses execSync`);
    if (/agent\.(answer|say|stop)|session\.spawn|send-keys|capture-pane/.test(text) && !text.includes("deny") && !text.includes("forbidden")) {
      if (/["'`](agent\.(answer|say|stop)|session\.spawn)["'`]/.test(text)) {
        fail(`${file} references a write method`);
      }
    }
  }
}

const artifactRoot = process.argv.includes("--artifacts")
  ? process.argv[process.argv.indexOf("--artifacts") + 1]
  : "";
try {
  const ciText = execFileSync(process.execPath, ["scripts/check-ci.mjs"], { encoding: "utf8" });
  const ciReport = JSON.parse(ciText);
  if (ciReport.ok !== true) fail("ci workflow failed the local machine check");
  if (ciReport.hostedActionsExecuted !== false) fail("ci check claimed hosted Actions ran");
  if (ciReport.runsOn !== "ubuntu-22.04" || ciReport.node !== "22.23.2" || ciReport.python !== "3.13.7") {
    fail("ci pins drifted");
  }
  if (ciReport.permissions?.contents !== "read") fail("ci permissions are not contents: read");
} catch (error) {
  const stderr = error && typeof error === "object" && "stderr" in error ? String(error.stderr ?? "") : "";
  const stdout = error && typeof error === "object" && "stdout" in error ? String(error.stdout ?? "") : "";
  fail(stderr.trim() || stdout.trim() || "check-ci failed");
}

if (artifactRoot) {
  if (!existsSync(artifactRoot)) fail(`missing artifacts ${artifactRoot}`);
  else {
    const stack = [artifactRoot];
    while (stack.length) {
      const current = stack.pop();
      for (const entry of readdirSync(current)) {
        const full = path.join(current, entry);
        if (statSync(full).isDirectory()) stack.push(full);
        else {
          const text = readFileSync(full, "utf8");
          if (text.includes("SYNTHETIC_SECRET_SENTINEL")) fail(`${full} contains secret sentinel`);
          if (text.includes("rawScreen") || text.includes("\"screen\":")) fail(`${full} may contain a raw screen`);
        }
      }
    }
  }
}

if (failures.length) {
  for (const failure of failures) process.stderr.write(`${failure}\n`);
  process.exit(1);
}
process.stdout.write("policy ok\n");
