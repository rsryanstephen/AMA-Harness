// Checks every repo's bitbucket-pipelines.yml under a given root for real YAML
// validity -- PROJ-15111. Confirmed real incident: resultsprocessor's pipeline
// had inconsistent step indentation and failed to parse entirely on Bitbucket, never
// even running the build. Invisible to a local `dotnet build`, only caught reactively
// when a cascade push happened to touch that repo.
//
// Needs a real parser, not a naive indentation heuristic -- a first attempt using a
// crude structural check false-positived on exporterplus's valid nested `parallel:`
// step block.
//
// One-time setup: `npm install js-yaml` in this scripts/ directory (or wherever you
// run this from) -- not committed here to avoid checking node_modules into ~/.claude.
//
// Usage: node check-pipeline-yaml.js <repos-root>
const fs = require('fs');
const path = require('path');
const yaml = require('js-yaml');

const root = process.argv[2];
const repos = fs.readdirSync(root, { withFileTypes: true })
  .filter(d => d.isDirectory())
  .map(d => d.name);

let failures = 0;
for (const repo of repos) {
  const ymlPath = path.join(root, repo, 'bitbucket-pipelines.yml');
  if (!fs.existsSync(ymlPath)) continue;
  const content = fs.readFileSync(ymlPath, 'utf8');
  try {
    yaml.load(content);
    console.log(`OK    ${repo}`);
  } catch (e) {
    failures++;
    console.log(`FAIL  ${repo}: ${e.message.split('\n')[0]}`);
  }
}
console.log(`\n${failures} failure(s) out of ${repos.length} repos checked.`);
