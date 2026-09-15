<#
.DISCLAIMER
    This project is provided AS-IS as a reference implementation and sample for educational
    and demonstration purposes only. It is NOT intended for production use without thorough
    review, testing, and hardening appropriate to your environment.

    By using this code, you accept full responsibility for any modifications, deployments,
    and outcomes. The authors make no warranties -- express or implied -- regarding the
    suitability, reliability, or security of this solution for any particular purpose. Use
    of Azure services, M365 Copilot, and related platforms is subject to their respective
    terms of service and licensing agreements.

    In short: Learn from it, build on it, but validate everything before relying on it.

.SYNOPSIS
    Scan Dataverse dataflows across ONE or ALL environments in your tenant to detect
    dataflow-to-dataflow connections, linked entity references, and Dataflows-connector
    references.

.DESCRIPTION
    Uses the Dataverse Global Discovery Service to enumerate every environment your
    account can access (-AllEnvironments), or targets a single environment
    (-EnvironmentUrl). For each environment it queries the Web API for dataflow records
    (msdyn_dataflow / dataflows), pulls the stored Power Query (M) / model.json
    definitions, and pattern-matches the mashup text.

    Detection categories:
      * DataflowConnector  - PowerPlatform.Dataflows / PowerBI.Dataflows / Dataflow(s).Contents
      * LinkedEntity       - ReferenceEntity / referenceModels / linkedEntity
      * DataflowToDataflow - a Dataflow-connector call that also carries a source dataflowId

.PARAMETER AllEnvironments
    Discover and scan every environment in the tenant your account can read.

.PARAMETER EnvironmentUrl
    Single environment to scan, e.g. https://contoso.crm.dynamics.com
    (Ignored when -AllEnvironments is used.)

.PARAMETER TenantId
    Azure AD tenant (GUID or domain). Required.

.PARAMETER ClientId
    App registration (client) ID. Defaults to the Azure CLI public client so device-code
    sign-in works with no setup. Provide your own for app-only auth.

.PARAMETER ClientSecret
    Optional. If supplied, uses client-credentials (app-only) auth per environment.

.PARAMETER OutputCsv
    Optional CSV report path. Defaults to .\dataflow-scan-<timestamp>.csv

.PARAMETER IncludeDefinitions
    Also dump each dataflow's raw definition text to .\definitions\ for manual review.

.EXAMPLE
    # Every environment in the tenant (interactive sign-in)
    .\Scan-DataverseDataflows.ps1 -AllEnvironments -TenantId contoso.onmicrosoft.com

.EXAMPLE
    # Single environment
    .\Scan-DataverseDataflows.ps1 -EnvironmentUrl https://contoso.crm.dynamics.com -TenantId <guid>

.EXAMPLE
    # All environments, app-only auth
    .\Scan-DataverseDataflows.ps1 -AllEnvironments -TenantId <guid> -ClientId <appid> -ClientSecret <secret>
#>
[CmdletBinding(DefaultParameterSetName = 'All')]
param(
    [Parameter(ParameterSetName = 'All', Mandatory = $true)]
    [switch] $AllEnvironments,

    [Parameter(ParameterSetName = 'Single', Mandatory = $true)]
    [string] $EnvironmentUrl,

    [Parameter(Mandatory = $true)] [string] $TenantId,
    [string] $ClientId = "1950a258-227b-4e31-a9cf-717495945fc2", # Azure PowerShell public client (present in most tenants; see README troubleshooting)
    [string] $ClientSecret,
    [string] $OutputCsv,
    [switch] $IncludeDefinitions,
    [int] $HttpTimeoutSec = 30
)

$ErrorActionPreference = 'Stop'
if (-not $OutputCsv) {
    $OutputCsv = Join-Path (Get-Location) ("dataflow-scan-{0:yyyyMMdd-HHmmss}.csv" -f (Get-Date))
}
$TranscriptPath = Join-Path (Get-Location) 'scan-progress.log'
try { Stop-Transcript | Out-Null } catch {}
Start-Transcript -Path $TranscriptPath -Force | Out-Null
Write-Host ""
Write-Host "============================================================" -ForegroundColor Yellow
Write-Host " DISCLAIMER: Provided as-is as a reference sample for"        -ForegroundColor Yellow
Write-Host " educational/demonstration purposes only. NOT intended for"   -ForegroundColor Yellow
Write-Host " production use without thorough review, testing, and"        -ForegroundColor Yellow
Write-Host " hardening. No warranties. Validate everything before you"     -ForegroundColor Yellow
Write-Host " rely on it."                                                  -ForegroundColor Yellow
Write-Host "============================================================" -ForegroundColor Yellow
Write-Host ""
$GlobalDisco = "https://globaldisco.crm.dynamics.com"
$tokenUrl = "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token"

