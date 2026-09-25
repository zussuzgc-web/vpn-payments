<#
.SYNOPSIS
  Установка платёжной части VPN: KV-хранилище, секреты, деплой Cloudflare Worker,
  правка адреса Worker'а на страницах, проверка живого цикла оплаты.

.DESCRIPTION
  Скрипт задаёт вопросы сам, секреты никуда не пишутся в репозиторий.
  Значения вводятся в окно PowerShell и уходят напрямую в Cloudflare (secret put).

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\setup.ps1

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\setup.ps1 -SkipGit

.EXAMPLE
  # Без вопросов (CI, все значения через параметры):
  powershell -ExecutionPolicy Bypass -File .\setup.ps1 `
    -MerchantId 123456 -SecretKey "xxxx" -BotToken "123:AA" -SkipGit
#>
[CmdletBinding()]
param(
  [string]$MerchantId,
  [string]$SecretKey,
  [string]$BotToken,
  [string]$ApiSecret,
  [string]$WorkerUrl,
  [switch]$SkipGit,
  [switch]$Yes
)

$ErrorActionPreference = 'Stop'
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls11 -bor [Net.SecurityProtocolType]::Tls } catch { }
$repo = Split-Path -Parent $MyInvocation.MyCommand.Path
$workerDir = Join-Path $repo 'worker'
$toml = Join-Path $workerDir 'wrangler.toml'
$configJs = Join-Path $repo 'assets\config.js'
$botEnv = Join-Path $repo 'bot\.env'
$wrangler = Join-Path $workerDir 'node_modules\wrangler\bin\wrangler.js'

$script:Fail = 0
function Step  { param([string]$Text) Write-Host "`n▸ $Text" -ForegroundColor Cyan }
function Ok    { param([string]$Text) Write-Host "  ✓ $Text" -ForegroundColor Green }
function Info  { param([string]$Text) Write-Host "  · $Text" -ForegroundColor Gray }
function Warn  { param([string]$Text) Write-Host "  ! $Text" -ForegroundColor Yellow }
function Die   { param([string]$Text) Write-Host "`n✗ $Text" -ForegroundColor Red; exit 1 }

