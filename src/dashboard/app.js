const RAW_DATA = INJECT_DATA;
const RAW_HISTORY = INJECT_HISTORY;
const RAW_DIRECTORY = INJECT_DIRECTORY;
const RAW_HISTORY_CENTER = INJECT_HISTORY_CENTER;
const RAW_SCAN_META = INJECT_SCAN_META;
const DATA = Array.isArray(RAW_DATA) ? RAW_DATA : RAW_DATA ? [RAW_DATA] : [];
const HISTORY = Array.isArray(RAW_HISTORY) ? RAW_HISTORY : RAW_HISTORY ? [RAW_HISTORY] : [];
const DIRECTORY = Array.isArray(RAW_DIRECTORY) ? RAW_DIRECTORY : RAW_DIRECTORY ? [RAW_DIRECTORY] : [];
const HISTORY_CENTER = Array.isArray(RAW_HISTORY_CENTER) ? RAW_HISTORY_CENTER : RAW_HISTORY_CENTER ? [RAW_HISTORY_CENTER] : [];
const SCAN_META = RAW_SCAN_META || {};
const TS = INJECT_TS_JSON;
const SYSTEM_DRIVE = INJECT_SYSTEM_DRIVE;
/* DISKPULSE_AI_RESULT_START */
const RAW_AI_ANALYSIS = INJECT_AI_ANALYSIS;
/* DISKPULSE_AI_RESULT_END */
let AI_ANALYSIS = RAW_AI_ANALYSIS || {};
const AI_COPY_TEXT = INJECT_AI_COPY_TEXT;

// TESTABLE_HISTORY_HELPERS_START
function selectHistoryComparison(disk, range, customScanId) {
  const scanId = range === "custom" ? customScanId : disk?.selections?.[range];
  return (disk?.comparisons || []).find((item) => item.scanId === scanId) || null;
}

function reliableHistoryRows(rows) {
  return (rows || []).filter((row) => ["created","changed","removed"].includes(row.state));
}

function defaultHistoryCustomScanId(disk) {
  return disk?.comparisons?.[0]?.scanId || null;
}

const historyListLimits = { growth: 5, release: 5, trend: 6 };
function visibleHistoryRows(rows, list, expanded) {
  return expanded?.[list] ? rows : rows.slice(0,historyListLimits[list]);
}
// TESTABLE_HISTORY_HELPERS_END

// TESTABLE_CAPACITY_HELPERS_START
function normalizeDriveId(value) {
  return String(value ?? "").replace(/\\/g, "").trim().toUpperCase();
}

function compareDriveId(a, b) {
  const left = normalizeDriveId(a), right = normalizeDriveId(b);
  return left < right ? -1 : left > right ? 1 : 0;
}

function capacityDriveOrder(drives) {
  const statusRank = { critical: 0, warning: 1, good: 2 };
  return [...drives].sort((a,b) =>
    (statusRank[a.status] ?? 3) - (statusRank[b.status] ?? 3) ||
    Number(b.percent || 0) - Number(a.percent || 0) ||
    compareDriveId(a.id,b.id)
  );
}

function defaultCapacityDrive(drives, systemDrive) {
  const critical = drives.filter((drive) => drive.status === "critical").sort((a,b) =>
    Number(b.percent || 0) - Number(a.percent || 0) ||
    Number(a.free || 0) - Number(b.free || 0) ||
    compareDriveId(a.id,b.id)
  );
  if (critical.length) return normalizeDriveId(critical[0].id);
  const wanted = normalizeDriveId(systemDrive);
  const system = drives.find((drive) => normalizeDriveId(drive.id) === wanted);
  if (system) return normalizeDriveId(system.id);
  return drives.length ? normalizeDriveId([...drives].sort((a,b) => compareDriveId(a.id,b.id))[0].id) : "";
}

function cleanCapacitySamples(history, current, driveId, reportTimestamp) {
  const wanted = normalizeDriveId(driveId);
  const rows = history.filter((row) => normalizeDriveId(row.ID) === wanted);
  if (current && normalizeDriveId(current.id) === wanted) {
    rows.push({ Timestamp: reportTimestamp, ID: current.id, Total: current.total, Used: current.used });
  }
  const byTime = new Map();
  rows.forEach((row) => {
    const time = Date.parse(row.Timestamp);
    const total = Number(row.Total), used = Number(row.Used);
    if (!Number.isFinite(time) || !Number.isFinite(total) || !Number.isFinite(used) || total <= 0 || used < 0 || used > total) return;
    byTime.set(time, { time, timestamp: String(row.Timestamp), total, used, percent: used / total * 100 });
  });
  return [...byTime.values()].sort((a,b) => a.time-b.time);
}

function filterCapacitySamples(samples, range, reportTimestamp) {
  if (range === "all") return [...samples];
  const days = Number(range);
  if (!Number.isFinite(days) || days <= 0 || !samples.length) return [];
  const reportTime = Date.parse(reportTimestamp);
  const end = Number.isFinite(reportTime) ? reportTime : samples[samples.length-1].time;
  const start = end - days * 86400000;
  return samples.filter((sample) => sample.time >= start && sample.time <= end);
}

function capacityTrendStats(samples) {
  if (!samples.length) return null;
  const used = samples.map((sample) => sample.used);
  return {
    first: samples[0], last: samples[samples.length-1], count: samples.length,
    min: Math.min(...used), max: Math.max(...used),
    change: samples.length > 1 ? samples[samples.length-1].used - samples[0].used : null
  };
}

function buildAttentionItems(drives, directoryItems, reliableRows) {
  const items = [];
  const critical = drives.filter((drive) => drive.status === "critical").sort((a,b) =>
    Number(a.free || 0) - Number(b.free || 0) || Number(b.percent || 0) - Number(a.percent || 0) || compareDriveId(a.id,b.id));
  const incomplete = directoryItems.filter((item) => item.status === "partial" || item.status === "failed");
  const warnings = drives.filter((drive) => drive.status === "warning").sort((a,b) =>
    Number(b.percent || 0) - Number(a.percent || 0) || compareDriveId(a.id,b.id));
  if (critical.length) items.push({ kind:"critical", tone:"critical", href:"#drive-details-section", title:`${critical.length} 个磁盘空间严重不足`, detail:`${normalizeDriveId(critical[0].id)} 仅剩 ${fmt(critical[0].free)}` });
  if (incomplete.length) items.push({ kind:"incomplete", tone:"warning", href:"#scan-completeness", title:`${incomplete.length} 个磁盘扫描不完整`, detail:"报告中的目录变化可能不完整，请查看详细原因" });
  if (warnings.length && items.length < 3) items.push({ kind:"warning", tone:"warning", href:"#drive-details-section", title:`${warnings.length} 个磁盘需要关注`, detail:`${normalizeDriveId(warnings[0].id)} 使用率 ${pct(warnings[0].percent)}` });
  const main = reliableRows.find((row) => isReliableChange(row) && Number(row.deltaBytes));
  if (main && items.length < 3) items.push({ kind:"change", tone:"info", href:"#change-details", title:main.deltaBytes > 0 ? "主要可靠增长" : "主要可靠释放", detail:`${main.displayPath} · ${main.deltaBytes > 0 ? "+" : ""}${fmtBytes(main.deltaBytes)}` });
  return items.length ? items.slice(0,3) : [{ kind:"clear", tone:"good", href:"#overview-section", title:"当前没有需要立即处理的问题", detail:"容量状态与扫描结果均未发现明显风险" }];
}
// TESTABLE_CAPACITY_HELPERS_END

const historyMap = {};
HISTORY.forEach((row) => {
  const id = normalizeDriveId(row.ID);
  if (!historyMap[id]) historyMap[id] = [];
  historyMap[id].push(row);
});
Object.values(historyMap).forEach((arr) =>
  arr.sort((a, b) => String(a.Timestamp).localeCompare(String(b.Timestamp)))
);

const state = {
  query: "",
  sort: "percent-desc",
  compact: false,
  driveLevels: {},
  historyRange: "previous",
  historyCustom: {},
  historyTab: "growth",
  historyExpanded: {},
  capacityDrive: defaultCapacityDrive(DATA,SYSTEM_DRIVE),
  capacityRange: "30"
};

const $ = (id) => document.getElementById(id);
const svgNs = "http://www.w3.org/2000/svg";

function element(tag, className, text) {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (text !== undefined) node.textContent = String(text);
  return node;
}

// --- AI live probe polling (testable block) ---
let aiLiveScanId = "";
let aiProbeInFlight = false;
let aiProbeSupported = null;
let aiLiveInterval = null;
let aiLiveWatchdog = null;
let aiFallbackScheduled = false;

function aiProbeSrc(scanId) {
  return "ai-live-" + scanId + (AI_ANALYSIS.analysisId ? "-" + AI_ANALYSIS.analysisId : "") + ".js?t=" + Date.now();
}

function aiRemoveProbeNode(node) {
  if (node && node.parentNode) {
    try { node.parentNode.removeChild(node); } catch (e) {}
  }
}

function aiApplyLiveResult(live) {
  if (aiLiveInterval !== null) { clearInterval(aiLiveInterval); aiLiveInterval = null; }
  if (aiLiveWatchdog !== null) { clearTimeout(aiLiveWatchdog); aiLiveWatchdog = null; }
  const scanId = AI_ANALYSIS.scanId || live.scanId || "unknown";
  aiProbeInFlight = false;
  aiProbeSupported = null;
  aiFallbackScheduled = false;
  aiLiveScanId = "";
  sessionStorage.removeItem("diskpulse-ai-refresh:" + scanId);
  AI_ANALYSIS = live;
  renderAIAnalysis();
}

function aiProbeTick(scanId) {
  if (aiProbeInFlight || aiLiveScanId !== scanId) return;
  aiProbeInFlight = true;
  const s = document.createElement("script");
  s.async = true;
  s.src = aiProbeSrc(scanId);
  s.onload = function() {
    aiProbeInFlight = false;
    aiRemoveProbeNode(s);
    aiProbeSupported = true;
    const live = window.DiskPulseAILive;
    if (live && live.scanId === scanId && live.analysisId === AI_ANALYSIS.analysisId && live.status && live.status !== "analyzing") {
      aiApplyLiveResult(live);
    }
  };
  s.onerror = function() {
    aiProbeInFlight = false;
    aiRemoveProbeNode(s);
    if (aiProbeSupported === null) {
      aiProbeSupported = false;
      aiStartRefreshFallback(scanId);
    }
  };
  document.head.appendChild(s);
}

