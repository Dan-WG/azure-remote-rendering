# This Powershell script is an example for the usage of the Azure Remote Rendering service
# Documentation: https://docs.microsoft.com/en-us/azure/remote-rendering/samples/powershell-example-scripts
#
# Usage:
# Fill out the accountSettings and renderingSessionSettings in arrconfig.json next to this file!
# This script is using the ARR REST API to start a rendering session

# RenderingSession.ps1
#   Will call the ARR REST interface to create a rendering session and poll its status until the rendering session is ready or an error occurs
#   Will print the hostname of the spun up rendering session on completion

# RenderingSession.ps1 -CreateSession
#   Will call the ARR REST interface to create a rendering session. Will print a session id which can be used to poll for its status

# RenderingSession.ps1 -GetSessionProperties [sessionID] [-Poll]
#   Will call the session properties REST API to retrieve the status of the rendering session with the given sessionID
#   If no sessionID is provided will prompt the user to enter a sessionID
#   Prints the current status of the session
#   If -Poll is specified will poll until the session is ready or an error occurs

# RenderingSession.ps1 -UpdateSession -MaxLeaseTime <hh:mm:ss> -Id [sessionID]
#   Updates the MaxLeaseTime of an already running session.
#   Note this sets the maxLeaseTime and does not extend it by the given duration
#   If no sessionID is provided the user will be asked to ender a sessionID

# RenderingSession.ps1 -StopSession -Id [sessionID]
#   Will call the stop session REST API to terminate an ongoing rendering session
#   If no sessionID is provided the user will be asked to ender a sessionID

# RenderingSession.ps1 -GetSessions -Id [sessionID]
#   Will list all currently running sessions and their properties

#The following individual parameters can be used to override values in the config file to create a session
# -VmSize <size>
# -Region <region>
# -ArrAccountId
# -ArrAccountKey
# -MaxLeaseTime <MaxLeaseTime>

Param(
    [switch] $CreateSession,
    [switch] $GetSessionProperties,
    [switch] $GetSessions,
    [switch] $UpdateSession,
    [switch] $StopSession,
    [switch] $Poll,
    [string] $Id,
    [string] $ArrAccountId, #optional override for arrAccountId of accountSettings in config file
    [string] $ArrAccountKey, #optional override for arrAccountKey of accountSettings in config file
    [string] $Region, #optional override for region of accountSettings in config file
    [string] $VmSize, #optional override for vmSize of renderingSessionSettings in config file
    [string] $MaxLeaseTime, #optional override for naxLeaseTime of renderingSessionSettings in config file
    [string] $AuthenticationEndpoint,
    [string] $ServiceEndpoint,
    [string] $ConfigFile,
    [hashtable] $AdditionalParameters
)

. "$PSScriptRoot\ARRUtils.ps1" #include ARRUtils for Logging, Config parsing

Set-StrictMode -Version Latest
$PrerequisitesInstalled = CheckPrerequisites
if (-Not $PrerequisitesInstalled) {
    WriteError("Prerequisites not installed - Exiting.")
    exit 1
}

$LoggedIn = CheckLogin
if (-Not $LoggedIn) {
    WriteError("User not logged in - Exiting.")
    exit 1
}
function WriteSessionProperties($session) {
    WriteInformation("    sessionId:                  $($session.id)")
    WriteInformation("    elapsedTimeMinutes:         $($session.elapsedTimeMinutes)")
    if ([bool]($session | get-member -name "hostname")) {
        WriteInformation("    sessionHostname:            $($session.hostname)")
    }
    if ([bool]($session | get-member -name "arrInspectorPort")) {
        WriteInformation("    arrInspectorPort:           $($session.arrInspectorPort)")
    }
    if ([bool]($session | get-member -name "handshakePort")) {
        WriteInformation("    handshakePort:              $($session.handshakePort)")
    }
    WriteInformation("    sessionMaxLeaseTimeMinutes: $($session.maxLeaseTimeMinutes)")
    WriteInformation("    sessionSize:                $($session.size)")
    WriteInformation("    sessionStatus:              $($session.status)")
    if ([bool]($session | get-member -name "error")) {
        WriteInformation("    error:                      $($session.error)")
    }
}

#call REST API <endpoint>/accounts/<accountId>/sessions/
function GetSessions($authenticationEndpoint, $serviceEndpoint, $accountId, $accountKey) {
    try {
        $url = "$serviceEndpoint/accounts/$accountId/sessions?api-version=2021-01-01-preview"

        $token = GetAuthenticationToken -authenticationEndpoint $authenticationEndpoint -accountId $accountId -accountKey $accountKey
        $response = Invoke-WebRequest -UseBasicParsing -Uri $url -Method GET -ContentType "application/json" -Headers @{ Authorization = "Bearer $token" }

        if ($response.StatusCode -eq 200) {
            Write-Host -ForegroundColor Green "********************************************************************************************************************";

            $responseFromJson = ($response | ConvertFrom-Json)

            WriteSuccessResponse("Currently there are $($responseFromJson.sessions.Length) sessions:")

            foreach ($session in $responseFromJson.sessions) {
                WriteSessionProperties($session)
                WriteInformation("")
            }

            Write-Host -ForegroundColor Green "********************************************************************************************************************";
        }
    }
    catch {
        WriteError("Unable to get the status of sessions")
        HandleException($_.Exception)
        throw
    }
}

#call REST API <endpoint>/accounts/<accountId>/sessions/<SessionId> with PATCH to update a session
# currently only updates the leaseTime
# $MaxLeaseTime has to be strictly larger than the existing lease time of the session
function UpdateSession($authenticationEndpoint, $serviceEndpoint, $accountId, $accountKey, $sessionId, [timespan] $maxLeaseTime) {
    try {
        $body =
        @{
            maxLeaseTimeMinutes = $maxLeaseTime.TotalMinutes -as [int];
        } | ConvertTo-Json
        $url = "$serviceEndpoint/accounts/$accountId/sessions/${sessionId}?api-version=2021-01-01-preview"

        $token = GetAuthenticationToken -authenticationEndpoint $authenticationEndpoint -accountId $accountId -accountKey $accountKey
        $response = Invoke-WebRequest -UseBasicParsing -Uri $url -Method PATCH -ContentType "application/json" -Body $body -Headers @{ Authorization = "Bearer $token" }

        WriteSuccessResponse($response.RawContent)

        $responseFromJson = ($response | ConvertFrom-Json)

        WriteInformation("Successfully updated session. Session properties:")
        WriteSessionProperties($responseFromJson)

        return $response
    }
    catch {
        WriteError("Unable to get the status of the session with Id: $sessionId")
        HandleException($_.Exception)
        throw
    }
}

