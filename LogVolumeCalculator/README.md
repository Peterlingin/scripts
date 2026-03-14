# Log Volume Calculator

## Table of Contents
1. [Overview](#overview)
2. [How to Use the Script](#how-to-use-the-script)
3. [Understanding Growth Methods](#understanding-growth-methods)
4. [Detailed Examples](#detailed-examples)
5. [Technical Details](#technical-details)
6. [CSV Export](#csv-export)
7. [Use Cases](#use-cases)

---

## Overview

The Log Volume Calculator is a PowerShell script designed to help IT professionals, system administrators, and DevOps teams project storage requirements for log data. It takes your current daily log volume and calculates monthly and annual storage needs, with support for different growth scenarios.

### Key Features
- **Automatic unit scaling** (GB to TB)
- **Two growth calculation methods** (Simple and Compound)
- **Multiple growth rate scenarios** (5%, 10%, 20%, 30%, 50% or custom)
- **CSV export** for reporting and tracking
- **Color-coded output** for easy reading

---

## How to Use the Script

### Step 1: Run the Script
```powershell
.\log-volume-calc.ps1
```

### Step 2: Enter Daily Log Volume
When prompted, enter your average daily log volume in GB:
```
Enter daily log volume in GB: 100
```

### Step 3: Choose Growth Method
Select how you want growth to be calculated:
```
Growth Calculation Methods:
1. Simple    - Apply growth % to total baseline (capacity planning)
2. Compound  - Daily volume grows gradually over time (realistic modeling)
Select method (1 or 2, default: 1): 1
```
- Press `1` or just **Enter** for Simple method
- Press `2` for Compound method

### Step 4: Set Growth Rate
Choose to use default scenarios or enter a custom rate:
```
Default growth scenarios: 5%, 10%, 20%, 30%, 50%
Enter a custom annual growth % (or press Enter to use defaults):
```
- Press **Enter** to see all 5 default scenarios
- Enter a number (e.g., `15`) to see only that specific growth rate

### Step 5: Review Results
The script displays:
- Baseline projections (no growth)
- Growth rate scenarios with projections
- Summary table comparing all scenarios

### Step 6: Export to CSV (Optional)
```
Do you want to export results to CSV? (Y/N): Y
```
- Press `Y` to export
- Press `N` to skip
- File is automatically named: `log_volume_estimate_YYYYMMDDHHMM.csv`

---

## Understanding Growth Methods

### Simple Growth Method (Recommended for Capacity Planning)

**What it does:**
Applies the growth percentage directly to your baseline annual total.

**Formula:**
```
Annual Storage with Growth = Baseline Annual Storage × (1 + Growth Rate)
Year-End Daily Volume = Current Daily Volume × (1 + Growth Rate)
```

**Example with 100 GB/day and 10% growth:**
- Baseline annual: 100 GB × 365 days = 36,500 GB (35.64 TB)
- With 10% growth: 36,500 GB × 1.10 = 40,150 GB (39.21 TB)
- Year-end daily: 100 GB × 1.10 = 110 GB/day

**When to use:**
- ✅ Budget and capacity planning
- ✅ Need to explain to non-technical stakeholders
- ✅ Want conservative estimates with safety buffer
- ✅ Asking "How much storage do I need if logs grow 10%?"

**Real-world scenario:**
Your CFO asks: "If our application logs grow 20% next year, what's our storage budget?" 

You need to plan for the **worst case** where you're generating 20% more logs by year-end, so you budget based on that increased rate for the entire year.

---

### Compound Growth Method (Recommended for Realistic Modeling)

**What it does:**
Models gradual growth where your daily log volume increases incrementally each month, not all at once.

**Formula:**
```
Monthly Growth Rate = Annual Growth Rate ÷ 12
Each Month: Daily Volume = Previous Daily Volume × (1 + Monthly Growth Rate)
Annual Storage = Sum of all 12 months with increasing daily volumes
```

**Example with 100 GB/day and 10% annual growth:**

| Month | Daily Volume | Monthly Total | Calculation |
|-------|--------------|---------------|-------------|
| Jan | 100.00 GB/day | 3,000 GB | Starting point |
| Feb | 100.83 GB/day | 3,025 GB | 100 × (1 + 0.10/12) |
| Mar | 101.67 GB/day | 3,050 GB | 100.83 × (1 + 0.10/12) |
| Apr | 102.50 GB/day | 3,075 GB | 101.67 × (1 + 0.10/12) |
| ... | ... | ... | ... |
| Dec | 109.58 GB/day | 3,287 GB | Growing each month |

- **Annual Total**: 36,807 GB (35.94 TB) - *less than simple method*
- **Year-End Daily**: 109.58 GB/day - *slightly less than 110 GB*

**Why is the total lower than Simple method?**
Because you only reach full 10% growth by December. For most of the year (Jan-Nov), you're generating less than 110 GB/day. The compound method reflects this realistic gradual increase.

**When to use:**
- ✅ Modeling organic business growth
- ✅ Predicting actual storage consumption patterns
- ✅ Understanding trend trajectories
- ✅ Asking "What will my logs look like by year-end?"

**Real-world scenario:**
Your SaaS application starts the year with 10,000 users and grows steadily to 11,000 users by December. Each user generates the same amount of logs, so your log volume grows proportionally with user count throughout the year.

---

## Detailed Examples

### Example 1: Small Application (10 GB/day, Simple Method, 20% Growth)

**Input:**
```
Daily log volume: 10 GB
Growth method: Simple
Growth rate: 20%
```

**Output:**
```
BASELINE PROJECTIONS (No Growth)
- Daily Volume:   10.00 GB
- Monthly:        300.00 GB
- Annual:         3.56 TB

GROWTH RATE SCENARIOS (Simple Method)
20% Annual Growth:
- Year-End Daily:  12.00 GB
- Annual Total:    4.27 TB (20% more than baseline)
```

**Interpretation:**
If your logs grow 20%, you'll need 4.27 TB storage capacity for the year. By December, you'll be generating 12 GB/day instead of 10 GB/day.

---

### Example 2: Enterprise Application (500 GB/day, Compound Method, Multiple Scenarios)

**Input:**
```
Daily log volume: 500 GB
Growth method: Compound
Growth rates: 5%, 10%, 20%, 30%, 50% (defaults)
```

**Key Results:**

| Growth Rate | Annual Total | Year-End Daily | Storage Increase |
|-------------|--------------|----------------|------------------|
| Baseline (0%) | 178.22 TB | 500.00 GB | - |
| 5% Compound | 182.51 TB | 525.64 GB | +2.4% |
| 10% Compound | 186.80 TB | 552.37 GB | +4.8% |
| 20% Compound | 195.68 TB | 610.44 GB | +9.8% |
| 30% Compound | 204.96 TB | 674.49 GB | +15.0% |
| 50% Compound | 225.53 TB | 822.84 GB | +26.6% |

**Interpretation:**
With compound growth, even a 50% annual growth rate only requires 26.6% more storage than baseline (not 50% more), because the growth is gradual. This is more realistic for organic business growth.

---

### Example 3: Comparing Both Methods (100 GB/day, 30% Growth)

**Simple Method Results:**
- Annual Total: **46.36 TB**
- Year-End Daily: 130.00 GB/day
- Interpretation: Plan for 130 GB/day from day 1

**Compound Method Results:**
- Annual Total: **41.45 TB**
- Year-End Daily: 134.82 GB/day
- Interpretation: Gradually reach 134.82 GB/day by December

**Difference:** 4.91 TB (10.6% less storage with compound method)

**Which to choose?**
- Use **Simple** if you need to budget conservatively or explain to management
- Use **Compound** if you want accurate predictions for actual storage consumption

---

## Technical Details

### Automatic Unit Scaling

The script automatically converts GB to TB when values exceed 1024 GB:

```powershell
if ($SizeInGB -ge 1024) {
    $sizeInTB = $SizeInGB / 1024
    return "{0:N2} TB" -f $sizeInTB
} else {
    return "{0:N2} GB" -f $SizeInGB
}
```

**Examples:**
- 512 GB → displays as "512.00 GB"
- 1536 GB → displays as "1.50 TB"
- 5120 GB → displays as "5.00 TB"

### Calculation Formulas

#### Simple Growth
```powershell
$baselineAnnual = $DailyGB * 365
$totalAnnual = $baselineAnnual * (1 + ($GrowthRatePercent / 100))
$endYearDaily = $DailyGB * (1 + ($GrowthRatePercent / 100))
```

#### Compound Growth
```powershell
$monthlyGrowthRate = $GrowthRatePercent / 12 / 100

$totalAnnual = 0
$currentDaily = $DailyGB

for ($month = 1; $month -le 12; $month++) {
    $monthlyTotal = $currentDaily * 30
    $totalAnnual += $monthlyTotal
    $currentDaily = $currentDaily * (1 + $monthlyGrowthRate)
}

$endYearDaily = $DailyGB * [Math]::Pow((1 + $monthlyGrowthRate), 12)
```

### Time Periods Used
- **Monthly**: 30 days (for consistency)
- **Annual**: 365 days (standard year)

---

## CSV Export

### File Naming Convention
```
log_volume_estimate_YYYYMMDDHHMM.csv
```

**Example:**
```
log_volume_estimate_202411261430.csv
```
- 2024 = Year
- 11 = November
- 26 = Day
- 14 = Hour (2 PM)
- 30 = Minute

### CSV Structure

The exported CSV contains these columns:

| Column | Description | Example |
|--------|-------------|---------|
| Scenario | Type of projection | "Baseline (No Growth)" or "Growth Scenario" |
| GrowthMethod | Calculation method used | "Simple" or "Compound" |
| GrowthRate | Growth percentage | "0%", "10%", "20%" |
| DailyVolumeGB | Starting daily volume (numeric) | 100 |
| MonthlyVolumeGB | Monthly volume (numeric) | 3000 |
| AnnualVolumeGB | Annual total storage (numeric) | 36500 |
| YearEndDailyGB | Projected end-year daily volume | 110 |
| DailyVolumeFormatted | Formatted daily volume | "100.00 GB" |
| MonthlyVolumeFormatted | Formatted monthly volume | "2.93 TB" |
| AnnualVolumeFormatted | Formatted annual volume | "35.64 TB" |

### Using the CSV

**In Excel/Sheets:**
1. Open the CSV file
2. Create pivot tables or charts
3. Compare multiple calculation runs over time
4. Share with stakeholders

**Track changes over time:**
Run the script monthly and compare CSV files to see how your actual growth compares to predictions.

---

## Use Cases

### 1. **Annual Budget Planning**
**Scenario:** IT manager needs storage budget for next fiscal year

**Approach:**
- Use **Simple method**
- Conservative growth rate (20-30%)
- Export to CSV for budget presentation

**Why:** CFOs want worst-case numbers. Simple method gives you that safety buffer.

---

### 2. **Capacity Trending**
**Scenario:** DevOps team wants to predict when to scale storage

**Approach:**
- Use **Compound method**
- Realistic growth rate based on business metrics
- Run monthly and track actual vs. projected

**Why:** Compound method reflects actual consumption patterns for better infrastructure planning.

---

### 3. **Multi-Application Planning**
**Scenario:** Managing logs from 10 different applications

**Approach:**
- Run script for each application
- Export each to CSV with timestamp
- Consolidate in Excel for total capacity planning

**Why:** Each app has different growth rates; individual projections give accurate totals.

---

### 4. **Cost Analysis**
**Scenario:** Evaluating cloud storage costs

**Approach:**
- Run projections with both methods
- Multiply storage (TB) by cloud provider rates
- Compare reserved vs. on-demand pricing

**Example:**
- Azure Storage: $0.0184/GB/month = $18.84/TB/month
- 40 TB annual = ~3.33 TB average = $62.80/month
- Growth to 50 TB = ~4.17 TB average = $78.56/month
- Additional cost: $15.76/month = $189/year

---

### 5. **Retention Policy Planning**
**Scenario:** Determining how long to keep logs

**Approach:**
- Calculate daily volume
- Multiply by retention days (e.g., 90 days)
- Account for growth in retention period

**Example:**
- 100 GB/day × 90 days = 9 TB baseline
- With 20% growth: need ~10 TB for 90-day retention
- Can now evaluate if 90 days is affordable

---

### 6. **Compression Strategy**
**Scenario:** Deciding whether to implement log compression

**Approach:**
- Run projections for raw logs
- Apply typical compression ratio (3:1 to 5:1)
- Calculate storage savings

**Example:**
- Uncompressed: 40 TB/year
- 4:1 compression: 10 TB/year
- Savings: 30 TB = ~$565/year (at $18.84/TB/month)

---

## Troubleshooting

### Issue: "Invalid input" error
**Solution:** Ensure you're entering numeric values only (no commas or units)
- ✅ Correct: `100` or `100.5`
- ❌ Wrong: `100 GB` or `100,000`

### Issue: Script won't run
**Solution:** Check PowerShell execution policy
```powershell
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser
```

### Issue: CSV export fails
**Solution:** Check file permissions in current directory
```powershell
# Check current location
Get-Location

# Change to writable directory
cd C:\Temp
```

### Issue: Results seem unrealistic
**Solution:** Verify your growth method selection and growth rate
- Simple method gives larger totals (more conservative)
- Compound method gives smaller totals (more realistic)
- Both are mathematically correct but model different scenarios

---

## Quick Reference Card

### When to Use Simple Growth
- ✅ Budget planning and cost estimates
- ✅ Presenting to non-technical stakeholders
- ✅ Need conservative/worst-case numbers
- ✅ Short-term planning (6-12 months)

### When to Use Compound Growth
- ✅ Technical capacity planning
- ✅ Long-term trending (1+ years)
- ✅ Organic/gradual business growth
- ✅ Matching actual consumption patterns

### Default Growth Rates Explained
- **5%** = Minimal growth (stable application)
- **10%** = Modest growth (typical SaaS)
- **20%** = Healthy growth (scaling startup)
- **30%** = Aggressive growth (hypergrowth phase)
- **50%** = Explosive growth (viral adoption)

---

## Mathematical Proof: Why Compound < Simple

For 100 GB/day with 10% annual growth:

**Simple Method:**
```
Total = 100 GB × 365 days × 1.10 = 40,150 GB
```

**Compound Method (monthly):**
```
Month 1:  100.00 GB/day × 30 days = 3,000 GB
Month 2:  100.83 GB/day × 30 days = 3,025 GB
Month 3:  101.67 GB/day × 30 days = 3,050 GB
...
Month 12: 109.58 GB/day × 30 days = 3,287 GB

Total = 36,807 GB
```

**Difference:** 40,150 - 36,807 = **3,343 GB** (8.3% less)

**Why?** In compound growth, you only reach the full growth rate in the final month. The Simple method assumes you're at full growth rate from day 1, making it more conservative.

---

## Conclusion

The Log Volume Calculator is a powerful tool for storage planning that gives you flexibility in how you model growth. Use Simple method for conservative budgeting and Compound method for realistic predictions. Run it regularly, export results, and track your actual consumption against projections to refine your growth assumptions over time.

For questions or suggestions, consider tracking your usage patterns over 3-6 months to determine which method and growth rate best matches your actual environment.
