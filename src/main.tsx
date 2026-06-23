import React, { useEffect, useState } from "react";
import { createRoot } from "react-dom/client";
import type { ComponentReport, DiagnosticCheck, ScanReport, Severity } from "./types";
import "./styles.css";

const severityRank: Record<Severity, number> = {
  critical: 5,
  warning: 4,
  unknown: 3,
  info: 2,
  ok: 1
};

function sortComponents(components: ComponentReport[]) {
  return [...components].sort((a, b) => {
    const rank = severityRank[b.status] - severityRank[a.status];
    return rank !== 0 ? rank : a.category.localeCompare(b.category) || a.name.localeCompare(b.name);
  });
}

function asStringArray(value: string[] | null | undefined) {
  return Array.isArray(value) ? value : [];
}

function Badge({ value }: { value: Severity }) {
  return <span className={`badge badge-${value}`}>{value.toUpperCase()}</span>;
}

function DiagnosticBadge({ value }: { value: DiagnosticCheck["status"] }) {
  return <span className={`badge diagnostic-${value}`}>{value.replace("_", " ").toUpperCase()}</span>;
}

type ActionItem = {
  title: string;
  priority: "Fix first" | "Verify next" | "Known limit";
  evidence: string;
  action: string;
};

const actionRank: Record<ActionItem["priority"], number> = {
  "Fix first": 3,
  "Verify next": 2,
  "Known limit": 1
};

function EvidenceList({ data }: { data: Record<string, unknown> }) {
  const entries = Object.entries(data).filter(([, value]) => value !== null && value !== undefined && value !== "");

  if (entries.length === 0) {
    return <p className="muted">No direct telemetry returned for this component.</p>;
  }

  return (
    <dl className="evidence">
      {entries.map(([key, value]) => (
        <React.Fragment key={key}>
          <dt>{key}</dt>
          <dd>{typeof value === "object" ? JSON.stringify(value) : String(value)}</dd>
        </React.Fragment>
      ))}
    </dl>
  );
}

function ComponentCard({ component }: { component: ComponentReport }) {
  const signals = asStringArray(component.signals);
  const recommendations = asStringArray(component.recommendations);

  return (
    <article className="component-card">
      <div className="component-head">
        <div>
          <p className="eyebrow">{component.category}</p>
          <h3>{component.name}</h3>
        </div>
        <Badge value={component.status} />
      </div>
      <p className="confidence">Confidence: {component.confidence}</p>
      <EvidenceList data={component.evidence} />
      <div className="card-section">
        <h4>Signals</h4>
        {signals.length > 0 ? (
          <ul>{signals.map((signal) => <li key={signal}>{signal}</li>)}</ul>
        ) : (
          <p className="muted">No negative signal found.</p>
        )}
      </div>
      <div className="card-section">
        <h4>Recommended action</h4>
        <ul>{recommendations.map((item) => <li key={item}>{item}</li>)}</ul>
      </div>
    </article>
  );
}

function ReportMeta({ report }: { report: ScanReport }) {
  return (
    <section className="meta-strip" aria-label="scan metadata">
      <div>
        <span>Host</span>
        <strong>{report.host || "Unknown"}</strong>
      </div>
      <div>
        <span>Operating system</span>
        <strong>{report.os || "Unknown"}</strong>
      </div>
      <div>
        <span>Scan window</span>
        <strong>{report.scanWindowDays} days</strong>
      </div>
      <div>
        <span>Generated</span>
        <strong>{new Date(report.generatedAt).toLocaleString()}</strong>
      </div>
    </section>
  );
}

