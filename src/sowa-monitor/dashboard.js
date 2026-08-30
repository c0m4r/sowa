"use strict";

const $ = (id) => document.getElementById(id);
const history = { cpu: [], memory: [] };
const HISTORY_LIMIT = 60;
let failures = 0;

function number(value, fallback = 0) {
  const parsed = Number(value);
  return Number.isFinite(parsed) ? parsed : fallback;
}

function formatBytes(value, perSecond = false) {
  let bytes = Math.max(0, number(value));
  const units = ["B", "KiB", "MiB", "GiB", "TiB", "PiB"];
  let index = 0;
  while (bytes >= 1024 && index < units.length - 1) { bytes /= 1024; index += 1; }
  const digits = bytes >= 100 || index === 0 ? 0 : bytes >= 10 ? 1 : 2;
  return `${bytes.toFixed(digits)} ${units[index]}${perSecond ? "/s" : ""}`;
}

function formatDuration(seconds) {
  const total = Math.max(0, Math.floor(number(seconds)));
  const days = Math.floor(total / 86400);
  const hours = Math.floor((total % 86400) / 3600);
  const minutes = Math.floor((total % 3600) / 60);
  if (days) return `Up ${days}d ${hours}h`;
  if (hours) return `Up ${hours}h ${minutes}m`;
  return `Up ${minutes}m`;
}

function setText(id, value) { const node = $(id); if (node) node.textContent = String(value); }
function setMeter(id, value) { const node = $(id); if (node) node.style.width = `${Math.max(0, Math.min(100, number(value)))}%`; }

function renderStorage(filesystems) {
  const list = $("storage-list");
  list.replaceChildren();
  setText("filesystem-count", `${filesystems.length} volume${filesystems.length === 1 ? "" : "s"}`);
  if (!filesystems.length) {
    const empty = document.createElement("p"); empty.className = "empty"; empty.textContent = "No physical filesystems are visible."; list.append(empty); return;
  }
  for (const filesystem of filesystems) {
    const row = document.createElement("div"); row.className = "storage-row";
    const name = document.createElement("div"); name.className = "storage-name";
    const strong = document.createElement("strong"); strong.textContent = filesystem.mountpoint;
    const small = document.createElement("small"); small.textContent = `${filesystem.type}${filesystem.read_only ? " · read only" : ""}`;
    name.append(strong, small);
    const bar = document.createElement("div"); bar.className = "storage-bar";
    const fill = document.createElement("span");
    const used = number(filesystem.used_percent);
    fill.style.width = `${Math.min(100, used)}%`;
    if (used >= 97) fill.className = "critical"; else if (used >= 90) fill.className = "warning";
    bar.append(fill);
    const size = document.createElement("div"); size.className = "storage-size"; size.textContent = `${used.toFixed(1)}% · ${formatBytes(filesystem.available_bytes)} free`;
    row.append(name, bar, size); list.append(row);
  }
}

function renderProcesses(processes) {
  const list = $("process-list"); list.replaceChildren();
  for (const process of processes.top_memory || []) {
    const row = document.createElement("div"); row.className = "process-row";
    const main = document.createElement("div"); main.className = "process-main";
    const name = document.createElement("strong"); name.textContent = process.name;
    const detail = document.createElement("small"); detail.textContent = `PID ${process.pid} · state ${process.state}`;
    main.append(name, detail);
    const size = document.createElement("span"); size.className = "process-size"; size.textContent = formatBytes(process.rss_bytes);
    row.append(main, size); list.append(row);
  }
  if (!list.childElementCount) { const empty = document.createElement("p"); empty.className = "empty"; empty.textContent = "No process details are visible."; list.append(empty); }
}

function renderServices(services) {
  const list = $("service-list"); list.replaceChildren();
  const active = services.active || [];
  setText("service-count", `${number(services.active_count)} active`);
  for (const service of active) {
    const chip = document.createElement("span"); chip.className = "service-chip"; chip.textContent = service; list.append(chip);
  }
  if (!active.length) { const empty = document.createElement("p"); empty.className = "empty"; empty.textContent = "No services are marked active."; list.append(empty); }
}

