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

Add-Type -AssemblyName Accessibility, UIAutomationClient, UIAutomationTypes, System.Drawing
$readerSource = @'
using Accessibility;
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

public static class ReaderTestDesktop
{
    // Use the COM property accessors with an explicit child ID, including CHILDID_SELF.
    private static readonly Func<IAccessible, object, string> ReadName =
        BindAccessibleProperty<string>("get_accName");
    private static readonly Func<IAccessible, object, object> ReadRole =
        BindAccessibleProperty<object>("get_accRole");
    private static readonly Func<IAccessible, object, object> ReadState =
        BindAccessibleProperty<object>("get_accState");
    private static readonly Func<IAccessible, object, string> ReadValue =
        BindAccessibleProperty<string>("get_accValue");
    private static readonly Func<IAccessible, object, string> ReadDescription =
        BindAccessibleProperty<string>("get_accDescription");

    private static Func<IAccessible, object, TValue> BindAccessibleProperty<TValue>(string accessor)
    {
        return (Func<IAccessible, object, TValue>)Delegate.CreateDelegate(
            typeof(Func<IAccessible, object, TValue>), typeof(IAccessible).GetMethod(accessor));
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct Point
    {
        public int X, Y;
    }

    public sealed class FlutterElement
    {
        public string Name;
        public object Role;
        public int State;
        public int Left, Top, Width, Height;

        public bool IsVisible
        {
            get
            {
                const int invisibleOrOffscreen = 0x8000 | 0x10000;
                return (State & invisibleOrOffscreen) == 0 && Width > 0 && Height > 0;
            }
        }
    }

    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr window);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr window, int command);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr window);
    [DllImport("user32.dll")] public static extern IntPtr SetThreadDpiAwarenessContext(IntPtr context);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern IntPtr FindWindowEx(IntPtr parent, IntPtr after, string className, string title);
    [DllImport("oleacc.dll")] private static extern int AccessibleObjectFromWindow(IntPtr window, uint objectId, ref Guid interfaceId, [MarshalAs(UnmanagedType.Interface)] out IAccessible accessible);
    [DllImport("oleacc.dll")] private static extern int AccessibleChildren([MarshalAs(UnmanagedType.Interface)] IAccessible container, int start, int count, [Out, MarshalAs(UnmanagedType.LPArray, ArraySubType = UnmanagedType.Struct, SizeParamIndex = 2)] object[] children, out int obtained);
    [DllImport("user32.dll")] private static extern IntPtr WindowFromPoint(Point point);
    [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr window, out uint owner);
    [DllImport("user32.dll")] private static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] private static extern void mouse_event(uint flags, uint x, uint y, uint data, UIntPtr info);

    private delegate bool EnumWindowsProc(IntPtr window, IntPtr parameter);
    [DllImport("user32.dll")] private static extern bool EnumWindows(EnumWindowsProc callback, IntPtr parameter);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern int GetClassName(IntPtr window, System.Text.StringBuilder text, int capacity);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern int GetWindowText(IntPtr window, System.Text.StringBuilder text, int capacity);

    // Top-level windows of one process, so a dialog is found even when it is not the foreground window.
    public static string[] ProcessWindows(uint owner)
    {
        var rows = new List<string>();
        EnumWindows(delegate (IntPtr handle, IntPtr parameter)
        {
            if (Owner(handle) != owner)
                return true;
            var cls = new System.Text.StringBuilder(256);
            var title = new System.Text.StringBuilder(256);
            GetClassName(handle, cls, cls.Capacity);
            GetWindowText(handle, title, title.Capacity);
            rows.Add(handle.ToInt64() + "|" + (IsWindowVisible(handle) ? "visible" : "hidden") + "|" + cls + "|" + title);
            return true;
        }, IntPtr.Zero);
        return rows.ToArray();
    }

    public static uint Owner(IntPtr window)
    {
        uint owner;
        GetWindowThreadProcessId(window, out owner);
        return owner;
    }

    public static IntPtr FindFlutterView(IntPtr window)
    {
        return FindWindowEx(window, IntPtr.Zero, "FLUTTERVIEW", null);
    }

    public static FlutterElement[] ReadFlutterAccessibility(IntPtr window)
    {
        const uint objIdClient = unchecked((uint)-4);
        Guid accessibleId = typeof(IAccessible).GUID;
        IAccessible root;
        var elements = new List<FlutterElement>();
        // Flutter handles OBJID_CLIENT on its own HWND even when UIA exposes only the pane.
        if (AccessibleObjectFromWindow(window, objIdClient, ref accessibleId, out root) == 0 && root != null)
        {
            try { ReadAccessibleNode(root, 0, 0, elements); }
            catch (Exception error) { if (!IsNodeFailure(error)) throw; /* Flutter can replace a node mid-read; keep what was read. */ }
        }
        return elements.ToArray();
    }

    // .NET maps E_INVALIDARG to ArgumentException, so a replaced node surfaces as either type.
    // Windows PowerShell compiles this block as C# 5, so exception filters are not available.
    private static bool IsNodeFailure(Exception error)
    {
        return error is COMException || error is ArgumentException;
    }

    private static void ReadAccessibleNode(IAccessible accessible, int childId,
                                           int depth, List<FlutterElement> elements)
    {
        if (depth > 64 || elements.Count >= 1024)
            return;

        var element = new FlutterElement();
        // Each property can fail independently on a replaced node; record the reason instead of losing the subtree.
        try { element.Name = ReadName(accessible, childId); }
        catch (Exception error)
        {
            if (!IsNodeFailure(error)) throw;
            string extra = "";
            // Probe what the node still answers, to tell a dead node from a variant problem.
            try { extra += " childCount=" + accessible.accChildCount; } catch (Exception) { extra += " childCount=err"; }
            try { extra += " value=" + ReadValue(accessible, childId); } catch (Exception) { extra += " value=err"; }
            try { extra += " desc=" + ReadDescription(accessible, childId); } catch (Exception) { extra += " desc=err"; }
            try { extra += " role=" + ReadRole(accessible, childId); } catch (Exception) { extra += " role=err"; }
            element.Name = "[name unavailable depth=" + depth + " childId=" + childId + extra + ": " + error.Message + "]";
        }
        try { element.Role = ReadRole(accessible, childId); }
        catch (Exception error) { if (!IsNodeFailure(error)) throw; element.Role = "unavailable"; }
        try { element.State = Convert.ToInt32(ReadState(accessible, childId)); }
        catch (Exception error) { if (!IsNodeFailure(error)) throw; element.State = 0; }
        try
        {
            accessible.accLocation(out element.Left, out element.Top, out element.Width,
                                   out element.Height, childId);
        }
        catch (Exception error) { if (!IsNodeFailure(error)) throw; }
        elements.Add(element);

        if (childId != 0)
            return;

        int children = 0;
        try { children = accessible.accChildCount; }
        catch (Exception error)
        {
            if (!IsNodeFailure(error)) throw;
            elements.Add(new FlutterElement { Name = "[child count unreadable at depth " + depth + ": " + error.Message + "]", Role = "error", State = 0x8000 });
        }
        // AccessibleChildren is the supported enumeration: each entry is either a child IAccessible or a simple child ID.
        // Flutter nodes can reject get_accChild(index) with E_INVALIDARG, so it is only the fallback.
        object[] entries = new object[children];
        int obtained = 0;
        int enumerated = children > 0 ? AccessibleChildren(accessible, 0, children, entries, out obtained) : 0;
        if (enumerated >= 0 && children > 0)
        {
            for (int index = 0; index < obtained && elements.Count < 1024; index++)
            {
                try
                {
                    IAccessible child = entries[index] as IAccessible;
                    if (child != null)
                        ReadAccessibleNode(child, 0, depth + 1, elements);
                    else if (entries[index] is int)
                        ReadAccessibleNode(accessible, (int)entries[index], depth + 1, elements);
                }
                catch (Exception error)
                {
                    if (!IsNodeFailure(error)) throw;
                    elements.Add(new FlutterElement { Name = "[child " + (index + 1) + "/" + obtained + " at depth " + depth + " unreadable: " + error.Message + "]", Role = "error", State = 0x8000 });
                }
            }
            return;
        }
        if (children > 0)
            elements.Add(new FlutterElement { Name = "[AccessibleChildren failed at depth " + depth + ": 0x" + enumerated.ToString("X8") + "; falling back to get_accChild]", Role = "error", State = 0x8000 });
        for (int index = 1; index <= children && elements.Count < 1024; index++)
        {
            try
            {
                IAccessible child = accessible.get_accChild(index) as IAccessible;
                if (child != null)
                    ReadAccessibleNode(child, 0, depth + 1, elements);
                else
                    ReadAccessibleNode(accessible, index, depth + 1, elements);
            }
            catch (Exception error)
            {
                if (!IsNodeFailure(error)) throw;
                // Keep a hidden marker so diagnostics show which child could not be read and why.
                elements.Add(new FlutterElement { Name = "[child " + index + "/" + children + " at depth " + depth + " unreadable: " + error.Message + "]", Role = "error", State = 0x8000 });
            }
        }
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
try {
  Add-Type -ReferencedAssemblies ([Accessibility.IAccessible].Assembly.Location) -TypeDefinition $readerSource
  [void][ReaderTestDesktop]::SetThreadDpiAwarenessContext([IntPtr](-4))
} catch {
  # Compilation and static initialisation happen before the journey's own handler.
  if ($env:GITHUB_ACTIONS -eq 'true') {
    $detail = $_.Exception.ToString()
    if ($_.Exception.InnerException) { $detail += "`n" + $_.Exception.InnerException.ToString() }
    $detail = $detail.Replace('%', '%25').Replace("`r", '%0D').Replace("`n", '%0A')
    Write-Host "::error title=Windows reader helper::$detail"
  }
  throw
}

$packagePath = (Resolve-Path -LiteralPath $Package).Path
$fixturePath = (Resolve-Path -LiteralPath $Fixture).Path
$executable = Join-Path $packagePath 'flutter_app.exe'
$executableHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $executable).Hash
$fixtureHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $fixturePath).Hash
$evidencePath = (New-Item -ItemType Directory -Force -Path $Evidence).FullName
$application = $null
$window = [IntPtr]::Zero
$flutterView = [IntPtr]::Zero
$dialog = $null

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
      # A native dialog element can disappear during a refresh.
    } catch [System.Runtime.InteropServices.COMException] {
      # A replaced MSAA node can report E_INVALIDARG, E_FAIL, CO_E_OBJNOTCONNECTED or RPC_E_DISCONNECTED.
      if ($_.Exception.GetBaseException().HResult -notin @(0x80070057, 0x800401FD, 0x80010108, 0x80004005)) { throw }
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
  foreach ($element in [ReaderTestDesktop]::ReadFlutterAccessibility($flutterView)) {
    if ($element.IsVisible -and $element.Name -match $Pattern) {
      return $element
    }
  }
}

