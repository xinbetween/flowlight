#!/usr/bin/env node
const fs = require('fs');
const path = require('path');

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
}

function checkFindings(findings) {
  requireCondition(Array.isArray(findings), 'findings.example.json must be an array');
  findings.forEach((finding, index) => {
    requireCondition(severities.has(finding.severity), `finding ${index} has unsupported severity`);
    for (const key of ['title', 'summary', 'evidence']) {
      requireCondition(Object.prototype.hasOwnProperty.call(finding, key), `finding ${index} missing ${key}`);
    }
    requireCondition(finding.title.length <= 120, `finding ${index} title is too long`);
    requireCondition(finding.summary.length <= 500, `finding ${index} summary is too long`);
    requireCondition(Array.isArray(finding.evidence) && finding.evidence.length <= 8, `finding ${index} evidence must be a short array`);
    requireCondition(!secretPattern.test(JSON.stringify(finding)), `finding ${index} appears to contain a secret-like value`);
    finding.evidence.forEach(evidence => {
      requireCondition((evidence.label || '').length <= 80, `finding ${index} evidence label is too long`);
      requireCondition((evidence.value || '').length <= 240, `finding ${index} evidence value is too long`);
    });
  });
}

checkManifest(load('manifest.json'));
checkFindings(load('findings.example.json'));
console.log('ok');
