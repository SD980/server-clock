# 서버 시계 - 예매 사이트 서버 시간을 보여 주는 시계 (클릭은 직접 합니다)
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

# ---------- 고정밀 내 PC 시계 ----------
$script:sw = [System.Diagnostics.Stopwatch]::StartNew()
$script:baseUtc = [DateTime]::UtcNow
$script:EPOCH = 621355968000000000
function Get-LocalSec {
    return ($script:baseUtc.Ticks - $script:EPOCH) / 1e7 + $script:sw.Elapsed.TotalSeconds
}

$script:offset = 0.0
$script:err = 0.0
$script:synced = $false
$script:lastK = $null
$script:targetText = ''
$script:targetSec = $null

# ---------- 소리 만들기 ----------
function New-Tone([int]$freq, [int]$ms) {
    $rate = 22050
    $n = [int]($rate * $ms / 1000)
    $mem = New-Object System.IO.MemoryStream
    $bw = New-Object System.IO.BinaryWriter($mem)
    $dataLen = $n * 2
    $ascii = [Text.Encoding]::ASCII
    $bw.Write($ascii.GetBytes('RIFF')); $bw.Write([int](36 + $dataLen)); $bw.Write($ascii.GetBytes('WAVE'))
    $bw.Write($ascii.GetBytes('fmt ')); $bw.Write([int]16); $bw.Write([int16]1); $bw.Write([int16]1)
    $bw.Write([int]$rate); $bw.Write([int]($rate * 2)); $bw.Write([int16]2); $bw.Write([int16]16)
    $bw.Write($ascii.GetBytes('data')); $bw.Write([int]$dataLen)
    for ($i = 0; $i -lt $n; $i++) {
        $fade = [Math]::Min($i, $n - $i)
        $env = 1.0
        if ($fade -lt 300) { $env = $fade / 300.0 }
        $v = [Math]::Sin(2 * [Math]::PI * $freq * $i / $rate) * 20000 * $env
        $bw.Write([int16][Math]::Round($v))
    }
    $bw.Flush()
    $mem.Position = 0
    $p = New-Object System.Media.SoundPlayer($mem)
    $p.Load()
    return $p
}
$script:sndTick  = New-Tone 1000 90
$script:sndMin   = New-Tone 800 400
$script:sndFinal = New-Tone 1600 500

# ---------- 서버 시간 읽기 ----------
function Get-ServerDate([string]$url) {
    $req = [System.Net.HttpWebRequest]::Create($url)
    $req.Method = 'HEAD'
    $req.AllowAutoRedirect = $false
    $req.Timeout = 5000
    $req.KeepAlive = $true
    $req.UserAgent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)'
    $t0 = Get-LocalSec
    $resp = $null
    try {
        $resp = $req.GetResponse()
    } catch {
        $ex = $_.Exception
        while ($ex -and -not ($ex -is [System.Net.WebException])) { $ex = $ex.InnerException }
        if ($ex -and $ex.Response) { $resp = $ex.Response } else { throw }
    }
    $t1 = Get-LocalSec
    $d = $resp.Headers['Date']
    $resp.Close()
    if (-not $d) { throw '이 사이트는 서버 시간을 알려 주지 않습니다' }
    $styles = [Globalization.DateTimeStyles]::AssumeUniversal -bor [Globalization.DateTimeStyles]::AdjustToUniversal
    $dt = [DateTime]::ParseExact($d, 'r', [Globalization.CultureInfo]::InvariantCulture, $styles)
    $D = ($dt.Ticks - $script:EPOCH) / 1e7
    return @($t0, $t1, $D)
}