# retrieves GetSessionProperties until error or ready status of rendering session are achieved
function PollSessionStatus($authenticationEndpoint, $serviceEndpoint, $accountId, $accountKey, $sessionId) {
    $sessionStatus = "Starting"

    WriteInformation("Provisioning a VM for rendering session '$sessionId' ...")

    $pollIntervalSec = 10

    if ($VmSize -eq "standard") {
        $pollIntervalSec = 2
    }

    $stopwatch = [system.diagnostics.stopwatch]::StartNew()

    while ($true) {
        $duration = FormatMilliseconds $stopwatch.ElapsedMilliseconds

        WriteProgress -Activity "Preparing VM for rendering session '$sessionId' ..." -Status: "Preparing for $duration"

        $response = GetSessionProperties $authenticationEndpoint $serviceEndpoint $accountId $accountKey $sessionId
        $responseContent = $response.Content | ConvertFrom-Json

        $sessionStatus = $responseContent.status
        if ($sessionStatus -iin "ready", "error", "expired") {
            break
        }
        Start-Sleep -Seconds $pollIntervalSec
    }

    $duration = FormatMilliseconds $stopwatch.ElapsedMilliseconds

    if ("ready" -ieq $sessionStatus) {
        WriteInformation ("")
        Write-Host -ForegroundColor Green "Session is ready.";
        WriteInformation ("Time elapsed: $duration")
        WriteInformation ("")
        WriteSessionProperties($responseContent)
        WriteInformation ("")
        WriteInformation ("Response details:")
        WriteInformation($response)
    }

    if ("error" -ieq $sessionStatus) {
        WriteInformation ("The attempt to create a new session resulted in an error.")
        WriteInformation ("SessionId: $sessionId")
        WriteInformation ("Time elapsed: $duration")
        WriteInformation($response)
        exit 1
    }

    if ("expired" -ieq $sessionStatus) {
        WriteInformation ("The attempt to create a new session expired before it became ready. Check the settings in your configuration (arrconfig.json).")
        WriteInformation ("SessionId: $sessionId")
        WriteInformation ("Time elapsed: $duration")
        WriteInformation($response)
        exit 1
    }
}

# Execution of script starts here

if ([string]::IsNullOrEmpty($ConfigFile)) {
    $ConfigFile = "$PSScriptRoot\arrconfig.json"
}

$config = LoadConfig `
    -fileLocation $ConfigFile `
    -ArrAccountId $ArrAccountId `
    -ArrAccountKey $ArrAccountKey `
    -AuthenticationEndpoint $AuthenticationEndpoint `
    -ServiceEndpoint $ServiceEndpoint `
    -Region $Region `
    -VmSize $VmSize `
    -MaxLeaseTime $MaxLeaseTime

if ($null -eq $config) {
    WriteError("Error reading config file - Exiting.")
    exit 1
}

$defaultConfig = GetDefaultConfig

$accountOkay = VerifyAccountSettings $config $defaultConfig $ServiceEndpoint
if ($false -eq $accountOkay) {
    WriteError("Error reading accountSettings in $ConfigFile - Exiting.")
    exit 1
}

if (-Not ($GetSessionProperties -or $GetSessions -or $StopSession -or ($UpdateSession -and -Not $MaxLeaseTime))) {
    #to get session properties etc we do not need to have proper renderingsessionsettings
    #otherwise we need to check them
    $vmSettingsOkay = VerifyRenderingSessionSettings $config $defaultConfig
    if (-Not $vmSettingsOkay) {
        WriteError("renderSessionSettings not valid. please ensure valid renderSessionSettings in $ConfigFile or commandline parameters - Exiting.")
        exit 1
    }
}

# GetSessionProperties
if ($GetSessionProperties) {
    $sessionId = $Id
    if ([string]::IsNullOrEmpty($Id)) {
        $sessionId = Read-Host "Please enter Session Id"
    }
    if ($Poll) {
        PollSessionStatus -authenticationEndpoint $config.accountSettings.authenticationEndpoint -serviceEndpoint $config.accountSettings.serviceEndpoint -accountId $config.accountSettings.arrAccountId -accountKey $config.accountSettings.arrAccountKey -SessionId $sessionId
    }
    else {
        $response = GetSessionProperties -authenticationEndpoint $config.accountSettings.authenticationEndpoint -serviceEndpoint $config.accountSettings.serviceEndpoint -accountId $config.accountSettings.arrAccountId -accountKey $config.accountSettings.arrAccountKey -SessionId $sessionId

        $responseFromJson = ($response | ConvertFrom-Json)

        WriteInformation("Session Status:")
        WriteSessionProperties($responseFromJson)
    }
    exit
}

# GetSessions
if ($GetSessions) {
    GetSessions -authenticationEndpoint $config.accountSettings.authenticationEndpoint -serviceEndpoint $config.accountSettings.serviceEndpoint -accountId $config.accountSettings.arrAccountId -accountKey $config.accountSettings.arrAccountKey
    exit
}

# StopSession
if ($StopSession) {
    $sessionId = $Id
    if ([string]::IsNullOrEmpty($Id)) {
        $sessionId = Read-Host "Please enter Session Id"
    }

    $null = StopSession -authenticationEndpoint $config.accountSettings.authenticationEndpoint -serviceEndpoint $config.accountSettings.serviceEndpoint -accountId $config.accountSettings.arrAccountId -accountKey $config.accountSettings.arrAccountKey -SessionId $sessionId

    exit
}

