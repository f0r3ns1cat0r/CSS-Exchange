﻿# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.

. $PSScriptRoot\CompareExchangeBuildLevel.ps1
. $PSScriptRoot\Get-ExchangeBuildVersionInformation.ps1
. $PSScriptRoot\Get-ExSetupFileVersionInfo.ps1
. $PSScriptRoot\Invoke-ScriptBlockHandler.ps1

function Get-ProcessedServerList {
    [CmdletBinding()]
    param(
        [string[]]$ExchangeServerNames,

        [string[]]$SkipExchangeServerNames,

        [bool]$CheckOnline,

        [bool]$DisableGetExchangeServerFullList,

        [string]$MinimumSU,

        [bool]$DisplayOutdatedServers = $true
    )
    begin {
        Write-Verbose "Calling: $($MyInvocation.MyCommand)"
        # The complete list of all the Exchange Servers that we ran Get-ExchangeServer against.
        $getExchangeServer = New-Object System.Collections.Generic.List[object]
        # The list of possible validExchangeServers prior to completing the list.
        $possibleValidExchangeServer = New-Object System.Collections.Generic.List[object]
        # The Get-ExchangeServer object for all the servers that are either in ExchangeServerNames or not in SkipExchangeServerNames and are within the correct SU build.
        $validExchangeServer = New-Object System.Collections.Generic.List[object]
        # The FQDN of the servers in the validExchangeServer list
        $validExchangeServerFqdn = New-Object System.Collections.Generic.List[string]
        # Servers that are online within the validExchangeServer list.
        $onlineExchangeServer = New-Object System.Collections.Generic.List[object]
        # The FQDN of the servers that are in the onlineExchangeServer list
        $onlineExchangeServerFqdn = New-Object System.Collections.Generic.List[string]
        # Servers that are not reachable and therefore classified as offline
        $offlineExchangeServer = New-Object System.Collections.Generic.List[string]
        # The FQDN of the servers that are not reachable and therefore classified as offline
        $offlineExchangeServerFqdn = New-Object System.Collections.Generic.List[string]
        # The list of servers that are outside min required SU
        $outdatedBuildExchangeServerFqdn = New-Object System.Collections.Generic.List[string]
    }
    process {
        if ($DisableGetExchangeServerFullList) {
            # If we don't want to get all the Exchange Servers, then we need to make sure the list of Servers are Exchange Server
            if ($null -eq $ExchangeServerNames -or
                $ExchangeServerNames.Count -eq 0) {
                throw "Must provide servers to process when DisableGetExchangeServerFullList is set."
            }

            Write-Verbose "Getting the result of the Exchange Servers individually"
            foreach ($server in $ExchangeServerNames) {
                try {
                    $result = Get-ExchangeServer $server -ErrorAction Stop
                    $getExchangeServer.Add($result)
                } catch {
                    Write-Verbose "Failed to run Get-ExchangeServer for server '$server'. Inner Exception $_"
                    throw
                }
            }
        } else {
            Write-Verbose "Getting all the Exchange Servers in the organization"
            $result = @(Get-ExchangeServer)
            $getExchangeServer.AddRange($result)
        }

        if ($null -ne $ExchangeServerNames -and $ExchangeServerNames.Count -gt 0) {
            $getExchangeServer |
                Where-Object { ($_.Name -in $ExchangeServerNames) -or ($_.FQDN -in $ExchangeServerNames) } |
                ForEach-Object {
                    if ($null -ne $SkipExchangeServerNames -and $SkipExchangeServerNames.Count -gt 0) {
                        if (($_.Name -notin $SkipExchangeServerNames) -and ($_.FQDN -notin $SkipExchangeServerNames)) {
                            Write-Verbose "Adding Server $($_.Name) to the valid server list"
                            $possibleValidExchangeServer.Add($_)
                        }
                    } else {
                        Write-Verbose "Adding Server $($_.Name) to the valid server list"
                        $possibleValidExchangeServer.Add($_)
                    }
                }
        } else {
            if ($null -ne $SkipExchangeServerNames -and $SkipExchangeServerNames.Count -gt 0) {
                $getExchangeServer |
                    Where-Object { ($_.Name -notin $SkipExchangeServerNames) -and ($_.FQDN -notin $SkipExchangeServerNames) } |
                    ForEach-Object {
                        Write-Verbose "Adding Server $($_.Name) to the valid server list"
                        $possibleValidExchangeServer.Add($_)
                    }
            } else {
                Write-Verbose "Adding Server $($_.Name) to the valid server list"
                $possibleValidExchangeServer.AddRange($getExchangeServer)
            }
        }

        if ($CheckOnline -or (-not ([string]::IsNullOrEmpty($MinimumSU)))) {
            Write-Verbose "Will check to see if the servers are online"
            $serverCount = 0
            $paramWriteProgress = @{
                Activity        = "Retrieving Exchange Server Build Information"
                Status          = "Progress:"
                PercentComplete = $serverCount
            }
            Write-Progress @paramWriteProgress

            foreach ($server in $possibleValidExchangeServer) {
                $serverCount++
                $paramWriteProgress.Activity = "Processing Server: $server"
                $paramWriteProgress.PercentComplete = (($serverCount / $possibleValidExchangeServer.Count) * 100)
                Write-Progress @paramWriteProgress

                $exSetupDetails = Get-ExSetupFileVersionInfo -Server $server.FQDN

                if ($null -ne $exSetupDetails -and
                    (-not ([string]::IsNullOrEmpty($exSetupDetails)))) {
                    # Got some results back, they are online.
                    $onlineExchangeServer.Add($server)
                    $onlineExchangeServerFqdn.Add($server.FQDN)

                    if (-not ([string]::IsNullOrEmpty($MinimumSU))) {
                        $params = @{
                            CurrentExchangeBuild = (Get-ExchangeBuildVersionInformation -FileVersion $exSetupDetails.FileVersion)
                            SU                   = $MinimumSU
                        }
                        if ((Test-ExchangeBuildGreaterOrEqualThanSecurityPatch @params)) {
                            $validExchangeServer.Add($server)
                        } else {
                            Write-Verbose "Server $($server.Name) build is older than our expected min SU build. Build Number: $($exSetupDetails.FileVersion)"
                            $outdatedBuildExchangeServerFqdn.Add($server.FQDN)
                        }
                    } else {
                        $validExchangeServer.Add($server)
                    }
                } else {
                    Write-Verbose "Server $($server.Name) not online"
                    $offlineExchangeServer.Add($server)
                    $offlineExchangeServerFqdn.Add($server.FQDN)
                }
            }

            Write-Progress @paramWriteProgress -Completed
        } else {
            $validExchangeServer.AddRange($possibleValidExchangeServer)
        }

        $validExchangeServer | ForEach-Object { $validExchangeServerFqdn.Add($_.FQDN) }

        # If we have servers in the outdatedBuildExchangeServerFqdn list, the default response should be to display that we are removing them from the list.
        if ($outdatedBuildExchangeServerFqdn.Count -gt 0) {
            if ($DisplayOutdatedServers) {
                Write-Host ""
                Write-Host "Excluded the following server(s) because the build is older than what is required to make a change: $([string]::Join(", ", $outdatedBuildExchangeServerFqdn))"
                Write-Host ""
            }
        }
    }
    end {
        return [PSCustomObject]@{
            ValidExchangeServer             = $validExchangeServer
            ValidExchangeServerFqdn         = $validExchangeServerFqdn
            GetExchangeServer               = $getExchangeServer
            OnlineExchangeServer            = $onlineExchangeServer
            OnlineExchangeServerFqdn        = $onlineExchangeServerFqdn
            OfflineExchangeServer           = $offlineExchangeServer
            OfflineExchangeServerFqdn       = $offlineExchangeServerFqdn
            OutdatedBuildExchangeServerFqdn = $outdatedBuildExchangeServerFqdn
        }
    }
}
