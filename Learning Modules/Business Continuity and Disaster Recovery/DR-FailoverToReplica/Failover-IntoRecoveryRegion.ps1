<#
.SYNOPSIS
  Recovers the Wingtip Tickets application into a recovery region by failing over to replicas

.DESCRIPTION
  This script recovers the Wingtip tickets application into a recovery region by failing over to database and app replicas.
  It is assumed that replicas are created using SQL database georeplication prior to running this script.

.PARAMETER StatusCheckTimeInterval
  This determines how often the script will check on the status of background failover jobs. The script will wait the provided time in seconds before checking the status again.

.PARAMETER NoEcho
  This stops the output of the signed in user to prevent double echo of subscription details

.EXAMPLE
  [PS] C:\>.\Failover-IntoRecoveryRegion
#>
[cmdletbinding()]
param (
    # NoEcho stops the output of the signed in user to prevent double echo  
    [parameter(Mandatory=$false)]
    [switch] $NoEcho,

    [parameter(Mandatory=$false)]
    [Int] $StatusCheckTimeInterval = 10
)

#----------------------------------------------------------[Initialization]----------------------------------------------------------

Import-Module $PSScriptRoot\..\..\Common\CatalogAndDatabaseManagement -Force
Import-Module $PSScriptRoot\..\..\WtpConfig -Force
Import-Module $PSScriptRoot\..\..\UserConfig -Force
Import-Module $PSScriptRoot\FormatJobOutput -Force

# Stop execution on error 
$ErrorActionPreference = "Stop"

# Get deployment configuration  
$wtpUser = Get-UserConfig
$config = Get-Configuration

# Get Azure credentials
$credentialLoad = Import-AzureRmContext -Path "$env:TEMP\profile.json" -ErrorAction SilentlyContinue
if (!$credentialLoad)
{
  Initialize-Subscription -NoEcho:$NoEcho.IsPresent
}

$recoveryResourceGroupName = $wtpUser.ResourceGroupName + $config.RecoveryRoleSuffix
$originLocation = (Get-AzureRmResourceGroup -ResourceGroupName $wtpUser.ResourceGroupName).Location
$recoveryLocation = (Get-AzureRmResourceGroup -ResourceGroupName $recoveryResourceGroupName).Location
$recoveryCatalogServerName = $config.CatalogServerNameStem + $wtpUser.Name + $config.RecoveryRoleSuffix 
$originCatalogServerName = $config.CatalogServerNameStem + $wtpUser.Name
$catalogFailoverGroupName = $config.CatalogFailoverGroupNameStem + $wtpUser.Name

#-------------------------------------------------------[Main Script]------------------------------------------------------------

$startTime = Get-Date

Write-Output "Original region: $originLocation,  Recovery region: $recoveryLocation"

# Disable traffic manager web app endpoint in origin region
Write-Output "Disabling Traffic Manager endpoint in origin region ..."
$profileName = $config.EventsAppNameStem + $wtpUser.Name
$originAppEndpoint = $config.EventsAppNameStem + $originLocation + '-' + $wtpUser.Name
Disable-AzureRmTrafficManagerEndpoint -Name $originAppEndpoint -Type AzureEndpoints -ProfileName $profileName -ResourceGroupName $wtpUser.ResourceGroupName -Force -ErrorAction SilentlyContinue > $null

# Get catalog failover group
$catalogFailoverGroup = Get-AzureRmSqlDatabaseFailoverGroup `
                          -ResourceGroupName $wtpUser.ResourceGroupName `
                          -ServerName $originCatalogServerName `
                          -FailoverGroupName $catalogFailoverGroupName `
                          -ErrorAction Stop

# Force-failover catalog database to recovery region (if applicable)
if (($catalogFailoverGroup.ReplicationState -eq 'CATCH_UP') -and ($catalogFailoverGroup.ReplicationRole -eq 'Primary'))
{
  Write-Output "Failing over catalog database to recovery region ..."
  Switch-AzureRmSqlDatabaseFailoverGroup `
    -ResourceGroupName $recoveryResourceGroupName `
    -ServerName $recoveryCatalogServerName `
    -FailoverGroupName $catalogFailoverGroupName `
    -AllowDataLoss`
    -ErrorAction Stop `
    >$null
}
elseif ($catalogFailoverGroup.ReplicationState -In 'PENDING', 'SEEDING')
{
  Write-Output "Catalog database in recovery region is still being seeded with data from the recovery region. Try running the failover script again later."
  exit
}
else
{
  Write-Output "Catalog database already failed over to recovery region ..."
}

# Get DNS alias for catalog server
$catalogAliasName = $config.ActiveCatalogAliasStem + $wtpUser.Name
$fullyQualifiedCatalogAlias = $catalogAliasName + ".database.windows.net"
$activeCatalogServerName = Get-ServerNameFromAlias $fullyQualifiedCatalogAlias -ErrorAction Stop

