BeforeAll {
    . "$PSScriptRoot/_TestHelpers.ps1"
    $script:users = @(
        [pscustomobject]@{ SamAccountName='jsmith'; DisplayName='John Smith'
            Sid='S-1-5-21-1-2-3-1001'; DistinguishedName='CN=John Smith,OU=Vendor,DC=corp,DC=example,DC=com' }
    )
}

Describe 'Get-OwnerMatchReason' {
    It 'emits an Owner reason when managedBy is a vendor user' {
        (Get-OwnerMatchReason -ManagedBy 'CN=John Smith,OU=Vendor,DC=corp,DC=example,DC=com' -VendorUsers $users).Pattern | Should -Be 'Owner'
    }
    It 'emits nothing when managedBy is empty' {
        Get-OwnerMatchReason -ManagedBy '' -VendorUsers $users | Should -BeNullOrEmpty
    }
}

Describe 'Get-MemberMatchReasons' {
    It 'emits one MemberVendorUser reason per vendor member' {
        $r = @(Get-MemberMatchReasons -Member @('CN=John Smith,OU=Vendor,DC=corp,DC=example,DC=com','CN=Other,DC=x') -VendorUsers $users)
        $r.Count | Should -Be 1
        $r[0].Pattern | Should -Be 'MemberVendorUser'
    }
}
