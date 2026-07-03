BeforeAll { . "$PSScriptRoot/_TestHelpers.ps1" }

Describe 'Get-LdapClauseBatches' {
    It 'yields one iterable batch per element with the clause cap honored' {
        $batches = @(Get-LdapClauseBatches -Clauses @('(a=1)', '(a=2)', '(a=3)') -MaxClauses 2)
        $batches.Count | Should -Be 2
        @($batches[0]).Count | Should -Be 2
        @($batches[1]).Count | Should -Be 1
        @($batches[0])[0] | Should -Be '(a=1)'
    }
    It 'starts a new batch when the character budget would overflow' {
        $long = '(a=' + ('x' * 50) + ')'
        $batches = @(Get-LdapClauseBatches -Clauses @($long, $long) -MaxChars 60)
        $batches.Count | Should -Be 2
    }
    It 'keeps an oversized single clause in its own batch rather than dropping it' {
        $huge = '(a=' + ('x' * 500) + ')'
        $batches = @(Get-LdapClauseBatches -Clauses @($huge) -MaxChars 60)
        $batches.Count | Should -Be 1
        @($batches[0]).Count | Should -Be 1
    }
    It 'skips null or empty clauses' {
        $batches = @(Get-LdapClauseBatches -Clauses @('(a=1)', '', $null, '(a=2)'))
        $batches.Count | Should -Be 1
        @($batches[0]).Count | Should -Be 2
    }
    It 'returns an empty array for no clauses' {
        $batches = @(Get-LdapClauseBatches -Clauses @())
        $batches.Count | Should -Be 0
    }
}
