using module ../../SovereignTrust.Foundation/Src/PowerShell/SovereignTrust.Foundation.psd1

$ErrorActionPreference = 'Stop'
function Assert([bool]$condition, [string]$message) { if (-not $condition) { throw $message } }
Import-Module (Join-Path $PSScriptRoot '../Src/Storage/AzureKeyVault/PowerShell/Storage_AzureKeyVault.psd1') -Force
$module = Get-Module Storage_AzureKeyVault

& $module {
    $script:calls = @()
    $script:reply = $null
    $script:failResponse = $false
    function Invoke-MappedAdapter {
        param($Adapter, $Activity, $Signal, $Plan, $ItemSignal)
        if ($Adapter -ne 'Condenser.Rest') { throw 'Unexpected real adapter dispatch.' }
        $script:calls += [pscustomobject]@{ Activity = $Activity; Config = $Plan.Config }
        $r = [Signal]::Start('KeyVaultMock', $ItemSignal) | Select-Object -Last 1
        if ($script:failResponse) { $r.LogCritical('SENTINEL_SECRET failed response') | Out-Null }
        else { $r.SetResult($script:reply) }
        return $r
    }
    $s = [Signal]::Start('KeyVaultTest') | Select-Object -Last 1
    $adapter = [Storage_AzureKeyVault]::new()
    $v2 = [pscustomobject]@{ SchemaVersion = 2; Resource = @([pscustomobject]@{ Key='vault'; Vault='vault' }); Routes = @([pscustomobject]@{ Key='primary'; Address='https://vault.vault.azure.net/'; ResourceKey='vault' }) }
    Assert (($adapter.Construct($v2)).Success()) 'Valid v2 Key Vault jacket failed.'
    Assert (($adapter.Construct([pscustomobject]@{ SchemaVersion=2; Resource=@([pscustomobject]@{Key='vault';Vault='wrong'}); Routes=@([pscustomobject]@{Key='primary';Address='https://vault.vault.azure.net/';ResourceKey='vault'}) })).Failure()) 'Mismatched v2 vault was accepted.'
    $null = $adapter.Construct($v2)
    $script:calls = @()
    $plan = [pscustomobject]@{ Container = ''; Resource = 'sample'; VirtualPath = '/sample'; Config = [pscustomobject]@{ Content = [pscustomobject]@{ Data='Test' } } }
    $script:reply = [pscustomobject]@{ StatusCode=200; Response=[pscustomobject]@{ id='https://vault.vault.azure.net/secrets/sample/version1' } }
    $write = $adapter.Invoke('Secrets','Write',$s,$plan,$s)
    Assert ($write.Success() -and $write.GetResult() -match '/version1$' -and $script:calls.Count -eq 1 -and $script:calls[0].Activity -eq 'Put' -and $script:calls[0].Config.ReturnHttpStatus -and $script:calls[0].Config.RedactDiagnostics) 'Key Vault Write status/id/redaction contract failed.'
    $plan.Config.Content = [pscustomobject]@{ Data='Again' }
    $script:reply.Response.id = 'https://vault.vault.azure.net/secrets/sample/version2'
    $secondWrite = $adapter.Invoke('Secrets','Write',$s,$plan,$s)
    Assert ($secondWrite.Success() -and $secondWrite.GetResult() -match '/version2$' -and
        $secondWrite.GetResult() -cne $write.GetResult()) 'Repeated Write did not return a distinct version id.'
    $script:reply = [pscustomobject]@{ StatusCode=200; Response=[pscustomobject]@{ value='{"Data":"Again"}' } }
    $latestRead = $adapter.Invoke('Secrets','Read',$s,$plan,$s)
    Assert ($latestRead.Success() -and $latestRead.GetResult() -ceq '{"Data":"Again"}') 'Latest Read did not return the mocked second version.'
    $script:reply = [pscustomobject]@{ StatusCode=200; Response=[pscustomobject]@{ id='https://vault.vault.azure.net/secrets/sample/version2' } }
    $writtenBody = $script:calls[0].Config.Body | ConvertFrom-Json
    $writtenValue = $writtenBody.value | ConvertFrom-Json
    Assert ($writtenValue.Data -ceq 'Test' -and $script:calls[0].Config.Body -notmatch 'SourcePath') 'Key Vault Write body contract failed.'
    $plan.Config = [pscustomobject]@{ Content='' }
    Assert (($adapter.Invoke('Secrets','Write',$s,$plan,$s)).Success() -and
        ($script:calls[-1].Config.Body | ConvertFrom-Json).value -ceq '') 'Empty string Write was rejected.'
    $plan.Config = [pscustomobject]@{ Content=('x' * 25601) }
    $before = $script:calls.Count
    Assert (($adapter.Invoke('Secrets','Write',$s,$plan,$s)).Failure() -and $script:calls.Count -eq $before) 'Oversize Write reached provider.'
    $plan.Config = [pscustomobject]@{ Content=[byte[]]@(1,2,3) }
    Assert (($adapter.Invoke('Secrets','Write',$s,$plan,$s)).Failure() -and $script:calls.Count -eq $before) 'Binary byte array reached provider.'
    $plan.Config = [pscustomobject]@{ Content=[object[]]@([pscustomobject]@{ Data='Test' },[pscustomobject]@{ Data='Again' }) }
    $jsonArrayWrite = $adapter.Invoke('Secrets','Write',$s,$plan,$s)
    $arrayBody = $script:calls[-1].Config.Body | ConvertFrom-Json
    $arrayValue = $arrayBody.value | ConvertFrom-Json
    Assert ($jsonArrayWrite.Success() -and @($arrayValue).Count -eq 2 -and $arrayValue[1].Data -ceq 'Again') 'Ordinary JSON array Write regressed.'
    $script:reply = [pscustomobject]@{ StatusCode=200; Response=[pscustomobject]@{ value='SENTINEL_SECRET' } }
    $plan.Config = [pscustomobject]@{}
    Assert (($adapter.Invoke('Secrets','Read',$s,$plan,$s)).GetResult() -ceq 'SENTINEL_SECRET') 'Authorized in-memory Read Result was lost.'
    $script:failResponse = $true
    $failedRead = $adapter.Invoke('Secrets','Read',$s,$plan,$s)
    Assert ($failedRead.Failure() -and -not $failedRead.HasResult() -and
        (@($failedRead.Entries.Message) -join '|') -notmatch 'SENTINEL_SECRET') 'Failed Read leaked provider diagnostics.'
    $script:failResponse = $false
    $plan.Config = [pscustomobject]@{}
    $script:reply = [pscustomobject]@{ StatusCode=200; Response=[pscustomobject]@{ value='{"Data":"Test"}' } }
    $read = $adapter.Invoke('Secrets','Read',$s,$plan,$s)
    Assert ($read.Success() -and $read.GetResult() -ceq '{"Data":"Test"}' -and $script:calls[-1].Activity -eq 'Get' -and $script:calls[-1].Config.RedactDiagnostics) 'Key Vault Read contract failed.'
    $script:reply = [pscustomobject]@{ StatusCode=404; Response=[pscustomobject]@{ error='not found' } }
    $exists = $adapter.Invoke('Secrets','Exists',$s,$plan,$s)
    Assert ($exists.Success() -and $exists.HasResult() -and $exists.GetResult() -is [bool] -and -not $exists.GetResult()) 'Key Vault Exists 404 contract failed.'
    $script:reply.StatusCode = 403
    Assert (($adapter.Invoke('Secrets','Exists',$s,$plan,$s)).Failure()) 'Key Vault Exists 403 was treated as absence.'
    foreach ($badStatus in @(401,429,500,$null)) {
        $script:reply.StatusCode = $badStatus
        Assert (($adapter.Invoke('Secrets','Exists',$s,$plan,$s)).Failure()) 'Denied or missing Exists status was accepted.'
    }
    $script:reply.StatusCode = 404
    Assert (($adapter.Invoke('Secrets','Read',$s,$plan,$s)).Failure()) 'Read 404 was accepted.'
    Assert (($adapter.Invoke('Secrets','Delete',$s,$plan,$s)).Failure()) 'Delete 404 was accepted.'
    $script:reply = [pscustomobject]@{ StatusCode=200; Response=[pscustomobject]@{ id='https://vault.vault.azure.net/secrets/sample/version1' } }
    $delete = $adapter.Invoke('Secrets','Delete',$s,$plan,$s)
    Assert ($delete.Success() -and $delete.GetResult() -is [bool] -and $delete.GetResult() -and $script:calls[-1].Activity -eq 'Delete' -and $script:calls[-1].Config.RedactDiagnostics) 'Key Vault Delete contract failed.'
    $before = $script:calls.Count
    foreach ($bad in @('/sample/other','sample.json','/sample?x=1')) {
        $plan.VirtualPath = $bad
        Assert (($adapter.Invoke('Secrets','Read',$s,$plan,$s)).Failure()) 'Invalid Key Vault name reached provider.'
    }
    Assert ($script:calls.Count -eq $before) 'Invalid path caused provider dispatch.'
    $plan.VirtualPath = $null
    $plan.Container = 'inherited-parent-container'
    $plan.Config = [pscustomobject]@{ VirtualPath='Storage.Secrets.Read.sample' }
    $script:reply = [pscustomobject]@{ StatusCode=200; Response=[pscustomobject]@{ value='legacy' } }
    Assert (($adapter.Invoke('Secrets','Read',$s,$plan,$s)).GetResult() -ceq 'legacy') 'Legacy Read path regressed.'
    $plan.Config = [ordered]@{ VirtualPath='Storage.Secrets.Read.sample' }
    Assert (($adapter.Invoke('Secrets','Read',$s,$plan,$s)).GetResult() -ceq 'legacy') 'OrderedDictionary token Config.VirtualPath was not recognized.'
    Assert (($adapter.Invoke('Secrets','Delete',$s,$plan,$s)).Failure()) 'Legacy verb mismatch was accepted.'
    $plan.Config = [ordered]@{ VirtualPath='sample'; SourcePath='C:/invalid/source' }
    $before = $script:calls.Count
    Assert (($adapter.Invoke('Secrets','Read',$s,$plan,$s)).Failure() -and $script:calls.Count -eq $before) 'OrderedDictionary SourcePath reached provider.'
    $plan.Config = [pscustomobject]@{}
    $plan.VirtualPath = '/sample'
    $before = $script:calls.Count
    Assert (($adapter.Invoke('Secrets','Read',$s,$plan,$s)).Failure() -and $script:calls.Count -eq $before) 'Mapped path accepted a nonempty Container.'
    $plan.Config = [pscustomobject]@{ TargetPath='C:/invalid/target' }
    $before = $script:calls.Count
    Assert (($adapter.Invoke('Secrets','Read',$s,$plan,$s)).Failure() -and $script:calls.Count -eq $before) 'Key Vault TargetPath reached provider.'
}
Write-Output 'PASS: Key Vault activity mock contracts.'