# ----------------------------------------------------------------------------
# Auth. Two modes:
#   - ClientSecret  -> client_credentials, fresh token per resource on demand.
#   - Device code   -> one interactive sign-in, then redeem refresh_token per resource.
# ----------------------------------------------------------------------------
$script:RefreshToken = $null

function Get-TokenForResource {
    param([string] $Resource)
    $scope = "$Resource/.default"

    if ($ClientSecret) {
        $body = @{
            client_id     = $ClientId
            client_secret = $ClientSecret
            scope         = $scope
            grant_type    = "client_credentials"
        }
        return (Invoke-RestMethod -Method Post -Uri $tokenUrl -Body $body).access_token
    }

    # Device-code path: bootstrap once, then silently redeem for each resource.
    if (-not $script:RefreshToken) {
        Write-Host "Authenticating (device code)..." -ForegroundColor Cyan
        $dc = Invoke-RestMethod -Method Post -Uri "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/devicecode" -Body @{
            client_id = $ClientId
            scope     = "$scope offline_access"
        }
        Write-Host ""; Write-Host $dc.message -ForegroundColor Yellow; Write-Host ""
        $interval = [int]$dc.interval
        $deadline = (Get-Date).AddSeconds([int]$dc.expires_in)
        while ((Get-Date) -lt $deadline) {
            Start-Sleep -Seconds $interval
            try {
                $tok = Invoke-RestMethod -Method Post -Uri $tokenUrl -Body @{
                    grant_type  = "urn:ietf:params:oauth:grant-type:device_code"
                    client_id   = $ClientId
                    device_code = $dc.device_code
                }
                $script:RefreshToken = $tok.refresh_token
                return $tok.access_token
            }
            catch {
                $e = $_.ErrorDetails.Message | ConvertFrom-Json -ErrorAction SilentlyContinue
                if ($e.error -eq 'authorization_pending') { continue }
                if ($e.error -eq 'slow_down') { $interval += 5; continue }
                throw "Device code auth failed: $($e.error) - $($e.error_description)"
            }
        }
        throw "Device code sign-in timed out."
    }

    # Redeem refresh token for the requested resource (rotates the refresh token).
    $tok = Invoke-RestMethod -Method Post -Uri $tokenUrl -TimeoutSec $HttpTimeoutSec -Body @{
        grant_type    = "refresh_token"
        client_id     = $ClientId
        refresh_token = $script:RefreshToken
        scope         = "$scope offline_access"
    }
    if ($tok.refresh_token) { $script:RefreshToken = $tok.refresh_token }
    return $tok.access_token
}

