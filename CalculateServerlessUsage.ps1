$sql_db = Get-AzSqlDatabase -ResourceGroupName azure_resources -ServerName "sqlazureeight" -DatabaseName "sqldbeight"
# Get the last 730 hours of usage, because then I don't have to do math.
$metrics = Get-AzMetric -ResourceId $sql_db.ResourceId -MetricName "cpu_percent" -TimeGrain 00:01:00 -DetailedOutput -AggregationType Maximum -StartTime $(Get-Date).AddHours(-730)

$min_serverless_cores = 0.5
$max_serverless_cores = 2
$min_cpu_seconds_in_minute = $min_serverless_cores * 60

$is_vcore = ($sql_db.Family)

$current_dtu = 0

if($is_vcore) {
    $current_dtu = $sql_db.Capacity * 100
} else {
    $current_dtu = $sql_db.Capacity
}

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

Write-Host "Total CPU seconds in 1 Month (730 hours): $total_cpu_seconds"
$pricing_url = "https://prices.azure.com/api/retail/prices?api-version=2023-01-01-preview&meterRegion='primary'&`$filter=productName eq 'SQL Database Single General Purpose - Serverless - Compute Gen5' and skuName eq '1 vCore' and armRegionName eq '$($sql_db.Location)' and meterName eq 'vCore'"
$response = Invoke-RestMethod -Uri $pricing_url
$price_per_second = $response.Items[0].retailPrice/60/60

$total_cost = $total_cpu_seconds * $price_per_second

Write-Host "Total Cost for 1 Month (730 hours) of compute: `$$total_cost"