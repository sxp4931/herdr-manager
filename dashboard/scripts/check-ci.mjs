import { readFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const workflowPath = path.join(root, ".github", "workflows", "ci.yml");
const failures = [];

function fail(message) {
  failures.push(message);
}

const expectedUses = ["actions/checkout@v4", "actions/setup-node@v4", "actions/setup-python@v5"];
const expectedStages = [
  "npm ci --no-audit --no-fund",
  "python3 -m venv .venv && .venv/bin/python -m pip install -r probes/requirements.txt",
  "npm exec playwright install chromium",
  "npm run check:policy",
  "npm run check",
  "npm run test:e2e",
];

let text = "";
try {
  text = readFileSync(workflowPath, "utf8");
} catch {
  fail("missing .github/workflows/ci.yml");
}

const uses = [];
const stages = [];
if (text) {
  for (const line of text.split("\n")) {
    const use = line.match(/^\s*- uses:\s*(\S+)\s*$/);
    if (use) uses.push(use[1]);
    const run = line.match(/^\s*- run:\s*(.+?)\s*$/);
    if (run) stages.push(run[1]);
  }
  if (uses.length !== expectedUses.length || uses.some((item, index) => item !== expectedUses[index])) {
    fail("workflow uses an action outside checkout, setup-node, and setup-python");
  }
  if (stages.length !== expectedStages.length || stages.some((item, index) => item !== expectedStages[index])) {
    fail("workflow run stages drifted");
  }
  const runsOn = [...text.matchAll(/^ {4}runs-on:\s*(\S+)\s*$/gm)].map((match) => match[1]);
  if (runsOn.length !== 1 || runsOn[0] !== "ubuntu-22.04") fail("workflow runs-on must be ubuntu-22.04");
  const nodeVersions = [...text.matchAll(/node-version:\s*"([^"]+)"/g)].map((match) => match[1]);
  if (nodeVersions.length !== 1 || nodeVersions[0] !== "22.23.2") fail("workflow node-version must be \"22.23.2\"");
  if (/node-version:\s*[^"\s]/.test(text)) fail("workflow node-version must be quoted");
  const pythonVersions = [...text.matchAll(/python-version:\s*"([^"]+)"/g)].map((match) => match[1]);
  if (pythonVersions.length !== 1 || pythonVersions[0] !== "3.13.7") fail("workflow python-version must be \"3.13.7\"");
  if (/python-version:\s*[^"\s]/.test(text)) fail("workflow python-version must be quoted");
  const permissionBlocks = [...text.matchAll(/^permissions:\n((?:[ \t].*\n)*)/gm)].map((match) => match[1]);
  if (permissionBlocks.length !== 1) fail("workflow must declare one permissions block");
  else {
    const lines = permissionBlocks[0].split("\n").map((line) => line.trim()).filter((line) => line.length > 0);
    if (lines.length !== 1 || lines[0] !== "contents: read") fail("workflow permissions must be contents: read");
  }
  if (!text.includes('CI: "1"')) fail("workflow e2e must set CI to \"1\"");
  if (/\bsecrets\b/.test(text)) fail("workflow references secrets");
  if (/\bdeploy\b/i.test(text)) fail("workflow deploys");
  if (/git\s+push/.test(text)) fail("workflow pushes");
  if (/--with-deps/.test(text)) fail("workflow installs system packages");
  const pkg = JSON.parse(readFileSync(path.join(root, "package.json"), "utf8"));
  const scripts = pkg.scripts ?? {};
  for (const stage of stages) {
    for (const match of stage.matchAll(/npm run ([A-Za-z0-9:_-]+)/g)) {
      if (!Object.hasOwn(scripts, match[1])) fail(`workflow runs missing script ${match[1]}`);
    }
  }
}

const runsOnValue = text.match(/^ {4}runs-on:\s*(\S+)\s*$/m)?.[1] ?? null;
const nodeValue = text.match(/node-version:\s*"([^"]+)"/)?.[1] ?? null;
const pythonValue = text.match(/python-version:\s*"([^"]+)"/)?.[1] ?? null;
const contentsValue = /^permissions:\n[ \t]+contents:\s*read\s*$/m.test(text) ? "read" : null;

const report = {
  hostedActionsExecuted: false,
  runsOn: runsOnValue,
  node: nodeValue,
  python: pythonValue,
  permissions: { contents: contentsValue },
  stages,
  ok: failures.length === 0,
};

process.stdout.write(`${JSON.stringify(report)}\n`);
if (!report.ok) {
  for (const failure of failures) process.stderr.write(`${failure}\n`);
  process.exit(1);
}
