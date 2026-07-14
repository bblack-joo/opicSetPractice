$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Speech

function Send-Response {
    param(
        [System.IO.Stream]$Stream,
        [int]$StatusCode,
        [string]$StatusText,
        [string]$ContentType,
        [byte[]]$Body
    )
    $header = "HTTP/1.1 $StatusCode $StatusText`r`n" +
              "Content-Type: $ContentType`r`n" +
              "Content-Length: $($Body.Length)`r`n" +
              "Access-Control-Allow-Origin: *`r`n" +
              "Access-Control-Allow-Methods: GET, POST, OPTIONS`r`n" +
              "Access-Control-Allow-Headers: Content-Type`r`n" +
              "Cache-Control: no-store`r`n" +
              "Connection: close`r`n`r`n"
    $headerBytes = [System.Text.Encoding]::ASCII.GetBytes($header)
    $Stream.Write($headerBytes, 0, $headerBytes.Length)
    if ($Body.Length -gt 0) {
        $Stream.Write($Body, 0, $Body.Length)
    }
    $Stream.Flush()
}

$htmlPath = Join-Path $PSScriptRoot 'OPIc_실제시험모드.html'
$listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 8765)

try {
    $listener.Start()
} catch {
    exit 0
}

while ($true) {
    $client = $null
    try {
        $client = $listener.AcceptTcpClient()
        $stream = $client.GetStream()
        $headerBuffer = [System.Collections.Generic.List[byte]]::new()
        $lastFour = [System.Collections.Generic.Queue[byte]]::new()
        while ($true) {
            $nextByte = $stream.ReadByte()
            if ($nextByte -lt 0) { break }
            $headerBuffer.Add([byte]$nextByte)
            $lastFour.Enqueue([byte]$nextByte)
            if ($lastFour.Count -gt 4) { [void]$lastFour.Dequeue() }
            if ($lastFour.Count -eq 4) {
                $tail = $lastFour.ToArray()
                if ($tail[0] -eq 13 -and $tail[1] -eq 10 -and $tail[2] -eq 13 -and $tail[3] -eq 10) { break }
            }
        }
        $headerText = [System.Text.Encoding]::ASCII.GetString($headerBuffer.ToArray())
        $headerLines = $headerText -split "`r`n"
        $requestLine = $headerLines[0]
        if ([string]::IsNullOrWhiteSpace($requestLine)) {
            $client.Close()
            continue
        }

        $parts = $requestLine.Split(' ')
        $method = $parts[0]
        $path = $parts[1].Split('?')[0]
        $headers = @{}
        foreach ($line in $headerLines[1..([Math]::Max(1, $headerLines.Length - 1))]) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            $colon = $line.IndexOf(':')
            if ($colon -gt 0) {
                $headers[$line.Substring(0, $colon).Trim().ToLowerInvariant()] = $line.Substring($colon + 1).Trim()
            }
        }

        if ($method -eq 'OPTIONS') {
            Send-Response $stream 204 'No Content' 'text/plain' ([byte[]]::new(0))
            $client.Close()
            continue
        }

        if ($path -eq '/tts' -and $method -eq 'POST') {
            $length = 0
            if ($headers.ContainsKey('content-length')) {
                $length = [int]$headers['content-length']
            }
            $bodyBytes = [byte[]]::new($length)
            $read = 0
            while ($read -lt $length) {
                $count = $stream.Read($bodyBytes, $read, $length - $read)
                if ($count -le 0) { break }
                $read += $count
            }
            $text = [System.Text.Encoding]::UTF8.GetString($bodyBytes, 0, $read)

            if ([string]::IsNullOrWhiteSpace($text)) {
                Send-Response $stream 400 'Bad Request' 'text/plain; charset=utf-8' ([System.Text.Encoding]::UTF8.GetBytes('No text'))
                $client.Close()
                continue
            }

            $wave = [System.IO.MemoryStream]::new()
            $speaker = [System.Speech.Synthesis.SpeechSynthesizer]::new()
            $englishVoices = $speaker.GetInstalledVoices() | Where-Object { $_.Enabled -and $_.VoiceInfo.Culture.Name -like 'en-*' }
            foreach ($englishVoice in $englishVoices) {
                try {
                    $speaker.SelectVoice($englishVoice.VoiceInfo.Name)
                    break
                } catch {}
            }
            $speaker.Rate = -1
            $speaker.Volume = 100
            $speaker.SetOutputToWaveStream($wave)
            $speaker.Speak($text)
            $speaker.SetOutputToNull()
            $speaker.Dispose()
            $audio = $wave.ToArray()
            $wave.Dispose()
            Send-Response $stream 200 'OK' 'audio/wav' $audio
            $client.Close()
            continue
        }

        if ($path -eq '/' -or $path -eq '/OPIc_실제시험모드.html') {
            Send-Response $stream 200 'OK' 'text/html; charset=utf-8' ([System.IO.File]::ReadAllBytes($htmlPath))
            $client.Close()
            continue
        }

        Send-Response $stream 404 'Not Found' 'text/plain; charset=utf-8' ([System.Text.Encoding]::UTF8.GetBytes('Not found'))
        $client.Close()
    } catch {
        if ($client) {
            try { $client.Close() } catch {}
        }
    }
}
