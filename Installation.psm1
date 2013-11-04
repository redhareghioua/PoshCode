# We're not using Requires because it just gets in the way on PSv2
#!Requires -Version 2 -Modules "Configuration"
#!Requires -Version 2 -Modules "ModuleInfo"
###############################################################################
## Copyright (c) 2013 by Joel Bennett, all rights reserved.
## Free for use under MS-PL, MS-RL, GPL 2, or BSD license. Your choice. 
###############################################################################
## Installation.psm1 defines the core commands for installing packages:
## Install-Module and Expand-ZipFile and Expand-Package
## It depends on the Configuration module and the Invoke-WebRequest cmdlet
## It depends on the ModuleInfo module

# FULL # BEGIN FULL: Don't include this in the installer script
$PoshCodeModuleRoot = Get-Variable PSScriptRoot -ErrorAction SilentlyContinue | ForEach-Object { $_.Value }
if(!$PoshCodeModuleRoot) {
  $PoshCodeModuleRoot = Split-Path $MyInvocation.MyCommand.Path -Parent
}
. $PoshCodeModuleRoot\Constants.ps1

if(!(Get-Command Invoke-WebReques[t] -ErrorAction SilentlyContinue)){
  Import-Module $PoshCodeModuleRoot\InvokeWeb
}
# if(!(Get-Command Import-Metadat[a] -ErrorAction SilentlyContinue)){
#   Import-Module $PoshCodeModuleRoot\ModuleInfo
# }

function Update-Module {
   <#
      .Synopsis
         Checks if you have the latest version of each module
      .Description
         Test the PackageManifestUri indicate if there's an upgrade available
   #>
   [CmdletBinding(SupportsShouldProcess=$true, ConfirmImpact="Medium")]
   param(
      # The name of the module to package
      [Parameter(ValueFromPipeline=$true)]
      [ValidateNotNullOrEmpty()] 
      $Module = "*",
   
      # Only test to see if there are updates available (don't do the actual updates)
      # This is similar to -WhatIf, except it outputs objects you can examine...
      [Alias("TestOnly")]
      [Switch]$ListAvailable,
   
      # Force an attempt to update even modules which don't have a PackageManifestUri
      [Switch]$Force,
   
      #  Specifies the client certificate that is used for a secure web request. Enter a variable that contains a certificate or a command or expression that gets the certificate.
      #  To find a certificate, use Get-PfxCertificate or use the Get-ChildItem cmdlet in the Certificate (Cert:) drive. If the certificate is not valid or does not have sufficient authority, the command fails.
      [System.Security.Cryptography.X509Certificates.X509Certificate[]]
      $ClientCertificate,
   
      #  Pass the default credentials
      [switch]$UseDefaultCredentials,
   
      #  Specifies a user account that has permission to send the request. The default is the current user.
      #  Type a user name, such as "User01" or "Domain01\User01", or enter a PSCredential object, such as one generated by the Get-Credential cmdlet.
      [System.Management.Automation.PSCredential]
      [System.Management.Automation.Credential()]
      [Alias("")]$Credential = [System.Management.Automation.PSCredential]::Empty,
   
      # Specifies that Authorization: Basic should always be sent. Requires $Credential to be set, and should only be used with https
      [ValidateScript({if(!($Credential -or $WebSession)){ throw "ForceBasicAuth requires the Credential parameter be set"} else { $true }})]
      [switch]$ForceBasicAuth,
   
      # Uses a proxy server for the request, rather than connecting directly to the Internet resource. Enter the URI of a network proxy server.
      # Note: if you have a default proxy configured in your internet settings, there is no need to set it here.
      [Uri]$Proxy,
   
      #  Pass the default credentials to the Proxy
      [switch]$ProxyUseDefaultCredentials,
   
      #  Pass specific credentials to the Proxy
      [System.Management.Automation.PSCredential]
      [System.Management.Automation.Credential()]
      $ProxyCredential= [System.Management.Automation.PSCredential]::Empty  
   )
   process {
      $ModuleInfo = $(
         foreach($m in Read-Module $Module -ListAvailable) {
            if($Force -or $m.PackageManifestUri) {
               if($m -is [Hashtable]) {
                  $m.Add("Update","Unknown")
                  New-Object PSObject -Property $m
               } else {
                  $m  | Add-Member NoteProperty Update -Value "Unknown" -Passthru -Force
               }
            }
         }
      )

   
      Write-Verbose "Testing for new versions of $(@($ModuleInfo).Count) modules."
      foreach($M in $ModuleInfo){
         Write-Progress -Activity "Updating module $($M.Name)" -Status "Checking for new version (current: $($M.Version))" -id 0
         if(!$M.PackageManifestUri) {
            # TODO: once the search domain is up, we need to do a search here.
            Write-Warning "Unable to check for update to $($M.Name) because there is no PackageManifestUri"
            continue
         }
   
         ## Download the PackageManifestUri and see what version we got...
         $WebParam = @{Uri = $M.PackageManifestUri}
         try { # A 404 is a terminating error, but I still want to handle it my way.
            $VPR, $VerbosePreference = $VerbosePreference, "SilentlyContinue"
            $WebResponse = Invoke-WebRequest @WebParam -ErrorVariable WebException -ErrorAction SilentlyContinue
         } catch [System.Net.WebException] {
            if(!$WebException) { $WebException = @($_.Exception) }
         } finally {
            $VPR, $VerbosePreference = $VerbosePreference, $VPR
         }

         if($WebException){
            $Source = $WebException[0].InnerException.Response.StatusCode
            if(!$Source) { $Source = $WebException[0].InnerException }

            Write-Warning "Can't fetch ModuleInfo from $($M.PackageManifestUri) for $($M.Name): $(@($WebException)[0].Message)"
            continue # Check the rest of the modules...
         }

         try {
            $null = $WebResponse.RawContentStream.Seek(0,"Begin")
            $reader = New-Object System.IO.StreamReader $WebResponse.RawContentStream, $WebResponse.BaseResponse.CharacterSet
            $content = $reader.ReadToEnd()
         } catch {
            $content= $WebResponse.Content
         } finally {
            if($reader) { $reader.Close() }
         }

   
         # Get the metadata straight from the WebResponse:
         # Now lets find out what the latest version is:
         $Mi = Import-Metadata $content
   
         $M.Update = [Version]$Mi.ModuleVersion
         Write-Verbose "Current version of $($M.Name) is $($M.Update), you have $($M.Version)"
   
         # They're going to want to install it where it already is:
         # But we want to use the PSModulePath roots, not the path to the actual folder:
         $Paths = $Env:PSModulePath -split ";" | %{ $_.Trim("/\ ") } | sort-object length -desc
         foreach($Path in $Paths) {
           if($M.ModuleManifestPath.StartsWith($Path)) {
             $InstallPath = $Path
             break
           }
         }
   
         # If we need to update ...
         if(!$ListAvailable -and ($M.Update -gt $M.ModuleVersion)) {
   
            if($PSCmdlet.ShouldProcess("Upgrading the module '$($M.Name)' from version $($M.Version) to $($M.Update)", "Update '$($M.Name)' from version $($M.Version) to $($M.Update)?", "Updating $($M.Name)" )) {
               if(!$InstallPath) {
                  $InstallPath = Split-Path (Split-Path $M.ModuleManifestPath)
               }
      
               $InstallParam = @{InstallPath = $InstallPath} + $PsBoundParameters
               $null = "Module", "ListAvailable" | % { $InstallParam.Remove($_) }
      
               $InstallParam.Add("Package", $Mi.DownloadUri)

               Write-Verbose "Install Module Upgrade:`n$( $InstallParam | Out-String )"
      
               Install-Module @InstallParam
            }
         } elseif($ListAvailable) {
            Write-Verbose "NOT UPGRADING. $($M.ModuleName) version is $($M.Update), you have $($M.ModuleVersion)"

            $M = $M | Add-Member -Type NoteProperty -Name PSModulePath -Value $InstallPath -Passthru
            $M.PSTypeNames.Insert(0, "PoshCode.ModuleInfo.Update")
            Write-Output $M
         }
      }
   }
}