# 서버 시간은 초 단위로만 오기 때문에, 초가 바뀌는 순간을 노려서 여러 번 물어보며 오차를 줄입니다.
function Sync-Clock {
    $btnSync.Enabled = $false
    $url = $txtUrl.Text.Trim()
    if ($url -notmatch '^https?://') { $url = 'https://' + $url }
    $lblStatus.ForeColor = [System.Drawing.Color]::Khaki
    $lblStatus.Text = '서버 시간 맞추는 중... (약 10초)'
    $form.Refresh()
    $lo = [double]::NegativeInfinity
    $hi = [double]::PositiveInfinity
    $rtt = 0.1
    for ($i = 0; $i -lt 9; $i++) {
        if ($i -gt 0) {
            $c = ($lo + $hi) / 2
            $now = Get-LocalSec
            $tgt = [Math]::Ceiling($now + 0.4 + $c + $rtt / 2)
            $send = $tgt - $c - $rtt / 2
            while ((Get-LocalSec) -lt $send) {
                [System.Windows.Forms.Application]::DoEvents()
                Start-Sleep -Milliseconds 1
            }
        }
        try {
            $r = Get-ServerDate $url
        } catch {
            $lblStatus.ForeColor = [System.Drawing.Color]::Salmon
            $lblStatus.Text = '접속 실패: ' + $_.Exception.Message
            $btnSync.Enabled = $true
            return
        }
        $t0 = $r[0]; $t1 = $r[1]; $D = $r[2]
        $rtt = $t1 - $t0
        $nlo = $D - $t1
        $nhi = $D + 1 - $t0
        $lo2 = [Math]::Max($lo, $nlo)
        $hi2 = [Math]::Min($hi, $nhi)
        if ($lo2 -gt $hi2) { $lo = $nlo; $hi = $nhi } else { $lo = $lo2; $hi = $hi2 }
        $script:offset = ($lo + $hi) / 2
        $script:synced = $true
        [System.Windows.Forms.Application]::DoEvents()
    }
    $script:err = ($hi - $lo) / 2
    $sign = if ($script:offset -ge 0) { '+' } else { '' }
    $lblStatus.ForeColor = [System.Drawing.Color]::LightGreen
    $lblStatus.Text = ('맞춤 완료 · 내 PC보다 {0}{1:0.000}초 · 오차 ±{2:0.000}초  ({3})' -f $sign, $script:offset, $script:err, (Get-Date -Format 'HH:mm'))
    $btnSync.Enabled = $true
}

