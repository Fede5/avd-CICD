// avd-deployment/sessionhosts.bicep
@description('Prefijo para nombrar recursos de VM (ej: "avd-prod-vm").')
param prefix string

@description('Ubicación para los Session Hosts y recursos asociados.')
param location string

@description('Número de VMs (Session Hosts) a crear.')
@minValue(1)
param vmCount int = 2

@description('Tamaño de las VMs (ej: "Standard_D4s_v3"). Asegúrate que soporta AccelNet y TrustedLaunch.')
param vmSize string = 'Standard_D2s_v3'

@description('Nombre del usuario administrador local para las VMs.')
param adminUsername string

@description('Contraseña para el usuario administrador local (obtenida de Key Vault).')
@secure()
param adminPassword string

@description('Nombre de la Red Virtual existente donde se crearán las NICs.')
param existingVnetName string

@description('Nombre de la Subred existente dentro de la VNet.')
param existingSubnetName string

@description('Nombre del Grupo de Recursos donde reside la VNet existente.')
param existingVnetResourceGroupName string = resourceGroup().name // Asume mismo RG por defecto

@description('Nombre de dominio completo (FQDN) al que se unirán las VMs (ej: "tu.dominio.com").')
param domainToJoin string

@description('UPN del usuario con permisos para unir al dominio (ej: "usuario@tu.dominio.com").')
param domainUsername string

@description('Contraseña del usuario de unión al dominio (obtenida de Key Vault).')
@secure()
param domainPassword string

@description('Ruta OU opcional donde se crearán las cuentas de equipo en AD (ej: "OU=AVD,OU=Workstations,DC=tu,DC=dominio,DC=com"). Dejar vacío si no se requiere.')
param domainOuPath string = ''

@description('Token de registro del Host Pool AVD (obtenido de Key Vault).')
@secure()
param hostpoolToken string

@description('ID del recurso del Host Pool AVD al que se unirán estas VMs.')
param hostPoolId string

@description('ID del Log Analytics Workspace para enviar diagnósticos y monitoreo.')
param logAnalyticsWorkspaceId string

// *** ACTUALIZADO: Usando win11-24h2-avd ***
@description('Detalles de la imagen de VM a usar (Marketplace).')
param imageReference object = {
  publisher: 'MicrosoftWindowsDesktop'
  offer: 'Windows-11'
  sku: 'win11-24h2-avd' // SKU actualizada
  version: 'latest'
}

@description('Tipo de disco del SO para las VMs.')
@allowed([ 'Standard_LRS', 'StandardSSD_LRS', 'Premium_LRS' ])
param osDiskType string = 'StandardSSD_LRS'

@description('Nombre del Availability Set a crear o usar. Dejar vacío para no usar AS.')
param availabilitySetName string = '${prefix}-as' // Crea uno por defecto con nombre basado en prefijo

// *** ACTUALIZADO: Parámetro tags con valores por defecto más descriptivos ***
@description('Tags comunes para aplicar a los recursos de VMs.')
param tags object = {
  environment: 'ChangeMe' // Proporcionado por el pipeline
  project: 'AVD Session Host ${prefix}'
  owner: 'ChangeMe' // Proporcionado por el pipeline
  costCenter: 'ChangeMe' // Proporcionado por el pipeline
  applicationName: 'AVD Session Hosts' // Proporcionado por el pipeline
  creationDate: 'ChangeMe' // Proporcionado por el pipeline
  automationTool: 'AzureDevOps-Bicep' // Proporcionado por el pipeline
}

// --- Recursos de Red (Existentes) ---
resource existingVnet 'Microsoft.Network/virtualNetworks@2023-05-01' existing = {
  name: existingVnetName
  scope: resourceGroup(existingVnetResourceGroupName)
}

resource existingSubnet 'Microsoft.Network/virtualNetworks/subnets@2023-05-01' existing = {
  name: existingSubnetName
  parent: existingVnet
}

// --- Availability Set (Opcional pero recomendado) ---
resource availabilitySet 'Microsoft.Compute/availabilitySets@2023-03-01' = if (!empty(availabilitySetName)) {
  name: availabilitySetName
  location: location
  tags: tags // Aplica tags comunes
  sku: {
    name: 'Aligned' // Requerido para Managed Disks
  }
  properties: {
    platformFaultDomainCount: 2 // Ajustable
    platformUpdateDomainCount: 5 // Ajustable
  }
}

// --- Bucle para crear NICs y VMs usando módulo interno ---
module vmDeployment 'modules/vm-deploy-loop.bicep' = [for i in range(0, vmCount): {
  name: 'vmDeployment-${i}'
  params: {
    // Parámetros específicos de esta instancia del bucle
    vmIndex: i
    nicName: '${prefix}-${i}-nic' // Naming convention
    vmName: '${prefix}-${i}' // Naming convention

    // Parámetros generales pasados al módulo interno
    location: location
    subnetId: existingSubnet.id
    adminUsername: adminUsername
    adminPassword: adminPassword
    vmSize: vmSize
    imageReference: imageReference // Pasa el objeto de imagen actualizado
    osDiskType: osDiskType
    availabilitySetId: empty(availabilitySetName) ? '' : availabilitySet.id // Pasa el ID del AS si se creó
    domainToJoin: domainToJoin
    domainUsername: domainUsername
    domainPassword: domainPassword
    domainOuPath: domainOuPath
    hostpoolToken: hostpoolToken
    logAnalyticsWorkspaceId: logAnalyticsWorkspaceId
    tags: tags // Pasa el objeto de tags actualizado
  }
}]

// --- Salidas ---
@description('Lista de IDs de las VMs creadas.')
output vmIds array = [for i in range(0, vmCount): vmDeployment[i].outputs.vmId]