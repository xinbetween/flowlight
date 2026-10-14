#!/usr/bin/env node
const fs = require('fs');
const path = require('path');
const vm = require('vm');

const root = __dirname;
const kinds = new Set(['traffic', 'llmMCP']);
const sources = new Set(['builtIn', 'installed']);
const publishers = new Set(['official', 'thirdParty']);
const providers = new Set(['flowlight', 'presidio', 'bedrock', 'lakera', 'aporia', 'noma', 'prismaAIRS', 'custom']);
const capabilities = new Set(['annotate', 'suggestGuardrail', 'suggestAction']);
const permissions = new Set(['trafficMetadata', 'headerNames', 'appIdentity', 'llmMetadata', 'mcpMetadata', 'suggestGuardrail', 'suggestAction']);
const privacyCategories = new Set(['metadataOnly', 'headerNames', 'appIdentity', 'toolNames', 'mcpMetadata', 'guardrailSuggestions']);
const channels = new Set(['builtIn', 'local', 'community', 'official']);
const reviewStatuses = new Set(['builtIn', 'unsigned', 'verifiedOfficial', 'verifiedCommunity', 'rejected']);
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
  if (manifest.schemaVersion !== undefined) {
    requireCondition(Number.isInteger(manifest.schemaVersion) && manifest.schemaVersion >= 1, 'schemaVersion must be a positive integer');
  }
  if (manifest.permissions !== undefined) {
    requireCondition(Array.isArray(manifest.permissions), 'permissions must be an array');
    requireCondition(manifest.permissions.every(permission => permissions.has(permission)), 'unsupported permission');
    if (manifest.capabilities.includes('suggestGuardrail')) {
      requireCondition(manifest.permissions.includes('suggestGuardrail') || manifest.permissions.includes('suggestAction'), 'suggestGuardrail capability must declare a suggestion permission');
    }
    if (manifest.capabilities.includes('suggestAction')) {
      requireCondition(manifest.permissions.includes('suggestAction') || manifest.permissions.includes('suggestGuardrail'), 'suggestAction capability must declare a suggestion permission');
    }
  }
  if (manifest.privacy !== undefined) {
    requireCondition(isPlainObject(manifest.privacy), 'privacy must be an object');
    requireCondition(Array.isArray(manifest.privacy.categories), 'privacy.categories must be an array');
    requireCondition(manifest.privacy.categories.length > 0, 'privacy.categories must not be empty');
    requireCondition(manifest.privacy.categories.every(category => privacyCategories.has(category)), 'unsupported privacy category');
    requireCondition(typeof (manifest.privacy.summary || '') === 'string', 'privacy.summary must be a string');
  }
  if (manifest.provenance !== undefined) {
    requireCondition(isPlainObject(manifest.provenance), 'provenance must be an object');
    if (manifest.provenance.distributionChannel !== undefined) {
      requireCondition(channels.has(manifest.provenance.distributionChannel), 'unsupported distributionChannel');
    }
    if (manifest.provenance.reviewStatus !== undefined) {
      requireCondition(reviewStatuses.has(manifest.provenance.reviewStatus), 'unsupported reviewStatus');
    }
  }
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

function checkGuardrail(value, source) {
  requireCondition(isPlainObject(value), `${source} guardrail must be an object`);
  for (const key of ['agent', 'server', 'tool', 'resource', 'name']) {
    requireCondition(typeof (value[key] || '') === 'string', `${source} guardrail ${key} must be a string`);
  }
  requireCondition((value.server || value.tool || value.resource), `${source} guardrail must name a server, tool or resource`);
}

function checkNetworkRule(value, source) {
  requireCondition(isPlainObject(value), `${source} networkRule must be an object`);
  requireCondition(['block', 'allow'].includes(value.action || 'block'), `${source} networkRule action must be block or allow`);
  requireCondition((value.app || value.destination), `${source} networkRule must name an app or destination`);
  for (const key of ['app', 'destination', 'path', 'method', 'name']) {
    requireCondition(typeof (value[key] || '') === 'string', `${source} networkRule ${key} must be a string`);
  }
  if (value.status !== undefined) {
    requireCondition(Number.isInteger(value.status) && value.status >= 400 && value.status <= 599, `${source} networkRule status must be 400-599`);
  }
}

function checkHeaders(headers, source) {
  requireCondition(headers === undefined || Array.isArray(headers), `${source} headers must be an array`);
  (headers || []).forEach((header, index) => {
    requireCondition(isPlainObject(header), `${source} header ${index} must be an object`);
    requireCondition(typeof (header.name || '') === 'string' && header.name.length <= 120, `${source} header ${index} name must be short text`);
    requireCondition(typeof (header.value || '') === 'string' && header.value.length <= 240, `${source} header ${index} value must be short text`);
  });
}