function Ask {
  param([string]$Prompt, [string]$Value, [switch]$Secret, [switch]$Required)
  if ($Value) { return $Value }
  if ($Yes) { Die "Нужен параметр: $Prompt (запусти без -Yes)" }
  Write-Host "  $Prompt" -ForegroundColor White -NoNewline
  if ($Secret) {
    $secure = Read-Host -AsSecureString
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    $Value = [Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
    [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
  }
  else { $Value = (Read-Host).Trim() }
  if ($Required -and -not $Value) { Die "Пустое значение: $Prompt" }
  return $Value
}

function Confirm {
  param([string]$Text, [bool]$Default = $true)
  if ($Yes) { return $true }
  $a = if ($Default) { 'Y/n' } else { 'y/N' }
  return ((Read-Host "  $Text [$a]") -match '^(y|д|yes|1)?$')
}

function Invoke-Wrangler {
  param([string[]]$WranglerArgs, [switch]$AllowFail)
  # stderr от wrangler не должен становиться исключением PowerShell
  $prev = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  $lines = & node.exe $wrangler '--config' $toml @WranglerArgs 2>&1 |
    ForEach-Object {
      $text = if ($_ -is [System.Management.Automation.ErrorRecord]) { $_.Exception.Message } else { [string]$_ }
      if ($text -and $text -ne 'System.Management.Automation.RemoteException') { $text }
    }
  $code = $LASTEXITCODE
  $ErrorActionPreference = $prev
  $out = $lines -join "`n"
  if ($code -ne 0) {
    Write-Host $out -ForegroundColor DarkGray
    if ($AllowFail) { return $null }
    Die "wrangler $($WranglerArgs -join ' ') завершился с кодом $code"
  }
  return $out
}

Write-Host @"

  ┌──────────────────────────────────────────────┐
  │  VPN Payments · установка оплаты FreeKassa   │
  └──────────────────────────────────────────────┘
"@ -ForegroundColor White

# ── 1. Окружение ────────────────────────────────────────────────────────────
Step 'Проверяю окружение'
if (-not (Get-Command node.exe -ErrorAction SilentlyContinue)) { Die 'Node.js не найден. Установи Node.js 20+ с nodejs.org' }
$nodeVer = (node.exe --version).Trim()
Ok "Node.js $nodeVer"
if (-not (Test-Path -LiteralPath $wrangler)) {
  Info 'Устанавливаю wrangler (npm install)…'
  Push-Location $workerDir
  try { & npm.cmd install --silent | Out-Null } finally { Pop-Location }
}
if (-not (Test-Path -LiteralPath $wrangler)) { Die 'Не удалось установить зависимости в worker\' }
Ok "wrangler $((node.exe $wrangler --version 2>&1 | Select-Object -Last 1).Trim())"

# ── 2. Авторизация в Cloudflare ─────────────────────────────────────────────
Step 'Авторизация в Cloudflare'
$who = Invoke-Wrangler @('whoami') -AllowFail
if ($who) {
  Ok ("Аккаунт: " + (($who -split "`n" | Where-Object { $_ -match 'Account' } | Select-Object -First 1) -replace '\s+', ' '))
}
else {
  Info 'Открываю браузер — нажми «Allow» на странице Cloudflare'
  Invoke-Wrangler @('login')
  $who = Invoke-Wrangler @('whoami') -AllowFail
  if (-not $who) { Die 'Не удалось авторизоваться. Запусти npx wrangler login вручную и повтори установку' }
  Ok 'Авторизация прошла'
}

# ── 3. KV-хранилище ─────────────────────────────────────────────────────────
Step 'KV-хранилище заказов'
$kvOut = Invoke-Wrangler @('kv', 'namespace', 'list') -AllowFail
$kvId = $null
if ($kvOut -and (Test-Path -LiteralPath $toml)) {
  $current = (Get-Content -LiteralPath $toml -Raw)
  if ($current -match 'id\s*=\s*"([0-9a-f]{32})"') { $kvId = $Matches[1] }
}
if ($kvId -and $kvId -ne 'ЗАМЕНИТЬ_НА_ТВОЙ_KV_ID') {
  Ok "Найдено существующее: $kvId"
}
else {
  Info 'Создаю namespace ORDERS…'
  $created = Invoke-Wrangler @('kv', 'namespace', 'create', 'ORDERS') -AllowFail
  if ($created -match 'id\s*=\s*"([0-9a-f]{32})"') { $kvId = $Matches[1] }
  else { Die 'Не удалось создать KV namespace. Проверь вывод: npx wrangler kv namespace create ORDERS' }
  $text = [System.IO.File]::ReadAllText($toml, [System.Text.UTF8Encoding]::new($false))
  $text = $text -replace '(?m)^id\s*=\s*"[^"]*"', "id = `"$kvId`""
  [System.IO.File]::WriteAllText($toml, $text, [System.Text.UTF8Encoding]::new($false))
  Ok "Создано и вписано в wrangler.toml: $kvId"
}

# ── 4. Секреты ──────────────────────────────────────────────────────────────
Step 'Секреты FreeKassa и бота'
Info 'ID кабинета и секретный ключ — кабинет FreeKassa → «Настройки кабинета».'
Info 'Токен бота — @BotFather в Telegram (/newbot для @FreeFi_bot).'
$MerchantId = Ask 'ID кабинета FreeKassa (число)' $MerchantId -Required
$SecretKey  = Ask 'Секретный ключ FreeKassa' $SecretKey -Secret -Required
$BotToken   = Ask 'Токен Telegram-бота @FreeFi_bot' $BotToken -Secret -Required
if (-not $ApiSecret) { $ApiSecret = [Convert]::ToBase64String((1..32 | ForEach-Object { Get-Random -Maximum 256 })) -replace '\+', '-' -replace '/', '_' }

$secretsFile = Join-Path $env:TEMP ('wrangler-secrets-' + [guid]::NewGuid().ToString('N') + '.json')
$secretsJson = @{ MERCHANT_ID = $MerchantId; SECRET_KEY = $SecretKey; BOT_TOKEN = $BotToken; API_SECRET = $ApiSecret } |
  ConvertTo-Json -Compress
[System.IO.File]::WriteAllText($secretsFile, $secretsJson, [System.Text.UTF8Encoding]::new($false))
Invoke-Wrangler @('secret', 'bulk', $secretsFile) | Out-Null
Remove-Item -LiteralPath $secretsFile -Force
Ok 'MERCHANT_ID, SECRET_KEY, BOT_TOKEN, API_SECRET заданы в Worker'
Ok "API_SECRET для бота: $ApiSecret"

# ── 5. Деплой ───────────────────────────────────────────────────────────────
Step 'Публикую Worker'
$deployOut = Invoke-Wrangler @('deploy') -AllowFail
if (-not $deployOut) {
  Write-Host ''
  if ($deployOut -match 'workers-dev-subdomain|workers\\?dev subdomain|onboarding') {
    Write-Host '  В аккаунте Cloudflare ещё нет поддомена workers.dev.' -ForegroundColor Yellow
    if ($deployOut -match 'https://dash\.cloudflare\.com/([0-9a-f]{32})') {
      Write-Host "  Открой один раз и подтверди создание поддомена:" -ForegroundColor Yellow
      Write-Host "  https://dash.cloudflare.com/$($Matches[1])/workers/workers-and-pages" -ForegroundColor White
    }
    Write-Host '  После этого запусти setup.ps1 ещё раз — всё остальное уже настроено.' -ForegroundColor Yellow
  }
  Write-Host ''
  exit 1
}
if ($deployOut -match 'https://([a-z0-9.-]*?workers\.dev)') { $WorkerUrl = 'https://' + $Matches[1] }
if (-not $WorkerUrl) {
  Die 'Не удалось определить адрес Worker из вывода wrangler deploy. Укажи его вручную: setup.ps1 -WorkerUrl https://<имя>.<поддомен>.workers.dev'
}
Ok "Адрес: $WorkerUrl"

# ── 6. Адрес Worker'а на страницах ──────────────────────────────────────────
Step "Вписываю адрес Worker'а в страницы и .env бота"
$cfg = [System.IO.File]::ReadAllText($configJs, [System.Text.UTF8Encoding]::new($false))
$cfg = $cfg -replace '(?m)(api:\s*")[^"]*(")', "`${1}$WorkerUrl`${2}"
[System.IO.File]::WriteAllText($configJs, $cfg, [System.Text.UTF8Encoding]::new($false))
Ok "assets/config.js → $WorkerUrl"

$envText = @"
FREEKASSA_API=$WorkerUrl
FREEKASSA_SECRET=$ApiSecret
BOT_USERNAME=FreeFi_bot
BOT_TOKEN=$BotToken
MERCHANT_ID=$MerchantId
"@
[System.IO.File]::WriteAllText($botEnv, $envText, [System.Text.UTF8Encoding]::new($false))
Ok 'bot/.env создан (в .gitignore, в репозиторий не попадёт)'

# ── 7. Проверка живого цикла ────────────────────────────────────────────────
Step 'Проверяю живой цикл оплаты'
$order = 'setup-smoke-' + (Get-Date -Format 'HHmmss')
function Md5 {
  param([string]$Text)
  ([System.BitConverter]::ToString([System.Security.Cryptography.MD5]::Create().ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Text))) -replace '-', '').ToLower()
}
function Call {
  param([string]$Path, [string]$Method = 'GET', $Body = $null, [hashtable]$Headers = @{})
  try {
    $r = Invoke-WebRequest -Uri "$WorkerUrl$Path" -Method $Method -Headers $Headers -Body $Body -ContentType 'application/json' -TimeoutSec 25 -UseBasicParsing
    return @{ Code = $r.StatusCode; Text = $r.Content }
  }
  catch {
    $code = 0; $text = ''
    if ($_.Exception.Response) {
      $code = [int]$_.Exception.Response.StatusCode
      try { $sr = New-Object IO.StreamReader($_.Exception.Response.GetResponseStream()); $text = $sr.ReadToEnd() } catch { }
    }
    return @{ Code = $code; Text = $text }
  }
}

$ping = Call '/ping'
foreach ($i in 1..12) {
  if ($ping.Code -eq 200) { break }
  Info "Worker ещё не отвечает (попытка $i/12) — DNS и сертификат после первого деплоя едут до 2 минут"
  Start-Sleep -Seconds 10
  $ping = Call '/ping'
}
if ($ping.Code -eq 200) { Ok '/ping отвечает' } else { Die "/ping вернул $($ping.Code) — проверь адрес $WorkerUrl" }

$create = Call '/create' 'POST' (@{ order_id = $order; amount = '1.00'; chat_id = 0; plan = 'smoke-test' } | ConvertTo-Json -Compress) @{ 'x-api-secret' = $ApiSecret }
if ($create.Code -eq 200) { Ok "/create создал заказ $order" } else { Die "/create вернул $($create.Code): $($create.Text)" }

$st = Call "/status?order_id=$order"
if (($st.Text | ConvertFrom-Json).status -eq 'created') { Ok '/status отдаёт created' } else { Warn "/status: $($st.Text)" }

$sigBad = Call "/notify?order_id=$order&order_amount=1.00&order_currency=RUB&order_status=PAID&signature=bad" 'POST'
if ($sigBad.Code -eq 403) { Ok 'подделка подписи отклонена (403)' } else { Warn "подделка подписи вернула $($sigBad.Code), ожидался 403" }

$sig = Md5 "$MerchantId`:$order`:1.00`:RUB`:PAID`:$SecretKey"
$pay = Call "/notify?order_id=$order&order_amount=1.00&order_currency=RUB&order_status=PAID&ID=smoke1&signature=$sig" 'POST'
if ($pay.Code -eq 200) { Ok 'оповещение с верной подписью принято' }
else { Warn "notify вернул $($pay.Code): $($pay.Text)"; Warn "sig=[$sig] len=$($sig.Length)"; Warn "url=[$WorkerUrl/notify?order_id=$order&order_amount=1.00&order_currency=RUB&order_status=PAID&ID=smoke1&signature=$sig]" }

$st2 = Call "/status?order_id=$order"
if (($st2.Text | ConvertFrom-Json).status -eq 'paid') { Ok '/status показал paid — цикл работает' } else { Warn "/status после оплаты: $($st2.Text)" }
Invoke-Wrangler @('kv', 'key', 'delete', "order:$order", '--namespace-id', $kvId, '--remote') -AllowFail | Out-Null
Info 'тестовый заказ удалён из KV'

# ── 8. Публикация страниц ───────────────────────────────────────────────────
if (-not $SkipGit) {
  Step 'Коммит и публикация страниц'
  Push-Location $repo
  try {
    & git.exe add -A 2>&1 | Out-Null
    & git.exe diff --cached --quiet
    if ($LASTEXITCODE -eq 0) { Info 'изменений нет — коммит не нужен' }
    elseif (Confirm 'Закоммитить и запушить в GitHub?') {
      & git.exe commit -q -m 'setup: адрес Worker в конфиге страниц' 2>&1 | Out-Null
      & git.exe push -q 2>&1 | Out-Null
      Ok ' Pages обновятся через минуту'
    }
    else { Warn 'пропущено — запуши вручную, иначе страницы останутся со старым адресом' }
  }
  finally { Pop-Location }
}

# ── Итог ────────────────────────────────────────────────────────────────────
$pages = 'https://zussuzgc-web.github.io/vpn-payments'
Write-Host @"

  ┌──────────────────────────────────────────────────────────────┐
  │  Готово. Впиши в кабинете FreeKassa → Настройки кабинета:     │
  ├──────────────────────────────────────────────────────────────┤
  │                                                              │
  │  URL оповещения        $WorkerUrl/notify
  │                                                              │
  │  URL успешной оплаты   $pages/success/
  │  URL при неудаче       $pages/fail/
  │                                                              │
  │  Страница статуса      $pages/order/?order_id=<ID>
  │                                                              │
  │  Проверка подписи      включить (Worker проверяет сам)        │
  │                                                              │
  └──────────────────────────────────────────────────────────────┘

  Дальше: скопируй bot\.env на сервер бота и подними его (см. bot\README).
"@ -ForegroundColor White