function aiStartRefreshFallback(scanId) {
  if (aiLiveInterval !== null) { clearInterval(aiLiveInterval); aiLiveInterval = null; }
  aiFallbackScheduled = true;
  if (aiLiveWatchdog !== null) { clearTimeout(aiLiveWatchdog); aiLiveWatchdog = null; }
  const refreshKey = "diskpulse-ai-refresh:" + scanId;
  const refreshCount = Number(sessionStorage.getItem(refreshKey) || "0");
  if (refreshCount >= 3) { return; }
  sessionStorage.setItem(refreshKey, String(refreshCount + 1));
  // First fallback refresh happens immediately once the watchdog fires (chromium/edge cache
  // file:// probes, so waiting longer only delays the user); follow-ups back off 20s then 30s.
  const delays = [0, 20000, 30000];
  // `??` (not `||`): delay 0 is a valid first-fallback delay; `||` would replace it with 30000.
  aiLiveWatchdog = setTimeout(() => { location.reload(); }, delays[refreshCount] ?? 30000);
}

function aiProbeGiveUp(scanId) {
  if (aiLiveScanId !== scanId) return;
  if (aiLiveInterval !== null) { clearInterval(aiLiveInterval); aiLiveInterval = null; }
  if (aiLiveWatchdog !== null) { clearTimeout(aiLiveWatchdog); aiLiveWatchdog = null; }
  aiProbeInFlight = false;
  aiStartRefreshFallback(scanId);
}

function ensureAiLivePolling() {
  const scanId = AI_ANALYSIS.scanId || "unknown";
  if (aiLiveScanId === scanId && (aiLiveInterval !== null || aiFallbackScheduled)) return;
  if (aiLiveScanId !== scanId) {
    aiLiveScanId = scanId;
    aiProbeInFlight = false;
    aiProbeSupported = null;
    aiFallbackScheduled = false;
  }
  if (aiProbeSupported === false) { aiStartRefreshFallback(scanId); return; }
  aiLiveInterval = setInterval(() => aiProbeTick(scanId), 2000);
  // Real-browser verification (Chrome/Edge on file://): the dynamic-script probe loads, but
  // chromium caches file:// subresources, so an already-open page usually cannot read the
  // worker-rewritten probe. Treat the probe as a best-effort optimization (seamless in browsers
  // that do not cache file://, and for pages opened after completion). The short 10s watchdog
  // is the reliable path: it triggers an immediate first fallback refresh, so a typical ~10s
  // AI result reaches the user around 10s instead of the old 5s x 12 reload spam or a 40s wait.
  aiLiveWatchdog = setTimeout(() => aiProbeGiveUp(scanId), 10000);
  aiProbeTick(scanId);
}

function renderAIAnalysis() {
  const root = $("ai-analysis-content");
  if (!root) return;
  root.replaceChildren();
  const statusMap = {
    "analyzing": "AI 分析中，请稍候...",
    "disabled": "AI 分析未启用",
    "not-configured": "尚未配置 AI",
    "baseline-required": "当前正在建立首次比较基线",
    "no-reliable-changes": "本次没有可靠变化，因此未调用 AI",
    "configuration-error": "AI 配置有误，无法调用接口",
    "timeout": "AI 请求超时",
    "authentication-failed": "API Key 或权限无效",
    "rate-limited": "接口额度或频率受限",
    "connection-failed": "无法连接 AI 接口",
    "invalid-response": "AI 返回格式无法识别",
    "unknown-error": "AI 分析失败"
  };
  const st = AI_ANALYSIS.status || "unknown-error";
  const scanId = AI_ANALYSIS.scanId || "unknown";
  const refreshKey = `diskpulse-ai-refresh:${scanId}`;
  const title = $("ai-analysis-title");
  const note = $("ai-analysis-note");
  const copyInputBtn = $("copy-ai-input");
  const copyOutputBtn = $("copy-ai-output");
  const defaultNote = "根据本次目录变化和历史趋势生成。AI 内容属于推测，请以原始磁盘数据为准。";
  const manualStates = ["not-configured", "disabled"];
  const failureStates = ["configuration-error", "timeout", "authentication-failed", "rate-limited", "connection-failed", "invalid-response", "unknown-error"];
  // Copy-to-AI is available whenever a canonical (redacted) payload was generated, independent
  // of whether an API is configured. It is hidden only when there is nothing meaningful to copy.
  if (copyInputBtn) copyInputBtn.hidden = !AI_COPY_TEXT;
  if (copyOutputBtn) copyOutputBtn.hidden = true;
  if (st === "analyzing") {
    if (title) title.textContent = "正在等待" + (AI_ANALYSIS.model ? " " + AI_ANALYSIS.model : "") + "分析…";
    if (note) note.textContent = "页面保持可用，无需手动刷新。";
    const refreshCount = Number(sessionStorage.getItem(refreshKey) || "0");
    root.appendChild(element("div", "ai-status", "⏳ " + statusMap["analyzing"]));
    if (refreshCount >= 3) {
      root.appendChild(element("div", "ai-status", "AI 分析仍在进行或已中断，请手动刷新"));
    }
    ensureAiLivePolling();
    return;
  }
  sessionStorage.removeItem(refreshKey);
  if (st === "success") {
    if (title) title.textContent = "AI 变化解释";
    if (note) note.textContent = defaultNote;
    if (copyOutputBtn) copyOutputBtn.hidden = false;
    if (AI_ANALYSIS.format === "structured" && AI_ANALYSIS.analysis) {
      const a = AI_ANALYSIS.analysis;
      const hasValue = (value) => Boolean(value) && (!Array.isArray(value) || value.length > 0);
      const appendValue = (parent, value) => {
        if (Array.isArray(value)) {
          const list = element("div", "ai-field-text");
          value.forEach((item) => list.appendChild(element("div", undefined, "· " + String(item))));
          parent.appendChild(list);
        } else {
          parent.appendChild(element("div", "ai-field-text", String(value)));
        }
      };
      const appendField = (parent, className, label, value) => {
        if (!hasValue(value)) return;
        const field = element("div", className);
        field.appendChild(element("div", "ai-field-label", label));
        appendValue(field, value);
        parent.appendChild(field);
      };
      const summary = element("div", "ai-summary");
      summary.appendChild(element("div", "ai-field-label", "结论"));
      if (hasValue(a.summary)) appendValue(summary, a.summary);
      else summary.appendChild(element("div", "ai-field-text", "AI 未提供简洁结论，请查看技术详情。"));
      root.appendChild(summary);

      const findings = element("div", "ai-findings");
      appendField(findings, "ai-field", "可能原因 / 重要发现", a.possibleCauses);
      if (hasValue(a.possibleCauses)) root.appendChild(findings);

      const recommendations = element("div", "ai-recommendations");
      appendField(recommendations, "ai-field", "建议检查", a.recommendations);
      if (hasValue(a.recommendations)) root.appendChild(recommendations);

      root.appendChild(element("div", "ai-facts-note", "以上是 AI 对扫描结果的解释，不是新的扫描事实；容量、路径和扫描状态请以本页原始数据为准。"));

      const evidence = element("details", "ai-evidence");
      evidence.appendChild(element("summary", "ai-evidence-summary", "查看证据与技术细节"));
      const evidenceBody = element("div", "ai-evidence-body");
      appendField(evidenceBody, "ai-field", "证据", a.evidence);
      appendField(evidenceBody, "ai-field", "证据边界", a.cautions);
      const conf = (a.confidence || "low").toLowerCase();
      const confClass = ["high","medium"].includes(conf) ? conf : "low";
      const confEl = element("div", "ai-field");
      confEl.appendChild(element("span", "ai-field-label", "可信度："));
      confEl.appendChild(element("span", "ai-confidence ai-confidence-" + confClass, conf === "high" ? "高" : conf === "medium" ? "中等" : "低"));
      evidenceBody.appendChild(confEl);
      evidence.appendChild(evidenceBody);
      root.appendChild(evidence);
    } else if (AI_ANALYSIS.rawText) {
      root.appendChild(element("div", "ai-summary", "AI 返回了非结构化内容。"));
      const evidence = element("details", "ai-evidence");
      evidence.appendChild(element("summary", "ai-evidence-summary", "查看 AI 原文"));
      evidence.appendChild(element("div", "ai-field-text", AI_ANALYSIS.rawText));
      root.appendChild(evidence);
    }
    if (AI_ANALYSIS.model) {
      root.appendChild(element("div", "ai-meta", "模型：" + AI_ANALYSIS.model + (AI_ANALYSIS.generatedAt ? " · " + formatLocalDate(AI_ANALYSIS.generatedAt) : "")));
    }
  } else {
    if (title) {
      if (manualStates.includes(st)) title.textContent = "自动 AI 未" + (st === "disabled" ? "启用" : "配置");
      else if (failureStates.includes(st)) title.textContent = "自动 AI 分析失败";
      else title.textContent = "AI 变化解释";
    }
    if (note) {
      if (manualStates.includes(st)) note.textContent = "你仍然可以复制本次分析数据到任意 AI。";
      else if (failureStates.includes(st)) note.textContent = "你仍然可以将本次数据复制到其他 AI。";
      else note.textContent = defaultNote;
    }
    const msg = statusMap[st] || statusMap["unknown-error"];
    root.appendChild(element("div", "ai-status", msg));
  }
}

function announce(message) {
  $("live-status").textContent = "";
  requestAnimationFrame(() => { $("live-status").textContent = message; });
}

(function() {
  var saved = localStorage.getItem("diskpulse-theme");
  if (saved) {
    document.documentElement.setAttribute("data-theme", saved);
  } else if (window.matchMedia && window.matchMedia("(prefers-color-scheme: dark)").matches) {
    document.documentElement.setAttribute("data-theme", "dark");
  }
})();

$("ts").textContent = "更新于 " + TS;
$("footer").textContent = "历史记录保留最近 " + HISTORY.length + " 条采样";

function fmt(gb) {
  const value = Number(gb) || 0;
  if (value >= 1000) return (value / 1000).toFixed(2) + " TB";
  return value.toFixed(value >= 100 ? 0 : 1) + " GB";
}

function pct(value) {
  return (Number(value) || 0).toFixed(1).replace(".0", "") + "%";
}

function historyFor(id) {
  return historyMap[normalizeDriveId(id)] || [];
}

