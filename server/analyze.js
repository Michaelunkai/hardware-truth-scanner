export function summarizeReport(report) {
  const counts = {
    criticalCount: 0,
    warningCount: 0,
    unknownCount: 0
  };

  for (const component of report.components ?? []) {
    if (component.status === "critical") counts.criticalCount += 1;
    if (component.status === "warning") counts.warningCount += 1;
    if (component.status === "unknown") counts.unknownCount += 1;
  }

  for (const finding of report.findings ?? []) {
    if (finding.severity === "critical") counts.criticalCount += 1;
    if (finding.severity === "warning") counts.warningCount += 1;
  }

  let overallStatus = "ok";
  if (counts.criticalCount > 0) {
    overallStatus = "critical";
  } else if (counts.warningCount > 0) {
    overallStatus = "warning";
  } else if (counts.unknownCount > 0) {
    overallStatus = "unknown";
  }

  return {
    overallStatus,
    componentCount: report.components?.length ?? 0,
    findingCount: report.findings?.length ?? 0,
    ...counts
  };
}

export function validateReportShape(report) {
  const missing = [];
  for (const key of ["scanner", "generatedAt", "host", "os", "components", "findings", "diagnostics", "coverageLimits"]) {
    if (!(key in report)) {
      missing.push(key);
    }
  }
  return missing;
}