function Save-FlutterAccessibility([IntPtr]$Handle) {
  $elements = [ReaderTestDesktop]::ReadFlutterAccessibility($Handle)
  $rows = @(
    foreach ($element in $elements) {
      $name = $element.Name -replace '\s+', ' '
      "role=$($element.Role) | state=$($element.State) | bounds=$($element.Left),$($element.Top),$($element.Width),$($element.Height) | name=$name"
    }
  )
  Write-AccessibilityEvidence 'MSAA' $Handle $rows
}

function Save-ReaderAccessibility([IntPtr]$Handle) {
  $root = [System.Windows.Automation.AutomationElement]::FromHandle($Handle)
  $elements = @($root; Get-ReaderElements $root)
  $rows = @(
    foreach ($element in $elements) {
      try {
        $item = $element.Current
        $name = $item.Name -replace '\s+', ' '
        $help = $item.HelpText -replace '\s+', ' '
        "$($item.ControlType.ProgrammaticName) | class=$($item.ClassName) | id=$($item.AutomationId) | offscreen=$($item.IsOffscreen) | name=$name | help=$help"
      } catch [System.Windows.Automation.ElementNotAvailableException] {
        'Element disappeared during capture.'
      }
    }
  )
  Write-AccessibilityEvidence 'UIA' $Handle $rows
}

