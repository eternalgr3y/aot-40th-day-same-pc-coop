# Classify an Army of Two/Xenia frame from either a live process window or a PNG fixture.
[CmdletBinding()]
param(
  [int]$ProcId = 0,
  [string]$ImagePath = ''
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'tools\runtime\aot_top_level_window.ps1')

$hasProcId = $ProcId -gt 0
$hasImagePath = -not [string]::IsNullOrWhiteSpace($ImagePath)
if ($hasProcId -eq $hasImagePath) {
  throw 'Specify exactly one of -ProcId or -ImagePath.'
}

Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Runtime.WindowsRuntime

$null = [Windows.Storage.StorageFile, Windows.Storage, ContentType = WindowsRuntime]
$null = [Windows.Storage.Streams.IRandomAccessStream, Windows.Storage.Streams, ContentType = WindowsRuntime]
$null = [Windows.Graphics.Imaging.BitmapDecoder, Windows.Graphics.Imaging, ContentType = WindowsRuntime]
$null = [Windows.Graphics.Imaging.SoftwareBitmap, Windows.Graphics.Imaging, ContentType = WindowsRuntime]
$null = [Windows.Media.Ocr.OcrEngine, Windows.Foundation, ContentType = WindowsRuntime]
$null = [Windows.Media.Ocr.OcrResult, Windows.Foundation, ContentType = WindowsRuntime]

if (-not ('WCls' -as [type])) {
  Add-Type @"
using System;
using System.Runtime.InteropServices;
public class WCls {
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h, IntPtr dc, uint flags);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
}
"@
}

function Await-WinRt($Operation, [Type]$ResultType) {
  $method = [System.WindowsRuntimeSystemExtensions].GetMethods() |
    Where-Object { $_.Name -eq 'AsTask' -and $_.IsGenericMethod -and $_.GetParameters().Count -eq 1 } |
    Select-Object -First 1
  $task = $method.MakeGenericMethod($ResultType).Invoke($null, @($Operation))
  $task.Wait()
  $task.Result
}

$script:OcrEngine = [Windows.Media.Ocr.OcrEngine]::TryCreateFromUserProfileLanguages()
if ($null -eq $script:OcrEngine) {
  throw 'Windows OCR is unavailable for the current user profile languages.'
}

function Get-OcrText([string]$Path) {
  $stream = $null
  $softwareBitmap = $null
  try {
    $file = Await-WinRt ([Windows.Storage.StorageFile]::GetFileFromPathAsync($Path)) ([Windows.Storage.StorageFile])
    $stream = Await-WinRt ($file.OpenAsync([Windows.Storage.FileAccessMode]::Read)) ([Windows.Storage.Streams.IRandomAccessStream])
    $decoder = Await-WinRt ([Windows.Graphics.Imaging.BitmapDecoder]::CreateAsync($stream)) ([Windows.Graphics.Imaging.BitmapDecoder])
    $softwareBitmap = Await-WinRt ($decoder.GetSoftwareBitmapAsync()) ([Windows.Graphics.Imaging.SoftwareBitmap])
    $result = Await-WinRt ($script:OcrEngine.RecognizeAsync($softwareBitmap)) ([Windows.Media.Ocr.OcrResult])
    $result.Text.ToUpperInvariant()
  } finally {
    if ($null -ne $softwareBitmap) { $softwareBitmap.Dispose() }
    if ($null -ne $stream) { $stream.Dispose() }
  }
}

function Get-FrameMetrics($Bitmap) {
  $x0 = [int]($Bitmap.Width * 0.18)
  $x1 = [int]($Bitmap.Width * 0.80)
  $y0 = [int]($Bitmap.Height * 0.30)
  $y1 = [int]($Bitmap.Height * 0.62)
  $bright = 0
  $total = 0
  $redSum = 0.0
  $greenSum = 0.0
  $blueSum = 0.0
  $lumSum = 0.0
  $lumSquareSum = 0.0

  for ($y = $y0; $y -lt $y1; $y += 3) {
    for ($x = $x0; $x -lt $x1; $x += 3) {
      $color = $Bitmap.GetPixel($x, $y)
      $luminance = (0.2126 * $color.R) + (0.7152 * $color.G) + (0.0722 * $color.B)
      $total++
      $redSum += $color.R
      $greenSum += $color.G
      $blueSum += $color.B
      $lumSum += $luminance
      $lumSquareSum += $luminance * $luminance
      if (($color.R + $color.G + $color.B) -ge 360) { $bright++ }
    }
  }

  $avgR = $redSum / $total
  $avgG = $greenSum / $total
  $avgB = $blueSum / $total
  $avgLum = $lumSum / $total
  $variance = [math]::Max(0.0, ($lumSquareSum / $total) - ($avgLum * $avgLum))
  [pscustomobject]@{
    BrightPct = 100.0 * $bright / $total
    AvgR = $avgR
    AvgG = $avgG
    AvgB = $avgB
    RedDom = $avgR - (($avgG + $avgB) / 2.0)
    LumStd = [math]::Sqrt($variance)
  }
}

