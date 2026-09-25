<#
  Локальный тест полного цикла оплаты. Ключи Cloudflare и FreeKassa не нужны.

  Проверяет:
    1. POST /create             — заказ создан, ссылка на оплату собрана верно
    2. GET  /status             — заказ в состоянии created
    3. POST /notify (мусор)     — 403, подпись не проходит, статус не меняется
    4. POST /notify (верная)    — {"status":"ok"}
    5. GET  /status             — заказ перешёл в paid
    6. POST /create (чужой)     — 403 без секрета, 400 на нулевую сумму
    7. POST /notify (ERROR)     — заказ в состоянии error
    8. GET  /status (неизвест.) — 404
    9. CORS                     — Access-Control-Allow-Origin: *
   10. GET /notify              — тоже принимается

  Запуск:  pwsh -File worker/test-local.ps1
#>
[CmdletBinding()]
param(
  [int]$Port = 8787,
  [switch]$KeepOpen
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Net.Http

$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$devVars = Join-Path $root '.dev.vars'
$wrangler = Join-Path $root 'node_modules\wrangler\bin\wrangler.js'

if (-not (Test-Path -LiteralPath $wrangler)) {
  Write-Host 'Устанавливаю wrangler…' -ForegroundColor Cyan
  Push-Location $root
  try { npm.cmd install --silent | Out-Null } finally { Pop-Location }
}

if (-not (Test-Path -LiteralPath $devVars)) {
  Write-Host 'Создаю .dev.vars из .dev.vars.example' -ForegroundColor Cyan
  Copy-Item -LiteralPath (Join-Path $root '.dev.vars.example') -Destination $devVars
}

$merchant = '123456'
$secret = 'test-secret-key'
$apiSecret = 'test-api-secret'
$base = "http://127.0.0.1:$Port"
$log = Join-Path $env:TEMP 'vpn-payments-wrangler.log'
$errLog = Join-Path $env:TEMP 'vpn-payments-wrangler.err.log'
$script:passed = 0
$script:failed = 0
$client = New-Object System.Net.Http.HttpClient
$client.Timeout = [TimeSpan]::FromSeconds(30)

function Get-Signature {
  param([string]$OrderId, [string]$Amount, [string]$Currency, [string]$Status)
  $raw = "${merchant}:${OrderId}:${Amount}:${Currency}:${Status}:${secret}"
  $md5 = [System.Security.Cryptography.MD5]::Create()
  ([System.BitConverter]::ToString($md5.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($raw))) -replace '-', '').ToLower()
}

function Assert-True {
  param([string]$Name, [bool]$Condition, $Detail = '')
  if ($Condition) {
    $script:passed++
    Write-Host "  [OK]   $Name" -ForegroundColor Green
  }
  else {
    $script:failed++
    Write-Host "  [FAIL] $Name  → $Detail" -ForegroundColor Red
  }
}

function Invoke-Api {
  param([string]$Path, [string]$Method = 'GET', $Body = $null, [hashtable]$Headers = @{})
  $req = New-Object System.Net.Http.HttpRequestMessage ([System.Net.Http.HttpMethod]::new($Method), "$base$Path")
  foreach ($k in $Headers.Keys) { [void]$req.Headers.TryAddWithoutValidation($k, $Headers[$k]) }
  if ($null -ne $Body) {
    $req.Content = New-Object System.Net.Http.StringContent (($Body | ConvertTo-Json -Compress), [System.Text.Encoding]::UTF8, 'application/json')
  }
  $res = $client.SendAsync($req).GetAwaiter().GetResult()
  $content = $res.Content.ReadAsStringAsync().GetAwaiter().GetResult()
  $hdr = @{}
  foreach ($h in $res.Headers) { $hdr[$h.Key] = ($h.Value -join ',') }
  foreach ($h in $res.Content.Headers) { $hdr[$h.Key] = ($h.Value -join ',') }
  [pscustomobject]@{ StatusCode = [int]$res.StatusCode; Content = $content; Headers = $hdr }
}

