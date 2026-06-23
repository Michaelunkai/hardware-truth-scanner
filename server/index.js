import express from "express";
import { spawn } from "node:child_process";
import { createServer } from "node:http";
import { existsSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { summarizeReport, validateReportShape } from "./analyze.js";

const __dirname = dirname(fileURLToPath(import.meta.url));
const root = resolve(__dirname, "..");
const app = express();
const port = Number(process.env.PORT ?? 4999);
let lastReport = null;

app.use(express.json());

function runPowerShellScanner() {
  return new Promise((resolveReport, reject) => {
    const scriptPath = join(__dirname, "hardware-scan.ps1");
    const powershell = process.env.SystemRoot
      ? join(process.env.SystemRoot, "System32", "WindowsPowerShell", "v1.0", "powershell.exe")
      : "powershell.exe";

    const child = spawn(powershell, [
      "-NoProfile",
      "-ExecutionPolicy",
      "Bypass",
      "-File",
      scriptPath
    ], {
      windowsHide: true,
      cwd: root
    });

    let stdout = "";
    let stderr = "";

    child.stdout.on("data", (chunk) => {
      stdout += chunk.toString();
    });

    child.stderr.on("data", (chunk) => {
      stderr += chunk.toString();
    });

    child.on("error", reject);
    child.on("close", (code) => {
      if (code !== 0) {
        reject(new Error(`Scanner exited with code ${code}: ${stderr || stdout}`));
        return;
      }

      try {
        const parsed = JSON.parse(stdout);
        const missing = validateReportShape(parsed);
        if (missing.length > 0) {
          throw new Error(`Scanner output is missing fields: ${missing.join(", ")}`);
        }
        parsed.summary = summarizeReport(parsed);
        lastReport = parsed;
        resolveReport(parsed);
      } catch (error) {
        reject(new Error(`Failed to parse scanner JSON: ${error.message}\n${stdout}\n${stderr}`));
      }
    });
  });
}

app.get("/api/health", (_request, response) => {
  response.json({ ok: true, scanner: "hardware-truth-scanner" });
});

app.get("/api/report", (_request, response) => {
  if (!lastReport) {
    response.status(404).json({ error: "No scan has been run yet." });
    return;
  }
  response.json(lastReport);
});

app.post("/api/scan", async (_request, response) => {
  try {
    const report = await runPowerShellScanner();
    response.json(report);
  } catch (error) {
    response.status(500).send(error instanceof Error ? error.message : String(error));
  }
});

const dist = join(root, "dist");
if (existsSync(dist)) {
  app.use(express.static(dist));
  app.use((_request, response) => {
    response.sendFile(join(dist, "index.html"));
  });
}

const server = createServer(app);
server.on("error", (error) => {
  console.error(`Failed to start Hardware Truth Scanner: ${error.message}`);
  process.exitCode = 1;
});

server.listen(port, "127.0.0.1", () => {
  console.log(`Hardware Truth Scanner listening at http://127.0.0.1:${port}`);
});
server.ref();