function Verdict({ report }: { report: ScanReport }) {
  const verdict =
    report.summary.criticalCount > 0
      ? "Critical hardware or reliability evidence was found. Fix the listed items first."
      : report.summary.warningCount > 0
        ? "Warning-level evidence was found. Review the listed parts and recommended actions."
        : report.summary.unknownCount > 0
          ? "No critical or warning fault was found, but some hardware angles cannot be proven from safe live telemetry."
          : "Every safe live software check passed. No hardware fault signal was found in the tested categories.";

  return (
    <section className="verdict-card">
      <p className="eyebrow">Human-readable verdict</p>
      <h2>{verdict}</h2>
      <p>
        “Perfect” means perfect within the checks that can safely run while Windows is live. Anything that needs reboot
        diagnostics, sustained load, vendor firmware tools, or physical inspection is listed separately instead of being
        falsely marked clean.
      </p>
    </section>
  );
}

function Diagnostics({ diagnostics }: { diagnostics: DiagnosticCheck[] }) {
  return (
    <section className="diagnostics">
      <div className="section-title">
        <p className="eyebrow">Proof coverage</p>
        <h2>What was actually tested</h2>
      </div>
      <div className="diagnostic-grid">
        {diagnostics.map((item) => (
          <article className="diagnostic-card" key={item.name}>
            <div className="component-head">
              <h3>{item.name}</h3>
              <DiagnosticBadge value={item.status} />
            </div>
            <p>{item.evidence}</p>
            <p className="recommendation">Next: {item.nextStep}</p>
          </article>
        ))}
      </div>
    </section>
  );
}

function ActionQueue({ report }: { report: ScanReport }) {
  const findingItems: ActionItem[] = report.findings.map((finding) => ({
    title: finding.title,
    priority: finding.severity === "critical" || finding.severity === "warning" ? "Fix first" : "Verify next",
    evidence: `${finding.component}: ${finding.evidence}`,
    action: finding.recommendation
  }));

  const warningItems: ActionItem[] = report.components
    .filter((component) => component.status === "critical" || component.status === "warning")
    .map((component) => ({
      title: `${component.category}: ${component.name}`,
      priority: "Fix first",
      evidence: asStringArray(component.signals)[0] ?? `${component.status.toUpperCase()} status`,
      action: asStringArray(component.recommendations)[0] ?? "Review the detailed component evidence below."
    }));

  const limitedDiagnostics: ActionItem[] = report.diagnostics
    .filter((item) => item.status === "limited" || item.status === "unavailable" || item.status === "not_run")
    .map((item) => ({
      title: item.name,
      priority: item.status === "not_run" ? "Known limit" : "Verify next",
      evidence: item.evidence,
      action: item.nextStep
    }));

  const items = [...findingItems, ...warningItems, ...limitedDiagnostics]
    .filter((item, index, allItems) => allItems.findIndex((candidate) => candidate.title === item.title) === index)
    .sort((a, b) => actionRank[b.priority] - actionRank[a.priority] || a.title.localeCompare(b.title))
    .slice(0, 12);

  if (items.length === 0) {
    return (
      <section className="action-queue clean-queue">
        <div className="section-title">
          <p className="eyebrow">Fix priority</p>
          <h2>Nothing needs action from safe live telemetry</h2>
        </div>
        <p>Every safe live software-visible check passed. Remaining certainty still depends on the boundary list below.</p>
      </section>
    );
  }

  return (
    <section className="action-queue">
      <div className="section-title">
        <p className="eyebrow">Fix priority</p>
        <h2>What to fix or verify first</h2>
      </div>
      <div className="action-grid">
        {items.map((item) => (
          <article className={`action-card action-${item.priority.toLowerCase().replace(/\s+/g, "-")}`} key={item.title}>
            <span>{item.priority}</span>
            <h3>{item.title}</h3>
            <p className="muted">Evidence: {item.evidence}</p>
            <p className="recommendation">Next: {item.action}</p>
          </article>
        ))}
      </div>
    </section>
  );
}

