[CmdletBinding()]
param(
    [ValidateRange(1, 2147483647)]
    [int]$Count = 5000,

    [ValidateRange(1, 2147483647)]
    [int]$MinRequestsPerSecond = 10,

    [ValidateRange(1, 2147483647)]
    [int]$MaxRequestsPerSecond = 20,

    [ValidateRange(1, 2147483647)]
    [int]$Concurrency = 2,

    [ValidateRange(1, 65535)]
    [int]$Port = 5001
)

if ($MinRequestsPerSecond -gt $MaxRequestsPerSecond) {
    throw "MinRequestsPerSecond must not exceed MaxRequestsPerSecond."
}

Add-Type -AssemblyName System.Net.Http
$client = [System.Net.Http.HttpClient]::new()
$client.Timeout = [TimeSpan]::FromSeconds(5)
$pending = [System.Collections.Generic.List[object]]::new()
$paths = @('/otel-test', '/orders', '/products', '/checkout')
$failedRequests = 0
$sentRequests = 0
$nextRequestMilliseconds = 0
$timer = [System.Diagnostics.Stopwatch]::StartNew()

Write-Host "Sending $Count requests at approximately $MinRequestsPerSecond-$MaxRequestsPerSecond requests/s, with up to $Concurrency in flight."

try {
    while ($sentRequests -lt $Count -or $pending.Count -gt 0) {
        for ($index = $pending.Count - 1; $index -ge 0; $index--) {
            $request = $pending[$index]
            if (-not $request.Task.IsCompleted) {
                continue
            }

            $response = $null
            try {
                $response = $request.Task.GetAwaiter().GetResult()
                $null = $response.EnsureSuccessStatusCode()
                Write-Host "Request $($request.Number) $($request.Path) : HTTP $([int]$response.StatusCode)"
            }
            catch {
                $failedRequests++
                Write-Warning "Request $($request.Number) $($request.Path) failed: $($_.Exception.Message)"
            }
            finally {
                if ($null -ne $response) {
                    $response.Dispose()
                }
                $request.Task.Dispose()
                $pending.RemoveAt($index)
            }
        }

        if ($sentRequests -lt $Count -and $pending.Count -lt $Concurrency -and
            $timer.Elapsed.TotalMilliseconds -ge $nextRequestMilliseconds) {
            $sentRequests++
            $path = Get-Random -InputObject $paths
            $item = Get-Random -Minimum 1 -Maximum 1001
            $url = "http://127.0.0.1:${Port}${path}?request=$sentRequests&item=$item"
            $pending.Add([pscustomobject]@{
                Number = $sentRequests
                Path = $path
                Task = $client.GetAsync($url)
            })

            # Pace all requests together, not each concurrent worker separately.
            $rate = Get-Random -Minimum $MinRequestsPerSecond -Maximum ($MaxRequestsPerSecond + 1)
            $intervalMilliseconds = 1000.0 / $rate
            $nextRequestMilliseconds += $intervalMilliseconds
            if ($nextRequestMilliseconds -le $timer.Elapsed.TotalMilliseconds) {
                $nextRequestMilliseconds = $timer.Elapsed.TotalMilliseconds + $intervalMilliseconds
            }
        }

        if ($sentRequests -lt $Count -or $pending.Count -gt 0) {
            Start-Sleep -Milliseconds 1
        }
    }
}
finally {
    $timer.Stop()
    $client.Dispose()
}

Write-Host "Completed: $($Count - $failedRequests) successful, $failedRequests failed."
Write-Host ("Elapsed: {0:N2}s; average: {1:N2} requests/s." -f
    $timer.Elapsed.TotalSeconds, ($Count / $timer.Elapsed.TotalSeconds))
if ($failedRequests -gt 0) {
    exit 1
}
