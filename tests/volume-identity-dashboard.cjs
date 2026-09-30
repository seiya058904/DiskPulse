const fs = require('node:fs');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const source = fs.readFileSync(require('node:path').join(__dirname, '../src/dashboard/app.js'), 'utf8');
const capacity = source.split('// TESTABLE_CAPACITY_HELPERS_START')[1].split('// TESTABLE_CAPACITY_HELPERS_END')[0];
const changes = source.split('// TESTABLE_CHANGE_HELPERS_START')[1].split('// TESTABLE_CHANGE_HELPERS_END')[0];
const guidA = String.raw`\\?\Volume{11111111-1111-1111-1111-111111111111}`;
const guidB = String.raw`\\?\Volume{22222222-2222-2222-2222-222222222222}`;
const current = { id: 'T:', volumeGuid: guidB.toLowerCase() + '\\', total: 2000, used: 20 };
const history = [
  { ID: 'T:', Timestamp: '2026-01-01', Total: 2000, Used: 1000, Percent: 50 },
  { ID: 'T:', Timestamp: '2026-01-02', Total: 2000, Used: 1000, Percent: 50, VolumeGuid: guidA },
  { ID: 'T:', Timestamp: '2026-01-03', Total: 2000, Used: 10, Percent: 0.5, VolumeGuid: guidB },
];
const context = { DATA: [current], HISTORY: history };
vm.createContext(context);
vm.runInContext(capacity + changes + source.slice(source.indexOf('const historyMap ='), source.indexOf('const state =')) +
  source.slice(source.indexOf('function historyFor('), source.indexOf('function sparkline(')), context);
assert.equal(context.normalizeVolumeGuid(guidB + '\\'), guidB.toUpperCase());
assert.equal(context.normalizeVolumeGuid('\\\\?\\Volume{bad}'), '');
assert.deepEqual(Array.from(context.capacityHistoryFor(history, current), r => r.Used), [10]);
assert.deepEqual(Array.from(context.historyFor('T:'), r => r.Used), [10], 'card sparkline and prediction source must share same-volume filter');
const samples = context.cleanCapacitySamples(history, current, 'T:', '2026-01-04');
assert.deepEqual(Array.from(samples, r => r.used), [10, 20]);
assert.equal(context.capacityTrendStats(samples).change, 10);
assert.equal(context.capacityTrendStats(context.cleanCapacitySamples(history, { ...current, volumeGuid: '' }, 'T:', '2026-01-04')).change, null);
assert.equal(context.capacityHistoryFor(history, { ...current, volumeGuid: '' }).length, 0);
assert.equal(context.capacityHistoryFor(history, { ...current, volumeGuid: guidA }).length, 1);
assert.equal(context.formatCapacityDelta(null), '等待同卷容量基线');
assert.equal(context.formatCapacityDelta(0), '容量基本不变');
assert(source.includes('formatCapacityDelta(d.diff)'), 'clipboard summary must preserve unknown delta');
console.log('PASS: capacity chart/card history, unknown baseline and clipboard delta identity guards.');
