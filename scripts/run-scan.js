import { spawn } from "node:child_process";
import { writeFile } from "node:fs/promises";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { summarizeReport, validateReportShape } from "../server/analyze.js";

const __dirname = dirname(fileURLToPath(import.meta.url));
const root = resolve(__dirname, "..");
const scriptPath = join(root, "server", "hardware-scan.ps1");
const powershell = process.env.SystemRoot
  ? join(process.env.SystemRoot, "System32", "WindowsPowerShell", "v1.0", "powershell.exe")
  : "powershell.exe";

function run() {
  return new Promise((resolveReport, reject) => {
    const child = spawn(powershell, ["-NoProfile", "-ExecutionPolicy", "Bypass", "-File", scriptPath], {
      cwd: root,
      windowsHide: true
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
        reject(new Error(`PowerShell scanner failed with code ${code}: ${stderr || stdout}`));
        return;
      }
      const report = JSON.parse(stdout);
      const missing = validateReportShape(report);
      if (missing.length > 0) {
        reject(new Error(`Scanner output missing fields: ${missing.join(", ")}`));
        return;
      }
      report.summary = summarizeReport(report);
      resolveReport(report);
    });
  });
}

const report = await run();
const outputPath = join(root, "hardware-report-latest.json");
await writeFile(outputPath, JSON.stringify(report, null, 2), "utf8");
console.log(`Report written to ${outputPath}`);
console.log(JSON.stringify(report.summary, null, 2));