# ---------- 경기 목록 (경기목록.txt 파일에서 읽음) ----------
$script:dir = $PSScriptRoot
if (-not $script:dir) { $script:dir = Split-Path -Parent ([Diagnostics.Process]::GetCurrentProcess().MainModule.FileName) }
$script:listFile = Join-Path $script:dir '경기목록.txt'
$script:defaultNol = 'https://nol.yanolja.com/ticket/genre/sports/postseason'
$script:onlineUrl = 'https://raw.githubusercontent.com/SD980/server-clock/main/games.txt'
$script:defaultList = @'
# ===== 서버 시계 경기 목록 =====
# 한 줄에 경기 하나:  차전, 장소, 경기 일시, 예매 시작, 메모, 예매 주소
#   - 날짜는 2026-11-06 18:30 처럼 적습니다
#   - 메모와 예매 주소는 비워도 됩니다
#   - 줄 앞에 # 을 붙이면 그 줄은 무시합니다
# 아래 URL= 뒤에 온라인 목록 주소를 넣으면 [목록 업데이트]와 켤 때마다 그 주소에서 새 목록을 받아 옵니다.
URL=
# --- 2026 KBO 한국시리즈 (삼성 라이온즈 vs KT 위즈) 대구 경기 ---
3차전, 대구 삼성라이온즈파크, 2026-11-06 18:30, 2026-11-02 13:00, 매진, https://nol.yanolja.com/ticket/genre/sports/postseason
4차전, 대구 삼성라이온즈파크, 2026-11-07 14:00, 2026-11-02 14:00, 매진, https://nol.yanolja.com/ticket/genre/sports/postseason
5차전, 대구 삼성라이온즈파크, 2026-11-08 14:00, 2026-11-02 15:00, 매진, https://nol.yanolja.com/ticket/genre/sports/postseason
'@
$script:utf8bom = New-Object System.Text.UTF8Encoding($true)
function Ensure-ListFile {
    if (-not (Test-Path -LiteralPath $script:listFile)) {
        [IO.File]::WriteAllText($script:listFile, ($script:defaultList -replace "`r?`n", "`r`n"), $script:utf8bom)
    }
}
function Get-ListUrl([string]$text) {
    foreach ($ln in ($text -split "`r?`n")) {
        if ($ln.Trim() -match '^URL\s*=\s*(\S*)') { return $Matches[1] }
    }
    return ''
}
function Parse-Games([string]$text) {
    $list = New-Object System.Collections.ArrayList
    $inv = [Globalization.CultureInfo]::InvariantCulture
    $fmts = [string[]]@('yyyy-MM-dd HH:mm', 'yyyy-MM-dd H:mm', 'yyyy-MM-dd HH:mm:ss', 'yyyy-MM-dd H:mm:ss')
    foreach ($ln in ($text -split "`r?`n")) {
        $t = $ln.Trim()
        if ($t -eq '' -or $t.StartsWith('#') -or $t -match '^URL\s*=') { continue }
        $f = $t -split ','
        if ($f.Count -lt 4) { continue }
        $gd = [DateTime]::MinValue; $od = [DateTime]::MinValue
        if (-not [DateTime]::TryParseExact($f[2].Trim(), $fmts, $inv, [Globalization.DateTimeStyles]::None, [ref]$gd)) { continue }
        $hasOpen = [DateTime]::TryParseExact($f[3].Trim(), $fmts, $inv, [Globalization.DateTimeStyles]::None, [ref]$od)
        $memo = if ($f.Count -ge 5) { $f[4].Trim() } else { '' }
        $link = if ($f.Count -ge 6 -and $f[5].Trim() -match '^https?://') { $f[5].Trim() } else { $script:defaultNol }
        $null = $list.Add(@{ No = $f[0].Trim(); Place = $f[1].Trim(); GameDt = $gd; OpenDt = $(if ($hasOpen) { $od } else { $null }); Memo = $memo; Link = $link; Cancel = $gd.AddHours(-5) })
    }
    return ,$list
}
# 온라인 주소가 있으면 받아서 파일을 새로 고침. 결과 메시지를 돌려줌
function Update-ListFromWeb {
    Ensure-ListFile
    $local = [IO.File]::ReadAllText($script:listFile)
    $url = Get-ListUrl $local
    if (-not $url) { $url = $script:onlineUrl }
    if (-not $url) { return '' }
    try {
        $wc = New-Object System.Net.WebClient
        $wc.Encoding = [Text.Encoding]::UTF8
        $wc.Headers['User-Agent'] = 'ServerClock'
        $web = $wc.DownloadString($url)
    } catch {
        return '온라인 목록을 못 받았습니다 (인터넷 확인). 저장된 목록을 씁니다.'
    }
    $parsed = Parse-Games $web
    if ($parsed.Count -eq 0) { return '받아 온 목록에 경기가 없습니다. 저장된 목록을 씁니다.' }
    $lines = foreach ($ln in ($web -split "`r?`n")) { if ($ln.Trim() -match '^URL\s*=') { 'URL=' + $url } else { $ln } }
    $out = ($lines -join "`r`n")
    if ((Get-ListUrl $out) -eq '') { $out = 'URL=' + $url + "`r`n" + $out }
    [IO.File]::WriteAllText($script:listFile, $out, $script:utf8bom)
    return ('온라인 목록 업데이트 완료 · 경기 {0}개 ({1})' -f $parsed.Count, (Get-Date -Format 'MM-dd HH:mm'))
}
$ko = [Globalization.CultureInfo]::GetCultureInfo('ko-KR')
function Fmt-Kst([DateTime]$d) { return $d.ToString('MM/dd(ddd) HH:mm', $ko) }

# ---------- 화면 ----------
$bg = [System.Drawing.Color]::FromArgb(24, 26, 32)
$fg = [System.Drawing.Color]::White
$blue = [System.Drawing.Color]::FromArgb(64, 170, 255)

