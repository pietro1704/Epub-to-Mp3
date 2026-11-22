[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string]$Package,
  [Parameter(Mandatory = $true)][string]$Fixture,
  [Parameter(Mandatory = $true)][string]$Evidence
)

$ErrorActionPreference = 'Stop'
if ($env:GITHUB_ACTIONS -ne 'true' -or $env:RUNNER_ENVIRONMENT -ne 'github-hosted') {
  throw 'The Windows GUI journey needs the disposable GitHub-hosted Windows account.'
}
if (-not [Environment]::UserInteractive) {
  throw 'The Windows runner has no interactive desktop.'
}

Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes, System.Drawing
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class ReaderTestDesktop
{
    [StructLayout(LayoutKind.Sequential)]
    public struct Point
    {
        public int X, Y;
    }

    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr window);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr window, int command);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr window);
    [DllImport("user32.dll")] public static extern IntPtr SetThreadDpiAwarenessContext(IntPtr context);
    [DllImport("user32.dll")] private static extern IntPtr WindowFromPoint(Point point);
    [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr window, out uint owner);
    [DllImport("user32.dll")] private static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] private static extern void mouse_event(uint flags, uint x, uint y, uint data, UIntPtr info);

    public static uint Owner(IntPtr window)
    {
        uint owner;
        GetWindowThreadProcessId(window, out owner);
        return owner;
    }

    public static void Click(int x, int y, uint owner)
    {
        var point = new Point { X = x, Y = y };
        if (Owner(GetForegroundWindow()) != owner || Owner(WindowFromPoint(point)) != owner)
            throw new InvalidOperationException("The control is not on the app's foreground window.");
        if (!SetCursorPos(x, y))
            throw new InvalidOperationException("The Windows cursor could not reach the control.");
        mouse_event(0x0002, 0, 0, 0, UIntPtr.Zero);
        mouse_event(0x0004, 0, 0, 0, UIntPtr.Zero);
    }
}
'@
[void][ReaderTestDesktop]::SetThreadDpiAwarenessContext([IntPtr](-4))

$packagePath = (Resolve-Path -LiteralPath $Package).Path
$fixturePath = (Resolve-Path -LiteralPath $Fixture).Path
$executable = Join-Path $packagePath 'flutter_app.exe'
$executableHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $executable).Hash
$fixtureHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $fixturePath).Hash
$evidencePath = (New-Item -ItemType Directory -Force -Path $Evidence).FullName
$application = $null
$window = [IntPtr]::Zero

function Wait-ForReaderUi([string]$Description, [scriptblock]$Lookup) {
  $clock = [Diagnostics.Stopwatch]::StartNew()
  while ($clock.Elapsed.TotalSeconds -lt 35) {
    $application.Refresh()
    if ($application.HasExited) {
      throw "The packaged application exited with code $($application.ExitCode) while waiting for $Description."
    }

    try {
      $match = & $Lookup
      if ($null -ne $match) {
        Write-Host "Observed $Description."
        return $match
      }
    } catch [System.Windows.Automation.ElementNotAvailableException] {
      # Flutter can replace accessibility elements while a frame is laid out.
    }
    Start-Sleep -Milliseconds 250
  }
  throw "Timed out waiting for $Description."
}

function Get-ReaderElements([System.Windows.Automation.AutomationElement]$Root) {
  $Root.FindAll(
    [System.Windows.Automation.TreeScope]::Descendants,
    [System.Windows.Automation.Condition]::TrueCondition
  )
}

function Find-VisibleElement([System.Windows.Automation.AutomationElement]$Root, [scriptblock]$Match) {
  foreach ($element in (Get-ReaderElements $Root)) {
    $properties = $element.Current
    if (-not $properties.IsOffscreen -and (& $Match $properties)) {
      return $element
    }
  }
}

function Find-AppText([string]$Pattern) {
  $root = [System.Windows.Automation.AutomationElement]::FromHandle($window)
  Find-VisibleElement $root { param($item) $item.Name -match $Pattern }
}

function Click-ReaderElement([System.Windows.Automation.AutomationElement]$Element) {
  $rectangle = $Element.Current.BoundingRectangle
  if ($rectangle.IsEmpty -or $rectangle.Width -le 0 -or $rectangle.Height -le 0) {
    throw 'The requested control has no visible bounds.'
  }
  $centerX = [int]($rectangle.X + $rectangle.Width / 2)
  $centerY = [int]($rectangle.Y + $rectangle.Height / 2)
  [ReaderTestDesktop]::Click($centerX, $centerY, $application.Id)
}

