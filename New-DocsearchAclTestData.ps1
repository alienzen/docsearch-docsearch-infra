<#
.SYNOPSIS
  Cree les comptes/groupes locaux et les fichiers de test necessaires
  pour valider le filtrage ACL docsearch sur le partage CIFS
  \\192.168.56.1\partage.

.DESCRIPTION
  A executer EN LOCAL (pas via le partage reseau) sur la machine qui
  heberge "partage", dans un PowerShell lance en administrateur.

  Cree :
    - Groupes locaux : docsearch-admins, docsearch-users
    - Comptes locaux : alice.admin (membre des deux groupes),
      bob.user (membre de docsearch-users seulement) -- memes noms et
      appartenances que les comptes de test de la stack LDAP docsearch,
      uniquement pour la lisibilite humaine (aucun lien technique entre
      les deux annuaires, voir la discussion associee).
      Comptes crees SANS mot de passe et DESACTIVES pour la connexion :
      ils n'existent que pour leur SID, jamais pour une ouverture de
      session reelle.
    - Un dossier <SharePath>\documents\acl-test\ avec 3 fichiers, une
      ACE AJOUTEE sur chacun (pas de remplacement -- les permissions
      heritees du dossier parent restent intactes, donc le compte
      utilise par docsearch pour lire le partage garde l'acces qu'il a
      deja) :
        public.txt        -> Tout le monde (Everyone)
        admins-only.txt    -> docsearch-admins uniquement
        users-only.txt     -> docsearch-users uniquement

  Affiche a la fin les SID des comptes/groupes crees, a transmettre
  pour renseigner CIFS_SID_MAP cote docsearch (docsearch-infra/.env) --
  voir acl_extractor.py:extract_windows_acl() dans docsearch-ingestion.

.PARAMETER SharePath
  Chemin LOCAL (pas le chemin UNC) du dossier partage en "partage",
  ex: C:\Partage.

.EXAMPLE
  .\New-DocsearchAclTestData.ps1 -SharePath C:\Partage
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$SharePath
)

$ErrorActionPreference = "Stop"

$currentPrincipal = New-Object Security.Principal.WindowsPrincipal(
    [Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw "A executer dans un PowerShell lance en tant qu'administrateur."
}
if (-not (Test-Path $SharePath)) {
    throw "Chemin introuvable : $SharePath"
}

# ── Groupes locaux ──────────────────────────────────────────────────
foreach ($group in "docsearch-admins", "docsearch-users") {
    if (-not (Get-LocalGroup -Name $group -ErrorAction SilentlyContinue)) {
        New-LocalGroup -Name $group -Description "Groupe de test docsearch (ACL CIFS)" | Out-Null
        Write-Host "Groupe cree : $group"
    } else {
        Write-Host "Groupe deja present : $group"
    }
}

# ── Comptes locaux (sans mot de passe, desactives) ──────────────────
$accounts = [ordered]@{
    "alice.admin" = @("docsearch-admins", "docsearch-users")
    "bob.user"    = @("docsearch-users")
}

foreach ($login in $accounts.Keys) {
    if (-not (Get-LocalUser -Name $login -ErrorAction SilentlyContinue)) {
        New-LocalUser -Name $login -NoPassword -FullName $login `
            -Description "Compte de test docsearch (ACL CIFS)" | Out-Null
        Disable-LocalUser -Name $login
        Write-Host "Compte cree (desactive) : $login"
    } else {
        Write-Host "Compte deja present : $login"
    }
    foreach ($group in $accounts[$login]) {
        Add-LocalGroupMember -Group $group -Member $login -ErrorAction SilentlyContinue
    }
}

# ── Dossier + fichiers de test ───────────────────────────────────────
$testDir = Join-Path $SharePath "documents\acl-test"
New-Item -ItemType Directory -Path $testDir -Force | Out-Null

$files = [ordered]@{
    # "*S-1-1-0" (Everyone en SID brut, prefixe * pour icacls) plutot que
    # le nom "Everyone" -- resolution de nom pas fiable selon la langue
    # d'installation de Windows (ex: "Tout le monde" en localisation FR),
    # le SID brut fonctionne quelle que soit la locale.
    "public.txt"      = @{ Content = "Document acltest public - visible par tout le monde."; Identity = "*S-1-1-0" }
    "admins-only.txt" = @{ Content = "Document acltest reserve aux administrateurs (docsearch-admins)."; Identity = "docsearch-admins" }
    "users-only.txt"  = @{ Content = "Document acltest reserve aux utilisateurs standards (docsearch-users)."; Identity = "docsearch-users" }
}

foreach ($name in $files.Keys) {
    $path = Join-Path $testDir $name
    Set-Content -Path $path -Value $files[$name].Content -Encoding UTF8

    # /grant AJOUTE une ACE sans toucher aux permissions heritees --
    # le compte de service utilise par docsearch pour lire le partage
    # garde donc l'acces qu'il a deja via l'heritage du dossier parent.
    # Sortie NON supprimee (contrairement a une version precedente) :
    # un icacls qui echoue silencieusement (ex: nom d'identite non
    # resolu) est pire qu'une erreur bruyante -- ca laisse croire qu'un
    # fichier de test est restreint alors qu'il ne l'est pas.
    $icaclsOutput = icacls $path /grant "$($files[$name].Identity):(R)" 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "icacls a echoue pour $path : $icaclsOutput"
    } else {
        Write-Host "Fichier cree : $path  (+ACE $($files[$name].Identity))"
    }
}

# ── Recapitulatif SID (a transmettre pour CIFS_SID_MAP) ─────────────
Write-Host ""
Write-Host "=== SID a transmettre pour CIFS_SID_MAP (docsearch-infra/.env) ==="
foreach ($login in $accounts.Keys) {
    Write-Host ("{0,-20} {1}" -f $login, (Get-LocalUser -Name $login).SID.Value)
}
foreach ($group in "docsearch-admins", "docsearch-users") {
    Write-Host ("{0,-20} {1}" -f $group, (Get-LocalGroup -Name $group).SID.Value)
}