$form = New-Object System.Windows.Forms.Form
$form.SuspendLayout()
$form.AutoScaleDimensions = New-Object System.Drawing.SizeF(96, 96)
$form.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::Dpi
$g0 = $form.CreateGraphics(); $script:dpiK = $g0.DpiX / 96.0; $g0.Dispose()
$form.Text = '서버 시계 - 2026 KBO 한국시리즈 (삼성 라이온즈 vs KT 위즈) 대구 경기'
$form.ClientSize = New-Object System.Drawing.Size(700, 650)
$form.BackColor = $bg
$form.ForeColor = $fg
$form.FormBorderStyle = 'FixedSingle'
$form.MaximizeBox = $false
$form.StartPosition = 'CenterScreen'
$form.TopMost = $true
$form.Font = New-Object System.Drawing.Font('Malgun Gothic', 10)

function Add-Label($text, $x, $y, $w, $h) {
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $text
    $l.Location = New-Object System.Drawing.Point($x, $y)
    $l.Size = New-Object System.Drawing.Size($w, $h)
    $form.Controls.Add($l)
    return $l
}

$lblDate = Add-Label '' 16 10 668 24
$lblDate.ForeColor = [System.Drawing.Color]::Silver

$lblTime = Add-Label '--:--:--.---' 10 34 680 96
$lblTime.Font = New-Object System.Drawing.Font('Consolas', 58, [System.Drawing.FontStyle]::Bold)
$lblTime.ForeColor = $blue
$lblTime.TextAlign = 'MiddleCenter'

$lblStatus = Add-Label '시작하면 자동으로 서버 시간을 맞춥니다' 16 132 668 24
$lblStatus.ForeColor = [System.Drawing.Color]::Khaki

$null = Add-Label '사이트' 16 166 60 24
$txtUrl = New-Object System.Windows.Forms.TextBox
$txtUrl.Location = New-Object System.Drawing.Point(80, 163)
$txtUrl.Size = New-Object System.Drawing.Size(420, 26)
$txtUrl.Text = 'nol.yanolja.com'
$form.Controls.Add($txtUrl)

$btnSync = New-Object System.Windows.Forms.Button
$btnSync.Text = '서버 시간 다시 맞추기'
$btnSync.Location = New-Object System.Drawing.Point(510, 161)
$btnSync.Size = New-Object System.Drawing.Size(174, 30)
$btnSync.ForeColor = [System.Drawing.Color]::Black
$btnSync.BackColor = [System.Drawing.Color]::Gainsboro
$btnSync.Add_Click({ Sync-Clock })
$form.Controls.Add($btnSync)

# 경기 표
$lblGames = Add-Label '경기 목록 (줄을 누르면 알람이 맞춰집니다)' 16 200 400 24
$btnUpd = New-Object System.Windows.Forms.Button
$btnUpd.Text = '목록 업데이트'
$btnUpd.Location = New-Object System.Drawing.Point(420, 195)
$btnUpd.Size = New-Object System.Drawing.Size(130, 29)
$btnUpd.ForeColor = [System.Drawing.Color]::Black
$btnUpd.BackColor = [System.Drawing.Color]::Gainsboro
$form.Controls.Add($btnUpd)
$btnEdit = New-Object System.Windows.Forms.Button
$btnEdit.Text = '목록 편집'
$btnEdit.Location = New-Object System.Drawing.Point(556, 195)
$btnEdit.Size = New-Object System.Drawing.Size(128, 29)
$btnEdit.ForeColor = [System.Drawing.Color]::Black
$btnEdit.BackColor = [System.Drawing.Color]::Gainsboro
$form.Controls.Add($btnEdit)
$lblGames.ForeColor = [System.Drawing.Color]::Silver

$lv = New-Object System.Windows.Forms.ListView
$lv.Location = New-Object System.Drawing.Point(16, 226)
$lv.Size = New-Object System.Drawing.Size(670, 112)
$lv.View = 'Details'
$lv.FullRowSelect = $true
$lv.HideSelection = $false
$lv.MultiSelect = $false
$lv.BackColor = [System.Drawing.Color]::FromArgb(36, 39, 48)
$lv.ForeColor = $fg
$null = $lv.Columns.Add('차전', [int](55 * $script:dpiK))
$null = $lv.Columns.Add('장소', [int](165 * $script:dpiK))
$null = $lv.Columns.Add('경기 일시', [int](115 * $script:dpiK))
$null = $lv.Columns.Add('예매 시작', [int](130 * $script:dpiK))
$null = $lv.Columns.Add('취소표 마감', [int](115 * $script:dpiK))
$null = $lv.Columns.Add('예매', [int](75 * $script:dpiK))
$form.Controls.Add($lv)
$lv.Add_MouseClick({
    param($sender, $e)
    $hit = $lv.HitTest($e.Location)
    if ($hit.Item -and $hit.SubItem -and $hit.Item.SubItems.IndexOf($hit.SubItem) -eq 5) {
        Start-Process $hit.Item.Tag.Link
    }
})