function sparkline(rows) {
  const samples = rows.slice(-20).map((row) => Number(row.Percent) || 0);
  const svg=document.createElementNS(svgNs,"svg"); svg.classList.add("spark"); svg.setAttribute("viewBox","0 0 120 38"); svg.setAttribute("preserveAspectRatio","none"); svg.setAttribute("aria-hidden","true");
  const path=document.createElementNS(svgNs,"path");
  if (samples.length < 2) { path.setAttribute("d","M2 28 L118 28"); svg.append(path); return svg; }
  const min = Math.min(...samples);
  const max = Math.max(...samples);
  const span = Math.max(1, max - min);
  const points = samples.map((value, index) => {
    const x = 2 + (index / (samples.length - 1)) * 116;
    const y = 34 - ((value - min) / span) * 30;
    return `${x.toFixed(1)} ${y.toFixed(1)}`;
  });
  path.setAttribute("d",`M${points.join(" L")}`); svg.append(path); return svg;
}

function estimateDays(drive, rows) {
  const samples = rows.slice(-20);
  if (samples.length < 3) return "样本不足";
  const points = samples.map((r, i) => ({ x: i, y: Number(r.Used) || 0 }));
  const n = points.length;
  const sumX = points.reduce((s, p) => s + p.x, 0);
  const sumY = points.reduce((s, p) => s + p.y, 0);
  const sumXY = points.reduce((s, p) => s + p.x * p.y, 0);
  const sumX2 = points.reduce((s, p) => s + p.x * p.x, 0);
  const denom = n * sumX2 - sumX * sumX;
  if (denom === 0) return "暂无增长压力";
  const slope = (n * sumXY - sumX * sumY) / denom;
  const firstTs = new Date(samples[0].Timestamp).getTime();
  const lastTs = new Date(samples[n - 1].Timestamp).getTime();
  const hoursPerSample = (lastTs - firstTs) / ((n - 1) * 36e5);
  const dailyGrowth = slope * (24 / Math.max(hoursPerSample, 1 / 24));
  if (dailyGrowth <= 0.01) return "暂无增长压力";
  const days = (Number(drive.free) || 0) / dailyGrowth;
  if (!Number.isFinite(days) || days > 3650) return "暂无增长压力";
  if (days < 1) return "不足 1 天";
  return Math.round(days) + " 天后可能满";
}

function trend(diff) {
  const value = Number(diff) || 0;
  const text = formatCapacityDelta(value);
  return element("span",text === "容量基本不变" ? "trend-st" : value > 0 ? "trend-up" : "trend-dn",text);
}

function totals() {
  return DATA.reduce((acc, d) => {
    acc.total += Number(d.total) || 0;
    acc.used += Number(d.used) || 0;
    acc.free += Number(d.free) || 0;
    acc.diff += Number(d.diff) || 0;
    return acc;
  }, { total: 0, used: 0, free: 0, diff: 0 });
}

function sortedDrives() {
  const query = state.query.trim().toLowerCase();
  const filtered = DATA.filter((d) => d.id.toLowerCase().includes(query));
  const sorters = {
    "percent-desc": (a, b) => b.percent - a.percent,
    "percent-asc": (a, b) => a.percent - b.percent,
    "free-asc": (a, b) => a.free - b.free,
    "name-asc": (a, b) => a.id.localeCompare(b.id),
    "change-desc": (a, b) => b.diff - a.diff
  };
  return filtered.sort(sorters[state.sort] || sorters["percent-desc"]);
}

function fmtBytes(value) {
  let size = Math.abs(Number(value) || 0);
  const units = ["B", "KB", "MB", "GB", "TB"];
  let index = 0;
  while (size >= 1024 && index < units.length - 1) { size /= 1024; index++; }
  return `${Number(value) < 0 ? "-" : ""}${size.toFixed(index ? 2 : 0)} ${units[index]}`;
}

function directoryCoverage(id) {
  return DIRECTORY.find((item) => normalizeDriveId(item.drive) === normalizeDriveId(id))?.coverage || null;
}

// TESTABLE_CHANGE_HELPERS_START
const defaultChangeFilters = { drive: "all", level: "1", direction: "all", state: "reliable", query: "" };

function isReliableChange(row) {
  return ["created", "changed", "removed"].includes(row.state);
}

function reliableChanges(item, level) {
  return item && item.baselineScanId ? (item.changes || []).filter((row) => isReliableChange(row) && (!level || row.level === level)) : [];
}

function filterChangeRows(items, filters) {
  const level = filters.level === "all" ? null : Number(filters.level);
  const query = String(filters.query || "").trim().toLowerCase();
  return items.filter((item) => filters.drive === "all" || item.drive === filters.drive).flatMap((item) =>
    (item.changes || []).filter((row) => {
      const stateMatches = filters.state === "reliable" ? Boolean(item.baselineScanId) && isReliableChange(row) : row.state === filters.state;
      const levelMatches = !level || Number(row.level) === level;
      const directionMatches = filters.direction === "all" || (filters.direction === "growth" ? Number(row.deltaBytes) > 0 : Number(row.deltaBytes) < 0);
      return stateMatches && levelMatches && directionMatches && (!query || String(row.displayPath || row.path || "").toLowerCase().includes(query));
    }).map((row) => ({...row, drive:item.drive}))
  );
}

function rankChanges(rows) {
  return {
    growth: rows.filter((row) => isReliableChange(row) && Number(row.deltaBytes) > 0).sort((a,b) => Number(b.deltaBytes)-Number(a.deltaBytes)),
    release: rows.filter((row) => isReliableChange(row) && Number(row.deltaBytes) < 0).sort((a,b) => Number(a.deltaBytes)-Number(b.deltaBytes))
  };
}

function emptyChangeCopy(context) {
  if (context.waiting) return "当前磁盘正在建立首次完整基线";
  if (context.comparable && context.kind === "release") return "本次没有明显释放";
  return "当前没有可可靠归因的目录变化";
}

function classifyScanEvidence(items) {
  // Three independent semantic groups (see scan-completeness section): designed ignores are
  // normal; permission limits sit inside an otherwise-successful scan (not errors); transient
  // missing paths vanished mid-scan (not a scan failure). Anything else is unexpected.
  const designedIgnored = [], permissionLimited = [], transientMissing = [], unexpected = [];
  items.forEach((item) => {
    (item.excluded || []).forEach((entry) =>
      (entry.reason === "access-denied" ? permissionLimited : designedIgnored).push({...entry,drive:item.drive})
    );
    (item.unavailable || []).forEach((entry) =>
      (entry.reason === "transient-missing" ? transientMissing : unexpected).push({...entry,drive:item.drive})
    );
    (item.errors || []).forEach((entry) =>
      (entry.kind === "transient-missing" ? transientMissing : unexpected).push({...entry,drive:item.drive})
    );
  });
  return { designedIgnored, permissionLimited, transientMissing, unexpected, expected: designedIgnored };
}

function formatCapacityDelta(gb) {
  const value = Number(gb) || 0;
  const bytes = Math.abs(value) * 1024 * 1024 * 1024;
  if (bytes < 1024) return "容量基本不变";
  const units = bytes >= 1024 ** 3 ? [1024 ** 3,"GB"] : bytes >= 1024 ** 2 ? [1024 ** 2,"MB"] : [1024,"KB"];
  return `${value > 0 ? "增加" : "减少"} ${(bytes / units[0]).toFixed(1)} ${units[1]}`;
}

function formatLocalDate(value) {
  const date = new Date(value);
  if (!Number.isFinite(date.getTime())) return "-";
  const pad = (part) => String(part).padStart(2,"0");
  return `${date.getFullYear()}-${pad(date.getMonth()+1)}-${pad(date.getDate())} ${pad(date.getHours())}:${pad(date.getMinutes())}:${pad(date.getSeconds())}`;
}

function shortSnapshotId(value) {
  const text = String(value || "-");
  return text.length > 9 ? `${text.slice(0,8)}…` : text;
}

function currentSizeBytes(row) {
  return Number(row?.sizeBytes || 0);
}

function summarizeChanges(items, rows) {
  const comparable = items.filter((item) => item.baselineScanId);
  const added = rows.filter((row) => isReliableChange(row) && row.deltaBytes > 0).reduce((sum,row) => sum + Number(row.deltaBytes),0);
  const released = rows.filter((row) => isReliableChange(row) && row.deltaBytes < 0).reduce((sum,row) => sum + Math.abs(Number(row.deltaBytes)),0);
  const located = added - released;
  const actual = comparable.reduce((sum,item) => sum + Number(item.coverage?.actualNetBytes || 0),0);
  const activityPreferred = comparable.some((item) => item.coverage?.activityPreferred) || (actual && located && Math.sign(actual) !== Math.sign(located));
  const rate = !activityPreferred && Math.abs(actual) >= 1 ? Math.min(100, Math.abs(located) / Math.abs(actual) * 100) : null;
  return { comparable, added, released, located, actual, activityPreferred, rate };
}

function confidenceFor(items) {
  const comparable = items.filter((item) => item.baselineScanId && item.status !== "failed");
  const waiting = items.filter((item) => !item.baselineScanId && item.status !== "failed");
  const incomplete = items.filter((item) => item.status === "partial");
  const failed = items.filter((item) => item.status === "failed");
  const state = items.length && failed.length === items.length ? "failed" : incomplete.length || failed.length ? "partial" : waiting.length ? "waiting" : "complete";
  const inspect = failed[0] || incomplete[0] || waiting[0] || items[0];
  return { comparable, waiting, incomplete, failed, state, inspect };
}

function statusLabel(status, hasBaseline) {
  // Execution-status label only: "完成/部分/失败" describe whether the scan ran to completion,
  // NOT how much data was visible. Permission limits / designed ignores / transient missing are
  // reported separately under "扫描信息", never folded into this badge.
  if (status === "failed") return "扫描失败";
  if (!hasBaseline) return "等待完整基线";
  if (status === "complete" || status === "baseline") return "扫描完成";
  return "部分完成";
}
// TESTABLE_CHANGE_HELPERS_END

function coverageLabel(item) {
  if (!item?.baselineScanId) return "等待完整基线";
  if (item.coverage?.activityPreferred || Math.abs(Number(item.coverage?.actualNetBytes || 0)) < 1) return "不适用";
  return `${Number(item.coverage?.rate || 0).toFixed(1)}%`;
}

function selectedHistoryState() {
  const selections = HISTORY_CENTER.map((disk) => ({disk,comparison:selectHistoryComparison(disk,state.historyRange,state.historyCustom[disk.drive])}));
  const items = selections.map(({disk,comparison}) => ({
    drive:disk.drive,status:disk.status,baselineScanId:comparison?.scanId || null,
    baselineCompletedAt:comparison?.completedAt || null,coverage:comparison?.coverage || {},
    changes:(comparison?.changes || []).map((row) => ({...row,drive:disk.drive}))
  }));
  return {selections,items};
}

