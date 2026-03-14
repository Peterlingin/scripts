# Log Volume Calculator - Daily to Monthly/Annual Projections
# Includes growth rate scenarios and automatically scales GB to TB

function Format-DataSize {
    param(
        [double]$SizeInGB
    )
    
    if ($SizeInGB -ge 1024) {
        $sizeInTB = $SizeInGB / 1024
        return "{0:N2} TB" -f $sizeInTB
    } else {
        return "{0:N2} GB" -f $SizeInGB
    }
}

function Calculate-GrowthProjection {
    param(
        [double]$DailyGB,
        [double]$GrowthRatePercent,
        [string]$GrowthMethod
    )
    
    if ($GrowthMethod -eq "Simple") {
        # Simple growth: apply percentage to baseline annual total
        $baselineAnnual = $DailyGB * 365
        $totalAnnual = $baselineAnnual * (1 + ($GrowthRatePercent / 100))
        $endYearDaily = $DailyGB * (1 + ($GrowthRatePercent / 100))
        
        return @{
            AnnualTotal = $totalAnnual
            EndYearDaily = $endYearDaily
        }
    } else {
        # Compound growth: daily volume increases gradually with monthly compounding
        $monthlyGrowthRate = $GrowthRatePercent / 12 / 100
        
        # Calculate total storage for a year with monthly compounding growth
        $totalAnnual = 0
        $currentDaily = $DailyGB
        
        for ($month = 1; $month -le 12; $month++) {
            $monthlyTotal = $currentDaily * 30
            $totalAnnual += $monthlyTotal
            # Apply growth for next month
            $currentDaily = $currentDaily * (1 + $monthlyGrowthRate)
        }
        
        # End-of-year daily volume
        $endYearDaily = $DailyGB * [Math]::Pow((1 + $monthlyGrowthRate), 12)
        
        return @{
            AnnualTotal = $totalAnnual
            EndYearDaily = $endYearDaily
        }
    }
}

# Main execution
Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "   Log Volume Projection Calculator" -ForegroundColor Cyan
Write-Host "   with Growth Rate Scenarios" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

$dailyInput = Read-Host "Enter daily log volume in GB"

if ($dailyInput -match "^\d+\.?\d*$") {
    $dailyGB = [double]$dailyInput
    
    # Ask for growth calculation method
    Write-Host "`nGrowth Calculation Methods:" -ForegroundColor Yellow
    Write-Host "1. Simple    - Apply growth % to total baseline (capacity planning)" -ForegroundColor White
    Write-Host "2. Compound  - Daily volume grows gradually over time (realistic modeling)" -ForegroundColor White
    $methodChoice = Read-Host "Select method (1 or 2, default: 1)"
    
    if ($methodChoice -eq "2") {
        $growthMethod = "Compound"
        Write-Host "Using Compound Growth method..." -ForegroundColor Green
    } else {
        $growthMethod = "Simple"
        Write-Host "Using Simple Growth method..." -ForegroundColor Green
    }
    
    # Ask for custom growth rate
    Write-Host "`nDefault growth scenarios: 5%, 10%, 20%, 30%, 50%" -ForegroundColor Yellow
    $customGrowthInput = Read-Host "Enter a custom annual growth % (or press Enter to use defaults)"
    
    # Determine growth rates to use
    if ([string]::IsNullOrWhiteSpace($customGrowthInput)) {
        $growthRates = @(5, 10, 20, 30, 50)
        Write-Host "Using default growth scenarios..." -ForegroundColor Green
    } elseif ($customGrowthInput -match "^\d+\.?\d*$") {
        $customRate = [double]$customGrowthInput
        $growthRates = @($customRate)
        Write-Host "Using custom growth rate: $customRate%" -ForegroundColor Green
    } else {
        Write-Host "Invalid growth rate. Using defaults..." -ForegroundColor Yellow
        $growthRates = @(5, 10, 20, 30, 50)
    }
    
    $monthlySizeGB = $dailyGB * 30
    $annualSizeGB = $dailyGB * 365
    
    Write-Host "`n--- BASELINE PROJECTIONS (No Growth) ---" -ForegroundColor Green
    Write-Host "Input Daily Volume: $(Format-DataSize $dailyGB)" -ForegroundColor White
    Write-Host "Monthly Projection: $(Format-DataSize $monthlySizeGB) (30 days)" -ForegroundColor Cyan
    Write-Host "Annual Projection:  $(Format-DataSize $annualSizeGB) (365 days)" -ForegroundColor Magenta
    
    # Growth scenarios
    Write-Host "`n--- GROWTH RATE SCENARIOS ($growthMethod Method) ---" -ForegroundColor Green
    
    if ($growthMethod -eq "Simple") {
        Write-Host "Growth applied to baseline annual total (capacity planning approach)`n" -ForegroundColor Yellow
    } else {
        Write-Host "Daily volume increases gradually with monthly compounding`n" -ForegroundColor Yellow
    }
    
    if ($growthRates.Count -eq 1) {
        Write-Host "Projection with $($growthRates[0])% growth:`n" -ForegroundColor Cyan
    } else {
        Write-Host "Projections with multiple growth rates:`n" -ForegroundColor Cyan
    }
    
    $results = @()
    
    foreach ($rate in $growthRates) {
        $projection = Calculate-GrowthProjection -DailyGB $dailyGB -GrowthRatePercent $rate -GrowthMethod $growthMethod
        
        Write-Host ("  {0}% Annual Growth:" -f $rate) -ForegroundColor White
        Write-Host ("    Year-End Daily:  $(Format-DataSize $projection.EndYearDaily)") -ForegroundColor Cyan
        Write-Host ("    Annual Total:    $(Format-DataSize $projection.AnnualTotal)") -ForegroundColor Magenta
        Write-Host ""
        
        $results += [PSCustomObject]@{
            GrowthRate = "$rate%"
            BaselineDaily = $dailyGB
            YearEndDaily = $projection.EndYearDaily
            AnnualTotal = $projection.AnnualTotal
            BaselineDailyFormatted = Format-DataSize $dailyGB
            YearEndDailyFormatted = Format-DataSize $projection.EndYearDaily
            AnnualTotalFormatted = Format-DataSize $projection.AnnualTotal
        }
    }
    
    Write-Host "`n--- SUMMARY TABLE ---" -ForegroundColor Green
    Write-Host ("{0,-15} {1,-25} {2,-25}" -f 'Growth Rate', 'Annual Total Storage', 'Year-End Daily Volume') -ForegroundColor Yellow
    Write-Host ("-" * 65) -ForegroundColor Yellow
    
    foreach ($result in $results) {
        Write-Host ("{0,-15} {1,-25} {2,-25}" -f $result.GrowthRate, $result.AnnualTotalFormatted, $result.YearEndDailyFormatted) -ForegroundColor White
    }
    
    # Return complete results object
    $finalResult = [PSCustomObject]@{
        BaselineDailyGB = $dailyGB
        BaselineMonthlyGB = $monthlySizeGB
        BaselineAnnualGB = $annualSizeGB
        GrowthMethod = $growthMethod
        GrowthScenarios = $results
    }
    
} else {
    Write-Host "`nInvalid input. Please enter a numeric value." -ForegroundColor Red
}

