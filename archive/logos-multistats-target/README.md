# Retired: the in-Logos MultiStats viewer target

`MultiStatsApp.swift` here is the standalone **MultiStats** executable target that used to
live in the Logos SwiftPM package (`Sources/MultiStats/`, product
`.executable(name: "MultiStats", ...)`). It was retired in
[#92](https://github.com/PsychQuant/logos/issues/92) on 2026-07-12.

## Why retired

The in-app **帳號用量** window (`AccountUsageWindow`, a SwiftUI `Window` scene over the
same `LogosUsage` / `RegistryUsageModel` layer) is a strict **superset** of what this
standalone viewer offered — a per-account plan-usage list — but with active-account
highlighting and no separate app to launch. Keeping both meant two code paths rendering
the same `UsageAccountRow` data, so the standalone target was redundant. `LogosUsage` and
`LogosAccounts` (the credential-free registry + read-only usage-client layer) are **kept**;
only the thin standalone SwiftUI shell was removed.

## Relationship to `../MultiStats/`

The sibling `archive/MultiStats/` folder is a local, untracked snapshot of the *original*
pre-merge standalone MultiStats project (its own `Sources/MultiStatsCore/`, `Package.swift`,
`.git`). This file is the **later, merged-into-Logos variant** — it imports the extracted
`LogosAccounts` / `LogosUsage` modules and uses `UsageAccountRow` (the original imported
`MultiStatsCore` and used `AccountRow`). Preserved here for history; it is outside
`Sources/`, so SwiftPM never builds it.