function historyTrendNode(row) {
  const recent = (row.samples || []).slice(-5).map((sample) => sample?.[1] == null ? "未知" : fmtBytes(sample[1])).join(" → ");
  const root = element("div","history-row");
  const main = element("div","history-row-main"); const path=element("span","",`${row.drive} · ${row.displayPath}`); path.title=String(row.displayPath ?? "");
  main.append(path,element("b",Number(row.cumulativeBytes)>=0?"growth-value":"release-value",`累计 ${Number(row.cumulativeBytes)>0?"+":""}${fmtBytes(row.cumulativeBytes)}`));
  const meta = element("div","history-row-meta"); [row.label,`增长 ${row.growthCount} 次`,`释放 ${row.releaseCount} 次`,recent || "暂无大小序列"].forEach((text) => meta.append(element("span","",text)));
  const dates = element("div","history-row-meta"); dates.append(element("span","",`首次 ${formatLocalDate(row.firstSeen)}`),element("span","",`最近 ${formatLocalDate(row.lastSeen)}`));
  root.append(main,meta,sizeSparklineNode(row.samples),dates);
  return root;
}

function sizeSparklineNode(samples) {
  const values = (samples || []).map((sample) => sample?.[1] == null ? null : Number(sample[1]));
  const known = values.filter((value) => value !== null);
  const svg = document.createElementNS(svgNs,"svg"); svg.classList.add("history-spark"); svg.setAttribute("viewBox","0 0 160 26"); svg.setAttribute("aria-hidden","true");
  if (known.length < 2) return svg;
  const min=Math.min(...known),max=Math.max(...known),span=max-min||1;
  const path=document.createElementNS(svgNs,"path"); path.setAttribute("d",values.map((value,index)=>value === null ? "" : `${index && values[index-1] !== null?"L":"M"}${(index/(values.length-1)*158+1).toFixed(1)} ${(24-(value-min)/span*22).toFixed(1)}`).join(" ")); svg.append(path);
  return svg;
}

function allDirectoryTrends() {
  return HISTORY_CENTER.flatMap((disk) => (disk.trends || []).map((trend) => ({...trend,drive:disk.drive})));
}

function directoryTrendRows(id,level) {
  const drive = HISTORY_CENTER.find((disk) => normalizeDriveId(disk.drive) === normalizeDriveId(id));
  return (drive?.trends || []).filter((row) => Number(row.level) === Number(level)).sort((a,b) => Math.abs(Number(b.cumulativeBytes))-Math.abs(Number(a.cumulativeBytes))).slice(0,6).map((row) => ({...row,drive:drive.drive}));
}

function renderHistoryCenter() {
  const labels = {previous:"上一次完整扫描",day:"约 24 小时前",week:"约 7 天前",earliest:"最早可用快照",custom:"自选历史快照"};
  if (state.historyRange === "custom") HISTORY_CENTER.forEach((disk) => { state.historyCustom[disk.drive] ||= defaultHistoryCustomScanId(disk); });
  const {selections,items} = selectedHistoryState();
  const rows = items.flatMap((item) => reliableHistoryRows(item.changes).filter((row) => Number(row.level) === 1));
  const rankings = rankChanges(rows);
  const summary = summarizeChanges(items,rows);
  const unexplained = summary.comparable.reduce((sum,item) => sum + Number(item.coverage?.unexplainedBytes || 0),0);
  const gross = summary.added + summary.released;
  const activity = summary.activityPreferred ? `活动总量 ${fmtBytes(gross)}` : summary.rate === null ? "解释率不适用" : `解释率 ${summary.rate.toFixed(1)}%`;
  const mainGrowth = rankings.growth[0]?.displayPath || "无可靠增长";
  const mainRelease = rankings.release[0]?.displayPath || "无可靠释放";
  $("history-range-note").textContent = `${labels[state.historyRange]} · ${summary.comparable.length} / ${items.length} 个磁盘可可靠比较${selections.filter(x=>x.comparison).length ? " · " + selections.filter(x=>x.comparison).map(x=>`${x.disk.drive} ${formatLocalDate(x.comparison.completedAt)}`).join("；") : " · 当前没有合格历史基线"}`;
  const historySummary = $("history-summary"); historySummary.replaceChildren();
  historySummary.className="history-summary history-rail";
  [
    ["较上次增长","+"+fmtBytes(summary.added)],["较上次释放",summary.released?"-"+fmtBytes(summary.released):fmtBytes(0)],
    ["净变化",fmtBytes(summary.located)],["本次扫描时长",SCAN_META.startedAt && SCAN_META.completedAt ? `${Math.max(0,Math.round((new Date(SCAN_META.completedAt)-new Date(SCAN_META.startedAt))/60000))} 分钟` : "-"],
    ["扫描时间",formatLocalDate(SCAN_META.completedAt)],["上次扫描",selections.find(x=>x.comparison)?.comparison?.completedAt ? formatLocalDate(selections.find(x=>x.comparison).comparison.completedAt) : "暂无历史"]
  ].forEach(([label,value]) => { const metric=element("div","history-metric"); const strong=element("b","",value); strong.title=String(value); metric.append(element("span","",label),strong); historySummary.append(metric); });

  const historyCustom = $("history-custom"); historyCustom.replaceChildren();
  if (state.historyRange === "custom") HISTORY_CENTER.forEach((disk) => {
    const label=element("label","",disk.drive); const select=element("select","select history-custom-baseline"); select.dataset.drive=disk.drive;
    (disk.comparisons || []).forEach((item) => { const option=element("option","",formatLocalDate(item.completedAt)); option.value=String(item.scanId); option.selected=state.historyCustom[disk.drive]===item.scanId; select.append(option); });
    label.append(select); historyCustom.append(label);
  });

  const trends = allDirectoryTrends();
  const lists = {
    growth: trends.filter((row) => row.label === "持续增长").sort((a,b) => Number(b.cumulativeBytes)-Number(a.cumulativeBytes)),
    release: trends.filter((row) => row.label === "持续释放").sort((a,b) => Number(a.cumulativeBytes)-Number(b.cumulativeBytes)),
    trend: trends.filter((row) => row.label !== "数据不足" || Number(row.occurrenceCount) > 0).sort((a,b) => Math.abs(Number(b.cumulativeBytes))-Math.abs(Number(a.cumulativeBytes)))
  };
  const ids = {growth:"sustained-growth-list",release:"sustained-release-list",trend:"history-trend-list"};
  const titles = {growth:"持续增长",release:"持续释放",trend:"历史变化"};
  const empty = {growth:"历史样本不足，至少需要 3 次有效比较。",release:"本范围内没有持续释放目录。",trend:"历史样本不足，暂无明显历史变化。"};
  Object.entries(lists).forEach(([list,listRows]) => {
    const panel = $(`history-${list}-panel`);
    const active = state.historyTab === list;
    panel.hidden = !active;
    const tab = document.querySelector(`[data-history-tab="${list}"]`);
    tab.classList.toggle("is-active",active);
    tab.setAttribute("aria-selected",String(active));
    tab.textContent = `${titles[list]}（${listRows.length}）`;
    const listRoot=$(ids[list]); listRoot.replaceChildren();
    const visible=visibleHistoryRows(listRows,list,state.historyExpanded);
    if (visible.length) visible.forEach((row) => listRoot.append(historyTrendNode(row)));
    else listRoot.append(element("div","history-empty",empty[list]));
    const expand = panel.querySelector(".history-expand");
    expand.hidden = listRows.length <= historyListLimits[list];
    expand.textContent = state.historyExpanded[list] ? "收起" : `展开全部（${listRows.length}）`;
    expand.setAttribute("aria-expanded",String(Boolean(state.historyExpanded[list])));
  });
}

function directoryTopThree(id) {
  const item = DIRECTORY.find((entry) => normalizeDriveId(entry.drive) === normalizeDriveId(id));
  return reliableChanges(item, 1).sort((a,b) => Math.abs(b.deltaBytes) - Math.abs(a.deltaBytes)).slice(0,3);
}

function changeRowNode(row, maxMagnitude, contributionBase) {
  const valueClass = row.deltaBytes >= 0 ? "growth-value" : "release-value";
  const intensity = maxMagnitude ? Math.max(4, Math.abs(Number(row.deltaBytes)) / maxMagnitude * 100) : 0;
  const contribution = contributionBase ? `${(Math.abs(Number(row.deltaBytes)) / contributionBase * 100).toFixed(1)}%` : "-";
  const root=element("div","change-item"), main=element("div","change-main"), path=element("span","change-path expandable-path",row.displayPath);
  path.title=String(row.displayPath ?? "");
  const context=element("div","change-context");
  context.append(element("span","",`${row.drive} · ${row.level} 级 · 当前 ${fmtBytes(currentSizeBytes(row))} ·`),element("span","change-contribution",`贡献 ${contribution}`));
  main.append(path,context);
  const side=element("div","change-side"); side.append(element("b",valueClass,`${row.deltaBytes >= 0 ? "+" : ""}${fmtBytes(row.deltaBytes)}`));
  const copy=element("button","copy-path","复制路径"); copy.type="button"; copy.dataset.copyPath=String(row.displayPath ?? ""); copy.setAttribute("aria-label",`复制路径 ${row.displayPath}`); side.append(copy);
  const track=element("div",`intensity-track ${valueClass}`),fill=element("span","intensity-fill"); fill.style.setProperty("--intensity",`${Math.max(0,Math.min(100,intensity)).toFixed(1)}%`); track.append(fill);
  root.append(main,side,track); return root;
}

function stateChangeRowNode(row) {
  const label = row.state === "unknown" ? "未知变化" : "当前不可用";
  const reason = {"scan-incomplete":"扫描范围不完整", "scope-mismatch":"与基线的扫描范围不同", "legacy-evidence-missing":"历史完整性证据不足", "no-baseline":"尚无比较基线"}[row.reason] || label;
  const root=element("div","change-item"), main=element("div","change-main"), path=element("span","change-path expandable-path",row.displayPath); path.title=String(row.displayPath ?? "");
  main.append(path,element("div","change-context",`${row.drive} · ${row.level} 级 · ${reason}`)); root.append(main,element("span","status-badge waiting",label)); return root;
}