function Get-GameViewport($Bitmap) {
  $left = 8
  $width = [math]::Max(1, $Bitmap.Width - 16)
  $height = [int][math]::Round($width * 9.0 / 16.0)
  if ($height -gt $Bitmap.Height) { $height = $Bitmap.Height }
  $top = [int][math]::Round(50.0 + (($Bitmap.Height - 50.0 - $height) / 2.0))
  $top = [math]::Max(0, [math]::Min($Bitmap.Height - $height, $top))
  [pscustomobject]@{ Left = $left; Top = $top; Width = $width; Height = $height }
}

function Get-CroppedOcrText($Bitmap, [double]$X, [double]$Y, [double]$Width, [double]$Height) {
  $crop = $null
  $scaled = $null
  $graphics = $null
  $memory = $null
  $randomAccess = $null
  $softwareBitmap = $null
  try {
    $left = [int]($script:Viewport.Left + ($script:Viewport.Width * $X))
    $top = [int]($script:Viewport.Top + ($script:Viewport.Height * $Y))
    $cropWidth = [math]::Min([int]($script:Viewport.Width * $Width), $Bitmap.Width - $left)
    $cropHeight = [math]::Min([int]($script:Viewport.Height * $Height), $Bitmap.Height - $top)
    $rectangle = [System.Drawing.Rectangle]::new($left, $top, $cropWidth, $cropHeight)
    $crop = $Bitmap.Clone($rectangle, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $scaled = [System.Drawing.Bitmap]::new($cropWidth * 3, $cropHeight * 3)
    $graphics = [System.Drawing.Graphics]::FromImage($scaled)
    $graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $graphics.DrawImage($crop, 0, 0, $scaled.Width, $scaled.Height)
    $graphics.Dispose()
    $graphics = $null

    $memory = [System.IO.MemoryStream]::new()
    $scaled.Save($memory, [System.Drawing.Imaging.ImageFormat]::Png)
    $memory.Position = 0
    $randomAccess = [System.IO.WindowsRuntimeStreamExtensions]::AsRandomAccessStream($memory)
    $decoder = Await-WinRt ([Windows.Graphics.Imaging.BitmapDecoder]::CreateAsync($randomAccess)) ([Windows.Graphics.Imaging.BitmapDecoder])
    $softwareBitmap = Await-WinRt ($decoder.GetSoftwareBitmapAsync()) ([Windows.Graphics.Imaging.SoftwareBitmap])
    $result = Await-WinRt ($script:OcrEngine.RecognizeAsync($softwareBitmap)) ([Windows.Media.Ocr.OcrResult])
    ($result.Text -replace '\s+', ' ').ToUpperInvariant()
  } finally {
    if ($null -ne $softwareBitmap) { $softwareBitmap.Dispose() }
    if ($null -ne $randomAccess) { $randomAccess.Dispose() }
    if ($null -ne $memory) { $memory.Dispose() }
    if ($null -ne $graphics) { $graphics.Dispose() }
    if ($null -ne $scaled) { $scaled.Dispose() }
    if ($null -ne $crop) { $crop.Dispose() }
  }
}

function Get-StyleSelection($Bitmap) {
  $rows = @(0.470, 0.515, 0.557, 0.598)
  $states = @('STYLE_SOLO', 'STYLE_SPLIT', 'STYLE_PRIVATE', 'STYLE_PUBLIC')
  $scores = @()

  foreach ($row in $rows) {
    $dark = 0
    $total = 0
    $x0 = [int]($Bitmap.Width * 0.30)
    $x1 = [int]($Bitmap.Width * 0.70)
    $y0 = [int]($Bitmap.Height * ($row - 0.010))
    $y1 = [int]($Bitmap.Height * ($row + 0.010))
    for ($y = $y0; $y -le $y1; $y++) {
      for ($x = $x0; $x -le $x1; $x += 2) {
        $color = $Bitmap.GetPixel($x, $y)
        $luminance = (0.2126 * $color.R) + (0.7152 * $color.G) + (0.0722 * $color.B)
        $total++
        if ($luminance -lt 65) { $dark++ }
      }
    }
    $scores += 100.0 * $dark / $total
  }

  $selected = 0
  for ($index = 1; $index -lt $scores.Count; $index++) {
    if ($scores[$index] -gt $scores[$selected]) { $selected = $index }
  }
  $script:StyleDiagnostics = 'styleRow={0};styleDark={1}' -f $selected, (($scores | ForEach-Object { '{0:F1}' -f $_ }) -join ',')
  $states[$selected]
}

function Get-SlotSelection($Bitmap, [bool]$AllowRawFallback) {
  # The normalized classifier window uses a wider carousel layout than the
  # older retained fixtures. Windows display scaling can expose the same layout
  # from 960x640 through roughly 1061x692. Its selected middle card is raised
  # and has a long neutral top border; unselected cards start lower.
  # When the selected right card is raised, the authored carousel clips most of
  # it beyond the viewport but leaves a measured ~98-pixel neutral top edge at
  # x~=858..959. Detect those two allowlisted targets before the conservative
  # entry fallback.
  if ($Bitmap.Width -ge 900 -and $Bitmap.Width -le 1100 -and
      $Bitmap.Height -ge 600 -and $Bitmap.Height -le 720) {
    $rightTopBest = 0
    $rightTopDropBest = 0
    for ($y = [int]($Bitmap.Height * 0.44);
      $y -le [int]($Bitmap.Height * 0.475); $y++) {
      $neutral = 0
      $drop = 0
      for ($x = [int]($Bitmap.Width * 0.89);
        $x -le [int]($Bitmap.Width * 0.995); $x += 2) {
        $color = $Bitmap.GetPixel($x, $y)
        $maximum = [math]::Max($color.R, [math]::Max($color.G, $color.B))
        $minimum = [math]::Min($color.R, [math]::Min($color.G, $color.B))
        if ($minimum -ge 140 -and ($maximum - $minimum) -le 55) {
          $neutral++
          $below = $Bitmap.GetPixel($x, [math]::Min($Bitmap.Height - 1, $y + 10))
          $topLuminance = (0.2126 * $color.R) + (0.7152 * $color.G) + (0.0722 * $color.B)
          $belowLuminance = (0.2126 * $below.R) + (0.7152 * $below.G) + (0.0722 * $below.B)
          if (($topLuminance - $belowLuminance) -ge 60) { $drop++ }
        }
      }
      if ($neutral -gt $rightTopBest -or
          ($neutral -eq $rightTopBest -and $drop -gt $rightTopDropBest)) {
        $rightTopBest = $neutral
        $rightTopDropBest = $drop
      }
    }
    if ($rightTopBest -ge 40 -and $rightTopDropBest -ge 35) {
      $script:SlotIndex = 2
      $script:SlotDetected = $true
      $script:SlotAnyBorder = $true
      $script:SlotDiagnostics = "slotMode=classifier960-right;slot=2;rightTop=$rightTopBest;rightDrop=$rightTopDropBest"
      return 'SAVE_SLOT_2'
    }

    $middleTopBest = 0
    for ($y = [int]($Bitmap.Height * 0.44);
      $y -le [int]($Bitmap.Height * 0.475); $y++) {
      $neutral = 0
      for ($x = [int]($Bitmap.Width * 0.606);
        $x -le [int]($Bitmap.Width * 0.895); $x += 2) {
        $color = $Bitmap.GetPixel($x, $y)
        $maximum = [math]::Max($color.R, [math]::Max($color.G, $color.B))
        $minimum = [math]::Min($color.R, [math]::Min($color.G, $color.B))
        if ($minimum -ge 140 -and ($maximum - $minimum) -le 55) { $neutral++ }
      }
      if ($neutral -gt $middleTopBest) { $middleTopBest = $neutral }
    }
    if ($middleTopBest -ge 80) {
      $script:SlotIndex = 1
      $script:SlotDetected = $true
      $script:SlotAnyBorder = $true
      $script:SlotDiagnostics = "slotMode=classifier960;slot=1;middleTop=$middleTopBest"
      return 'SAVE_SLOT_1'
    }
  }

  $centers = @(0.31, 0.50, 0.69)
  $borderRows = @()
  $borderStrengths = @()
  $rawBorderRows = @()
  $rawBorderStrengths = @()

  foreach ($center in $centers) {
    $x0 = [int]($script:Viewport.Left + ($script:Viewport.Width * ($center - 0.065)))
    $x1 = [int]($script:Viewport.Left + ($script:Viewport.Width * ($center + 0.065)))
    $bestY = [int]($script:Viewport.Top + ($script:Viewport.Height * 0.27))
    $bestWhite = -1
    $bestRawY = $bestY
    $bestRawNeutral = -1
    for ($y = [int]($script:Viewport.Top + ($script:Viewport.Height * 0.19));
      $y -le [int]($script:Viewport.Top + ($script:Viewport.Height * 0.27)); $y++) {
      $white = 0
      $rawNeutral = 0
      for ($x = $x0; $x -le $x1; $x++) {
        $color = $Bitmap.GetPixel($x, $y)
        $maximum = [math]::Max($color.R, [math]::Max($color.G, $color.B))
        $minimum = [math]::Min($color.R, [math]::Min($color.G, $color.B))
        if ($minimum -ge 170 -and ($maximum - $minimum) -le 55) { $white++ }
        if ($minimum -ge 140 -and ($maximum - $minimum) -le 55) { $rawNeutral++ }
      }
      if ($white -gt $bestWhite) {
        $bestWhite = $white
        $bestY = $y
      }
      if ($rawNeutral -gt $bestRawNeutral) {
        $bestRawNeutral = $rawNeutral
        $bestRawY = $y
      }
    }
    $borderRows += ($bestY - $script:Viewport.Top) / [double]$script:Viewport.Height
    $borderStrengths += $bestWhite / [double](($x1 - $x0) + 1)
    $rawBorderRows += ($bestRawY - $script:Viewport.Top) / [double]$script:Viewport.Height
    $rawBorderStrengths += $bestRawNeutral / [double](($x1 - $x0) + 1)
  }

  $strong = @(0..2 | Where-Object { $borderStrengths[$_] -ge 0.75 })
  $rawStrong = @(0..2 | Where-Object { $rawBorderStrengths[$_] -ge 0.90 })
  $rawOrdered = @($rawBorderStrengths | Sort-Object -Descending)
  # The small CJ window renders the selected border at about 143/255 in a raw
  # PrintWindow frame.  Permit that low-light signature only when save-screen
  # OCR independently authorizes it and the 170 primary detector found no
  # candidate; one dominant neutral line avoids turning scene texture into a
  # selectable slot.
  $useRawFallback = $AllowRawFallback -and $strong.Count -eq 0 -and
    $rawStrong.Count -eq 1 -and $rawOrdered[1] -lt 0.70
  $activeBorderRows = $borderRows
  $activeBorderStrengths = $borderStrengths
  if ($useRawFallback) {
    $selected = $rawStrong[0]
    $activeBorderRows = $rawBorderRows
    $activeBorderStrengths = $rawBorderStrengths
  } elseif ($strong.Count -eq 1) {
    $selected = $strong[0]
  } elseif ($strong.Count -gt 1) {
    $selected = $strong[0]
    foreach ($index in $strong) {
      if ($borderRows[$index] -lt $borderRows[$selected]) { $selected = $index }
    }
  } else {
    $selected = 0
    for ($index = 1; $index -lt $borderStrengths.Count; $index++) {
      if ($borderStrengths[$index] -gt $borderStrengths[$selected]) { $selected = $index }
    }
  }
  $script:SlotIndex = $selected
  $script:SlotDetected = $strong.Count -ge 2
  $script:SlotAnyBorder = $strong.Count -ge 1 -or $useRawFallback
  $modeDiagnostics = if ($useRawFallback) { 'slotMode=raw140;' } else { '' }
  $script:SlotDiagnostics = '{0}slot={1};slotTop={2};slotBorder={3}' -f $modeDiagnostics, $selected,
    (($activeBorderRows | ForEach-Object { '{0:F3}' -f $_ }) -join ','),
    (($activeBorderStrengths | ForEach-Object { '{0:F2}' -f $_ }) -join ',')
  @('SAVE_SLOT_0', 'SAVE_SLOT_1', 'SAVE_SLOT_2')[$selected]
}

function Get-SaveOptionsSelection($Bitmap) {
  $optionCenter = @(0.31, 0.50, 0.69)[$script:SlotIndex]
  $rows = @(0.645, 0.695, 0.742)
  $scoreSets = @()
  foreach ($radius in @(0.09, 0.10)) {
    $scores = @()
    foreach ($row in $rows) {
      $inside = 0.0
      $insideCount = 0
      $outside = 0.0
      $outsideCount = 0
      foreach ($sign in @(-1.0, 1.0)) {
        $insideCenter = $optionCenter + ($sign * $radius)
        $outsideCenter = $optionCenter + ($sign * ($radius + 0.025))
        for ($y = [int]($script:Viewport.Top + ($script:Viewport.Height * ($row - 0.012)));
          $y -le [int]($script:Viewport.Top + ($script:Viewport.Height * ($row + 0.012))); $y++) {
          for ($x = [int]($script:Viewport.Left + ($script:Viewport.Width * ($insideCenter - 0.008)));
            $x -le [int]($script:Viewport.Left + ($script:Viewport.Width * ($insideCenter + 0.008))); $x += 2) {
            $color = $Bitmap.GetPixel($x, $y)
            $inside += (0.2126 * $color.R) + (0.7152 * $color.G) + (0.0722 * $color.B)
            $insideCount++
          }
          for ($x = [int]($script:Viewport.Left + ($script:Viewport.Width * ($outsideCenter - 0.008)));
            $x -le [int]($script:Viewport.Left + ($script:Viewport.Width * ($outsideCenter + 0.008))); $x += 2) {
            $color = $Bitmap.GetPixel($x, $y)
            $outside += (0.2126 * $color.R) + (0.7152 * $color.G) + (0.0722 * $color.B)
            $outsideCount++
          }
        }
      }
      $scores += ($outside / $outsideCount) - ($inside / $insideCount)
    }
    $scoreSets += ,$scores
  }

  $nearScores = $scoreSets[0]
  $farScores = $scoreSets[1]
  $nearWinner = 0
  $farWinner = 0
  for ($index = 1; $index -lt 3; $index++) {
    if ($nearScores[$index] -gt $nearScores[$nearWinner]) { $nearWinner = $index }
    if ($farScores[$index] -gt $farScores[$farWinner]) { $farWinner = $index }
  }
  $nearOrdered = @($nearScores | Sort-Object -Descending)
  $farOrdered = @($farScores | Sort-Object -Descending)
  $nearMargin = $nearOrdered[0] - $nearOrdered[1]
  $farMargin = $farOrdered[0] - $farOrdered[1]

  $selected = -1
  if ($nearWinner -eq 2 -and $nearMargin -ge 3.5) {
    $selected = 2
  } elseif ($farWinner -eq 0 -and $farMargin -ge 4.0) {
    $selected = 0
  } elseif ($nearWinner -eq 1 -and $farWinner -eq 1 -and $nearMargin -ge 4.0 -and $farMargin -ge 4.0) {
    $selected = 1
  }

  $script:OptionIndex = $selected
  $script:OptionSelectionConfident = $selected -ge 0
  $optionName = if ($selected -ge 0) { @('CONTINUE', 'CHAPTER', 'NEW')[$selected] } else { 'UNKNOWN' }
  $script:OptionDiagnostics = 'option={0};optionEdgeNear={1};optionEdgeFar={2};optionMargin={3:F1},{4:F1}' -f $optionName,
    (($nearScores | ForEach-Object { '{0:F1}' -f $_ }) -join ','),
    (($farScores | ForEach-Object { '{0:F1}' -f $_ }) -join ','), $nearMargin, $farMargin
  if ($selected -eq 0) { 'SAVE_OPTIONS_CONTINUE' }
  elseif ($selected -ge 0) { 'SAVE_OPTIONS_OTHER' }
  else { 'OTHER' }
}

function Get-MainMenuSelection($Bitmap) {
  $rows = @(0.295, 0.348, 0.400, 0.450, 0.500, 0.550, 0.607)
  $names = @('CAMPAIGN', 'VERSUS', 'EXTRACTION', 'OPTIONS', 'MASKS', 'EXTRAS', 'DOWNLOADABLE_CONTENT')
  $scores = @()
  $inkScores = @()
  foreach ($row in $rows) {
    $dark = 0
    $ink = 0
    $total = 0
    for ($y = [int]($script:Viewport.Top + ($script:Viewport.Height * ($row - 0.015)));
      $y -le [int]($script:Viewport.Top + ($script:Viewport.Height * ($row + 0.015))); $y++) {
      for ($x = [int]($script:Viewport.Left + ($script:Viewport.Width * 0.70));
        $x -le [int]($script:Viewport.Left + ($script:Viewport.Width * 0.93)); $x += 2) {
        $color = $Bitmap.GetPixel($x, $y)
        $luminance = (0.2126 * $color.R) + (0.7152 * $color.G) + (0.0722 * $color.B)
        $total++
        if ($luminance -lt 60) { $dark++ }
        if ($luminance -lt 30) { $ink++ }
      }
    }
    $scores += 100.0 * $dark / $total
    $inkScores += 100.0 * $ink / $total
  }

  $selected = 0
  for ($index = 1; $index -lt $scores.Count; $index++) {
    if ($scores[$index] -gt $scores[$selected]) { $selected = $index }
  }
  $ordered = @($scores | Sort-Object -Descending)
  # In a normalized frame the selected row is the only materially dark band.
  # If the runner-up is also dark, scene exposure is dominating the score and
  # the primary detector must defer to the OCR-gated strict-ink fallback.
  $script:MainMenuSelectionVerified = $ordered[0] -ge 20.0 -and
    ($ordered[0] - $ordered[1]) -ge 8.0 -and $ordered[1] -lt 20.0
  $script:MainMenuSelected = $names[$selected]
  $script:MainMenuDiagnostics = 'selected={0};menuDark={1}' -f $names[$selected],
    (($scores | ForEach-Object { '{0:F1}' -f $_ }) -join ',')

  # Raw PrintWindow frames are materially darker than the 1.9x evidence PNGs.
  # A second, stricter ink threshold isolates the black selected-row backing
  # without treating the dark menu scene itself as selection evidence.  The
  # caller only permits this fallback when OCR independently sees both stable
  # main-menu labels.
  $inkSelected = 0
  for ($index = 1; $index -lt $inkScores.Count; $index++) {
    if ($inkScores[$index] -gt $inkScores[$inkSelected]) { $inkSelected = $index }
  }
  $inkOrdered = @($inkScores | Sort-Object -Descending)
  $script:MainMenuInkSelectionVerified = $inkOrdered[0] -ge 20.0 -and ($inkOrdered[0] - $inkOrdered[1]) -ge 8.0
  $script:MainMenuInkSelected = $names[$inkSelected]
  $script:MainMenuInkDiagnostics = 'selectionMode=strict30;selected={0};menuDark30={1};primarySelected={2};menuDark={3}' -f
    $names[$inkSelected], (($inkScores | ForEach-Object { '{0:F1}' -f $_ }) -join ','),
    $names[$selected], (($scores | ForEach-Object { '{0:F1}' -f $_ }) -join ',')
  $names[$selected]
}

function Test-LoadingFrame($Bitmap, $Metrics) {
  $Metrics.BrightPct -ge 4.0 -and $Metrics.BrightPct -lt 20.0 -and
    $Metrics.AvgG -ge 45.0 -and $Metrics.RedDom -ge 20.0
}

function Test-LoadingTipLayout($Metrics) {
  # Bright evidence captures of the rotating Salem loading-tip screen keep an
  # invariant background even when OCR sees a completely different tip title.
  # These deliberately tight bounds separate that layout from every retained
  # menu/gameplay/dialog fixture; the broader OCR-gated fallback below remains
  # available for other roles and exposure modes.
  $Metrics.BrightPct -ge 6.5 -and $Metrics.BrightPct -le 9.5 -and
    $Metrics.AvgR -ge 98.0 -and $Metrics.AvgR -le 112.0 -and
    $Metrics.AvgG -ge 62.0 -and $Metrics.AvgG -le 75.0 -and
    $Metrics.AvgB -ge 56.0 -and $Metrics.AvgB -le 70.0 -and
    $Metrics.RedDom -ge 34.0 -and $Metrics.RedDom -le 43.0 -and
    $Metrics.LumStd -ge 24.0 -and $Metrics.LumStd -le 33.0
}

function Test-ConnectingFrame($Bitmap, $Metrics) {
  $Metrics.BrightPct -lt 4.0 -and $Metrics.RedDom -ge 25.0 -and $Metrics.AvgG -lt 40.0
}

function Test-ObscuredFrame($Metrics) {
  $Metrics.BrightPct -ge 97.0 -and $Metrics.AvgR -ge 210.0 -and
    $Metrics.AvgG -ge 210.0 -and $Metrics.AvgB -ge 210.0 -and
    [math]::Abs($Metrics.RedDom) -le 8.0 -and $Metrics.LumStd -le 15.0
}

function Test-MainMenuFrame($Bitmap) {
  $yellow = 0
  $total = 0
  for ($y = [int]($Bitmap.Height * 0.33); $y -lt [int]($Bitmap.Height * 0.63); $y += 2) {
    for ($x = [int]($Bitmap.Width * 0.70); $x -lt [int]($Bitmap.Width * 0.93); $x += 2) {
      $color = $Bitmap.GetPixel($x, $y)
      $total++
      if ($color.R -gt 140 -and $color.G -gt 105 -and $color.B -lt 120 -and ($color.R - $color.B) -gt 50) {
        $yellow++
      }
    }
  }
  $script:MainMenuYellowPct = 100.0 * $yellow / $total
  $script:MainMenuYellowPct -ge 7.0
}

$bitmap = $null
$temporaryPath = $null
try {
  if ($hasProcId) {
    $process = Get-Process -Id $ProcId -ErrorAction SilentlyContinue
    if ($null -eq $process) {
      Write-Output 'NOPROC confidence=1.00'
      return
    }

    $handle = Get-AotTopLevelWindowHandle -ProcessId $process.Id
    $rect = New-Object WCls+RECT
    if ($handle -eq [IntPtr]::Zero -or -not [WCls]::GetWindowRect($handle, [ref]$rect)) {
      Write-Output 'NOWIN confidence=1.00'
      return
    }
    $width = $rect.R - $rect.L
    $height = $rect.B - $rect.T
    if ($width -le 0 -or $height -le 0) {
      Write-Output 'NOWIN confidence=1.00'
      return
    }

    $bitmap = [System.Drawing.Bitmap]::new($width, $height)
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    $deviceContext = [IntPtr]::Zero
    try {
      $deviceContext = $graphics.GetHdc()
      [void][WCls]::PrintWindow($handle, $deviceContext, 2)
    } finally {
      if ($deviceContext -ne [IntPtr]::Zero) { $graphics.ReleaseHdc($deviceContext) }
      $graphics.Dispose()
    }

    $temporaryPath = Join-Path ([System.IO.Path]::GetTempPath()) ('classify_screen_{0}_{1}.png' -f $PID, [guid]::NewGuid().ToString('N'))
    $bitmap.Save($temporaryPath, [System.Drawing.Imaging.ImageFormat]::Png)
    $ocrPath = $temporaryPath
  } else {
    if (-not [System.IO.Path]::IsPathRooted($ImagePath)) {
      throw '-ImagePath must be an absolute PNG path.'
    }
    $resolvedPath = [System.IO.Path]::GetFullPath($ImagePath)
    if ([System.IO.Path]::GetExtension($resolvedPath) -ine '.png' -or -not (Test-Path -LiteralPath $resolvedPath -PathType Leaf)) {
      throw '-ImagePath must name an existing PNG file.'
    }
    $bitmap = [System.Drawing.Bitmap]::new($resolvedPath)
    $ocrPath = $resolvedPath
  }

  $ocr = (Get-OcrText $ocrPath) -replace '\s+', ' '
  $metrics = Get-FrameMetrics $bitmap
  $script:Viewport = Get-GameViewport $bitmap
  $headerOcr = Get-CroppedOcrText $bitmap 0.04 0.05 0.40 0.20
  # CJ's smaller bright window can leave the four campaign-style rows too
  # small for whole-frame OCR even though the selection bar is clear. Keep the
  # authorization narrow: OCR only the style-list region, upscale it through
  # the existing helper, and still require the stable SELECT CAMPAIGN header.
  $styleOcr = Get-CroppedOcrText $bitmap 0.27 0.36 0.48 0.30
  $optionsOcr = Get-CroppedOcrText $bitmap 0.15 0.57 0.70 0.23
  $screenOcr = (($ocr + ' ' + $headerOcr + ' ' + $styleOcr + ' ' + $optionsOcr) -replace '\s+', ' ').Trim()
  # Tesseract occasionally drops the leading S from SAVE on the dim retail
  # carousel ("SELECT AVE SLOT"). The full three-word anchor remains narrow.
  $hasSaveScreenOcr = $screenOcr -match 'SELECT\s+S?AVE\s+SLOT'
  # PASS137: a too-early online transition can render the slot before the
  # chapter-localization token resolves (for example
  # AO3FRONTEND.CHAPTER_SELECTION.CHECKPOINTNAME_).  It is visible but not
  # actionable: confirming it produces LID=-1 / PORT=0 / an empty map.
  $hasUnreadySaveSlotOcr = $screenOcr -match 'AO3FRONTEND|CHECKPOINTN.ME_'
  $hasOptionsOcr = $optionsOcr -match 'CONT|COMT|MTL|CHAPTER|\bNEW\b'
  # The red bullet glyph in front of the header regularly merges with the word
  # SELECT, so 'SELECT CAMPAIGN' alone is NOT a reliable anchor: a live style
  # screen OCR'd as 'CAMPAIGN STYLE SOLO ... ONLINE ...' and fell through to
  # OTHER 0.20. That is what let the driver's blind-A intro phase walk both
  # rigs past this menu into a solo campaign. 'CAMPAIGN STYLE' as adjacent
  # words appears only here (the main menu pairs CAMPAIGN with VERSUS), so
  # accepting either anchor widens recognition without loosening the state.
  $hasFourStyleRows = $screenOcr -match '\bSOLO\b' -and
    $screenOcr -match 'SPLIT(?:-SCREEN)?' -and
    $screenOcr -match '(?:ONLINE\s+)?PRIVATE\s+CO-OP' -and
    $screenOcr -match '(?:ONLINE\s+)?PUBLIC\s+CO-OP'
  $hasCampaignStyleOcr = ((($screenOcr -match 'SELECT\s+CAMPAIGN' -or
        $screenOcr -match 'CAMPAIGN\s+STYLE') -and
      $screenOcr -match 'STYLE|SP[IL]|SOLO|SPLIT|ONLINE|\bONI\b|CO-OP') -or
    $hasFourStyleRows)
  $hasMainMenuOcr = $screenOcr -match '\bCAMPAIGN\b' -and $screenOcr -match '\bVERSUS\b'
  $hasMainMenuLayout = (Test-MainMenuFrame $bitmap) -and
    $metrics.RedDom -lt 40.0 -and $metrics.LumStd -ge 45.0
  $slotState = Get-SlotSelection $bitmap $hasSaveScreenOcr
  $optionsState = Get-SaveOptionsSelection $bitmap
  $styleState = Get-StyleSelection $bitmap
  $mainMenuSelection = Get-MainMenuSelection $bitmap
  $hasLoadingTipLayout = Test-LoadingTipLayout $metrics
  $state = 'OTHER'
  $confidence = 0.20
  $layoutDiagnostics = ''

  if ($screenOcr -match 'CONNECTION\s+LOST') {
    $state = 'CONNECTION_LOST'; $confidence = 0.99
  } elseif ($hasUnreadySaveSlotOcr) {
    $state = 'SAVE_SLOT_LOADING'; $confidence = 0.99
    $layoutDiagnostics = 'safeAction=HOLD'
  } elseif ($screenOcr -match '\bWARNING\b' -and $screenOcr -match '\bOVERWRITE\b') {
    $state = 'SAVE_OVERWRITE_WARNING'; $confidence = 0.99
    $layoutDiagnostics = 'safeAction=B'
  } elseif ($screenOcr -match 'CHARACTER\s+SELECT') {
    # Only appears on the ONLINE co-op character picker (PLAYER 1 TYSON RIOS /
    # SALEM, "A SELECT"). The solo path never reaches it, which is why no state
    # existed: measured 2026-07-30, the host committed its save slot, landed
    # here, classified OTHER, and the driver waited out its budget on a screen
    # that only wanted an A press.
    $state = 'CHARACTER_SELECT'; $confidence = 0.99
    $layoutDiagnostics = 'safeAction=A'
  } elseif ($screenOcr -match 'P?RESS\s+START') {
    $state = 'TITLE'; $confidence = 0.99
  } elseif (Test-ObscuredFrame $metrics) {
    $state = 'OBSCURED'; $confidence = 0.99
  } elseif ($hasCampaignStyleOcr) {
    $state = $styleState; $confidence = 0.90; $layoutDiagnostics = $script:StyleDiagnostics
  } elseif ($hasSaveScreenOcr -and $hasOptionsOcr) {
    if ($script:SlotAnyBorder -and $script:OptionSelectionConfident) {
      $state = $optionsState; $confidence = 0.90
      $layoutDiagnostics = $script:OptionDiagnostics + ';' + $script:SlotDiagnostics
    } else {
      $state = 'OTHER'; $confidence = 0.30
      $layoutDiagnostics = 'saveOptions=unverified;' + $script:OptionDiagnostics + ';' + $script:SlotDiagnostics
    }
  } elseif ($hasSaveScreenOcr) {
    if ($script:SlotAnyBorder) {
      $state = $slotState; $confidence = 0.90; $layoutDiagnostics = $script:SlotDiagnostics
    } else {
      # The game's save carousel is authored against a wider fixed canvas. On
      # the Acer classifier window its right edge can clip, defeating the
      # fractional border probes even though entry always selects slot 0.
      $state = 'SAVE_SLOT_0'; $confidence = 0.75
      $layoutDiagnostics = 'slotMode=entryFallback;' + $script:SlotDiagnostics
    }
  } elseif ($screenOcr -match '\bCONNECTING\b') {
    $state = 'CONNECTING'; $confidence = 0.99
  } elseif ($hasMainMenuOcr -or $hasMainMenuLayout) {
    if ($script:MainMenuSelectionVerified -and $script:MainMenuSelected -eq 'CAMPAIGN') {
      $state = 'MAIN_MENU'; $confidence = 0.90; $layoutDiagnostics = $script:MainMenuDiagnostics
    } elseif (-not $script:MainMenuSelectionVerified -and $hasMainMenuOcr -and
      $script:MainMenuInkSelectionVerified -and
      $script:MainMenuInkSelected -eq 'CAMPAIGN') {
      $state = 'MAIN_MENU'; $confidence = 0.88; $layoutDiagnostics = $script:MainMenuInkDiagnostics
    } else {
      $state = 'OTHER'; $confidence = 0.35; $layoutDiagnostics = 'menuSelection=unverified;' + $script:MainMenuDiagnostics
    }
  # Tip text rotates while the loading background remains fixed. Prefer the
  # narrow retained-corpus layout fingerprint; preserve the OCR+coarser-metric
  # path for other role/exposure variants such as the daddy Aggro tip.
  } elseif ($hasLoadingTipLayout -or
    ($screenOcr -match 'AGGRO|ADVANTAGE|FLANK|SNIPE|CAMERA\s+SIDE|SIDE\s+SW[IL]TCH[IL]NG' -and
      (Test-LoadingFrame $bitmap $metrics))) {
    $state = 'LOADING'; $confidence = if ($hasLoadingTipLayout) { 0.92 } else { 0.80 }
    if ($hasLoadingTipLayout) { $layoutDiagnostics = 'loadingMode=layout' }
  } elseif ($screenOcr -match 'PLEASE\s+WAIT' -and $screenOcr -match '\bCANCEL\b' -and
    (Test-ConnectingFrame $bitmap $metrics)) {
    $state = 'CONNECTING'; $confidence = 0.76
  }

  $safeOcr = ($screenOcr -replace "'", '')
  $diagnostics = "confidence={0:F2} ocr='{1}' brightPct={2:F1} redDom={3:F1} avgRGB={4:F0},{5:F0},{6:F0} lumStd={7:F1}" -f
    $confidence, $safeOcr, $metrics.BrightPct, $metrics.RedDom, $metrics.AvgR, $metrics.AvgG, $metrics.AvgB, $metrics.LumStd
  if (-not [string]::IsNullOrWhiteSpace($layoutDiagnostics)) { $diagnostics += ' ' + $layoutDiagnostics }
  Write-Output ($state + ' ' + $diagnostics)
} finally {
  if ($null -ne $bitmap) { $bitmap.Dispose() }
  if ($null -ne $temporaryPath -and (Test-Path -LiteralPath $temporaryPath)) {
    Remove-Item -LiteralPath $temporaryPath -Force
  }
}
