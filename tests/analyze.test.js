import { describe, expect, it } from "vitest";
import { summarizeReport, validateReportShape } from "../server/analyze.js";

describe("summarizeReport", () => {
  it("marks critical when any component is critical", () => {
    const summary = summarizeReport({
      components: [
        { status: "ok" },
        { status: "warning" },
        { status: "critical" }
      ],
      findings: [{}, {}]
    });

    expect(summary).toMatchObject({
      overallStatus: "critical",
      componentCount: 3,
      findingCount: 2,
      criticalCount: 1,
      warningCount: 1
    });
  });

  it("marks unknown only when no critical or warning component exists", () => {
    const summary = summarizeReport({
      components: [
        { status: "ok" },
        { status: "unknown" }
      ],
      findings: []
    });

    expect(summary.overallStatus).toBe("unknown");
  });
});

describe("validateReportShape", () => {
  it("returns every missing top-level report field", () => {
    expect(validateReportShape({ scanner: "x", components: [] })).toEqual([
      "generatedAt",
      "host",
      "os",
      "findings",
      "coverageLimits"
    ]);
  });
});
