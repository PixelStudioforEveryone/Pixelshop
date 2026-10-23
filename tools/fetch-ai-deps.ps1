# Fetch the AI mask dependencies.
#
# Why this is a separate script: the DSH file sandbox refuses to hand TLS
# credentials to child processes, so every HTTPS download from an agent shell
# fails with `SEC_E_NO_CREDENTIALS` / "The SSL connection could not be
# established" even though TCP 443 is reachable. Run this from a normal
# developer shell (no sandbox) and it will fetch, verify and report everything.
#
#   pwsh -File tools/fetch-ai-deps.ps1
#
# It only downloads public upstream artifacts. Nothing here is uploaded.
[CmdletBinding()]
param(
  [switch]$SkipNcnn
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$root = Split-Path -Parent $PSScriptRoot

$ncnnDir = Join-Path $root 'tmp/ai-mask-deps'
$ncnnZip = Join-Path $ncnnDir 'ncnn-20260526-harmonyos.zip'
$ncnnOut = Join-Path $root 'entry/src/main/cpp/third_party/ncnn'
$maskDir = Join-Path $root 'entry/src/main/resources/rawfile/ai_masks'
$onnxDir = Join-Path $root 'tmp/ai-mask-deps'

foreach ($d in @($ncnnDir, $ncnnOut, $maskDir, $onnxDir)) {
  New-Item -ItemType Directory -Force -Path $d | Out-Null
}

# name -> @{ url; dest; md5 (optional, expected) }
$artifacts = @(
  @{
    Name = 'ncnn-20260526-harmonyos.zip'
    Url  = 'https://github.com/Tencent/ncnn/releases/download/20260526/ncnn-20260526-harmonyos.zip'
    Dest = $ncnnZip
    Note = 'Tencent ncnn 20260526 HarmonyOS prebuilt (arm64-v8a + x86_64 static)'
  },
  @{
    Name = 'skysegsmall_sim-opt-fp16.param'
    Url  = 'https://raw.githubusercontent.com/xiongzhu666/Sky-Segmentation-and-Post-processing/main/skysegsmall_sim-opt-fp16.param'
    Dest = Join-Path $maskDir 'skysegsmall_sim-opt-fp16.param'
    Note = 'Sky segmentation ncnn param, 384x384, input.1 -> 1959'
  },
  @{
    Name = 'skysegsmall_sim-opt-fp16.bin'
    Url  = 'https://raw.githubusercontent.com/xiongzhu666/Sky-Segmentation-and-Post-processing/main/skysegsmall_sim-opt-fp16.bin'
    Dest = Join-Path $maskDir 'skysegsmall_sim-opt-fp16.bin'
    Note = 'Sky segmentation ncnn weights'
  },
  @{
    Name = 'u2netp.onnx'
    Url  = 'https://github.com/danielgatis/rembg/releases/download/v0.0.0/u2netp.onnx'
    Dest = Join-Path $onnxDir 'u2netp.onnx'
    Md5  = '8e83ca70e441ab06c318d82300c84806'
    Note = 'U^2-NetP salient object detection, 320x320, rembg official release'
  },
  @{
    Name = 'ncnn-LICENSE.txt'
    Url  = 'https://raw.githubusercontent.com/Tencent/ncnn/master/LICENSE.txt'
    Dest = Join-Path $root 'entry/src/main/cpp/third_party/ncnn-LICENSE.txt'
    Note = 'ncnn licence (expected BSD-3-Clause)'
  },
  @{
    Name = 'u2net-LICENSE.txt'
    Url  = 'https://raw.githubusercontent.com/xuebinqin/U-2-Net/master/LICENSE'
    Dest = Join-Path $root 'entry/src/main/cpp/third_party/u2net-LICENSE.txt'
    Note = 'U^2-Net licence (expected Apache-2.0)'
  },
  @{
    Name = 'skysegmentation-LICENSE.txt'
    Url  = 'https://raw.githubusercontent.com/xiongzhu666/Sky-Segmentation-and-Post-processing/main/LICENSE'
    Dest = Join-Path $root 'entry/src/main/cpp/third_party/skysegmentation-LICENSE.txt'
    Note = 'Sky-Segmentation licence (expected MIT)'
  }
)

$manifest = @()
foreach ($a in $artifacts) {
  if ($SkipNcnn -and $a.Name -eq 'ncnn-20260526-harmonyos.zip') { continue }
  Write-Host ("fetch {0}" -f $a.Url)
  $ok = $true
  $errorText = ''
  try {
    Invoke-WebRequest -Uri $a.Url -OutFile $a.Dest -MaximumRedirection 5 -TimeoutSec 300
  } catch {
    $ok = $false
    $errorText = $_.Exception.Message
  }
  $entry = [ordered]@{
    name = $a.Name
    url  = $a.Url
    dest = $a.Dest
    note = $a.Note
    ok   = $ok
  }
  if ($ok) {
    $entry.bytes = (Get-Item $a.Dest).Length
    $entry.sha256 = (Get-FileHash -Algorithm SHA256 -Path $a.Dest).Hash.ToLower()
    if ($a.Md5) {
      $actual = (Get-FileHash -Algorithm MD5 -Path $a.Dest).Hash.ToLower()
      $entry.md5 = $actual
      $entry.md5Expected = $a.Md5
      $entry.md5Match = ($actual -eq $a.Md5)
    }
    Write-Host ("  ok {0} bytes sha256={1}" -f $entry.bytes, $entry.sha256)
  } else {
    $entry.error = $errorText
    Write-Warning ("  FAILED: {0}" -f $errorText)
  }
  $manifest += (New-Object psobject -Property $entry)
}

if (-not $SkipNcnn -and (Test-Path $ncnnZip)) {
  Write-Host 'extracting ncnn archive'
  $tmp = Join-Path $ncnnDir 'extract'
  if (Test-Path $tmp) { Remove-Item -Recurse -Force $tmp }
  Expand-Archive -Path $ncnnZip -DestinationPath $tmp -Force
  # The release contains a top-level version folder; flatten it into third_party/ncnn.
  $inner = Get-ChildItem -Path $tmp -Directory | Select-Object -First 1
  $source = if ($inner) { $inner.FullName } else { $tmp }
  Copy-Item -Recurse -Force -Path (Join-Path $source '*') -Destination $ncnnOut
  Write-Host ("extracted to {0}" -f $ncnnOut)
}

$manifestPath = Join-Path $root 'tmp/ai-mask-deps/manifest.json'
$manifest | ConvertTo-Json -Depth 4 | Set-Content -Encoding UTF8 -Path $manifestPath
Write-Host ("manifest written to {0}" -f $manifestPath)