function currentChangeFilters() {
  return {
    drive: $("change-drive-filter").value || defaultChangeFilters.drive,
    level: $("change-level-filter").value || defaultChangeFilters.level,
    direction: $("change-direction-filter").value || defaultChangeFilters.direction,
    state: $("change-state-filter").value || defaultChangeFilters.state,
    query: $("change-path-filter").value || defaultChangeFilters.query
  };
}

function selectedItems(filters) {
  return DIRECTORY.filter((item) => filters.drive === "all" || item.drive === filters.drive);
}

function capacityStatement(mostFull) {
  if (!mostFull || Number(mostFull.percent) < 75) return "当前没有明显容量压力";
  return `${mostFull.id} 使用率最高，建议关注`;
}

function renderCapacitySummary() {
  const t = totals();
  const overallPct = t.total > 0 ? t.used / t.total * 100 : 0;
  const mostFull = [...DATA].sort((a,b) => b.percent-a.percent)[0];
  const root = $("capacity-summary");
  root.replaceChildren();
  root.append(element("div","summary-label","整体容量"));
  const layout = element("div","capacity-layout");
  const ring = element("div","ring");
  ring.style.setProperty("--pct",String(Math.max(0,Math.min(100,Number(overallPct) || 0))));
  ring.append(element("span","",pct(overallPct)));
  const copy = element("div");
  copy.append(element("h2","summary-title",capacityStatement(mostFull)));
  copy.append(element("p","summary-note",`最高使用率 ${mostFull ? `${normalizeDriveId(mostFull.id)} ${pct(mostFull.percent)}` : "-"}`));
  layout.append(ring,copy);
  root.append(layout);
  const scan = confidenceFor(DIRECTORY);
  const baselineWaiting = DIRECTORY.some((item) => !item.baselineScanId);
  const allFailed = DIRECTORY.length > 0 && DIRECTORY.every((item) => item.status === "failed");
  const scanState = !DIRECTORY.length ? ["unknown","扫描状态未知"] : allFailed ? ["failed","扫描执行：全部失败"] : scan.incomplete.length || scan.failed.length ? ["partial","扫描执行：部分完成"] : baselineWaiting ? ["waiting","等待比较基线"] : ["complete","扫描执行：全部完成"];
  const statusLink = element("a",`overview-scan-state ${scanState[0]}`,scanState[1]);
  statusLink.href = "#scan-completeness";
  root.append(statusLink);
  const facts = element("div","summary-facts");
  [["已用",fmt(t.used)],["总容量",fmt(t.total)],["剩余",fmt(t.free)]].forEach(([label,value]) => {
    const fact = element("div","summary-fact"); fact.append(element("span","",label),element("b","",value)); facts.append(fact);
  });
  root.append(facts);
}

function renderConfidence(items) {
  const c = confidenceFor(items);
  const root = $("comparison-confidence"); root.replaceChildren();
  const top=element("div","summary-card-link"); top.append(element("div","summary-label","可比磁盘概览"),element("a","summary-link","查看全部")); top.querySelector("a").href="#drive-details-section"; root.append(top);
  const body=element("div","confidence-body"); const copy=element("div"); copy.append(element("div",`confidence-count confidence-state ${c.state}`,`${c.comparable.length} / ${items.length}`),element("h2","summary-title","个磁盘可可靠比较"));
  const list = element("div","confidence-list");
  [`● ${c.comparable.length} 个磁盘相似`, `● ${c.waiting.length + c.incomplete.length + c.failed.length} 个磁盘不可比`, `优先建议：${c.inspect ? normalizeDriveId(c.inspect.drive) : "无需检查"}`].forEach((text) => list.append(element("span","",text))); copy.append(list);
  const art=element("div","confidence-illustration"); art.setAttribute("aria-hidden","true"); art.append(element("span","confidence-stack","▤"),element("span","confidence-check","✓")); body.append(copy,art); root.append(body);
}

function renderChangeSummary(items, summary, rankings) {
  const main = rankings.growth[0] || rankings.release[0];
  const gross = summary.added + summary.released;
  const contribution = main && gross ? Math.abs(Number(main.deltaBytes)) / gross * 100 : null;
  const headline = main ? `${main.deltaBytes > 0 ? "主要增长" : "主要释放"}来自 ${main.displayPath}` : emptyChangeCopy({waiting:!summary.comparable.length,comparable:summary.comparable.length > 0,kind:"all"});
  const fourthLabel = summary.activityPreferred ? "活动总量" : "目录解释率";
  const fourthValue = summary.activityPreferred ? fmtBytes(gross) : summary.rate === null ? "不适用" : `${summary.rate.toFixed(1)}%`;
  const root = $("latest-change"); root.replaceChildren();
  root.append(element("div","summary-label","最新变化"),element("h2","summary-title",headline));
  const hero = element("div","change-hero");
  // The headline figure is the most prominent number in the section, so it must not contradict the
  // change rows below it: same growth/release semantics, neutral when no direction is known. The
  // sign and the headline sentence still carry the meaning on their own, so colour is never the
  // only signal.
  const heroTone = main ? (main.deltaBytes > 0 ? "growth-value" : "release-value") : "neutral-value";
  hero.append(element("b",heroTone,main ? `${main.deltaBytes > 0 ? "+" : ""}${fmtBytes(main.deltaBytes)}` : "—"),element("span","summary-note",contribution === null ? "没有可靠变化排行" : `主路径贡献 ${contribution.toFixed(1)}%`));
  root.append(hero);
  const metrics = element("div","change-metrics");
  [["可靠新增",`+${fmtBytes(summary.added)}`],["可靠释放",`${summary.released ? "-" : ""}${fmtBytes(summary.released)}`],["已定位净变化",fmtBytes(summary.located)],[fourthLabel,fourthValue]].forEach(([label,value]) => {
    const metric = element("div","change-metric"); metric.append(element("span","",label),element("b","",value)); metrics.append(metric);
  });
  root.append(metrics);
  root.append(summary.comparable.length
    ? element("div","summary-note change-net-note",`实际净变化 ${fmtBytes(summary.actual)} · 已定位净变化 ${fmtBytes(summary.located)} · 未解释净变化 ${fmtBytes((Number(summary.actual)||0)-(Number(summary.located)||0))}`)
    : element("div","summary-note change-net-note","等待建立完整基线后显示净变化分解。"));
  root.append(element("div","change-explanation-note","目录解释率仅表示本次磁盘净变化可由一级目录变化归因的比例，不代表磁盘扫描比例；扫描限制见「扫描信息」"));
  root.append(element("div","reliability-badge",`${summary.comparable.length} / ${items.length} 个磁盘可可靠比较`));
}

function renderAttention(rankings) {
  const root = $("attention-list"); root.replaceChildren();
  const rows = [...rankings.growth,...rankings.release].sort((a,b) => Math.abs(Number(b.deltaBytes))-Math.abs(Number(a.deltaBytes)));
  const items = buildAttentionItems(DATA,DIRECTORY,rows);
  root.dataset.count = String(items.length);
  root.parentElement.classList.toggle("is-clear", items.length === 1 && items[0].kind === "clear");
  items.forEach((item) => {
    const link = element("a",`attention-item ${item.tone}${item.kind === "clear" ? " attention-empty" : ""}`);
    link.href = item.href;
    const marker = element("span","attention-marker","⚠");
    const label = element("span","attention-severity",item.tone === "critical" ? "高关注" : item.tone === "warning" ? "提醒" : "关注");
    const copy = element("span","attention-copy"); copy.append(element("b","",item.title),element("small","",item.detail));
    link.append(marker,element("span","attention-heading","关注中心"),label,copy,element("span","attention-arrow","查看详情"));
    root.append(link);
  });
}

function renderDirectoryChanges() {
  const driveFilter = $("change-drive-filter");
  if (!driveFilter.options.length) {
    driveFilter.add(new Option("全部磁盘", "all"));
    DIRECTORY.forEach((item) => driveFilter.add(new Option(item.drive, item.drive)));
  }
  const filters = currentChangeFilters();
  const items = selectedItems(filters);
  const rows = filterChangeRows(DIRECTORY, filters);
  const rankings = rankChanges(rows);
  const growth = rankings.growth.slice(0,5), release = rankings.release.slice(0,5);
  const maxMagnitude = Math.max(0,...growth.concat(release).map((row) => Math.abs(Number(row.deltaBytes))));
  const gross = rows.filter(isReliableChange).reduce((sum,row) => sum + Math.abs(Number(row.deltaBytes)),0);
  const waiting = items.length > 0 && items.every((item) => !item.baselineScanId);
  const reliableView = filters.state === "reliable";
  const lists = $("change-details").querySelector(".change-lists");
  lists.hidden = !reliableView;
  const onlyGrowth = reliableView && growth.length > 0 && release.length === 0;
  const onlyRelease = reliableView && release.length > 0 && growth.length === 0;
  const bothEmpty = reliableView && growth.length === 0 && release.length === 0;
  lists.classList.toggle("only-growth",onlyGrowth);
  lists.classList.toggle("only-release",onlyRelease);
  lists.classList.toggle("both-empty",bothEmpty);
  $("release-empty-note").hidden = !onlyGrowth;
  $("growth-empty-note").hidden = !onlyRelease;
  $("state-change-list").hidden = reliableView;
  if (reliableView) {
    [["growth-list",growth,"growth"],["release-list",release,"release"]].forEach(([id,list,kind]) => { const root=$(id); root.replaceChildren(); if(list.length) list.forEach((row)=>root.append(changeRowNode(row,maxMagnitude,gross))); else if (!bothEmpty || kind === "growth") root.append(element("div","baseline-guide",emptyChangeCopy({waiting,comparable:!waiting,kind:bothEmpty?"all":kind}))); });
  } else {
    $("state-change-title").textContent = filters.state === "unknown" ? "未知变化" : "不可用项目";
    const stateRoot=$("state-change-body"); stateRoot.replaceChildren();
    if(rows.length) rows.forEach((row)=>stateRoot.append(stateChangeRowNode(row))); else stateRoot.append(element("div","baseline-guide","当前筛选没有对应项目。"));
  }
  const summary = summarizeChanges(items,rows);
  renderChangeSummary(items,summary,rankings);
  renderConfidence(items);
  renderAttention(rankings);
}

function capacityStatusLabel(status) {
  return status === "critical" ? "严重" : status === "warning" ? "提醒" : "正常";
}

