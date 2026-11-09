import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import {execFileSync} from 'node:child_process';
import {pathToFileURL} from 'node:url';

export const IMAGE = 'ghcr.io/the-running-dev/build-agent@sha256:cc13d62b66fab58e264eb583de5c47eb5f49a3ee8a2cdd48f0de0b1d0ba16556';
export const TEMPLATE = '1c3b5f76554aca455cd4a284c4e473edd21c0d72';
const SITE = 'artifacts/self-hosted-docs-smoke';
const marker = 'SubZeroDev Linux runner documentation smoke fixture.';
const secondMarker = 'SubZeroDev second-page smoke marker.';
const json = file => JSON.parse(fs.readFileSync(file, 'utf8'));
const save = (file, value) => { fs.mkdirSync(path.dirname(file), {recursive: true}); fs.writeFileSync(file, JSON.stringify(value, null, 2) + '\n'); };
const summary = text => { console.log(text); if (process.env.GITHUB_STEP_SUMMARY) fs.appendFileSync(process.env.GITHUB_STEP_SUMMARY, text + '\n'); };
const statePath = () => path.join(process.env.RUNNER_TEMP, `szr-docs-smoke-${process.env.GITHUB_RUN_ID}-${process.env.GITHUB_RUN_ATTEMPT}.json`);

export function checkIdentity(e) {
  assert.equal(e.runner.environment, 'self-hosted', 'Build did not run on a self-hosted runner');
  assert.equal(e.runner.os, 'Linux');
  assert.ok(e.runner.name, 'Missing runner name');
  assert.equal(e.selectedImage, IMAGE);
  assert.equal(e.templateCommit, TEMPLATE);
}

export function checkSite(root) {
  const index = fs.readFileSync(path.join(root, 'index.html'), 'utf8');
  assert.ok(index.includes(marker), 'Missing rendered index marker');
  const pages = [];
  function walk(dir) {
    for (const entry of fs.readdirSync(dir, {withFileTypes: true})) {
      const file = path.join(dir, entry.name);
      assert.ok(!entry.isSymbolicLink(), 'Unexpected symlink in generated site');
      if (entry.isDirectory()) walk(file); else if (entry.name.endsWith('.html')) pages.push(file);
    }
  }
  walk(root);
  assert.ok(pages.some(file => fs.readFileSync(file, 'utf8').includes(secondMarker)), 'Second page was not rendered');
  assert.ok(fs.existsSync(path.join(root, 'assets')), 'Missing Docusaurus assets');
  return {htmlFiles: pages.length, indexBytes: Buffer.byteLength(index)};
}

function before() {
  const e = {
    repository: process.env.GITHUB_REPOSITORY,
    sha: process.env.GITHUB_SHA,
    runId: process.env.GITHUB_RUN_ID,
    runAttempt: process.env.GITHUB_RUN_ATTEMPT,
    runUrl: `${process.env.GITHUB_SERVER_URL}/${process.env.GITHUB_REPOSITORY}/actions/runs/${process.env.GITHUB_RUN_ID}`,
    runner: {name: process.env.RUNNER_NAME, os: process.env.RUNNER_OS, arch: process.env.RUNNER_ARCH, environment: process.env.RUNNER_ENVIRONMENT},
    selectedImage: IMAGE,
    templateCommit: TEMPLATE,
    capturedAt: new Date().toISOString(),
  };
  checkIdentity(e);
  const workflow = fs.readFileSync('.github/workflows/self-hosted-docs-smoke.yml', 'utf8');
  assert.ok(workflow.includes(`image: ${IMAGE}`), 'Workflow image differs from captured selection');
  assert.ok(workflow.includes(`docs.yml@${TEMPLATE}`), 'Workflow template pin differs');
  assert.ok(Number(process.versions.node.split('.')[0]) >= 20);
  e.tools = {node: process.version};
  for (const cmd of ['git', 'pnpm', 'pwsh']) e.tools[cmd] = execFileSync(cmd, ['--version'], {encoding: 'utf8'}).trim();
  assert.ok(fs.existsSync('/usr/local/bin/build'), 'BuildAgent build wrapper is absent');
  assert.ok(fs.existsSync('/nuke/scripts/build.ps1'), 'BuildAgent Forge entry point is absent');
  // Refuse stale success: a previous job's files cannot satisfy the post-build check.
  fs.rmSync(SITE, {recursive: true, force: true});
  save(statePath(), e);
  summary(`Build runner: ${e.runner.name} (${e.runner.os}/${e.runner.arch}, ${e.runner.environment})\n\nSelected job-container image: \`${IMAGE}\`\n\nTemplate commit: \`${TEMPLATE}\`\n\n${JSON.stringify(e.tools)}`);
}

function after() {
  const e = json(statePath());
  checkIdentity(e);
  e.site = checkSite(SITE);
  e.buildOutputValidatedAt = new Date().toISOString();
  // Included inside artifact.tar, so the download check validates the transported evidence.
  save(path.join(SITE, 'smoke-evidence.json'), e);
  summary(`Documentation output validated: ${e.site.htmlFiles} HTML pages, ${e.site.indexBytes} bytes in index.html. Artifact upload and final job result are checked by Verify smoke evidence.`);
}

