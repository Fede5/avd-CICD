// avd-deployment/sessionhosts-update.bicep
@description('Prefijo para nombrar los nuevos recursos de VM (ej: "avdprod-vm", "avdtest-vm").')
param prefix string

@description('Ubicación para los Session Hosts y recursos asociados.')
param location string

@description('Número de VMs (Session Hosts) a crear en esta ejecución (usualmente 1 para rolling update).')
@minValue(1)
param vmCount int = 1

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

@description('Nombre de dominio completo (FQDN) al que se unirán las VMs (ej: "prod.contoso.com").')
param domainToJoin string

@description('UPN del usuario con permisos para unir al dominio (ej: "svc_join@prod.contoso.com").')
param domainUsername string

@description('Contraseña del usuario de unión al dominio (obtenida de Key Vault).')
@secure()
param domainPassword string

@description('Ruta OU opcional donde se crearán las cuentas de equipo en AD (ej: "OU=AVD,DC=prod,DC=contoso,DC=com"). Dejar vacío si no se requiere.')
param domainOuPath string = ''

@description('Token de registro del Host Pool AVD (obtenido de Key Vault).')
@secure()
param hostpoolToken string

@description('ID del recurso del Host Pool AVD al que se unirán estas VMs.')
param hostPoolId string

@description('ID del Log Analytics Workspace para enviar diagnósticos y monitoreo.')
param logAnalyticsWorkspaceId string

// *** PARÁMETRO CLAVE: ID de la versión de imagen de la galería ***
@description('Resource ID de la versión de Azure Compute Gallery Image a usar para los nuevos hosts.')
param galleryImageVersionId string

@description('Tipo de disco del SO para las VMs.')
@allowed([ 'Standard_LRS', 'StandardSSD_LRS', 'Premium_LRS' ])
param osDiskType string = 'StandardSSD_LRS'

@description('Nombre del Availability Set a crear o usar. Dejar vacío para no usar AS.')
param availabilitySetName string = '${prefix}-as' // Crea uno por defecto con nombre basado en prefijo

@description('Tags a aplicar a los recursos de VMs. Debe incluir "sourceImageVersionId".')
param tags object = {} // El pipeline construirá y pasará este objeto

// --- Recursos de Red (Existentes) ---
// Referencia a la VNet existente
resource existingVnet 'Microsoft.Network/virtualNetworks@2023-05-01' existing = {
  name: existingVnetName
  scope: resourceGroup(existingVnetResourceGroupName)
}

// Referencia a la Subred existente
resource existingSubnet 'Microsoft.Network/virtualNetworks/subnets@2023-05-01' existing = {
  name: existingSubnetName
  parent: existingVnet
}

// --- Availability Set (Opcional pero recomendado) ---
// Define o referencia un Availability Set si se proporciona un nombre
resource availabilitySet 'Microsoft.Compute/availabilitySets@2023-03-01' = if (!empty(availabilitySetName)) {
  name: availabilitySetName
  location: location
  tags: tags // Aplica tags definidos
  sku: {
    name: 'Aligned' // Requerido para Managed Disks
  }
  properties: {
    platformFaultDomainCount: 2 // Ajustable según necesidad
    platformUpdateDomainCount: 5 // Ajustable según necesidad
  }
}

// --- Bucle para crear NICs y VMs usando módulo interno ---
// Itera 'vmCount' veces (normalmente 1 para rolling update)
module vmDeployment 'modules/vm-deploy-loop-update.bicep' = [for i in range(0, vmCount): {
  name: 'vmDeployment-${i}' // Nombre del despliegue del módulo
  params: {
    // Parámetros específicos de esta instancia del bucle
    vmIndex: i // Índice actual (0 si vmCount es 1)
    nicName: '${prefix}-${i}-nic' // Naming convention para NIC
    vmName: '${prefix}-${i}' // Naming convention para VM

    // Parámetros generales pasados al módulo interno
    location: location
    subnetId: existingSubnet.id
    adminUsername: adminUsername
    adminPassword: adminPassword // @secure()
    vmSize: vmSize
    // *** Pasa el ID de la imagen de galería al módulo ***
    galleryImageVersionId: galleryImageVersionId
    osDiskType: osDiskType
    availabilitySetId: empty(availabilitySetName) ? '' : availabilitySet.id // Pasa el ID del AS si se creó/usó
    domainToJoin: domainToJoin
    domainUsername: domainUsername
    domainPassword: domainPassword // @secure()
    domainOuPath: domainOuPath
    hostpoolToken: hostpoolToken // @secure()
    logAnalyticsWorkspaceId: logAnalyticsWorkspaceId
    tags: tags // *** Pasa el objeto de tags completo (que debe incluir sourceImageVersionId) ***
  }
}]

// --- Salidas ---
@description('Lista de IDs de las VMs creadas en esta ejecución.')
output vmIds array = [for i in range(0, vmCount): vmDeployment[i].outputs.vmId] // Recopila IDs de VM creadas