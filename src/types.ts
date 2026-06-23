export type Severity = "ok" | "info" | "warning" | "critical" | "unknown";

export type ComponentReport = {
  id: string;
  category: string;
  name: string;
  status: Severity;
  confidence: "high" | "medium" | "low";
  evidence: Record<string, unknown>;
  signals: string[];
  recommendations: string[];
};

export type Finding = {
  severity: Severity;
  component: string;
  title: string;
  detail: string;
  evidence: string;
  recommendation: string;
  confidence: "high" | "medium" | "low";
};

export type DiagnosticCheck = {
  name: string;
  status: "passed" | "warning" | "critical" | "limited" | "not_run" | "unavailable";
  evidence: string;
  nextStep: string;
};

export type ScanReport = {
  scanner: string;
  generatedAt: string;
  host: string;
  os: string;
  scanWindowDays: number;
  summary: {
    overallStatus: Severity;
    componentCount: number;
    findingCount: number;
    criticalCount: number;
    warningCount: number;
    unknownCount: number;
  };
  components: ComponentReport[];
  findings: Finding[];
  diagnostics: DiagnosticCheck[];
  coverageLimits: string[];
  raw?: Record<string, unknown>;
};