function renderCapacityDriveList() {
  const root = $("capacity-drive-select"); root.replaceChildren();
  capacityDriveOrder(DATA).forEach((drive) => {
    const id = normalizeDriveId(drive.id);
    const selected = id === state.capacityDrive;
    const button = element("button",`capacity-drive-row ${drive.status}${selected ? " is-selected" : ""}`);
    button.type = "button";
    button.dataset.capacityDrive = id;
    button.setAttribute("aria-pressed",String(selected));
    button.setAttribute("aria-label",`${id}，使用率 ${pct(drive.percent)}，已用 ${fmt(drive.used)}，剩余 ${fmt(drive.free)}，总容量 ${fmt(drive.total)}`);
    const head = element("span","capacity-drive-head");
    head.append(element("b","",id),element("span",`capacity-drive-state ${drive.status}`,capacityStatusLabel(drive.status)));
    head.append(element("span",`capacity-current${selected ? "" : " is-placeholder"}`,selected ? "当前" : "占位"));
    head.append(element("strong","",pct(drive.percent)));
    const bar = element("span","capacity-ratio-track");
    const fill = element("span","capacity-ratio-fill");
    fill.style.width = `${Math.max(0,Math.min(100,Number(drive.percent) || 0))}%`;
    bar.append(fill);
    const facts = element("span","capacity-drive-facts",`已用 ${fmt(drive.used)} · 剩余 ${fmt(drive.free)} · 总容量 ${fmt(drive.total)}`);
    button.append(head,bar,facts);
    root.append(button);
  });
  if (!DATA.length) root.append(element("p","capacity-empty","当前没有可显示的磁盘。"));
}

function capacityRangeLabel(range) {
  return range === "all" ? "全部历史" : `最近 ${range} 天`;
}

// Last viewBox width drawn, so the resize handler only redraws when the bucket changes.
let capacityChartWidth = 0;

function renderCapacityChart(samples, drive) {
  const root = $("capacity-trend-chart"); root.replaceChildren();
  const stats = capacityTrendStats(samples);
  if (!stats) {
    root.append(element("div","capacity-empty","当前范围没有有效容量样本。"));
    return;
  }
  // Draw at the host's real pixel width so SVG text keeps its declared size. A fixed 720-unit
  // viewBox scaled down to a narrow panel reduced axis labels to a few unreadable pixels.
  const measured = Math.round(root.clientWidth || 0) || 720;
  const width = Math.max(260, Math.min(720, measured));
  capacityChartWidth = width;
  const narrow = width < 520;
  const height = narrow ? 250 : 270, left = narrow ? 44 : 56, right = narrow ? 14 : 18, top = 24, bottom = narrow ? 34 : 38;
  const plotWidth = width-left-right, plotHeight = height-top-bottom;
  const minTime = stats.first.time, maxTime = stats.last.time;
  const rawSpan = stats.max-stats.min;
  const padding = rawSpan > 0 ? rawSpan*.12 : Math.max(1,stats.max*.04);
  const minUsed = Math.max(0,stats.min-padding), maxUsed = stats.max+padding;
  const x = (sample) => left + (maxTime === minTime ? plotWidth/2 : (sample.time-minTime)/(maxTime-minTime)*plotWidth);
  const y = (sample) => top + (maxUsed-sample.used)/(maxUsed-minUsed)*plotHeight;
  const svg = document.createElementNS(svgNs,"svg");
  svg.classList.add("capacity-svg");
  svg.setAttribute("viewBox",`0 0 ${width} ${height}`);
  svg.setAttribute("role","img");
  const titleId = "capacity-chart-title", descId = "capacity-chart-desc";
  svg.setAttribute("aria-labelledby",`${titleId} ${descId}`);
  const title = document.createElementNS(svgNs,"title"); title.id=titleId; title.textContent=`${drive.id} 已用容量历史趋势`;
  const desc = document.createElementNS(svgNs,"desc"); desc.id=descId; desc.textContent=`${capacityRangeLabel(state.capacityRange)}，${formatLocalDate(stats.first.timestamp)} 至 ${formatLocalDate(stats.last.timestamp)}，共 ${stats.count} 个有效样本。最新 ${fmt(stats.last.used)}，范围内最高 ${fmt(stats.max)}，最低 ${fmt(stats.min)}。`;
  svg.append(title,desc);
  const defs = document.createElementNS(svgNs,"defs");
  const gradient = document.createElementNS(svgNs,"linearGradient");
  gradient.id="capacity-area-gradient"; gradient.setAttribute("x1","0"); gradient.setAttribute("y1","0"); gradient.setAttribute("x2","0"); gradient.setAttribute("y2","1");
  [["0%",".24"],["100%",".02"]].forEach(([offset,opacity]) => { const stop=document.createElementNS(svgNs,"stop"); stop.setAttribute("offset",offset); stop.setAttribute("stop-color","var(--blue)"); stop.setAttribute("stop-opacity",opacity); gradient.append(stop); });
  defs.append(gradient); svg.append(defs);
  [0,.5,1].forEach((ratio) => {
    const line = document.createElementNS(svgNs,"line");
    const lineY = top+plotHeight*ratio;
    line.setAttribute("x1",String(left)); line.setAttribute("x2",String(width-right)); line.setAttribute("y1",String(lineY)); line.setAttribute("y2",String(lineY)); line.classList.add("capacity-grid-line"); svg.append(line);
    const label = document.createElementNS(svgNs,"text"); label.setAttribute("x",String(left-8)); label.setAttribute("y",String(lineY+4)); label.setAttribute("text-anchor","end"); label.classList.add("capacity-axis-label"); label.textContent=fmt(maxUsed-(maxUsed-minUsed)*ratio); svg.append(label);
  });
  const area = document.createElementNS(svgNs,"path");
  area.classList.add("capacity-area");
  area.setAttribute("d",`${samples.map((sample,index) => `${index ? "L" : "M"}${x(sample).toFixed(2)},${y(sample).toFixed(2)}`).join(" ")} L${x(samples[samples.length-1]).toFixed(2)},${top+plotHeight} L${x(samples[0]).toFixed(2)},${top+plotHeight} Z`);
  svg.append(area);
  const path = document.createElementNS(svgNs,"path");
  path.classList.add("capacity-line");
  path.setAttribute("d",samples.map((sample,index) => `${index ? "L" : "M"}${x(sample).toFixed(2)},${y(sample).toFixed(2)}`).join(" "));
  svg.append(path);
  samples.forEach((sample,index) => {
    const point = document.createElementNS(svgNs,"circle");
    point.classList.add("capacity-point");
    const isLatest = index === samples.length-1;
    if (isLatest) point.classList.add("is-latest");
    point.setAttribute("cx",x(sample).toFixed(2)); point.setAttribute("cy",y(sample).toFixed(2)); point.setAttribute("r",isLatest ? "4" : "2.4");
    const tooltip = document.createElementNS(svgNs,"title"); tooltip.textContent=`${isLatest ? "最新样本 " : ""}${formatLocalDate(sample.timestamp)} · ${fmt(sample.used)} · ${pct(sample.percent)}`; point.append(tooltip); svg.append(point);
  });
  [[left,stats.first.timestamp,"start"],[width-right,stats.last.timestamp,"end"]].forEach(([labelX,timestamp,anchor]) => {
    const label = document.createElementNS(svgNs,"text"); label.setAttribute("x",String(labelX)); label.setAttribute("y",String(height-10)); label.setAttribute("text-anchor",anchor); label.classList.add("capacity-axis-label"); label.textContent=formatLocalDate(timestamp).slice(0,10); svg.append(label);
  });
  root.append(svg);
  if (stats.count === 1) root.append(element("p","capacity-empty","样本不足，无法计算变化。"));
}

function renderCapacityVisuals() {
  if (!DATA.some((drive) => normalizeDriveId(drive.id) === state.capacityDrive)) state.capacityDrive = defaultCapacityDrive(DATA,SYSTEM_DRIVE);
  renderCapacityDriveList();
  document.querySelectorAll("[data-capacity-range]").forEach((button) => button.setAttribute("aria-pressed",String(button.dataset.capacityRange === state.capacityRange)));
  const drive = DATA.find((item) => normalizeDriveId(item.id) === state.capacityDrive);
  const statsRoot = $("capacity-trend-stats"); statsRoot.replaceChildren();
  if (!drive) {
    $("capacity-trend-caption").textContent = "当前没有可显示的磁盘";
    $("capacity-trend-chart").replaceChildren(element("div","capacity-empty","当前没有可显示的磁盘。"));
    $("print-meta").textContent = `报告生成时间：${TS} · 无可用容量趋势`;
    return;
  }
  const allSamples = cleanCapacitySamples(HISTORY,drive,state.capacityDrive,TS);
  const samples = filterCapacitySamples(allSamples,state.capacityRange,TS);
  const stats = capacityTrendStats(samples);
  $("capacity-trend-caption").textContent = `${state.capacityDrive} · ${capacityRangeLabel(state.capacityRange)}`;
  statsRoot.className="capacity-trend-stats trend-summary";
  const statValues = stats
    ? [["当前使用",fmt(drive.used)],["总容量",fmt(drive.total)],["可用容量",fmt(drive.free)],
       ["较范围起点",stats.change === null ? "样本不足" : `${stats.change >= 0 ? "+" : ""}${fmt(stats.change)}`],
       ["范围内最高",fmt(stats.max)],["范围内最低",fmt(stats.min)]]
    : [["当前使用","—"],["总容量","—"],["可用容量","—"],["较范围起点","—"],["范围内最高","—"],["范围内最低","—"]];
  statValues.forEach(([label,value]) => { const card=element("div","capacity-stat"); card.append(element("span","",label),element("b","",value)); statsRoot.append(card); });
  renderCapacityChart(samples,drive);
  const rangeText = stats ? `${formatLocalDate(stats.first.timestamp)} 至 ${formatLocalDate(stats.last.timestamp)} · ${stats.count} 个有效样本` : "当前范围没有有效样本";
  $("print-meta").textContent = `报告生成时间：${TS} · 趋势磁盘：${state.capacityDrive} · ${rangeText}`;
}

function miniNode(label,value,previous) {
  const root=element("div","mini"); root.append(element("span","",label),element("b","",value)); if(previous !== null) root.append(element("small","",`上次 ${previous}`)); return root;
}

function topPathNode(row,maxMagnitude) {
  const root=element("div","top-path-row"), path=element("span","top-path-name expandable-path",row.displayPath); path.title=String(row.displayPath ?? "");
  const valueClass=row.deltaBytes>=0?"growth-value":"release-value"; root.append(path,element("b",valueClass,`${row.deltaBytes>=0?"+":""}${fmtBytes(row.deltaBytes)}`));
  const copy=element("button","copy-path","复制"); copy.type="button"; copy.dataset.copyPath=String(row.displayPath ?? ""); copy.setAttribute("aria-label",`复制路径 ${row.displayPath}`); root.append(copy);
  const track=element("span",`intensity-track ${valueClass}`),fill=element("span","intensity-fill"); const intensity=maxMagnitude?Math.max(4,Math.abs(Number(row.deltaBytes))/maxMagnitude*100):0; fill.style.setProperty("--intensity",`${Math.max(0,Math.min(100,intensity)).toFixed(1)}%`); track.append(fill); root.append(track); return root;
}