function Get-Status {
  param([string]$OrderId)
  (Invoke-Api -Path "/status?order_id=$OrderId").Content | ConvertFrom-Json
}

Write-Host "`nПоднимаю wrangler dev на $base …" -ForegroundColor Cyan
$proc = Start-Process -FilePath 'node.exe' -ArgumentList @($wrangler, 'dev', '--port', "$Port", '--ip', '127.0.0.1', '--log-level', 'error') `
  -WorkingDirectory $root -RedirectStandardOutput $log -RedirectStandardError $errLog -PassThru -WindowStyle Hidden

try {
  $ready = $false
  foreach ($i in 1..60) {
    Start-Sleep -Seconds 1
    if ($proc.HasExited) { break }
    try {
      if ((Invoke-Api -Path '/ping').StatusCode -eq 200) { $ready = $true; break }
    } catch { }
  }
  if (-not $ready) {
    Write-Host "`nНе удалось поднять локальный сервер. Логи:" -ForegroundColor Red
    if (Test-Path $log) { Get-Content $log -Tail 40 }
    if (Test-Path $errLog) { Get-Content $errLog -Tail 40 }
    exit 1
  }

  Write-Host "`n1. Создание заказа" -ForegroundColor Cyan
  $create = Invoke-Api -Path '/create' -Method 'POST' -Headers @{ 'x-api-secret' = $apiSecret } `
    -Body @{ order_id = 'local-test-1'; amount = '299.00'; chat_id = 42; plan = 'month' }
  $order = $create.Content | ConvertFrom-Json
  Assert-True 'POST /create вернул 200' ($create.StatusCode -eq 200) $create.StatusCode
  Assert-True 'order_id сохранён' ($order.order_id -eq 'local-test-1') $order.order_id
  Assert-True 'сумма нормализована в 2 знака' ($order.amount -eq '299.00') $order.amount
  Assert-True 'в ссылке order_amount=299.00' ($order.payment_url -like '*order_amount=299.00*')
  Assert-True 'в ссылке success_url на Pages' ($order.payment_url -like '*success_url=https%3A%2F%2Fzussuzgc-web.github.io*')
  Assert-True 'в ссылке fail_url на Pages' ($order.payment_url -like '*fail_url=https%3A%2F%2Fzussuzgc-web.github.io*')
  Assert-True 'есть ссылка на страницу статуса' ($order.status_page -like '*/order/?order_id=local-test-1*') $order.status_page
  Assert-True 'в ссылке статуса есть api=' ($order.status_page -like '*api=http%3A%2F%2F127.0.0.1*') $order.status_page
  Assert-True 'в ответе указан notify_url' ($order.notify_url -like 'http://127.0.0.1*/notify') $order.notify_url

  Write-Host "`n2. Статус нового заказа" -ForegroundColor Cyan
  $st = Get-Status 'local-test-1'
  Assert-True 'status = created' ($st.status -eq 'created') $st.status
  Assert-True 'сумма 299.00' ($st.amount -eq '299.00') $st.amount
  Assert-True 'paid_at пуст' ($null -eq $st.paid_at)

  Write-Host "`n3. Оповещение с неверной подписью" -ForegroundColor Cyan
  $bad = Invoke-Api -Path '/notify?order_id=local-test-1&order_amount=299.00&order_currency=RUB&order_status=PAID&signature=deadbeef' -Method 'POST'
  Assert-True 'мусорная подпись отклонена (403)' ($bad.StatusCode -eq 403) $bad.StatusCode
  Assert-True 'статус не изменился после подделки' ((Get-Status 'local-test-1').status -eq 'created')

  Write-Host "`n4. Оповещение с верной подписью" -ForegroundColor Cyan
  $sig = Get-Signature -OrderId 'local-test-1' -Amount '299.00' -Currency 'RUB' -Status 'PAID'
  $pay = Invoke-Api -Path "/notify?order_id=local-test-1&order_amount=299.00&order_currency=RUB&order_status=PAID&ID=999111&signature=$sig" -Method 'POST'
  Assert-True 'notify вернул 200' ($pay.StatusCode -eq 200) $pay.StatusCode
  Assert-True 'ответ {"status":"ok"}' ($pay.Content -match '"status"\s*:\s*"ok"') $pay.Content

  Write-Host "`n5. Статус после оплаты" -ForegroundColor Cyan
  $st3 = Get-Status 'local-test-1'
  Assert-True 'status = paid' ($st3.status -eq 'paid') $st3.status
  Assert-True 'paid_at проставлен' ($null -ne $st3.paid_at)

  Write-Host "`n6. Защита /create" -ForegroundColor Cyan
  $noauth = Invoke-Api -Path '/create' -Method 'POST' -Body @{ order_id = 'hack-1'; amount = '1.00' }
  Assert-True 'без x-api-secret отдаёт 403' ($noauth.StatusCode -eq 403) $noauth.StatusCode
  $zero = Invoke-Api -Path '/create' -Method 'POST' -Headers @{ 'x-api-secret' = $apiSecret } -Body @{ order_id = 'zero-1'; amount = '0' }
  Assert-True 'нулевая сумма отклонена (400)' ($zero.StatusCode -eq 400) $zero.StatusCode

  Write-Host "`n7. Отклонённый платёж" -ForegroundColor Cyan
  Invoke-Api -Path '/create' -Method 'POST' -Headers @{ 'x-api-secret' = $apiSecret } -Body @{ order_id = 'local-test-2'; amount = '99.00' } | Out-Null
  $sigErr = Get-Signature -OrderId 'local-test-2' -Amount '99.00' -Currency 'RUB' -Status 'ERROR'
  Invoke-Api -Path "/notify?order_id=local-test-2&order_amount=99.00&order_currency=RUB&order_status=ERROR&ID=999222&signature=$sigErr" -Method 'POST' | Out-Null
  Assert-True 'status = error' ((Get-Status 'local-test-2').status -eq 'error')

  Write-Host "`n8. Неизвестный заказ и CORS" -ForegroundColor Cyan
  $miss = Invoke-Api -Path '/status?order_id=does-not-exist'
  Assert-True '404 для неизвестного заказа' ($miss.StatusCode -eq 404) $miss.StatusCode
  $cors = Invoke-Api -Path '/status?order_id=local-test-1'
  Assert-True 'Access-Control-Allow-Origin: *' ($cors.Headers['Access-Control-Allow-Origin'] -eq '*') ($cors.Headers.Keys -join ',')

  Write-Host "`n9. GET /notify тоже принимается" -ForegroundColor Cyan
  $sigGet = Get-Signature -OrderId 'local-test-3' -Amount '50.00' -Currency 'RUB' -Status 'PAID'
  $get = Invoke-Api -Path "/notify?order_id=local-test-3&order_amount=50.00&order_currency=RUB&order_status=PAID&signature=$sigGet"
  Assert-True 'GET /notify вернул 200' ($get.StatusCode -eq 200) $get.StatusCode
  Assert-True 'order_id без созданного заказа тоже принимается' ((Get-Status 'local-test-3').status -eq 'paid')

  Write-Host "`n────────────────────────────────────" -ForegroundColor DarkGray
  if ($failed -eq 0) { Write-Host "Пройдено: $passed   Провалено: $failed" -ForegroundColor Green }
  else { Write-Host "Пройдено: $passed   Провалено: $failed" -ForegroundColor Red }
  Write-Host "────────────────────────────────────`n" -ForegroundColor DarkGray
}
finally {
  $client.Dispose()
  if (-not $KeepOpen -and $proc -and -not $proc.HasExited) {
    & taskkill.exe /PID $proc.Id /T /F 2>&1 | Out-Null
  }
}

if ($failed -eq 0) { exit 0 } else { exit 1 }