# Internal function called by Expand-Package when the package isn't a PoshCode package.
# NOTE: ZIP File Support not included in Install.ps1
# TODO: Validate Output is a valid module: Specifically check folder name = module manifest name
function Expand-ZipFile {
   #.Synopsis
   #   Expand a zip file, ensuring it's contents go to a single folder ...
   [CmdletBinding(SupportsShouldProcess=$true)]
   param(
      # The path of the zip file that needs to be extracted
      [Parameter(Position=0, Mandatory=$true, ValueFromPipelineByPropertyName=$true)]
      [Alias("PSPath")]
      $FilePath,
   
      # The base path where we want the output folder to end up
      [Parameter(Position=1, Mandatory=$true)] 
      $OutputPath,

      # When the PackagePath refers to a .zip archive instead of a module packages, the ZipFolder is a subfolder in the zip which contains the module. Only files within this folder will be unpacked.
      [Parameter(ValueFromPipelineByPropertyName=$true)]
      [AllowNull()][AllowEmptyString()]
      [String]$ZipFolder,

      # Make sure the resulting folder is always named the same as the archive
      [Switch]$Force
   )
   process {
      $ZipFile = Get-Item $FilePath -ErrorAction Stop
      $OutputFolderName = [IO.Path]::GetFileNameWithoutExtension($ZipFile.FullName)
      
      # Figure out where we'd prefer to end up:
      if(Test-Path $OutputPath -Type Container) {
         # If they pass a path that exists, resolve it:
         $OutputPath = Convert-Path $OutputPath
         
         # If it's not empty, assume they want us to make a folder there:
         # Unless it already exists:
         if((Get-ChildItem $OutputPath) -and ($OutputFolderName -ne (Split-Path $OutputPath -Leaf))) {
            $Destination = (New-Item (Join-Path $OutputPath $OutputFolderName) -Type Directory -Force).FullName
            # Otherwise, we could just use that folder (maybe):
         } else {
            $Destination = $OutputPath
         }
      } else {
         # Otherwise, assume they want us to make a new folder:
         $Destination = (New-Item $OutputPath -Type Directory -Force).FullName
      }

      # If the Destination Directory is empty, or they want to overwrite
      if($Force -Or !(Get-ChildItem $Destination) -or  $PSCmdlet.ShouldContinue("The output location '$Destination' already exists, and is not empty: do you want to replace it?", "Installing $FilePath", [ref]$ConfirmAllOverwriteOnInstall, [ref]$RejectAllOverwriteOnInstall)) {
         $success = $false
         if(Test-Path $Destination) {
            Remove-Item $Destination -Recurse -Force -ErrorAction Stop
         }
         $Destination = (New-Item $Destination -Type Directory -Force).FullName
      } else {
         $PSCmdlet.ThrowTerminatingError( (New-Object System.Management.Automation.ErrorRecord (New-Object System.Management.Automation.HaltCommandException "Can't overwrite $Destination folder: User Refused"), "ShouldContinue:False", "OperationStopped", $_) )
      }
      
      # If they're looking for a specific zpifolder, then we put everything in a temporary subfolder so we can delete it later
      if($ZipFolder){
         $Destination = Join-Path $Destination __PC_temp_Install__
         $Destination = (New-Item $Destination -Type Directory -Force).FullName
      }
      Write-Verbose "Unzipping: $($ZipFile.FullName)"
      Write-Verbose "Destination: $Destination"

      try { 
         Add-Type -Assembly System.IO.Compression.FileSystem -ErrorAction SilentlyContinue 
      } catch { <# We don't need to know if it fails, we'll test for the type: #> }
      if("System.IO.Compression.ZipFile" -as [Type]) {
         # If we have .Net 4.5, this is better (no GUI)
         try {
            $Archive = [System.IO.Compression.ZipFile]::Open( $ZipFile.FullName, "Read" )
            [System.IO.Compression.ZipFileExtensions]::ExtractToDirectory( $Archive, $Destination )
         } catch { Write-Error $_.Message } finally {
            $Archive.Dispose()
         }
      } else {
         # Note: the major problem with this method is that it has GUI!
         $shellApplication = new-object -com Shell.Application
         $zipPackage = $shellApplication.NameSpace($ZipFile.FullName)
         $shellApplication.NameSpace($Destination).CopyHere($zipPackage.Items())
      }

      if($ZipFolder) {
         $ModuleZipFolder = Convert-Path (Join-Path $Destination $ZipFolder)
         $DestinationRoot = Split-Path $Destination
         Write-Verbose "Move items from ZipFolder: '$ModuleZipFolder' to '$DestinationRoot'"
         if(Test-Path $ModuleZipFolder) {
            Move-Item $ModuleZipFolder -Destination $DestinationRoot -ErrorAction Stop
            Remove-Item $Destination -Recurse
         }
         $Destination = $DestinationRoot
      }

      # Now, a few corrective options:
      # If there are no items, bail.
      $RootItems = @(Get-ChildItem $Destination)
      $RootItemCount = $RootItems.Count
      if($RootItemCount -lt 1) {
         throw "There were no items in the Archive: $($ZipFile.FullName)"
      }
      
      # If there's nothing there but another folder, move it up one.
      while($RootItemCount -eq 1 -and $RootItems[0].PSIsContainer) {
         if($Force -or ($RootItems[0].Name -eq (Split-Path $Destination -Leaf))) { 
            Write-Verbose "Extracted one folder '$($RootItems[0].Name)' -Force:$Force moving items to '$Destination'"
            # Keep the archive named folder
            Move-Item (join-path $RootItems[0].FullName *) $Destination
            # Remove the child folder
            Remove-Item $RootItems[0].FullName
         } else {
            $NewDestination = Join-Path (Split-Path $Destination) $RootItems[0].Name
            Write-Verbose "Extracted One Folder '$RootItems' - moving items to '$NewDestination'"         
            if(Test-Path $NewDestination) {
               if(Get-ChildItem $NewDestination) {
                  if($Force -or $PSCmdlet.ShouldContinue("The OutputPath exists and is not empty. Do you want to replace the contents of '$NewDestination'?", "Deleting contents of '$NewDestination'")) {
                     Remove-Item $NewDestination -Recurse -ErrorAction Stop
                  } else {
                     throw "OutputPath '$NewDestination' Exists and is not empty."
                  }
               }
               # move the contents to the new location
               Write-Verbose "Move-Item '$(join-path $RootItems[0].FullName *)' '$NewDestination'"
               Move-Item (join-path $RootItems[0].FullName *) $NewDestination
            } else {
               # move the whole folder to the new location
               Write-Verbose "Move the folder '$($RootItems[0].Name)' to '$(Split-Path $NewDestination)'"
               Move-Item $RootItems[0].FullName (Split-Path $NewDestination)
            }
            Remove-Item $Destination -Recurse
            $Destination = $NewDestination
         }
      
         $RootItems = @(Get-ChildItem $Destination)
         $RootItemCount = $RootItems.Count
         if($RootItemCount -lt 1) {
            throw "There were no items in the Archive: $($ZipFile.FullName)"
         }
      }

      # Finally, double-check the file name (it's likely to be Name-v.x.x)
      $BaseName = [IO.Path]::GetFileNameWithoutExtension($Destination)
      Write-Verbose "Test: $Destination\$BaseName.psd1"
      if(!(Test-Path (Join-Path $Destination "${BaseName}.psd1"))) {
         $BaseName, $null = $BaseName -Split '-'
         Write-Verbose "Test: $Destination\$BaseName.psd1"
         if(Test-Path (Join-Path $Destination "${BaseName}.psd1")) {
            Write-Verbose "Rename-Item $Destination $BaseName"
            $Destination = Rename-Item $Destination $BaseName
         } else {
            Write-Warning "Module manifest not found in $Destination"
         }
      }

      Write-Verbose "Return '$Destination' from Expand-ZipFile"
      # Output the new folder
      Get-Item $Destination
   }
}
# FULL # END FULL

function Install-Module {
   #.Synopsis
   #   Install a module package to the module 
   [CmdletBinding(SupportsShouldProcess=$true, ConfirmImpact="Medium", DefaultParameterSetName="UserPath")]
   param(
      # The package file to be installed
      [Parameter(ValueFromPipelineByPropertyName=$true, Mandatory=$true, Position=0)]
      [Alias("PSPath","PackagePath","PackageManifestUri","DownloadUri")]
      $Package,
   
      # A custom path to install the module to
      [Parameter(ParameterSetName="InstallPath", Mandatory=$true, Position=1)]
      [Alias("PSModulePath")]
      $InstallPath,

      # When installing modules from .zip archives instead of module packages, the ZipFolder is a subfolder in the zip which contains the module. Only files within this folder will be unpacked.
      [Parameter(ValueFromPipelineByPropertyName=$true)]
      [String]$ZipFolder,
   
      # If set, the module is installed to the Common module path (as specified in Packaging.ini)
      [Parameter(ParameterSetName="CommonPath", Mandatory=$true)]
      [Switch]$CommonPath,
   
      # If set, the module is installed to the User module path (as specified in Packaging.ini). This is the default.
      [Parameter(ParameterSetName="UserPath")]
      [Switch]$UserPath,
   
      # If set, overwrite existing modules without prompting
      [Switch]$Force,
   
      # If set, the module is imported immediately after install
      [Switch]$Import,
   
      # If set, output information about the files as well as the module 
      [Switch]$Passthru,
   
      #  Specifies the client certificate that is used for a secure web request. Enter a variable that contains a certificate or a command or expression that gets the certificate.
      #  To find a certificate, use Get-PfxCertificate or use the Get-ChildItem cmdlet in the Certificate (Cert:) drive. If the certificate is not valid or does not have sufficient authority, the command fails.
      [System.Security.Cryptography.X509Certificates.X509Certificate[]]
      $ClientCertificate,
   
      #  Pass the default credentials
      [switch]$UseDefaultCredentials,
   
      #  Specifies a user account that has permission to send the request. The default is the current user.
      #  Type a user name, such as "User01" or "Domain01\User01", or enter a PSCredential object, such as one generated by the Get-Credential cmdlet.
      [System.Management.Automation.PSCredential]
      [System.Management.Automation.Credential()]
      [Alias("")]$Credential = [System.Management.Automation.PSCredential]::Empty,
   
      # Specifies that Authorization: Basic should always be sent. Requires $Credential to be set, and should only be used with https
      [ValidateScript({if(!($Credential -or $WebSession)){ throw "ForceBasicAuth requires the Credential parameter be set"} else { $true }})]
      [switch]$ForceBasicAuth,
   
      # Uses a proxy server for the request, rather than connecting directly to the Internet resource. Enter the URI of a network proxy server.
      # Note: if you have a default proxy configured in your internet settings, there is no need to set it here.
      [Uri]$Proxy,
   
      #  Pass the default credentials to the Proxy
      [switch]$ProxyUseDefaultCredentials,
   
      #  Pass specific credentials to the Proxy
      [System.Management.Automation.PSCredential]
      [System.Management.Automation.Credential()]
      $ProxyCredential= [System.Management.Automation.PSCredential]::Empty     
   )
   dynamicparam {
      $paramDictionary = new-object System.Management.Automation.RuntimeDefinedParameterDictionary
      if(Get-Command Get-ConfigDat[a] -ListImported -ErrorAction SilentlyContinue) {
         foreach( $name in (Get-ConfigData).InstallPaths.Keys ){
            if("CommonPath","UserPath" -notcontains $name) {
               $param = new-object System.Management.Automation.RuntimeDefinedParameter( $Name, [Switch], (New-Object Parameter -Property @{ParameterSetName=$Name;Mandatory=$true}))
               $paramDictionary.Add($Name, $param)
            }
         } 
      }
      return $paramDictionary
   }  
   begin {
      if($PSCmdlet.ParameterSetName -ne "InstallPath") {
         $Config = Get-ConfigData
         switch($PSCmdlet.ParameterSetName){
            "InstallPath" {}
            default { $InstallPath = $Config.InstallPaths.($PSCmdlet.ParameterSetName) }
            # "SystemPath" { $InstallPath = $Config.InstallPaths.SystemPath }
         }
         $null = $PsBoundParameters.Remove(($PSCmdlet.ParameterSetName))
         $null = $PsBoundParameters.Add("InstallPath", $InstallPath)
      }


      if(Test-Path $InstallPath) {
         if(Test-Path $InstallPath -PathType Leaf) {
            $InstallPath = Split-Path $InstallPath
         }
      } else {
         $InstallPath = "$InstallPath".TrimEnd("\")
   
         # Warn them if they're installing in an irregular location
         [string[]]$ModulePaths = $(
            foreach($psmPath in $Env:PSModulePath -split "\\;") {
               Resolve-Path $psmPath -ErrorAction SilentlyContinue -ErrorVariable psmpErr
               if($psmpErr) { $psmPath }
            }
         )

         if(!($ModulePaths -match ([Regex]::Escape($InstallPath) + ".*"))) {
            if((Get-PSCallStack | Where-Object { $_.Command -eq "Install-Module" }).Count -le 1) {
               Write-Warning "Install path '$InstallPath' does not exist, and is not in your PSModulePath!"

               if($Force -Or $PSCmdlet.ShouldContinue("Do you want to create module folder: '$InstallPath'", "Creating module folder that's not in PSModulePath")) {
                  $null = New-Item $InstallPath -ItemType Directory
               } else {
                  $PSCmdlet.ThrowTerminatingError( (New-Object System.Management.Automation.ErrorRecord (New-Object System.IO.DirectoryNotFoundException "$InstallPath does not exist"), "InstallPath not found", "ObjectNotFound", $InstallPath) )
               }
            }
         } elseif($PSCmdlet.ShouldProcess("Creating Module InstallPath: '$InstallPath'", "Creating Module Path", "Create Module InstallPath" )) {
            $null = New-Item $InstallPath -ItemType Directory
         } else {
            $PSCmdlet.ThrowTerminatingError( (New-Object System.Management.Automation.ErrorRecord (New-Object System.IO.DirectoryNotFoundException "$InstallPath does not exist"), "InstallPath not found", "ObjectNotFound", $InstallPath) )
         }
      }
   }
   process {
      # There are a few possibilities here: they might be installing from a web module, in which case we need to download first
      # If we need to download, that's a seperate pre-install step:
      if("$Package" -match "^https?://" ) {
         $WebParam = @{} + $PsBoundParameters
         $WebParam.Add("Uri",$Package)
         $null = "Package", "InstallPath", "Common", "User", "Force", "Import", "Passthru", "ZipFolder", "ErrorAction", "ErrorVariable" | % { $WebParam.Remove($_) }
         try { # A 404 is a terminating error, but I still want to handle it my way.
            $VPR, $VerbosePreference = $VerbosePreference, "SilentlyContinue"
            $WebResponse = Invoke-WebRequest @WebParam -ErrorVariable WebException -ErrorAction SilentlyContinue
         } catch [System.Net.WebException] {
            if(!$WebException) { $WebException = @($_.Exception) }
         } finally {
            $VPR, $VerbosePreference = $VerbosePreference, $VPR
         }
         if($WebException){
            $Source = @($WebException)[0].InnerException.Response.StatusCode
            if(!$Source) { $Source = @($WebException)[0].InnerException }

            $PSCmdlet.ThrowTerminatingError( (New-Object System.Management.Automation.ErrorRecord @($WebException)[0], "Can't Download $($WebParam.Uri)", "InvalidData", $Source) )
         }

         $FileName = ([regex]'(?i)filename=(.*)$').Match( $WebResponse.Headers["Content-Disposition"] ).Groups[1].Value
         if(!$FileName) {
            $FileName = [IO.Path]::GetFileName( $WebResponse.BaseResponse.ResponseUri.AbsolutePath )
         }

         $ext = $(if($WebResponse.Content -is [Byte[]]) { $ModulePackageExtension } else { $ModuleInfoExtension })

         if(!$FileName) {
            $FileName = [IO.path]::ChangeExtension( [IO.Path]::GetRandomFileName(), $ext )
         } 
         elseif(![IO.path]::HasExtension($FileName) -or !($ModuleInfoExtension, $ModulePackageExtension -eq [IO.Path]::GetExtension($FileName))) {
            $FileName = [IO.path]::ChangeExtension( $FileName, $ext )
         }

         $Package = Join-Path $InstallPath $FileName

         if( $WebResponse.Content -is [Byte[]] ) {
            Set-Content $Package $WebResponse.Content -Encoding Byte
         } else {
            Set-Content $Package $WebResponse.Content
         }         
      }

      # At this point, the Package must be a file 
      # TODO: consider supporting install from a (UNC Path) folder for corporate environments
      $PackagePath = Resolve-Path $Package -ErrorAction Stop

      ## If we just got back a module manifest (text file vs. zip/psmx)
      ## Figure out the real package Uri and recurse so we can download it
      # TODO: Check the file contents instead (it's just testing extensions right now)
      if($ModuleInfoExtension -eq [IO.Path]::GetExtension($PackagePath)) {
         Write-Verbose "Downloaded file '$PackagePath' is just a manifest, get DownloadUri."
         $MI = Import-Metadata $PackagePath -ErrorAction "SilentlyContinue"
         Remove-Item $PackagePath

         if($Mi.DownloadUri) {
            Write-Verbose "Found DownloadUri '$($Mi.DownloadUri)' in Module Info file '$PackagePath' -- Installing by Uri"
            $PsBoundParameters["Package"] = $Mi.DownloadUri
            Install-Module @PsBoundParameters
            return
         } else {
            # TODO: Change this Error Category
            $PSCmdlet.ThrowTerminatingError( (New-Object System.Management.Automation.ErrorRecord (New-Object System.IO.FileFormatException "$PackagePath is not a valid package or package manifest."), "Invalid Package", "InvalidResult", $Package) )
         }
      }


      # At this point $PackagePath is a local file, but it might be a .psmx, or .zip or .nupkg instead
      Write-Verbose "PackagePath: $PackagePath"
      Write-Verbose "InstallPath: $InstallPath"
      $Manifest = Read-Module $PackagePath
      # Expand the package (psmx/zip: npkg not supported yet)
      $ModuleFolder = Expand-Package $PackagePath $InstallPath -Force:$Force -ZipFolder:$ZipFolder -ErrorAction Stop

      # On ocassions when we downloaded the package to the Install Path, we want to rename it if 
      # If the installed module ended up having a totally different name than the source package
      if(((Split-Path $PackagePath) -eq $InstallPath) -and ([IO.Path]::GetFileName($PackagePath) -notlike "$(Split-Path $ModuleFolder -Leaf)*")) {
         if($PackageExt = [IO.Path]::GetExtension($PackagePath)) {
            $NewPackagePath = "$((Convert-Path $ModuleFolder).TrimEnd('\'))$PackageExt"
            Write-Verbose "Rename downloaded $PackagePath to $NewPackagePath"
            if((Split-Path $NewPackagePath) -eq $InstallPath) {
               Move-Item $PackagePath $NewPackagePath -ErrorAction SilentlyContinue
            }
         }
      }

      if(!(Test-Path (Join-Path $ModuleFolder.FullName $ModuleInfoFile))) {
         Write-Warning "The archive was unpacked to $($ModuleFolder.Fullname), but is not supported for upgrade (it is missing the package.psd1 manifest)"
      }

      if(!$Manifest) {
         Write-Verbose "Read-Module $($ModuleFolder.Name) -ListAvailable"
         $Manifest = Read-Module $ModuleFolder.Name -ListAvailable | Where-Object { $_.ModuleBase -eq $ModuleFolder.FullName }
         Write-Verbose "Module Manifest loaded by Read-Module:`n$($Manifest |out-default)"
      }

      # Now verify the RequiredModules are available, and try installing them.
      if($Manifest -and $Manifest.RequiredModules) {
         $FailedModules = @()
         foreach($RequiredModule in $Manifest.RequiredModules ) {
            # If the module is available ... 
            $VPR = "SilentlyContinue"
            $VPR, $VerbosePreference = $VerbosePreference, $VPR

            if($Module = Read-Module -Name $RequiredModule.ModuleName -ListAvailable) {
               $VPR, $VerbosePreference = $VerbosePreference, $VPR
               if($Module = $Module | Where-Object { $_.Version -ge $RequiredModule.ModuleVersion }) {
                  if($Import) {
                     Import-Module -Name $RequiredModule.ModuleName -MinimumVersion
                  }
                  continue
               } else {
                  Write-Warning "The package $PackagePath requires $($RequiredModule.ModuleVersion) of the $($RequiredModule.ModuleName) module. Yours is version $($Module.Version). Trying upgrade:"
               }
            } else {
               Write-Warning "The package $PackagePath requires the $($RequiredModule.ModuleName) module. Trying install:"
            }

            # Check for a local copy, maybe we get lucky:
            $Folder = Split-Path $PackagePath
            # Check with and without the version number in the file name:
            if(($RequiredFile = Get-Item (Join-Path $Folder "$($RequiredModule.ModuleName)*$ModulePackageExtension") | 
                                  Sort-Object { [IO.Path]::GetFileNameWithoutExtension($_) } | 
                                  Select-Object -First 1) -and
               (Read-Module $RequiredFile).Version -ge $RequiredModule.ModuleVersion)
            {
               Write-Warning "Installing required module $($RequiredModule.ModuleName) from $RequiredFile"
               Install-Module $RequiredFile $InstallPath
               continue
            }

            # If they have a PackageManifestUri, we can try that:
            if($RequiredModule.PackageManifestUri) {
               Write-Warning "Installing required module $($RequiredModule.MOduleName) from $($RequiredModule.PackageManifestUri)"
               Install-Module $RequiredModule.PackageManifestUri $InstallPath
               continue
            } 
   
            Write-Warning "The module package does not have a PackageManifestUri for the required module $($RequiredModule.MOduleName), and there's not a local copy."
            $FailedModules += $RequiredModule
            continue
         }
         if($FailedModules) {
            Write-Error "Unable to resolve required modules."
            Write-Output $FailedModules
            return # TODO: Should we install anyway? Prompt?
         }
      }

      if($Import -and $ModuleFolder) {
         Write-Verbose "Import-Module Requested. Importing $($ModuleFolder.Name)"
         Import-Module $ModuleFolder.Name -Passthru:$Passthru
      } elseif($ModuleFolder) {
         Write-Verbose "No Import. Read-Module: $($ModuleFolder.Name) -ListAvailable"
         Read-Module $ModuleFolder.Name -ListAvailable | Where-Object { $_.ModuleBase -eq $ModuleFolder.FullName }
      }
   }
}

# Internal function called by Install-Module to unpack the Module Package
# TODO: Test (and fix) behavior with Nuget packages
#       * Ideally: make sure we only end up with a single folder with the same name as the main assembly
#       * Ideally: if it's a nuget development package, generate a module manifest
#       * Ideally: find and test some of the nupkg files made by PSGet lovers -- make sure we do the right thing for them 
function Expand-Package {
   #.Synopsis
   #   Expand a zip file, ensuring it's contents go to a single folder ...
   [CmdletBinding(SupportsShouldProcess=$true)]
   param(
      # The path of the module package that needs to be extracted
      [Parameter(Position=0, Mandatory=$true, ValueFromPipelineByPropertyName=$true)]
      [Alias("PSPath")]
      $PackagePath,

      # The base path where we want the module folder to end up
      [Parameter(Position=1)] 
      $InstallPath = $(Split-Path $PackagePath),
      
      # When the PackagePath refers to a .zip archive instead of a module packages, the ZipFolder is a subfolder in the zip which contains the module. Only files within this folder will be unpacked.
      [Parameter(ValueFromPipelineByPropertyName=$true)]
      [AllowNull()][AllowEmptyString()]
      [String]$ZipFolder,

      # If set, overwrite existing modules without prompting
      [Switch]$Force,

      # If set, output information about the files as well as the module 
      [Switch]$Passthru    
   )
   begin {
      if(!(Test-Path variable:RejectAllOverwriteOnInstall)){
         $RejectAllOverwriteOnInstall = $false;
         $ConfirmAllOverwriteOnInstall = $false;
      }
   }
   process {
      try {
         $success = $false
         $PackagePath = Convert-Path $PackagePath
         $Package = [System.IO.Packaging.Package]::Open( $PackagePath, "Open", "Read" )
         $ModuleVersion = if($Package.PackageProperties.Version) {$Package.PackageProperties.Version } else {""}
         Write-Verbose ($Package.PackageProperties|Select-Object Title,Version,@{n="Guid";e={$_.Identifier}},Creator,Description, @{n="Package";e={$PackagePath}}|Out-String)

         if($ModuleResult = $ModuleName = $Package.PackageProperties.Title) {
            if($InstallPath -match ([Regex]::Escape($ModuleName)+'$')) {
               $InstallPath = Split-Path $InstallPath
            }
         } else {
            $Name = Split-Path $PackagePath -Leaf
            $Name = @($Name -split "[\-\.]")[0]
            if($InstallPath -match ([Regex]::Escape((Join-Path (Split-Path $PackagePath) $Name)))) {
               $InstallPath = Split-Path $InstallPath
            }
         }

         if(!@($Package.GetParts())) {
            $Package.Close()
            $Package.Dispose()
            $Package = $null

            $Output = Expand-ZipFile -FilePath $PackagePath -OutputPath $InstallPath -ZipFolder:$ZipFolder -Force:$Force
            if($Passthru) { $Output }
            return
         }

         if($PSCmdlet.ShouldProcess("Extracting the module '$ModuleName' to '$InstallPath\$ModuleName'", "Extract '$ModuleName' to '$InstallPath\$ModuleName'?", "Installing $ModuleName $ModuleVersion" )) {
            if($Force -Or !(Test-Path "$InstallPath\$ModuleName" -ErrorAction SilentlyContinue) -Or $PSCmdlet.ShouldContinue("The module '$InstallPath\$ModuleName' already exists, do you want to replace it?", "Installing $ModuleName $ModuleVersion", [ref]$ConfirmAllOverwriteOnInstall, [ref]$RejectAllOverwriteOnInstall)) {
               if(Test-Path "$InstallPath\$ModuleName") {
                  Remove-Item "$InstallPath\$ModuleName" -Recurse -Force -ErrorAction Stop
               }
               $ModuleResult = New-Item -Type Directory -Path "$InstallPath\$ModuleName" -Force -ErrorVariable FailMkDir
             
               ## Handle the error if they asked for -Common and don't have permissions
               if($FailMkDir -and @($FailMkDir)[0].CategoryInfo.Category -eq "PermissionDenied") {
                  throw "You do not have permission to install a module to '$InstallPath\$ModuleName'. You may need to be elevated."
               }

               foreach($part in $Package.GetParts() | Where-Object {$_.Uri -match ("^/" + $ModuleName)}) {
                  $fileSuccess = $false
                  # Copy the data to the file system
                  try {
                     if(!(Test-Path ($Folder = Split-Path ($File = Join-Path $InstallPath $Part.Uri)) -EA 0) ){
                        $null = New-Item -Type Directory -Path $Folder -Force
                     }
                     Write-Verbose "Unpacking $File"
                     $writer = [IO.File]::Open( $File, "Create", "Write" )
                     $reader = $part.GetStream()

                     Copy-Stream $reader $writer -Activity "Writing $file"
                     $fileSuccess = $true
                  } catch [Exception] {
                     $PSCmdlet.WriteError( (New-Object System.Management.Automation.ErrorRecord $_.Exception, "Unexpected Exception", "InvalidResult", $_) )
                  } finally {
                     if($writer) {
                        $writer.Close()
                        $writer.Dispose()
                     }
                     if($reader) {
                        $reader.Close()
                        $reader.Dispose()
                     }
                  }
                  if(!$fileSuccess) { throw "Couldn't unpack to $File." }
                  if($Passthru) { Get-Item $file }
               }
               $success = $true
            } else { # !Force
               $Import = $false # Don't _EVER_ import if they refuse the install
            }        
         } # ShouldProcess
         if(!$success) { $PSCmdlet.WriteError( (New-Object System.Management.Automation.ErrorRecord (New-Object System.Management.Automation.HaltCommandException "Can't overwrite $ModuleName module: User Refused"), "ShouldContinue:False", "OperationStopped", $_) ) }
      } catch [Exception] {
         $PSCmdlet.WriteError( (New-Object System.Management.Automation.ErrorRecord $_.Exception, "Unexpected Exception", "InvalidResult", $_) )
      } finally {
         if($Package) {
            $Package.Close()
            # # ZipPackage doesn't contain a method named Dispose (causes error in PS 2)
            # # For the Package class, Dispose and Close perform the same operation
            # # There is no reason to call Dispose if you call Close, or vice-versa.
            # $Package.Dispose()
         }
      }
      if($success) {
         Write-Output $ModuleResult
      }
   }
}

# Internal function: Copy data from one stream to another
# Used by Expand-Package and New-Module...
function Copy-Stream {
  #.Synopsis
  #   Copies data from one stream to another
  param(
    # The source stream to read from
    [IO.Stream]
    $reader,

    # The destination stream to write to
    [IO.Stream]
    $writer,

    [string]$Activity = "File Packing",

    [Int]
    $Length = 0
  )
  end {
    $bufferSize = 0x1000 
    [byte[]]$buffer = new-object byte[] $bufferSize
    [int]$sofar = [int]$count = 0
    while(($count = $reader.Read($buffer, 0, $bufferSize)) -gt 0)
    {
      $writer.Write($buffer, 0, $count);

      $sofar += $count
      if($Length -gt 0) {
         Write-Progress -Activity $Activity  -Status "Copied $sofar of $Length" -ParentId 0 -Id 1 -PercentComplete (($sofar/$Length)*100)
      } else {
         Write-Progress -Activity $Activity  -Status "Copied $sofar bytes..." -ParentId 0 -Id 1
      }
    }
    Write-Progress -Activity "File Packing" -Status "Complete" -ParentId 0 -Id 1 -Complete
  }
}
