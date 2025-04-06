// avd-deployment/modules/vm-deploy-loop-update.bicep

@description('Índice de la VM en el bucle (usado para nombres únicos).')
param vmIndex int

@description('Nombre de la interfaz de red (NIC).')
param nicName string

@description('Nombre de la máquina virtual.')
param vmName string

@description('Ubicación de los recursos.')
param location string

@description('ID de la subred donde se conectará la NIC.')
param subnetId string

@description('Nombre de usuario administrador local.')
param adminUsername string

@description('Contraseña del administrador local.')
@secure()
param adminPassword string

@description('Tamaño de la VM.')
param vmSize string

// *** PARÁMETRO ACTUALIZADO: Acepta ID de imagen directamente ***
@description('Resource ID de la versión de Azure Compute Gallery Image a usar.')
param galleryImageVersionId string

@description('Tipo de disco del SO.')
param osDiskType string

@description('ID del Availability Set (puede ser vacío).')
param availabilitySetId string

@description('Dominio al que unirse.')
param domainToJoin string

@description('Usuario para unirse al dominio.')
param domainUsername string

@description('Contraseña para unirse al dominio.')
@secure()
param domainPassword string

@description('Ruta OU opcional.')
param domainOuPath string

@description('Token de registro del Host Pool AVD.')
@secure()
param hostpoolToken string

@description('ID del Workspace de Log Analytics.')
param logAnalyticsWorkspaceId string

@description('Tags para los recursos (debe incluir sourceImageVersionId).')
param tags object

// --- NIC ---
resource nic 'Microsoft.Network/networkInterfaces@2023-05-01' = {
  name: nicName
  location: location
  tags: tags // Aplica tags
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          subnet: {
            id: subnetId
          }
          privateIPAllocationMethod: 'Dynamic' // O 'Static' si es necesario
        }
      }
    ]
    // *** Redes Aceleradas activadas ***
    // Nota: El tamaño de VM ('vmSize') DEBE soportar Redes Aceleradas.
    enableAcceleratedNetworking: true
  }
}

// --- Máquina Virtual ---
resource vm 'Microsoft.Compute/virtualMachines@2023-03-01' = {
  name: vmName
  location: location
  tags: tags // Aplica TODOS los tags pasados (importante para sourceImageVersionId)
  properties: {
    // Asocia al Availability Set si se proporcionó su ID
    availabilitySet: !empty(availabilitySetId) ? { id: availabilitySetId } : null
    hardwareProfile: {
      vmSize: vmSize
    }
    storageProfile: {
      // *** ACTUALIZADO: Usa el ID de la imagen de la galería directamente ***
      imageReference: {
        id: galleryImageVersionId
      }
      osDisk: {
        createOption: 'FromImage'
        managedDisk: {
          storageAccountType: osDiskType
        }
        deleteOption: 'Delete' // Borrar disco si se borra la VM
      }
    }
    osProfile: {
      computerName: vmName
      adminUsername: adminUsername
      adminPassword: adminPassword
      windowsConfiguration: {
        provisionVMAgent: true // Necesario para extensiones
        enableAutomaticUpdates: true // Considera gestionarlo centralizadamente
        patchSettings: {
          patchMode: 'AutomaticByOS' // Opciones: AutomaticByPlatform, Manual
        }
      }
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: nic.id
        }
      ]
    }
    diagnosticsProfile: {
      bootDiagnostics: {
        enabled: true // Habilita diagnósticos de arranque básicos
      }
    }
    // *** Perfil de Seguridad para Trusted Launch (Windows 11 / Gen2) ***
    securityProfile: {
      uefiSettings: {
        secureBootEnabled: true // Habilita Arranque Seguro
        vTpmEnabled: true       // Habilita Módulo de Plataforma Segura virtual
      }
      securityType: 'TrustedLaunch' // Especifica el tipo de seguridad Trusted Launch
    }
    // *** (Opcional/Recomendado para Managed Identity) Habilitar Identidad Administrada ***
    // Si usas Managed Identity para acceder al script del agente AVD desde Blob Storage
    // identity: {
    //   type: 'SystemAssigned' // O 'UserAssigned', especificando userAssignedIdentities
    // }
  }
}

