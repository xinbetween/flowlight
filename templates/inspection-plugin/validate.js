#!/usr/bin/env node
const fs = require('fs');
const path = require('path');
const vm = require('vm');

const root = __dirname;
const kinds = new Set(['traffic', 'llmMCP']);
const sources = new Set(['builtIn', 'installed']);
const publishers = new Set(['official', 'thirdParty']);
const providers = new Set(['flowlight', 'presidio', 'bedrock', 'lakera', 'aporia', 'noma', 'prismaAIRS', 'custom']);
const capabilities = new Set(['annotate', 'suggestGuardrail']);
const severities = new Set(['info', 'low', 'medium', 'high']);
const secretPattern = /(sk-[A-Za-z0-9_-]{8,}|bearer\s+\S+|api[_-]?key\s*[:=]|secret\s*[:=]|token\s*[:=])/i;

function load(name) {
  return JSON.parse(fs.readFileSync(path.join(root, name), 'utf8'));
}

function fail(message) {
  console.error(`error: ${message}`);
  process.exit(1);
}

function requireCondition(condition, message) {
  if (!condition) fail(message);
}

function isPlainObject(value) {
  return value !== null && typeof value === 'object' && !Array.isArray(value);
}

function checkManifest(manifest) {
  for (const key of ['id', 'name', 'version', 'kind', 'source', 'publisher', 'guardrailProvider', 'description', 'privacySummary', 'capabilities']) {
    requireCondition(Object.prototype.hasOwnProperty.call(manifest, key), `manifest missing ${key}`);
  }
  requireCondition(/^[A-Za-z0-9_.-]+$/.test(manifest.id), 'manifest id must use letters, numbers, dots, underscores, and hyphens');
  requireCondition(kinds.has(manifest.kind), 'manifest kind must be traffic or llmMCP');
  requireCondition(sources.has(manifest.source), 'manifest source must be builtIn or installed');
  requireCondition(publishers.has(manifest.publisher), 'manifest publisher must be official or thirdParty');
  requireCondition(providers.has(manifest.guardrailProvider), 'unsupported guardrailProvider');
  requireCondition(Array.isArray(manifest.capabilities), 'manifest capabilities must be an array');
  requireCondition(manifest.capabilities.every(capability => capabilities.has(capability)), 'unsupported capability');
  requireCondition(manifest.privacySummary.length <= 500, 'privacySummary should stay concise');
  if (manifest.configuration !== undefined) {
    requireCondition(isPlainObject(manifest.configuration), 'configuration must be an object');
    for (const [key, value] of Object.entries(manifest.configuration)) {
      requireCondition(typeof value === 'string', `configuration ${key} must be a string`);
    }
  }
  if (manifest.script !== undefined) {
    requireCondition(typeof manifest.script === 'string', 'script must be a string');
    requireCondition(Buffer.byteLength(manifest.script, 'utf8') <= 128 * 1024, 'script must be 128 KB or smaller');
  }
}

function checkFindings(findings, source = 'findings') {
  requireCondition(Array.isArray(findings), `${source} must be an array`);
  findings.forEach((finding, index) => {
    requireCondition(severities.has(finding.severity), `${source} ${index} has unsupported severity`);
    for (const key of ['title', 'summary', 'evidence']) {
      requireCondition(Object.prototype.hasOwnProperty.call(finding, key), `${source} ${index} missing ${key}`);
    }
    requireCondition(finding.title.length <= 120, `${source} ${index} title is too long`);
    requireCondition(finding.summary.length <= 500, `${source} ${index} summary is too long`);
    requireCondition(Array.isArray(finding.evidence) && finding.evidence.length <= 8, `${source} ${index} evidence must be a short array`);
    requireCondition(!secretPattern.test(JSON.stringify(finding)), `${source} ${index} appears to contain a secret-like value`);
    finding.evidence.forEach(evidence => {
      requireCondition((evidence.label || '').length <= 80, `${source} ${index} evidence label is too long`);
      requireCondition((evidence.value || '').length <= 240, `${source} ${index} evidence value is too long`);
    });
  });
}

function sampleContext() {
  return {
    manifest: load('manifest.json'),
    exchange: {
      method: 'POST',
      scheme: 'https',
      host: 'api.anthropic.com',
      port: 443,
      path: '/v1/messages',
      status: 200,
      requestHeaderNames: ['content-type', 'authorization'],
      responseHeaderNames: ['content-type'],
      requestSize: 8192,
      responseSize: 16384,
      requestTruncated: false,
      responseTruncated: false,
      contentType: 'application/json',
      bundleID: 'com.anthropic.claudecode',
      appName: 'Claude Code',
      agent: 'claude',
      agentName: 'Claude Code',
      mcpServer: null,
      toolCalls: [{ source: 'anthropic', name: 'Bash', mcpServer: null }],
      mcp: [],
      llm: {
        provider: 'anthropic',
        model: 'claude-test',
        declaredTools: [{ name: 'Bash', kind: 'function', server: null }],
        connectors: [{ label: 'github', provider: 'Anthropic', approval: 'always', authorized: true }],
        stopReason: null,
        errorType: null
      }
    }
  };
}

function runScript(manifest) {
  if (!manifest.script) return;
  const pluginFile = fs.readFileSync(path.join(root, 'plugin.js'), 'utf8');
  requireCondition(manifest.script.trim() === pluginFile.trim(), 'manifest script should match plugin.js');
  const sandbox = {};
  vm.createContext(sandbox);
  vm.runInContext(manifest.script, sandbox, { timeout: 250 });
  requireCondition(typeof sandbox.evaluate === 'function', 'script must define evaluate(context)');
  const findings = sandbox.evaluate(sampleContext());
  checkFindings(findings, 'script finding');
}

const manifest = load('manifest.json');
checkManifest(manifest);
checkFindings(load('findings.example.json'), 'sample finding');
runScript(manifest);
console.log('ok');