# 알람 대상
$null = Add-Label '알람 맞출 시간' 16 347 110 24
$cmb = New-Object System.Windows.Forms.ComboBox
$cmb.DropDownStyle = 'DropDownList'
$cmb.Location = New-Object System.Drawing.Point(130, 344)
$cmb.Size = New-Object System.Drawing.Size(320, 26)
$script:choices = New-Object System.Collections.ArrayList
$form.Controls.Add($cmb)

$txtTarget = New-Object System.Windows.Forms.TextBox
$txtTarget.Location = New-Object System.Drawing.Point(460, 344)
$txtTarget.Size = New-Object System.Drawing.Size(224, 26)
$form.Controls.Add($txtTarget)
$lblHint = Add-Label '직접 입력 예) 2026-11-07 09:00:00  또는  14:00:00 (오늘)' 130 374 554 22
$lblHint.ForeColor = [System.Drawing.Color]::Gray

$cmb.Add_SelectedIndexChanged({
    $c = $script:choices[$cmb.SelectedIndex]
    if ($c.When) { $txtTarget.Text = $c.When.ToString('yyyy-MM-dd HH:mm:ss') }
})
$lv.Add_SelectedIndexChanged({
    if ($lv.SelectedItems.Count -eq 0) { return }
    $g = $lv.SelectedItems[0].Tag
    for ($i = 0; $i -lt $script:choices.Count; $i++) {
        if ($script:choices[$i].When -eq $g.Cancel) { $cmb.SelectedIndex = $i; break }
    }
})

