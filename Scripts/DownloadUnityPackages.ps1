Param(
    [string] $DownloadDestDir = (Join-Path $PSScriptRoot "/../Unity/MRPackages"),
    [string] $DependenciesJson = (Join-Path $PSScriptRoot "unity_sample_dependencies.json"),
    [switch] $Verbose
)

. "$PSScriptRoot\ARRUtils.ps1" #include ARRUtils for Logging

### Functions ###
function NormalizePath([string] $path)
{
    if (-not [System.IO.Path]::IsPathRooted($path))
    {
        $wd = Get-Location
        $joined = Join-Path $wd $path
        $path = ([System.IO.Path]::GetFullPath($joined))
    }
    return $path
}

$DownloadPackage = {
    param(
        [string] $root,
        [string] $DownloadDestDir,
        [string] $registry,
        [string] $package,
        [string] $version = "latest",
        [switch] $verbose
    )

    . "$root\ARRUtils.ps1" #include ARRUtils for Logging

    #region GetDetails
    $details = $null
    $uri = "$registry/$package"
    try 
    {
        $response = Invoke-WebRequest -UseBasicParsing -Uri $uri
        $json = $response | ConvertFrom-Json

        if ($version -like "latest") {
            $version = $json.'dist-tags'.latest
        }

        $versionInfo = $json.versions.($version)
        if ($null -eq $versionInfo) {
            Write-Error "No info found for version $version of package $package."
            throw
        }
        $details = $json.versions.($version).dist
    }
    catch
    {
        Write-Error "Web request to $uri failed."
        Write-Error $_
        throw
    }

    if ($null -eq $details) 
    {
        Write-Error "Failed to get details for $($package.name)@$($package.version) from $($package.registry)."
        throw
    }
    
    $packageUrl = $details.tarball
    $fileName = [System.IO.Path]::GetFileName($packageUrl)
    $downloadPath = Join-Path $DownloadDestDir $fileName
    $downloadPath = [System.IO.Path]::GetFullPath($downloadPath)

    $packageDetails = [PSCustomObject]@{
        Name         = $package
        Version      = $version
        Registry     = $registry
        Url          = $packageUrl
        Sha1sum      = $details.shasum
        DownloadPath = $downloadPath
    }
    #endregion

    #region CheckLocalPackages
    if ((Test-Path $packageDetails.DownloadPath -PathType Leaf))
    {
        $packageShasum = $packageDetails.Sha1sum.ToLower()
        $localShasum = (Get-FileHash -Algorithm SHA1 $packageDetails.DownloadPath).Hash.ToLower()
        if ($packageShasum -like $localShasum)
        {
            WriteInformation "$($packageDetails.DownloadPath) already exists. Skipping download."
            return
        }

        Write-Warning "SHA1 hashes for $($packageDetails.Name)@$($packageDetails.Version) and $($packageDetails.DownloadPath) do not match."
        Write-Warning "$packageShasum != $localShasum"
        Write-Warning "Deleting file and re-downloading."
        Remove-Item $packageDetails.DownloadPath -Force
    }
    #endregion

    #region Download
    WriteInformation "Downloading $($packageDetails.Name)@$($packageDetails.Version) from $($packageDetails.Url)."

    $retries = 1
    while ($retries -le 3)
    {
        try
        {
            $responseStream = $null
            $destStream = $null
            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            $uri = New-Object "System.Uri" "$($packageDetails.Url)"
            $request = [System.Net.HttpWebRequest]::Create($uri)
        
            $response = $request.GetResponse()
            $responseStream = $response.GetResponseStream()
            $contentLength = $response.get_ContentLength()
        
            $destStream = New-Object -TypeName System.IO.FileStream -ArgumentList $packageDetails.DownloadPath, Create
            $buf = new-object byte[] 16KB
        
            $srcFileName = [System.IO.Path]::GetFileName($packageDetails.Url)
            
            $lastLogPercentage = 0

            do
            {
                if ($($sw.Elapsed.TotalMinutes) -gt 5)
                {
                    throw "Timeout"
                }

                $destStream.Write($buf, 0, $readBytes)
                $readBytes = $responseStream.Read($buf, 0, $buf.length)
                $readBytesTotal = $readBytesTotal + $readBytes
                
                $percentComplete = (($readBytesTotal / $contentLength) * 100)
                if (($percentComplete - $lastLogPercentage) -gt 5)
                {
                    $lastLogPercentage = $percentComplete
                    $status = "Downloaded {0:N2} MB of {1:N2} MB (Attempt $retries)" -f ($readBytesTotal / 1MB), ($contentLength / 1MB)
                    Write-Progress -Activity "Downloading '$($srcFileName)'" -Status $status -PercentComplete $percentComplete

                    if ($verbose)
                    {
                        Write-Host "DL (Attempt $retries) `"$($srcFileName)`" at $([math]::round($percentComplete,2))%"
                    }
                }
            }
            while ($readBytes -gt 0)

            Write-Progress -Completed -Activity "Finished downloading '$($srcFileName)'"
            return
        }
        catch
        {
            Write-Host "Error downloading $($packageDetails.Url) to $($packageDetails.DownloadPath)"
            Write-Host "$_"
            $retries += 1
        }
        finally
        {
            if ($null -ne $destStream) {
                $destStream.Flush()
                $destStream.Close()
                $destStream.Dispose()
                $destStream = $null
            }
            if ($null -ne $responseStream) {
                $responseStream.Dispose()
                $responseStream = $null
            }
        }
    }
    #endregion

    #region Verify
    $packageShasum = $packageDetails.Sha1sum.ToLower()
    if (Test-Path $packageDetails.DownloadPath -PathType Leaf)
    {
        $localShasum = (Get-FileHash -Algorithm SHA1 $packageDetails.DownloadPath).Hash.ToLower()
        if (-not ($packageShasum -like $localShasum))
        {
            Write-Error "SHA1 hashes for $($packageDetails.Name)@$($packageDetails.Version) and $($packageDetails.DownloadPath) do not match."
            Write-Error "$packageShasum != $localShasum"
            throw
        }
    }
    else
    {
        Write-Error "Download failed for $($packageDetails.Name)@$($packageDetails.Version). File not found: $($packageDetails.DownloadPath)."
        throw
    }
    #endregion
}

### Main script ###
$DownloadDestDir = NormalizePath($DownloadDestDir)
$DependenciesJson = NormalizePath($DependenciesJson)

if (-not (Test-Path $DownloadDestDir -PathType Container))
{
    New-Item -Path $DownloadDestDir -ItemType Directory | Out-Null
}

$downloads = @()
foreach ($package in ((Get-Content $DependenciesJson) | ConvertFrom-Json).packages)
{
    $download = Start-Job -ScriptBlock $DownloadPackage -ArgumentList $PSScriptRoot, $DownloadDestDir, $package.registry, $package.name, $package.version, $Verbose

    $downloads += [PSCustomObject]@{
        JobObject = $download
        Completed = $false
    }
}

$failedJobs = @()
$failed = $false
$sw = [System.Diagnostics.Stopwatch]::StartNew()

do
{
    $completedJobCount = 0
    foreach ($download in $downloads)
    {
        if ($download.Completed -or $failedJobs -contains $download.JobObject.Id)
        {
            $completedJobCount++
            continue
        }

        if ($download.JobObject.State -ne "NotStarted" -and $download.JobObject.State -ne "Running")
        {
            $download.Completed = $true
            $download.JobObject.ChildJobs[0].Output | Write-Host
            $download.JobObject.ChildJobs[0].Information | Write-Host

            if ($download.JobObject.ChildJobs[0].Error.Count -ne 0)
            {
                $failed = $true
                $failedJobs += $download.JobObject.Id
                $download.JobObject.ChildJobs[0].Error | Write-Error
            }
        }

        $latestProgress = $download.JobObject.ChildJobs[0].Progress[-1]
        if ($null -ne $latestProgress -and $null -ne $latestProgress.Activity)
        {
            if ($latestProgress.RecordType -eq "Completed")
            {
                Write-Progress -ParentId 0 -Completed -Id $download.JobObject.Id -Activity $latestProgress
            }
            else
            {
                Write-Progress -ParentId 0 -Id $download.JobObject.Id -Activity $latestProgress.Activity -Status $latestProgress.StatusDescription -PercentComplete $latestProgress.PercentComplete
            }
        }
    }

    $status = "$completedJobCount of $($downloads.Count) Downloads completed"
    Write-Progress -Id 0 -Activity "Downloading Packages" -Status $status -PercentComplete (($completedJobCount / $downloads.Count) * 100)

    if ($Verbose -and $($sw.Elapsed.TotalSeconds) -gt 30)
    {
        Write-Host "Periodic job status:"
        $downloads.JobObject | Format-Table -AutoSize
        $downloads.JobObject | Receive-Job
        $sw.Restart()
    } 
}
while ($completedJobCount -lt $downloads.Count)

if (-not $failed)
{
    WriteSuccess "Downloading dependency packages succeeded."
}
else
{
    WriteError "Downloading dependency packages failed."
    exit 1
}

# SIG # Begin signature block
# MIIoLQYJKoZIhvcNAQcCoIIoHjCCKBoCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCCKsXVecpk+m0UT
# R4ZPeKXqgo+7lAuduRLNjFUYmvJ/T6CCDXYwggX0MIID3KADAgECAhMzAAADTrU8
# esGEb+srAAAAAANOMA0GCSqGSIb3DQEBCwUAMH4xCzAJBgNVBAYTAlVTMRMwEQYD
# VQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNy
# b3NvZnQgQ29ycG9yYXRpb24xKDAmBgNVBAMTH01pY3Jvc29mdCBDb2RlIFNpZ25p
# bmcgUENBIDIwMTEwHhcNMjMwMzE2MTg0MzI5WhcNMjQwMzE0MTg0MzI5WjB0MQsw
# CQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9u
# ZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMR4wHAYDVQQDExVNaWNy
# b3NvZnQgQ29ycG9yYXRpb24wggEiMA0GCSqGSIb3DQEBAQUAA4IBDwAwggEKAoIB
# AQDdCKiNI6IBFWuvJUmf6WdOJqZmIwYs5G7AJD5UbcL6tsC+EBPDbr36pFGo1bsU
# p53nRyFYnncoMg8FK0d8jLlw0lgexDDr7gicf2zOBFWqfv/nSLwzJFNP5W03DF/1
# 1oZ12rSFqGlm+O46cRjTDFBpMRCZZGddZlRBjivby0eI1VgTD1TvAdfBYQe82fhm
# WQkYR/lWmAK+vW/1+bO7jHaxXTNCxLIBW07F8PBjUcwFxxyfbe2mHB4h1L4U0Ofa
# +HX/aREQ7SqYZz59sXM2ySOfvYyIjnqSO80NGBaz5DvzIG88J0+BNhOu2jl6Dfcq
# jYQs1H/PMSQIK6E7lXDXSpXzAgMBAAGjggFzMIIBbzAfBgNVHSUEGDAWBgorBgEE
# AYI3TAgBBggrBgEFBQcDAzAdBgNVHQ4EFgQUnMc7Zn/ukKBsBiWkwdNfsN5pdwAw
# RQYDVR0RBD4wPKQ6MDgxHjAcBgNVBAsTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjEW
# MBQGA1UEBRMNMjMwMDEyKzUwMDUxNjAfBgNVHSMEGDAWgBRIbmTlUAXTgqoXNzci
# tW2oynUClTBUBgNVHR8ETTBLMEmgR6BFhkNodHRwOi8vd3d3Lm1pY3Jvc29mdC5j
# b20vcGtpb3BzL2NybC9NaWNDb2RTaWdQQ0EyMDExXzIwMTEtMDctMDguY3JsMGEG
# CCsGAQUFBwEBBFUwUzBRBggrBgEFBQcwAoZFaHR0cDovL3d3dy5taWNyb3NvZnQu
# Y29tL3BraW9wcy9jZXJ0cy9NaWNDb2RTaWdQQ0EyMDExXzIwMTEtMDctMDguY3J0
# MAwGA1UdEwEB/wQCMAAwDQYJKoZIhvcNAQELBQADggIBAD21v9pHoLdBSNlFAjmk
# mx4XxOZAPsVxxXbDyQv1+kGDe9XpgBnT1lXnx7JDpFMKBwAyIwdInmvhK9pGBa31
# TyeL3p7R2s0L8SABPPRJHAEk4NHpBXxHjm4TKjezAbSqqbgsy10Y7KApy+9UrKa2
# kGmsuASsk95PVm5vem7OmTs42vm0BJUU+JPQLg8Y/sdj3TtSfLYYZAaJwTAIgi7d
# hzn5hatLo7Dhz+4T+MrFd+6LUa2U3zr97QwzDthx+RP9/RZnur4inzSQsG5DCVIM
# pA1l2NWEA3KAca0tI2l6hQNYsaKL1kefdfHCrPxEry8onJjyGGv9YKoLv6AOO7Oh
# JEmbQlz/xksYG2N/JSOJ+QqYpGTEuYFYVWain7He6jgb41JbpOGKDdE/b+V2q/gX
# UgFe2gdwTpCDsvh8SMRoq1/BNXcr7iTAU38Vgr83iVtPYmFhZOVM0ULp/kKTVoir
# IpP2KCxT4OekOctt8grYnhJ16QMjmMv5o53hjNFXOxigkQWYzUO+6w50g0FAeFa8
# 5ugCCB6lXEk21FFB1FdIHpjSQf+LP/W2OV/HfhC3uTPgKbRtXo83TZYEudooyZ/A
# Vu08sibZ3MkGOJORLERNwKm2G7oqdOv4Qj8Z0JrGgMzj46NFKAxkLSpE5oHQYP1H
# tPx1lPfD7iNSbJsP6LiUHXH1MIIHejCCBWKgAwIBAgIKYQ6Q0gAAAAAAAzANBgkq
# hkiG9w0BAQsFADCBiDELMAkGA1UEBhMCVVMxEzARBgNVBAgTCldhc2hpbmd0b24x
# EDAOBgNVBAcTB1JlZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlv
# bjEyMDAGA1UEAxMpTWljcm9zb2Z0IFJvb3QgQ2VydGlmaWNhdGUgQXV0aG9yaXR5
# IDIwMTEwHhcNMTEwNzA4MjA1OTA5WhcNMjYwNzA4MjEwOTA5WjB+MQswCQYDVQQG
# EwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwG
# A1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSgwJgYDVQQDEx9NaWNyb3NvZnQg
# Q29kZSBTaWduaW5nIFBDQSAyMDExMIICIjANBgkqhkiG9w0BAQEFAAOCAg8AMIIC
# CgKCAgEAq/D6chAcLq3YbqqCEE00uvK2WCGfQhsqa+laUKq4BjgaBEm6f8MMHt03
# a8YS2AvwOMKZBrDIOdUBFDFC04kNeWSHfpRgJGyvnkmc6Whe0t+bU7IKLMOv2akr
# rnoJr9eWWcpgGgXpZnboMlImEi/nqwhQz7NEt13YxC4Ddato88tt8zpcoRb0Rrrg
# OGSsbmQ1eKagYw8t00CT+OPeBw3VXHmlSSnnDb6gE3e+lD3v++MrWhAfTVYoonpy
# 4BI6t0le2O3tQ5GD2Xuye4Yb2T6xjF3oiU+EGvKhL1nkkDstrjNYxbc+/jLTswM9
# sbKvkjh+0p2ALPVOVpEhNSXDOW5kf1O6nA+tGSOEy/S6A4aN91/w0FK/jJSHvMAh
# dCVfGCi2zCcoOCWYOUo2z3yxkq4cI6epZuxhH2rhKEmdX4jiJV3TIUs+UsS1Vz8k
# A/DRelsv1SPjcF0PUUZ3s/gA4bysAoJf28AVs70b1FVL5zmhD+kjSbwYuER8ReTB
# w3J64HLnJN+/RpnF78IcV9uDjexNSTCnq47f7Fufr/zdsGbiwZeBe+3W7UvnSSmn
# Eyimp31ngOaKYnhfsi+E11ecXL93KCjx7W3DKI8sj0A3T8HhhUSJxAlMxdSlQy90
# lfdu+HggWCwTXWCVmj5PM4TasIgX3p5O9JawvEagbJjS4NaIjAsCAwEAAaOCAe0w
# ggHpMBAGCSsGAQQBgjcVAQQDAgEAMB0GA1UdDgQWBBRIbmTlUAXTgqoXNzcitW2o
# ynUClTAZBgkrBgEEAYI3FAIEDB4KAFMAdQBiAEMAQTALBgNVHQ8EBAMCAYYwDwYD
# VR0TAQH/BAUwAwEB/zAfBgNVHSMEGDAWgBRyLToCMZBDuRQFTuHqp8cx0SOJNDBa
# BgNVHR8EUzBRME+gTaBLhklodHRwOi8vY3JsLm1pY3Jvc29mdC5jb20vcGtpL2Ny
# bC9wcm9kdWN0cy9NaWNSb29DZXJBdXQyMDExXzIwMTFfMDNfMjIuY3JsMF4GCCsG
# AQUFBwEBBFIwUDBOBggrBgEFBQcwAoZCaHR0cDovL3d3dy5taWNyb3NvZnQuY29t
# L3BraS9jZXJ0cy9NaWNSb29DZXJBdXQyMDExXzIwMTFfMDNfMjIuY3J0MIGfBgNV
# HSAEgZcwgZQwgZEGCSsGAQQBgjcuAzCBgzA/BggrBgEFBQcCARYzaHR0cDovL3d3
# dy5taWNyb3NvZnQuY29tL3BraW9wcy9kb2NzL3ByaW1hcnljcHMuaHRtMEAGCCsG
# AQUFBwICMDQeMiAdAEwAZQBnAGEAbABfAHAAbwBsAGkAYwB5AF8AcwB0AGEAdABl
# AG0AZQBuAHQALiAdMA0GCSqGSIb3DQEBCwUAA4ICAQBn8oalmOBUeRou09h0ZyKb
# C5YR4WOSmUKWfdJ5DJDBZV8uLD74w3LRbYP+vj/oCso7v0epo/Np22O/IjWll11l
# hJB9i0ZQVdgMknzSGksc8zxCi1LQsP1r4z4HLimb5j0bpdS1HXeUOeLpZMlEPXh6
# I/MTfaaQdION9MsmAkYqwooQu6SpBQyb7Wj6aC6VoCo/KmtYSWMfCWluWpiW5IP0
# wI/zRive/DvQvTXvbiWu5a8n7dDd8w6vmSiXmE0OPQvyCInWH8MyGOLwxS3OW560
# STkKxgrCxq2u5bLZ2xWIUUVYODJxJxp/sfQn+N4sOiBpmLJZiWhub6e3dMNABQam
# ASooPoI/E01mC8CzTfXhj38cbxV9Rad25UAqZaPDXVJihsMdYzaXht/a8/jyFqGa
# J+HNpZfQ7l1jQeNbB5yHPgZ3BtEGsXUfFL5hYbXw3MYbBL7fQccOKO7eZS/sl/ah
# XJbYANahRr1Z85elCUtIEJmAH9AAKcWxm6U/RXceNcbSoqKfenoi+kiVH6v7RyOA
# 9Z74v2u3S5fi63V4GuzqN5l5GEv/1rMjaHXmr/r8i+sLgOppO6/8MO0ETI7f33Vt
# Y5E90Z1WTk+/gFcioXgRMiF670EKsT/7qMykXcGhiJtXcVZOSEXAQsmbdlsKgEhr
# /Xmfwb1tbWrJUnMTDXpQzTGCGg0wghoJAgEBMIGVMH4xCzAJBgNVBAYTAlVTMRMw
# EQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVN
# aWNyb3NvZnQgQ29ycG9yYXRpb24xKDAmBgNVBAMTH01pY3Jvc29mdCBDb2RlIFNp
# Z25pbmcgUENBIDIwMTECEzMAAANOtTx6wYRv6ysAAAAAA04wDQYJYIZIAWUDBAIB
# BQCgga4wGQYJKoZIhvcNAQkDMQwGCisGAQQBgjcCAQQwHAYKKwYBBAGCNwIBCzEO
# MAwGCisGAQQBgjcCARUwLwYJKoZIhvcNAQkEMSIEIChipHQwTmCiYwllBrgP/9R5
# een3BTKB2yXDEdCdMTmlMEIGCisGAQQBgjcCAQwxNDAyoBSAEgBNAGkAYwByAG8A
# cwBvAGYAdKEagBhodHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20wDQYJKoZIhvcNAQEB
# BQAEggEAd9Jq1oTWimPbfctLAMAwucvoajiwSha4OI52ksIaBBEHerjG+LR1kn5Q
# iHSiCEYBj3urroXxquYwE6Pn+HBxAJv5nnIpvzuE2JUyisjigMEFE0f2CDIb3t2y
# Od9FrNA5/r8KeKwisWC968BU6HVKkypc0dRanwbu0hjZX3OLO27zHR0zGcyuqQXr
# 7smrOXd8+SRzRo6jF8YJQo6XT6wvHRqXXU/tEFG6IsokXx6peLLUuWrs9rAHAVRb
# CrAxWtOf4ZXI/T70FKoL6k7UnHVOtYmWndZxPfQs+ev2HFDo9UDT1ErzxUW0zP+M
# DlYzY52x8qsk+3xkatlK5wUArsJVEaGCF5cwgheTBgorBgEEAYI3AwMBMYIXgzCC
# F38GCSqGSIb3DQEHAqCCF3AwghdsAgEDMQ8wDQYJYIZIAWUDBAIBBQAwggFSBgsq
# hkiG9w0BCRABBKCCAUEEggE9MIIBOQIBAQYKKwYBBAGEWQoDATAxMA0GCWCGSAFl
# AwQCAQUABCA/eB//3VcgUnBFOGxBP1aOSXSgbwW9CoyUeRqf+2spHAIGZMvhxZZL
# GBMyMDIzMDgwODE3MzAxNS45NzJaMASAAgH0oIHRpIHOMIHLMQswCQYDVQQGEwJV
# UzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UE
# ChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSUwIwYDVQQLExxNaWNyb3NvZnQgQW1l
# cmljYSBPcGVyYXRpb25zMScwJQYDVQQLEx5uU2hpZWxkIFRTUyBFU046REMwMC0w
# NUUwLUQ5NDcxJTAjBgNVBAMTHE1pY3Jvc29mdCBUaW1lLVN0YW1wIFNlcnZpY2Wg
# ghHtMIIHIDCCBQigAwIBAgITMwAAAdIhJDFKWL8tEQABAAAB0jANBgkqhkiG9w0B
# AQsFADB8MQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UE
# BxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSYwJAYD
# VQQDEx1NaWNyb3NvZnQgVGltZS1TdGFtcCBQQ0EgMjAxMDAeFw0yMzA1MjUxOTEy
# MjFaFw0yNDAyMDExOTEyMjFaMIHLMQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2Fz
# aGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENv
# cnBvcmF0aW9uMSUwIwYDVQQLExxNaWNyb3NvZnQgQW1lcmljYSBPcGVyYXRpb25z
# MScwJQYDVQQLEx5uU2hpZWxkIFRTUyBFU046REMwMC0wNUUwLUQ5NDcxJTAjBgNV
# BAMTHE1pY3Jvc29mdCBUaW1lLVN0YW1wIFNlcnZpY2UwggIiMA0GCSqGSIb3DQEB
# AQUAA4ICDwAwggIKAoICAQDcYIhC0QI/SPaT5+nYSBsSdhBPO2SXM40Vyyg8Fq1T
# PrMNDzxChxWUD7fbKwYGSsONgtjjVed5HSh5il75jNacb6TrZwuX+Q2++f2/8CCy
# u8TY0rxEInD3Tj52bWz5QRWVQejfdCA/n6ZzinhcZZ7+VelWgTfYC7rDrhX3TBX8
# 9elqXmISOVIWeXiRK8h9hH6SXgjhQGGQbf2bSM7uGkKzJ/pZ2LvlTzq+mOW9iP2j
# cYEA4bpPeurpglLVUSnGGQLmjQp7Sdy1wE52WjPKdLnBF6JbmSREM/Dj9Z7okxRN
# UjYSdgyvZ1LWSilhV/wegYXVQ6P9MKjRnE8CI5KMHmq7EsHhIBK0B99dFQydL1vd
# uC7eWEjzz55Z/DyH6Hl2SPOf5KZ4lHf6MUwtgaf+MeZxkW0ixh/vL1mX8VsJTHa8
# AH+0l/9dnWzFMFFJFG7g95nHJ6MmYPrfmoeKORoyEQRsSus2qCrpMjg/P3Z9WJAt
# FGoXYMD19NrzG4UFPpVbl3N1XvG4/uldo1+anBpDYhxQU7k1gfHn6QxdUU0TsrJ/
# JCvLffS89b4VXlIaxnVF6QZh+J7xLUNGtEmj6dwPzoCfL7zqDZJvmsvYNk1lcbyV
# xMIgDFPoA2fZPXHF7dxahM2ZG7AAt3vZEiMtC6E/ciLRcIwzlJrBiHEenIPvxW15
# qwIDAQABo4IBSTCCAUUwHQYDVR0OBBYEFCC2n7cnR3ToP/kbEZ2XJFFmZ1kkMB8G
# A1UdIwQYMBaAFJ+nFV0AXmJdg/Tl0mWnG1M1GelyMF8GA1UdHwRYMFYwVKBSoFCG
# Tmh0dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMvY3JsL01pY3Jvc29mdCUy
# MFRpbWUtU3RhbXAlMjBQQ0ElMjAyMDEwKDEpLmNybDBsBggrBgEFBQcBAQRgMF4w
# XAYIKwYBBQUHMAKGUGh0dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMvY2Vy
# dHMvTWljcm9zb2Z0JTIwVGltZS1TdGFtcCUyMFBDQSUyMDIwMTAoMSkuY3J0MAwG
# A1UdEwEB/wQCMAAwFgYDVR0lAQH/BAwwCgYIKwYBBQUHAwgwDgYDVR0PAQH/BAQD
# AgeAMA0GCSqGSIb3DQEBCwUAA4ICAQCw5iq0Ey0LlAdz2PcqchRwW5d+fitNISCv
# qD0E6W/AyiTk+TM3WhYTaxQ2pP6Or4qOV+Du7/L+k18gYr1phshxVMVnXNcdjecM
# tTWUOVAwbJoeWHaAgknNIMzXK3+zguG5TVcLEh/CVMy1J7KPE8Q0Cz56NgWzd9ur
# G+shSDKkKdhOYPXF970Mr1GCFFpe1oXjEy6aS+Heavp2wmy65mbu0AcUOPEn+hYq
# ijgLXSPqvuFmOOo5UnSV66Dv5FdkqK7q5DReox9RPEZcHUa+2BUKPjp+dQ3D4c9I
# H8727KjMD8OXZomD9A8Mr/fcDn5FI7lfZc8ghYc7spYKTO/0Z9YRRamhVWxxrIsB
# N5LrWh+18soXJ++EeSjzSYdgGWYPg16hL/7Aydx4Kz/WBTUmbGiiVUcE/I0aQU2U
# /0NzUiIFIW80SvxeDWn6I+hyVg/sdFSALP5JT7wAe8zTvsrI2hMpEVLdStFAMqan
# FYqtwZU5FoAsoPZ7h1ElWmKLZkXk8ePuALztNY1yseO0TwdueIGcIwItrlBYg1Xp
# Pz1+pMhGMVble6KHunaKo5K/ldOM0mQQT4Vjg6ZbzRIVRoDcArQ5//0875jOUvJt
# Yyc7Hl04jcmvjEIXC3HjkUYvgHEWL0QF/4f7vLAchaEZ839/3GYOdqH5VVnZrUIB
# QB6DTaUILDCCB3EwggVZoAMCAQICEzMAAAAVxedrngKbSZkAAAAAABUwDQYJKoZI
# hvcNAQELBQAwgYgxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAw
# DgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24x
# MjAwBgNVBAMTKU1pY3Jvc29mdCBSb290IENlcnRpZmljYXRlIEF1dGhvcml0eSAy
# MDEwMB4XDTIxMDkzMDE4MjIyNVoXDTMwMDkzMDE4MzIyNVowfDELMAkGA1UEBhMC
# VVMxEzARBgNVBAgTCldhc2hpbmd0b24xEDAOBgNVBAcTB1JlZG1vbmQxHjAcBgNV
# BAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjEmMCQGA1UEAxMdTWljcm9zb2Z0IFRp
# bWUtU3RhbXAgUENBIDIwMTAwggIiMA0GCSqGSIb3DQEBAQUAA4ICDwAwggIKAoIC
# AQDk4aZM57RyIQt5osvXJHm9DtWC0/3unAcH0qlsTnXIyjVX9gF/bErg4r25Phdg
# M/9cT8dm95VTcVrifkpa/rg2Z4VGIwy1jRPPdzLAEBjoYH1qUoNEt6aORmsHFPPF
# dvWGUNzBRMhxXFExN6AKOG6N7dcP2CZTfDlhAnrEqv1yaa8dq6z2Nr41JmTamDu6
# GnszrYBbfowQHJ1S/rboYiXcag/PXfT+jlPP1uyFVk3v3byNpOORj7I5LFGc6XBp
# Dco2LXCOMcg1KL3jtIckw+DJj361VI/c+gVVmG1oO5pGve2krnopN6zL64NF50Zu
# yjLVwIYwXE8s4mKyzbnijYjklqwBSru+cakXW2dg3viSkR4dPf0gz3N9QZpGdc3E
# XzTdEonW/aUgfX782Z5F37ZyL9t9X4C626p+Nuw2TPYrbqgSUei/BQOj0XOmTTd0
# lBw0gg/wEPK3Rxjtp+iZfD9M269ewvPV2HM9Q07BMzlMjgK8QmguEOqEUUbi0b1q
# GFphAXPKZ6Je1yh2AuIzGHLXpyDwwvoSCtdjbwzJNmSLW6CmgyFdXzB0kZSU2LlQ
# +QuJYfM2BjUYhEfb3BvR/bLUHMVr9lxSUV0S2yW6r1AFemzFER1y7435UsSFF5PA
# PBXbGjfHCBUYP3irRbb1Hode2o+eFnJpxq57t7c+auIurQIDAQABo4IB3TCCAdkw
# EgYJKwYBBAGCNxUBBAUCAwEAATAjBgkrBgEEAYI3FQIEFgQUKqdS/mTEmr6CkTxG
# NSnPEP8vBO4wHQYDVR0OBBYEFJ+nFV0AXmJdg/Tl0mWnG1M1GelyMFwGA1UdIARV
# MFMwUQYMKwYBBAGCN0yDfQEBMEEwPwYIKwYBBQUHAgEWM2h0dHA6Ly93d3cubWlj
# cm9zb2Z0LmNvbS9wa2lvcHMvRG9jcy9SZXBvc2l0b3J5Lmh0bTATBgNVHSUEDDAK
# BggrBgEFBQcDCDAZBgkrBgEEAYI3FAIEDB4KAFMAdQBiAEMAQTALBgNVHQ8EBAMC
# AYYwDwYDVR0TAQH/BAUwAwEB/zAfBgNVHSMEGDAWgBTV9lbLj+iiXGJo0T2UkFvX
# zpoYxDBWBgNVHR8ETzBNMEugSaBHhkVodHRwOi8vY3JsLm1pY3Jvc29mdC5jb20v
# cGtpL2NybC9wcm9kdWN0cy9NaWNSb29DZXJBdXRfMjAxMC0wNi0yMy5jcmwwWgYI
# KwYBBQUHAQEETjBMMEoGCCsGAQUFBzAChj5odHRwOi8vd3d3Lm1pY3Jvc29mdC5j
# b20vcGtpL2NlcnRzL01pY1Jvb0NlckF1dF8yMDEwLTA2LTIzLmNydDANBgkqhkiG
# 9w0BAQsFAAOCAgEAnVV9/Cqt4SwfZwExJFvhnnJL/Klv6lwUtj5OR2R4sQaTlz0x
# M7U518JxNj/aZGx80HU5bbsPMeTCj/ts0aGUGCLu6WZnOlNN3Zi6th542DYunKmC
# VgADsAW+iehp4LoJ7nvfam++Kctu2D9IdQHZGN5tggz1bSNU5HhTdSRXud2f8449
# xvNo32X2pFaq95W2KFUn0CS9QKC/GbYSEhFdPSfgQJY4rPf5KYnDvBewVIVCs/wM
# nosZiefwC2qBwoEZQhlSdYo2wh3DYXMuLGt7bj8sCXgU6ZGyqVvfSaN0DLzskYDS
# PeZKPmY7T7uG+jIa2Zb0j/aRAfbOxnT99kxybxCrdTDFNLB62FD+CljdQDzHVG2d
# Y3RILLFORy3BFARxv2T5JL5zbcqOCb2zAVdJVGTZc9d/HltEAY5aGZFrDZ+kKNxn
# GSgkujhLmm77IVRrakURR6nxt67I6IleT53S0Ex2tVdUCbFpAUR+fKFhbHP+Crvs
# QWY9af3LwUFJfn6Tvsv4O+S3Fb+0zj6lMVGEvL8CwYKiexcdFYmNcP7ntdAoGokL
# jzbaukz5m/8K6TT4JDVnK+ANuOaMmdbhIurwJ0I9JZTmdHRbatGePu1+oDEzfbzL
# 6Xu/OHBE0ZDxyKs6ijoIYn/ZcGNTTY3ugm2lBRDBcQZqELQdVTNYs6FwZvKhggNQ
# MIICOAIBATCB+aGB0aSBzjCByzELMAkGA1UEBhMCVVMxEzARBgNVBAgTCldhc2hp
# bmd0b24xEDAOBgNVBAcTB1JlZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jw
# b3JhdGlvbjElMCMGA1UECxMcTWljcm9zb2Z0IEFtZXJpY2EgT3BlcmF0aW9uczEn
# MCUGA1UECxMeblNoaWVsZCBUU1MgRVNOOkRDMDAtMDVFMC1EOTQ3MSUwIwYDVQQD
# ExxNaWNyb3NvZnQgVGltZS1TdGFtcCBTZXJ2aWNloiMKAQEwBwYFKw4DAhoDFQCJ
# ptLCZsE06NtmHQzB5F1TroFSBqCBgzCBgKR+MHwxCzAJBgNVBAYTAlVTMRMwEQYD
# VQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNy
# b3NvZnQgQ29ycG9yYXRpb24xJjAkBgNVBAMTHU1pY3Jvc29mdCBUaW1lLVN0YW1w
# IFBDQSAyMDEwMA0GCSqGSIb3DQEBCwUAAgUA6Hz3qDAiGA8yMDIzMDgwODE3MTkz
# NloYDzIwMjMwODA5MTcxOTM2WjB3MD0GCisGAQQBhFkKBAExLzAtMAoCBQDofPeo
# AgEAMAoCAQACAiCZAgH/MAcCAQACAhJTMAoCBQDofkkoAgEAMDYGCisGAQQBhFkK
# BAIxKDAmMAwGCisGAQQBhFkKAwKgCjAIAgEAAgMHoSChCjAIAgEAAgMBhqAwDQYJ
# KoZIhvcNAQELBQADggEBAHn3SZ/IBGPUnmo6KxmGe1IIlh/AbhYGy56k4rVn+CJJ
# guVcjtSInvALTGnUeeCVzc4DKiuoeHX2jm68W8pQSqFclwBXOqm72cucabMU7t9a
# vvRifxlhi/ILOu40zeypiwAuOupKqtN6KOt21EKbGkeIXATOoLEEVcqMuV3MFwa0
# VD0OqOv0yWtGq30mbEN7RquveLRyo/YwM/Ee1zqrUCaR7v7P7axOvBiNPtUidSEk
# vKoKepR1Rc/SKKR+ne1dxLgzzwV4tHEDv7BOP0V5ipoC3lF9ngzsKhXOkTzVxO/C
# yoUIL87GoSG3Wg1ZmYshucKqqfi+tS6fUfqMLres6K0xggQNMIIECQIBATCBkzB8
# MQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVk
# bW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSYwJAYDVQQDEx1N
# aWNyb3NvZnQgVGltZS1TdGFtcCBQQ0EgMjAxMAITMwAAAdIhJDFKWL8tEQABAAAB
# 0jANBglghkgBZQMEAgEFAKCCAUowGgYJKoZIhvcNAQkDMQ0GCyqGSIb3DQEJEAEE
# MC8GCSqGSIb3DQEJBDEiBCBlfbUvc6z+X2uUKOLJEwFjrQGhhw/BAiBU72AAWBGC
# JDCB+gYLKoZIhvcNAQkQAi8xgeowgecwgeQwgb0EIMeAIJPf30i9ZbOExU557GwW
# NaLH0Z5s65JFga2DeaROMIGYMIGApH4wfDELMAkGA1UEBhMCVVMxEzARBgNVBAgT
# Cldhc2hpbmd0b24xEDAOBgNVBAcTB1JlZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29m
# dCBDb3Jwb3JhdGlvbjEmMCQGA1UEAxMdTWljcm9zb2Z0IFRpbWUtU3RhbXAgUENB
# IDIwMTACEzMAAAHSISQxSli/LREAAQAAAdIwIgQgqLdt9xpsCNc9KFHjzghXsb8s
# XBucWEbzijk6eAvKZ98wDQYJKoZIhvcNAQELBQAEggIAF2Xk4HT515rqh10hfhjp
# I+ReO0xqDBmTkwgor7XInvZpnmgPIfpO+9BfqjD6R4w8vfx5cqiUuW6BQ/XzOWY1
# QfVN8deOS0G2WLLe302XoLkotInHWqDiBw07l0BKOrSFOTGbAgZKhbb1k6R5wcwh
# azRSqbjr4vm9kxl6E6xVTJWtk3XhZ7n+4CBZA54F63gVDJ6MuJnBZwSQ/rRlbYVY
# pv4daHRq8/XTF7iJCeBYETelLs0claMtz99uAftDxrT70NDg113xpwCKieVWv2VG
# IcqG6gx5PScdnZLtGDtUpTvSc+aSVxCfLrqEGyTQohAt/EcnjcMsxI3/l2EyKOkb
# mBFogaSfF2qhXEfmA+5ndBJdnmraph8Pf8Wl0HQXvf8a6WJ9mS6aQEFd2NexYWeP
# pDUbeh/QTlU46/wuncFHdHfK0IbMwK/Of3TwbKrv1e6Dw+IKnfMc1D2Xl5mCjzVQ
# iPJY7qtuhCdQQR/0/7Bu4eRqBTxkoFzX8whWn0OHZcWC9XKY/99xD2CAXoWXRLQV
# NrpydIT8n3ZDDruNB+4NWnpCTgetBKsoNutoRleSPYJ7rCLrn6XmnJGvFbCAhtAp
# /XjfDjx2mazYWv9JkFrg6JOUCh8tGaevJ7CG8a0DlN06Js2/uIq+s+0o5beWMUjH
# oiPvVtKLRYcCQhw0+inySuc=
# SIG # End signature block