function App() {
  const [report, setReport] = useState<ScanReport | null>(null);
  const [status, setStatus] = useState("Ready to run hardware scan.");
  const [error, setError] = useState<string | null>(null);

  async function runScan() {
    setStatus("Running read-only hardware scan. This can take up to a minute.");
    setError(null);
    try {
      const response = await fetch("/api/scan", { method: "POST" });
      if (!response.ok) {
        throw new Error(await response.text());
      }
      const nextReport = (await response.json()) as ScanReport;
      setReport(nextReport);
      setStatus(`Scan completed at ${new Date(nextReport.generatedAt).toLocaleString()}.`);
    } catch (scanError) {
      setError(scanError instanceof Error ? scanError.message : String(scanError));
      setStatus("Scan failed.");
    }
  }

  useEffect(() => {
    void runScan();
  }, []);

  const components = report ? sortComponents(report.components) : [];
  const findings = report?.findings ?? [];
  const diagnostics = report?.diagnostics ?? [];
  const coverageLimits = report?.coverageLimits ?? [];

  return (
    <main className="shell">
      <section className="hero">
        <div>
          <p className="eyebrow">Windows hardware evidence report</p>
          <h1>Hardware Truth Scanner</h1>
          <p className="hero-copy">
            Read-only physical-health triage using Device Manager status, storage health, SMART failure prediction,
            reliability counters, WHEA, disk, thermal, GPU, battery, and recent system event evidence.
            The GUI separates confirmed software-visible faults from physical checks that still need offline or
            vendor diagnostics.
          </p>
        </div>
        <button onClick={runScan}>Run scan again</button>
      </section>

      <section className="status-strip">
        <p>{status}</p>
        {error ? <p className="error">{error}</p> : null}
      </section>

      {report ? (
        <>
          <ReportMeta report={report} />
          <Verdict report={report} />

          <section className="summary-grid">
            <div className="summary-card main-status">
              <span>Overall</span>
              <strong>{report.summary.overallStatus.toUpperCase()}</strong>
            </div>
            <div className="summary-card">
              <span>Components</span>
              <strong>{report.summary.componentCount}</strong>
            </div>
            <div className="summary-card">
              <span>Critical</span>
              <strong>{report.summary.criticalCount}</strong>
            </div>
            <div className="summary-card">
              <span>Warnings</span>
              <strong>{report.summary.warningCount}</strong>
            </div>
            <div className="summary-card">
              <span>Unknowns</span>
              <strong>{report.summary.unknownCount}</strong>
            </div>
          </section>

          <ActionQueue report={report} />

          <Diagnostics diagnostics={diagnostics} />

          <section className="findings">
            <div className="section-title">
              <p className="eyebrow">Exact issues found</p>
              <h2>Findings that may need action</h2>
            </div>
            {findings.length === 0 ? (
              <p className="clean">No critical or warning hardware fault signal was found by software telemetry.</p>
            ) : (
              <div className="finding-list">
                {findings.map((finding, index) => (
                  <article className="finding" key={`${finding.component}-${finding.title}-${index}`}>
                    <Badge value={finding.severity} />
                    <div>
                      <h3>{finding.title}</h3>
                      <p>{finding.detail}</p>
                      <p className="muted">Evidence: {finding.evidence}</p>
                      <p className="recommendation">Action: {finding.recommendation}</p>
                    </div>
                  </article>
                ))}
              </div>
            )}
          </section>

          <section className="components">
            <div className="section-title">
              <p className="eyebrow">Every detected hardware class</p>
              <h2>Component evidence</h2>
            </div>
            <div className="component-grid">
              {components.map((component) => <ComponentCard component={component} key={component.id} />)}
            </div>
          </section>

          <section className="limits">
            <div className="section-title">
              <p className="eyebrow">Accuracy boundary</p>
              <h2>What software cannot prove physically</h2>
            </div>
            <p className="boundary-copy">
              These are not skipped checks. They are the cases where Windows telemetry cannot honestly prove physical
              condition without reboot-level diagnostics, vendor tools, load testing, or inspection.
            </p>
            <ul>{coverageLimits.map((limit) => <li key={limit}>{limit}</li>)}</ul>
          </section>
        </>
      ) : (
        <section className="empty">Waiting for first scan result.</section>
      )}
    </main>
  );
}

createRoot(document.getElementById("root")!).render(<App />);