function Fit-List {
    $need = 0
    for ($ci = 0; $ci -lt $lv.Columns.Count; $ci++) {
        $col = $lv.Columns[$ci]
        $w = [System.Windows.Forms.TextRenderer]::MeasureText($col.Text, $lv.Font).Width
        foreach ($it in $lv.Items) {
            $sub = $it.SubItems[$ci]
            $f = if ($sub.Font) { $sub.Font } else { $lv.Font }
            $tw = [System.Windows.Forms.TextRenderer]::MeasureText($sub.Text, $f).Width
            if ($tw -gt $w) { $w = $tw }
        }
        $col.Width = $w + [int](22 * $script:dpiK)
        $need += $col.Width
    }
    $need += [System.Windows.Forms.SystemInformation]::VerticalScrollBarWidth + 6
    $extra = $need - $lv.ClientSize.Width
    if ($extra -gt 0) {
        $lv.Width += $extra; $form.Width += $extra; $lblTime.Width += $extra; $lblCount.Width += $extra
    }
    if ($lv.Items.Count -gt 0) {
        $r = $lv.GetItemRect(0)
        $rows = [Math]::Min([Math]::Max($lv.Items.Count, 3), 8)
        $dy = ($rows * $r.Height + $r.Top + 6) - $lv.ClientSize.Height
        if ($dy -ne 0) {
            foreach ($c in $form.Controls) { if ($c.Top -gt $lv.Top) { $c.Top += $dy } }
            $lv.Height += $dy
            $form.Height += $dy
        }
    }
}
function Fill-Games {
    Ensure-ListFile
    $script:games = Parse-Games ([IO.File]::ReadAllText($script:listFile))
    $lv.BeginUpdate()
    $lv.Items.Clear()
    $linkFont = New-Object System.Drawing.Font('Malgun Gothic', 10, [System.Drawing.FontStyle]::Underline)
    foreach ($g in $script:games) {
        $item = New-Object System.Windows.Forms.ListViewItem($g.No)
        $null = $item.SubItems.Add($g.Place)
        $null = $item.SubItems.Add((Fmt-Kst $g.GameDt))
        $open = if ($g.OpenDt) { Fmt-Kst $g.OpenDt } else { '미정' }
        if ($g.Memo) { $open += ' (' + $g.Memo + ')' }
        $null = $item.SubItems.Add($open)
        $null = $item.SubItems.Add((Fmt-Kst $g.Cancel))
        $item.UseItemStyleForSubItems = $false
        $sub = $item.SubItems.Add('▶ NOL 열기')
        $sub.ForeColor = $blue
        $sub.Font = $linkFont
        $item.Tag = $g
        $null = $lv.Items.Add($item)
    }
    $lv.EndUpdate()
    $keep = $txtTarget.Text
    $script:choices.Clear()
    $cmb.Items.Clear()
    $null = $script:choices.Add(@{ Text = '직접 입력'; When = $null })
    foreach ($g in $script:games) {
        if ($g.OpenDt) { $null = $script:choices.Add(@{ Text = $g.No + ' ' + $g.Place.Split(' ')[0] + ' 예매 시작 ' + (Fmt-Kst $g.OpenDt); When = $g.OpenDt }) }
        $null = $script:choices.Add(@{ Text = $g.No + ' ' + $g.Place.Split(' ')[0] + ' 취소표 마감 ' + (Fmt-Kst $g.Cancel); When = $g.Cancel })
        $null = $script:choices.Add(@{ Text = $g.No + ' ' + $g.Place.Split(' ')[0] + ' 경기 시작 ' + (Fmt-Kst $g.GameDt); When = $g.GameDt })
    }
    foreach ($c in $script:choices) { $null = $cmb.Items.Add($c.Text) }
    # 가장 가까운 앞으로의 시간 자동 선택
    $now = [DateTime]::UtcNow.AddHours(9)
    $best = -1
    for ($i = 1; $i -lt $script:choices.Count; $i++) {
        $w = $script:choices[$i].When
        if ($w -gt $now -and ($best -lt 0 -or $w -lt $script:choices[$best].When)) { $best = $i }
    }
    if ($best -gt 0) { $cmb.SelectedIndex = $best } else { $cmb.SelectedIndex = 0; $txtTarget.Text = $keep }
    Fit-List
}
$btnUpd.Add_Click({
    $btnUpd.Enabled = $false
    $msg = Update-ListFromWeb
    Fill-Games
    if (-not $msg) { $msg = "경기목록.txt 파일을 다시 읽었습니다.`r`n경기 " + $script:games.Count + "개`r`n`r`n(온라인 주소가 없어서 내 컴퓨터의 파일만 읽었습니다)" }
    $lblGames.Text = '경기 목록 (줄을 누르면 알람이 맞춰집니다)'
    $null = [System.Windows.Forms.MessageBox]::Show($form, $msg, '목록 업데이트')
    $btnUpd.Enabled = $true
})
$btnEdit.Add_Click({
    Ensure-ListFile
    Start-Process notepad.exe -ArgumentList ('"' + $script:listFile + '"')
    $lblGames.Text = '메모장에서 저장 후 [목록 업데이트]'
})

$lblCount = Add-Label '' 16 400 668 48
$lblCount.Font = New-Object System.Drawing.Font('Malgun Gothic', 20, [System.Drawing.FontStyle]::Bold)
$lblCount.TextAlign = 'MiddleCenter'

# 알람 설정 (자동 크기로 글씨가 잘리지 않게)
function New-Row($y) {
    $p = New-Object System.Windows.Forms.FlowLayoutPanel
    $p.Location = New-Object System.Drawing.Point(16, $y)
    $p.Size = New-Object System.Drawing.Size(668, 34)
    $p.WrapContents = $false
    $p.FlowDirection = 'LeftToRight'
    $form.Controls.Add($p)
    return $p
}
function Add-RowLabel($row, $text, $w) {
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $text
    $l.AutoSize = $false
    $l.Size = New-Object System.Drawing.Size($w, 26)
    $l.TextAlign = 'MiddleLeft'
    $l.ForeColor = [System.Drawing.Color]::Silver
    $row.Controls.Add($l)
}
function Add-RowCheck($row, $text, $on) {
    $c = New-Object System.Windows.Forms.CheckBox
    $c.Text = $text
    $c.Checked = $on
    $c.AutoSize = $true
    $c.Margin = New-Object System.Windows.Forms.Padding(3, 5, 18, 3)
    $row.Controls.Add($c)
    return $c
}

