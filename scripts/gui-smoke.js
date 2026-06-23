import { spawn } from "node:child_process";
import { mkdir, rm, writeFile } from "node:fs/promises";
import { existsSync } from "node:fs";
import { join, resolve } from "node:path";
import { tmpdir } from "node:os";

const chromeCandidates = [
  "C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe",
  "C:\\Program Files (x86)\\Google\\Chrome\\Application\\chrome.exe",
  join(process.env.LOCALAPPDATA ?? "", "Google\\Chrome\\Application\\chrome.exe"),
  "C:\\Program Files\\Microsoft\\Edge\\Application\\msedge.exe",
  "C:\\Program Files (x86)\\Microsoft\\Edge\\Application\\msedge.exe"
];

const chromePath = chromeCandidates.find((candidate) => candidate && existsSync(candidate));
if (!chromePath) {
  throw new Error("No Chrome or Edge executable found for GUI smoke verification.");
}

const root = resolve(".");
const userDataDir = join(tmpdir(), `hardware-truth-scanner-smoke-${Date.now()}`);
const debugPort = 9227;
await mkdir(userDataDir, { recursive: true });

const chrome = spawn(chromePath, [
  "--headless=new",
  `--remote-debugging-port=${debugPort}`,
  `--user-data-dir=${userDataDir}`,
  "--disable-gpu",
  "--no-first-run",
  "--no-default-browser-check",
  "about:blank"
], {
  stdio: "ignore",
  windowsHide: true
});

let socket;
let messageId = 0;
const pending = new Map();
const runtimeEvents = [];

function wait(ms) {
  return new Promise((resolveWait) => setTimeout(resolveWait, ms));
}

async function fetchJson(url, attempts = 50) {
  let lastError;
  for (let attempt = 0; attempt < attempts; attempt += 1) {
    try {
      const response = await fetch(url);
      if (response.ok) return response.json();
      lastError = new Error(`${url} returned ${response.status}`);
    } catch (error) {
      lastError = error;
    }
    await wait(200);
  }
  throw lastError;
}

function send(method, params = {}, sessionId = undefined) {
  const id = ++messageId;
  socket.send(JSON.stringify({ id, method, params, sessionId }));
  return new Promise((resolveSend, reject) => {
    pending.set(id, { resolve: resolveSend, reject });
  });
}

try {
  await fetchJson(`http://127.0.0.1:${debugPort}/json/version`);
  const pageTargetResponse = await fetch(`http://127.0.0.1:${debugPort}/json/new?about:blank`, {
    method: "PUT"
  });
  if (!pageTargetResponse.ok) {
    throw new Error(`Chrome did not create GUI page target: ${pageTargetResponse.status}`);
  }
  const pageTarget = await pageTargetResponse.json();
  socket = new WebSocket(pageTarget.webSocketDebuggerUrl);

  socket.addEventListener("message", (event) => {
    const message = JSON.parse(event.data);
    if (!message.id) {
      if (
        message.method === "Runtime.exceptionThrown" ||
        message.method === "Runtime.consoleAPICalled" ||
        message.method === "Network.loadingFailed" ||
        message.method === "Log.entryAdded"
      ) {
        runtimeEvents.push(message);
      }
      return;
    }
    if (!message.id || !pending.has(message.id)) return;
    const waiter = pending.get(message.id);
    pending.delete(message.id);
    if (message.error) {
      waiter.reject(new Error(message.error.message));
    } else {
      waiter.resolve(message.result);
    }
  });

  await new Promise((resolveOpen, rejectOpen) => {
    socket.addEventListener("open", resolveOpen, { once: true });
    socket.addEventListener("error", rejectOpen, { once: true });
  });

  await send("Runtime.enable");
  await send("Page.enable");
  await send("Network.enable");
  await send("Log.enable");
  await send("Page.navigate", { url: "http://127.0.0.1:4999/" });

  let bodyText = "";
  let debugState = {};
  for (let attempt = 0; attempt < 90; attempt += 1) {
    const result = await send("Runtime.evaluate", {
      expression: "({ href: location.href, readyState: document.readyState, text: document.body ? document.body.innerText : '', html: document.documentElement ? document.documentElement.outerHTML.slice(0, 1000) : '' })",
      returnByValue: true
    });
    debugState = result.result?.value ?? {};
    bodyText = debugState.text ?? "";
    if (
      bodyText.includes("Hardware Truth Scanner") &&
      bodyText.includes("Scan completed") &&
      bodyText.includes("Component evidence") &&
      bodyText.includes("Confidence:") &&
      bodyText.includes("Recommended action") &&
      bodyText.includes("What software cannot prove physically")
    ) {
      break;
    }
    await wait(1000);
  }

  const requiredText = [
    "Hardware Truth Scanner",
    "Scan completed",
    "Component evidence",
    "Findings that may need action",
    "Confidence:",
    "Recommended action",
    "What software cannot prove physically"
  ];
  const missing = requiredText.filter((text) => !bodyText.includes(text));
  if (missing.length > 0) {
    throw new Error(`GUI smoke missing visible text: ${missing.join(", ")}; state=${JSON.stringify({
      href: debugState.href,
      readyState: debugState.readyState,
      textPreview: bodyText.slice(0, 500),
      htmlPreview: debugState.html,
      runtimeEvents: runtimeEvents.slice(-10)
    })}`);
  }

  const screenshot = await send("Page.captureScreenshot", { format: "png", fullPage: true });
  const screenshotPath = join(root, "gui-smoke.png");
  await writeFile(screenshotPath, Buffer.from(screenshot.data, "base64"));

  console.log(JSON.stringify({
    ok: true,
    url: "http://127.0.0.1:4999/",
    screenshotPath,
    checks: requiredText
  }, null, 2));
} finally {
  if (socket) socket.close();
  chrome.kill();
  await wait(1000);
  await rm(userDataDir, { recursive: true, force: true }).catch(() => {});
}