// --- Extensión: Unir al Dominio ---
resource domainJoinExtension 'Microsoft.Compute/virtualMachines/extensions@2023-03-01' = {
  parent: vm // Asocia la extensión a la VM
  name: 'JsonADDomainExtension'
  location: location
  properties: {
    publisher: 'Microsoft.Compute'
    type: 'JsonADDomainExtension'
    typeHandlerVersion: '1.3' // Verifica la versión más reciente
    autoUpgradeMinorVersion: true
    settings: {
      name: domainToJoin
      ouPath: domainOuPath
      user: domainUsername
      restart: 'true' // Reiniciar después de unirse (necesario)
      options: '3' // 3 = Join domain
    }
    protectedSettings: {
      password: domainPassword
    }
  }
}

// --- Extensión: Azure Monitor Agent (para Logs y Métricas) ---
resource azureMonitorAgentExtension 'Microsoft.Compute/virtualMachines/extensions@2023-03-01' = {
  parent: vm
  name: 'AzureMonitorWindowsAgent'
  location: location
  dependsOn: [ // Depende de que la unión al dominio (y reinicio) haya ocurrido
    domainJoinExtension
  ]
  properties: {
    publisher: 'Microsoft.Azure.Monitor'
    type: 'AzureMonitorWindowsAgent'
    typeHandlerVersion: '1.0' // Verifica la versión
    autoUpgradeMinorVersion: true
    settings: {
      'workspaceId': logAnalyticsWorkspaceId // Autoconfigura usando el workspace ID
    }
  }
}


// --- Extensión: Instalar Agente AVD y Registrar (Método Seguro) ---
// Usa Custom Script Extension para descargar y ejecutar un script PowerShell,
// pasando el token de forma segura a través de protectedSettings.
resource avdAgentExtension 'Microsoft.Compute/virtualMachines/extensions@2023-03-01' = {
  parent: vm
  name: 'InstallAvdAgent'
  location: location
  dependsOn: [ // Ejecutar DESPUÉS de unirse al dominio y DESPUÉS de que el Monitor Agent esté instalado
    domainJoinExtension
    azureMonitorAgentExtension
  ]
  properties: {
    publisher: 'Microsoft.Compute'
    type: 'CustomScriptExtension'
    typeHandlerVersion: '1.10' // Verifica versión
    autoUpgradeMinorVersion: true
    settings: {
      // Especifica la(s) URI(s) desde donde descargar los scripts.
      // ¡¡IMPORTANTE!! Reemplaza esta URL de ejemplo por la tuya (idealmente Blob+SAS/MSI).
      'fileUris': [
        'https://raw.githubusercontent.com/tu-usuario/tu-repo/main/scripts/InstallAvdAgent.ps1' // <-- ¡¡ACTUALIZA ESTA URL!!
      ]
      // 'timestamp': dateTimeUtcNow('u') // Descomenta para forzar re-ejecución si el script cambia
    }
    // --- Configuración Protegida ---
    // El comando a ejecutar y el token van aquí para seguridad.
    protectedSettings: {
      // Ejecuta el script descargado (InstallAvdAgent.ps1) pasando el token como argumento seguro.
      'commandToExecute': 'powershell.exe -ExecutionPolicy Bypass -File InstallAvdAgent.ps1 -RegistrationToken \'${hostpoolToken}\''

      // --- Configuración para Managed Identity (si se usa para acceder al script en Blob) ---
      // 'managedIdentity': {
      //   'objectId': '...' // objectId de la User Assigned Identity (o vacío/omitido para System Assigned)
      // },
      // 'fileUris': [ 'https://mystorageacc.blob.core.windows.net/scripts/InstallAvdAgent.ps1' ] // Sin SAS si usa MSI
    }
  }
}


// --- Salida del módulo ---
@description('ID de la VM creada en esta iteración.')
output vmId string = vm.id