$row1 = New-Row 456
Add-RowLabel $row1 '미리 알림 소리' 130
$chk3 = Add-RowCheck $row1 '3분 전' $false
$chk2 = Add-RowCheck $row1 '2분 전' $true
$chk1 = Add-RowCheck $row1 '1분 전' $true

$row2 = New-Row 492
Add-RowLabel $row2 '카운트다운 소리' 130
$cmbSec = New-Object System.Windows.Forms.ComboBox
$cmbSec.DropDownStyle = 'DropDownList'
$cmbSec.Size = New-Object System.Drawing.Size(250, 26)
$cmbSec.Margin = New-Object System.Windows.Forms.Padding(3, 2, 24, 3)
$script:secOpts = @(0, 5, 10, 20, 30, 60)
foreach ($o in $script:secOpts) { if ($o -eq 0) { $null = $cmbSec.Items.Add('안 씀') } else { $null = $cmbSec.Items.Add('정각 ' + [string]$o + '초 전부터 1초마다 삐') } }
$cmbSec.SelectedIndex = 2
$row2.Controls.Add($cmbSec)
$chk0 = Add-RowCheck $row2 '정각에 긴 소리' $true

$row3 = New-Row 528
Add-RowLabel $row3 '기타' 130
$chkTop = Add-RowCheck $row3 '항상 맨 위에' $true
$chkTop.Add_CheckedChanged({ $form.TopMost = $chkTop.Checked })
$btnTest = New-Object System.Windows.Forms.Button
$btnTest.Text = '알람 소리 듣기'
$btnTest.AutoSize = $true
$btnTest.ForeColor = [System.Drawing.Color]::Black
$btnTest.BackColor = [System.Drawing.Color]::Gainsboro
$btnTest.Add_Click({ $script:sndMin.Play() })
$row3.Controls.Add($btnTest)

$lblFoot = New-Object System.Windows.Forms.Label
$lblFoot.Location = New-Object System.Drawing.Point(16, 574)
$lblFoot.AutoSize = $true
$lblFoot.MaximumSize = New-Object System.Drawing.Size(668, 0)
$lblFoot.ForeColor = [System.Drawing.Color]::Gray
$lblFoot.Font = New-Object System.Drawing.Font('Malgun Gothic', 9)
$lblFoot.Text = "※ 취소표 마감 = 경기 5시간 전 (온라인 취소 마감 시간)`r`n※ 현장 매표소는 경기 2시간 전부터 엽니다`r`n※ 이 프로그램은 시간만 알려 줍니다. 예매 버튼은 직접 누르세요"
$form.Controls.Add($lblFoot)

# ---------- 알람 시간 계산 ----------
$script:K9 = 9 * 36000000000
function Update-Target([double]$serverSec) {
    $txt = $txtTarget.Text.Trim()
    if ($txt -eq $script:targetText -and $script:targetSec -ne $null) { return }
    $script:targetText = $txt
    $script:lastK = $null
    $script:targetSec = $null
    if ($txt -eq '') { return }
    $inv = [Globalization.CultureInfo]::InvariantCulture
    $d = [DateTime]::MinValue
    $full = [string[]]@('yyyy-MM-dd HH:mm:ss', 'yyyy-MM-dd H:mm:ss', 'yyyy-MM-dd HH:mm', 'yyyy-MM-dd H:mm')
    if ([DateTime]::TryParseExact($txt, $full, $inv, [Globalization.DateTimeStyles]::None, [ref]$d)) {
        $script:targetSec = ($d.Ticks - $script:K9 - $script:EPOCH) / 1e7
        return
    }
    $t = [TimeSpan]::Zero
    $fmts = [string[]]@('h\:mm\:ss', 'hh\:mm\:ss', 'h\:mm', 'hh\:mm')
    if ([TimeSpan]::TryParseExact($txt, $fmts, $inv, [ref]$t)) {
        $kstNow = New-Object DateTime ([long]($script:EPOCH + $serverSec * 1e7 + $script:K9))
        $sec = (($kstNow.Date.Add($t)).Ticks - $script:K9 - $script:EPOCH) / 1e7
        if ($sec -lt $serverSec - 120) { $sec += 86400 }
        $script:targetSec = $sec
    }
}