#UpdateSession
if ($UpdateSession) {
    $sessionId = $Id
    if ([string]::IsNullOrEmpty($Id)) {
        $sessionId = Read-Host "Please enter Session Id"
    }
    $null = UpdateSession -authenticationEndpoint $config.accountSettings.authenticationEndpoint -serviceEndpoint $config.accountSettings.serviceEndpoint -accountId $config.accountSettings.arrAccountId -accountKey $config.accountSettings.arrAccountKey -SessionId $sessionId -maxLeaseTime $config.renderingSessionSettings.maxLeaseTime

    exit
}

# Create a Session and Poll for Completion
$sessionId = CreateRenderingSession -authenticationEndpoint $config.accountSettings.authenticationEndpoint -serviceEndpoint $config.accountSettings.serviceEndpoint -accountId $config.accountSettings.arrAccountId -accountKey $config.accountSettings.arrAccountKey -vmSize $config.renderingSessionSettings.vmSize -maxLeaseTime $config.renderingSessionSettings.maxLeaseTime -AdditionalParameters $AdditionalParameters -sessionId $Id
if ($CreateSession -and ($false -eq $Poll)) {
    exit #do not poll if we asked to only create the session
}
PollSessionStatus -authenticationEndpoint $config.accountSettings.authenticationEndpoint -serviceEndpoint $config.accountSettings.serviceEndpoint -accountId $config.accountSettings.arrAccountId -accountKey $config.accountSettings.arrAccountKey -SessionId $sessionId

