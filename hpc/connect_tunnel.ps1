<#
Finds the running llama-server/TTS-engines/whisper-fastapi SLURM job and opens
SSH tunnels so http://localhost:<LocalLlmPort>/<TTS engine ports>/<LocalSttPort>
each reach the job's compute node. Leave this running while TalkWithMe is in
use; Ctrl+C stops the tunnels.

Every TTS engine tts-serve supports runs as its own server on its own port
(see hpc/start_all_tts_engines.sh); this script tunnels every port that
script reported as actually started (read from ~/.tts_engines_info via the
`tts_ports=` line in ~/.llama_server_info), so switching engines in
TalkWithMe's "TTS Model" dropdown needs no re-tunneling. Older info files
that only have a single `tts_port=` line (from before multi-engine support)
still work — that one port is tunneled as before.

Uses PuTTY's plink (not the OpenSSH client), since the private key is a
.ppk file. Requires PuTTY installed (plink.exe); if it isn't on PATH, pass
-Plink with a full path, e.g. "C:\Program Files\PuTTY\plink.exe".

First-time use: run `plink -ssh -i <KeyFile> ccollard@jarvis.stevens.edu` once
by hand and accept the host key prompt, so later -batch calls don't hang.

Usage: .\connect_tunnel.ps1
Specify the compute node positionally: .\connect_tunnel.ps1 g013
Or explicitly: .\connect_tunnel.ps1 -NodeHost gpu-node-01
#>
param(
    [string]$NodeHost = "",
    [string]$LoginHost = "jarvis.stevens.edu",
    [string]$User = "ccollard",
    [string]$KeyFile = "C:\OneDrive\Documents\private-key-for-putty.ppk",
    [int]$LocalLlmPort = 9090,
    [int]$LocalTtsPort = 8181,
    [int]$LocalSttPort = 5000,
    [string]$Plink = "plink"
)

$ErrorActionPreference = "Stop"

Write-Host "Looking up job info on $LoginHost..."
$info = & $Plink -ssh -batch -i $KeyFile "$User@$LoginHost" "cat ~/.llama_server_info" 2>$null

if (-not $info) {
    Write-Error "No job info found. Is the job running? Check with: plink -ssh -i `"$KeyFile`" $User@$LoginHost squeue -u $User"
    exit 1
}

function Get-InfoValue($text, $key) {
    return (($text -split "`n" | Where-Object { $_ -match "^$key=" }) -replace "^$key=", "")
}

$discoveredNodeHost = Get-InfoValue $info "host"
$llmPort = Get-InfoValue $info "llm_port"
$ttsPort = Get-InfoValue $info "tts_port"
$ttsPortsRaw = Get-InfoValue $info "tts_ports"
$sttPort = Get-InfoValue $info "stt_port"

if (-not $NodeHost) {
    $NodeHost = $discoveredNodeHost
}

if (-not $NodeHost -or -not $llmPort -or -not $sttPort) {
    Write-Error "Could not parse job info:`n$info"
    exit 1
}

# Every port a TTS engine actually started on (multi-engine support). Falls
# back to the single tts_port for an info file written before that feature
# existed, or when nothing parsed out of tts_ports.
$ttsPorts = @($ttsPortsRaw -split "," | Where-Object { $_ -match '^\d+$' })
if ($ttsPorts.Count -eq 0 -and $ttsPort) {
    $ttsPorts = @($ttsPort)
}
if ($ttsPorts.Count -eq 0) {
    Write-Error "Could not parse job info:`n$info"
    exit 1
}

Write-Host "Tunneling via $User@$LoginHost -> $NodeHost :"
Write-Host "  localhost:$LocalLlmPort -> LLM  ${NodeHost}:${llmPort}"
foreach ($port in $ttsPorts) {
    $localPort = if ($port -eq $ttsPort) { $LocalTtsPort } else { $port }
    Write-Host "  localhost:$localPort -> TTS  ${NodeHost}:${port}"
}
Write-Host "  localhost:$LocalSttPort -> STT  ${NodeHost}:${sttPort}"
Write-Host "Leave this window open while TalkWithMe is running. Ctrl+C to stop."

$forwards = @("-L", "${LocalLlmPort}:${NodeHost}:${llmPort}")
foreach ($port in $ttsPorts) {
    $localPort = if ($port -eq $ttsPort) { $LocalTtsPort } else { $port }
    $forwards += @("-L", "${localPort}:${NodeHost}:${port}")
}
$forwards += @("-L", "${LocalSttPort}:${NodeHost}:${sttPort}")

& $Plink -ssh -batch -i $KeyFile -N @forwards "$User@$LoginHost"