function Format-Remain([double]$rem) {
    $ts = [TimeSpan]::FromSeconds($rem)
    if ($ts.TotalDays -ge 1) { return ('{0}일 {1}시간 {2:00}분 {3:00}초' -f [int][Math]::Floor($ts.TotalDays), $ts.Hours, $ts.Minutes, $ts.Seconds) }
    if ($ts.TotalHours -ge 1) { return ('{0}시간 {1:00}분 {2:00}초' -f [int][Math]::Floor($ts.TotalHours), $ts.Minutes, $ts.Seconds) }
    return ('{0:00}:{1:00}.{2}' -f $ts.Minutes, $ts.Seconds, [int][Math]::Floor($ts.Milliseconds / 100))
}

# ---------- 매 순간 갱신 ----------
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 15
$timer.Add_Tick({
    $s = (Get-LocalSec) + $script:offset
    $kst = New-Object DateTime ([long]($script:EPOCH + $s * 1e7 + $script:K9))
    $lblTime.Text = $kst.ToString('HH:mm:ss.fff')
    $src = if ($script:synced) { $txtUrl.Text.Trim() + ' 서버 기준' } else { '내 PC 시계 (아직 서버와 안 맞춤)' }
    $lblDate.Text = $kst.ToString('yyyy-MM-dd (ddd)', $ko) + '   ·   ' + $src

    Update-Target $s
    if ($script:targetSec -eq $null) {
        $lblCount.ForeColor = [System.Drawing.Color]::Gray
        $lblCount.Text = '위 표에서 경기를 누르거나 알람 시간을 입력하세요'
        $lblTime.ForeColor = $blue
        return
    }
    $rem = $script:targetSec - $s
    if ($rem -gt 10) {
        $lblCount.ForeColor = [System.Drawing.Color]::White
        $lblCount.Text = '남은 시간  ' + (Format-Remain $rem)
        $lblTime.ForeColor = $blue
    } elseif ($rem -gt 0.6) {
        $lblCount.ForeColor = [System.Drawing.Color]::Orange
        $lblCount.Text = '곧입니다!  ' + (Format-Remain $rem)
        $lblTime.ForeColor = [System.Drawing.Color]::Orange
    } elseif ($rem -gt -3) {
        $lblCount.ForeColor = [System.Drawing.Color]::Lime
        $lblCount.Text = '▶ 지금입니다!'
        $lblTime.ForeColor = [System.Drawing.Color]::Lime
    } else {
        $lblCount.ForeColor = [System.Drawing.Color]::Gray
        $lblCount.Text = '설정한 시간이 지났습니다'
        $lblTime.ForeColor = $blue
    }

    $k = [int][Math]::Ceiling($rem)
    if ($script:lastK -ne $null -and $k -ne $script:lastK) {
        if (($k -eq 180 -and $chk3.Checked) -or ($k -eq 120 -and $chk2.Checked) -or ($k -eq 60 -and $chk1.Checked)) { $script:sndMin.Play() }
        elseif ($k -ge 1 -and $k -le $script:secOpts[$cmbSec.SelectedIndex]) { $script:sndTick.Play() }
        elseif ($k -eq 0 -and $chk0.Checked) { $script:sndFinal.Play() }
    }
    $script:lastK = $k
})

# 처음에는 다음에 올 취소표 마감 시간을 자동 선택
$form.Add_Shown({
    $msg = Update-ListFromWeb
    Fill-Games
    if ($msg -and $msg -notlike '*완료*') { $lblGames.Text = '온라인 목록 받기 실패 · 저장된 목록 사용' }
    $timer.Start()
    Sync-Clock
})
$form.ResumeLayout($true)
$form.Add_FormClosing({ $timer.Stop() })
[System.Windows.Forms.Application]::Run($form)
