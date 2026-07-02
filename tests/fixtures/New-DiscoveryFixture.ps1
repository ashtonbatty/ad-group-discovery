<#
.SYNOPSIS
    Generates the Vendor AD Group Discovery test fixture: a simulated multi-domain
    directory (directory.json) plus the five discovery-input CSVs for discovering the
    primary vendor (Northwind Traders).

.DESCRIPTION
    Deterministic - no randomness, no dates from the clock - so the output is
    stable and diffable. Re-run after editing the data tables below to regenerate.

    Scenario:
      * 4 domains in the Globex forest, with inconsistent naming/TLDs.
      * 4 organisations: 3 vendors (Northwind Traders [PRIMARY/discovered], Contoso,
        Fabrikam) and the customer org (Globex, non-vendor).
      * 40 users (20 Northwind, 7 Contoso, 7 Fabrikam, 6 Globex).
      * 24 groups (12 Northwind-related, 12 other).
      * 2 directory structures:
          - Structure A (corp, emea): vendor groups foldered into per-vendor
            OUs (OU=<Vendor>,OU=Vendors); customer groups in OU=Groups.
          - Structure B (apac, dmz): every group in a single flat OU=Groups.

    See README.md in this folder for the planted matches and expected results.

.PARAMETER OutDir
    Directory to write directory.json and discovery-input/*.csv into. Defaults to the
    folder containing this script.
#>
[CmdletBinding()]
param([string]$OutDir = $PSScriptRoot)

$ErrorActionPreference = 'Stop'

# --- Domains ------------------------------------------------------------------
$domMeta = [ordered]@{
    corp = @{ Fqdn = 'corp.globex.com';  Base = 'DC=corp,DC=globex,DC=com';  Server = 'dc01.corp.globex.com';  Struct = 'A'; Name = 'Globex Corp HQ' }
    emea = @{ Fqdn = 'emea.globex.com';  Base = 'DC=emea,DC=globex,DC=com';  Server = 'dc01.emea.globex.com';  Struct = 'A'; Name = 'Globex EMEA' }
    apac = @{ Fqdn = 'apac.globex.local'; Base = 'DC=apac,DC=globex,DC=local'; Server = 'dc01.apac.globex.local'; Struct = 'B'; Name = 'Globex APAC' }
    dmz  = @{ Fqdn = 'dmz.globex.net';   Base = 'DC=dmz,DC=globex,DC=net';   Server = 'dc01.dmz.globex.net';   Struct = 'B'; Name = 'Globex DMZ' }
}

# --- Users: Org, Sam, Given, Surname, Rid, DomainKey --------------------------
# NOTE: rows are comma-separated so @() keeps them as nested arrays (without the
# commas, @() would flatten the inner arrays into one long scalar list).
$userRows = @(
    # Northwind Traders (PRIMARY vendor) - 20
    ,@('Northwind','jbrooks','Jacob','Brooks',1001,'corp')
    ,@('Northwind','mhale','Maria','Hale',1002,'corp')
    ,@('Northwind','tpatel','Tarun','Patel',1003,'corp')
    ,@('Northwind','lchen','Lucy','Chen',1004,'corp')
    ,@('Northwind','dokafor','David','Okafor',1005,'corp')
    ,@('Northwind','rsantos','Rosa','Santos',1006,'corp')
    ,@('Northwind','kvolkov','Kiril','Volkov',1007,'corp')
    ,@('Northwind','awright','Aisha','Wright',1008,'corp')
    ,@('Northwind','bnguyen','Bao','Nguyen',1009,'emea')
    ,@('Northwind','sfischer','Sven','Fischer',1010,'emea')
    ,@('Northwind','egarcia','Elena','Garcia',1011,'emea')
    ,@('Northwind','pnowak','Pawel','Nowak',1012,'emea')
    ,@('Northwind','ytanaka','Yuki','Tanaka',1013,'apac')
    ,@('Northwind','wliu','Wei','Liu',1014,'apac')
    ,@('Northwind','akapoor','Anil','Kapoor',1015,'apac')
    ,@('Northwind','stui','Sione','Tui',1016,'apac')
    ,@('Northwind','ohaddad','Omar','Haddad',1017,'dmz')
    ,@('Northwind','gbell','Grace','Bell',1018,'dmz')
    ,@('Northwind','vreyes','Victor','Reyes',1019,'dmz')
    ,@('Northwind','npetrova','Nina','Petrova',1020,'dmz')
    # Contoso - 7
    ,@('Contoso','fmills','Frank','Mills',2001,'corp')
    ,@('Contoso','ipark','Ivy','Park',2002,'corp')
    ,@('Contoso','cdiaz','Carlos','Diaz',2003,'emea')
    ,@('Contoso','hschmidt','Hannah','Schmidt',2004,'emea')
    ,@('Contoso','rmehta','Raj','Mehta',2005,'apac')
    ,@('Contoso','msaid','Mona','Said',2006,'apac')
    ,@('Contoso','lberg','Leo','Berg',2007,'dmz')
    # Fabrikam - 7
    ,@('Fabrikam','plind','Pia','Lind',3001,'corp')
    ,@('Fabrikam','tford','Tom','Ford',3002,'corp')
    ,@('Fabrikam','scohen','Sara','Cohen',3003,'emea')
    ,@('Fabrikam','badler','Ben','Adler',3004,'emea')
    ,@('Fabrikam','mwong','Mei','Wong',3005,'apac')
    ,@('Fabrikam','kshah','Karan','Shah',3006,'apac')
    ,@('Fabrikam','eroth','Eva','Roth',3007,'dmz')
    # Globex (customer org, NON-vendor) - 6
    ,@('Globex','amorgan','Alice','Morgan',4001,'corp')
    ,@('Globex','bturner','Bob','Turner',4002,'corp')
    ,@('Globex','clopez','Cara','Lopez',4003,'emea')
    ,@('Globex','dwebb','Dan','Webb',4004,'apac')
    ,@('Globex','efrost','Ella','Frost',4005,'dmz')
    ,@('Globex','ghunt','George','Hunt',4006,'corp')
)

$userBySam = @{}
$users = foreach ($r in $userRows) {
    $org = $r[0]; $sam = $r[1]; $given = $r[2]; $sn = $r[3]; $rid = $r[4]; $dom = $r[5]
    $m = $domMeta[$dom]
    $display = "$given $sn"
    if ($m.Struct -eq 'A') {
        $ouUser = if ($org -eq 'Globex') { 'OU=Staff' } else { 'OU=Contractors,OU=Vendors' }
    } else {
        $ouUser = 'CN=Users'
    }
    $u = [pscustomobject]@{
        SamAccountName         = $sam
        DisplayName            = $display
        GivenName              = $given
        Surname                = $sn
        Sid                    = "S-1-5-21-1001-2002-3003-$rid"
        DistinguishedName      = "CN=$display,$ouUser,$($m.Base)"
        UserPrincipalName      = "$sam@$($m.Fqdn)"
        Mail                   = "$sam@$($m.Fqdn)"
        Domain                 = $m.Fqdn
        Org                    = $org
        Enabled                = $true
        LockedOut              = $false
        Description            = "$org contractor account"
        AccountExpirationDate  = $null
        LastLogonDate          = '2024-10-01T09:00:00'
        PasswordLastSet        = '2024-06-01T09:00:00'
        PasswordNeverExpires   = $false
        BadLogonCount          = 0
        PasswordExpiryComputed = '133612200000000000'
    }
    $userBySam[$sam] = $u
    $u
}

# Deterministic overrides so the account-audit report has stable, meaningful oracle rows.
($userBySam['gbell']).Enabled = $false                              # disabled account
($userBySam['vreyes']).LockedOut = $true
($userBySam['vreyes']).BadLogonCount = 7                            # locked account with bad logons
($userBySam['npetrova']).PasswordNeverExpires = $true
($userBySam['npetrova']).PasswordExpiryComputed = '9223372036854775807'   # never -> blank in report

# --- Groups -------------------------------------------------------------------
# Fields: Name, Dom, Cont(token), Desc, Owner(sam|''), Members(@sams),
#         MemberGroups(@names, same domain), Fsid(@sams referenced as FSP),
#         Scope, Cat, Admin(bool), Mail, Org
$groupRows = @(
    @{ Name='Northwind Traders Admins'; Dom='corp'; Cont='NW'; Desc='Privileged administrators for the Northwind Traders logistics platform.'; Owner='jbrooks'; Members=@('mhale','tpatel'); MemberGroups=@(); Fsid=@(); Scope='Global'; Cat='Security'; Admin=$true; Mail=$null; Org='Northwind' }
    @{ Name='NWT Application Owners'; Dom='corp'; Cont='NW'; Desc='Application owners for NWT systems.'; Owner=''; Members=@('jbrooks'); MemberGroups=@(); Fsid=@('ohaddad'); Scope='Global'; Cat='Security'; Admin=$false; Mail=$null; Org='Northwind' }
    @{ Name='Logistics Integration RW'; Dom='corp'; Cont='GR'; Desc='Northwind Traders integration service accounts. Primary contact Jacob Brooks (jbrooks).'; Owner='lchen'; Members=@('dokafor','rsantos'); MemberGroups=@(); Fsid=@(); Scope='Global'; Cat='Security'; Admin=$false; Mail=$null; Org='Northwind' }
    @{ Name='NWT Finance Sync'; Dom='emea'; Cont='NW'; Desc='NWT finance reconciliation batch access.'; Owner=''; Members=@('bnguyen','sfischer'); MemberGroups=@(); Fsid=@(); Scope='Global'; Cat='Security'; Admin=$false; Mail=$null; Org='Northwind' }
    @{ Name='Northwind Support'; Dom='emea'; Cont='NW'; Desc='Northwind support contacts mailing list.'; Owner='egarcia'; Members=@('pnowak'); MemberGroups=@(); Fsid=@(); Scope='Universal'; Cat='Distribution'; Admin=$false; Mail='northwind-support@emea.globex.com'; Org='Northwind' }
    @{ Name='Traders Data Feed'; Dom='apac'; Cont='GR'; Desc='Northwind Traders APAC data feed consumers.'; Owner=''; Members=@('ytanaka','wliu'); MemberGroups=@(); Fsid=@(); Scope='Global'; Cat='Security'; Admin=$false; Mail=$null; Org='Northwind' }
    @{ Name='APAC Vendor Access'; Dom='apac'; Cont='GR'; Desc='Access bundle for Northwind (NWT) APAC contractors.'; Owner=''; Members=@('stui'); MemberGroups=@('Traders Data Feed'); Fsid=@(); Scope='Global'; Cat='Security'; Admin=$false; Mail=$null; Org='Northwind' }
    @{ Name='Northwind RW'; Dom='dmz'; Cont='GR'; Desc='Northwind read-write file share access.'; Owner=''; Members=@('ohaddad','gbell'); MemberGroups=@(); Fsid=@(); Scope='Global'; Cat='Security'; Admin=$false; Mail=$null; Org='Northwind' }
    @{ Name='Global Logistics Stewards'; Dom='corp'; Cont='GR'; Desc='Logistics governance stewards and change approvers.'; Owner=''; Members=@(); MemberGroups=@('Northwind Traders Admins'); Fsid=@(); Scope='Global'; Cat='Security'; Admin=$false; Mail=$null; Org='Northwind' }
    @{ Name='Project Atlas Team'; Dom='corp'; Cont='GR'; Desc='Project Atlas delivery team workspace access.'; Owner=''; Members=@('bturner'); MemberGroups=@(); Fsid=@(); Scope='Global'; Cat='Security'; Admin=$false; Mail=$null; Org='Northwind' }
    @{ Name='Freight Portal Ops'; Dom='corp'; Cont='GR'; Desc='Freight portal operations crew for carrier scheduling.'; Owner=''; Members=@('kvolkov','awright'); MemberGroups=@(); Fsid=@(); Scope='Global'; Cat='Security'; Admin=$false; Mail=$null; Org='Northwind' }
    @{ Name='Freight Terminal Access'; Dom='corp'; Cont='GR'; Desc='Terminal booking system access. Managed by Freight Portal Ops.'; Owner=''; Members=@('amorgan'); MemberGroups=@(); Fsid=@(); Scope='Global'; Cat='Security'; Admin=$false; Mail=$null; Org='Northwind' }
    @{ Name='Contoso Service Desk'; Dom='corp'; Cont='CO'; Desc='Contoso managed service desk operators.'; Owner=''; Members=@('fmills','ipark'); MemberGroups=@(); Fsid=@(); Scope='Global'; Cat='Security'; Admin=$false; Mail=$null; Org='Contoso' }
    @{ Name='Contoso Billing Admins'; Dom='emea'; Cont='CO'; Desc='Contoso billing administration.'; Owner=''; Members=@('cdiaz'); MemberGroups=@(); Fsid=@(); Scope='Global'; Cat='Security'; Admin=$false; Mail=$null; Org='Contoso' }
    @{ Name='Contoso EDI Integration'; Dom='apac'; Cont='GR'; Desc='Contoso EDI integration endpoints.'; Owner=''; Members=@('rmehta'); MemberGroups=@(); Fsid=@(); Scope='Global'; Cat='Security'; Admin=$false; Mail=$null; Org='Contoso' }
    @{ Name='Fabrikam Plant Ops'; Dom='corp'; Cont='FA'; Desc='Fabrikam plant operations technicians.'; Owner=''; Members=@('plind','tford'); MemberGroups=@(); Fsid=@(); Scope='Global'; Cat='Security'; Admin=$false; Mail=$null; Org='Fabrikam' }
    @{ Name='Fabrikam QA Team'; Dom='emea'; Cont='FA'; Desc='Fabrikam quality assurance team.'; Owner=''; Members=@('scohen','badler'); MemberGroups=@(); Fsid=@(); Scope='Global'; Cat='Security'; Admin=$false; Mail=$null; Org='Fabrikam' }
    @{ Name='Fabrikam Sensor Net'; Dom='dmz'; Cont='GR'; Desc='Fabrikam IoT sensor network service accounts.'; Owner=''; Members=@('eroth'); MemberGroups=@(); Fsid=@(); Scope='Global'; Cat='Security'; Admin=$false; Mail=$null; Org='Fabrikam' }
    @{ Name='Globex IT Admins'; Dom='corp'; Cont='GR'; Desc='Globex corporate IT administrators.'; Owner='ghunt'; Members=@('amorgan','bturner'); MemberGroups=@(); Fsid=@(); Scope='Global'; Cat='Security'; Admin=$true; Mail=$null; Org='Globex' }
    @{ Name='Globex Helpdesk'; Dom='emea'; Cont='GR'; Desc='Globex internal helpdesk.'; Owner=''; Members=@('clopez'); MemberGroups=@(); Fsid=@(); Scope='Global'; Cat='Security'; Admin=$false; Mail=$null; Org='Globex' }
    @{ Name='All Staff'; Dom='apac'; Cont='GR'; Desc='All APAC staff distribution list.'; Owner=''; Members=@('ytanaka','wliu','rmehta','mwong','dwebb'); MemberGroups=@(); Fsid=@(); Scope='Universal'; Cat='Distribution'; Admin=$false; Mail='all-staff@apac.globex.local'; Org='Globex' }
    @{ Name='Globex All Employees'; Dom='dmz'; Cont='GR'; Desc='All Globex employees.'; Owner=''; Members=@('ohaddad','gbell','eroth','efrost'); MemberGroups=@(); Fsid=@(); Scope='Universal'; Cat='Distribution'; Admin=$false; Mail='all-employees@dmz.globex.net'; Org='Globex' }
    # Built-in group with an incidental vendor member (jbrooks): surfaces as Low,
    # but its generic name must NOT become a trusted description token.
    @{ Name='Domain Admins'; Dom='corp'; Cont='BI'; Desc='Designated administrators of the domain.'; Owner=''; Members=@('amorgan','ghunt','jbrooks'); MemberGroups=@(); Fsid=@(); Scope='Global'; Cat='Security'; Admin=$true; Mail=$null; Org='Globex' }
    # Decoy: mentions Domain Admins in its description but has no vendor link;
    # must not surface (regression guard for description-name trust).
    @{ Name='SQL Backup Operators'; Dom='corp'; Cont='GR'; Desc='SQL estate backup job operators. Escalations handled by Domain Admins.'; Owner=''; Members=@('bturner'); MemberGroups=@(); Fsid=@(); Scope='Global'; Cat='Security'; Admin=$false; Mail=$null; Org='Globex' }
)

function Get-ContainerPath([string]$token) {
    switch ($token) {
        'NW' { 'OU=Northwind,OU=Vendors' }
        'CO' { 'OU=Contoso,OU=Vendors' }
        'FA' { 'OU=Fabrikam,OU=Vendors' }
        'GR' { 'OU=Groups' }
        'BI' { 'CN=Users' }
        default { throw "Unknown container token '$token'" }
    }
}

# Pass 1: compute every group's DN so member-group references can resolve.
$groupDnByName = @{}
foreach ($g in $groupRows) {
    $base = $domMeta[$g.Dom].Base
    $groupDnByName[$g.Name] = "CN=$($g.Name),$(Get-ContainerPath $g.Cont),$base"
}

# Pass 2: resolve members/owner/foreign-SID/nested groups, and reverse memberOf.
$memberOfByName = @{}
foreach ($g in $groupRows) { $memberOfByName[$g.Name] = New-Object System.Collections.Generic.List[string] }
foreach ($g in $groupRows) {
    foreach ($childName in $g.MemberGroups) {
        $memberOfByName[$childName].Add($groupDnByName[$g.Name])
    }
}

$groups = foreach ($g in $groupRows) {
    $m = $domMeta[$g.Dom]
    $memberDns = New-Object System.Collections.Generic.List[string]
    foreach ($sam in $g.Members)       { $memberDns.Add($userBySam[$sam].DistinguishedName) }
    foreach ($name in $g.MemberGroups) { $memberDns.Add($groupDnByName[$name]) }
    foreach ($sam in $g.Fsid)          { $memberDns.Add("CN=$($userBySam[$sam].Sid),CN=ForeignSecurityPrincipals,$($m.Base)") }

    $managedBy = ''
    if ($g.Owner) { $managedBy = $userBySam[$g.Owner].DistinguishedName }

    [pscustomobject]@{
        Domain            = $m.Fqdn
        Name              = $g.Name
        DistinguishedName = $groupDnByName[$g.Name]
        Description       = $g.Desc
        Info              = ''
        ManagedBy         = $managedBy
        Member            = $memberDns.ToArray()
        MemberOf          = $memberOfByName[$g.Name].ToArray()
        GroupScope        = $g.Scope
        GroupCategory     = $g.Cat
        Mail              = $g.Mail
        AdminCount        = $(if ($g.Admin) { 1 } else { $null })
        WhenCreated       = '2021-06-01T09:00:00'
        WhenChanged       = '2024-10-15T14:30:00'
        Org               = $g.Org
    }
}

# --- Emit directory.json ------------------------------------------------------
$directory = [pscustomobject]@{
    Domains = @($domMeta.GetEnumerator() | ForEach-Object {
        [pscustomobject]@{ Domain = $_.Value.Fqdn; Server = $_.Value.Server; Name = $_.Value.Name; Structure = $_.Value.Struct }
    })
    Users  = $users
    Groups = $groups
}
$directory | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $OutDir 'directory.json') -Encoding UTF8

# --- Emit discovery-input CSVs (discovering the PRIMARY vendor: Northwind) -----------
$inputDir = Join-Path $OutDir 'discovery-input'
if (-not (Test-Path -LiteralPath $inputDir)) { New-Item -ItemType Directory -Path $inputDir | Out-Null }

# users.csv - the 20 Northwind users
$users | Where-Object Org -eq 'Northwind' |
    Select-Object SamAccountName, @{ Name = 'UUserId'; Expression = { 'U' + ([string]$_.Sid).Split('-')[-1] } }, DisplayName |
    Export-Csv -LiteralPath (Join-Path $inputDir 'users.csv') -NoTypeInformation -Encoding UTF8

# domains.csv - all four discovered domains
@($domMeta.GetEnumerator() | ForEach-Object {
    [pscustomobject]@{ Domain = $_.Value.Fqdn; Server = $_.Value.Server; Name = $_.Value.Name }
}) | Export-Csv -LiteralPath (Join-Path $inputDir 'domains.csv') -NoTypeInformation -Encoding UTF8

# keywords.csv
@('Northwind','Northwind Traders','NWT') | ForEach-Object { [pscustomobject]@{ Keyword = $_ } } |
    Export-Csv -LiteralPath (Join-Path $inputDir 'keywords.csv') -NoTypeInformation -Encoding UTF8

# known.csv - a Northwind group with no automatic signal
@([pscustomobject]@{ Domain = 'corp.globex.com'; Identity = 'Project Atlas Team' }) |
    Export-Csv -LiteralPath (Join-Path $inputDir 'known.csv') -NoTypeInformation -Encoding UTF8

# exclude.csv - noisy customer "all staff" groups that would otherwise surface as Low
@(
    [pscustomobject]@{ Domain = 'apac.globex.local'; Identity = 'All Staff' }
    [pscustomobject]@{ Domain = 'dmz.globex.net';   Identity = 'Globex All Employees' }
) | Export-Csv -LiteralPath (Join-Path $inputDir 'exclude.csv') -NoTypeInformation -Encoding UTF8

Write-Host "Fixture written: $((Join-Path $OutDir 'directory.json'))"
Write-Host "  users=$($users.Count) groups=$($groups.Count) domains=$($domMeta.Count)"
Write-Host "Discovery-input CSVs written to: $inputDir"
