# Widget Sync Implementation Checklist

## Status Snapshot (March 6, 2026)
- Baseline refactor is in place: widget data now derives from the same transport connection pipeline used by `TransportView`.
- Foreground reconcile and morning `BGAppRefreshTask` scheduling are implemented.
- Sparse timeline strategy + dynamic countdown rendering are implemented.
- Debug diagnostics are implemented and wired into write/reconcile/stale/reload/background flows.
- Debug widget snapshot status is visible in Settings (Debug builds).
- Remaining blocker: no XCTest target exists in the project yet, so Phase 7 test suite is pending target creation.

## Goal
Build a robust widget update system that:
- Uses the same data source as `TransportView`.
- Shows minute-level accuracy before the last minute.
- Shows second-level countdown in the last minute via dynamic timer rendering.
- Survives overnight inactivity with precomputed coverage.
- Uses system-friendly refresh behavior (event-driven + sparse reconcile).

## Phase 1: Data Contract Hardening

### File: `Gleis/Sources/Models/Widget/WidgetModels.swift`
- [x] Add `schemaVersion` to `WidgetData`.
- [x] Add metadata fields:
  - `generatedAt`
  - `coverageStart`
  - `coverageEnd`
  - `routeSignature`
  - `snapshotSignature`
- [x] Use strict decoding for current schema version only.
- [x] Add helper validations:
  - `hasCoverage(at:)`
  - `isCoverageExhausted(at:)`
  - `needsTopUp(referenceDate:targetEnd:)`
- [x] Add deterministic signature helpers for stored payloads.

### File: `GleisWidget/SharedWidgetModels.swift`
- [x] Mirror all `WidgetData` and metadata fields from app target.
- [x] Use strict decoding for current schema version only.
- [x] Keep App Group storage API aligned with app model exactly.
- [x] Add shared helper parity used by provider (`hasCoverage`, `needsTopUp`, etc.).

## Phase 2: App-Side Snapshot Production

### File: `Gleis/Sources/ViewModels/TransportViewModel.swift`
- [x] Keep event-driven write triggers only.
- [x] Compute `snapshotSignature` from widget-relevant fields.
- [x] Gate writes by signature.
- [x] Populate metadata on write.
- [x] Add top-up decision and horizon extension behavior.

### File: `Gleis/Sources/Services/TransportService.swift`
- [x] Existing API fetch path reused for horizon top-up and reconcile fallback.
- [x] Dedupe + stable sorting preserved in snapshot builder/reconcile flow.

## Phase 3: Widget Timeline Strategy

### File: `GleisWidget/GleisWidget.swift`
- [x] Remove per-second timeline entry loops.
- [x] Build sparse timeline entries at meaningful boundaries.
- [x] Use dynamic timer rendering for second-level countdown in last-minute mode.
- [x] Keep minute-level display above 60 seconds.
- [x] Reload policy:
  - near/exhausting coverage -> 5 min
  - normal conditions -> 10 min
- [x] Stale behavior with explicit fallback hint/recovery flow.

## Phase 4: Overnight Resilience

### File: `Gleis/Sources/ViewModels/TransportViewModel.swift`
- [x] Morning coverage window defined (`04:30` to `10:00` local).
- [x] Evening/night top-up attempts to cover morning window.
- [x] App launch/foreground path reconciles snapshot freshness.

### File: `Gleis/GleisApp.swift`
- [x] Lightweight foreground reconcile trigger added.
- [x] Cheap signature-gated write behavior preserved.

### File: `Gleis/Info.plist`
- [x] Background refresh identifier registered.
- [x] Required background mode keys present for current design.

## Phase 5: Optional Background v2 (Best-Effort)

### File: `Gleis/GleisApp.swift`
- [x] Single `BGAppRefreshTask` handler registered.
- [x] Earliest begin date targeted around 05:30 local time.
- [x] Task run performs reconcile + timeline reload through shared write logic.
- [x] Reschedule on each run and app background transition.

### File: `Gleis/Sources/Services`
- [x] No route/day-direction matrix fan-out reintroduced.
- [x] Shared snapshot logic remains centralized in `WidgetSnapshotBuilder` + reconciler path.

## Phase 6: Observability and Diagnostics

### File: `Gleis/Sources/Managers/WidgetSyncDiagnostics.swift`
- [x] Structured debug logs for:
  - snapshot write skipped/applied
  - coverage decisions/top-up outcomes
  - timeline reload reasons
  - stale display reasons
  - background task scheduling/execution
- [x] Logs are throttled and avoid sensitive data.

### File: `Gleis/Sources/Views/Settings/SettingsView.swift`
- [x] Debug-only widget status section added:
  - generated time
  - coverage end
  - signature excerpt
  - snapshot state/message

## Phase 7: Tests

### File: `GleisTests/...` (new target required)
- [ ] `WidgetData` strict schema decode test.
- [ ] Signature stability/change tests.
- [ ] Timeline boundary tests (`>60s`, `<=60s`, transition at leave).
- [ ] Overnight coverage window tests.
- [ ] DST morning-window boundary tests.

## Current Blockers
- No `GleisTests` target exists in `Gleis.xcodeproj`, so automated tests cannot be added yet.

## Acceptance Criteria Check
- [x] Widget data matches `TransportView`-derived data on meaningful refreshes.
- [x] Countdown is minute-accurate above 60s and second-accurate at/below 60s.
- [x] No per-second timeline generation exists.
- [x] Overnight coverage/top-up strategy implemented.
- [x] Stale state is explicit and recoverable.
- [x] Reload calls are signature-gated and reduced.

## Next Action
1. Add `GleisTests` target.
2. Implement Phase 7 test suite.
3. Run full widget sync regression pass on simulator/device overnight.