function checkHeaderEdits(edits, source) {
  requireCondition(edits === undefined || Array.isArray(edits), `${source} header edits must be an array`);
  (edits || []).forEach((edit, index) => {
    requireCondition(isPlainObject(edit), `${source} header edit ${index} must be an object`);
    requireCondition(['set', 'add', 'remove'].includes(edit.op || 'set'), `${source} header edit ${index} op is unsupported`);
    requireCondition(typeof (edit.name || '') === 'string' && edit.name.length <= 120, `${source} header edit ${index} name must be short text`);
    requireCondition(typeof (edit.value || '') === 'string' && edit.value.length <= 240, `${source} header edit ${index} value must be short text`);
  });
}

function checkBodyEdits(edits, source) {
  requireCondition(edits === undefined || Array.isArray(edits), `${source} body edits must be an array`);
  (edits || []).forEach((edit, index) => {
    requireCondition(isPlainObject(edit), `${source} body edit ${index} must be an object`);
    requireCondition(['set', 'remove'].includes(edit.op || 'set'), `${source} body edit ${index} op is unsupported`);
    requireCondition(typeof (edit.path || '') === 'string' && edit.path.length <= 160, `${source} body edit ${index} path must be short text`);
    requireCondition(typeof (edit.value || '') === 'string' && edit.value.length <= 4096, `${source} body edit ${index} value is too long`);
  });
}

function checkSuggestedAction(action, source) {
  requireCondition(isPlainObject(action), `${source} suggested action must be an object`);
  requireCondition(['guardrail', 'networkRule', 'mockResponse', 'requestRewrite', 'responseTransform'].includes(action.kind), `${source} suggested action kind is unsupported`);
  requireCondition(typeof (action.title || '') === 'string' && action.title.length <= 120, `${source} suggested action title is too long`);
  requireCondition(typeof (action.reason || '') === 'string' && action.reason.length <= 240, `${source} suggested action reason is too long`);
  if (action.kind === 'guardrail') checkGuardrail(action.guardrail, source);
  if (action.kind === 'networkRule') checkNetworkRule(action.networkRule, source);
  if (action.kind === 'mockResponse') {
    const mock = action.mock;
    requireCondition(isPlainObject(mock), `${source} mock must be an object`);
    requireCondition(typeof (mock.host || '') === 'string' && mock.host.length <= 240, `${source} mock host must be short text`);
    requireCondition(typeof (mock.path || '') === 'string' && mock.path.length <= 240, `${source} mock path must be short text`);
    requireCondition(typeof (mock.method || '') === 'string' && mock.method.length <= 20, `${source} mock method must be short text`);
    requireCondition(mock.status === undefined || (Number.isInteger(mock.status) && mock.status >= 100 && mock.status <= 599), `${source} mock status must be 100-599`);
    requireCondition(mock.delay === undefined || (typeof mock.delay === 'number' && mock.delay >= 0 && mock.delay <= 300), `${source} mock delay must be 0-300`);
    requireCondition(typeof (mock.body || '') === 'string' && mock.body.length <= 4096, `${source} mock body is too long`);
    checkHeaders(mock.headers, `${source} mock`);
  }
  if (action.kind === 'requestRewrite') {
    const rewrite = action.rewrite;
    requireCondition(isPlainObject(rewrite), `${source} rewrite must be an object`);
    checkHeaderEdits(rewrite.headers, `${source} rewrite`);
    checkBodyEdits(rewrite.body, `${source} rewrite`);
    requireCondition((rewrite.headers || []).length > 0 || (rewrite.body || []).length > 0, `${source} rewrite must include an edit`);
  }
  if (action.kind === 'responseTransform') {
    const transform = action.responseTransform;
    requireCondition(isPlainObject(transform), `${source} responseTransform must be an object`);
    requireCondition(typeof (transform.script || '') === 'string' && transform.script.length > 0 && transform.script.length <= 4096, `${source} responseTransform script must be 1-4096 characters`);
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
    if (finding.suggestedGuardrail !== undefined) {
      checkGuardrail(finding.suggestedGuardrail, `${source} ${index} suggestedGuardrail`);
    }
    if (finding.suggestedRule !== undefined) {
      checkNetworkRule(finding.suggestedRule, `${source} ${index} suggestedRule`);
    }
    if (finding.suggestedActions !== undefined) {
      requireCondition(Array.isArray(finding.suggestedActions) && finding.suggestedActions.length <= 4, `${source} ${index} suggestedActions must be a short array`);
      finding.suggestedActions.forEach((action, actionIndex) => checkSuggestedAction(action, `${source} ${index} action ${actionIndex}`));
    }
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