function evidenceGroupNode(title,rows) {
  const root=element("div","detail-group"); root.append(element("b","",title));
  if(rows.length){ const list=element("ul"); rows.forEach((item)=>{ const row=element("li","",`${item.path} · ${item.reason}`); row.title=String(item.path ?? ""); list.append(row); }); root.append(list); }
  else root.append(element("p","","无")); return root;
}

function renderCards() {
  const drives = sortedDrives(), grid=$("grid");
  $("empty").style.display = drives.length ? "none" : "block";
  grid.replaceChildren();
  drives.forEach((d) => {
    const rows=historyFor(d.id),lastSeen=rows.length?rows[rows.length-1].Timestamp:TS,prev=rows.length>=2?rows[rows.length-2]:null;
    const directory=DIRECTORY.find((item)=>normalizeDriveId(item.drive)===normalizeDriveId(d.id)),coverage=directoryCoverage(d.id),topThree=directoryTopThree(d.id);
    const topThreeMax=Math.max(0,...topThree.map((row)=>Math.abs(Number(row.deltaBytes)))),detailLevel=Number(state.driveLevels[d.id]||1);
    const topTen=reliableChanges(directory,detailLevel).sort((a,b)=>Math.abs(b.deltaBytes)-Math.abs(a.deltaBytes)).slice(0,10),trendRows=directoryTrendRows(d.id,detailLevel),detailMax=Math.max(0,...topTen.map((row)=>Math.abs(Number(row.deltaBytes))));
    const scanEvidence=classifyScanEvidence(directory?[directory]:[]),cardStatus=!directory?.baselineScanId?"waiting":directory.status==="failed"?"failed":directory.status==="partial"?"partial":"complete";
    const activityLabel=coverage?.activityPreferred?`活动总量 ${fmtBytes(Number(coverage.addedBytes||0)+Number(coverage.releasedBytes||0))}`:`目录解释率 ${directory?coverageLabel(directory):"-"}`; const activityEl=element("span","",activityLabel); activityEl.title="解释率/活动总量 = 本次净变化归因比例，不代表扫描比例；扫描限制见「扫描信息」。";
    const card=element("article",`card ${d.status}`);
    const top=element("div","card-top"),heading=element("div"); heading.append(element("div","drive-name",`磁盘 ${normalizeDriveId(d.id)}`),element("div","drive-sub",`最近采样 ${lastSeen}`));
    const actions=element("div","card-top-actions"); actions.append(element("span",`status-badge ${cardStatus}`,directory?statusLabel(directory.status,directory.baselineScanId):"未扫描"),element("div","badge",`使用率 ${pct(d.percent)}`)); top.append(heading,actions); card.append(top);
    const bar=element("div","bar-track"),fill=element("div","bar-fill"); fill.dataset.w=`${Math.max(0,Math.min(100,Number(d.percent)||0))}%`; bar.append(fill); card.append(bar);
    const meta=element("div","meta"); meta.append(miniNode("已用",fmt(d.used),prev?fmt(prev.Used):null),miniNode("剩余",fmt(d.free),prev?fmt(prev.Free):null),miniNode("总量",fmt(d.total),prev?fmt(prev.Total):null)); card.append(meta);
    const spark=element("div","spark-row"),trendCopy=element("div"),trendLine=element("div"),estimate=element("div","",estimateDays(d,rows)); trendLine.append(trend(d.diff)); trendCopy.append(trendLine,estimate); spark.append(sparkline(rows),trendCopy); card.append(spark);
    const extra=element("div","directory-card-extra"); extra.append(element("b","",directory?.baselineScanId?`目录净变化 ${fmtBytes(coverage?.actualNetBytes)}`:"当前目录规模已记录"),activityEl);
    if(topThree.length){ const paths=element("div","top-paths"); topThree.forEach((row)=>paths.append(topPathNode(row,topThreeMax))); extra.append(paths); } else extra.append(element("p","",directory?.baselineScanId?"本次没有可靠目录变化。":"建立完整基线后显示目录变化 Top 3。")); card.append(extra);
    const details=element("details","drive-details"); details.append(element("summary","","展开目录与扫描详情")); const body=element("div","drive-details-body");
    const levelLabel=element("label","","目录层级 "),levelSelect=element("select","select drive-level-switch"); levelSelect.dataset.drive=d.id; [[1,"一级目录"],[2,"二级目录"]].forEach(([value,label])=>{ const option=element("option","",label); option.value=String(value); option.selected=detailLevel===value; levelSelect.append(option); }); levelLabel.append(levelSelect); body.append(levelLabel);
    const detailPaths=element("div","top-paths"); if(topTen.length) topTen.forEach((row)=>detailPaths.append(topPathNode(row,detailMax))); else detailPaths.append(element("p","",emptyChangeCopy({waiting:!directory?.baselineScanId,comparable:Boolean(directory?.baselineScanId),kind:"all"}))); body.append(detailPaths);
    const trends=element("div","directory-trends"); trends.append(element("b","","目录历史序列")); if(trendRows.length) trendRows.forEach((row)=>trends.append(historyTrendNode(row))); else trends.append(element("p","history-empty","历史样本不足，暂无可展示序列。")); body.append(trends);
    const groups=element("div","detail-groups"); groups.append(evidenceGroupNode("按设计忽略",scanEvidence.designedIgnored),evidenceGroupNode("权限受限",scanEvidence.permissionLimited),evidenceGroupNode("扫描期间消失",scanEvidence.transientMissing),evidenceGroupNode("意外不可用",scanEvidence.unexpected)); body.append(groups,element("p","",`基线时间：${directory?.baselineCompletedAt||"等待完整基线"} · 扫描执行：${directory?statusLabel(directory.status,directory.baselineScanId):"未扫描"}`));
    const detailSpark=element("div"); detailSpark.append(sparkline(rows)); body.append(detailSpark); details.append(body); card.append(details); grid.append(card);
  });
  requestAnimationFrame(() => {
    document.querySelectorAll(".bar-fill").forEach((bar) => {
      bar.style.width = bar.dataset.w;
    });
  });
}

function renderScanCompleteness() {
  const {designedIgnored,permissionLimited,transientMissing,unexpected} = classifyScanEvidence(DIRECTORY);
  const root = $("scan-detail-body"); root.replaceChildren();
  const grid = element("div","scan-completeness-grid");
  const addGroup = (title,description,rows,empty) => {
    const group = element("div","detail-group"); group.append(element("h3","",title),element("p","",description));
    if (rows.length) {
      const list = element("ul");
      rows.forEach((row) => { const item=element("li","",`${row.drive} · ${row.path} · ${row.reason}`); item.title=String(row.path ?? ""); list.append(item); });
      group.append(list);
    } else group.append(element("p","",empty));
    grid.append(group);
  };
  // Execution status (扫描完成/部分完成/失败) is shown on each disk; these groups are the
  // "scan limitations / visibility" axis and must NOT be folded into the execution badge.
  addGroup("按设计忽略","重解析点、联接、符号链接、$RECYCLE.BIN 和 System Volume Information 属于正常忽略，不是扫描限制。",designedIgnored,"没有记录到按设计忽略项。");
  addGroup("扫描限制 · 权限受限","这些路径因权限限制无法枚举，属于扫描限制而非扫描错误；常见于 Windows 系统区域。",permissionLimited,"没有权限受限路径。");
  addGroup("扫描限制 · 扫描期间消失","扫描时这些路径已不存在（扫描过程中被删除或移动），属于瞬时变化，不判定为扫描失败。",transientMissing,"扫描期间没有路径消失。");
  addGroup("意外不可用","其它枚举失败或不可用路径，可能影响结果完整性。",unexpected,"没有意外不可用项目。");
  root.append(grid);
}

function renderScanMetadata() {
  const start = SCAN_META.startedAt ? new Date(SCAN_META.startedAt) : null;
  const end = SCAN_META.completedAt ? new Date(SCAN_META.completedAt) : null;
  const duration = start && end ? `${Math.max(0,Math.round((end-start)/1000))} 秒` : "-";
  const fields = [["扫描开始",formatLocalDate(SCAN_META.startedAt),SCAN_META.startedAt||"-"],["扫描完成",formatLocalDate(SCAN_META.completedAt),SCAN_META.completedAt||"-"],["总耗时",duration,duration],["扫描磁盘",`${Number(SCAN_META.driveCount||0)} 个`,`${Number(SCAN_META.driveCount||0)} 个`]];
  // Credibility belongs next to the scan facts (see DESIGN.md 扫描信息). Surface the same
  // aggregate verdict the comparison-confidence card uses, plus how many paths were excluded or
  // limited, so the verdict is readable without opening 查看扫描详情. No new judgement is made here.
  const evidence = classifyScanEvidence(DIRECTORY);
  const integrityLabels = { complete:"完整", partial:"部分完成", failed:"失败", waiting:"等待基线" };
  const integrity = integrityLabels[confidenceFor(DIRECTORY).state] || "等待基线";
  const limitationCount = evidence.permissionLimited.length + evidence.transientMissing.length + evidence.unexpected.length;
  fields.push(["扫描完整性",integrity,"各磁盘扫描执行状态与可比性的综合判断。"]);
  fields.push(["排除与受限",`忽略 ${evidence.designedIgnored.length} · 受限 ${limitationCount}`,"按设计忽略项与受限项数量；详见「查看扫描详情」。"]);
  // A drive letter that resolves to a volume already counted (a SUBST-style alias) is skipped so the
  // same capacity is not added twice. Say so: a letter that silently disappears would look like a
  // failed scan. Only rendered when it actually happened. The field is normally a list; a single
  // record is also accepted because older builds serialized one-element lists as a bare object.
  const rawAliases = SCAN_META.driveAliases;
  const aliasList = Array.isArray(rawAliases) ? rawAliases : (rawAliases && rawAliases.id ? [rawAliases] : []);
  const aliasNote = aliasList
    .filter((alias) => alias && alias.id)
    .map((alias) => `${String(alias.id)} 与 ${String(alias.aliasOf||"?")} 同卷，未重复统计`);
  if (aliasNote.length) { fields.push(["同卷别名",aliasNote.join("；"),"这些盘符指向已经统计过的卷，已跳过以避免容量被重复计算。"]); }
  const scanId = String(SCAN_META.scanId||"-");
  const root = $("scan-metadata"); root.className="scan-metadata scan-summary-card"; root.replaceChildren();
  fields.forEach(([label,value,title]) => { const item=element("div","metadata-item"); const strong=element("b","",value); strong.title=String(title); item.append(element("span","",label),strong); root.append(item); });
  const item = element("div","metadata-item"); item.append(element("span","","快照 ID"));
  const value = element("div","snapshot-value"); const strong=element("b","",shortSnapshotId(scanId)); strong.title=scanId;
  const copy = element("button","copy-path snapshot-copy","复制"); copy.type="button"; copy.dataset.copyPath=scanId; copy.setAttribute("aria-label","复制快照 ID");
  value.append(strong,copy); item.append(value); root.append(item);
}

