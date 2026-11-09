// Synthetic checks of the evidence validator. These are not a real runner execution.
import {test} from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import http from 'node:http';
import {execFileSync, spawn} from 'node:child_process';
import {fileURLToPath} from 'node:url';
import {IMAGE, TEMPLATE, checkIdentity, checkSite, checkJob} from './smoke.mjs';

const evidence = () => ({runner: {name: 'fixture-linux', environment: 'self-hosted', os: 'Linux'}, selectedImage: IMAGE, templateCommit: TEMPLATE, repository: 'fixture/consumer', sha: 'fixture-sha', runId: '123', runAttempt: '2'});
const job = () => ({id: 789, name: 'Docs smoke / Build', status: 'completed', conclusion: 'success', runner_name: 'fixture-linux', runner_id: 456, labels: ['subzerodev-linux']});
function fixtureSite(dir) {
  fs.mkdirSync(path.join(dir, 'assets'), {recursive: true});
  fs.writeFileSync(path.join(dir, 'index.html'), '<html>SubZeroDev Linux runner documentation smoke fixture.</html>');
  fs.writeFileSync(path.join(dir, 'second.html'), '<html>SubZeroDev second-page smoke marker.</html>');
  fs.writeFileSync(path.join(dir, 'smoke-evidence.json'), JSON.stringify(evidence()));
}
test('reject hosted or non-Linux execution evidence', () => {
  checkIdentity(evidence());
  for (const runner of [{environment: 'github-hosted'}, {os: 'Windows'}, {name: ''}]) {
    const e = evidence(); Object.assign(e.runner, runner); assert.throws(() => checkIdentity(e));
  }
});
test('reject selected image drift', () => {
  const e = evidence(); e.selectedImage = 'image:latest'; assert.throws(() => checkIdentity(e));
});
test('reject a different runner or a failed job even with a valid site', () => {
  checkJob(evidence(), [job()]);
  for (const patch of [{runner_name: 'another-runner'}, {conclusion: 'failure'}, {labels: ['ubuntu-latest']}]) {
    assert.throws(() => checkJob(evidence(), [{...job(), ...patch}]));
  }
  assert.throws(() => checkJob(evidence(), []));
});
test('check rendered pages and reject stale/incomplete artifacts', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'docs-site-'));
  try {
    fixtureSite(dir); assert.equal(checkSite(dir).htmlFiles, 2);
    fs.rmSync(path.join(dir, 'second.html')); assert.throws(() => checkSite(dir));
  } finally { fs.rmSync(dir, {recursive: true, force: true}); }
});
test('manual consumer template matches the configured image and evidence pins', () => {
  const config = JSON.parse(fs.readFileSync(new URL('../../runners.json', import.meta.url), 'utf8'));
  const workflow = fs.readFileSync(new URL('../../tests/linux-runner-docs-smoke.yml', import.meta.url), 'utf8');
  assert.equal(config.buildAgent.image, IMAGE);
  assert.ok(workflow.includes(`image: ${IMAGE}`));
  assert.ok(workflow.includes(`docs.yml@${TEMPLATE}`));
  assert.ok(workflow.includes('runs-on: subzerodev-linux'));
  assert.ok(workflow.includes('deploy: false') && workflow.includes('upload-builds: true'));
  assert.doesNotMatch(workflow, /^\s+(push|pull_request|pull_request_target|schedule|workflow_call):/m);
});
for (const scenario of ['success', 'missing-artifact', 'failed-build', 'unexpected-runner', 'jobs-api-failure']) {
  test(`verification records ${scenario} with a synthetic GitHub jobs API`, async () => {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'docs-verify-'));
    const server = http.createServer((request, response) => {
      assert.equal(request.url, '/repos/fixture/consumer/actions/runs/123/attempts/2/jobs?per_page=100&page=1');
      response.setHeader('Content-Type', 'application/json');
      if (scenario === 'jobs-api-failure') response.statusCode = 503;
      response.end(JSON.stringify({jobs: [job()]}));
    });
    await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
    try {
      if (scenario !== 'missing-artifact') {
        const site = path.join(dir, 'source'); fixtureSite(site);
        const download = path.join(dir, 'artifacts/docs-smoke-download'); fs.mkdirSync(download, {recursive: true});
        execFileSync('tar', ['-cf', path.join(download, 'artifact.tar'), '-C', site, '.']);
      }
      const child = spawn(process.execPath, [fileURLToPath(new URL('./smoke.mjs', import.meta.url)), 'verify'], {cwd: dir, env: {...process.env, GITHUB_STEP_SUMMARY: path.join(dir, 'summary.md'), GITHUB_REPOSITORY: 'fixture/consumer', GITHUB_SHA: 'fixture-sha', GITHUB_RUN_ID: '123', GITHUB_RUN_ATTEMPT: '2', GITHUB_API_URL: `http://127.0.0.1:${server.address().port}`, GH_TOKEN: 'synthetic', EXPECTED_RUNNER_NAME: 'fixture-linux', EXPECTED_RUNNER_ID: scenario === 'unexpected-runner' ? '999' : '456', DOCS_RESULT: scenario === 'failed-build' ? 'failure' : 'success', DOWNLOAD_RESULT: scenario === 'missing-artifact' ? 'failure' : 'success'}, stdio: 'ignore'});
      const code = await new Promise((resolve, reject) => { child.on('exit', resolve); child.on('error', reject); });
      const result = JSON.parse(fs.readFileSync(path.join(dir, 'artifacts/docs-smoke-result/result.json'), 'utf8'));
      assert.equal(result.status, scenario === 'success' ? 'success' : 'failure');
      assert.equal(code === 0, scenario === 'success');
      assert.equal(fs.existsSync(path.join(dir, 'artifacts/docs-smoke-result/jobs.json')), scenario !== 'jobs-api-failure');
    } finally { server.close(); fs.rmSync(dir, {recursive: true, force: true}); }
  });
}