export function checkJob(e, jobs) {
  const candidates = jobs.filter(j => j.name === 'Docs smoke / Build');
  assert.equal(candidates.length, 1, 'Expected exactly one reusable documentation Build job');
  const job = candidates[0];
  assert.equal(job.status, 'completed');
  assert.equal(job.conclusion, 'success');
  assert.equal(job.runner_name, e.runner.name, 'Artifact and GitHub job have different runner identities');
  assert.ok(job.runner_id > 0);
  assert.ok(job.labels.includes('subzerodev-linux'));
  return {id: job.id, name: job.name, conclusion: job.conclusion, runnerId: job.runner_id, runnerName: job.runner_name, runnerGroupName: job.runner_group_name, requestedLabels: job.labels, url: job.html_url};
}

async function jobsForAttempt() {
  const jobs = [];
  for (let page = 1; ; page++) {
    const url = `${process.env.GITHUB_API_URL}/repos/${process.env.GITHUB_REPOSITORY}/actions/runs/${process.env.GITHUB_RUN_ID}/attempts/${process.env.GITHUB_RUN_ATTEMPT}/jobs?per_page=100&page=${page}`;
    const response = await fetch(url, {headers: {Authorization: `Bearer ${process.env.GH_TOKEN}`, Accept: 'application/vnd.github+json'}, signal: AbortSignal.timeout(30000)});
    if (!response.ok) throw new Error(`GitHub jobs GET returned ${response.status}`);
    const result = await response.json();
    jobs.push(...result.jobs);
    if (result.jobs.length < 100) return jobs;
  }
}

async function verify() {
  const dir = 'artifacts/docs-smoke-result';
  fs.rmSync(dir, {recursive: true, force: true});
  const result = {status: 'failure', docsResult: process.env.DOCS_RESULT, downloadResult: process.env.DOWNLOAD_RESULT, selectedImage: IMAGE, templateCommit: TEMPLATE, checkedAt: new Date().toISOString()};
  const errors = [];
  let jobs;
  try {
    jobs = await jobsForAttempt();
    save(path.join(dir, 'jobs.json'), jobs);
    result.observedBuildJobs = jobs.filter(j => j.name === 'Docs smoke / Build');
  }
  catch (error) { errors.push(error.message); }
  try {
    assert.equal(result.docsResult, 'success', `Documentation job result: ${result.docsResult}`);
    assert.equal(result.downloadResult, 'success', 'Site artifact download failed');
    const archive = 'artifacts/docs-smoke-download/artifact.tar';
    const entries = execFileSync('tar', ['-tf', archive], {encoding: 'utf8'}).trim().split('\n');
    for (const entry of entries) assert.ok(!path.posix.isAbsolute(entry) && !entry.split('/').includes('..'), 'Unsafe site archive path');
    const site = path.join(dir, 'site');
    fs.mkdirSync(site, {recursive: true});
    execFileSync('tar', ['-xf', archive, '-C', site, '--no-same-owner', '--no-same-permissions']);
    result.site = checkSite(site);
    const e = json(path.join(site, 'smoke-evidence.json'));
    checkIdentity(e);
    assert.equal(e.repository, process.env.GITHUB_REPOSITORY);
    assert.equal(e.sha, process.env.GITHUB_SHA);
    assert.equal(e.runId, process.env.GITHUB_RUN_ID);
    assert.equal(e.runAttempt, process.env.GITHUB_RUN_ATTEMPT);
    result.buildEvidence = e;
    if (jobs) result.buildJob = checkJob(e, jobs);
    assert.ok(/^\d+$/.test(process.env.EXPECTED_RUNNER_ID ?? '') && Number(process.env.EXPECTED_RUNNER_ID) > 0, 'Expected runner ID must be supplied');
    assert.equal(e.runner.name, process.env.EXPECTED_RUNNER_NAME, 'Build ran on a different runner than the verified consumer selection');
    assert.equal(String(result.buildJob?.runnerId), process.env.EXPECTED_RUNNER_ID, 'Build ran on a different GitHub runner ID than expected');
  } catch (error) { errors.push(error.message); }
  if (!errors.length) result.status = 'success';
  result.errors = errors;
  save(path.join(dir, 'result.json'), result);
  // The site is already in self-hosted-docs-site; keep the result artifact small.
  fs.rmSync(path.join(dir, 'site'), {recursive: true, force: true});
  summary(`Smoke result: **${result.status}**\n\nDocs: ${result.docsResult}; artifact download: ${result.downloadResult}\n\nSelected image: \`${IMAGE}\`\n\n${result.buildJob ? `Build runner: ${result.buildJob.runnerName} (GitHub runner ID ${result.buildJob.runnerId}); job: ${result.buildJob.url}` : 'No successful build runner verified.'}\n\n${errors.join('\n\n')}`);
  assert.equal(result.status, 'success', errors.join('; '));
}

if (process.argv[1] && import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href) {
  const mode = process.argv[2];
  if (mode === 'before') before();
  else if (mode === 'after') after();
  else if (mode === 'verify') await verify();
  else throw new Error('Usage: node scripts/docs-smoke/smoke.mjs before|after|verify');
}
