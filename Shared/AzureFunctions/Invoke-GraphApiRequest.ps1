﻿# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.

. $PSScriptRoot\..\ScriptUpdateFunctions\Invoke-WebRequestWithProxyDetection.ps1

function Invoke-GraphApiRequest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Query,

        [ValidateSet("v1.0", "beta")]
        [Parameter(Mandatory = $false)]
        [string]$Endpoint = "v1.0",

        [Parameter(Mandatory = $false)]
        [string]$Method = "GET",

        [Parameter(Mandatory = $false)]
        [string]$ContentType = "application/json",

        [Parameter(Mandatory = $false)]
        $Body,

        [Parameter(Mandatory = $true)]
        [ValidatePattern("^([a-zA-Z0-9_=]+)\.([a-zA-Z0-9_=]+)\.([a-zA-Z0-9_\-\+\/=]*)")]
        [string]$AccessToken,

        [Parameter(Mandatory = $false)]
        [int]$ExpectedStatusCode = 200,

        [Parameter(Mandatory = $false)]
        [int]$MaxRetryAttempts = 3,

        [Parameter(Mandatory = $true)]
        [string]$GraphApiUrl
    )

    <#
        This shared function is used to make requests to the Microsoft Graph API.
        It returns a PSCustomObject with the following properties:
            Content: The content of the response (converted from JSON to a PSCustomObject)
            Response: The full response object
            StatusCode: The status code of the response
            Successful: A boolean indicating whether the request was successful
    #>

    begin {
        Write-Verbose "Calling $($MyInvocation.MyCommand)"
        $retryIndex = 0
        $retryAfterSeconds = 0
        $successful = $false
        $content = $null
    }
    process {
        $graphApiRequestParams = @{
            Uri             = "$GraphApiUrl/$Endpoint/$($Query.TrimStart("/"))"
            Header          = @{ Authorization = "Bearer $AccessToken" }
            Method          = $Method
            ContentType     = $ContentType
            UseBasicParsing = $true
            ErrorAction     = "Stop"
        }

        if ($null -ne $Body) {
            Write-Verbose "Body: $Body"
            $graphApiRequestParams.Add("Body", $Body)
        }

        Write-Verbose "Graph API uri called: $($graphApiRequestParams.Uri)"
        Write-Verbose "Method: $($graphApiRequestParams.Method) ContentType: $($graphApiRequestParams.ContentType)"

        do {
            $retryIndex++

            if ($retryIndex -gt $MaxRetryAttempts) {
                Write-Verbose "Reached maximum retry attempts"

                break
            }

            Write-Verbose "Graph API request attempts $retryIndex of $MaxRetryAttempts"

            if ($retryAfterSeconds -ne 0) {
                Write-Verbose "Waiting for $retryAfterSeconds seconds before trying to run Graph API call again"

                # Wait as long as specified in the Retry-After header that was returned and reset retryAfterSeconds afterwards
                Start-Sleep -Seconds $retryAfterSeconds
                $retryAfterSeconds = 0
            }

            $graphApiResponse = Invoke-WebRequestWithProxyDetection -ParametersObject $graphApiRequestParams

            if ($null -eq $graphApiResponse -or
                [System.String]::IsNullOrEmpty($graphApiResponse.StatusCode)) {
                Write-Verbose "Graph API request failed - no response"

                break
            }

            # We return HTTP 429 together with the Retry-After header in case that a Graph API call gets throttled
            # https://learn.microsoft.com/graph/throttling#best-practices-to-handle-throttling
            if ($graphApiResponse.StatusCode -eq 429) {
                $retryAfterSeconds = $graphApiResponse.Headers["Retry-After"]
                Write-Verbose "Graph API throttling threshold exceeded - retry again after $retryAfterSeconds seconds"

                continue
            }

            if ($graphApiResponse.StatusCode -ne $ExpectedStatusCode) {
                Write-Verbose "Graph API status code: $($graphApiResponse.StatusCode) doesn't match the expected status code: $ExpectedStatusCode"

                break
            }

            Write-Verbose "Graph API request successful"

            $successful = $true
            $content = $graphApiResponse.Content | ConvertFrom-Json
        } while ($successful -eq $false)
    }
    end {
        return [PSCustomObject]@{
            Content    = $content
            Response   = $graphApiResponse
            StatusCode = $graphApiResponse.StatusCode
            Successful = $successful
        }
    }
}