function Save-ReaderFrame([string]$Name, [IntPtr]$Handle = $window, [switch]$Diagnostic) {
  if ([ReaderTestDesktop]::GetForegroundWindow() -ne $Handle) {
    throw 'The application window is not in the foreground for capture.'
  }

  $root = [System.Windows.Automation.AutomationElement]::FromHandle($Handle)
  $bounds = $root.Current.BoundingRectangle
  $width = [int]$bounds.Width
  $height = [int]$bounds.Height
  if ($width -lt 320 -or $height -lt 240) {
    throw "Unexpected application window dimensions: ${width}x${height}."
  }

  $bitmap = [Drawing.Bitmap]::new($width, $height)
  $graphics = [Drawing.Graphics]::FromImage($bitmap)
  try {
    $graphics.CopyFromScreen([int]$bounds.X, [int]$bounds.Y, 0, 0, $bitmap.Size)
    $bitmap.Save((Join-Path $evidencePath "$Name.png"), [Drawing.Imaging.ImageFormat]::Png)
    $colors = [Collections.Generic.HashSet[int]]::new()
    for ($y = 64; $y -lt ($height - 64); $y += 8) {
      for ($x = 32; $x -lt ($width - 32); $x += 8) {
        [void]$colors.Add($bitmap.GetPixel($x, $y).ToArgb())
      }
    }
    if (-not $Diagnostic -and $colors.Count -lt 8) {
      throw "The $Name capture has too little visible content ($($colors.Count) sampled colors)."
    }
    Write-Host "Captured $Name at ${width}x${height} with $($colors.Count) sampled colors."
  } finally {
    $graphics.Dispose()
    $bitmap.Dispose()
  }
}

try {
  $application = Start-Process -FilePath $executable -WorkingDirectory $packagePath -PassThru
  $window = Wait-ForReaderUi 'the packaged Windows app window' {
    $handle = $application.MainWindowHandle
    if ($handle -ne [IntPtr]::Zero -and [ReaderTestDesktop]::IsWindowVisible($handle)) { $handle }
  }
  [void][ReaderTestDesktop]::ShowWindow($window, 3)
  [void][ReaderTestDesktop]::SetForegroundWindow($window)

  $addBook = Wait-ForReaderUi 'the Library Add a book control' { Find-AppText '^Add a book$' }
  Click-ReaderElement $addBook

  $dialog = Wait-ForReaderUi 'the native file picker' {
    $handle = [ReaderTestDesktop]::GetForegroundWindow()
    if ($handle -ne $window -and [ReaderTestDesktop]::Owner($handle) -eq $application.Id) {
      [System.Windows.Automation.AutomationElement]::FromHandle($handle)
    }
  }
  $filename = Wait-ForReaderUi 'the native file name field' {
    Find-VisibleElement $dialog {
      param($item)
      $item.ControlType -eq [System.Windows.Automation.ControlType]::Edit -and
        ($item.AutomationId -eq '1001' -or $item.Name -match '^File name:?$')
    }
  }
  $value = $filename.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern)
  $value.SetValue($fixturePath)

  $open = Wait-ForReaderUi 'the native Open button' {
    Find-VisibleElement $dialog {
      param($item)
      $item.ControlType -eq [System.Windows.Automation.ControlType]::Button -and $item.AutomationId -eq '1'
    }
  }
  Click-ReaderElement $open

  $book = Wait-ForReaderUi 'the imported EPUB in Library' { Find-AppText '^Amostra p.blica do CLI(?:\s|$)' }
  Click-ReaderElement $book
  $chapterOne = (Wait-ForReaderUi 'the opening chapter passage' { Find-AppText 'a neblina cobria a colina' }).Current.Name
  Save-ReaderFrame 'chapter-1'

  $contents = Wait-ForReaderUi 'the reader Table of contents control' { Find-AppText '^Table of contents$' }
  Click-ReaderElement $contents
  $secondEntry = Wait-ForReaderUi 'the second chapter in the table of contents' { Find-AppText '^O mapa antigo$' }
  Click-ReaderElement $secondEntry
  $chapterTwo = (Wait-ForReaderUi 'the second chapter passage' { Find-AppText 'um mapa antigo, dobrado' }).Current.Name
  Save-ReaderFrame 'chapter-2'

  [ordered]@{
    source = $env:GITHUB_SHA
    run = $env:GITHUB_RUN_ID
    architecture = $env:PROCESSOR_ARCHITECTURE
    executable_sha256 = $executableHash
    fixture_sha256 = $fixtureHash
    first_chapter = $chapterOne
    second_chapter = $chapterTwo
  } | ConvertTo-Json | Set-Content -Encoding UTF8 -LiteralPath (Join-Path $evidencePath 'reader-journey.json')
  Write-Host 'WINDOWS_READER_GUI: native picker, Library, reader and second chapter passed.'
} catch {
  $foreground = [ReaderTestDesktop]::GetForegroundWindow()
  if ($null -ne $application -and [ReaderTestDesktop]::Owner($foreground) -eq $application.Id) {
    try {
      Save-ReaderFrame 'failure' -Handle $foreground -Diagnostic
      $root = [System.Windows.Automation.AutomationElement]::FromHandle($foreground)
      Get-ReaderElements $root | ForEach-Object {
        $item = $_.Current
        "$($item.ControlType.ProgrammaticName) | $($item.AutomationId) | $($item.Name)"
      } | Set-Content -Encoding UTF8 -LiteralPath (Join-Path $evidencePath 'visible-elements.txt')
    } catch {
      Write-Warning "Could not retain the complete failure evidence: $_"
    }
  }
  throw
} finally {
  if ($null -ne $application) {
    $application.Refresh()
    if (-not $application.HasExited) {
      [void]$application.CloseMainWindow()
      if (-not $application.WaitForExit(5000)) {
        $application.Kill()
      }
    }
    $application.Dispose()
  }
}
