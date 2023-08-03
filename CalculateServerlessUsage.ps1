<#
.SYNOPSIS
    A way to estimate serverless SQL costs based on provisioned SQL Usage. This is easiest to run in  something like Azure Cloud Shell.

.DESCRIPTION
    This script estimates SQL Serverless costs by utilizing past usage of your provisioned databases.
    It gets this by querying the CPU metrics for your DB and doing some basic math to determine CPU Seconds
    used. From this is then queries the retail pricing information to get you the most accurate price.

    We also take into account your Max used storage and use that to calculate storage costs.

.EXAMPLE
    PS> ./CalculateServerlessUsage.ps1
    Will output estimates for all databases on your subscription.

.EXAMPLE
    PS> ./CalculateServerlessUsage.ps1 -ResourceGroupName <your resource group>
    Will output estimates for all databases in the specified resource group.

.EXAMPLE
    PS> ./CalculateServerlessUsage.ps1 -ResourceGroupName <your resource group> -ServerName <your server name>
    Will output estimates for all databases in the specified logical server.

.EXAMPLE
    PS> ./CalculateServerlessUsage.ps1 -ResourceGroupName <your resource group> -ServerName <your server name> -DatabaseName <your database name>
    Will output estimates for the specified database.
#>
param(
    # The resource group you would like to query
    [string]$ResourceGroupName="",
    # The sql server name (without .database.windows.net)
    [string]$ServerName="",
    #The Database name that you want to check
    [string]$DatabaseName=""
)
$sql_dbs = @{}
$resultsArray = [System.Collections.ArrayList]@()
if($ResourceGroupName -eq "" -and $ServerName -eq "" -and $DatabaseName -eq "") {
    $sql_dbs = Get-AzSqlServer | Get-AzSqlDatabase | Where-Object {$_.DatabaseName -ne "master" -and $_.SkuName -ne "DataWarehouse"}
} elseif($ServerName -eq "" -and $DatabaseName -eq "") {
    $sql_dbs = Get-AzSqlServer -ResourceGroupName $ResourceGroupName | Get-AzSqlDatabase | Where-Object {$_.DatabaseName -ne "master" -and $_.SkuName -ne "DataWarehouse"}
} elseif($DatabaseName -eq "") {
    $sql_dbs = Get-AzSqlDatabase -ResourceGroupName $ResourceGroupName -ServerName $ServerName
} else {
    $sql_dbs = Get-AzSqlDatabase -ResourceGroupName $ResourceGroupName -ServerName $ServerName -DatabaseName $DatabaseName
}

foreach($sql_db in $sql_dbs) {
    Write-Information "Processing Database $($sql_db.DatabaseName) on Server $($sql_db.ServerName)"
    if($sql_db.SkuName -eq "BC_Gen5" -or $sql_db.SkuName -eq "Premium") {
        Write-Warning "Database $($sql_db.DatabaseName) on Server $($sql_db.ServerName) has a Premium or Business Critical sku, results will be potentially invalid."
    }
    # Get the last 730 hours of usage, because then I don't have to do math.
    Write-Debug "Starting Metrics Request"
    $metrics = Get-AzMetric -ResourceId $sql_db.ResourceId -MetricName "cpu_percent" -TimeGrain 00:01:00 -AggregationType Maximum -StartTime $(Get-Date).AddHours(-730)
    Write-Debug "Finished Metrics Request"
    $is_vcore = ($sql_db.Family)

    $current_dtu = 0
    $current_vcore = 0

    if($is_vcore) {
        $current_dtu = $sql_db.Capacity * 100
        $current_vcore = $sql_db.Capacity
    } else {
        $current_dtu = $sql_db.Capacity
        $current_vcore = $sql_db.Capacity/100
    }

    $sql_min_max_info = Invoke-RestMethod -Uri "https://raw.githubusercontent.com/cbattlegear/CalculateServerlessUsage/main/min_max_vcores_serverless.json"
    $sku_match = @{}
    foreach ($sku in $sql_min_max_info.serverless_skus ) {
        if($sku.max_cpu -ge $current_vcore)
        { 
            $sku_match = $sku
            break
        } 
    }
    $min_serverless_cores = $sku_match.min_cpu
    $max_serverless_cores = $sku_match.max_cpu
    $min_cpu_seconds_in_minute = $min_serverless_cores * 60

    $total_cpu_seconds = 0

    foreach($metric in $metrics.data) {
        $max_cpu = $metric.Maximum
        $cpu_seconds_in_minute = ($current_dtu/100) * ($max_cpu/100) * 60
        if($cpu_seconds_in_minute -lt $min_cpu_seconds_in_minute) {
            $total_cpu_seconds += $min_cpu_seconds_in_minute
        } else {
            $total_cpu_seconds += $cpu_seconds_in_minute
        }
    }


    $pricing_url = "https://prices.azure.com/api/retail/prices?api-version=2023-01-01-preview&meterRegion='primary'&`$filter=productName eq 'SQL Database Single General Purpose - Serverless - Compute Gen5' and skuName eq '1 vCore' and armRegionName eq '$($sql_db.Location)' and meterName eq 'vCore'"
    $response = Invoke-RestMethod -Uri $pricing_url
    $price_per_second = $response.Items[0].retailPrice/60/60

    $storage_pricing_url = "https://prices.azure.com/api/retail/prices?api-version=2023-01-01-preview&`$filter=armRegionName eq '$($sql_db.Location)' and productName eq 'SQL Database Single/Elastic Pool General Purpose - Storage' and meterName eq 'General Purpose Data Stored'"
    $storage_response = Invoke-RestMethod -Uri $pricing_url
    $storage_price_per_gig = $response.Items[0].retailPrice
    $total_storage_cost = ($sql_db.MaxSizeBytes / 1Gb) * $storage_price_per_gig

    $total_cost = $total_cpu_seconds * $price_per_second
    # Write-Host "Total CPU seconds in 1 Month (730 hours): $total_cpu_seconds"
    # Write-Host "Total Cost for 1 Month (730 hours) of compute: `$$total_cost"
    $results = [PSCustomObject] @{
        ResourceGroupName = $sql_db.ResourceGroupName;
        ServerName = $sql_db.ServerName;
        DatabaseName = $sql_db.DatabaseName;
        EstimatedCpuSeconds = $total_cpu_seconds;
        EstimatedComputeCost = $total_cost;
        EstimatedStorageCost = $total_storage_cost;
        EstimatedTotalCost = $total_cost + $total_storage_cost;
    }
    $resultsArray.Add($results)
}

Write-Output $resultsArray