function New-Headers { param([string] $AccessToken)
    return @{
        Authorization      = "Bearer $AccessToken"
        "OData-Version"    = "4.0"
        "OData-MaxVersion" = "4.0"
        Accept             = "application/json"
        Prefer             = "odata.include-annotations=`"*`""
    }
}

# ----------------------------------------------------------------------------
# Build the list of environments to scan
# ----------------------------------------------------------------------------
$targets = @()   # each: @{ Name; ApiBase }

if ($AllEnvironments) {
    Write-Host "Discovering environments via Global Discovery Service..." -ForegroundColor Cyan
    $discoHeaders = New-Headers (Get-TokenForResource $GlobalDisco)
    $disco = Invoke-RestMethod -Headers $discoHeaders -Uri "$GlobalDisco/api/discovery/v2.0/Instances" -TimeoutSec $HttpTimeoutSec
    foreach ($inst in $disco.value) {
        # State 0 = Enabled/Ready. Some tenants omit State; include those too.
        if ($null -ne $inst.State -and $inst.State -ne 0) { continue }
        $api = ($inst.ApiUrl ? $inst.ApiUrl : $inst.Url).TrimEnd('/')
        $targets += @{ Name = $inst.FriendlyName; ApiBase = $api }
    }
    Write-Host "Found $($targets.Count) environment(s)." -ForegroundColor Green
}
else {
    $targets += @{ Name = $EnvironmentUrl; ApiBase = $EnvironmentUrl.TrimEnd('/') }
}

# ----------------------------------------------------------------------------
# Detection: read ONLY the signal columns; never the refresh-history noise.
#   * msdyn_mashupsettings -> QueriesMetadata with LastKnownIsLinkedEntity/Calculated flags
#   * msdyn_mashupdocument -> the M mashup (PowerPlatform.Dataflows( connector calls)
# msdyn_refreshhistory contains refresh ERROR logs that mention the connector namespace
# and MUST be excluded or it produces false positives.
# ----------------------------------------------------------------------------
$signalColumns  = @('msdyn_mashupsettings','msdyn_mashupdocument',
                    # legacy / alternate names kept for cross-version safety:
                    'msdyn_originaldataflowdefinition','msdyn_dataflowdefinition','msdyn_definition',
                    'msdyn_model','msdyn_modeljson','msdyn_querymetadata','definition')
$excludeColumns = @('msdyn_refreshhistory')   # refresh error logs -> noise

function Get-DefinitionText { param($record)
    $sb = New-Object System.Text.StringBuilder
    foreach ($col in $signalColumns) {
        if ($record.PSObject.Properties.Name -contains $col -and $record.$col) {
            [void]$sb.AppendLine([string]$record.$col)
        }
    }
    return $sb.ToString()
}

# Parse possibly double-encoded JSON. Returns $null if it isn't JSON.
function ConvertFrom-JsonSafe { param([string] $Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    $t = $Text.Trim()
    # A definition column may hold several concatenated blobs; take from first '{'.
    $brace = $t.IndexOf('{')
    if ($brace -gt 0) { $t = $t.Substring($brace) }
    for ($i = 0; $i -lt 2; $i++) {
        try { return ($t | ConvertFrom-Json -ErrorAction Stop) } catch {}
        if ($t.StartsWith('"')) { try { $t = ($t | ConvertFrom-Json -ErrorAction Stop) } catch { break } } else { break }
    }
    return $null
}

# Classify one dataflow definition using the REAL Power Query dataflow schema.
# Verified against live definitions: the deprecation-relevant signal is the per-query
# metadata flag "LastKnownIsLinkedEntity". Connector usage must be the M *function call*
# form  PowerPlatform.Dataflows( ...  because the bare namespace also appears inside
# embedded refresh-error logs (MashupExecutionException etc.) and must NOT be counted.
#   * LinkedEntity      -> QueriesMetadata[*].LastKnownIsLinkedEntity == true   (impacted)
#   * CalculatedEntity  -> QueriesMetadata[*].LastKnownIsCalculatedEntity == true
#   * DataflowConnector -> PowerPlatform.Dataflows( / PowerBI.Dataflows(  in the M
#   * DataflowToDataflow-> a connector call referencing a dataflowId GUID != this df's own id
function Get-DfInsight { param([string] $DefText, [string] $SelfId)
    $o = [ordered]@{
        LinkedEntityCount   = 0
        LinkedEntityNames   = @()
        CalcEntityCount     = 0
        ConnectorCall       = $false
        ConnectorFlavor     = @()
        LinkedDataflowIds   = @()
    }
    if ([string]::IsNullOrWhiteSpace($DefText)) { return $o }

    # --- Linked / calculated entities: authoritative per-query metadata flags ---
    $o.LinkedEntityCount = ([regex]::Matches($DefText, '"LastKnownIsLinkedEntity"\s*:\s*true')).Count
    $o.CalcEntityCount   = ([regex]::Matches($DefText, '"LastKnownIsCalculatedEntity"\s*:\s*true')).Count
    # Best-effort: capture the query names whose LastKnownIsLinkedEntity is true.
    foreach ($mm in [regex]::Matches($DefText, '"QueryName"\s*:\s*"([^"]+)"[^}]*?"LastKnownIsLinkedEntity"\s*:\s*true')) {
        $o.LinkedEntityNames += $mm.Groups[1].Value
    }

    # --- Dataflow connector: require the M FUNCTION-CALL form (open paren) ---
    if ([regex]::IsMatch($DefText, 'PowerPlatform\.Dataflows\s*\(')) { $o.ConnectorCall = $true; $o.ConnectorFlavor += 'PowerPlatform.Dataflows' }
    if ([regex]::IsMatch($DefText, 'PowerBI\.Dataflows\s*\('))       { $o.ConnectorCall = $true; $o.ConnectorFlavor += 'PowerBI.Dataflows' }

    # --- Dataflow-to-dataflow: connector call that names a source dataflowId != our own ---
    if ($o.ConnectorCall) {
        foreach ($mm in [regex]::Matches($DefText, 'dataflowId["\\ =:]+([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})')) {
            $g = $mm.Groups[1].Value
            if ($SelfId -and ($g -ieq $SelfId)) { continue }   # skip the dataflow's own id
            $o.LinkedDataflowIds += $g
        }
    }
    $o.LinkedEntityNames = @($o.LinkedEntityNames | Select-Object -Unique)
    $o.LinkedDataflowIds = @($o.LinkedDataflowIds | Select-Object -Unique)
    return $o
}

$defDir = Join-Path (Get-Location) 'definitions'
if ($IncludeDefinitions -and -not (Test-Path $defDir)) { New-Item -ItemType Directory -Path $defDir | Out-Null }

# ----------------------------------------------------------------------------
# Scan each environment
# ----------------------------------------------------------------------------
$results = @()
foreach ($t in $targets) {
    Write-Host ""
    Write-Host "Scanning: $($t.Name)  [$($t.ApiBase)]" -ForegroundColor White
    try {
        $headers = New-Headers (Get-TokenForResource $t.ApiBase)
    } catch {
        Write-Warning "  Could not get a token for this environment ($($_.Exception.Message)). Skipping."
        continue
    }
    $apiBase = "$($t.ApiBase)/api/data/v9.2"

    # Pick an available dataflow entity set.
    $set = $null
    foreach ($candidate in @('msdyn_dataflows','dataflows')) {
        try { Invoke-RestMethod -Headers $headers -Uri "$apiBase/$candidate`?`$top=1" -TimeoutSec $HttpTimeoutSec | Out-Null; $set = $candidate; break } catch {}
    }
    if (-not $set) { Write-Host "  No dataflow table here (or no access). Skipping." -ForegroundColor DarkGray; continue }

    # Page through all records.
    $records = @()
    $uri = "$apiBase/$set"
    try {
        do {
            $page = Invoke-RestMethod -Headers $headers -Uri $uri -TimeoutSec $HttpTimeoutSec
            $records += $page.value
            $uri = $page.'@odata.nextLink'
        } while ($uri)
    } catch {
        Write-Warning "  Failed reading dataflows: $($_.Exception.Message)"; continue
    }
    Write-Host "  $($records.Count) dataflow(s)." -ForegroundColor Green

    foreach ($r in $records) {
        $name = if ($r.msdyn_name) { $r.msdyn_name } else { $r.name }
        $id   = if ($r.msdyn_dataflowid) { $r.msdyn_dataflowid } else { $r.dataflowid }
        $text = Get-DefinitionText $r

        if ($IncludeDefinitions -and $text) {
            $safe = ("{0}_{1}" -f $t.Name, $name) -replace '[^\w\-]', '_'
            Set-Content -Path (Join-Path $defDir "$safe-$id.txt") -Value $text -Encoding UTF8
        }

        $ins = Get-DfInsight -DefText $text -SelfId $id
        $isLinkedEntity = ($ins.LinkedEntityCount -gt 0)
        $isConnector    = $ins.ConnectorCall
        $isD2D          = $isConnector -and ($ins.LinkedDataflowIds.Count -gt 0)

        $results += [pscustomobject]@{
            Environment          = $t.Name
            Name                 = $name
            DataflowId           = $id
            # Deprecation-relevant: linked/referenced entities (authoritative metadata flag)
            UsesLinkedEntities   = [bool]$isLinkedEntity
            LinkedEntityCount    = $ins.LinkedEntityCount
            LinkedEntityNames    = ($ins.LinkedEntityNames -join '; ')
            CalculatedEntityCount= $ins.CalcEntityCount
            # Dataflows connector (the modern replacement mechanism)
            DataflowConnector    = [bool]$isConnector
            ConnectorFlavor      = (($ins.ConnectorFlavor | Select-Object -Unique) -join '; ')
            DataflowToDataflow   = [bool]$isD2D
            LinkedDataflowIds    = ($ins.LinkedDataflowIds -join '; ')
            ImpactedByDeprecation= [bool]$isLinkedEntity
            DefinitionBytes      = $text.Length
        }
    }
}

# ----------------------------------------------------------------------------
# Output
# ----------------------------------------------------------------------------
if ($results.Count -eq 0) {
    Write-Warning "No dataflows found in any scanned environment (or no access)."
    Write-Host "SCAN_COMPLETE_NO_RESULTS"
    try { Stop-Transcript | Out-Null } catch {}
    return
}

$results | Sort-Object Environment, Name |
    Format-Table Environment, Name, UsesLinkedEntities, LinkedEntityCount, CalculatedEntityCount, DataflowConnector, DataflowToDataflow -AutoSize

$results | Sort-Object Environment, Name | Export-Csv -Path $OutputCsv -NoTypeInformation -Encoding UTF8

Write-Host ""
Write-Host "Summary:" -ForegroundColor Cyan
Write-Host ("  Environments scanned:        {0}" -f ($results.Environment | Select-Object -Unique).Count)
Write-Host ("  Total dataflow records:      {0}" -f $results.Count)
Write-Host ("  *** Impacted (linked entities): {0}" -f (($results | Where-Object ImpactedByDeprecation).Count)) -ForegroundColor Yellow
Write-Host ("  Calculated/computed entities:{0}" -f (($results | Where-Object { $_.CalculatedEntityCount -gt 0 }).Count))
Write-Host ("  Using Dataflow connector:    {0}" -f (($results | Where-Object DataflowConnector).Count))
Write-Host ("  Dataflow-to-dataflow (conn): {0}" -f (($results | Where-Object DataflowToDataflow).Count))
Write-Host ""
Write-Host "CSV report: $OutputCsv" -ForegroundColor Green
if ($IncludeDefinitions) { Write-Host "Raw definitions: $defDir" -ForegroundColor Green }
Write-Host "SCAN_COMPLETE"
try { Stop-Transcript | Out-Null } catch {}
