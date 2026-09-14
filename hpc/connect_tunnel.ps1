<#
Finds the running llama-server/OmniVoice/whisper-fastapi SLURM job and opens
SSH tunnels so http://localhost:<LocalLlmPort/LocalTtsPort/LocalSttPort> each
reach the job's compute node. Leave this running while TalkWithMe is in use;
Ctrl+C stops the tunnels.

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
$sttPort = Get-InfoValue $info "stt_port"

if (-not $NodeHost) {
    $NodeHost = $discoveredNodeHost
}

if (-not $NodeHost -or -not $llmPort -or -not $ttsPort -or -not $sttPort) {
    Write-Error "Could not parse job info:`n$info"
    exit 1
}

Write-Host "Tunneling via $User@$LoginHost -> $NodeHost :"
Write-Host "  localhost:$LocalLlmPort -> LLM  ${NodeHost}:${llmPort}"
Write-Host "  localhost:$LocalTtsPort -> TTS  ${NodeHost}:${ttsPort}"
Write-Host "  localhost:$LocalSttPort -> STT  ${NodeHost}:${sttPort}"
Write-Host "Leave this window open while TalkWithMe is running. Ctrl+C to stop."
& $Plink -ssh -batch -i $KeyFile -N `
    -L "${LocalLlmPort}:${NodeHost}:${llmPort}" `
    -L "${LocalTtsPort}:${NodeHost}:${ttsPort}" `
    -L "${LocalSttPort}:${NodeHost}:${sttPort}" `
    "$User@$LoginHost"