Write-Host "`n========================================`n" -ForegroundColor Cyan

# Display the result object as a formatted list
$finalResult | Format-List

# Ask if user wants to export to CSV
Write-Host "`n--- EXPORT OPTIONS ---" -ForegroundColor Green
$exportChoice = Read-Host "Do you want to export results to CSV? (Y/N)"

if ($exportChoice -eq 'Y' -or $exportChoice -eq 'y') {
    # Generate filename with timestamp
    $timestamp = Get-Date -Format "yyyyMMddHHmm"
    $filename = "log_volume_estimate_$timestamp.csv"
    
    # Prepare data for CSV export
    $csvData = @()
    
    # Add baseline row
    $csvData += [PSCustomObject]@{
        Scenario = "Baseline (No Growth)"
        GrowthMethod = $growthMethod
        GrowthRate = "0%"
        DailyVolumeGB = $dailyGB
        MonthlyVolumeGB = $monthlySizeGB
        AnnualVolumeGB = $annualSizeGB
        YearEndDailyGB = $dailyGB
        DailyVolumeFormatted = Format-DataSize $dailyGB
        MonthlyVolumeFormatted = Format-DataSize $monthlySizeGB
        AnnualVolumeFormatted = Format-DataSize $annualSizeGB
    }
    
    # Add growth scenario rows
    foreach ($result in $results) {
        $csvData += [PSCustomObject]@{
            Scenario = "Growth Scenario"
            GrowthMethod = $growthMethod
            GrowthRate = $result.GrowthRate
            DailyVolumeGB = $result.BaselineDaily
            MonthlyVolumeGB = $result.BaselineDaily * 30
            AnnualVolumeGB = $result.AnnualTotal
            YearEndDailyGB = $result.YearEndDaily
            DailyVolumeFormatted = $result.BaselineDailyFormatted
            MonthlyVolumeFormatted = Format-DataSize ($result.BaselineDaily * 30)
            AnnualVolumeFormatted = $result.AnnualTotalFormatted
        }
    }
    
    # Export to CSV
    try {
        $csvData | Export-Csv -Path $filename -NoTypeInformation -Encoding UTF8
        Write-Host "`nResults exported successfully to: $filename" -ForegroundColor Green
        Write-Host "File location: $(Get-Location)\$filename" -ForegroundColor Cyan
    } catch {
        Write-Host "`nError exporting to CSV: $_" -ForegroundColor Red
    }
} else {
    Write-Host "`nExport skipped." -ForegroundColor Yellow
}

Write-Host "`n========================================`n" -ForegroundColor Cyan