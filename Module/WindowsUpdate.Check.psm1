function New-WindowsUpdateCheckRedistributionNotice {
    param(
        [Parameter(Mandatory)][string]$Target,
        [Parameter(Mandatory)][string]$Reason
    )

    [pscustomobject]@{
        Area = 'WindowsUpdateAdm'
        Target = $Target
        Reason = $Reason
        NextStep = 'WindowsUpdateAdm-Verteilung und WinRM-Verbindung prüfen; bei fehlendem oder veraltetem JEA-Endpunkt Verteilung erneut ausführen.'
    }
}

function New-WindowsUpdateCheckExternalSetupNotice {
    param(
        [Parameter(Mandatory)][string]$Area,
        [Parameter(Mandatory)][string]$Target,
        [Parameter(Mandatory)][string]$Reason
    )

    $nextStep = if ($Reason -match 'Verbindung nicht bestätigt') {
        'Zuerst Erreichbarkeit und SSH prüfen; Verteilung nur bei fehlender oder ungültiger Einrichtung erneut ausführen.'
    } elseif ($Area -eq 'Linux') {
        'Bei fehlendem/veraltetem SSH-Schlüssel oder sudo-Setup die Linux-Verteilung erneut ausführen.'
    } else {
        'Bei fehlendem SSH-Schlüssel die Home-Assistant-Verteilung erneut ausführen.'
    }

    [pscustomobject]@{ Area = $Area; Target = $Target; Reason = $Reason; NextStep = $nextStep }
}

function Get-WindowsUpdateCheckClientCertificate {
    param(
        [AllowEmptyString()][string]$Thumbprint,
        [Parameter(Mandatory)][string]$ComputerName,
        [string]$StorePath = 'Cert:\CurrentUser\My'
    )

    $certificates = @(Get-ChildItem -Path $StorePath -ErrorAction Stop)
    if (-not [string]::IsNullOrWhiteSpace($Thumbprint)) {
        return $certificates | Where-Object Thumbprint -eq $Thumbprint | Select-Object -First 1
    }

    $certificates |
        Where-Object Subject -eq "CN=WinRM-UpdateClient-$ComputerName" |
        Sort-Object NotAfter -Descending |
        Select-Object -First 1
}


