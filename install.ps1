<#
.SYNOPSIS
  AIStrap 2.0 for Windows - one command to set up a modern AI/ML workstation.

.DESCRIPTION
  Native mode (default): installs Git, uv, Ollama (and optionally VS Code / Claude Code),
  detects your GPU, picks the newest PyTorch build your driver supports (CUDA / XPU / CPU)
  and builds isolated Python environments with the full AI stack.

  -WSL mode: enables WSL2, installs Ubuntu, and runs the Linux installer inside it.
  This is the best option for vLLM, JAX on GPU and TensorFlow on GPU, which are Linux-only.

.EXAMPLE
  irm https://raw.githubusercontent.com/brandonjabr/aistrap/master/install.ps1 | iex

.EXAMPLE
  & ([scriptblock]::Create((irm https://raw.githubusercontent.com/brandonjabr/aistrap/master/install.ps1))) -Profile full -Yes

.EXAMPLE
  .\install.ps1 -WSL            # set up Ubuntu in WSL2 and run the Linux installer there
#>
[CmdletBinding()]
param(
  [Alias('Profile')][ValidateSet('minimal', 'standard', 'full')][string]$SetupProfile = 'standard',
  [string]$Python = '3.12',
  [string]$Backend = '',
  [string]$InstallDir = (Join-Path $env:USERPROFILE '.aistrap'),
  [switch]$Yes,
  [switch]$DryRun,
  [switch]$NoOllama,
  [switch]$Jax,
  [switch]$TensorFlow,
  [switch]$ClaudeCode,
  [switch]$VSCode,
  [switch]$NoShellConfig,
  [switch]$WSL,
  [string]$Distro = 'Ubuntu-24.04'
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'   # makes Invoke-WebRequest much faster on PS 5.1
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$AistrapVersion = '2.0.0'
$RepoRaw = if ($env:AISTRAP_REPO_RAW) { $env:AISTRAP_REPO_RAW } else { 'https://raw.githubusercontent.com/brandonjabr/aistrap/master' }
$AistrapHome = $InstallDir
$script:Warnings = New-Object System.Collections.Generic.List[string]
$script:Installed = New-Object System.Collections.Generic.List[string]
$script:StepN = 0

function Info($m) { Write-Host "==> $m" -ForegroundColor Cyan }
function Ok($m) { Write-Host " ok $m" -ForegroundColor Green }
function Warn($m) { Write-Host " !! $m" -ForegroundColor Yellow; $script:Warnings.Add($m) }
function Step($m) { $script:StepN++; Write-Host "`n[$script:StepN] $m" -ForegroundColor Cyan }
function Have($cmd) { [bool](Get-Command $cmd -ErrorAction SilentlyContinue) }
function Refresh-Path {
  $machine = [Environment]::GetEnvironmentVariable('Path', 'Machine')
  $user = [Environment]::GetEnvironmentVariable('Path', 'User')
  $env:Path = "$machine;$user;$env:USERPROFILE\.local\bin"
}
function Run([string]$Display, [scriptblock]$Block) {
  if ($DryRun) { Write-Host "   [dry-run] $Display" -ForegroundColor DarkGray; return $true }
  Write-Host "   > $Display" -ForegroundColor DarkGray
  $global:LASTEXITCODE = 0
  & $Block
  return ($LASTEXITCODE -eq 0 -or $null -eq $LASTEXITCODE)
}

# --------------------------------------------------------------------------- WSL mode
function Invoke-WslSetup {
  Step "WSL2 + $Distro"
  $wslOk = $false
  try { wsl.exe --status *> $null; $wslOk = ($LASTEXITCODE -eq 0) } catch { $wslOk = $false }
  if (-not $wslOk) {
    Info 'WSL is not enabled yet. Enabling it needs administrator rights and a reboot.'
    if (-not $DryRun) {
      Start-Process wsl.exe -ArgumentList '--install', '--no-distribution' -Verb RunAs -Wait
    }
    Write-Host "`nReboot Windows, then run this script again with -WSL to continue." -ForegroundColor Yellow
    return
  }
  $distros = (wsl.exe -l -q) -replace "`0", '' | Where-Object { $_.Trim() }
  if (-not ($distros -contains $Distro)) {
    Info "Installing $Distro. When it opens, create your Linux username and password, then type 'exit'."
    Run "wsl --install -d $Distro" { wsl.exe --install -d $Distro | Out-Host } | Out-Null
  }
  $flags = "--profile $SetupProfile --python $Python"
  if ($Yes) { $flags += ' --yes' }
  if ($DryRun) { $flags += ' --dry-run' }
  if ($Jax) { $flags += ' --jax' }
  if ($TensorFlow) { $flags += ' --tensorflow' }
  if ($ClaudeCode) { $flags += ' --claude-code' }
  if ($NoOllama) { $flags += ' --no-ollama' }
  if ($Backend) { $flags += " --backend $Backend" }
  Info "Running the Linux installer inside $Distro (you may be asked for your Linux password)."
  wsl.exe -d $Distro -- bash -lc "curl -fsSL $RepoRaw/install.sh | bash -s -- $flags"
  Write-Host "`nDone. Open '$Distro' from the Start menu (or run: wsl -d $Distro) and type 'ai' to start." -ForegroundColor Green
  Write-Host "Tip: in VS Code install the 'WSL' extension and run 'code .' inside WSL." -ForegroundColor DarkGray
}

# --------------------------------------------------------------------------- detection
function Get-GpuInfo {
  $gpu = [ordered]@{ Vendor = 'none'; Name = 'none detected'; DriverCuda = ''; Driver = ''; CC = '' }
  if ($env:AISTRAP_SIMULATE_GPU) {
    $parts = $env:AISTRAP_SIMULATE_GPU.Split(':')
    $gpu.Vendor = $parts[0]; $gpu.Name = "(simulated $($parts[0]))"
    if ($parts.Count -gt 1) { $gpu.DriverCuda = $parts[1] }
    if ($parts.Count -gt 2) { $gpu.CC = $parts[2] }
    return $gpu
  }
  $controllers = @(Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue)
  $smi = Get-Command nvidia-smi -ErrorAction SilentlyContinue
  if ($smi) {
    $out = (& $smi.Source 2>$null) -join "`n"
    if ($out -match 'CUDA Version:\s*([0-9]+\.[0-9]+)') { $gpu.DriverCuda = $Matches[1] }
    if ($out -match 'Driver Version:\s*([0-9.]+)') { $gpu.Driver = $Matches[1] }
    $name = (& $smi.Source --query-gpu=name --format=csv,noheader 2>$null | Select-Object -First 1)
    $cc = (& $smi.Source --query-gpu=compute_cap --format=csv,noheader 2>$null | Select-Object -First 1)
    if ($cc -match '^\s*([0-9]+\.[0-9]+)') { $gpu.CC = $Matches[1] }
    if ($name) { $gpu.Vendor = 'nvidia'; $gpu.Name = $name.Trim(); return $gpu }
  }
  $nv = $controllers | Where-Object { $_.Name -match 'NVIDIA' } | Select-Object -First 1
  $amd = $controllers | Where-Object { $_.Name -match 'AMD|Radeon' } | Select-Object -First 1
  $arc = $controllers | Where-Object { $_.Name -match 'Intel.*Arc' } | Select-Object -First 1
  if ($nv) { $gpu.Vendor = 'nvidia'; $gpu.Name = $nv.Name }
  elseif ($amd) { $gpu.Vendor = 'amd'; $gpu.Name = $amd.Name }
  elseif ($arc) { $gpu.Vendor = 'intel'; $gpu.Name = $arc.Name }
  return $gpu
}

function Get-LatestTorch([string]$Tag, [string]$Cp, [string]$Plat) {
  try {
    $html = (Invoke-WebRequest -UseBasicParsing -TimeoutSec 25 "https://download.pytorch.org/whl/$Tag/torch/").Content
  } catch { return $null }
  $re = "torch-([0-9]+\.[0-9]+\.[0-9]+)(%2B|\+)$([regex]::Escape($Tag))-$Cp-$Cp-$Plat"
  $vers = [regex]::Matches($html, $re) | ForEach-Object { [version]$_.Groups[1].Value } | Sort-Object -Unique
  if ($vers) { return ($vers | Select-Object -Last 1).ToString() }
  return $null
}

function Select-Backend($gpu) {
  $cp = 'cp' + $Python.Replace('.', '')
  $plat = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'win_arm64' } else { 'win_amd64' }
  if ($Backend) {
    $url = if ($Backend -in @('pypi', 'default')) { '' } else { "https://download.pytorch.org/whl/$Backend" }
    return @{ Tag = $Backend; Url = $url; Version = '' }
  }
  $cands = @()
  switch ($gpu.Vendor) {
    'nvidia' {
      $cap = if ($gpu.DriverCuda) { [version]$gpu.DriverCuda } else { Warn 'NVIDIA driver not found; assuming CUDA 13.0 support. Install the latest driver from the NVIDIA App.'; [version]'13.0' }
      $floor = [version]'0.0'
      if ($gpu.CC) {
        # Blackwell needs CUDA 12.8+ builds; CUDA 13 dropped GPUs older than Turing (sm_75).
        if ([version]$gpu.CC -ge [version]'10.0') { $floor = [version]'12.8' }
        if ([version]$gpu.CC -lt [version]'7.5' -and $cap -gt [version]'12.6') { $cap = [version]'12.6' }
      }
      foreach ($maj in 14, 13, 12) { foreach ($min in 9..0) {
          if ($maj -eq 12 -and $min -lt 6) { continue }
          $v = [version]"$maj.$min"
          if ($v -le $cap -and $v -ge $floor) { $cands += "cu$maj$min" }
        } }
      if (-not $cands) {
        if ($floor -gt $cap) { Warn "This GPU needs a driver with CUDA 12.8+ (570 or newer). Update the driver, then run: aistrap update" }
        else { Warn 'Your NVIDIA driver is old; using an older PyTorch build. Update the driver for current releases.'; $cands = @('cu124', 'cu121', 'cu118') }
      }
      Info "Finding the newest PyTorch build for this GPU (driver CUDA $($gpu.DriverCuda), compute $($gpu.CC))..."
    }
    'intel' { $cands = @('xpu') }
    'amd' { Warn 'AMD GPUs: PyTorch on native Windows is CPU-only here. For ROCm use Linux (or try -WSL on supported Radeon cards).'; $cands = @('cpu') }
    default { $cands = @('cpu') }
  }
  $best = $null; $bestV = [version]'0.0.0'
  foreach ($t in $cands) {
    $v = Get-LatestTorch $t $cp $plat
    if (-not $v) { continue }
    Write-Host "   $($t.PadRight(9)) -> torch $v" -ForegroundColor DarkGray
    if ([version]$v -gt $bestV) { $bestV = [version]$v; $best = $t }
  }
  if (-not $best) {
    Warn 'Could not reach download.pytorch.org; using the default PyPI (CPU) wheel.'
    return @{ Tag = 'pypi'; Url = ''; Version = '' }
  }
  return @{ Tag = $best; Url = "https://download.pytorch.org/whl/$best"; Version = $bestV.ToString() }
}

function Get-Accel([string]$tag) {
  if ($tag -like 'cu*') { 'cuda' } elseif ($tag -like 'rocm*') { 'rocm' } elseif ($tag -eq 'xpu') { 'xpu' } else { 'cpu' }
}

# --------------------------------------------------------------------------- package sets (keep in sync with install.sh)
$PkgsCore = 'numpy scipy pandas polars pyarrow scikit-learn matplotlib seaborn plotly jupyterlab ipykernel ipywidgets tqdm rich'
$PkgsStandard = 'transformers datasets accelerate peft trl diffusers safetensors tokenizers sentence-transformers evaluate timm einops huggingface_hub[cli] xgboost lightgbm onnx onnxruntime opencv-python-headless gradio anthropic openai mcp ollama wandb mlflow tensorboard'
$PkgsFull = 'lightning optuna catboost statsmodels duckdb sympy networkx shap'

function Get-AiPackages($gpu) {
  $p = $PkgsCore
  if ($SetupProfile -ne 'minimal') {
    $p += " $PkgsStandard"
    if ($gpu.Vendor -eq 'nvidia') { $p += ' bitsandbytes' }
  }
  if ($SetupProfile -eq 'full') { $p += " $PkgsFull" }
  return ($p -split '\s+' | Where-Object { $_ })
}

# --------------------------------------------------------------------------- install steps
function Install-Winget([string]$Id, [string]$Label) {
  Run "winget install $Id" {
    winget install --id $Id -e --silent --accept-source-agreements --accept-package-agreements --disable-interactivity | Out-Host
  } | Out-Null
  $script:Installed.Add($Label)
}

function EnvPython([string]$name) { Join-Path $AistrapHome "envs\$name\Scripts\python.exe" }

function New-AistrapEnv([string]$name) {
  $py = EnvPython $name
  if (Test-Path $py) {
    $v = & $py -c "import sys; print('%d.%d' % sys.version_info[:2])"
    if ($v -eq $Python) { Ok "Re-using env '$name' (Python $v); upgrading packages in place."; return }
    Run "remove env $name" { Remove-Item -Recurse -Force (Join-Path $AistrapHome "envs\$name") } | Out-Null
  }
  Run "uv venv envs\$name --python $Python" { uv venv (Join-Path $AistrapHome "envs\$name") --python $Python --python-preference only-managed --prompt $name } | Out-Null
}

function UvPip([string]$envName, [string[]]$UvArgs) {
  $py = EnvPython $envName
  return (Run "uv pip install $($UvArgs -join ' ')" { uv pip install --python $py @UvArgs | Out-Host })
}

function Install-Resilient([string]$envName, [string[]]$Pkgs, [string[]]$Extra) {
  if (UvPip $envName (@('--upgrade') + $Extra + $Pkgs)) { return }
  Warn "Some packages in env '$envName' failed to resolve together; installing one by one."
  foreach ($p in $Pkgs) {
    if (-not (UvPip $envName (@('--upgrade') + $Extra + @($p)))) { Warn "env '$envName': could not install '$p' (skipped)" }
  }
}

function Register-Kernel([string]$envName, [string]$display) {
  $py = EnvPython $envName
  Run "register Jupyter kernel aistrap-$envName" { & $py -m ipykernel install --user --name "aistrap-$envName" --display-name $display | Out-Null } | Out-Null
}

function Get-Asset([string]$name, [string]$dest) {
  $local = if ($PSScriptRoot) { Join-Path $PSScriptRoot $name } else { $null }
  if ($local -and (Test-Path $local)) { Run "copy $name" { Copy-Item $local $dest -Force } | Out-Null }
  else { Run "download $name" { Invoke-WebRequest -UseBasicParsing "$RepoRaw/$name" -OutFile $dest } | Out-Null }
}

$AistrapPs1 = @'
# aistrap - AIStrap helper for Windows (generated by install.ps1)
param([Parameter(Position = 0)][string]$Cmd = 'help', [Parameter(ValueFromRemainingArguments = $true)][string[]]$Rest)
$AistrapHome = if ($env:AISTRAP_HOME) { $env:AISTRAP_HOME } else { Join-Path $env:USERPROFILE '.aistrap' }
$state = @{}
$sf = Join-Path $AistrapHome 'state.json'
if (Test-Path $sf) { $state = Get-Content $sf -Raw | ConvertFrom-Json }
function EnvDir($n) { $d = Join-Path $AistrapHome "envs\$n"; if (-not (Test-Path "$d\Scripts\python.exe")) { throw "No env '$n'" }; $d }
function Envs { Get-ChildItem (Join-Path $AistrapHome 'envs') -Directory | ForEach-Object Name }
switch ($Cmd) {
  'doctor' {
    $targets = if ($Rest) { $Rest } else { Envs }
    $rc = 0
    foreach ($e in $targets) { & "$(EnvDir $e)\Scripts\python.exe" "$AistrapHome\doctor.py" --env $e --expect $state.accel; if ($LASTEXITCODE) { $rc = 1 } }
    exit $rc
  }
  { $_ -in 'lab', 'jupyter' } { & "$(EnvDir ai)\Scripts\jupyter.exe" lab @Rest }
  'shell' {
    $n = if ($Rest) { $Rest[0] } else { 'ai' }
    powershell.exe -NoExit -ExecutionPolicy Bypass -Command ". '$(EnvDir $n)\Scripts\Activate.ps1'"
  }
  'run' { $d = EnvDir $Rest[0]; $env:VIRTUAL_ENV = $d; $env:Path = "$d\Scripts;$env:Path"; & $Rest[1] @($Rest | Select-Object -Skip 2) }
  'add' {
    $e = 'ai'; $pk = @($Rest)
    if ($pk.Count -ge 2 -and $pk[0] -in '-e', '--env') { $e = $pk[1]; $pk = $pk | Select-Object -Skip 2 }
    $d = EnvDir $e; $extra = @()
    if (Test-Path "$d\aistrap-constraints.txt") { $extra = @('--constraint', "$d\aistrap-constraints.txt") }
    uv pip install --python "$d\Scripts\python.exe" @extra @pk
  }
  { $_ -in 'envs', 'list' } {
    foreach ($e in Envs) {
      $code = "import sys`nfrom importlib.metadata import version`nout=['Python '+sys.version.split()[0]]`nfor p in ('torch','jax','tensorflow','transformers'):`n    try: out.append(p+' '+version(p))`n    except Exception: pass`nprint(', '.join(out))"
      Write-Host ("{0,-6} {1}" -f $e, (& "$AistrapHome\envs\$e\Scripts\python.exe" -c $code))
    }
  }
  { $_ -in 'update', 'upgrade' } {
    $raw = if ($state.repo) { $state.repo } else { 'https://raw.githubusercontent.com/brandonjabr/aistrap/master' }
    $sb = [scriptblock]::Create((Invoke-RestMethod "$raw/install.ps1"))
    $a = @{}; if ($state.args) { $state.args.PSObject.Properties | ForEach-Object { $a[$_.Name] = $_.Value } }
    & $sb @a -Yes
  }
  'uninstall' {
    if ((Read-Host "Remove $AistrapHome (all envs), aistrap and profile config? [y/N]") -notmatch '^y') { return }
    $prof = $PROFILE.CurrentUserAllHosts
    if (Test-Path $prof) { $t = Get-Content $prof -Raw; $t = [regex]::Replace($t, '(?s)# >>> aistrap >>>.*?# <<< aistrap <<<\r?\n?', ''); Set-Content $prof $t }
    Get-ChildItem "$env:APPDATA\jupyter\kernels" -Filter 'aistrap-*' -Directory -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force
    uv tool uninstall huggingface-hub 2>$null | Out-Null
    Remove-Item "$env:USERPROFILE\.local\bin\aistrap.cmd", "$env:USERPROFILE\.local\bin\ai.cmd" -ErrorAction SilentlyContinue
    Remove-Item -Recurse -Force $AistrapHome
    Write-Host 'Removed. uv, Git, Ollama and drivers were left in place.'
  }
  'version' { Write-Host "AIStrap $($state.version) (backend $($state.backend), profile $($state.profile))" }
  default {
    # (no nested here-string: it would terminate the outer one)
    @(
      "aistrap - AIStrap helper",
      "  aistrap doctor [env...]      health check: GPU, frameworks, quick benchmark",
      "  aistrap lab [args]           start JupyterLab (all env kernels available)",
      "  aistrap shell [env]          open a PowerShell with an env active (default: ai)",
      "  aistrap run ENV CMD...       run a command inside an env",
      "  aistrap add [-e ENV] PKG...  install extra packages (keeps the PyTorch build pinned)",
      "  aistrap envs                 list environments and framework versions",
      "  aistrap update               re-run the installer: newest builds/packages",
      "  aistrap uninstall            remove envs, helper and profile config"
    ) | ForEach-Object { Write-Host $_ }
  }
}
'@

function Install-Helpers($sel, $savedArgs) {
  Step 'aistrap helper, health check and shell integration'
  if ($DryRun) { Write-Host '   [dry-run] write doctor.py, aistrap.ps1, aistrap.cmd, ai.cmd, state.json, PowerShell profile block' -ForegroundColor DarkGray; return }
  New-Item -ItemType Directory -Force (Join-Path $AistrapHome 'bin'), "$env:USERPROFILE\.local\bin" | Out-Null
  Get-Asset 'doctor.py' (Join-Path $AistrapHome 'doctor.py')
  Set-Content -Path (Join-Path $AistrapHome 'bin\aistrap.ps1') -Value $AistrapPs1 -Encoding UTF8
  Set-Content -Path "$env:USERPROFILE\.local\bin\aistrap.cmd" -Encoding ASCII -Value "@powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$AistrapHome\bin\aistrap.ps1`" %*"
  Set-Content -Path "$env:USERPROFILE\.local\bin\ai.cmd" -Encoding ASCII -Value "@call `"$AistrapHome\envs\ai\Scripts\activate.bat`""
  [ordered]@{
    version = $AistrapVersion; profile = $SetupProfile; backend = $sel.Tag; accel = (Get-Accel $sel.Tag)
    python = $Python; repo = $RepoRaw; args = $savedArgs; installed_at = (Get-Date -Format 's')
  } | ConvertTo-Json | Set-Content (Join-Path $AistrapHome 'state.json')

  if (-not $NoShellConfig) {
    $prof = $PROFILE.CurrentUserAllHosts
    New-Item -ItemType Directory -Force (Split-Path $prof) | Out-Null
    $existing = if (Test-Path $prof) { Get-Content $prof -Raw } else { '' }
    $existing = [regex]::Replace($existing, '(?s)# >>> aistrap >>>.*?# <<< aistrap <<<\r?\n?', '')
    $block = @"
# >>> aistrap >>>  (managed by AIStrap; 'aistrap uninstall' removes it)
`$env:AISTRAP_HOME = '$AistrapHome'
function ai { . "`$env:AISTRAP_HOME\envs\ai\Scripts\Activate.ps1" }
function aistrap { & "`$env:AISTRAP_HOME\bin\aistrap.ps1" @args }
# <<< aistrap <<<
"@
    Set-Content $prof ($existing.TrimEnd() + "`r`n" + $block + "`r`n")
    $policy = Get-ExecutionPolicy -Scope CurrentUser
    if ($policy -in 'Undefined', 'Restricted', 'AllSigned') {
      $machinePolicy = Get-ExecutionPolicy
      if ($machinePolicy -in 'Restricted', 'AllSigned') {
        Warn "PowerShell won't load your profile (execution policy '$machinePolicy'), so the 'ai' and 'aistrap' functions won't exist yet. 'aistrap' still works via aistrap.cmd. To enable both, run:  Set-ExecutionPolicy -Scope CurrentUser RemoteSigned"
      }
    }
  }
}

# --------------------------------------------------------------------------- main
function Main {
  Write-Host "AIStrap $AistrapVersion - modern AI/ML workstation setup (Windows)" -ForegroundColor White
  if ($DryRun) { Write-Host '(dry run: nothing will be changed)' -ForegroundColor Yellow }

  if ($WSL) { Invoke-WslSetup; return }

  $savedArgs = [ordered]@{}
  foreach ($k in $PSBoundParameters.Keys) {
    if ($k -in 'DryRun', 'Yes', 'WSL') { continue }
    $v = $PSBoundParameters[$k]
    $savedArgs[$k] = if ($v -is [System.Management.Automation.SwitchParameter]) { $v.IsPresent } else { $v }
  }
  $wantOllama = (-not $NoOllama) -and ($SetupProfile -ne 'minimal')
  $wantJax = $Jax -or ($SetupProfile -eq 'full')
  $wantTf = $TensorFlow -or ($SetupProfile -eq 'full')
  $wantClaude = $ClaudeCode -or ($SetupProfile -eq 'full')

  $gpu = Get-GpuInfo
  $os = Get-CimInstance Win32_OperatingSystem
  $cpu = (Get-CimInstance Win32_Processor | Select-Object -First 1).Name
  $ramGb = [math]::Round($os.TotalVisibleMemorySize / 1MB)
  $freeGb = [math]::Round((Get-PSDrive ($env:USERPROFILE.Substring(0, 1))).Free / 1GB)
  $sel = Select-Backend $gpu

  Write-Host "`nThis machine" -ForegroundColor White
  Write-Host "  OS         $($os.Caption) ($env:PROCESSOR_ARCHITECTURE)"
  Write-Host "  CPU        $cpu"
  Write-Host "  Memory     $ramGb GB"
  $drv = if ($gpu.Driver) { " (driver $($gpu.Driver), CUDA $($gpu.DriverCuda))" } else { '' }
  Write-Host "  GPU        $($gpu.Name)$drv"
  Write-Host "  Disk       $freeGb GB free"

  Write-Host "`nPlan (profile: $SetupProfile)" -ForegroundColor White
  Write-Host '  - Git, uv (Python + package manager)'
  $torchV = if ($sel.Version) { $sel.Version } else { 'latest' }
  Write-Host "  - env 'ai': PyTorch $torchV [$($sel.Tag)] + $SetupProfile stack"
  if ($wantJax) { Write-Host "  - env 'jax': JAX (CPU on native Windows; use -WSL for GPU)" }
  if ($wantTf) { Write-Host "  - env 'tf': TensorFlow + Keras (CPU on native Windows; use -WSL for GPU)" }
  if ($SetupProfile -ne 'minimal') { Write-Host "  - Hugging Face 'hf' CLI" }
  if ($wantOllama) { Write-Host '  - Ollama (local LLMs)' }
  if ($wantClaude) { Write-Host '  - Claude Code' }
  if ($VSCode) { Write-Host '  - Visual Studio Code' }
  Write-Host "  - 'aistrap' helper + 'ai' command + Jupyter kernels`n"

  if (-not $Yes -and -not $DryRun) {
    if ((Read-Host 'Proceed? [Y/n]') -match '^(n|no)$') { Write-Host 'Aborted.'; return }
  }

  if (-not $DryRun) {
    New-Item -ItemType Directory -Force (Join-Path $AistrapHome 'logs') | Out-Null
    $log = Join-Path $AistrapHome "logs\install-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"
    Start-Transcript -Path $log | Out-Null
  }

  try {
    Step 'Apps (winget)'
    if (-not (Have winget)) { throw 'winget is missing. Install "App Installer" from the Microsoft Store, then re-run.' }
    if (-not (Have git)) { Install-Winget 'Git.Git' 'Git' } else { Ok 'Git already installed.' }
    if ($wantOllama) { if (-not (Have ollama)) { Install-Winget 'Ollama.Ollama' 'Ollama (ollama run <model>)' } else { Ok 'Ollama already installed.' } }
    if ($VSCode -and -not (Have code)) { Install-Winget 'Microsoft.VisualStudioCode' 'VS Code' }
    if ($gpu.Vendor -eq 'nvidia' -and -not $gpu.Driver) { Warn 'No working NVIDIA driver found. Install the latest Game Ready / Studio driver (NVIDIA App), then run: aistrap update' }
    Refresh-Path

    Step 'uv (Python + package manager)'
    if (Have uv) { Run 'uv self update' { uv self update 2>&1 | Out-Null } | Out-Null; Ok 'uv ready.' }
    else {
      Run 'install uv (astral.sh)' { powershell.exe -NoProfile -ExecutionPolicy Bypass -Command 'irm https://astral.sh/uv/install.ps1 | iex' } | Out-Null
      Refresh-Path; $script:Installed.Add('uv')
    }

    Step "Environment 'ai': PyTorch [$($sel.Tag)] + $SetupProfile stack"
    New-AistrapEnv 'ai'
    $sf = Join-Path $AistrapHome 'state.json'
    $torchArgs = @('--upgrade', 'torch', 'torchvision')
    if ((Test-Path $sf) -and ((Get-Content $sf -Raw | ConvertFrom-Json).backend -ne $sel.Tag)) {
      $torchArgs += @('--reinstall-package', 'torch', '--reinstall-package', 'torchvision')
    }
    if ($sel.Url) { $torchArgs += @('--index-url', $sel.Url) }
    if (-not (UvPip 'ai' $torchArgs)) { throw 'PyTorch install failed.' }
    $cons = Join-Path $AistrapHome 'envs\ai\aistrap-constraints.txt'
    if (-not $DryRun) {
      & (EnvPython 'ai') -c "from importlib.metadata import version as v; print('\n'.join(f'{p}=={v(p).split(chr(43))[0]}' for p in ('torch','torchvision')))" | Set-Content $cons -Encoding ASCII
    }
    Install-Resilient 'ai' (Get-AiPackages $gpu) @('--constraint', $cons)
    Register-Kernel 'ai' 'Python (ai: PyTorch)'
    $script:Installed.Add("env 'ai': PyTorch [$($sel.Tag)] + $SetupProfile stack")

    if ($wantJax) {
      Step "Environment 'jax'"
      New-AistrapEnv 'jax'
      Install-Resilient 'jax' @('jax', 'flax', 'optax', 'orbax-checkpoint', 'chex', 'numpy', 'matplotlib', 'ipykernel') @()
      Register-Kernel 'jax' 'Python (jax)'
      $script:Installed.Add("env 'jax' (CPU on native Windows)")
    }
    if ($wantTf) {
      Step "Environment 'tf'"
      New-AistrapEnv 'tf'
      Install-Resilient 'tf' @('tensorflow', 'keras', 'numpy', 'matplotlib', 'ipykernel') @()
      Register-Kernel 'tf' 'Python (tf: TensorFlow)'
      $script:Installed.Add("env 'tf' (CPU on native Windows)")
    }
    if ($SetupProfile -ne 'minimal') {
      Step 'hf CLI'
      Run 'uv tool install huggingface_hub[cli]' { uv tool install --upgrade --python $Python 'huggingface_hub[cli]' | Out-Host } | Out-Null
      $script:Installed.Add('hf CLI')
    }
    if ($wantClaude) {
      Step 'Claude Code'
      if (Have claude) { Ok 'Claude Code already installed.' }
      else { Run 'install Claude Code (claude.ai/install.ps1)' { Invoke-Expression (Invoke-RestMethod 'https://claude.ai/install.ps1') } | Out-Null; $script:Installed.Add('Claude Code') }
    }

    Install-Helpers $sel $savedArgs

    if (-not $DryRun) {
      Step 'Health check'
      foreach ($e in 'ai', 'jax', 'tf') {
        $py = EnvPython $e
        if (Test-Path $py) { & $py (Join-Path $AistrapHome 'doctor.py') --env $e --expect (Get-Accel $sel.Tag); if ($LASTEXITCODE) { Warn "Health check for env '$e' reported problems." } }
      }
    }
  }
  finally {
    if (-not $DryRun) { try { Stop-Transcript | Out-Null } catch {} }
  }

  Write-Host "`n============================================================" -ForegroundColor White
  if ($DryRun) { Write-Host 'Dry run complete. Nothing was changed.' -ForegroundColor White }
  else {
    Write-Host "AIStrap $AistrapVersion`: your AI workstation is ready." -ForegroundColor Green
    if ($script:Installed.Count) { Write-Host "`nInstalled / updated"; $script:Installed | ForEach-Object { Write-Host "  - $_" } }
  }
  if ($script:Warnings.Count) { Write-Host "`nNeeds your attention" -ForegroundColor Yellow; $script:Warnings | ForEach-Object { Write-Host "  - $_" } }
  if (-not $DryRun) {
    Write-Host "`nNext steps"
    Write-Host '  * Open a new terminal'
    Write-Host '  * ai               activate the main env'
    Write-Host '  * aistrap lab          JupyterLab with every env as a kernel'
    Write-Host '  * aistrap doctor       GPU / framework health check'
    if ($wantOllama) { Write-Host '  * ollama run gemma3   chat with a local LLM' }
    Write-Host '  * aistrap update       upgrade everything to the newest compatible versions'
    Write-Host '  * For vLLM / GPU JAX / GPU TensorFlow: .\install.ps1 -WSL'
  }
}

Main
