@{
    RootModule        = 'VendorAdGroupDiscovery.psm1'
    ModuleVersion     = '0.1.0'
    GUID              = '9d3f5b62-1a4e-4c77-9b2a-0a1f2e3d4c50'
    Author            = 'Ashton Batty'
    Description       = 'Discover AD groups belonging to or used by a vendor across multiple domains.'
    PowerShellVersion = '5.1'
    FunctionsToExport = @('Find-VendorAdGroup')
}