function render() {
  document.body.classList.toggle("compact", state.compact);
  renderCapacitySummary();
  renderDirectoryChanges();
  renderAIAnalysis();
  renderCapacityVisuals();
  renderHistoryCenter();
  renderCards();
  renderScanCompleteness();
  renderScanMetadata();
}

function openHistoryFromHash() {
  const hash = location.hash;
  if (hash === "#history-center" || hash === "#history-details") {
    const details = $("history-details");
    if (details) details.open = true;
    return;
  }
  // The attention centre links straight at the collapsed scan-details block; without this the
  // user lands on a closed summary and has to click a second time to see the reason.
  if (hash === "#scan-completeness") {
    const scanDetails = $("scan-completeness");
    if (scanDetails) scanDetails.open = true;
  }
}

["change-drive-filter","change-level-filter","change-direction-filter","change-state-filter"].forEach((id) => $(id).addEventListener("change", renderDirectoryChanges));
$("change-path-filter").addEventListener("input", renderDirectoryChanges);
$("history-range").addEventListener("change", (event) => { state.historyRange = event.target.value; renderHistoryCenter(); });
document.addEventListener("click", async (event) => {
  const capacityDrive = event.target.closest("[data-capacity-drive]");
  if (capacityDrive) {
    state.capacityDrive = normalizeDriveId(capacityDrive.dataset.capacityDrive);
    renderCapacityVisuals();
    announce(`已选择 ${state.capacityDrive} 容量趋势`);
    return;
  }
  const capacityRange = event.target.closest("[data-capacity-range]");
  if (capacityRange) {
    state.capacityRange = capacityRange.dataset.capacityRange;
    renderCapacityVisuals();
    announce(`已切换为${capacityRangeLabel(state.capacityRange)}`);
    return;
  }
  const historyTab = event.target.closest("[data-history-tab]");
  if (historyTab) {
    state.historyTab = historyTab.dataset.historyTab;
    renderHistoryCenter();
    return;
  }
  const historyExpand = event.target.closest(".history-expand");
  if (historyExpand) {
    const list = historyExpand.dataset.historyList;
    state.historyExpanded[list] = !state.historyExpanded[list];
    renderHistoryCenter();
    return;
  }
  const button = event.target.closest(".copy-path");
  if (button) {
    const path = button.dataset.copyPath;
    copyText(path).then((ok) => {
      if (!ok) return;
      const old = button.textContent;
      button.textContent = "已复制";
      announce("已复制到剪贴板");
      setTimeout(() => { button.textContent = old; }, 1200);
    });
    return;
  }
  const path = event.target.closest(".expandable-path");
  if (path && window.matchMedia("(max-width: 560px)").matches) path.classList.toggle("is-expanded");
});
document.addEventListener("change", (event) => {
  const customBaseline = event.target.closest(".history-custom-baseline");
  if (customBaseline) {
    state.historyCustom[customBaseline.dataset.drive] = customBaseline.value;
    renderHistoryCenter();
    return;
  }
  const level = event.target.closest(".drive-level-switch");
  if (!level) return;
  state.driveLevels[level.dataset.drive] = level.value;
  renderCards();
});

$("search").addEventListener("input", (event) => {
  state.query = event.target.value;
  renderCards();
});

$("sort").addEventListener("change", (event) => {
  state.sort = event.target.value;
  renderCards();
});

$("compact").addEventListener("change", (event) => {
  state.compact = event.target.checked;
  render();
});

$("themeBtn").addEventListener("click", () => {
  var current = document.documentElement.getAttribute("data-theme");
  var next = current === "dark" ? "light" : "dark";
  document.documentElement.setAttribute("data-theme", next);
  localStorage.setItem("diskpulse-theme", next);
  $("themeBtn").textContent = next === "dark" ? " 浅色" : " 深色";
  $("themeBtn").setAttribute("aria-label",next === "dark" ? "切换到浅色主题" : "切换到深色主题");
  announce(next === "dark" ? "已切换到深色主题" : "已切换到浅色主题");
});

(function() {
  var t = document.documentElement.getAttribute("data-theme");
  $("themeBtn").textContent = t === "dark" ? " 浅色" : " 深色";
  $("themeBtn").setAttribute("aria-label",t === "dark" ? "切换到浅色主题" : "切换到深色主题");
})();

$("print-report").addEventListener("click", () => window.print());

// Redraw the trend chart when the panel crosses a width bucket, so the viewBox keeps matching
// the rendered size and axis labels stay at their declared size instead of shrinking.
window.addEventListener("resize", () => {
  const root = $("capacity-trend-chart");
  if (!root || !root.clientWidth) return;
  const next = Math.max(260, Math.min(720, Math.round(root.clientWidth)));
  if (next === capacityChartWidth) return;
  renderCapacityVisuals();
});

window.addEventListener("hashchange",openHistoryFromHash);
openHistoryFromHash();

async function copyText(text) {
  const value = String(text ?? "");
  if (!value) return true;
  try {
    if (navigator.clipboard && navigator.clipboard.writeText) {
      await navigator.clipboard.writeText(value);
      return true;
    }
  } catch (e) {}
  try {
    const ta = document.createElement("textarea");
    ta.value = value;
    ta.setAttribute("readonly", "");
    ta.style.position = "fixed";
    ta.style.top = "0";
    ta.style.left = "0";
    ta.style.opacity = "0";
    document.body.appendChild(ta);
    ta.focus();
    ta.select();
    ta.setSelectionRange(0, ta.value.length);
    const ok = document.execCommand && document.execCommand("copy");
    document.body.removeChild(ta);
    if (ok) return true;
  } catch (e) {}
  return showAiCopyModal(value);
}

function showAiCopyModal(text) {
  const overlay = document.createElement("div");
  overlay.className = "copy-modal-overlay";
  const box = document.createElement("div");
  box.className = "copy-modal";
  const hint = element("div", "copy-modal-hint", "未能自动复制，请全选后 Ctrl+C 手动复制，然后关闭。");
  const ta = element("textarea", "copy-modal-text", text);
  ta.setAttribute("readonly", "");
  const close = element("button", "button", "关闭");
  close.type = "button";
  close.addEventListener("click", () => { if (overlay.parentNode) overlay.parentNode.removeChild(overlay); });
  box.append(hint, ta, close);
  overlay.append(box);
  overlay.addEventListener("click", (e) => { if (e.target === overlay && overlay.parentNode) overlay.parentNode.removeChild(overlay); });
  document.body.appendChild(overlay);
  ta.focus();
  ta.select();
  ta.setSelectionRange(0, ta.value.length);
  return false;
}

function buildAiResultCopyText() {
  const a = AI_ANALYSIS || {};
  if (a.rawText) return String(a.rawText);
  if (a.format === "structured" && a.analysis) {
    const an = a.analysis;
    const lines = [];
    if (an.summary) lines.push(String(an.summary));
    if (an.possibleCauses && an.possibleCauses.length) { lines.push("", "最可能的原因"); an.possibleCauses.forEach((x) => lines.push("· " + String(x))); }
    if (an.evidence && an.evidence.length) { lines.push("", "证据"); an.evidence.forEach((x) => lines.push("· " + String(x))); }
    if (an.recommendations && an.recommendations.length) { lines.push("", "建议怎么处理"); an.recommendations.forEach((x) => lines.push("· " + String(x))); }
    if (an.cautions && an.cautions.length) { lines.push("", "证据边界"); an.cautions.forEach((x) => lines.push("· " + String(x))); }
    if (an.confidence) lines.push("", "可信度：" + (an.confidence === "high" ? "高" : an.confidence === "medium" ? "中等" : "低"));
    if (a.model) lines.push("模型：" + a.model + (a.generatedAt ? " · " + formatLocalDate(a.generatedAt) : ""));
    return lines.join("\n");
  }
  return "";
}

$("copy-ai-input").addEventListener("click", async () => {
  const ok = await copyText(AI_COPY_TEXT);
  if (!ok) return;
  const btn = $("copy-ai-input");
  const old = btn.textContent;
  btn.textContent = "已复制";
  announce("分析数据已复制到剪贴板");
  setTimeout(() => { btn.textContent = old; }, 1400);
});

$("copy-ai-output").addEventListener("click", async () => {
  const ok = await copyText(buildAiResultCopyText());
  if (!ok) return;
  const btn = $("copy-ai-output");
  const old = btn.textContent;
  btn.textContent = "已复制";
  announce("AI 分析结果已复制到剪贴板");
  setTimeout(() => { btn.textContent = old; }, 1400);
});

$("copy").addEventListener("click", async () => {
  const t = totals();
  const lines = [
    `磁盘容量看板 ${TS}`,
    `总容量 ${fmt(t.total)} / 已用 ${fmt(t.used)} / 剩余 ${fmt(t.free)}`,
    ...DATA.map((d) => `${d.id} 使用率 ${pct(d.percent)}，剩余 ${fmt(d.free)}，本次${(Number(d.diff) || 0) >= 0 ? "增加" : "减少"} ${fmt(Math.abs(Number(d.diff) || 0))}`)
  ];
  const ok = await copyText(lines.join("\n"));
  if (!ok) return;
  $("copy").textContent = "已复制";
  announce("磁盘摘要已复制到剪贴板");
  setTimeout(() => $("copy").textContent = "复制磁盘摘要", 1400);
});

document.addEventListener("keydown", (e) => {
  if (e.target.tagName === "INPUT" || e.target.tagName === "SELECT") return;
  if (e.key === "c" || e.key === "C") {
    state.compact = !state.compact;
    $("compact").checked = state.compact;
    render();
  }
});

render();
