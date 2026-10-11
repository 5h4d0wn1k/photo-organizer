$ErrorActionPreference = 'Stop'

$buildDirectory = Join-Path 'target' 'debug/build'
if (-not (Test-Path -LiteralPath $buildDirectory -PathType Container)) {
    throw "Cargo build directory is missing: $buildDirectory"
}

$candidatePdbs = @(
    foreach ($build in Get-ChildItem -LiteralPath $buildDirectory -Directory -Filter 'openssl-sys-*') {
        $outputFile = Join-Path $build.FullName 'output'
        if (-not (Test-Path -LiteralPath $outputFile -PathType Leaf)) {
            continue
        }

        $output = Get-Content -LiteralPath $outputFile -Raw
        foreach ($match in [regex]::Matches($output, '(?m)^cargo:root=(.+)\r?$')) {
            $installRoot = $match.Groups[1].Value.Trim()
            $pdb = Join-Path $installRoot 'lib/ossl_static.pdb'
            if (Test-Path -LiteralPath $pdb -PathType Leaf) {
                (Resolve-Path -LiteralPath $pdb).Path
            }
        }
    }
) | Sort-Object -Unique
$candidatePdbs = @($candidatePdbs)

if ($candidatePdbs.Count -ne 1) {
    throw "Expected one built OpenSSL symbol file, found $($candidatePdbs.Count). Refusing to stage an ambiguous or missing PDB."
}

$destinationDirectory = [System.IO.Path]::GetFullPath((Join-Path 'target' 'debug/deps'))
if (-not (Test-Path -LiteralPath $destinationDirectory -PathType Container)) {
    throw "Cargo dependency link directory is missing: $destinationDirectory"
}

$destination = Join-Path $destinationDirectory 'ossl_static.pdb'
$sourcePdb = [System.IO.Path]::GetFullPath([string]$candidatePdbs[0])
[System.IO.File]::Copy($sourcePdb, $destination, $true)

$sourceHash = (Get-FileHash -LiteralPath $sourcePdb -Algorithm SHA256).Hash
$destinationHash = (Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash
if ($sourceHash -ne $destinationHash) {
    throw 'The staged OpenSSL symbol file does not match the PDB produced by the vendored build.'
}

Write-Host "Staged the vendored OpenSSL PDB for strict MSVC linking: $destination"