function Invoke-WindowsUpdateCheckCacheCleanup {
  param(
    [string]$Servername,
    [Parameter(Mandatory)][object]$UpdateSettings,
    [Parameter(Mandatory)][scriptblock]$WriteLog,
    # AuthInfo stammt aus dem gemeinsamen Zertifikatsmodul und enthält den
    # Client-Zertifikat-Thumbprint für Nicht-AD-Ziele.
    $AuthInfo = $null
  )

  $writeLogCallback = $WriteLog
  function Write-ScriptLog ($Message, [bool]$LogOnly = $false) {
    & $writeLogCallback -Message $Message -LogOnly:$LogOnly
  }
  $diagnosticLog = { param($message) & $writeLogCallback -Message $message }.GetNewClosure()
  $diagnosticLogOnly = { param($message) & $writeLogCallback -Message $message -LogOnly:$true }.GetNewClosure()

  # Standardmäßig bewusst aktiv: Kunden werden teils nur selten versorgt und
  # sollen vor dem Scan frische Update-Metadaten erhalten. Der Schalter kann
  # bei häufigen Prüfungen je Kundenkonfiguration deaktiviert werden.
  if ($UpdateSettings.PSObject.Properties.Name -contains 'ClearUpdateCacheBeforeCheck' -and
      -not [bool]$UpdateSettings.ClearUpdateCacheBeforeCheck) {
    Write-ScriptLog "Cache-Bereinigung auf ${Servername} laut Konfiguration übersprungen."
    return
  }

  Write-ScriptLog "Bereinige Windows Update Cache (Download + DataStore) auf ${Servername}..."

  # -----------------------------------------------------------------------
  # ÄNDERUNG 1: DataStore wird zusätzlich geleert
  # ÄNDERUNG 2: BITS-Dienst wird ebenfalls gestoppt (hält Dateien offen)
  # ÄNDERUNG 3: Nach dem Neustart der Dienste wird DetectNow ausgelöst,
  #             damit Windows Update frisch bei Microsoft sucht und nicht
  #             auf gecachte (veraltete) Metadaten zurückgreift.
  # ÄNDERUNG 4: Wartezeit nach DetectNow (Standard 60s, konfigurierbar)
  # -----------------------------------------------------------------------
  $clearCacheScript = {
    param([int]$DetectNowWaitSec = 60)
    try {
      $result = "SUCCESS"
      $diagnostics = [System.Collections.Generic.List[string]]::new()
      $serviceStartFailed = $false

      # Dienste stoppen: erst wuauserv, dann bits
      foreach ($svc in @('wuauserv','bits')) {
        try { Stop-Service -Name $svc -Force -ErrorAction Stop }
        catch {
          $result = 'SERVICE_STOP_FAILED'
          $diagnostics.Add("Dienst '$svc' konnte nicht gestoppt werden: $($_.Exception.ToString())")
        }
      }

      # Warte bis beide Dienste wirklich gestoppt sind (max 30 Sekunden)
      $maxWait = 30
      foreach ($svc in @('wuauserv','bits')) {
        $waited = 0
        while ((Get-Service -Name $svc).Status -ne 'Stopped' -and $waited -lt $maxWait) {
          Start-Sleep -Seconds 1
          $waited++
        }
        if ((Get-Service -Name $svc).Status -ne 'Stopped') {
          if ($result -eq 'SUCCESS') { $result = "TIMEOUT_STOP_$svc" }
          $diagnostics.Add("Dienst '$svc' blieb nach $maxWait Sekunden aktiv.")
        }
      }

      if ($result -eq "SUCCESS") {
        foreach ($cachePath in @('C:\Windows\SoftwareDistribution\Download\*', 'C:\Windows\SoftwareDistribution\DataStore\*')) {
          try {
            Remove-Item $cachePath -Recurse -Force -ErrorAction Stop
          }
          catch {
            $result = 'ERROR_CACHE_DELETE'
            $diagnostics.Add("Cachepfad '$cachePath' konnte nicht bereinigt werden: $($_.Exception.ToString())")
          }
        }
      }

      # Dienste wieder starten
      foreach ($svc in @('bits','wuauserv')) {
        try { Start-Service -Name $svc -ErrorAction Stop }
        catch {
          $serviceStartFailed = $true
          $diagnostics.Add("Dienst '$svc' konnte nicht gestartet werden: $($_.Exception.ToString())")
        }
      }

      # Warte bis wuauserv läuft
      $waited = 0
      while ((Get-Service -Name wuauserv).Status -ne 'Running' -and $waited -lt $maxWait) {
        Start-Sleep -Seconds 1
        $waited++
      }
      if ((Get-Service -Name wuauserv).Status -ne 'Running') {
        $serviceStartFailed = $true
        $diagnostics.Add("Dienst 'wuauserv' lief nach $maxWait Sekunden noch nicht.")
      }
      if ($serviceStartFailed) { $result = 'SERVICE_FAILED' }

      # NEU: DetectNow auslösen damit WU frisch bei Microsoft sucht
      # Methode 1: wuauclt (klassisch, funktioniert auf allen Versionen)
      $wuaucltDiagnostic = $null
      try {
        & wuauclt.exe /detectnow 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { $wuaucltDiagnostic = "wuauclt.exe /detectnow endete mit Exitcode $LASTEXITCODE." }
      } catch { $wuaucltDiagnostic = "wuauclt.exe /detectnow fehlgeschlagen: $($_.Exception.ToString())" }

      # Methode 2: COM-Objekt (zuverlässiger auf neueren Systemen)
      $detectNowDiagnostic = $null
      try {
        $AutoUpdate = New-Object -ComObject Microsoft.Update.AutoUpdate
        $AutoUpdate.DetectNow()
      } catch { $detectNowDiagnostic = $_.Exception.ToString() }
      if ($wuaucltDiagnostic) { $diagnostics.Add($wuaucltDiagnostic) }

      # Warten bis der WU-Scan abgeschlossen ist
      Start-Sleep -Seconds $DetectNowWaitSec

      return [PSCustomObject]@{ Status = $result; DetectNowDiagnostic = $detectNowDiagnostic; Diagnostic = ($diagnostics -join [Environment]::NewLine) }
    }
    catch {
      return [PSCustomObject]@{ Status = 'ERROR'; DetectNowDiagnostic = $null; Diagnostic = $_.Exception.ToString() }
    }
  }

  # Wartezeit nach DetectNow aus Settings lesen (Standard 60 Sekunden)
  $detectWait = 60
  if ($UpdateSettings.DetectNowWaitSeconds -gt 0) {
    $detectWait = $UpdateSettings.DetectNowWaitSeconds
  }

  try {
    try {
      $result = Invoke-WindowsUpdateRemoteCommandWithTimeout -ComputerName $Servername -AuthInfo $AuthInfo `
        -ScriptBlock $clearCacheScript -ArgumentList @($detectWait) -TimeoutSeconds 300 -OperationName "Cache-Bereinigung auf $Servername" `
        -WriteLog $diagnosticLogOnly
    }
    catch {
      Write-ScriptLog "WARNUNG: Cache-Bereinigung via WinRM auf $Servername fehlgeschlagen; Details im Log."
      Write-WindowsUpdateDiagnostic -WriteLog $diagnosticLog -Operation 'Cache-Bereinigung' -Target $Servername -ErrorRecord $_ -Context @('Fallback=Update-Check wird fortgesetzt')
      $result = "SKIPPED"
    }

    if ($result -is [System.Management.Automation.PSCustomObject]) {
      if ($result.DetectNowDiagnostic) {
        Write-WindowsUpdateDiagnostic -WriteLog $diagnosticLog -Operation 'WindowsUpdate-AutoUpdate.DetectNow-Fallback' -Target $Servername -DiagnosticText $result.DetectNowDiagnostic -Context @('wuauclt /detectnow wurde zuvor ausgeführt')
      }
      if ($result.Diagnostic) {
        Write-WindowsUpdateDiagnostic -WriteLog $diagnosticLog -Operation 'Cache-Bereinigung remote' -Target $Servername -DiagnosticText $result.Diagnostic
      }
      $result = [string]$result.Status
    }

    switch -Wildcard ($result) {
      "SUCCESS"           { Write-ScriptLog "Cache (Download + DataStore) erfolgreich bereinigt auf ${Servername}. DetectNow wurde ausgelöst, ${detectWait}s gewartet." }
      "TIMEOUT_STOP_*"    { Write-ScriptLog "WARNUNG: Dienst $($result -replace 'TIMEOUT_STOP_','') konnte nicht gestoppt werden auf ${Servername} - Cache möglicherweise unvollständig bereinigt." }
      "SERVICE_FAILED"    { Write-ScriptLog "WARNUNG: wuauserv konnte nach dem Reset nicht gestartet werden auf ${Servername}." }
      "SKIPPED"           { Write-ScriptLog "Cache-Bereinigung auf ${Servername} übersprungen." }
      default             { Write-ScriptLog "Cache-Bereinigung auf ${Servername}: $result" }
    }
  }
  catch {
    Write-ScriptLog "WARNUNG: Cache-Bereinigung auf ${Servername} fehlgeschlagen; Details im Log."
    Write-WindowsUpdateDiagnostic -WriteLog $diagnosticLog -Operation 'Cache-Bereinigung' -Target $Servername -ErrorRecord $_ -Context @('Fallback=Update-Check wird fortgesetzt')
  }
}

Export-ModuleMember -Function Invoke-WindowsUpdateCheckCacheCleanup, New-WindowsUpdateCheckRedistributionNotice, New-WindowsUpdateCheckExternalSetupNotice, Get-WindowsUpdateCheckClientCertificate