# Update catalog alias to point to recovery region catalog (if applicable)
if ($activeCatalogServerName -ne $recoveryCatalogServerName)
{
  Write-Output "Updating catalog alias to point to recovery region instance..."
  Set-DnsAlias `
    -ResourceGroupName $recoveryResourceGroupName `
    -ServerName $recoveryCatalogServerName `
    -ServerDNSAlias $catalogAliasName `
    -OldResourceGroupName $wtpUser.ResourceGroupName `
    -OldServerName $activeCatalogServerName `
    -PollDnsUpdate
}

# Initalize Azure context for background scripts  
$scriptPath= $PSScriptRoot
Save-AzureRmContext -Path "$env:TEMP\profile.json" -Force -ErrorAction Stop

# Start background process to sync tenant server, pool, and database configuration info into the catalog 
$runningScripts = (Get-WmiObject -Class Win32_Process -Filter "Name='PowerShell.exe'").CommandLine
if (!($runningScripts -like "*Sync-TenantConfiguration*"))
{
  Start-Process powershell.exe -ArgumentList "-NoExit &'$PSScriptRoot\Sync-TenantConfiguration.ps1'"
}

# Get the active tenant catalog 
$tenantCatalog = Get-Catalog -ResourceGroupName $wtpUser.ResourceGroupName -WtpUser $wtpUser.Name
Write-Output "Acquired tenant catalog in recovery region ..."

# Get list of tenants registered in catalog
$tenantList = Get-Tenants -Catalog $tenantCatalog -ErrorAction Stop

# Mark all non-recovered tenants as unavailable in the catalog
Write-Output "Marking non-recovered tenants offline in the catalog..."
foreach ($tenant in $tenantList)
{
  $tenantStatus = (Get-ExtendedTenant -Catalog $tenantCatalog -TenantKey $tenant.Key).TenantRecoveryState

  if ($tenantStatus -NotIn 'OnlineInRecovery')
  {
    Set-TenantOffline -Catalog $tenantCatalog -TenantKey $tenant.Key -ErrorAction Stop
  }
}

# Enable traffic manager endpoint in recovery region (if applicable)
$recoveryAppEndpointName = $config.EventsAppNameStem + $recoveryLocation + '-' + $wtpUser.Name
$recoveryAppEndpoint = Get-AzureRmTrafficManagerEndpoint -Name $recoveryAppEndpointName -Type AzureEndpoints -ProfileName $profileName -ResourceGroupName $wtpUser.ResourceGroupName
if ($recoveryAppEndpoint.EndpointStatus -ne 'Enabled')
{
  Write-Output "Enabling traffic manager endpoint for Wingtip events app in recovery region..."
  Enable-AzureRmTrafficManagerEndpoint -Name $recoveryAppEndpointName -Type AzureEndpoints -ProfileName $profileName -ResourceGroupName $wtpUser.ResourceGroupName -ErrorAction Stop > $null
}

# Start background job to failover tenant databases
$databaseRecoveryJob = Start-Job -Name "DatabaseRecovery" -FilePath "$PSScriptRoot\RecoveryJobs\Failover-TenantDatabasesToRecoveryRegion.ps1" -ArgumentList @($recoveryResourceGroupName)

# Start background job to mark tenants online when failover is complete 
$tenantRecoveryJob = Start-Job -Name "TenantRecovery" -FilePath "$PSScriptRoot\RecoveryJobs\Enable-TenantsAfterRecoveryOperation.ps1" -ArgumentList @($recoveryResourceGroupName)

# Monitor status of recovery jobs.
while ($true)
{
  # Get state of all failover jobs. Stop recovery if there is an error with any job
  $databaseRecoveryStatus = Receive-Job $databaseRecoveryJob -Keep -ErrorAction Stop
  $tenantRecoveryStatus = Receive-Job $tenantRecoveryJob -Keep -ErrorAction Stop  

  # Initialize and format output for failover jobs 
  $databaseRecoveryStatus = Format-JobOutput $databaseRecoveryStatus
  $tenantRecoveryStatus = Format-JobOutput $tenantRecoveryStatus
  
  # Output status of recovery jobs to console
  [PSCustomObject] @{
    Tenants = $tenantRecoveryStatus
    TenantDatabases = $databaseRecoveryStatus
  } | Format-List
  

  # Exit recovery if all tenant databases have been recovered 
  if (($databaseRecoveryJob.State -eq "Completed") -and ($tenantRecoveryJob.State -eq "Completed"))
  {
    Remove-Item -Path "$env:TEMP\profile.json" -ErrorAction SilentlyContinue
    break
  }
  else
  {
    Write-Output "---`nRefreshing status in $StatusCheckTimeInterval seconds..."
    Start-Sleep $StatusCheckTimeInterval
    $elapsedTime = (Get-Date) - $startTime
  }          
}

Write-Output "'$($wtpUser.ResourceGroupName)' deployment recovered into '$recoveryLocation' region in $($elapsedTime.TotalMinutes) minutes."