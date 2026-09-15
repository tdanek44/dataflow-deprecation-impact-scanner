# Dataflow Deprecation Impact Scanner

## Disclaimer

This project is provided **as-is** as a reference implementation and sample for educational and demonstration purposes only. It is **not intended for production use** without thorough review, testing, and hardening appropriate to your environment.

By using this code, you accept full responsibility for any modifications, deployments, and outcomes. The authors make no warranties — express or implied — regarding the suitability, reliability, or security of this solution for any particular purpose. Use of Azure services, M365 Copilot, and related platforms is subject to their respective terms of service and licensing agreements.

> 📋 **In short:** Learn from it, build on it, but validate everything before relying on it.

---

A PowerShell tool that scans **Power Platform dataflows across every environment in your tenant** and flags the ones impacted by the **linked / referenced entity** deprecation. It reads dataflow definitions directly from Dataverse — no per-environment clicking, no Power BI Desktop.

**Script:** `Scan-DataverseDataflows.ps1`

---

## What it checks

For each dataflow it inspects the stored Power Query definition and reports:

| Column | Meaning |
|---|---|
| **UsesLinkedEntities** / **ImpactedByDeprecation** | ⚠️ Dataflow uses linked/referenced entities — **this is the deprecation target** |
| **LinkedEntityCount** | Number of linked-entity queries in the dataflow |
| **CalculatedEntityCount** | Number of calculated/computed-entity queries |
| **DataflowConnector** | Uses the `PowerPlatform.Dataflows` connector (the modern replacement) |
| **DataflowToDataflow** | A connector call that references another dataflow's ID |

Detection uses the authoritative per-query metadata flag (`LastKnownIsLinkedEntity`) and the actual M mashup — and deliberately **ignores refresh-history error logs** to avoid false positives.

---

## Prerequisites

- **PowerShell 7+** (`pwsh`). Windows PowerShell 5.1 is **not** supported. Check with `pwsh -v`.
- **Access to the environments** you want to scan. You only see environments your account can read; for full tenant coverage, use an account (or Power Platform admin) added to all environments.
- **Sign-in method** — one of:
  - *Interactive (default):* nothing to set up. You'll complete a browser device-code sign-in.
  - *App-only (unattended):* an Entra app registration with a client secret and the Dataverse (Dynamics CRM) **user_impersonation** / application permission granted in each environment.
- Outbound HTTPS to `login.microsoftonline.com`, `globaldisco.crm.dynamics.com`, and your `*.crm.dynamics.com` environment URLs.

---

## How to use

**Scan every environment in the tenant (interactive):**
```powershell
pwsh -File .\Scan-DataverseDataflows.ps1 -AllEnvironments -TenantId <yourtenant>.onmicrosoft.com
```
A device-code prompt appears (`https://microsoft.com/devicelogin` + a code). Sign in once; the tool discovers all environments and scans them.

**Scan a single environment:**
```powershell
pwsh -File .\Scan-DataverseDataflows.ps1 -EnvironmentUrl https://YOURORG.crm.dynamics.com -TenantId <guid>
```

**Unattended / app-only:**
```powershell
pwsh -File .\Scan-DataverseDataflows.ps1 -AllEnvironments -TenantId <guid> `
  -ClientId <appId> -ClientSecret <secret>
```

**Useful options:** `-OutputCsv <path>` (custom report path) · `-IncludeDefinitions` (dump raw definitions for manual review) · `-HttpTimeoutSec <n>` (per-request timeout, default 30).

---

## Troubleshooting

- **`AADSTS700016: Application ... was not found in the directory`** — the default public sign-in client isn't registered in your tenant. Re-run with a client that is, e.g. the Azure PowerShell public client:
  ```powershell
  -ClientId 1950a258-227b-4e31-a9cf-717495945fc2
  ```
  or the Azure CLI client (`04b07795-8ddb-461a-bbb0-02f9e1bf7b46`), or your own app registration. At least one is present in most tenants.
- **`AADSTS65001 / consent required`** — an admin must consent to the client for Dataverse access, or use `-ClientId` with a pre-consented app.
- **401 on an environment** — your account isn't a member of that environment; it's skipped automatically. Add the account (or run as a Power Platform admin) for full coverage.
- **A scan seems to hang on one environment** — a slow/unreachable environment is bounded by `-HttpTimeoutSec` (default 30s) and then skipped. Lower it if needed.
- **`pwsh: command not found`** — install PowerShell 7+ (`winget install Microsoft.PowerShell`). The built-in Windows PowerShell 5.1 will not work.

---

## What you get

- A console summary (environments scanned, total dataflows, **impacted count**).
- A CSV report: `dataflow-scan-<timestamp>.csv` — one row per dataflow definition, with the columns above.

**To find impacted dataflows:** open the CSV and filter **`ImpactedByDeprecation = True`** (or `UsesLinkedEntities = True`). Those are the dataflows to remediate.

> Note: each dataflow typically appears as **two rows** (authoring + published definition records). De-duplicate on `DataflowName` if you want a unique count.

---

## Notes & limitations

- **Read-only.** The script only reads metadata; it never modifies dataflows.
- **Scope = your permissions.** Environments/dataflows you can't read are silently skipped.
- **Environments with no analytical dataflows** are reported as 0 and skipped.
- For a fully tenant-complete, Microsoft-supported audit, the **Power BI / Fabric Admin Scanner API** is the authoritative alternative.

---

*Tested on PowerShell 7.6 against Dataverse Web API v9.2. Detection validated against real dataflow definitions with zero false positives.*
