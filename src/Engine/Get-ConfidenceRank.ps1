function Get-ConfidenceRank {
    # Canonical confidence-band ordering (higher = more confident).
    # Single source of truth for filtering (Select-AuditResults) and sort order
    # (Invoke-AdVendorGroupAudit, Write-HtmlReport).
    [CmdletBinding()]
    param()
    @{ None = 0; Low = 1; Medium = 2; High = 3; Confirmed = 4 }
}