function Write-AccessibilityEvidence([string]$Api, [IntPtr]$Handle, [string[]]$Rows) {
  $summary = "$Api handle=$Handle, elements=$($Rows.Count)"
  Write-Host $summary
  $Rows | Select-Object -First 20 | ForEach-Object {
    Write-Host ("$Api " + $_.Substring(0, [Math]::Min(220, $_.Length)))
  }
  @($summary) + $Rows | Set-Content -Encoding UTF8 -LiteralPath (Join-Path $evidencePath "visible-elements-$Api-$Handle.txt")
  if ($env:GITHUB_ACTIONS -eq 'true') {
    # Annotations stay readable without downloading logs or artifacts.
    $digest = (@($summary) + ($Rows | Select-Object -First 70 | ForEach-Object { $_.Substring(0, [Math]::Min(160, $_.Length)) })) -join "`n"
    $digest = $digest.Replace('%', '%25').Replace("`r", '%0D').Replace("`n", '%0A')
    Write-Host "::notice title=$Api tree $Handle::$digest"
  }
}

function Click-FlutterElement([ReaderTestDesktop+FlutterElement]$Element) {
  $centerX = [int]($Element.Left + $Element.Width / 2)
  $centerY = [int]($Element.Top + $Element.Height / 2)
  [ReaderTestDesktop]::Click($centerX, $centerY, $application.Id)
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

  $flutterView = Wait-ForReaderUi 'the Flutter view window' {
    $handle = [ReaderTestDesktop]::FindFlutterView($window)
    if ($handle -ne [IntPtr]::Zero -and [ReaderTestDesktop]::Owner($handle) -eq $application.Id) { $handle }
  }
  $addBook = Wait-ForReaderUi 'the Library Add a book control' { Find-AppText '^Add a book$' }
  Click-FlutterElement $addBook
  $importFile = Wait-ForReaderUi 'the local EPUB or PDF import control' { Find-AppText '^Import an EPUB or PDF file$' }
  Click-FlutterElement $importFile

  $dialog = Wait-ForReaderUi 'the native file picker' {
    $handle = [ReaderTestDesktop]::GetForegroundWindow()
    if ($handle -ne $window -and [ReaderTestDesktop]::Owner($handle) -eq $application.Id) {
      [System.Windows.Automation.AutomationElement]::FromHandle($handle)
    } else {
      # The picker can be visible without being foreground; look at every top-level window of the app.
      foreach ($row in [ReaderTestDesktop]::ProcessWindows($application.Id)) {
        $parts = $row.Split('|', 4)
        if ($parts[1] -eq 'visible' -and $parts[2] -eq '#32770') {
          [System.Windows.Automation.AutomationElement]::FromHandle([IntPtr][long]$parts[0])
          break
        }
      }
    }
  }
  # The Windows 11 common dialog exposes no stable file name edit through UIA, but it opens with the
  # file name box focused. Prefer the UIA field when present, otherwise type into the focused box.
  $filename = $null
  $clock = [Diagnostics.Stopwatch]::StartNew()
  while ($null -eq $filename -and $clock.Elapsed.TotalSeconds -lt 5) {
    try {
      $filename = Find-VisibleElement $dialog {
        param($item)
        $item.ControlType -eq [System.Windows.Automation.ControlType]::Edit -and
          ($item.AutomationId -in @('1001', '1148') -or $item.Name -match '(?i)^(File name|Nome do arquivo):?$')
      }
    } catch [System.Runtime.InteropServices.COMException] {
      # The dialog is still building its tree.
    }
    if ($null -eq $filename) { Start-Sleep -Milliseconds 250 }
  }
  if ($null -ne $filename) {
    $value = $filename.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern)
    $value.SetValue($fixturePath)
    $open = Wait-ForReaderUi 'the native Open button' {
      Find-VisibleElement $dialog {
        param($item)
        $item.ControlType -eq [System.Windows.Automation.ControlType]::Button -and $item.AutomationId -eq '1'
      }
    }
    Click-ReaderElement $open
  } else {
    Write-Host 'The native file name field is not exposed through UIA; typing into the focused box.'
    Add-Type -AssemblyName System.Windows.Forms
    [void][ReaderTestDesktop]::SetForegroundWindow([IntPtr]$dialog.Current.NativeWindowHandle)
    Start-Sleep -Milliseconds 750
    $escaped = [regex]::Replace($fixturePath, '[+^%~(){}\[\]]', '{$0}')
    [System.Windows.Forms.SendKeys]::SendWait($escaped)
    Start-Sleep -Milliseconds 500
    [System.Windows.Forms.SendKeys]::SendWait('{ENTER}')
  }

  $book = Wait-ForReaderUi 'the imported EPUB in Library' { Find-AppText '^Amostra p.blica do CLI(?:\s|$)' }
  Click-FlutterElement $book
  $chapterOne = (Wait-ForReaderUi 'the opening chapter passage' { Find-AppText 'a neblina cobria a colina' }).Name
  Save-ReaderFrame 'chapter-1'

  $contents = Wait-ForReaderUi 'the reader Table of contents control' { Find-AppText '^Table of contents$' }
  Click-FlutterElement $contents
  $secondEntry = Wait-ForReaderUi 'the second chapter in the table of contents' { Find-AppText '^O mapa antigo$' }
  Click-FlutterElement $secondEntry
  $chapterTwo = (Wait-ForReaderUi 'the second chapter passage' { Find-AppText 'um mapa antigo, dobrado' }).Name
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
  if ($env:GITHUB_ACTIONS -eq 'true') {
    $message = $_.Exception.Message.Replace('%', '%25').Replace("`r", '%0D').Replace("`n", '%0A')
    Write-Host "::error title=Windows reader journey::$message"
  }
  if ($null -ne $application) {
    try {
      [ReaderTestDesktop]::ProcessWindows($application.Id) |
        Set-Content -Encoding UTF8 -LiteralPath (Join-Path $evidencePath 'process-windows.txt')
    } catch {
      Write-Warning "Could not list the application windows: $_"
    }
  }
  if ($null -ne $dialog) {
    try {
      Save-ReaderAccessibility ([IntPtr]$dialog.Current.NativeWindowHandle)
    } catch {
      Write-Warning "Could not capture the native dialog tree: $_"
    }
  }
  $foreground = [ReaderTestDesktop]::GetForegroundWindow()
  if ($null -ne $application -and [ReaderTestDesktop]::Owner($foreground) -eq $application.Id) {
    try {
      Save-ReaderFrame 'failure' -Handle $foreground -Diagnostic
    } catch {
      Write-Warning "Could not capture the failure frame: $_"
    }
    try {
      if ($foreground -eq $window -and $flutterView -ne [IntPtr]::Zero) {
        Save-FlutterAccessibility $flutterView
        try {
          Save-ReaderAccessibility $flutterView
        } catch {
          Write-Warning "Could not capture the Flutter view UIA tree: $_"
        }
      } else {
        Save-ReaderAccessibility $foreground
      }
    } catch {
      Write-Warning "Could not capture the accessibility tree: $_"
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