function drawChart() {
  const canvas = $("pulse-chart");
  const bounds = canvas.getBoundingClientRect();
  const ratio = Math.min(window.devicePixelRatio || 1, 2);
  canvas.width = Math.max(1, Math.floor(bounds.width * ratio));
  canvas.height = Math.max(1, Math.floor(bounds.height * ratio));
  const context = canvas.getContext("2d");
  context.scale(ratio, ratio);
  const width = bounds.width, height = bounds.height;
  const pad = { top: 9, right: 8, bottom: 22, left: 30 };
  const chartWidth = width - pad.left - pad.right, chartHeight = height - pad.top - pad.bottom;
  context.font = "9px ui-monospace, monospace";
  context.textAlign = "right";
  context.textBaseline = "middle";
  for (const value of [0, 25, 50, 75, 100]) {
    const y = pad.top + chartHeight - (value / 100) * chartHeight;
    context.strokeStyle = "rgba(217,235,226,.075)"; context.lineWidth = 1;
    context.beginPath(); context.moveTo(pad.left, y); context.lineTo(width - pad.right, y); context.stroke();
    context.fillStyle = "#71837c"; context.fillText(String(value), pad.left - 8, y);
  }
  const drawSeries = (values, stroke, fill) => {
    if (!values.length) return;
    const points = values.map((value, index) => ({ x: pad.left + (index / Math.max(1, HISTORY_LIMIT - 1)) * chartWidth, y: pad.top + chartHeight - (number(value) / 100) * chartHeight }));
    context.beginPath(); context.moveTo(points[0].x, points[0].y); for (const point of points.slice(1)) context.lineTo(point.x, point.y);
    context.lineTo(points[points.length - 1].x, pad.top + chartHeight); context.lineTo(points[0].x, pad.top + chartHeight); context.closePath();
    const gradient = context.createLinearGradient(0, pad.top, 0, pad.top + chartHeight); gradient.addColorStop(0, fill); gradient.addColorStop(1, "rgba(0,0,0,0)"); context.fillStyle = gradient; context.fill();
    context.beginPath(); context.moveTo(points[0].x, points[0].y); for (const point of points.slice(1)) context.lineTo(point.x, point.y);
    context.strokeStyle = stroke; context.lineWidth = 1.8; context.lineJoin = "round"; context.stroke();
  };
  drawSeries(history.memory, "#75b7ff", "rgba(117,183,255,.18)");
  drawSeries(history.cpu, "#73e2b7", "rgba(115,226,183,.16)");
  context.textAlign = "left"; context.fillStyle = "#71837c"; context.fillText("now", width - 25, height - 7);
}

function render(data) {
  const root = (data.filesystems || []).find((filesystem) => filesystem.mountpoint === "/") || (data.filesystems || [])[0] || {};
  setText("hostname", data.system.hostname || "Sowa host");
  setText("os-name", `${data.system.name || "Sowa Linux"} ${data.system.version || ""}`.trim());
  setText("uptime", formatDuration(data.system.uptime_seconds));
  setText("kernel", data.system.kernel || "—"); setText("architecture", data.system.architecture || "—");
  setText("package-count", number(data.system.installed_packages).toLocaleString());
  setText("process-count", number(data.processes.total).toLocaleString());
  const temperatures = data.temperatures || [];
  setText("temperature", temperatures.length ? `${Math.max(...temperatures.map((item) => number(item.celsius))).toFixed(1)} °C` : "Unavailable");

  const cpu = number(data.cpu.used_percent), memory = number(data.memory.used_percent), disk = number(root.used_percent);
  setText("cpu-value", cpu.toFixed(1)); setMeter("cpu-meter", cpu); setText("load-value", number(data.cpu.load?.[0]).toFixed(2)); setText("core-count", number(data.cpu.cores));
  setText("memory-value", memory.toFixed(1)); setMeter("memory-meter", memory); setText("memory-used", formatBytes(data.memory.used_bytes)); setText("memory-total", formatBytes(data.memory.total_bytes));
  setText("disk-value", disk.toFixed(1)); setMeter("disk-meter", disk); setText("disk-free", root.available_bytes === undefined ? "—" : formatBytes(root.available_bytes));
  setText("network-in", formatBytes(data.network.rx_bytes_per_second, true)); setText("network-out", formatBytes(data.network.tx_bytes_per_second, true)); setText("interface-count", (data.network.interfaces || []).length);
  setText("running-processes", number(data.processes.running)); setText("sleeping-processes", number(data.processes.sleeping)); setText("blocked-processes", number(data.processes.blocked)); setText("zombie-processes", number(data.processes.zombie));

  const health = ["healthy", "attention", "critical"].includes(data.health) ? data.health : "attention";
  const pill = $("health-pill"); pill.className = `health-pill ${health}`; setText("health-label", health === "healthy" ? "All nominal" : health === "attention" ? "Needs attention" : "Critical");
  const collected = new Date(data.collected_at); setText("updated-at", Number.isNaN(collected.valueOf()) ? "just now" : collected.toLocaleTimeString([], { hour: "2-digit", minute: "2-digit", second: "2-digit" }));

  renderStorage(data.filesystems || []); renderProcesses(data.processes || {}); renderServices(data.services || {});
  history.cpu.push(cpu); history.memory.push(memory); if (history.cpu.length > HISTORY_LIMIT) history.cpu.shift(); if (history.memory.length > HISTORY_LIMIT) history.memory.shift(); drawChart();
}

function connectionState(online) {
  const dot = $("connection-dot"); dot.className = `pulse-dot ${online ? "online" : "offline"}`; setText("connection-label", online ? "Live" : "Reconnecting");
  $("error-toast").classList.toggle("visible", !online && failures > 1);
}

async function refresh() {
  try {
    const response = await fetch("api/v1/summary", { cache: "no-store", headers: { Accept: "application/json" } });
    if (!response.ok) throw new Error(`HTTP ${response.status}`);
    render(await response.json()); failures = 0; connectionState(true);
  } catch (_error) { failures += 1; connectionState(false); }
}

window.addEventListener("resize", drawChart);
document.addEventListener("visibilitychange", () => { if (!document.hidden) refresh(); });
refresh();
window.setInterval(refresh, 2000);