# SIG # Begin signature block
# MIIrWAYJKoZIhvcNAQcCoIIrSTCCK0UCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCD0p0jsj1n5j0gN
# bNW6Wiy8+gcD/k9jgkOCKhSlelbyb6CCEXkwggiJMIIHcaADAgECAhM2AAABfv9v
# /QSkJVgSAAIAAAF+MA0GCSqGSIb3DQEBCwUAMEExEzARBgoJkiaJk/IsZAEZFgNH
# QkwxEzARBgoJkiaJk/IsZAEZFgNBTUUxFTATBgNVBAMTDEFNRSBDUyBDQSAwMTAe
# Fw0yMTA5MDkwMTI2MjZaFw0yMjA5MDkwMTI2MjZaMCQxIjAgBgNVBAMTGU1pY3Jv
# c29mdCBBenVyZSBDb2RlIFNpZ24wggEiMA0GCSqGSIb3DQEBAQUAA4IBDwAwggEK
# AoIBAQCQh1zMc6GVq9fygCskp/O9g6jS0ilJ3idmz+2JkE+9AarM0AiJ1/CDQETS
# X56JOh9Vm8kdffjdqJfD2NoSV2lO1eKAFKETKyiJKvbcW38H7JhH1h+yCBjajiWy
# wcAZ/ipRX3sMYM5nXl5+GxEZpGQbLIsrLj24Zi9dj2kdHc0DxqbemzlCySiB+n9r
# HFdi9zEn6XzuTf/3i6XM36lUPZ+xt6Zckupu0CAnu4dZr1XiwHvbJvqq3RcXOU5j
# p1m/AKk4Ov+9jaEKOnYiHJbnpC+vKx/Zv8aZajhPyVY3fXb/tygGOyb607EYn7F2
# v4AcJL5ocPTT3BGWtve1KuOwRRs3AgMBAAGjggWVMIIFkTApBgkrBgEEAYI3FQoE
# HDAaMAwGCisGAQQBgjdbAQEwCgYIKwYBBQUHAwMwPQYJKwYBBAGCNxUHBDAwLgYm
# KwYBBAGCNxUIhpDjDYTVtHiE8Ys+hZvdFs6dEoFgg93NZoaUjDICAWQCAQwwggJ2
# BggrBgEFBQcBAQSCAmgwggJkMGIGCCsGAQUFBzAChlZodHRwOi8vY3JsLm1pY3Jv
# c29mdC5jb20vcGtpaW5mcmEvQ2VydHMvQlkyUEtJQ1NDQTAxLkFNRS5HQkxfQU1F
# JTIwQ1MlMjBDQSUyMDAxKDIpLmNydDBSBggrBgEFBQcwAoZGaHR0cDovL2NybDEu
# YW1lLmdibC9haWEvQlkyUEtJQ1NDQTAxLkFNRS5HQkxfQU1FJTIwQ1MlMjBDQSUy
# MDAxKDIpLmNydDBSBggrBgEFBQcwAoZGaHR0cDovL2NybDIuYW1lLmdibC9haWEv
# QlkyUEtJQ1NDQTAxLkFNRS5HQkxfQU1FJTIwQ1MlMjBDQSUyMDAxKDIpLmNydDBS
# BggrBgEFBQcwAoZGaHR0cDovL2NybDMuYW1lLmdibC9haWEvQlkyUEtJQ1NDQTAx
# LkFNRS5HQkxfQU1FJTIwQ1MlMjBDQSUyMDAxKDIpLmNydDBSBggrBgEFBQcwAoZG
# aHR0cDovL2NybDQuYW1lLmdibC9haWEvQlkyUEtJQ1NDQTAxLkFNRS5HQkxfQU1F
# JTIwQ1MlMjBDQSUyMDAxKDIpLmNydDCBrQYIKwYBBQUHMAKGgaBsZGFwOi8vL0NO
# PUFNRSUyMENTJTIwQ0ElMjAwMSxDTj1BSUEsQ049UHVibGljJTIwS2V5JTIwU2Vy
# dmljZXMsQ049U2VydmljZXMsQ049Q29uZmlndXJhdGlvbixEQz1BTUUsREM9R0JM
# P2NBQ2VydGlmaWNhdGU/YmFzZT9vYmplY3RDbGFzcz1jZXJ0aWZpY2F0aW9uQXV0
# aG9yaXR5MB0GA1UdDgQWBBRufMhNVeWweAyGzdFbxkxa8y1WjDAOBgNVHQ8BAf8E
# BAMCB4AwUAYDVR0RBEkwR6RFMEMxKTAnBgNVBAsTIE1pY3Jvc29mdCBPcGVyYXRp
# b25zIFB1ZXJ0byBSaWNvMRYwFAYDVQQFEw0yMzYxNjcrNDY3OTc0MIIB5gYDVR0f
# BIIB3TCCAdkwggHVoIIB0aCCAc2GP2h0dHA6Ly9jcmwubWljcm9zb2Z0LmNvbS9w
# a2lpbmZyYS9DUkwvQU1FJTIwQ1MlMjBDQSUyMDAxKDIpLmNybIYxaHR0cDovL2Ny
# bDEuYW1lLmdibC9jcmwvQU1FJTIwQ1MlMjBDQSUyMDAxKDIpLmNybIYxaHR0cDov
# L2NybDIuYW1lLmdibC9jcmwvQU1FJTIwQ1MlMjBDQSUyMDAxKDIpLmNybIYxaHR0
# cDovL2NybDMuYW1lLmdibC9jcmwvQU1FJTIwQ1MlMjBDQSUyMDAxKDIpLmNybIYx
# aHR0cDovL2NybDQuYW1lLmdibC9jcmwvQU1FJTIwQ1MlMjBDQSUyMDAxKDIpLmNy
# bIaBvWxkYXA6Ly8vQ049QU1FJTIwQ1MlMjBDQSUyMDAxKDIpLENOPUJZMlBLSUNT
# Q0EwMSxDTj1DRFAsQ049UHVibGljJTIwS2V5JTIwU2VydmljZXMsQ049U2Vydmlj
# ZXMsQ049Q29uZmlndXJhdGlvbixEQz1BTUUsREM9R0JMP2NlcnRpZmljYXRlUmV2
# b2NhdGlvbkxpc3Q/YmFzZT9vYmplY3RDbGFzcz1jUkxEaXN0cmlidXRpb25Qb2lu
# dDAfBgNVHSMEGDAWgBSWUYTga297/tgGq8PyheYprmr51DAfBgNVHSUEGDAWBgor
# BgEEAYI3WwEBBggrBgEFBQcDAzANBgkqhkiG9w0BAQsFAAOCAQEAU1RmrZsQtaYx
# 8dBu9zC6w4TXEtumd3O0ArP7W0Co7nNFCDTv8pxqOM2bz/pH49DXdnzcXCTjUjci
# o03V+QPO3Ql8xOMqm8bE9Kcof+fPk4DyDY5y+YzxQyk49URn4ea3WhihAJkg/xnF
# LiKnbWW8iyqxie+B44u9dPfbsWrxcgedzSnH0aXwfIt29IKCpGHL74rBDbKHXdL0
# pEjf9c2YA6OiS1IH7X/suBjEFa4LEYPTSFK2AJXpgM7q9dmSvta4CyudRoYf1BXP
# KR+CzNT9XL5ZJX8LUuC5LrZgbt7LzjlW+1Umo2OsmUO3YA7/s5vH6Tqc6uZ9isIw
# sit0XfouHTCCCOgwggbQoAMCAQICEx8AAABR6o/2nHMMqDsAAAAAAFEwDQYJKoZI
# hvcNAQELBQAwPDETMBEGCgmSJomT8ixkARkWA0dCTDETMBEGCgmSJomT8ixkARkW
# A0FNRTEQMA4GA1UEAxMHYW1lcm9vdDAeFw0yMTA1MjExODQ0MTRaFw0yNjA1MjEx
# ODU0MTRaMEExEzARBgoJkiaJk/IsZAEZFgNHQkwxEzARBgoJkiaJk/IsZAEZFgNB
# TUUxFTATBgNVBAMTDEFNRSBDUyBDQSAwMTCCASIwDQYJKoZIhvcNAQEBBQADggEP
# ADCCAQoCggEBAMmaUgl9AZ6NVtcqlzIU+gVJSWVqWuKd8RXokxzuL5tkOgv2s0ec
# cMZ8mB65Ehg7Utj/V/igxOuFdtJphEJLm8ZzzXjlZxNkb3TxsYMJavgYUtzjXVbE
# D4+/au14BzPR4cwffqpNDwvSjdc5vaf7HsokUuiRdXWzqkX9aVJexQFcZoIghYFf
# IRyG/6wz14oOxQ4t0tMhMdglA1aSKvIxIRvGp1BRNVmMTPp4tEuSh8MCjyleKshg
# 6AzvvQJg6JmtwocruVg5VuXHbal01rBjxN7prZ1+gJpZXVBS5rODlUeILin/p+Sy
# AQgum04qHH1z6JqmI2EysewBjH2lS2ml5oUCAwEAAaOCBNwwggTYMBIGCSsGAQQB
# gjcVAQQFAgMCAAIwIwYJKwYBBAGCNxUCBBYEFBJoJEIhR8vUa74xzyCkwAsjfz9H
# MB0GA1UdDgQWBBSWUYTga297/tgGq8PyheYprmr51DCCAQQGA1UdJQSB/DCB+QYH
# KwYBBQIDBQYIKwYBBQUHAwEGCCsGAQUFBwMCBgorBgEEAYI3FAIBBgkrBgEEAYI3
# FQYGCisGAQQBgjcKAwwGCSsGAQQBgjcVBgYIKwYBBQUHAwkGCCsGAQUFCAICBgor
# BgEEAYI3QAEBBgsrBgEEAYI3CgMEAQYKKwYBBAGCNwoDBAYJKwYBBAGCNxUFBgor
# BgEEAYI3FAICBgorBgEEAYI3FAIDBggrBgEFBQcDAwYKKwYBBAGCN1sBAQYKKwYB
# BAGCN1sCAQYKKwYBBAGCN1sDAQYKKwYBBAGCN1sFAQYKKwYBBAGCN1sEAQYKKwYB
# BAGCN1sEAjAZBgkrBgEEAYI3FAIEDB4KAFMAdQBiAEMAQTALBgNVHQ8EBAMCAYYw
# EgYDVR0TAQH/BAgwBgEB/wIBADAfBgNVHSMEGDAWgBQpXlFeZK40ueusnA2njHUB
# 0QkLKDCCAWgGA1UdHwSCAV8wggFbMIIBV6CCAVOgggFPhjFodHRwOi8vY3JsLm1p
# Y3Jvc29mdC5jb20vcGtpaW5mcmEvY3JsL2FtZXJvb3QuY3JshiNodHRwOi8vY3Js
# Mi5hbWUuZ2JsL2NybC9hbWVyb290LmNybIYjaHR0cDovL2NybDMuYW1lLmdibC9j
# cmwvYW1lcm9vdC5jcmyGI2h0dHA6Ly9jcmwxLmFtZS5nYmwvY3JsL2FtZXJvb3Qu
# Y3JshoGqbGRhcDovLy9DTj1hbWVyb290LENOPUFNRVJvb3QsQ049Q0RQLENOPVB1
# YmxpYyUyMEtleSUyMFNlcnZpY2VzLENOPVNlcnZpY2VzLENOPUNvbmZpZ3VyYXRp
# b24sREM9QU1FLERDPUdCTD9jZXJ0aWZpY2F0ZVJldm9jYXRpb25MaXN0P2Jhc2U/
# b2JqZWN0Q2xhc3M9Y1JMRGlzdHJpYnV0aW9uUG9pbnQwggGrBggrBgEFBQcBAQSC
# AZ0wggGZMEcGCCsGAQUFBzAChjtodHRwOi8vY3JsLm1pY3Jvc29mdC5jb20vcGtp
# aW5mcmEvY2VydHMvQU1FUm9vdF9hbWVyb290LmNydDA3BggrBgEFBQcwAoYraHR0
# cDovL2NybDIuYW1lLmdibC9haWEvQU1FUm9vdF9hbWVyb290LmNydDA3BggrBgEF
# BQcwAoYraHR0cDovL2NybDMuYW1lLmdibC9haWEvQU1FUm9vdF9hbWVyb290LmNy
# dDA3BggrBgEFBQcwAoYraHR0cDovL2NybDEuYW1lLmdibC9haWEvQU1FUm9vdF9h
# bWVyb290LmNydDCBogYIKwYBBQUHMAKGgZVsZGFwOi8vL0NOPWFtZXJvb3QsQ049
# QUlBLENOPVB1YmxpYyUyMEtleSUyMFNlcnZpY2VzLENOPVNlcnZpY2VzLENOPUNv
# bmZpZ3VyYXRpb24sREM9QU1FLERDPUdCTD9jQUNlcnRpZmljYXRlP2Jhc2U/b2Jq
# ZWN0Q2xhc3M9Y2VydGlmaWNhdGlvbkF1dGhvcml0eTANBgkqhkiG9w0BAQsFAAOC
# AgEAUBAjt08P6N9e0a3e8mnanLMD8dS7yGMppGkzeinJrkbehymtF3u91MdvwEN9
# E34APRgSZ4MHkcpCgbrEc8jlNe4iLmyb8t4ANtXcLarQdA7KBL9VP6bVbtr/vnaE
# wif4vhm7LFV5IGl/B/uhDhhJk+Hr6eBm8EeB8FpXPg73/Bx/D3VANmdOAr3MCH3J
# EoqWzZvOI8SfF45kxU1rHJXS/XnY9jbGOohp8iRSMrq9j0u1UWMld6dVQCafdYI9
# Y0ULVhMggfD+YPZxN8/LtADWlP4Y8BEAq3Rsq2r1oJ39ibRvm09umAKJG3PJvt9s
# 1LV0TvjSt7QI4TrthXbBt6jaxeLHO8t+0fwvuz3G/3BX4bbarIq3qWYouMUrXIzD
# g2Ll8xptyCbNG9KMBxuqCne2Thrx6ZpofSvPwy64g/7KvG1EQ9dKov8LlvMzOyKS
# 4Nb3EfXSCtpnNKY+OKXOlF9F27bT/1RCYLt5U9niPVY1rWio8d/MRPcKEjMnpD0b
# c08IH7srBfQ5CYrK/sgOKaPxT8aWwcPXP4QX99gx/xhcbXktqZo4CiGzD/LA7pJh
# Kt5Vb7ljSbMm62cEL0Kb2jOPX7/iSqSyuWFmBH8JLGEUfcFPB4fyA/YUQhJG1KEN
# lu5jKbKdjW6f5HJ+Ir36JVMt0PWH9LHLEOlky2KZvgKAlCUxghk1MIIZMQIBATBY
# MEExEzARBgoJkiaJk/IsZAEZFgNHQkwxEzARBgoJkiaJk/IsZAEZFgNBTUUxFTAT
# BgNVBAMTDEFNRSBDUyBDQSAwMQITNgAAAX7/b/0EpCVYEgACAAABfjANBglghkgB
# ZQMEAgEFAKCBrjAZBgkqhkiG9w0BCQMxDAYKKwYBBAGCNwIBBDAcBgorBgEEAYI3
# AgELMQ4wDAYKKwYBBAGCNwIBFTAvBgkqhkiG9w0BCQQxIgQgrr5RvuPY5GJqXVz+
# WZFT4E5uVN3DMMi/ew4RAxpsAXYwQgYKKwYBBAGCNwIBDDE0MDKgFIASAE0AaQBj
# AHIAbwBzAG8AZgB0oRqAGGh0dHA6Ly93d3cubWljcm9zb2Z0LmNvbTANBgkqhkiG
# 9w0BAQEFAASCAQAiZxLrRFQvrhAEuZi19jxJtOrvM/53/G8kAYJsJMYkBCMs5Qsm
# uTcPGE4ztj4xvavJvIAR/z+SRGRUT5nlairSlMAoq76ZTK+2SuHYQ4y3SWW3aBV4
# pRkFQTdYnXe0oaBMmi7+NfLS4lHbM0GuHCtrYKuBadEn1bBkdlg+KwRg80Il6xbS
# MdmVt8Vnw1YA1eplbAbZsYRHcAWQtVuxcwDZDDkxCUbwlQsK8nRLdSvbbmbGpfk7
# Z+6b1lpsignvEvnE0/hSxerLsDiQpsW2erNhP/Ds1IjyqscgaMJGfhn9tz+EMdLX
# kfTS6bL0A05HjWKMeSwQH1ECQ9oCVKf33xRRoYIW/TCCFvkGCisGAQQBgjcDAwEx
# ghbpMIIW5QYJKoZIhvcNAQcCoIIW1jCCFtICAQMxDzANBglghkgBZQMEAgEFADCC
# AVEGCyqGSIb3DQEJEAEEoIIBQASCATwwggE4AgEBBgorBgEEAYRZCgMBMDEwDQYJ
# YIZIAWUDBAIBBQAEICkKNsaJmtlC37hh+byNBOUCqIMM9C2aPdHgSEzQyu+gAgZi
# acXkag8YEzIwMjIwNTA0MTgxMTM5LjgyMVowBIACAfSggdCkgc0wgcoxCzAJBgNV
# BAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4w
# HAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xJTAjBgNVBAsTHE1pY3Jvc29m
# dCBBbWVyaWNhIE9wZXJhdGlvbnMxJjAkBgNVBAsTHVRoYWxlcyBUU1MgRVNOOjdC
# RjEtRTNFQS1CODA4MSUwIwYDVQQDExxNaWNyb3NvZnQgVGltZS1TdGFtcCBTZXJ2
# aWNloIIRVDCCBwwwggT0oAMCAQICEzMAAAGfK0U1FQguS10AAQAAAZ8wDQYJKoZI
# hvcNAQELBQAwfDELMAkGA1UEBhMCVVMxEzARBgNVBAgTCldhc2hpbmd0b24xEDAO
# BgNVBAcTB1JlZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjEm
# MCQGA1UEAxMdTWljcm9zb2Z0IFRpbWUtU3RhbXAgUENBIDIwMTAwHhcNMjExMjAy
# MTkwNTIyWhcNMjMwMjI4MTkwNTIyWjCByjELMAkGA1UEBhMCVVMxEzARBgNVBAgT
# Cldhc2hpbmd0b24xEDAOBgNVBAcTB1JlZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29m
# dCBDb3Jwb3JhdGlvbjElMCMGA1UECxMcTWljcm9zb2Z0IEFtZXJpY2EgT3BlcmF0
# aW9uczEmMCQGA1UECxMdVGhhbGVzIFRTUyBFU046N0JGMS1FM0VBLUI4MDgxJTAj
# BgNVBAMTHE1pY3Jvc29mdCBUaW1lLVN0YW1wIFNlcnZpY2UwggIiMA0GCSqGSIb3
# DQEBAQUAA4ICDwAwggIKAoICAQCk9Xl8TVGyiZAvzm8tB4fLP0znL883YDIG03js
# 1/WzCaICXDs0kXlJ39OUZweBFa/V8l27mlBjyLZDtTg3W8dQORDunfn7SzZEoFml
# XaSYcQhyDMV5ghxi6lh8y3NV1TNHGYLzaoQmtBeuFSlEH9wp6rC/sRK7GPrOn17X
# AGzo+/yFy7DfWgIQ43X35ut20TShUeYDrs5GOVpHp7ouqQYRTpu+lAaCHfq8tr+L
# FqIyjpkvxxb3Hcx6Vjte0NPH6GnICT84PxWYK7eoa5AxbsTUqWQyiWtrGoyQyXP4
# yIKfTUYPtsTFCi14iuJNr3yRGjo4U1OHZU2yGmWeCrdccJgkby6k2N5AhRYvKHre
# PPh5oWHY01g8TckxV4h4iloqvaaYGh3HDPWPw4KoKyEy7QHGuZK1qAkheWiKX2qE
# 0eNRWummCKPhdcF3dcViVI9aKXhty4zM76tsUjcdCtnG5VII6eU6dzcL6YFp0vMl
# 7JPI3y9Irx9sBEiVmSigM2TDZU4RUIbFItD60DJYzNH0rGu2Dv39P/0Owox37P3Z
# fvB5jAeg6B+SBSD0awi+f61JFrVc/UZ83W+5tgI/0xcLGWHBNdEibSF1NFfrV0KP
# CKfi9iD2BkQgMYi02CY8E3us+UyYA4NFYcWJpjacBKABeDBdkY1BPfGgzskaKhIG
# hdox9QIDAQABo4IBNjCCATIwHQYDVR0OBBYEFGI08tUeExYrSA4u6N/ZasfWHchh
# MB8GA1UdIwQYMBaAFJ+nFV0AXmJdg/Tl0mWnG1M1GelyMF8GA1UdHwRYMFYwVKBS
# oFCGTmh0dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMvY3JsL01pY3Jvc29m
# dCUyMFRpbWUtU3RhbXAlMjBQQ0ElMjAyMDEwKDEpLmNybDBsBggrBgEFBQcBAQRg
# MF4wXAYIKwYBBQUHMAKGUGh0dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMv
# Y2VydHMvTWljcm9zb2Z0JTIwVGltZS1TdGFtcCUyMFBDQSUyMDIwMTAoMSkuY3J0
# MAwGA1UdEwEB/wQCMAAwEwYDVR0lBAwwCgYIKwYBBQUHAwgwDQYJKoZIhvcNAQEL
# BQADggIBAB2KKCk8O+kZ8+m9bPXQIAmo+6xbKDaKkMR3/82A8XVAMa9RpItYJkdk
# ta+C6ZIVBsZEARJkKnWpYJiiyGBV3PmPoIMP5zFbr0BYLMolDJZMtH3MifVBD9Nk
# nYNKg+GbWyaAPs8VZ6UD3CRzjoVZ2PbHRH+UOl2Yc/cm1IR3BlvjlcNwykpzBGUn
# dARefuzjfRSfB+dBzmlFY+dME8+J3OvveMraIcznSrlr46GXMoWGJt0hBJNf4G5J
# ZqyXe8n8z2yR5poL2uiMRzqIXX1rwCIXhcLPFgSKN/vJxrxHiF9ByViouf4jCcD8
# O2mO94toCSqLERuodSe9dQ7qrKVBonDoYWAx+W0XGAX2qaoZmqEun7Qb8hnyNyVr
# J2C2fZwAY2yiX3ZMgLGUrpDRoJWdP+tc5SS6KZ1fwyhL/KAgjiNPvUBiu7PF4LHx
# 5TRFU7HZXvgpZDn5xktkXZidA4S26NZsMSygx0R1nXV3ybY3JdlNfRETt6SIfQdC
# xRX5YUbI5NdvuVMiy5oB3blfhPgNJyo0qdmkHKE2pN4c8iw9SrajnWcM0bUExrDk
# Nqcwaq11Dzwc0lDGX14gnjGRbghl6HLsD7jxx0+buzJHKZPzGdTLMFKoSdJeV4pU
# /t3dPbdU21HS60Ex2Ip2TdGfgtS9POzVaTA4UucuklbjZkQihfg2MIIHcTCCBVmg
# AwIBAgITMwAAABXF52ueAptJmQAAAAAAFTANBgkqhkiG9w0BAQsFADCBiDELMAkG
# A1UEBhMCVVMxEzARBgNVBAgTCldhc2hpbmd0b24xEDAOBgNVBAcTB1JlZG1vbmQx
# HjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjEyMDAGA1UEAxMpTWljcm9z
# b2Z0IFJvb3QgQ2VydGlmaWNhdGUgQXV0aG9yaXR5IDIwMTAwHhcNMjEwOTMwMTgy
# MjI1WhcNMzAwOTMwMTgzMjI1WjB8MQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2Fz
# aGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENv
# cnBvcmF0aW9uMSYwJAYDVQQDEx1NaWNyb3NvZnQgVGltZS1TdGFtcCBQQ0EgMjAx
# MDCCAiIwDQYJKoZIhvcNAQEBBQADggIPADCCAgoCggIBAOThpkzntHIhC3miy9ck
# eb0O1YLT/e6cBwfSqWxOdcjKNVf2AX9sSuDivbk+F2Az/1xPx2b3lVNxWuJ+Slr+
# uDZnhUYjDLWNE893MsAQGOhgfWpSg0S3po5GawcU88V29YZQ3MFEyHFcUTE3oAo4
# bo3t1w/YJlN8OWECesSq/XJprx2rrPY2vjUmZNqYO7oaezOtgFt+jBAcnVL+tuhi
# JdxqD89d9P6OU8/W7IVWTe/dvI2k45GPsjksUZzpcGkNyjYtcI4xyDUoveO0hyTD
# 4MmPfrVUj9z6BVWYbWg7mka97aSueik3rMvrg0XnRm7KMtXAhjBcTyziYrLNueKN
# iOSWrAFKu75xqRdbZ2De+JKRHh09/SDPc31BmkZ1zcRfNN0Sidb9pSB9fvzZnkXf
# tnIv231fgLrbqn427DZM9ituqBJR6L8FA6PRc6ZNN3SUHDSCD/AQ8rdHGO2n6Jl8
# P0zbr17C89XYcz1DTsEzOUyOArxCaC4Q6oRRRuLRvWoYWmEBc8pnol7XKHYC4jMY
# ctenIPDC+hIK12NvDMk2ZItboKaDIV1fMHSRlJTYuVD5C4lh8zYGNRiER9vcG9H9
# stQcxWv2XFJRXRLbJbqvUAV6bMURHXLvjflSxIUXk8A8FdsaN8cIFRg/eKtFtvUe
# h17aj54WcmnGrnu3tz5q4i6tAgMBAAGjggHdMIIB2TASBgkrBgEEAYI3FQEEBQID
# AQABMCMGCSsGAQQBgjcVAgQWBBQqp1L+ZMSavoKRPEY1Kc8Q/y8E7jAdBgNVHQ4E
# FgQUn6cVXQBeYl2D9OXSZacbUzUZ6XIwXAYDVR0gBFUwUzBRBgwrBgEEAYI3TIN9
# AQEwQTA/BggrBgEFBQcCARYzaHR0cDovL3d3dy5taWNyb3NvZnQuY29tL3BraW9w
# cy9Eb2NzL1JlcG9zaXRvcnkuaHRtMBMGA1UdJQQMMAoGCCsGAQUFBwMIMBkGCSsG
# AQQBgjcUAgQMHgoAUwB1AGIAQwBBMAsGA1UdDwQEAwIBhjAPBgNVHRMBAf8EBTAD
# AQH/MB8GA1UdIwQYMBaAFNX2VsuP6KJcYmjRPZSQW9fOmhjEMFYGA1UdHwRPME0w
# S6BJoEeGRWh0dHA6Ly9jcmwubWljcm9zb2Z0LmNvbS9wa2kvY3JsL3Byb2R1Y3Rz
# L01pY1Jvb0NlckF1dF8yMDEwLTA2LTIzLmNybDBaBggrBgEFBQcBAQROMEwwSgYI
# KwYBBQUHMAKGPmh0dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2kvY2VydHMvTWlj
# Um9vQ2VyQXV0XzIwMTAtMDYtMjMuY3J0MA0GCSqGSIb3DQEBCwUAA4ICAQCdVX38
# Kq3hLB9nATEkW+Geckv8qW/qXBS2Pk5HZHixBpOXPTEztTnXwnE2P9pkbHzQdTlt
# uw8x5MKP+2zRoZQYIu7pZmc6U03dmLq2HnjYNi6cqYJWAAOwBb6J6Gngugnue99q
# b74py27YP0h1AdkY3m2CDPVtI1TkeFN1JFe53Z/zjj3G82jfZfakVqr3lbYoVSfQ
# JL1AoL8ZthISEV09J+BAljis9/kpicO8F7BUhUKz/AyeixmJ5/ALaoHCgRlCGVJ1
# ijbCHcNhcy4sa3tuPywJeBTpkbKpW99Jo3QMvOyRgNI95ko+ZjtPu4b6MhrZlvSP
# 9pEB9s7GdP32THJvEKt1MMU0sHrYUP4KWN1APMdUbZ1jdEgssU5HLcEUBHG/ZPkk
# vnNtyo4JvbMBV0lUZNlz138eW0QBjloZkWsNn6Qo3GcZKCS6OEuabvshVGtqRRFH
# qfG3rsjoiV5PndLQTHa1V1QJsWkBRH58oWFsc/4Ku+xBZj1p/cvBQUl+fpO+y/g7
# 5LcVv7TOPqUxUYS8vwLBgqJ7Fx0ViY1w/ue10CgaiQuPNtq6TPmb/wrpNPgkNWcr
# 4A245oyZ1uEi6vAnQj0llOZ0dFtq0Z4+7X6gMTN9vMvpe784cETRkPHIqzqKOghi
# f9lwY1NNje6CbaUFEMFxBmoQtB1VM1izoXBm8qGCAsswggI0AgEBMIH4oYHQpIHN
# MIHKMQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMH
# UmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSUwIwYDVQQL
# ExxNaWNyb3NvZnQgQW1lcmljYSBPcGVyYXRpb25zMSYwJAYDVQQLEx1UaGFsZXMg
# VFNTIEVTTjo3QkYxLUUzRUEtQjgwODElMCMGA1UEAxMcTWljcm9zb2Z0IFRpbWUt
# U3RhbXAgU2VydmljZaIjCgEBMAcGBSsOAwIaAxUAdF2umB/yywxFLFTC8rJ9Fv9c
# 9reggYMwgYCkfjB8MQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQ
# MA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9u
# MSYwJAYDVQQDEx1NaWNyb3NvZnQgVGltZS1TdGFtcCBQQ0EgMjAxMDANBgkqhkiG
# 9w0BAQUFAAIFAOYc1YAwIhgPMjAyMjA1MDQxODM1NDRaGA8yMDIyMDUwNTE4MzU0
# NFowdDA6BgorBgEEAYRZCgQBMSwwKjAKAgUA5hzVgAIBADAHAgEAAgIW2zAHAgEA
# AgISRzAKAgUA5h4nAAIBADA2BgorBgEEAYRZCgQCMSgwJjAMBgorBgEEAYRZCgMC
# oAowCAIBAAIDB6EgoQowCAIBAAIDAYagMA0GCSqGSIb3DQEBBQUAA4GBAKvTpIPB
# LX3cRPJkq9Y9xjmzFg3zXJbeDoyw06aWX33fIr4J6Rpyw1Jhic5GUugg2vj3VLiu
# T5iEFUMR8HErYph8YNHmDTyJTwQjeptxcHmznhO1rNRlgrc2Jq+02+OlnIloaPGu
# mBruf2J2cObgxwlJBKgHBXu072k/kz1VbotrMYIEDTCCBAkCAQEwgZMwfDELMAkG
# A1UEBhMCVVMxEzARBgNVBAgTCldhc2hpbmd0b24xEDAOBgNVBAcTB1JlZG1vbmQx
# HjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjEmMCQGA1UEAxMdTWljcm9z
# b2Z0IFRpbWUtU3RhbXAgUENBIDIwMTACEzMAAAGfK0U1FQguS10AAQAAAZ8wDQYJ
# YIZIAWUDBAIBBQCgggFKMBoGCSqGSIb3DQEJAzENBgsqhkiG9w0BCRABBDAvBgkq
# hkiG9w0BCQQxIgQgMDp2/nKOv7PyMuptRovPfBy6DGU0kVEU7VhIn9ovcyUwgfoG
# CyqGSIb3DQEJEAIvMYHqMIHnMIHkMIG9BCCG8V4poieJnqXnVzwNUejeKgLJfEH7
# P+jspyw3S3xc2jCBmDCBgKR+MHwxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNo
# aW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29y
# cG9yYXRpb24xJjAkBgNVBAMTHU1pY3Jvc29mdCBUaW1lLVN0YW1wIFBDQSAyMDEw
# AhMzAAABnytFNRUILktdAAEAAAGfMCIEINxAA3jYBvHisfG8AF2a+1P2AO08BI2k
# 32hUDTnk5sHkMA0GCSqGSIb3DQEBCwUABIICAI82A5FAO/WDLxM4grtJYeQaiK7d
# 1xQ4Re52aR19J8cVWyzs2PYxMQu5DHWaq+XhDymqgXQ29/eFNP1nLxNXrP0hKdmw
# ITg+T3MWyttcSEe17/lR3lh1nPQS3SGCfSIIFYPlr0Ame+2ZuOBbHzJmzQJ64OR6
# CZsVL0mUk6/dVkSgTC3ZcHpcgyIklkpJKy3mVyiFZVrvlrs9bzACgwCtLm9YX3R7
# gVBoWT3DIXLJdopET1NhNbB2i9CE3NX1CgAMDMun0IuH7YRBHJTH8VmwBPhf+b/C
# SdwHD7nRkU0quIATLGn7fRAxI0zfJfY0BhA+YTDfiOpIDvyD22BCEi5hKfJL96U4
# EnNDKcebVzOeyC6qzE8Qf626LsB5tgcOjQFALW4PICc0YQ4m/eawwqd8N8K1IqzL
# 3ZlycIEKHb+itJhGWc9CmwckGxPqjW4p6ActLnsf22H7p3/9wPw/k5EUXKLlWnBM
# rPVFzHRsbrmjX18LXraTc0DtD5I3cENHA8NXoxuBy7f0GfvfOxEzMyANgLQT1nQL
# KYhdQ6mbOFNXd26JvCC8jNBxv41zwUtRLq7pqpskT9DEbq+b6jN2cfYZ0HBkUjqJ
# +VeerBU2ZsuvNXBR+qXfoepmYIF+reu+R0Jnd03NSHi+7+BHdHniUd2imUdUX1KC
# YVGYfv5tJ5j2Ds7P
# SIG # End signature block
