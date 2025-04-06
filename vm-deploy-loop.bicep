// avd-deployment/modules/vm-deploy-loop.bicep

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

@description('Referencia de la imagen de la VM.')
param imageReference object

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

@description('Tags para los recursos.')
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
          privateIPAllocationMethod: 'Dynamic'
        }
      }
    ]
    // *** CONFIRMADO: Redes Aceleradas activadas ***
    // Nota: El tamaño de VM especificado ('vmSize') DEBE soportar Redes Aceleradas.
    enableAcceleratedNetworking: true
  }
}

// --- Máquina Virtual ---
resource vm 'Microsoft.Compute/virtualMachines@2023-03-01' = {
  name: vmName
  location: location
  tags: tags // Aplica tags
  properties: {
    // Asocia al Availability Set si se proporcionó su ID
    availabilitySet: !empty(availabilitySetId) ? { id: availabilitySetId } : null
    hardwareProfile: {
      vmSize: vmSize
    }
    storageProfile: {
      imageReference: imageReference // Usa el objeto de imagen pasado como parámetro
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
        enableAutomaticUpdates: true
        patchSettings: {
          patchMode: 'AutomaticByOS'
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
    // *** AÑADIDO: Perfil de Seguridad para Trusted Launch (Requerido/Recomendado para Win11 Gen2) ***
    securityProfile: {
      uefiSettings: {
        secureBootEnabled: true // Habilita Arranque Seguro
        vTpmEnabled: true       // Habilita Módulo de Plataforma Segura virtual
      }
      securityType: 'TrustedLaunch' // Especifica el tipo de seguridad Trusted Launch
    }
    // *** (Opcional/Recomendado para Managed Identity) Habilitar Identidad Administrada Asignada por Sistema ***
    // identity: {
    //   type: 'SystemAssigned'
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
      restart: 'true'
      options: '3' // Join domain
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
      // ¡¡IMPORTANTE!! Reemplaza esta URL de ejemplo por la tuya.
      // Idealmente, usa una URI de Blob Storage con SAS Token o configura Managed Identity.
      'fileUris': [
        'https://raw.githubusercontent.com/tu-usuario/tu-repo/main/scripts/InstallAvdAgent.ps1' // <-- ¡¡ACTUALIZA ESTA URL!!
      ]
      // Puedes añadir un timestamp para forzar re-ejecución si el script en la URL cambia pero la URL no
      // 'timestamp': dateTimeUtcNow('u')
    }
    // --- Configuración Protegida ---
    // El comando a ejecutar y cualquier dato sensible (como el token) van aquí.
    // La plataforma Azure cifra estos settings y sólo la extensión dentro de la VM puede descifrarlos.
    // ¡El token NO aparecerá en logs ni en la definición del recurso en Azure!
    protectedSettings: {
      // Comando que se ejecutará DESPUÉS de descargar los archivos de fileUris.
      // Ejecuta el script descargado (InstallAvdAgent.ps1) y le pasa el token como parámetro.
      // La interpolación '${hostpoolToken}' aquí es manejada de forma segura por Bicep/ARM
      // porque está dentro de la sección protectedSettings.
      'commandToExecute': 'powershell.exe -ExecutionPolicy Bypass -File InstallAvdAgent.ps1 -RegistrationToken \'${hostpoolToken}\'' // Token pasado como argumento seguro

      // --- Alternativa usando Managed Identity (Más seguro para acceder a Blob Storage) ---
      // Si el script estuviera en Blob Storage y la VM tuviera Managed Identity con acceso:
      // 'managedIdentity': {
      //   'objectId': '...' // objectId de la User Assigned Identity (o vacío/omitido para System Assigned)
      // },
      // // Ya no necesitarías SAS token en fileUris si usas Managed Identity
      // 'fileUris': [ 'https://mystorageacc.blob.core.windows.net/scripts/InstallAvdAgent.ps1' ]
    }
  }
}


// --- Salida del módulo ---
@description('ID de la VM creada en esta iteración.')
output vmId string = vm.id